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

let verify_webhook_signature ~body ~headers:_ =
  let _ = body in
  (* For now, skip JWT verification. In production, implement proper verification.
   * TODO: Add JWT library and implement Plaid webhook verification:
   * 1. Extract Plaid-Verification header (JWT)
   * 2. Get key_id from JWT header
   * 3. Fetch verification key from Plaid
   * 4. Verify JWT signature
   * 5. Verify body hash matches claim
   *)
  Lwt.return true

let extract_public_tokens event =
  match event.public_token with
  | Some token -> [token]
  | None -> 
      match event.public_tokens with
      | Some tokens -> tokens
      | None -> []

let process_webhook_event event =
  let open Db in
  match event.webhook_type, event.webhook_code with
  | "LINK", "SESSION_FINISHED" | "LINK", "ITEM_ADD_RESULT" ->
      let tokens = extract_public_tokens event in
      Lwt_list.iter_s (fun public_token ->
        Plaid.exchange_public_token public_token >>= fun (_, item_id, access_token) ->
        save_token item_id access_token None >>= fun () ->
        (* Update link session status *)
        (match event.link_token with
         | Some link_token -> update_link_session_status link_token "completed"
         | None -> Lwt.return_unit)
      ) tokens
  | "ITEM", "ERROR" ->
      (match event.item_id with
       | Some id -> 
           let open Yojson.Safe.Util in
           let error_code = event.raw |> member "error" |> member "error_code" |> to_string_option in
           (match error_code with
            | Some "ITEM_LOGIN_REQUIRED" -> mark_token_error id
            | _ -> Lwt.return_unit)
       | None -> Lwt.return_unit)
  | _ -> 
      (* Other webhook types - just log *)
      Lwt.return_unit

let handle_webhook ~body ~headers =
  verify_webhook_signature ~body ~headers >>= function
  | true ->
      (try
         let json = Yojson.Safe.from_string body in
         let event = parse_webhook_event json in
         process_webhook_event event >>= fun () ->
         Lwt.return (Ok event)
       with
       | exn -> Lwt.return (Error (Printexc.to_string exn)))
  | false -> Lwt.return (Error "Invalid webhook signature")