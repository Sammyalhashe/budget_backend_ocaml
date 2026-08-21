# Testing Guide

## Prerequisites

- The devenv development shell (`direnv allow`, or prefix commands with
  `devenv shell --`)
- An SSH key at `~/.ssh/id_ed25519` authorized to decrypt `secrets.yaml`

## 1. Plaid Credentials

Credentials are stored in `secrets.yaml`, encrypted with sops/age, and are
decrypted **automatically on shell entry** — see `devenv.nix`. You should see
`Secrets decrypted via ~/.ssh/id_ed25519` when the shell loads. `PLAID_ENV` is
set to `sandbox` there too. No manual export is needed.

## 2. Build and Run

```bash
devenv shell -- dune build
devenv shell -- dune exec src/main.exe
```

The server starts on `http://localhost:5000` by default, and listens on
`0.0.0.0`. Set `PORT` to change it — if you do, set `BUDGET_BACKEND_URL` to
match before running the TUI.

## 3. Web-based Testing

Visit `http://localhost:5000/link` in your browser for a pre-built UI to test the Plaid Link flow end-to-end.

> **Known broken.** `Plaid_handler.create_link_token` nests Plaid's whole
> response under a `link_token` key, so the page's `data.link_token` is an
> object rather than a string and `Plaid.create` rejects it. The TUI flow via
> `/api/plaid/start-auth` is unaffected.

## 4. Manual Testing with Nushell

### Health check

```nushell
http get http://localhost:5000/
```

### Start hosted auth flow

```nushell
# Returns link_token and hosted_link_url — open the URL in your browser manually
http post http://localhost:5000/api/plaid/start-auth
```

### Wait for auth completion (long-poll)
Requires the `link_token` from `start-auth`. Waits for the webhook (first 30s) then falls back to polling Plaid directly. Returns `item_id` and `access_token` on success.

```nushell
http get http://localhost:5000/api/plaid/wait-auth?link_token=<LINK_TOKEN>
```

### Check auth status
Returns the current state, including the `access_token` (if connected) and `item_id`.

```nushell
http get http://localhost:5000/api/plaid/status
```

### Fetch transactions
Now supports defaults (last 2 years to today) if dates are omitted.

```nushell
# Default (last 2 years)
{ access_token: "<TOKEN>" } | http post http://localhost:5000/api/plaid/get_transactions

# Custom range
{
  access_token: "<TOKEN>",
  start_date: "2024-01-01",
  end_date: "2024-03-31"
} | http post http://localhost:5000/api/plaid/get_transactions
```

### Real-time events (WebSockets)
Listen for real-time notifications (like webhook events) via WebSocket.

```nushell
# Nushell doesn't have a native websocket client, but you can use 'websocat'
websocat ws://localhost:5000/api/plaid/ws
```

### Database Cleanup
Delete tokens that have entered an error state (e.g., `ITEM_LOGIN_REQUIRED`).

```nushell
http post http://localhost:5000/api/plaid/cleanup
```

## 5. Webhooks

See [WEBHOOKS.md](./WEBHOOKS.md) for detailed information on how to test and mock webhooks locally.

## 6. Plaid Sandbox Test Credentials

When using `PLAID_ENV=sandbox`:

- **Username**: `user_good`
- **Password**: `pass_good`

See [Plaid Sandbox docs](https://plaid.com/docs/sandbox/) for more test accounts.

## 7. Production Readiness & Testing

Before moving from Sandbox to Production, ensure the following are addressed:

### 1. Webhook Verification
In production, you **must** verify the JWT signature of incoming webhooks to ensure they actually come from Plaid. The current implementation in `lib/plaid_webhook.ml` contains a TODO for this.

### 2. HTTPS/TLS
Plaid requires all production redirect URIs and webhooks to use HTTPS. Ensure your backend is behind a reverse proxy (like Nginx or Caddy) with a valid SSL certificate.

### 3. Access Token Security
The `access_token` is a permanent secret. In a production environment, you should encrypt these tokens before storing them in SQLite (using a library like `Nocturne` or `Cryptokit`).

### 4. Handling Update Mode
Test the "re-authentication" flow by simulating an `ITEM_LOGIN_REQUIRED` error in Sandbox. Your TUI/frontend must be able to launch Link in "Update Mode" using the existing `access_token`.

### 5. Persistent Database
While SQLite is sufficient for small TUIs, ensure your `budget.db` is backed up regularly or consider moving to a managed PostgreSQL instance if scaling to multiple users.
