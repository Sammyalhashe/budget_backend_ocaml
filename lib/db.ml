open Lwt.Infix
open Caqti_request.Infix

let db_uri = Uri.of_string "sqlite3:budget.db"

let pool =
  match Caqti_lwt_unix.connect_pool db_uri with
  | Ok pool -> pool
  | Error err -> failwith (Caqti_error.show err)

let unwrap = function
  | Ok x -> Lwt.return x
  | Error err -> Lwt.fail_with (Caqti_error.show err)

let init () =
  let query1 = Caqti_type.(unit ->. unit)
    "CREATE TABLE IF NOT EXISTS plaid_tokens (item_id TEXT PRIMARY KEY, access_token TEXT NOT NULL, session_id TEXT)" in
  let query2 = Caqti_type.(unit ->. unit)
    "CREATE TABLE IF NOT EXISTS link_sessions (
       session_id TEXT PRIMARY KEY,
       link_token TEXT,
       hosted_link_url TEXT,
       status TEXT,
       created_at TEXT,
       updated_at TEXT
     )" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query1 () >>= function
    | Ok () -> Conn.exec query2 ()
    | Error _ as e -> Lwt.return e
  ) pool >>= unwrap

let save_token item_id access_token session_id =
  let query = Caqti_type.(t3 string string (option string) ->. unit)
    "INSERT OR REPLACE INTO plaid_tokens (item_id, access_token, session_id) VALUES (?, ?, ?)" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query (item_id, access_token, session_id)
  ) pool >>= unwrap

let get_tokens () =
  let query = Caqti_type.(unit ->* (t3 string string (option string)))
    "SELECT item_id, access_token, session_id FROM plaid_tokens" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.collect_list query ()
  ) pool >>= unwrap

let save_link_session session_id link_token hosted_link_url status =
  let query = Caqti_type.(t4 string string string string ->. unit)
    "INSERT OR REPLACE INTO link_sessions (session_id, link_token, hosted_link_url, status, created_at, updated_at) VALUES (?, ?, ?, ?, datetime('now'), datetime('now'))" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query (session_id, link_token, hosted_link_url, status)
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
