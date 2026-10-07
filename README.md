# Budget Backend (OCaml)

A Dream HTTP server that connects bank accounts through Plaid, plus a
lambda-term TUI client that drives the authentication flow from the terminal.

## Develop

`dune` is only on `PATH` inside the devenv shell. Run `direnv allow` once and
it loads automatically; otherwise prefix every command with `devenv shell --`.
To test end to end at home, follow [CHECKLIST.md](CHECKLIST.md).

```bash
direnv allow                  # once, then dune works directly
dune build                    # build everything
dune exec src/main.exe        # run the server  (terminal 1)
dune exec bin/tui.exe         # run the TUI     (terminal 2)
```

Entering the shell decrypts `secrets.yaml` with sops and exports
`PLAID_CLIENT_ID`, `PLAID_SECRET`, `PLAID_ENV=sandbox`, and
`PLAID_WEBHOOK_URL`. You need an SSH key at `~/.ssh/id_ed25519` authorized for
it; you'll see `Secrets decrypted via …` on entry if it worked.

`dune test` runs three files: `test/test_db.ml` covers the database invariants
the auth flow depends on, `test/test_jwt.ml` covers webhook signature
verification, signing real ES256 tokens to check the forgery cases, and
`test/test_notifier.ml` covers the event broadcast the front-ends wait on.
None of them needs a server or credentials. Everything else is verified by
running the server and exercising endpoints; see `TESTING.md`. To test against a fake
Plaid, point `PLAID_BASE_URL` at a local stub.

### Environment variables

| Variable | Default | Purpose |
| --- | --- | --- |
| `PORT` | `5000` | Server listen port. Binds `0.0.0.0`, not just loopback. |
| `BUDGET_BACKEND_URL` | `http://localhost:5000` | Where the TUI looks for the server. Keep in sync with `PORT`. |
| `PLAID_WEBHOOK_URL` | set by `devenv.nix` | Public HTTPS URL Plaid posts to. Without it, only the polling fallback works. |
| `PLAID_WEBHOOK_VERIFY` | on | Set to `false` to accept webhooks without checking their signature. Warns at startup. |
| `PLAID_ENV` | `sandbox` | Selects the Plaid host. |
| `PLAID_BASE_URL` | unset | Overrides the Plaid host entirely. For pointing at a local stub. |

The SQLite database is `budget.db`, resolved **relative to the working
directory** — launching from elsewhere silently creates a new empty one.

## Layout

- `lib/` — `budget_backend_lib`: Plaid client (`plaid.ml`), webhook handling
  (`plaid_webhook.ml`), persistence (`db.ml`), event broadcast
  (`plaid_notifier.ml`).
- `src/main.ml` — the server and its route table.
- `bin/` — the TUI (`tui.ml`) and its HTTP client (`backend_client.ml`). The
  TUI asks for the current status on startup, so a restart lands straight on
  the accounts of an already connected item instead of re-authenticating.

## What works today

- **Bank authentication.** `POST /api/plaid/start-auth` → hosted Link in a
  browser → access token stored. Completion arrives either by webhook or, after
  30s, by polling Plaid. See `WEBHOOKS.md`.
- **Telling the front-end it is authenticated.** Whichever path completes the
  exchange broadcasts the outcome, carrying the link token so a client can tell
  its own session apart from someone else's. Clients listen on
  `GET /api/plaid/events` (server-sent events, opening with a `status` snapshot
  of the current connection) or `GET /api/plaid/ws`; `GET
  /api/plaid/wait-auth?link_token=…` remains as a long poll. The TUI waits on
  the stream and the long poll at once, so losing either one does not strand it.
- **Reading connected accounts.** `GET /api/plaid/accounts` and `GET
  /api/plaid/transactions?start_date=…&end_date=…` use the stored access token,
  so a front-end never handles one.
- **Verified webhooks.** Plaid's ES256 signature is checked against the raw
  request body, on by default. See `WEBHOOKS.md`.

## What does not

- **Nothing is persisted but tokens.** No transaction storage, no sync cursor,
  no categorisation, no budgeting.
- **No automatic updates.** `TRANSACTIONS` webhooks are ignored.
- **One institution only.** Institutions are not modelled at all; no route
  lists linked items, and `/api/plaid/status` reports a single connection.

Further reading: `WEBHOOKS.md` (auth flow and webhook handling), `TESTING.md`
(manual endpoint exercises), `AGENTS.md` (code style and conventions).
