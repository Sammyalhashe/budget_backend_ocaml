(* The browser-based Plaid Link page served at /link. Kept out of the
   router so main.ml stays a readable list of routes. *)

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
|}
