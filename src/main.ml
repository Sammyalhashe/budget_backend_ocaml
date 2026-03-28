open Lwt
open Dream

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

let noop_logger inner_handler req =
  inner_handler req >>= fun resp ->
  Lwt.return resp

let () =
  Dream.run
  @@ noop_logger
  @@ Dream.router
       [ Dream.get "/" (fun _ -> Dream.html "Budget Backend is running!")
       ; Dream.post "/api/plaid/create_link_token" (fun _ ->
           let open Lwt.Infix in
           Plaid_handler.create_link_token ()
           >>= fun json ->
           Lwt.return (Dream.json (Yojson.Safe.to_string json)))
       ; Dream.post "/api/plaid/exchange_public_token" (fun request ->
           let open Lwt.Infix in
           Dream.body_json request
           >>= fun payload ->
           let open Yojson.Safe.Util in
           let public_token = payload |> member "public_token" |> to_string in
           let session_id = payload |> member "session_id" |> to_string_option |> Option.value ~default:"" in
           Plaid_handler.exchange_public_token public_token
           >>= fun json ->
           let item_id = match json with
             | `Assoc fields -> (match List.assoc_opt "item_id" fields with
                 | Some (`String id) -> id
                 | _ -> "")
             | _ -> ""
           in
           let access_token = match json with
             | `Assoc fields -> (match List.assoc_opt "access_token" fields with
                 | Some (`String token) -> token
                 | _ -> "")
             | _ -> ""
           in
           Session_store.create_session item_id access_token;
           Lwt.return (Dream.json (Yojson.Safe.to_string json)))
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
           Lwt.return (Dream.json (Yojson.Safe.to_string json)))
       
       (* New endpoints for hosted link *)
       ; Dream.post "/api/plaid/start-auth" (fun _req ->
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
           (* Save link session *)
           Session_store.save_link_session link_token (Some hosted_link_url);
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
           Dream.json (Yojson.Safe.to_string response))
       
       ; Dream.get "/api/plaid/status" (fun _req ->
           match Session_store.get_current_status () with
           | Some (link_token, hosted_link_url, status) ->
               let response = `Assoc [
                 ("status", `String status);
                 ("link_token", `String link_token);
                 ("hosted_link_url", match hosted_link_url with Some u -> `String u | None -> `Null);
               ] in
               Dream.json (Yojson.Safe.to_string response)
           | None ->
               let response = `Assoc [("status", `String "disconnected")] in
               Dream.json (Yojson.Safe.to_string response))
       
       ; Dream.get "/api/plaid/accounts" (fun _req ->
           match Session_store.get_current_status () with
           | Some (_, _, "connected") ->
               (* We need access token; for simplicity, return placeholder *)
               let response = `Assoc [("message", `String "Accounts endpoint - implement with access token")] in
               Dream.json (Yojson.Safe.to_string response)
           | _ ->
               Dream.respond ~status:`Not_Found "Not connected")
       
       ; Dream.post "/api/plaid/webhook" (fun req ->
           Dream.body req >>= fun body_str ->
           let headers = Dream.headers req in
           Plaid_webhook.handle_webhook ~body:body_str ~headers >>= fun result ->
           match result with
           | Ok event ->
               let response = `Assoc [
                 ("webhook_type", `String event.Plaud_webhook.webhook_type);
                 ("webhook_code", `String event.Plaud_webhook.webhook_code);
                 ("status", `String "processed");
               ] in
               Dream.json (Yojson.Safe.to_string response)
           | Error err ->
               Dream.respond ~status:`Bad_Request ("Webhook error: " ^ err))
       
       ; Dream.get "/api/plaid/wait-auth" (fun _req ->
           let timeout = 300.0 in  (* 5 minutes *)
           let start_time = Unix.gettimeofday () in
           let rec poll () =
             match Session_store.get_current_status () with
             | Some (_, _, "connected") ->
                 let response = `Assoc [("status", `String "connected")] in
                 Dream.json (Yojson.Safe.to_string response)
             | Some (link_token, _, "pending") ->
                 let current_time = Unix.gettimeofday () in
                 if current_time -. start_time > timeout then
                   Dream.respond ~status:`Request_Timeout "Auth timeout"
                 else
                   (* Check if link token has results via Plaid API *)
                   Plaid.get_link_token_results link_token >>= fun body ->
                   let json = Yojson.Safe.from_string body in
                   let `Assoc fields = json in
                   (match List.assoc_opt "results" fields with
                    | Some (`Assoc result_fields) ->
                        (match List.assoc_opt "item_add_results" result_fields with
                         | Some (`List (_::_)) -> 
                             (* Has results, auth completed *)
                             Session_store.update_link_session_status link_token "connected";
                             let response = `Assoc [("status", `String "connected")] in
                             Dream.json (Yojson.Safe.to_string response)
                         | _ ->
                             (* Still waiting *)
                             let%lwt () = Lwt_unix.sleep 2.0 in
                             poll ())
                    | _ ->
                        let%lwt () = Lwt_unix.sleep 2.0 in
                        poll ())
             | _ ->
                 let%lwt () = Lwt_unix.sleep 2.0 in
                 poll ()
           in
           poll ())
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