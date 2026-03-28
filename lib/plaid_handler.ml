open Lwt.Infix

let create_link_token () =
  Plaid.create_link_token () >>= fun json ->
  Lwt.return (`Assoc [("link_token", json)])

let exchange_public_token public_token =
  Plaid.exchange_public_token public_token >>= fun (_json, item_id, access_token) ->
  Db.save_token item_id access_token None >>= fun () ->
  Lwt.return (`Assoc [("access_token", `String access_token); ("item_id", `String item_id)])

let get_transactions access_token start_date end_date =
  Plaid.get_transactions access_token start_date end_date >>= fun json ->
  Lwt.return json

let handle_webhook payload =
  let fields = Yojson.Safe.Util.to_assoc payload in
  let event_type = match List.assoc_opt "event_type" fields with
    | Some (`String s) -> s
    | _ -> ""
  in
  let item_id = match List.assoc_opt "item_id" fields with
    | Some (`String s) -> s
    | _ -> ""
  in
  let error = match List.assoc_opt "error" fields with
    | Some (`Assoc err_fields) ->
      let error_message = match List.assoc_opt "error_message" err_fields with
        | Some (`String s) -> s
        | _ -> ""
      in
      Some error_message
    | _ -> None
  in
  let new_transactions = match List.assoc_opt "new_transactions" fields with
    | Some (`Int n) -> Some n
    | _ -> None
  in
  let last_updated = match List.assoc_opt "last_updated" fields with
    | Some (`String s) -> Some s
    | _ -> None
  in
  let event = {
    Plaid_event.event_type = Plaid_event.string_to_event_type event_type;
    item_id;
    error;
    new_transactions;
    last_updated
  } in
  Plaid_notifier.notify event >>= fun () ->
  Lwt.return_unit
