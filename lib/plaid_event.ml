type event_type =
  | Transactions
  | Income
  | Identity
  | Balances
  | Credit_details
  | Assets
  | Auth_connected
  | Auth_error

type event = {
  event_type : event_type;
  item_id : string;
  (* Which authentication attempt this concerns. A front-end may have started
     a session while another one is still open, so an [Auth_connected] with no
     way back to a link token is not actionable. *)
  link_token : string option;
  error : string option;
  new_transactions : int option;
  last_updated : string option;
}

let event_type_to_string = function
  | Transactions -> "transactions"
  | Income -> "income"
  | Identity -> "identity"
  | Balances -> "balances"
  | Credit_details -> "credit_details"
  | Assets -> "assets"
  | Auth_connected -> "auth_connected"
  | Auth_error -> "auth_error"

let string_to_event_type = function
  | "transactions" -> Transactions
  | "income" -> Income
  | "identity" -> Identity
  | "balances" -> Balances
  | "credit_details" -> Credit_details
  | "assets" -> Assets
  | "auth_connected" -> Auth_connected
  | "auth_error" -> Auth_error
  | _ -> Transactions

let make ?(item_id = "") ?link_token ?error ?new_transactions ?last_updated
      event_type =
  { event_type; item_id; link_token; error; new_transactions; last_updated }

let auth_connected ~item_id ~link_token =
  make ~item_id ?link_token Auth_connected

let auth_error ?(item_id = "") ~link_token message =
  make ~item_id ?link_token ~error:message Auth_error

let to_json event =
  let string_or_null = function Some s -> `String s | None -> `Null in
  `Assoc
    [ ("event_type", `String (event_type_to_string event.event_type));
      ("item_id", `String event.item_id);
      ("link_token", string_or_null event.link_token);
      ("error", string_or_null event.error);
      ( "new_transactions",
        match event.new_transactions with Some n -> `Int n | None -> `Null );
      ("last_updated", string_or_null event.last_updated) ]

let of_json = function
  | `Assoc fields ->
    let string_field key =
      match List.assoc_opt key fields with
      | Some (`String s) -> Some s
      | _ -> None
    in
    {
      event_type =
        (match string_field "event_type" with
         | Some s -> string_to_event_type s
         | None -> Transactions);
      item_id = string_field "item_id" |> Option.value ~default:"";
      link_token = string_field "link_token";
      error = string_field "error";
      new_transactions =
        (match List.assoc_opt "new_transactions" fields with
         | Some (`Int n) -> Some n
         | _ -> None);
      last_updated = string_field "last_updated";
    }
  | _ -> make Transactions
