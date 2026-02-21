(* Plaid API integration (sandbox, dummy credentials) *)

open Lwt.Infix
open Cohttp_lwt_unix
open Cohttp
open Yojson.Safe

let client_id = "dummy_client_id"
let secret = "dummy_secret"
let base_url = "https://sandbox.plaid.com"

let default_headers =
  Header.init ()
  |> Header.add "Content-Type" "application/json"
  |> Header.add "PLAID-CLIENT-ID" client_id
  |> Header.add "PLAID-SECRET" secret

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
  let body = `String (to_string body_json) in
  Client.post ~headers:default_headers ~body uri >>= fun (_resp, body) ->
  Body.to_string body >|= from_string

let exchange_public_token public_token =
  let uri = Uri.of_string (base_url ^ "/item/public_token/exchange") in
  let body_json =
    `Assoc [
      ("client_id", `String client_id);
      ("secret", `String secret);
      ("public_token", `String public_token)
    ]
  in
  let body = `String (to_string body_json) in
  Client.post ~headers:default_headers ~body uri >>= fun (_resp, body) ->
  Body.to_string body >|= from_string
