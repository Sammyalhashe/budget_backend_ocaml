(* Plaid API integration (sandbox, dummy credentials) *)

open Lwt.Infix
open Yojson.Safe

let client_id = Sys.getenv_opt "PLAID_CLIENT_ID" |> Option.value ~default:"dummy_client_id"
let secret = Sys.getenv_opt "PLAID_SECRET" |> Option.value ~default:"dummy_secret"
let base_url = "https://sandbox.plaid.com"

let default_headers =
  let h = Cohttp.Header.init () in
  let h = Cohttp.Header.add h "Content-Type" "application/json" in
  let h = Cohttp.Header.add h "PLAID-CLIENT-ID" client_id in
  Cohttp.Header.add h "PLAID-SECRET" secret

let create_link_token () =
  let uri = Uri.of_string (base_url ^ "/link/token/create") in
  let body_json =
    `Assoc [
      ("client_id", `String client_id);
      ("secret", `String secret);
      ("client_name", `String "Budget Backend");
      ("language", `String "en");
      ("country_codes", `List [`String "US"]);
      ("products", `List [`String "transactions"])
    ]
  in
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
  Cohttp_lwt.Body.to_string body >|= from_string

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
  Cohttp_lwt.Body.to_string body
