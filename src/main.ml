open Lwt.Infix
open Budget_backend_lib

let get_iso_date days_ago =
  let now = Unix.gettimeofday () in
  let target = now -. (float_of_int days_ago *. 86400.0) in
  let tm = Unix.gmtime target in
  Printf.sprintf "%04d-%02d-%02d" (tm.tm_year + 1900) (tm.tm_mon + 1) tm.tm_mday

let () =
  let _ = Lwt_main.run (Db.init ()) in
  Dream.run ~port:5000
  @@ Dream.logger
  @@ Dream.router
       [ Dream.get "/" (fun _ -> Dream.html "Budget Backend is running!")
       ; Dream.get "/link" (fun _ ->
           let html = {|
<!DOCTYPE html>
<html>
<head>
  <meta charset='UTF-8'>
  <title>Plaid Link</title>
  <script src='https://cdn.plaid.com/link/v2/stable/link-initialize.js'></script>
</head>
<body>
  <h1>Plaid Link</h1>
  <button id='link-button'>Connect Bank</button>
  <div id='status'></div>

  <script>
    let button = document.getElementById('link-button');
    let status = document.getElementById('status');

    button.addEventListener('click', function() {
      fetch('/api/plaid/create_link_token', { method: 'POST' })
        .then(response => response.json())
        .then(data => {
          let token = data.link_token;
          let handler = Plaid.create({
            token: token,
            onSuccess: function(public_token, metadata) {
              fetch('/api/plaid/exchange_public_token', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ public_token: public_token, session_id: 'browser_session' })
              })
              .then(res => res.json())
              .then(data => {
                status.innerHTML = '<p style="color: green;">Success! Public token exchanged.</p>';
                console.log('Exchange response:', data);
              })
              .catch(err => {
                status.innerHTML = '<p style="color: red;">Error exchanging token: ' + err + '</p>';
                console.error('Exchange error:', err);
              });
            }
          });

          handler.open();
        })
        .catch(err => {
          status.innerHTML = '<p style="color: red;">Error creating link token: ' + err + '</p>';
          console.error('Create token error:', err);
        });
    });
  </script>
</body>
</html>
|} in
           Dream.html html)
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
               (fun exn ->
                 let err_msg = Printexc.to_string exn in
                 Dream.error (fun m -> m "Transactions error: %s" err_msg);
                 let is_reauth_required = 
                   try 
                     let _ = Str.search_forward (Str.regexp "ITEM_LOGIN_REQUIRED") err_msg 0 in
                     true
                   with Not_found -> false
                 in
                 if is_reauth_required then (
                   (* We need the item_id to mark it. This is a bit tricky here since we only have the token.
                      In a real app, you'd look up the item_id by token first.
                      For now, we'll log it. *)
                   Dream.error (fun m -> m "Item requires re-authentication");
                 );
                 Dream.respond ~status:`Internal_Server_Error "Plaid API Error")
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
           Db.save_link_session link_token link_token hosted_link_url "pending" >>= fun () ->
           let response =
             `Assoc
               [ ("link_token", `String link_token)
               ; ("hosted_link_url", `String hosted_link_url)
               ]
           in
           Dream.json (Yojson.Safe.to_string response))
       ; Dream.get "/api/plaid/status" (fun _req ->
           Db.get_current_status () >>= function
           | Some (item_id, access_token, link_token, status, updated_at) ->
             let response =
               `Assoc
                 [ ("status", `String status)
                 ; ("item_id", match item_id with Some id -> `String id | None -> `Null)
                 ; ("link_token", match link_token with Some t -> `String t | None -> `Null)
                 ; ("access_token_present", `Bool (access_token <> None))
                 ; ("access_token", match access_token with Some at -> `String at | None -> `Null)
                 ; ("updated_at", `String updated_at)
                 ]
             in
             Dream.json (Yojson.Safe.to_string response)
           | None ->
             let response =
               `Assoc [ ("status", `String "disconnected") ]
             in
             Dream.json (Yojson.Safe.to_string response))
       ; Dream.get "/api/plaid/accounts" (fun _req ->
           Db.get_current_status () >>= function
           | Some (_, Some token, _, "connected", _) ->
             Plaid.get_accounts token >>= fun json ->
             Dream.json (Yojson.Safe.to_string json)
           | _ -> Dream.respond ~status:`Not_Found "Not connected")
       ; Dream.post "/api/plaid/webhook" (fun req ->
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
               ("Webhook error: " ^ err))
       ; Dream.get "/api/plaid/wait-auth" (fun req ->
           let link_token = Dream.query req "link_token" in
           match link_token with
           | None ->
             Dream.respond ~status:`Bad_Request "Missing link_token query parameter"
           | Some lt ->
             let timeout = 300.0 in
             let fallback_threshold = 30.0 in
             let start_time = Unix.gettimeofday () in
             let rec poll () =
               let elapsed = Unix.gettimeofday () -. start_time in
               if elapsed > timeout then
                 Dream.respond ~status:`Request_Timeout "Auth timeout"
               else
                 Db.get_link_session lt >>= function
                 | Some (_, _, status, _) when status = "connected" ->
                   Db.get_token_by_session lt >>= (function
                   | Some (item_id, access_token) ->
                     let response = `Assoc
                       [ ("status", `String "connected")
                       ; ("item_id", `String item_id)
                       ; ("access_token", `String access_token)
                       ] in
                     Dream.json (Yojson.Safe.to_string response)
                   | None ->
                     let response = `Assoc [ ("status", `String "connected") ] in
                     Dream.json (Yojson.Safe.to_string response))
                 | Some (_, _, status, _) when status = "error" ->
                   Dream.respond ~status:`Internal_Server_Error "Auth failed"
                 | _ ->
                   if elapsed < fallback_threshold then
                     Lwt_unix.sleep 1.0 >>= fun () -> poll ()
                   else begin
                     Dream.info (fun m -> m "wait-auth: webhook not received, polling Plaid");
                     Plaid.get_link_token_results lt >>= fun json ->
                     let open Yojson.Safe.Util in
                     let item_add_result =
                       try
                         let sessions = json |> member "link_sessions" |> to_list in
                         List.find_map (fun s ->
                           match s |> member "results" |> member "item_add_results" |> to_list with
                           | res :: _ -> Some res
                           | [] -> None
                         ) sessions
                       with _ -> None
                     in
                     match item_add_result with
                     | Some res ->
                       let public_token = res |> member "public_token" |> to_string in
                       Db.claim_exchange lt >>= fun claimed ->
                       if not claimed then
                         Lwt_unix.sleep 1.0 >>= fun () -> poll ()
                       else begin
                         Plaid.exchange_public_token public_token >>= fun (_, item_id, access_token) ->
                         Db.save_token item_id access_token (Some lt) >>= fun () ->
                         Db.mark_exchange_done lt >>= fun () ->
                         let response = `Assoc
                           [ ("status", `String "connected")
                           ; ("item_id", `String item_id)
                           ; ("access_token", `String access_token)
                           ] in
                         Dream.json (Yojson.Safe.to_string response)
                       end
                     | None ->
                       Lwt_unix.sleep 2.0 >>= fun () -> poll ()
                   end
             in
             poll ())
       ]
