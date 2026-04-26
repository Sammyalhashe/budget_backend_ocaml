(* Plaid API integration (sandbox, dummy credentials) *)

open Lwt.Infix
open Yojson.Safe

let client_id = Sys.getenv_opt "PLAID_CLIENT_ID" |> Option.value ~default:"dummy_client_id"
let secret = Sys.getenv_opt "PLAID_SECRET" |> Option.value ~default:"dummy_secret"
let env = Sys.getenv_opt "PLAID_ENV" |> Option.value ~default:"sandbox"
let base_url = 
  match env with
  | "production" -> "https://production.plaid.com"
  | "development" -> "https://development.plaid.com"
  | _ -> "https://sandbox.plaid.com"
let webhook_url = Sys.getenv_opt "PLAID_WEBHOOK_URL"

let default_headers =
  let h = Cohttp.Header.init () in
  let h = Cohttp.Header.add h "Content-Type" "application/json" in
  let h = Cohttp.Header.add h "PLAID-CLIENT-ID" client_id in
  Cohttp.Header.add h "PLAID-SECRET" secret

let create_link_token ?(hosted_link = false) ?webhook () =
  let uri = Uri.of_string (base_url ^ "/link/token/create") in
  let products = `List [`String "transactions"] in
  let user = `Assoc [("client_user_id", `String "user-1")] in
  let base_fields = [
    ("client_id", `String client_id);
    ("secret", `String secret);
    ("client_name", `String "Budget Backend");
    ("language", `String "en");
    ("country_codes", `List [`String "US"]);
    ("products", products);
    ("user", user);
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
  let body_json = `Assoc fields_with_hosted_link in
  let body = Cohttp_lwt.Body.of_string (to_string body_json) in
  Cohttp_lwt_unix.Client.post ~headers:default_headers ~body uri >>= fun (_resp, body) ->
  Cohttp_lwt.Body.to_string body >|= from_string

let exchange_public_token public_token =
  let uri = Uri.of_string (base_url ^ "/item/public_token/exchange") in
  let body_json =
    `Assoc [
      ("client_id", `String client_id);
      ("secret", `String secret);
      ("public_token", `String public_token)
    ]
  in
  let body = Cohttp_lwt.Body.of_string (to_string body_json) in
  Cohttp_lwt_unix.Client.post ~headers:default_headers ~body uri >>= fun (_resp, body) ->
  Cohttp_lwt.Body.to_string body >|= from_string >|= fun json ->
  let fields = match json with
    | `Assoc fields -> fields
    | _ -> []
  in
  let item_id = match List.assoc_opt "item_id" fields with
    | Some (`String id) -> id
    | _ -> ""
  in
  let access_token = match List.assoc_opt "access_token" fields with
    | Some (`String token) -> token
    | _ -> ""
  in
  (json, item_id, access_token)

let get_transactions access_token start_date end_date =
  let uri = Uri.of_string (base_url ^ "/transactions/get") in
  let body_json =
    `Assoc [
      ("client_id", `String client_id);
      ("secret", `String secret);
      ("access_token", `String access_token);
      ("start_date", `String start_date);
      ("end_date", `String end_date)
    ]
  in
  let body = Cohttp_lwt.Body.of_string (to_string body_json) in
  Cohttp_lwt_unix.Client.post ~headers:default_headers ~body uri >>= fun (_resp, body) ->
  Cohttp_lwt.Body.to_string body >|= from_string

let get_link_token_results link_token =
  let uri = Uri.of_string (base_url ^ "/link/token/get") in
  let body_json =
    `Assoc [
      ("client_id", `String client_id);
      ("secret", `String secret);
      ("link_token", `String link_token)
    ]
  in
  let body_str = to_string body_json in
  let body = Cohttp_lwt.Body.of_string body_str in
  Cohttp_lwt_unix.Client.post ~headers:default_headers ~body uri >>= fun (resp, body) ->
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Cohttp_lwt.Body.to_string body >>= fun body_str ->
  Printf.printf "[DEBUG] Plaid get_link_token_results: status=%d\n" status;
  Lwt.return body_str >|= from_string

let get_webhook_verification_key ?key_id () =
  let uri = Uri.of_string (base_url ^ "/webhook_verification_key/get") in
  let base_fields = [
    ("client_id", `String client_id);
    ("secret", `String secret);
  ] in
  let fields = 
    match key_id with
    | Some id -> ("key_id", `String id) :: base_fields
    | None -> base_fields
  in
  let body_json = `Assoc fields in
  let body = Cohttp_lwt.Body.of_string (to_string body_json) in
  Cohttp_lwt_unix.Client.post ~headers:default_headers ~body uri >>= fun (_resp, body) ->
  Cohttp_lwt.Body.to_string body >|= from_string

let get_accounts access_token =
  let uri = Uri.of_string (base_url ^ "/accounts/get") in
  let body_json =
    `Assoc [
      ("client_id", `String client_id);
      ("secret", `String secret);
      ("access_token", `String access_token)
    ]
  in
  let body = Cohttp_lwt.Body.of_string (to_string body_json) in
  Cohttp_lwt_unix.Client.post ~headers:default_headers ~body uri >>= fun (_resp, body) ->
  Cohttp_lwt.Body.to_string body >|= from_string
