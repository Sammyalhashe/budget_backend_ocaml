# Webhooks in Budget Backend

## What is a Webhook?
A webhook is an HTTP callback: an HTTP POST that occurs when something happens. In this project, Plaid "calls" your backend to notify it of events so you don't have to constantly poll their API.

## How they work in this project

### 1. The Entry Point
Two routes share one handler (`src/main.ml`):

- `POST /api/plaid/webhook` — the original path.
- `POST /plaid` — the path the Cloudflare tunnel forwards to.

The tunnel publishes `webhook.salh.xyz/^/plaid/?$` and forwards to the origin without rewriting the path, so Plaid posting to `https://webhook.salh.xyz/plaid` arrives as `POST /plaid`. `PLAID_WEBHOOK_URL` must be that public HTTPS URL — never the origin's IP, which Plaid cannot reach.

### 2. Verification
**Not implemented.** `verify_webhook_signature` in `lib/plaid_webhook.ml` unconditionally returns `true`; the `Plaid-Verification` JWT is never checked. Both routes accept any POST from anyone. This is a known gap, not a subtlety of the design.

### 3. What is actually handled
`process_webhook_event` in `lib/plaid_webhook.ml` handles exactly two cases. Everything else, including all `TRANSACTIONS` webhooks, falls through a catch-all and does nothing.

- **`LINK` / `SESSION_FINISHED` or `ITEM_ADD_RESULT`** — exchanges the public token(s) and saves them, but only if the event carries at least one public token *and* its `status` is not something other than `SUCCESS`. Otherwise the session is marked `error` and an `Auth_error` is broadcast.
- **`ITEM` / `ERROR`** — marks the token errored, but only when `error_code` is `ITEM_LOGIN_REQUIRED`. Other item errors are dropped.

## The authentication flow

`POST /api/plaid/start-auth` creates a hosted-link token and a `pending` row in `link_sessions`. The user completes Plaid Link in a browser. Completion then reaches the backend by one of two paths, whichever arrives first:

1. **Webhook (fast path)** — Plaid posts to the tunnel, `process_webhook_event` exchanges the token.
2. **Polling (fallback)** — after 30 seconds without a webhook, `wait-auth` (`src/main.ml`) starts polling Plaid's `/link/token/get` itself, up to a 300-second cap.

Both paths exchange the public token, so they are arbitrated by `Db.claim_exchange`: whoever claims the session first proceeds, the loser becomes a no-op.

This is why the abandoned-session guard matters. If a `SESSION_FINISHED` with no tokens were allowed to claim the session, an abandoned Link attempt would take the claim, mark the session `connected` with no token stored, and permanently lock out the polling fallback. Rejecting those events keeps the fallback available.

## Real-time TUI Integration

The TUI isn't a public web server, so it can't receive webhooks. Two mechanisms exist:

- **`GET /api/plaid/wait-auth`** — the long-poll the TUI currently uses. It blocks until the session reaches `connected`, and carries the polling fallback described above.
- **`GET /api/plaid/ws`** — a WebSocket that broadcasts `Plaid_event` values as the backend processes webhooks. Wired up on the server, but the TUI does not currently subscribe to it.

## Testing Webhooks Locally

Post directly to the running server — no tunnel needed:

```bash
# Mock an error webhook
curl -X POST http://localhost:5000/api/plaid/webhook \
  -H 'Content-Type: application/json' \
  -d '{"webhook_type":"ITEM","webhook_code":"ERROR","item_id":"your_item_id","error":{"error_code":"ITEM_LOGIN_REQUIRED"}}'
```

To exercise the real delivery path, the server must be reachable at whatever origin the tunnel points to, and `PORT` must match it.
