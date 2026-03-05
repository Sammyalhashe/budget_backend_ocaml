open Lwt
open Dream

let () =
  Dream.set_logger (`Custom (fun _ -> Lwt.return_unit))
  >>= fun () ->
  Dream.run
  @@ Dream.logger
  @@ Dream.router
       [ Dream.get "/" (fun _ -> Dream.html "Budget Backend is running!")
       ; Dream.post "/api/plaid/create_link_token" (fun _ ->
           let open Lwt.Infix in
           Plaid_handler.create_link_token ()
           >>= fun json ->
           Lwt.return (Dream.json json))
       ; Dream.post "/api/plaid/exchange_public_token" (fun request ->
           let open Lwt.Infix in
           Dream.body_json request
           >>= fun payload ->
           let open Yojson.Safe.Util in
           let public_token = payload |> member "public_token" |> to_string in
           let session_id = payload |> member "session_id" |> to_string_option |> Option.value ~default:"" in
           Plaid_handler.exchange_public_token public_token session_id
           >>= fun json ->
           Lwt.return (Dream.json json))
       ; Dream.post "/api/plaid/get_transactions" (fun request ->
           let open Lwt.Infix in
           Dream.body_json request
           >>= fun payload ->
           let open Yojson.Safe.Util in
           let access_token = payload |> member "access_token" |> to_string in
           let start_date = payload |> member "start_date" |> to_string in
           let end_date = payload |> member "end_date" |> to_string in
           Plaid_handler.get_transactions access_token start_date end_date
           >>= fun json ->
           Lwt.return (Dream.json json))
       ]
  >>= fun server ->
  Lwt.catch
    (fun () ->
      Dream.start server
      >>= fun () ->
      Lwt.return_unit)
    (fun exn ->
      Dream_logger.error "Server error" ~exn;
      Lwt.return_unit)
