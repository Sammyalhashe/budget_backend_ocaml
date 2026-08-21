(* Plaid API integration (sandbox, dummy credentials) *)

open Lwt.Infix
open Yojson.Safe

let client_id = Sys.getenv_opt "PLAID_CLIENT_ID" |> Option.value ~default:"dummy_client_id"
let secret = Sys.getenv_opt "PLAID_SECRET" |> Option.value ~default:"dummy_secret"
let env = Sys.getenv_opt "PLAID_ENV" |> Option.value ~default:"sandbox"
(* PLAID_BASE_URL overrides the environment-derived host, so the client can be
   pointed at a local stub in tests. *)
let base_url =
  match Sys.getenv_opt "PLAID_BASE_URL" with
  | Some url -> url
  | None ->
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

(* Plaid answers failures with a well-formed JSON error object and a 4xx/5xx
   status. Parsed as success it yields empty strings for every field, which is
   indistinguishable from a real response, so all calls funnel through
   post_json and raise instead. *)
exception Plaid_error of { status : int; error_code : string; error_message : string }

let () =
  Printexc.register_printer (function
    | Plaid_error { status; error_code; error_message } ->
      Some (Printf.sprintf "Plaid API error (HTTP %d) %s: %s"
              status error_code error_message)
    | _ -> None)

let credentials =
  [ ("client_id", `String client_id); ("secret", `String secret) ]

let post_json path fields =
  let uri = Uri.of_string (base_url ^ path) in
  let body = Cohttp_lwt.Body.of_string (to_string (`Assoc (credentials @ fields))) in
  Cohttp_lwt_unix.Client.post ~headers:default_headers ~body uri
  >>= fun (resp, body) ->
  let status = Cohttp.Code.code_of_status (Cohttp.Response.status resp) in
  Cohttp_lwt.Body.to_string body >>= fun body_str ->
  let json = try from_string body_str with _ -> `Null in
  if status >= 200 && status < 300 then Lwt.return json
  else
    let field key =
      match json with
      | `Assoc fields ->
        (match List.assoc_opt key fields with Some (`String s) -> s | _ -> "")
      | _ -> ""
    in
    Lwt.fail
      (Plaid_error
         { status
         ; error_code = field "error_code"
         ; error_message = field "error_message"
         })

let create_link_token ?(hosted_link = false) ?webhook () =
  let base_fields = [
    ("client_name", `String "Budget Backend");
    ("language", `String "en");
    ("country_codes", `List [`String "US"]);
    ("products", `List [`String "transactions"]);
    ("user", `Assoc [("client_user_id", `String "user-1")]);
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
  post_json "/link/token/create" fields_with_hosted_link

let exchange_public_token public_token =
  post_json "/item/public_token/exchange"
    [ ("public_token", `String public_token) ]
  >|= fun json ->
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
  post_json "/transactions/get"
    [ ("access_token", `String access_token)
    ; ("start_date", `String start_date)
    ; ("end_date", `String end_date)
    ]

let get_link_token_results link_token =
  post_json "/link/token/get" [ ("link_token", `String link_token) ]

let get_webhook_verification_key ?key_id () =
  let fields =
    match key_id with
    | Some id -> [ ("key_id", `String id) ]
    | None -> []
  in
  post_json "/webhook_verification_key/get" fields

let get_accounts access_token =
  post_json "/accounts/get" [ ("access_token", `String access_token) ]
