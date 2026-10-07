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

This page went through a period where `Plaid_handler.create_link_token` nested
Plaid's whole response under a `link_token` key, so `data.link_token` was an
object rather than a string and `Plaid.create` rejected it. The endpoint now
returns Plaid's response unwrapped. Note the page has not been exercised
against real Plaid credentials since that fix.

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
Returns the current state and `item_id` (if connected). The access token stays on the server.

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

## 7. End-to-End Test at Home (Tunnel + TUI)

The full path: a real Plaid Link session, delivered to a running server
through the Cloudflare Tunnel, watched live over SSE, and surfaced in the
TUI. The short version is [CHECKLIST.md](CHECKLIST.md).

### 7.1 Where does `webhook.salh.xyz` actually point?

`PLAID_WEBHOOK_URL` defaults to `https://webhook.salh.xyz/plaid`
(`devenv.nix`, `nixos-module.nix`). The tunnel publishes that hostname with
path regex `^/plaid/?$` and forwards unmodified to `POST /plaid` — only that
one path is public (see the comment above the route in `src/main.ml` and
[WEBHOOKS.md](./WEBHOOKS.md)).

The tunnel itself (`cloudflared-tunnel-picloud`, a systemd unit on the
`oldboy` host in the NixOS config) runs in **remotely-managed mode**
(`cloudflared tunnel run --token ...`). That mode keeps its ingress rules —
including which local origin `webhook.salh.xyz` forwards to — in the
Cloudflare dashboard, not in any file on disk; there's no local `config.yml`
to grep.

**Check the real origin before testing**: Zero Trust dashboard → Networks →
Tunnels → the tunnel (likely named `picloud`, matching the systemd unit and
its sops secret) → **Published application routes** → the row for
`webhook.salh.xyz`. Its **Service** field (e.g. `http://<lan-ip>:5000`) is
where Plaid's webhook actually lands. The `nixos-module.nix` service in this
repo isn't wired into any host in the NixOS config yet, so don't assume the
route points at a deployed instance of it — confirm the Service field
before you start the server.

### 7.2 Point the tunnel (or yourself) at the right place

- **Option A — run where the route already points.** Confirm the Service
  field above, then `devenv shell -- dune exec src/main.exe` on that exact
  machine and port.
- **Option B — repoint the route at your dev machine.** Edit the Service
  field for the `webhook.salh.xyz` route to `http://<laptop-lan-ip>:5000`,
  test, then change it back. The path regex still only forwards `/plaid`.
- **Option C — skip the dashboard, use a disposable tunnel.** For
  laptop-only testing:

  ```bash
  cloudflared tunnel --url http://localhost:5000
  ```

  This prints a random `https://<subdomain>.trycloudflare.com` URL and
  forwards every path unmodified. The server answers webhooks on both
  `/plaid` and `/api/plaid/webhook`, so either works:

  ```bash
  PLAID_WEBHOOK_URL=https://<subdomain>.trycloudflare.com/plaid \
    devenv shell -- dune exec src/main.exe
  ```

### 7.3 Happy path

1. **Enter the shell** from the repo root:

   ```bash
   direnv allow   # once; after that `dune` just works
   ```

   Look for `Secrets decrypted via ~/.ssh/id_ed25519`. This exports
   `PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV=sandbox`, and
   `PLAID_WEBHOOK_URL` (the default from 7.1, unless overridden per 7.2C).
   Leave `PLAID_WEBHOOK_VERIFY` unset (verification on) unless you're doing
   the no-tunnel trick in [WEBHOOKS.md](./WEBHOOKS.md). Only touch `PORT` /
   `BUDGET_BACKEND_URL` if 5000 is taken, and keep both in sync.

2. **Start the server** (terminal 1):

   ```bash
   devenv shell -- dune exec src/main.exe
   ```

3. **Verify the tunnel reaches it**, before touching the TUI:

   ```bash
   curl -i -X POST https://webhook.salh.xyz/plaid \
     -H 'Content-Type: application/json' -d '{}'
   ```

   With verification on (default), `400 rejected: no Plaid-Verification
   header` means success — the request made it through the tunnel to the
   webhook handler. A hang, connection error, or 502 means the tunnel isn't
   reaching this server; recheck 7.1/7.2.

4. **Run the TUI** (terminal 2):

   ```bash
   devenv shell -- dune exec bin/tui.exe
   ```

   Press Enter to start Link — it opens the hosted Link URL in your browser
   (press `o` if it didn't). Sign in with Plaid's sandbox credentials:
   `user_good` / `pass_good` (no MFA code is documented or needed for this
   pair — see §6).

5. **Watch it land.** Terminal 1 logs the incoming `POST /plaid`. In a third
   terminal:

   ```bash
   curl -N http://localhost:5000/api/plaid/events
   ```

   prints an initial `status` frame, then a `plaid` frame reporting the
   connection once the webhook (or the 30s polling fallback) exchanges the
   token.

6. **Confirm accounts.** The TUI redraws itself off the same event stream
   and lists each account with its masked number and balance — no manual
   refresh needed.

### 7.4 Exercise the polling fallback

Stop the tunnel (or start the server with `PLAID_WEBHOOK_URL` unset, or
pointed somewhere dead), then repeat step 4. About 30 seconds after you
finish Link in the browser, terminal 1 logs `wait-auth: webhook not
received, polling Plaid` (`lib/auth_flow.ml`: `fallback_after = 30.0`,
`timeout = 300.0`), and the TUI still lands on accounts — just slower.

There's no sandbox-webhook-fire endpoint in this codebase (checked
`src/main.ml` and `lib/plaid.ml`) — the only way to trigger a real webhook
is to complete Link, or to hand-craft one as shown in WEBHOOKS.md's *Testing
Webhooks Locally* section (needs `PLAID_WEBHOOK_VERIFY=false`).

### 7.5 Reset between runs

```bash
curl -X POST http://localhost:5000/api/plaid/cleanup   # drops only errored tokens (e.g. ITEM_LOGIN_REQUIRED)
rm budget.db                                            # full reset; recreated on next server start
```

`budget.db` resolves relative to the working directory the server was
launched from — delete the one next to wherever you ran `dune exec
src/main.exe`.

### 7.6 Troubleshooting

| Symptom | Likely cause | Fix |
| --- | --- | --- |
| Webhook never arrives; TUI always falls back to polling | Tunnel route points at the wrong origin, or `PLAID_WEBHOOK_URL` is stale | Recheck 7.1, and the curl in 7.3 step 3 — it should 400, not hang or 502 |
| `curl https://webhook.salh.xyz/plaid` hangs or 502s | Nothing is running on the host:port the tunnel's Service field names | Confirm the server is up there, and that `cloudflared-tunnel-picloud` is active on `oldboy` (`systemctl status cloudflared-tunnel-picloud`) |
| `400 rejected: ...` from a hand-built webhook | Expected: verification is on and there's no valid `Plaid-Verification` header | Use a real Plaid-delivered webhook, or set `PLAID_WEBHOOK_VERIFY=false` for manual-only testing |
| TUI stuck on the spinner for minutes | `wait-auth`'s 300s cap elapsed with no exchange | Check the server log for a Plaid error; press Enter again to restart `start-auth` |
| Port already in use | Something else already bound 5000 | `lsof -i :5000`, then kill it, or set `PORT` and matching `BUDGET_BACKEND_URL` for both server and TUI |

## 8. Production Readiness & Testing

Before moving from Sandbox to Production, ensure the following are addressed:

### 1. Webhook Verification
Implemented, and on by default — see the Verification section of
[WEBHOOKS.md](./WEBHOOKS.md). Confirm `PLAID_WEBHOOK_VERIFY` is **not** set to
`false` in production; the server warns loudly at startup if it is.

### 2. HTTPS/TLS
Plaid requires all production redirect URIs and webhooks to use HTTPS. Ensure your backend is behind a reverse proxy (like Nginx or Caddy) with a valid SSL certificate.

### 3. Access Token Security
The `access_token` is a permanent secret. In a production environment, you should encrypt these tokens before storing them in SQLite (using a library like `Nocturne` or `Cryptokit`).

### 4. Handling Update Mode
Test the "re-authentication" flow by simulating an `ITEM_LOGIN_REQUIRED` error in Sandbox. Your TUI/frontend must be able to launch Link in "Update Mode" using the existing `access_token`.

### 5. Persistent Database
While SQLite is sufficient for small TUIs, ensure your `budget.db` is backed up regularly or consider moving to a managed PostgreSQL instance if scaling to multiple users.
