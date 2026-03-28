open Lwt
open Cohttp
open Cohttp_lwt_unix
open Yojson.Safe

let plaid_env () =
  match Sys.getenv_opt "PLAID_ENV" with
  | Some env -> env
  | None -> "sandbox"

let plaid_client_id () =
  match Sys.getenv_opt "PLAID_CLIENT_ID" with
  | Some id -> id
  | None -> failwith "PLAID_CLIENT_ID environment variable not set"

let plaid_secret () =
  match Sys.getenv_opt "PLAID_SECRET" with
  | Some secret -> secret
  | None -> failwith "PLAID_SECRET environment variable not set"

let plaid_base_url () =
  match plaid_env () with
  | "sandbox" -> "https://sandbox.plaid.com"
  | "development" -> "https://development.plaid.com"
  | "production" -> "https://production.plaid.com"
  | _ -> "https://sandbox.plaid.com"

let plaid_post endpoint body =
  let uri = Uri.of_string (plaid_base_url () ^ endpoint) in
  let headers =
    Header.add (Header.add (Header.add Header.empty "Content-Type" "application/json")
                "PLAID-CLIENT-ID" (plaid_client_id ()))
      "PLAID-SECRET" (plaid_secret ())
  in
  let body = Cohttp_lwt.Body.of_string (to_string body) in
  Client.post uri ~headers ~body >>= fun (res, body_str) ->
  if res.status = `OK then
    Lwt.return (of_string body_str)
  else
    Lwt.fail_with ("Plaid API error: " ^ string_of_status res.status)

let create_link_token ?(hosted_link = false) ?webhook () =
  let base_fields = [
    ("client_id", `String (plaid_client_id ()));
    ("secret", `String (plaid_secret ()));
    ("client_user_id", `String "user-123");
    ("products", `List [`String "transactions"]);
    ("country_codes", `List [`String "US"]);
    ("language", `String "en");
    ("client_name", `String "Budget Backend");
  ] in
  let fields_with_webhook = 
    match webhook with
    | Some url -> ("webhook", `String url) :: base_fields
    | None -> base_fields
  in
  let fields_with_hosted_link =
    if hosted_link then
      ("hosted_link", `Assoc []) :: fields_with_webhook
    else
      fields_with_webhook
  in
  let body = `Assoc fields_with_hosted_link in
  plaid_post "/link/token/create" body

let exchange_public_token public_token =
  let body = `Assoc [
    ("client_id", `String (plaid_client_id ()));
    ("secret", `String (plaid_secret ()));
    ("public_token", `String public_token)
  ] in
  plaid_post "/item/public_token/exchange" body

let get_transactions access_token start_date end_date =
  let body = `Assoc [
    ("client_id", `String (plaid_client_id ()));
    ("secret", `String (plaid_secret ()));
    ("access_token", `String access_token);
    ("start_date", `String start_date);
    ("end_date", `String end_date)
  ] in
  plaid_post "/transactions/get" body
```