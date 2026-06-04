let base_url =
  match Sys.getenv_opt "BUDGET_BACKEND_URL" with
  | Some url -> url
  | None -> "http://localhost:5000"

type auth_start = {
  link_token : string;
  hosted_link_url : string;
}

type auth_result = {
  status : string;
  item_id : string;
  access_token : string;
}

type error =
  | Connection_refused
  | Timeout
  | Http_error of int
  | Parse_error of string

let error_to_string = function
  | Connection_refused -> "Connection refused - is the backend running?"
  | Timeout -> "Timeout - auth took too long"
  | Http_error code -> Printf.sprintf "HTTP error %d" code
  | Parse_error msg -> Printf.sprintf "Parse error: %s" msg

let http_post path =
  let uri = Uri.of_string (base_url ^ path) in
  let body = Cohttp_lwt.Body.of_string "" in
  let open Lwt.Infix in
  Cohttp_lwt_unix.Client.post ~body uri >>= fun (resp, body) ->
  let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
  Cohttp_lwt.Body.to_string body >>= fun body_str ->
  Lwt.return (status, body_str)

let http_get path =
  let uri = Uri.of_string (base_url ^ path) in
  let open Lwt.Infix in
  Cohttp_lwt_unix.Client.get uri >>= fun (resp, body) ->
  let status = Cohttp.Response.status resp |> Cohttp.Code.code_of_status in
  Cohttp_lwt.Body.to_string body >>= fun body_str ->
  Lwt.return (status, body_str)

let start_auth () : (auth_start, error) result =
  try
    let (status, body) = Lwt_main.run (http_post "/api/plaid/start-auth") in
    if status <> 200 then Error (Http_error status)
    else
      let json = Yojson.Safe.from_string body in
      let open Yojson.Safe.Util in
      let link_token = json |> member "link_token" |> to_string in
      let hosted_link_url = json |> member "hosted_link_url" |> to_string in
      Ok { link_token; hosted_link_url }
  with
  | Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> Error Connection_refused
  | exn -> Error (Parse_error (Printexc.to_string exn))

let wait_auth ~link_token : (auth_result, error) result =
  try
    let path = Printf.sprintf "/api/plaid/wait-auth?link_token=%s" link_token in
    let (status, body) = Lwt_main.run (http_get path) in
    if status = 408 then Error Timeout
    else if status <> 200 then Error (Http_error status)
    else
      let json = Yojson.Safe.from_string body in
      let open Yojson.Safe.Util in
      let item_status = json |> member "status" |> to_string in
      let item_id = json |> member "item_id" |> to_string_option |> Option.value ~default:"" in
      let access_token = json |> member "access_token" |> to_string_option |> Option.value ~default:"" in
      Ok { status = item_status; item_id; access_token }
  with
  | Unix.Unix_error (Unix.ECONNREFUSED, _, _) -> Error Connection_refused
  | exn -> Error (Parse_error (Printexc.to_string exn))
