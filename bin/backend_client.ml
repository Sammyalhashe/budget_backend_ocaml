open Lwt.Infix

let base_url =
  match Sys.getenv_opt "BUDGET_BACKEND_URL" with
  | Some url -> url
  | None -> "http://localhost:5000"

type auth_start = {
  link_token : string;
  hosted_link_url : string;
}

type auth_result = {
  status : string;
  item_id : string;
  access_token : string;
}

(* What the backend knows about the current connection, as reported by
   /api/plaid/status and by the snapshot the event stream opens with. *)
type connection =
  | Connected of { item_id : string; access_token : string }
  | Pending of { link_token : string }
  | Auth_failed of { link_token : string }
  | Disconnected

type account = {
  account_id : string;
  name : string;
  mask : string option;
  subtype : string option;
  balance : float option;
  currency : string option;
}

type transaction = {
  date : string;
  description : string;
  amount : float;
  currency : string option;
}

type error =
  | Connection_refused
  | Timeout
  | Http_error of int
  | Parse_error of string
  | Auth_rejected of string
  | Not_connected

let error_to_string = function
  | Connection_refused -> "Connection refused - is the backend running?"
  | Timeout -> "Timeout - auth took too long"
  | Http_error code -> Printf.sprintf "HTTP error %d" code
  | Parse_error msg -> Printf.sprintf "Parse error: %s" msg
  | Auth_rejected msg -> msg
  | Not_connected -> "No bank account is connected yet"

let catch_request f =
  Lwt.catch f (function
    | Unix.Unix_error (Unix.ECONNREFUSED, _, _) ->
      Lwt.return (Error Connection_refused)
    | exn -> Lwt.return (Error (Parse_error (Printexc.to_string exn))))

let http_post path =
  let uri = Uri.of_string (base_url ^ path) in
  let body = Cohttp_lwt.Body.of_string "" in
  Cohttp_lwt_unix.Client.post ~body uri >>= fun (resp, body) ->
  let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
  Cohttp_lwt.Body.to_string body >>= fun body_str ->
  Lwt.return (status, body_str)

let http_get path =
  let uri = Uri.of_string (base_url ^ path) in
  Cohttp_lwt_unix.Client.get uri >>= fun (resp, body) ->
  let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
  Cohttp_lwt.Body.to_string body >>= fun body_str ->
  Lwt.return (status, body_str)

let start_auth () =
  catch_request (fun () ->
    http_post "/api/plaid/start-auth" >>= fun (status, body) ->
    if status <> 200 then Lwt.return (Error (Http_error status))
    else
      let json = Yojson.Safe.from_string body in
      let open Yojson.Safe.Util in
      let link_token = json |> member "link_token" |> to_string in
      let hosted_link_url = json |> member "hosted_link_url" |> to_string in
      Lwt.return (Ok { link_token; hosted_link_url }))

let string_field ?(default = "") json name =
  Yojson.Safe.Util.(json |> member name |> to_string_option)
  |> Option.value ~default

let wait_auth ~link_token =
  catch_request (fun () ->
    let path = Printf.sprintf "/api/plaid/wait-auth?link_token=%s" link_token in
    http_get path >>= fun (status, body) ->
    if status = 408 then Lwt.return (Error Timeout)
    else if status <> 200 then Lwt.return (Error (Http_error status))
    else
      let json = Yojson.Safe.from_string body in
      let open Yojson.Safe.Util in
      let item_status = json |> member "status" |> to_string in
      Lwt.return
        (Ok
           {
             status = item_status;
             item_id = string_field json "item_id";
             access_token = string_field json "access_token";
           }))

let connection_of_json json =
  let field = string_field json in
  match field "status" with
  | "connected" ->
    Connected { item_id = field "item_id"; access_token = field "access_token" }
  | "pending" -> Pending { link_token = field "link_token" }
  | "error" -> Auth_failed { link_token = field "link_token" }
  | _ -> Disconnected

(* Asked once at startup: the connection outlives the TUI process, so a
   restart should land on the accounts rather than on "press Enter to
   connect". *)
let status () =
  catch_request (fun () ->
    http_get "/api/plaid/status" >>= fun (code, body) ->
    if code <> 200 then Lwt.return (Error (Http_error code))
    else Lwt.return (Ok (connection_of_json (Yojson.Safe.from_string body))))

let fetch_json path ~parse =
  catch_request (fun () ->
    http_get path >>= fun (code, body) ->
    if code = 404 then Lwt.return (Error Not_connected)
    else if code <> 200 then Lwt.return (Error (Http_error code))
    else Lwt.return (Ok (parse (Yojson.Safe.from_string body))))

let account_of_json json =
  let open Yojson.Safe.Util in
  let balances = json |> member "balances" in
  {
    account_id = string_field json "account_id";
    name = string_field json "name" ~default:"(unnamed)";
    mask = json |> member "mask" |> to_string_option;
    subtype = json |> member "subtype" |> to_string_option;
    balance =
      (match balances |> member "current" with
       | `Float f -> Some f
       | `Int i -> Some (float_of_int i)
       | _ -> None);
    currency = balances |> member "iso_currency_code" |> to_string_option;
  }

let accounts () =
  fetch_json "/api/plaid/accounts" ~parse:(fun json ->
    let open Yojson.Safe.Util in
    json |> member "accounts" |> to_list |> List.map account_of_json)

let transaction_of_json json =
  let open Yojson.Safe.Util in
  {
    date = string_field json "date";
    description =
      (match json |> member "merchant_name" |> to_string_option with
       | Some name -> name
       | None -> string_field json "name");
    amount =
      (match json |> member "amount" with
       | `Float f -> f
       | `Int i -> float_of_int i
       | _ -> 0.0);
    currency = json |> member "iso_currency_code" |> to_string_option;
  }

let transactions ?(days = 30) () =
  let path =
    Printf.sprintf "/api/plaid/transactions?start_date=%s"
      (let seconds = Unix.gettimeofday () -. (float_of_int days *. 86400.) in
       let tm = Unix.gmtime seconds in
       Printf.sprintf "%04d-%02d-%02d" (tm.Unix.tm_year + 1900)
         (tm.Unix.tm_mon + 1) tm.Unix.tm_mday)
  in
  fetch_json path ~parse:(fun json ->
    let open Yojson.Safe.Util in
    json |> member "transactions" |> to_list |> List.map transaction_of_json)

(* The event stream (SSE).

   This is the leg that closes the loop the user never sees: Plaid posts the
   webhook to the backend, the backend exchanges the token and broadcasts,
   and the frame arriving here is what tells the TUI it may start asking for
   data. Frames are "event: <name>", "data: <json>", blank line; lines
   beginning with ':' are keep-alive comments. *)

type frame = { name : string; data : string }

let parse_frame block =
  let lines = String.split_on_char '\n' block in
  let field prefix line =
    let n = String.length prefix in
    if String.length line >= n && String.sub line 0 n = prefix then
      Some (String.trim (String.sub line n (String.length line - n)))
    else None
  in
  let name = List.find_map (field "event:") lines in
  let data = List.find_map (field "data:") lines in
  match (name, data) with
  | Some name, Some data -> Some { name; data }
  | _ -> None

(* Frames arrive split across chunks at arbitrary points, so completed ones
   are cut off a buffer rather than read per chunk. *)
let frames_of_buffer buffer =
  (* A frame ends at the first blank line. *)
  let blank_line_index s =
    let len = String.length s in
    let rec find i =
      if i + 1 >= len then None
      else if s.[i] = '\n' && s.[i + 1] = '\n' then Some i
      else find (i + 1)
    in
    find 0
  in
  let rec split acc rest =
    match blank_line_index rest with
    | None -> (List.rev acc, rest)
    | Some i ->
      let block = String.sub rest 0 i in
      let rest = String.sub rest (i + 2) (String.length rest - i - 2) in
      split (block :: acc) rest
  in
  let blocks, remainder = split [] (Buffer.contents buffer) in
  Buffer.clear buffer;
  Buffer.add_string buffer remainder;
  List.filter_map parse_frame blocks

(* Reads the stream until [decide] returns a verdict for one of its frames.
   The connection is left to close with the process: the stream never ends on
   its own, so there is nothing to drain. *)
let watch_events ~decide =
  catch_request (fun () ->
    let uri = Uri.of_string (base_url ^ "/api/plaid/events") in
    Cohttp_lwt_unix.Client.get uri >>= fun (resp, body) ->
    let code = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
    if code <> 200 then Lwt.return (Error (Http_error code))
    else
      let chunks = Cohttp_lwt.Body.to_stream body in
      let buffer = Buffer.create 512 in
      let rec read () =
        Lwt_stream.get chunks >>= function
        | None -> Lwt.return (Error (Parse_error "event stream closed"))
        | Some chunk ->
          Buffer.add_string buffer chunk;
          let rec consume = function
            | [] -> read ()
            | frame :: rest ->
              (match decide frame.name (Yojson.Safe.from_string frame.data) with
               | Some verdict -> Lwt.return verdict
               | None -> consume rest)
          in
          consume (frames_of_buffer buffer)
      in
      read ())

(* Resolves when the backend announces the outcome of [link_token]. Events
   for an older session are ignored, as is the opening status snapshot: a
   connection left over from a previous run would otherwise report this
   session as finished the moment it starts. *)
let watch_auth ~link_token =
  watch_events ~decide:(fun name json ->
    let open Yojson.Safe.Util in
    if name <> "plaid" then None
    else
      let event_link_token = json |> member "link_token" |> to_string_option in
      if event_link_token <> Some link_token then None
      else
        match json |> member "event_type" |> to_string_option with
        | Some "auth_connected" ->
          Some
            (Ok
               {
                 status = "connected";
                 item_id =
                   json |> member "item_id" |> to_string_option
                   |> Option.value ~default:"";
                 access_token = "";
               })
        | Some "auth_error" ->
          Some
            (Error
               (Auth_rejected
                  (json |> member "error" |> to_string_option
                  |> Option.value ~default:"authentication failed")))
        | _ -> None)

(* A verdict is an answer about the session; anything else is one way of
   listening having broken, which says nothing about the other. *)
let is_verdict = function
  | Ok _ | Error (Auth_rejected _) | Error Timeout -> true
  | Error _ -> false

(* Waits for the session to finish over both channels at once.

   They fail independently: an event stream cut by a proxy, or a long poll
   the backend answers with a 502 mid-restart, must not be reported as a
   failed authentication while the other channel is still listening. Only a
   verdict ends the wait early; a transport failure retires that channel and
   is surfaced only if the other one never produces an answer either. *)
let await_auth ~link_token =
  let rec settle pending fallback =
    if pending = [] then Lwt.return (Error fallback)
    else
      Lwt.nchoose_split pending >>= fun (settled, still_pending) ->
      match List.find_opt is_verdict settled with
      | Some verdict ->
        List.iter Lwt.cancel still_pending;
        Lwt.return verdict
      | None ->
        let fallback =
          match settled with Error e :: _ -> e | _ -> fallback
        in
        settle still_pending fallback
  in
  settle
    [ wait_auth ~link_token; watch_auth ~link_token ]
    (Parse_error "no answer from the backend")
