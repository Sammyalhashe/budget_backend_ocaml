open Lwt.Infix
open Budget_backend_lib

let get_iso_date days_ago =
  let now = Unix.gettimeofday () in
  let target = now -. (float_of_int days_ago *. 86400.0) in
  let tm = Unix.gmtime target in
  Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let port =
  match Sys.getenv_opt "PORT" with
  | Some p -> (match int_of_string_opt p with Some n -> n | None -> 5000)
  | None -> 5000

(* Plaid errors carry a code; anything else is genuinely unexpected. *)
let plaid_error_response context exn =
  match exn with
  | Plaid.Plaid_error { status; error_code; error_message } ->
    Dream.error (fun m ->
      m "%s: Plaid returned %d %s: %s" context status error_code error_message);
    Dream.json ~status:`Bad_Gateway
      (Yojson.Safe.to_string
         (`Assoc
            [ ("error", `String "plaid_error")
            ; ("error_code", `String error_code)
            ; ("error_message", `String error_message)
            ]))
  | exn ->
    Dream.error (fun m -> m "%s: %s" context (Printexc.to_string exn));
    Dream.respond ~status:`Internal_Server_Error "Internal error"

let plaid_webhook_handler req =
  Dream.body req >>= fun body_str ->
  let headers = Dream.all_headers req in
  Plaid_webhook.handle_webhook ~body:body_str ~headers
  >>= fun result ->
  match result with
  | Ok event ->
    let response =
      `Assoc
        [ ( "webhook_type"
          , `String event.Plaid_webhook.webhook_type )
        ; ( "webhook_code"
          , `String event.Plaid_webhook.webhook_code )
        ; ("status", `String "processed")
        ]
    in
    Dream.json (Yojson.Safe.to_string response)
  | Error err ->
    Dream.respond ~status:`Bad_Request
      ("Webhook error: " ^ err)

let () =
  let _ = Lwt_main.run (Db.init ()) in
  Dream.run ~interface:"0.0.0.0" ~port
  @@ Dream.logger
  @@ Dream.router
       [ Dream.get "/" (fun _ -> Dream.html "Budget Backend is running!")
       ; Dream.get "/link" (fun _ -> Dream.html Link_page.html)
       ; Dream.post "/api/plaid/create_link_token" (fun _ ->
           Plaid_handler.create_link_token ()
           >>= fun json ->
           Dream.json (Yojson.Safe.to_string json))
       ; Dream.post "/api/plaid/exchange_public_token" (fun request ->
           Dream.body request >>= fun body_str ->
           let payload = Yojson.Safe.from_string body_str in
           let open Yojson.Safe.Util in
           let public_token = payload |> member "public_token" |> to_string in
           let session_id =
             payload |> member "session_id" |> to_string_option
             |> Option.value ~default:"default_session"
           in
           Plaid.exchange_public_token public_token
           >>= fun (json, item_id, access_token) ->
           Db.save_token item_id access_token (Some session_id)
           >>= fun () ->
           Dream.json (Yojson.Safe.to_string json))
       ; Dream.post "/api/plaid/get_transactions" (fun request ->
           Dream.body request >>= fun body_str ->
           let payload = 
             try Yojson.Safe.from_string body_str 
             with _ -> `Assoc []
           in
           let open Yojson.Safe.Util in
           let access_token = payload |> member "access_token" |> to_string_option in
           let start_date = 
             payload |> member "start_date" |> to_string_option 
             |> Option.value ~default:(get_iso_date 730) (* 2 years ago *)
           in
           let end_date = 
             payload |> member "end_date" |> to_string_option 
             |> Option.value ~default:(get_iso_date 0) (* today *)
           in
           match access_token with
           | Some token ->
             Lwt.catch
               (fun () ->
                 Plaid_handler.get_transactions token start_date end_date
                 >>= fun json ->
                 Dream.json (Yojson.Safe.to_string json))
               (plaid_error_response "get_transactions")
           | None ->
             Dream.respond ~status:`Bad_Request "Missing access_token")
       ; Dream.post "/api/plaid/cleanup" (fun _req ->
           Db.delete_errored_tokens () >>= fun () ->
           Dream.json (Yojson.Safe.to_string (`Assoc [("status", `String "success"); ("message", `String "Deleted errored tokens")])))
       ; Dream.get "/api/plaid/ws" (fun _req ->
           Dream.websocket (fun websocket ->
             Plaid_notifier.add_subscriber (fun event ->
               let json = Yojson.Safe.to_string (Plaid_event.to_json event) in
               Lwt.catch (fun () -> Dream.send websocket json >>= fun () -> Lwt.return_unit)
                 (fun _ -> Lwt.return_unit)
             ) >>= fun () ->
             let rec loop () =
               Dream.receive websocket >>= function
               | Some _msg -> loop ()
               | None -> Lwt.return_unit
             in
             loop ()))
       ; Dream.post "/api/plaid/start-auth" (fun _req ->
           let webhook = Plaid.webhook_url in
           Plaid.create_link_token ~hosted_link:true ?webhook ()
           >>= fun json ->
           let fields = Yojson.Safe.Util.to_assoc json in
           let link_token =
             match List.assoc_opt "link_token" fields with
             | Some (`String token) -> token
             | _ -> ""
           in
           let hosted_link_url =
             match List.assoc_opt "hosted_link_url" fields with
             | Some (`String url) -> url
             | _ -> ""
           in
           Db.save_link_session ~link_token ~hosted_link_url ~status:"pending"
           >>= fun () ->
           let response =
             `Assoc
               [ ("link_token", `String link_token)
               ; ("hosted_link_url", `String hosted_link_url)
               ]
           in
           Dream.json (Yojson.Safe.to_string response))
       ; Dream.get "/api/plaid/status" (fun _req ->
           Db.get_current_status () >>= fun status ->
           let response =
             match status with
             | Db.Connected { item_id; access_token; updated_at } ->
               `Assoc
                 [ ("status", `String "connected")
                 ; ("item_id", `String item_id)
                 ; ("access_token", `String access_token)
                 ; ("access_token_present", `Bool true)
                 ; ("updated_at", `String updated_at)
                 ]
             | Db.Pending { link_token; updated_at } ->
               `Assoc
                 [ ("status", `String "pending")
                 ; ("link_token", `String link_token)
                 ; ("access_token_present", `Bool false)
                 ; ("updated_at", `String updated_at)
                 ]
             | Db.Auth_failed { link_token; updated_at } ->
               `Assoc
                 [ ("status", `String "error")
                 ; ("link_token", `String link_token)
                 ; ("access_token_present", `Bool false)
                 ; ("updated_at", `String updated_at)
                 ]
             | Db.Disconnected -> `Assoc [ ("status", `String "disconnected") ]
           in
           Dream.json (Yojson.Safe.to_string response))
       ; Dream.get "/api/plaid/accounts" (fun _req ->
           Db.get_current_status () >>= function
           | Db.Connected { access_token; _ } ->
             Lwt.catch
               (fun () ->
                 Plaid.get_accounts access_token >>= fun json ->
                 Dream.json (Yojson.Safe.to_string json))
               (plaid_error_response "get_accounts")
           | _ -> Dream.respond ~status:`Not_Found "Not connected")
       ; Dream.post "/api/plaid/webhook" plaid_webhook_handler
         (* Path exposed through the Cloudflare tunnel (webhook.salh.xyz/plaid) *)
       ; Dream.post "/plaid" plaid_webhook_handler
       ; Dream.get "/api/plaid/wait-auth" (fun req ->
           match Dream.query req "link_token" with
           | None | Some "" ->
             Dream.respond ~status:`Bad_Request "Missing link_token query parameter"
           | Some link_token ->
             let log msg = Dream.info (fun m -> m "%s" msg) in
             Auth_flow.wait_for_completion ~link_token ~log ()
             >>= (function
             | Auth_flow.Wait_connected { item_id; access_token } ->
               Dream.json
                 (Yojson.Safe.to_string
                    (`Assoc
                       [ ("status", `String "connected")
                       ; ("item_id", `String item_id)
                       ; ("access_token", `String access_token)
                       ]))
             | Auth_flow.Wait_connected_unknown_token ->
               Dream.json
                 (Yojson.Safe.to_string (`Assoc [ ("status", `String "connected") ]))
             | Auth_flow.Wait_failed msg ->
               Dream.error (fun m -> m "wait-auth failed: %s" msg);
               Dream.respond ~status:`Internal_Server_Error "Auth failed"
             | Auth_flow.Wait_timeout ->
               Dream.respond ~status:`Request_Timeout "Auth timeout"))
       ]
