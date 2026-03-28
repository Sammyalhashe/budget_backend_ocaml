(* Simple OCaml Dream server entry point with Plaid integration *)

open Lwt.Infix

let open_url url =
  let cmd = 
    match Sys.os_type with
    | "Unix" -> "xdg-open " ^ url
    | "Win32" -> "start " ^ url
    | "Cygwin" -> "cygstart " ^ url
    | _ -> "open " ^ url  (* macOS and others *)
  in
  let _ = Sys.command cmd in
  ()

let () =
  let _ = Lwt_main.run (Db.init ()) in
  Dream.run
  @@ Dream.logger
  @@ Dream.router [
    Dream.get "/" (fun _ ->
      Dream.html "Hello World!");

    Dream.get "/link" (fun _ ->
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
        .then(token => {
          let handler = Plaid.create({
            token: token,
            onSuccess: function(public_token, metadata) {
              fetch('/api/plaid/exchange_public_token', {
                method: 'POST',
                headers: { 'Content-Type': 'application/json' },
                body: JSON.stringify({ public_token: public_token })
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
      Dream.html html);

    (* Create a Plaid link token *)
    Dream.post "/api/plaid/create_link_token" (fun _req ->
      Plaid.create_link_token () >>= fun json ->
      Dream.json (Yojson.Safe.to_string json));

    (* Exchange a public token for an access token *)
    Dream.post "/api/plaid/exchange_public_token" (fun req ->
      Dream.body req >>= fun body_str ->
      match Yojson.Safe.from_string body_str with
      | `Assoc fields ->
        (match (List.assoc_opt "public_token" fields,
                List.assoc_opt "session_id" fields) with
         | (Some (`String token), Some (`String session_id)) ->
           Plaid.exchange_public_token token >>= fun (json, item_id, access_token) ->
           Db.save_token item_id access_token (Some session_id) >>= fun () ->
           Dream.json (Yojson.Safe.to_string json)
         | _ ->
           Dream.respond ~status:`Bad_Request "Missing public_token or session_id")
      | _ ->
        Dream.respond ~status:`Bad_Request "Invalid JSON");

    (* Get transactions *)
    Dream.post "/api/plaid/transactions" (fun req ->
      Dream.body req >>= fun body_str ->
      match Yojson.Safe.from_string body_str with
      | `Assoc fields ->
        (match (List.assoc_opt "access_token" fields,
               List.assoc_opt "start_date" fields,
               List.assoc_opt "end_date" fields) with
         | (Some (`String access_token),
            Some (`String start_date),
            Some (`String end_date)) ->
           Plaid.get_transactions access_token start_date end_date >>= fun body ->
           Dream.json body
         | _ ->
           Dream.respond ~status:`Bad_Request "Missing required fields: access_token, start_date, end_date")
      | _ ->
        Dream.respond ~status:`Bad_Request "Invalid JSON");

    (* WebSocket endpoint for real-time Plaid event notifications *)
    Dream.post "/api/plaid/ws" (fun req ->
      Dream.websocket req >>= fun (reader, writer) ->
      let session_id = Session_store.generate_session_id () in
      Session_store.create_session "" "" >>= fun () ->
      Plaid_notifier.add_subscriber (fun event ->
        let json = Yojson.Safe.to_string (Plaid_event.to_json event) in
        Lwt.catch (fun () -> Dream.websocket_send writer (`Text json) >>= fun () -> Lwt.return_unit)
          (fun _ -> Lwt.return_unit)
      );
      let rec loop () =
        Dream.websocket_receive reader >>= function
        | `Text msg ->
          (* Optional: handle client messages, e.g., heartbeat *)
          loop ()
        | `Close ->
          Plaid_notifier.remove_subscriber (fun _ -> Lwt.return_unit);
          Lwt.return_unit
        | _ -> loop ()
      in
      loop ()
    );

    (* Start Plaid authentication with hosted link *)
    Dream.post "/api/plaid/start-auth" (fun _req ->
      let webhook = Plaid.webhook_url in
      Plaid.create_link_token ~hosted_link:true ?webhook () >>= fun json ->
      let `Assoc fields = json in
      let link_token = match List.assoc_opt "link_token" fields with
        | Some (`String token) -> token
        | _ -> ""
      in
      let hosted_link_url = match List.assoc_opt "hosted_link_url" fields with
        | Some (`String url) -> url
        | _ -> ""
      in
      (* Save link session to database *)
      Db.save_link_session link_token (Some hosted_link_url) >>= fun () ->
      (* Auto-open browser *)
      if hosted_link_url <> "" then (
        open_url hosted_link_url;
      );
      (* Return response with fallback URL *)
      let response = `Assoc [
        ("link_token", `String link_token);
        ("hosted_link_url", `String hosted_link_url);
        ("open_command", `String (match Sys.os_type with
          | "Unix" -> "xdg-open " ^ hosted_link_url
          | "Win32" -> "start " ^ hosted_link_url
          | "Cygwin" -> "cygstart " ^ hosted_link_url
          | _ -> "open " ^ hosted_link_url));
      ] in
      Dream.json (Yojson.Safe.to_string response));

    (* Get current Plaid connection status *)
    Dream.get "/api/plaid/status" (fun _req ->
      Db.get_current_status () >>= fun result ->
      let response = match result with
        | Some (item_id, access_token, link_token, status, updated_at) ->
            (match status with
             | "connected" when access_token <> None ->
                 (* Get account info *)
                 (match access_token with
                  | Some token ->
                      Plaid.get_accounts token >>= fun body ->
                      let json = Yojson.Safe.from_string body in
                      let `Assoc fields = json in
                      let accounts = match List.assoc_opt "accounts" fields with
                        | Some accounts -> accounts
                        | None -> `List []
                      in
                      let response = `Assoc [
                        ("status", `String "connected");
                        ("item_id", `String item_id);
                        ("accounts", accounts);
                        ("updated_at", `String updated_at);
                      ] in
                      Dream.json (Yojson.Safe.to_string response)
                  | None -> 
                      let response = `Assoc [("status", `String status)] in
                      Dream.json (Yojson.Safe.to_string response))
             | _ ->
                 let response = `Assoc [
                   ("status", `String status);
                   ("link_token", match link_token with Some t -> `String t | None -> `Null);
                   ("updated_at", `String updated_at);
                 ] in
                 Dream.json (Yojson.Safe.to_string response))
        | None ->
            let response = `Assoc [("status", `String "disconnected")] in
            Dream.json (Yojson.Safe.to_string response));

    (* Get accounts if connected *)
    Dream.get "/api/plaid/accounts" (fun _req ->
      Db.get_current_status () >>= fun result ->
      match result with
      | Some (item_id, access_token, _, status, _) when status = "connected" ->
          (match access_token with
           | Some token ->
               Plaid.get_accounts token >>= fun body ->
               Dream.json body
           | None ->
               Dream.respond ~status:`Not_Found "No access token")
      | _ ->
          Dream.respond ~status:`Not_Found "Not connected");

    (* Webhook receiver for Plaid events *)
    Dream.post "/api/plaid/webhook" (fun req ->
      Dream.body req >>= fun body_str ->
      let headers = Dream.headers req in
      Plaid_webhook.handle_webhook ~body:body_str ~headers >>= fun result ->
      match result with
      | Ok event ->
          let response = `Assoc [
            ("webhook_type", `String event.Plaid_webhook.webhook_type);
            ("webhook_code", `String event.Plaid_webhook.webhook_code);
            ("status", `String "processed");
          ] in
          Dream.json (Yojson.Safe.to_string response)
      | Error err ->
          Dream.respond ~status:`Bad_Request ("Webhook error: " ^ err));

    (* Long polling endpoint for auth completion *)
    Dream.get "/api/plaid/wait-auth" (fun _req ->
      let timeout = 300.0 in  (* 5 minutes *)
      let start_time = Unix.gettimeofday () in
      let rec poll () =
        Db.get_current_status () >>= fun result ->
        let current_time = Unix.gettimeofday () in
        if current_time -. start_time > timeout then
          Dream.respond ~status:`Request_Timeout "Auth timeout"
        else
          match result with
          | Some (_, _, _, "connected", _) ->
              let response = `Assoc [("status", `String "connected")] in
              Dream.json (Yojson.Safe.to_string response)
          | Some (_, _, link_token, "pending", _) ->
              (match link_token with
               | Some token ->
                   (* Check if link token is still valid by calling Plaid API *)
                   Plaid.get_link_token_results token >>= fun body ->
                   let json = Yojson.Safe.from_string body in
                   let `Assoc fields = json in
                   (match List.assoc_opt "results" fields with
                    | Some (`Assoc result_fields) ->
                        (match List.assoc_opt "item_add_results" result_fields with
                         | Some (`List (_::_)) -> 
                             (* Has results, auth completed *)
                             Db.update_link_session_status token "completed" >>= fun () ->
                             let response = `Assoc [("status", `String "connected")] in
                             Dream.json (Yojson.Safe.to_string response)
                         | _ ->
                             (* Still waiting *)
                             let%lwt () = Lwt_unix.sleep 2.0 in
                             poll ())
                    | _ ->
                        let%lwt () = Lwt_unix.sleep 2.0 in
                        poll ())
               | None ->
                   let%lwt () = Lwt_unix.sleep 2.0 in
                   poll ())
          | _ ->
              let%lwt () = Lwt_unix.sleep 2.0 in
              poll ()
      in
      poll ())
  ]
