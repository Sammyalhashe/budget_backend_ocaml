open Lwt.Infix

type webhook_event = {
  webhook_type: string;
  webhook_code: string;
  link_token: string option;
  item_id: string option;
  public_token: string option;
  public_tokens: string list option;
  status: string option;
  link_session_id: string option;
  environment: string option;
  raw: Yojson.Safe.t;
}

let parse_webhook_event (json : Yojson.Safe.t) =
  let fields = Yojson.Safe.Util.to_assoc json in
  let get_string key = 
    match List.assoc_opt key fields with
    | Some (`String s) -> Some s
    | _ -> None
  in
  let get_string_list key =
    match List.assoc_opt key fields with
    | Some (`List lst) -> 
        Some (List.filter_map (function `String s -> Some s | _ -> None) lst)
    | _ -> None
  in
  {
    webhook_type = get_string "webhook_type" |> Option.value ~default:"";
    webhook_code = get_string "webhook_code" |> Option.value ~default:"";
    link_token = get_string "link_token";
    item_id = get_string "item_id";
    public_token = get_string "public_token";
    public_tokens = get_string_list "public_tokens";
    status = get_string "status";
    link_session_id = get_string "link_session_id";
    environment = get_string "environment";
    raw = json;
  }

(* Signature verification: the impure half. Plaid_jwt does the checking; this
   supplies it with keys and the clock, and decides what to do on failure. *)

(* Set PLAID_WEBHOOK_VERIFY=false to accept unverified webhooks. Only useful
   when experimenting against a webhook you are posting by hand. *)
let verification_enabled =
  match Sys.getenv_opt "PLAID_WEBHOOK_VERIFY" with
  | Some ("false" | "0" | "no") -> false
  | _ -> true

let () =
  if not verification_enabled then
    prerr_endline
      "WARNING: PLAID_WEBHOOK_VERIFY is off. Webhook signatures are not \
       checked and this endpoint will accept a forged request from anyone."

(* Plaid rotates keys rarely, so one fetch per kid is plenty. The mutex stops
   a burst of webhooks all fetching the same key at once. *)
let key_cache : (string, Jose.Jwk.public Jose.Jwk.t) Hashtbl.t =
  Hashtbl.create 4

let key_cache_mutex = Lwt_mutex.create ()

let fetch_verification_key kid =
  Lwt.catch
    (fun () ->
      Plaid.get_webhook_verification_key ~key_id:kid () >>= fun json ->
      let key_json = Yojson.Safe.Util.member "key" json in
      (* A retired key must not verify anything, however well-formed. *)
      match Yojson.Safe.Util.member "expired_at" key_json with
      | `Null ->
        (match Jose.Jwk.of_pub_json key_json with
         | Ok jwk -> Lwt.return (Ok jwk)
         | Error _ -> Lwt.return (Error ("key " ^ kid ^ " is not a usable JWK")))
      | _ -> Lwt.return (Error ("key " ^ kid ^ " has expired")))
    (fun exn ->
      Lwt.return (Error ("could not fetch key " ^ kid ^ ": " ^ Printexc.to_string exn)))

let verification_key kid =
  match Hashtbl.find_opt key_cache kid with
  | Some jwk -> Lwt.return (Ok jwk)
  | None ->
    Lwt_mutex.with_lock key_cache_mutex (fun () ->
      match Hashtbl.find_opt key_cache kid with
      | Some jwk -> Lwt.return (Ok jwk)
      | None ->
        fetch_verification_key kid >>= function
        | Ok jwk -> Hashtbl.replace key_cache kid jwk; Lwt.return (Ok jwk)
        | Error _ as e -> Lwt.return e)

let verification_header headers =
  List.find_map
    (fun (name, value) ->
      if String.lowercase_ascii name = "plaid-verification" then Some value
      else None)
    headers

let verify_webhook_signature ~body ~headers =
  if not verification_enabled then Lwt.return (Ok ())
  else
    match verification_header headers with
    | None -> Lwt.return (Error "no Plaid-Verification header")
    | Some token ->
      (match Plaid_jwt.kid_of_token token with
       | Error reason -> Lwt.return (Error (Plaid_jwt.reason_to_string reason))
       | Ok kid ->
         verification_key kid >>= (function
         | Error msg -> Lwt.return (Error msg)
         | Ok jwk ->
           let now = Unix.gettimeofday () in
           (match Plaid_jwt.verify ~jwk ~body ~now token with
            | Ok () -> Lwt.return (Ok ())
            | Error reason ->
              Lwt.return (Error (Plaid_jwt.reason_to_string reason)))))

let extract_public_tokens event =
  match event.public_token with
  | Some token -> [token]
  | None -> 
      match event.public_tokens with
      | Some tokens -> tokens
      | None -> []

let process_webhook_event event =
  match event.webhook_type, event.webhook_code with
  | "LINK", ("SESSION_FINISHED" | "ITEM_ADD_RESULT") ->
    (match event.link_token with
     | Some link_token ->
       let tokens = extract_public_tokens event in
       (* An abandoned session arrives as SESSION_FINISHED with status EXITED and
          no public tokens; claiming it would lock out the polling fallback. *)
       let succeeded =
         tokens <> [] && (match event.status with
                          | Some status -> status = "SUCCESS"
                          | None -> true)
       in
       if not succeeded then
         Db.get_link_session link_token >>= (function
         | Some (_, _, "connected", _) -> Lwt.return_unit
         | _ ->
           Db.update_link_session_status link_token "error" >>= fun () ->
           let err_event = Plaid_event.{
             event_type = Auth_error;
             item_id = (match event.item_id with Some id -> id | None -> "");
             error = Some ("Link session did not complete: " ^
                           (match event.status with Some s -> s | None -> "no public token"));
             new_transactions = None;
             last_updated = None;
           } in
           Plaid_notifier.notify err_event)
       else
         Auth_flow.exchange ~link_token ~public_tokens:tokens >>= (function
         | Auth_flow.Already_claimed -> Lwt.return_unit
         | Auth_flow.Connected { item_id; access_token = _ } ->
           let auth_event = Plaid_event.{
             event_type = Auth_connected;
             item_id;
             error = None;
             new_transactions = None;
             last_updated = None;
           } in
           Plaid_notifier.notify auth_event
         | Auth_flow.Failed msg ->
           let err_event = Plaid_event.{
             event_type = Auth_error;
             item_id = "";
             error = Some msg;
             new_transactions = None;
             last_updated = None;
           } in
           Plaid_notifier.notify err_event)
     | None -> Lwt.return_unit)
  | "ITEM", "ERROR" ->
    (match event.item_id with
     | Some id ->
       let open Yojson.Safe.Util in
       let error_code = event.raw |> member "error" |> member "error_code" |> to_string_option in
       (match error_code with
        | Some "ITEM_LOGIN_REQUIRED" -> Db.mark_token_error id
        | _ -> Lwt.return_unit)
     | None -> Lwt.return_unit)
  | _ -> Lwt.return_unit

let handle_webhook ~body ~headers =
  verify_webhook_signature ~body ~headers >>= function
  | Error reason -> Lwt.return (Error ("rejected: " ^ reason))
  | Ok () ->
    (* Lwt.catch rather than try/with: process_webhook_event returns a promise,
       and a bare try only catches what is raised while that promise is being
       built. Every Db call rejects rather than raises, so those failures used
       to escape to Dream as a 500, prompting Plaid to retry a webhook whose
       claim had already been consumed. *)
    Lwt.catch
      (fun () ->
        let json = Yojson.Safe.from_string body in
        let event = parse_webhook_event json in
        process_webhook_event event >>= fun () -> Lwt.return (Ok event))
      (fun exn -> Lwt.return (Error (Printexc.to_string exn)))