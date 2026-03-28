type event_type =
  | Transactions
  | Income
  | Identity
  | Balances
  | Credit_details
  | Assets

type event = {
  event_type : event_type;
  item_id : string;
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

let string_to_event_type = function
  | "transactions" -> Transactions
  | "income" -> Income
  | "identity" -> Identity
  | "balances" -> Balances
  | "credit_details" -> Credit_details
  | "assets" -> Assets
  | _ -> Transactions

let to_json event =
  let error_json = match event.error with
    | Some e -> `String e
    | None -> `Null
  in
  let new_transactions_json = match event.new_transactions with
    | Some n -> `Int n
    | None -> `Null
  in
  let last_updated_json = match event.last_updated with
    | Some t -> `String t
    | None -> `Null
  in
  `Assoc [
    ("event_type", `String (event_type_to_string event.event_type));
    ("item_id", `String event.item_id);
    ("error", error_json);
    ("new_transactions", new_transactions_json);
    ("last_updated", last_updated_json)
  ]

let of_json = function
  | `Assoc fields ->
    let event_type = match List.assoc_opt "event_type" fields with
      | Some (`String s) -> string_to_event_type s
      | _ -> Transactions
    in
    let item_id = match List.assoc_opt "item_id" fields with
      | Some (`String s) -> s
      | _ -> ""
    in
    let error = match List.assoc_opt "error" fields with
      | Some (`String s) -> Some s
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
    { event_type; item_id; error; new_transactions; last_updated }
  | _ -> {
      event_type = Transactions;
      item_id = "";
      error = None;
      new_transactions = None;
      last_updated = None
    }
