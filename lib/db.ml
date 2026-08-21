open Lwt.Infix
open Caqti_request.Infix

(* busy_timeout is read only from the URI query string. Without it SQLite's
   default of 0ms applies and the first contended write fails immediately
   instead of retrying. *)
let db_uri = Uri.of_string "sqlite3:budget.db?busy_timeout=5000"

let pool =
  match Caqti_lwt_unix.connect_pool db_uri with
  | Ok pool -> pool
  | Error err -> failwith (Caqti_error.show err)

let unwrap = function
  | Ok x -> Lwt.return x
  | Error err -> Lwt.fail_with (Caqti_error.show err)

let init () =
  let query1 = Caqti_type.(unit ->. unit)
    "CREATE TABLE IF NOT EXISTS plaid_tokens (
       item_id TEXT PRIMARY KEY,
       access_token TEXT NOT NULL,
       session_id TEXT,
       status TEXT DEFAULT 'active',
       created_at TEXT DEFAULT (datetime('now'))
     )" in
  let query2 = Caqti_type.(unit ->. unit)
    "CREATE TABLE IF NOT EXISTS link_sessions (
       session_id TEXT PRIMARY KEY,
       link_token TEXT,
       hosted_link_url TEXT,
       status TEXT,
       exchange_status TEXT,
       created_at TEXT,
       updated_at TEXT
     )" in
  let migrate = Caqti_type.(unit ->. unit)
    "ALTER TABLE link_sessions ADD COLUMN exchange_status TEXT" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query1 () >>= function
    | Ok () ->
      Conn.exec query2 () >>= (function
      | Ok () ->
        Conn.exec migrate () >>= fun _ -> Lwt.return (Ok ())
      | Error _ as e -> Lwt.return e)
    | Error _ as e -> Lwt.return e
  ) pool >>= unwrap

let save_token item_id access_token session_id =
  let query = Caqti_type.(t3 string string (option string) ->. unit)
    (* Caqti takes linear '?' placeholders; '?1'-style numbering fails to
       parse and made every call to this function raise. *)
    "INSERT OR REPLACE INTO plaid_tokens (item_id, access_token, session_id, status, created_at)
     VALUES (?, ?, ?, 'active', datetime('now'))" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query (item_id, access_token, session_id)
  ) pool >>= unwrap

let mark_token_error item_id =
  let query = Caqti_type.(string ->. unit)
    "UPDATE plaid_tokens SET status = 'error' WHERE item_id = ?" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query item_id
  ) pool >>= unwrap

let delete_errored_tokens () =
  let query = Caqti_type.(unit ->. unit)
    "DELETE FROM plaid_tokens WHERE status = 'error'" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query ()
  ) pool >>= unwrap

let get_tokens () =
  let query = Caqti_type.(unit ->* (t3 string string (option string)))
    "SELECT item_id, access_token, session_id FROM plaid_tokens" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.collect_list query ()
  ) pool >>= unwrap

(* link_sessions.session_id holds the Plaid link token: it is the only handle
   the webhook and the polling fallback both have, so it is the primary key.
   The separate link_token column is kept for the existing schema and always
   holds the same value. *)
let save_link_session ~link_token ~hosted_link_url ~status =
  let query = Caqti_type.(t4 string string string string ->. unit)
    "INSERT OR REPLACE INTO link_sessions (session_id, link_token, hosted_link_url, status, created_at, updated_at) VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query (link_token, link_token, hosted_link_url, status)
  ) pool >>= unwrap

let get_link_session session_id =
  let query = Caqti_type.(string ->? (t4 string string string string))
    "SELECT link_token, hosted_link_url, status, updated_at FROM link_sessions WHERE session_id = ?" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.find_opt query session_id
  ) pool >>= unwrap

let update_link_session_status session_id status =
  let query = Caqti_type.(t2 string string ->. unit)
    "UPDATE link_sessions SET status = ?, updated_at = datetime('now') WHERE session_id = ?" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query (status, session_id)
  ) pool >>= unwrap

let get_all_link_sessions () =
  let query = Caqti_type.(unit ->* (t5 string string string string string))
    "SELECT session_id, link_token, hosted_link_url, status, updated_at FROM link_sessions ORDER BY created_at DESC" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.collect_list query ()
  ) pool >>= unwrap

(* Arbitrates between the webhook and the wait-auth polling fallback, which
   both try to exchange the same single-use public token. This must stay a
   single statement: SQLite serializes concurrent UPDATEs, so exactly one
   caller can flip a NULL exchange_status to 'claimed'. A read-then-write pair
   lets both callers observe NULL and both proceed. changes() reports the rows
   touched by the previous statement on this connection, and Pool.use holds
   that connection for the whole callback. An unknown session_id matches no
   row and so claims nothing. *)
let claim_exchange link_token =
  let claim_q = Caqti_type.(string ->. unit)
    "UPDATE link_sessions SET exchange_status = 'claimed', updated_at = datetime('now')
     WHERE session_id = ? AND (exchange_status IS NULL OR exchange_status = '')" in
  let changes_q = Caqti_type.(unit ->! int) "SELECT changes()" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec claim_q link_token >>= function
    | Error e -> Lwt.return (Error e)
    | Ok () ->
      Conn.find changes_q () >>= (function
      | Ok rows -> Lwt.return (Ok (rows > 0))
      | Error e -> Lwt.return (Error e))
  ) pool >>= unwrap

(* Undoes a claim so the other path can retry after a failed exchange. *)
let release_exchange link_token =
  let query = Caqti_type.(string ->. unit)
    "UPDATE link_sessions SET exchange_status = NULL, updated_at = datetime('now')
     WHERE session_id = ? AND exchange_status = 'claimed'" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query link_token
  ) pool >>= unwrap

let mark_exchange_done link_token =
  let query = Caqti_type.(string ->. unit)
    "UPDATE link_sessions SET exchange_status = 'exchanged', status = 'connected', updated_at = datetime('now') WHERE session_id = ?" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query link_token
  ) pool >>= unwrap

(* A session can produce several items, so this must collect rather than expect
   at most one row: find_opt fails outright when a Link session added two
   accounts. *)
let get_tokens_by_session session_id =
  let query = Caqti_type.(string ->* t2 string string)
    "SELECT item_id, access_token FROM plaid_tokens WHERE session_id = ?" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.collect_list query session_id
  ) pool >>= unwrap

type connection_status =
  | Connected of { item_id : string; access_token : string; updated_at : string }
  | Pending of { link_token : string; updated_at : string }
  | Auth_failed of { link_token : string; updated_at : string }
  | Disconnected

let latest_active_token () =
  let query = Caqti_type.(unit ->? t3 string string string)
    "SELECT item_id, access_token, created_at FROM plaid_tokens
     WHERE access_token != '' AND status = 'active'
     ORDER BY created_at DESC LIMIT 1" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.find_opt query ()
  ) pool >>= unwrap

let latest_link_session () =
  let query = Caqti_type.(unit ->? t3 string string string)
    "SELECT link_token, status, updated_at FROM link_sessions
     ORDER BY updated_at DESC LIMIT 1" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.find_opt query ()
  ) pool >>= unwrap

(* A usable token wins over session state. The previous version sorted a UNION
   of both tables by timestamp, which meant starting a new link session hid a
   perfectly good token, and made the "connected with an access token" case
   unrepresentable: the token branch could only report plaid_tokens.status
   ('active'/'error'), never 'connected'. *)
let get_current_status () =
  latest_active_token () >>= function
  | Some (item_id, access_token, updated_at) ->
    Lwt.return (Connected { item_id; access_token; updated_at })
  | None ->
    latest_link_session () >>= function
    | Some (link_token, "error", updated_at) ->
      Lwt.return (Auth_failed { link_token; updated_at })
    | Some (link_token, _, updated_at) ->
      Lwt.return (Pending { link_token; updated_at })
    | None -> Lwt.return Disconnected
