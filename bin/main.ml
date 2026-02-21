(* Simple OCaml Dream server entry point with Plaid integration *)

open Lwt.Infix
open Dream

let () =
  Dream.run
  @@ Dream.logger
  @@ Dream.router [
    Dream.get "/" (fun _ ->
      Dream.html "Hello World!");

    (* Create a Plaid link token *)
    Dream.post "/api/plaid/create_link_token" (fun _req ->
      Plaid.create_link_token () >>= fun json ->
      Dream.json (Yojson.Safe.to_string json));

    (* Exchange a public token for an access token *)
    Dream.post "/api/plaid/exchange_public_token" (fun req ->
      Dream.body req >>= fun body_str ->
      match Yojson.Safe.from_string body_str with
      | `Assoc fields ->
        (match List.assoc_opt "public_token" fields with
         | Some (`String token) ->
           Plaid.exchange_public_token token >>= fun json ->
           Dream.json (Yojson.Safe.to_string json)
         | _ ->
           Dream.respond ~status:`Bad_Request "Missing public_token")
      | _ ->
        Dream.respond ~status:`Bad_Request "Invalid JSON")
  ]
