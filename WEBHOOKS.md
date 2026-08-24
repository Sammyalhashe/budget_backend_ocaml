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

Plaid signs every webhook with an ES256 JWT in the `Plaid-Verification` header. The JWT's `request_body_sha256` claim covers the exact bytes of the request body, so a valid signature proves both origin and integrity. Verification is split in two:

- **`lib/plaid_jwt.ml`** does the checking and performs no I/O — the caller supplies the key and the current time. It rejects any algorithm but ES256 *before* examining the signature, verifies the signature against the key, compares SHA-256 of the raw body against `request_body_sha256` in constant time, and rejects tokens whose `iat` is more than 300 seconds old.
- **`lib/plaid_webhook.ml`** supplies the keys and the policy. Keys come from Plaid's `/webhook_verification_key/get`, cached per `kid` behind a mutex, and a key with a non-null `expired_at` is refused.

The algorithm check is not a formality. Trusting the token's own `alg` is the standard JWT forgery: `none` asks the server to skip verification, and `HS256` asks it to treat the public key — which anyone can fetch from Plaid — as an HMAC secret.

Verification is **on by default**. Set `PLAID_WEBHOOK_VERIFY=false` to accept unverified webhooks; the server prints a warning at startup when you do. A rejected webhook gets a 400 whose body names the reason.

Note that verification depends on hashing the body exactly as received. `handle_webhook` is given the raw string for this reason — re-serialised JSON will not produce the same hash.

### 3. What is actually handled
`process_webhook_event` in `lib/plaid_webhook.ml` handles exactly two cases. Everything else, including all `TRANSACTIONS` webhooks, falls through a catch-all and does nothing.

- **`LINK` / `SESSION_FINISHED` or `ITEM_ADD_RESULT`** — exchanges the public token(s) and saves them, via `Auth_flow.exchange`. It only proceeds if the event carries at least one public token and its `status`, when present, is `SUCCESS`. Otherwise the session is marked `error` and an `Auth_error` is broadcast.
- **`ITEM` / `ERROR`** — marks the token errored, but only when `error_code` is `ITEM_LOGIN_REQUIRED`. Other item errors are dropped.

## The authentication flow

`POST /api/plaid/start-auth` creates a hosted-link token and a `pending` row in `link_sessions`. The user completes Plaid Link in a browser. Completion then reaches the backend by one of two paths, whichever arrives first:

1. **Webhook (fast path)** — Plaid posts to the tunnel, `process_webhook_event` exchanges the token.
2. **Polling (fallback)** — after 30 seconds without a webhook, `wait-auth` (`src/main.ml`) starts polling Plaid's `/link/token/get` itself, up to a 300-second cap.

Both paths exchange the public token, so they are arbitrated by `Db.claim_exchange`: whoever claims the session first proceeds, the loser becomes a no-op. That claim is a single conditional `UPDATE` rather than a read followed by a write, so two concurrent callers cannot both win it. A link token with no matching row claims nothing, which also means a forged webhook naming an unknown session cannot drive an exchange.

The shared sequence lives in `Auth_flow.exchange`, used by both paths. A failed exchange releases the claim, so a crash mid-exchange does not leave the session permanently stuck as `claimed`.

This is why the abandoned-session guard matters. If a `SESSION_FINISHED` with no tokens were allowed to claim the session, an abandoned Link attempt would take the claim, mark the session `connected` with no token stored, and permanently lock out the polling fallback. Rejecting those events keeps the fallback available.

## Real-time TUI Integration

The TUI isn't a public web server, so it can't receive webhooks. Two mechanisms exist:

- **`GET /api/plaid/wait-auth`** — the long-poll the TUI currently uses. It blocks until the session reaches `connected`, and carries the polling fallback described above.
- **`GET /api/plaid/ws`** — a WebSocket that broadcasts `Plaid_event` values as the backend processes webhooks. Wired up on the server, but the TUI does not currently subscribe to it.

## Testing Webhooks Locally

A hand-written webhook has no valid signature, so it is rejected unless you start the server with verification off:

```bash
PLAID_WEBHOOK_VERIFY=false dune exec src/main.exe
```

Then post directly to the running server — no tunnel needed:

```bash
# Mock an error webhook
curl -X POST http://localhost:5000/api/plaid/webhook \
  -H 'Content-Type: application/json' \
  -d '{"webhook_type":"ITEM","webhook_code":"ERROR","item_id":"your_item_id","error":{"error_code":"ITEM_LOGIN_REQUIRED"}}'
```

Against a server with verification on, that same request returns `400 rejected: no Plaid-Verification header`.

The verification logic itself is covered by `test/test_jwt.ml`, which signs real ES256 tokens and checks the forgery cases (wrong key, altered body, `alg: none`, HS256 with the public key as secret, and replay). Run it with `dune test` — that needs no server and no credentials.

To exercise the real delivery path, the server must be reachable at whatever origin the tunnel points to, and `PORT` must match it.
