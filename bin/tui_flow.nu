# 1. Start the authentication
print "Starting authentication..."
let auth = http post http://localhost:5000/api/plaid/start-auth
let open_cmd = $auth.open_command

# Run the open command (using ^ to call external command)
print $"Opening browser: ($open_cmd)"
^$open_cmd

# 2. Wait for the user to finish in the browser
print "Waiting for authentication to complete in browser..."
http get http://localhost:5000/api/plaid/wait-auth

# 3. Get the latest connection info
print "Authentication successful! Fetching status..."
let status = http get http://localhost:5000/api/plaid/status
print $status

# 4. Fetch transactions using the new token
if $status.access_token_present {
    print "Fetching transactions for the last 2 years..."
    let transactions = { access_token: $status.access_token } | http post http://localhost:5000/api/plaid/get_transactions $in
    print $transactions
} else {
    print "Error: No access token found in status response."
}
