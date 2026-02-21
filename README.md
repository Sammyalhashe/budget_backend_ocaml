# Budget Backend (OCaml)

This backend service handles user data, budgeting logic, and persistent bank connections via the Plaid API.

## Architecture

- **Web Framework**: [Dream](https://aantron.github.io/dream/) for HTTP routing, middleware, and request handling.
- **Data Serialization**: [Yojson](https://github.com/ocaml-community/yojson) for JSON encoding/decoding.
- **HTTP Client**: [Cohttp](https://github.com/mirage/ocaml-cohttp) for making requests to the Plaid API.
- **Asynchronous I/O**: [Lwt](https://ocsigen.org/lwt/) for non-blocking operations.

## Plaid Integration Plan

1.  **Environment Setup**: Securely store `PLAID_CLIENT_ID`, `PLAID_SECRET`, and `PLAID_ENV` (sandbox/development/production).
2.  **Link Token Creation**: Implement an endpoint `/api/plaid/create_link_token` that requests a temporary link token from Plaid for the client app to initialize Link.
3.  **Public Token Exchange**: Implement `/api/plaid/exchange_public_token` to receive a `public_token` from the client after successful Link flow and exchange it for a permanent `access_token`.
4.  **Data Fetching**: Use the `access_token` to fetch transaction data, balances, and account details.
5.  **Webhooks**: Set up a webhook receiver to handle updates from Plaid (e.g., new transactions available).

## Building & Running

Ensure you have OCaml and Dune installed.

```bash
dune build
dune exec ./bin/main.exe
```
