# AGENTS.md - Budget Backend OCaml

## Build & Run Commands

All commands must be run inside the nix development shell:

```bash
# Enter dev shell
nix develop

# Build entire project
dune build

# Run the server
dune exec ./src/main.exe

# Clean build artifacts
dune clean

# Check for compilation errors without building
dune build @check

# Run formatter (if ocamlformat enabled)
dune build @fmt
```

**No formal test framework is configured.** `test.ml` is a placeholder. To add tests, use `alcotest` or `ounit2` and add a `(test ...)` stanza to a dune file.

## Project Structure

- `lib/` - Library (`budget_backend_lib`): all business logic modules
- `src/` - Executable (`budget_backend`): Dream web server entry point
- `bin/` - Legacy executable (do not modify; unused)
- `flake.nix` - Nix dev environment with all OCaml dependencies
- `dune-project` - Top-level dune config (lang dune 3.11)

## Key Dependencies

- **Dream** - Web framework (routing, middleware, HTTP)
- **Yojson** - JSON serialization (use `Yojson.Safe`, `Yojson.Safe.Util`)
- **Cohttp** - HTTP client for Plaid API calls
- **Lwt** - Async I/O (use `Lwt.Infix` for `>>=`, `>=>`)
- **Caqti** - Database access (SQLite via `caqti-driver-sqlite3`)
- **Jose** - JWT verification (for webhook signatures)

## Code Style

### Formatting

- Configured via `.ocamlformat` (profile: conventional, margin: 80)
- Run `dune build @fmt` to auto-format
- `max-indent = 2`, `let-binding-spacing = compact`

### Imports

- Place `open` statements at top of file
- Common pattern: `open Lwt.Infix` for monadic operators
- Use `open Yojson.Safe.Util` locally when accessing JSON fields
- Avoid unnecessary opens (compiler warning 33 is enabled)

### Naming

- Modules: `snake_case.ml` (e.g., `plaid_event.ml` -> `Plaid_event`)
- Types: `snake_case` for record fields, `Capitalized` for variant constructors
- Functions: `snake_case`
- Constants: `snake_case`

### Async Patterns

```ocaml
(* Preferred: use >>= and >|= from Lwt.Infix *)
open Lwt.Infix
Cohttp_lwt_unix.Client.post uri >>= fun (_resp, body) ->
Cohttp_lwt.Body.to_string body >|= from_string

(* Also valid: let%lwt for complex flows *)
let%lwt result = some_lwt_call () in
process result
```

### Error Handling

- Use `Result.t` for recoverable errors: `(Ok x, Error err)`
- Use `Lwt.fail_with` for unrecoverable errors (wraps in exception)
- Caqti errors: unwrap with pattern matching, not `or_fail` (type issues in 2.x)
- JSON access: use `Yojson.Safe.Util` functions (`member`, `to_string`, `to_assoc`)
- Avoid `let \`Assoc fields = json` (narrows variant type); use `to_assoc` instead

### JSON Constructions

```ocaml
(* Build JSON responses with Yojson constructors *)
let response = `Assoc [
  ("status", `String "ok");
  ("data", `List [`String "item"]);
  ("optional", match x with Some v -> `String v | None -> `Null);
] in
Dream.json (Yojson.Safe.to_string response)
```

### Database Queries (Caqti 2.x)

```ocaml
(* Use Caqti_request.Infix operators: ->. ->! ->? ->* *)
open Caqti_request.Infix
let query = Caqti_type.(unit ->* (t3 string string string))
  "SELECT a, b, c FROM table" in
Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
  Conn.collect_list query ()
) pool >>= unwrap
```

### Record Types

```ocaml
type event = {
  event_type : string;
  item_id : string;
  error : string option;
}

(* Update with record-with syntax *)
let updated = { event with error = Some "msg" }
```

## Environment Variables

- `PLAID_CLIENT_ID` - Plaid API client ID
- `PLAID_SECRET` - Plaid API secret
- `PLAID_ENV` - sandbox/development/production
- `PLAID_WEBHOOK_URL` - Optional webhook endpoint

## Warnings & Flags

- Executable suppresses warning 49 (missing cmx) via `(flags (:standard -w -49))`
- Warning 33 (unused-open) is enabled - remove unused opens
- Warning 27 (unused-var-strict) is enabled - prefix unused vars with `_`

## Common Pitfalls

1. **Caqti 2.x removed `Caqti_request.exec`** - use `Caqti_type.(unit ->. unit)` with infix operators
2. **`Caqti_lwt_unix.Pool.use` returns `result Lwt.t`** - unwrap with `>>= function Ok x -> ... | Error e -> ...`
3. **Yojson pattern matching narrows types** - use `Yojson.Safe.Util.to_assoc` instead of `let \`Assoc fields = json`
4. **`open Lwt_result.Infix` can conflict** with `Lwt.Infix` - prefer one or use inline matching
5. **Database pool is created at module level** - do not recreate per request
