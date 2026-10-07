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

(* Shared by GET /api/plaid/status and the snapshot the event stream opens
   with, so a front-end that connects late is not left guessing. The access
   token is left out of both: the backend makes the Plaid calls itself. *)
let status_json = function
  | Db.Connected { item_id; updated_at; _ } ->
    `Assoc
      [ ("status", `String "connected")
      ; ("item_id", `String item_id)
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

(* Server-sent events: one frame is "event: <name>", "data: <json>", blank
   line. The TUI reads this with a plain HTTP client, which a WebSocket would
   have required a second protocol implementation for. *)
let sse_frame ~event json =
  Printf.sprintf "event: %s\ndata: %s\n\n" event (Yojson.Safe.to_string json)

let sse_heartbeat_seconds = 15.0

(* Matches the wait-auth timeout, past which no session is still pending. *)
let sse_lifetime_seconds = 300.0

(* The comment frame keeps intermediaries from timing an idle connection out.
   It does not detect a peer that hung up: Dream's writes keep succeeding
   after a disconnect, so every stream ends at [sse_lifetime_seconds] instead,
   and a client that still wants events reconnects. "Connection: close" makes
   that end release the socket too, rather than leave it idling for a next
   request from a client that is gone.

   A Dream stream takes one pending write at a time; a second one overwrites
   the first, which then never resolves. Events and pings are therefore
   queued and written by a single loop. Subscribing before the snapshot is
   read means an event raised in between is queued rather than lost. *)
let event_stream_handler _req =
  Dream.stream
    ~headers:
      [ ("Content-Type", "text/event-stream")
      ; ("Cache-Control", "no-cache")
      ; ("Connection", "close")
      ]
    (fun stream ->
      let write chunk =
        Dream.write stream chunk >>= fun () -> Dream.flush stream
      in
      let queue, push = Lwt_stream.create () in
      Plaid_notifier.subscribe (fun event ->
        push (Some (sse_frame ~event:"plaid" (Plaid_event.to_json event)));
        Lwt.return_unit)
      >>= fun subscription ->
      let rec heartbeat () =
        Lwt_unix.sleep sse_heartbeat_seconds >>= fun () ->
        push (Some ": ping\n\n");
        heartbeat ()
      in
      let heartbeat = heartbeat () in
      let lifetime =
        Lwt_unix.sleep sse_lifetime_seconds >|= fun () -> push None
      in
      (* Returning lets Dream.stream close the response. *)
      Lwt.finalize
        (fun () ->
          Lwt.catch
            (fun () ->
              Db.get_current_status () >>= fun status ->
              write (sse_frame ~event:"status" (status_json status))
              >>= fun () -> Lwt_stream.iter_s write queue)
            (fun _ -> Lwt.return_unit))
        (fun () ->
          Lwt.cancel heartbeat;
          Lwt.cancel lifetime;
          Plaid_notifier.unsubscribe subscription))

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
           >>= fun (_, item_id, access_token) ->
           Db.save_token item_id access_token (Some session_id)
           >>= fun () ->
           (* Plaid's reply carries the access token, which stays here. *)
           Dream.json
             (Yojson.Safe.to_string (`Assoc [ ("item_id", `String item_id) ])))
       ; Dream.post "/api/plaid/cleanup" (fun _req ->
           Db.delete_errored_tokens () >>= fun () ->
           Dream.json (Yojson.Safe.to_string (`Assoc [("status", `String "success"); ("message", `String "Deleted errored tokens")])))
       ; Dream.get "/api/plaid/events" event_stream_handler
       ; Dream.get "/api/plaid/ws" (fun _req ->
           Dream.websocket (fun websocket ->
             (* The send must be allowed to fail: a subscriber that swallows
                the error of a closed socket is never dropped, and the list
                grows by one dead entry per reconnect. Sends are serialized
                because Dream keeps only one pending write per socket. *)
             let sending = Lwt_mutex.create () in
             Plaid_notifier.subscribe (fun event ->
               Lwt_mutex.with_lock sending (fun () ->
                 Dream.send websocket
                   (Yojson.Safe.to_string (Plaid_event.to_json event))))
             >>= fun subscription ->
             let rec loop () =
               Dream.receive websocket >>= function
               | Some _msg -> loop ()
               | None -> Lwt.return_unit
             in
             Lwt.finalize loop (fun () ->
               Plaid_notifier.unsubscribe subscription)))
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
           Dream.json (Yojson.Safe.to_string (status_json status)))
       ; Dream.get "/api/plaid/accounts" (fun _req ->
           Db.get_current_status () >>= function
           | Db.Connected { access_token; _ } ->
             Lwt.catch
               (fun () ->
                 Plaid.get_accounts access_token >>= fun json ->
                 Dream.json (Yojson.Safe.to_string json))
               (plaid_error_response "get_accounts")
           | _ -> Dream.respond ~status:`Not_Found "Not connected")
         (* The POST form takes an access token; this one uses the connection
            the backend already holds, which is all a front-end has. *)
       ; Dream.get "/api/plaid/transactions" (fun req ->
           let date name default =
             match Dream.query req name with
             | Some value when value <> "" -> value
             | _ -> default
           in
           let start_date = date "start_date" (get_iso_date 30) in
           let end_date = date "end_date" (get_iso_date 0) in
           Db.get_current_status () >>= function
           | Db.Connected { access_token; _ } ->
             Lwt.catch
               (fun () ->
                 Plaid.get_transactions access_token start_date end_date
                 >>= fun json -> Dream.json (Yojson.Safe.to_string json))
               (plaid_error_response "transactions")
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
             | Auth_flow.Wait_connected { item_id; _ } ->
               Dream.json
                 (Yojson.Safe.to_string
                    (`Assoc
                       [ ("status", `String "connected")
                       ; ("item_id", `String item_id)
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
