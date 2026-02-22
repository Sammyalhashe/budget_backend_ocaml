(* Simple OCaml Dream server entry point with Plaid integration *)

open Lwt.Infix

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
    )
  ]
```