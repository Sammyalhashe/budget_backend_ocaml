# Testing Guide

## Prerequisites

- Nix development shell (`nix develop`)
- Access to the sops age key for decrypting `secrets.yaml`

## 1. Decrypt and Export Plaid Credentials

Credentials are stored in `secrets.yaml`, encrypted with sops/age.

```bash
# Verify you can decrypt
sops -d secrets.yaml

# Export Plaid env vars
eval $(sops -d --output-type json secrets.yaml | jq -r 'to_entries[] | select(.key | test("^PLAID")) | "export \(.key)=\(.value)"')

# Set environment (sandbox for testing)
export PLAID_ENV=sandbox
```

## 2. Build and Run

```bash
dune build
dune exec ./src/main.exe
```

The server starts on `http://localhost:8080` by default.

## 3. Manual Testing with curl

### Health check

```bash
curl http://localhost:8080/
```

### Create a link token

```bash
curl -s -X POST http://localhost:8080/api/plaid/create_link_token | jq .
```

### Start hosted auth flow (opens browser)

```bash
curl -s -X POST http://localhost:8080/api/plaid/start-auth | jq .
```

This returns a `hosted_link_url` that the user visits to authenticate with their bank. The server also attempts to auto-open it in the default browser.

### Check auth status

```bash
curl -s http://localhost:8080/api/plaid/status | jq .
```

Returns `"disconnected"`, `"pending"`, or `"connected"`.

### Wait for auth completion (long-poll, 5 min timeout)

```bash
curl -s http://localhost:8080/api/plaid/wait-auth | jq .
```

Polls Plaid until the hosted link flow completes or times out.

### Exchange a public token

```bash
curl -s -X POST http://localhost:8080/api/plaid/exchange_public_token \
  -H 'Content-Type: application/json' \
  -d '{"public_token": "<TOKEN_FROM_PLAID_LINK>"}' | jq .
```

### Fetch transactions

```bash
curl -s -X POST http://localhost:8080/api/plaid/get_transactions \
  -H 'Content-Type: application/json' \
  -d '{"access_token": "<ACCESS_TOKEN>", "start_date": "2024-01-01", "end_date": "2024-12-31"}' | jq .
```

### Get accounts

```bash
curl -s http://localhost:8080/api/plaid/accounts | jq .
```

### Send a webhook (for local testing)

```bash
curl -s -X POST http://localhost:8080/api/plaid/webhook \
  -H 'Content-Type: application/json' \
  -d '{"webhook_type": "LINK", "webhook_code": "SESSION_FINISHED", "public_token": "<TOKEN>"}' | jq .
```

## 4. Typical Auth Flow (End-to-End)

1. Start the server
2. `POST /api/plaid/start-auth` — get a hosted link URL
3. Open the URL in a browser and complete bank login (use Plaid sandbox test credentials)
4. `GET /api/plaid/status` or `GET /api/plaid/wait-auth` — wait for `"connected"`
5. Use the access token to fetch transactions/accounts

## 5. Plaid Sandbox Test Credentials

When using `PLAID_ENV=sandbox`, Plaid provides test credentials for the hosted link flow:

- **Username**: `user_good`
- **Password**: `pass_good`

See [Plaid Sandbox docs](https://plaid.com/docs/sandbox/) for more test accounts and error scenarios.
