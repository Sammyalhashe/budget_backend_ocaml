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
  let query1 =
    Caqti_type.(unit ->. unit)
      "CREATE TABLE IF NOT EXISTS plaid_tokens (\n\
      \       item_id TEXT PRIMARY KEY, \n\
      \       access_token TEXT NOT NULL, \n\
      \       session_id TEXT,\n\
      \       status TEXT DEFAULT 'active',\n\
      \       created_at TEXT DEFAULT (datetime('now'))\n\
      \     )"
  in
  let query2 =
    Caqti_type.(unit ->. unit)
      "CREATE TABLE IF NOT EXISTS link_sessions (\n\
      \       session_id TEXT PRIMARY KEY,\n\
      \       link_token TEXT,\n\
      \       hosted_link_url TEXT,\n\
      \       status TEXT,\n\
      \       created_at TEXT,\n\
      \       updated_at TEXT\n\
      \     )"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) ->
      Conn.exec query1 () >>= function
      | Ok () -> Conn.exec query2 ()
      | Error _ as e -> Lwt.return e)
    pool
  >>= unwrap

let save_token item_id access_token session_id =
  let query =
    Caqti_type.(t3 string string (option string) ->. unit)
      "INSERT OR REPLACE INTO plaid_tokens (item_id, access_token, session_id, \
       status, created_at) \n\
      \     VALUES (?1, ?2, ?3, 'active', datetime('now'))"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) ->
      Conn.exec query (item_id, access_token, session_id))
    pool
  >>= unwrap

let mark_token_error item_id =
  let query =
    Caqti_type.(string ->. unit)
      "UPDATE plaid_tokens SET status = 'error' WHERE item_id = ?"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) -> Conn.exec query item_id)
    pool
  >>= unwrap

let delete_errored_tokens () =
  let query =
    Caqti_type.(unit ->. unit) "DELETE FROM plaid_tokens WHERE status = 'error'"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) -> Conn.exec query ())
    pool
  >>= unwrap

let get_tokens () =
  let query =
    Caqti_type.(unit ->* t3 string string (option string))
      "SELECT item_id, access_token, session_id FROM plaid_tokens"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) -> Conn.collect_list query ())
    pool
  >>= unwrap

let save_link_session session_id link_token hosted_link_url status =
  let query =
    Caqti_type.(t4 string string string string ->. unit)
      "INSERT OR REPLACE INTO link_sessions (session_id, link_token, \
       hosted_link_url, status, created_at, updated_at) VALUES (?, ?, ?, ?, \
       datetime('now'), datetime('now'))"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) ->
      Conn.exec query (session_id, link_token, hosted_link_url, status))
    pool
  >>= unwrap

let get_link_session session_id =
  let query =
    Caqti_type.(string ->? t4 string string string string)
      "SELECT link_token, hosted_link_url, status, updated_at FROM \
       link_sessions WHERE session_id = ?"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) -> Conn.find_opt query session_id)
    pool
  >>= unwrap

let update_link_session_status session_id status =
  let query =
    Caqti_type.(t2 string string ->. unit)
      "UPDATE link_sessions SET status = ?, updated_at = datetime('now') WHERE \
       session_id = ?"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) ->
      Conn.exec query (status, session_id))
    pool
  >>= unwrap

let get_all_link_sessions () =
  let query =
    Caqti_type.(unit ->* t5 string string string string string)
      "SELECT session_id, link_token, hosted_link_url, status, updated_at FROM \
       link_sessions ORDER BY created_at DESC"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) -> Conn.collect_list query ())
    pool
  >>= unwrap

let get_current_status () =
  let query =
    Caqti_type.(
      unit ->? t5 (option string) (option string) (option string) string string)
      "SELECT item_id, access_token, link_token, status, updated_at \n\
      \     FROM (\n\
      \       SELECT item_id, access_token, NULL as link_token, status, \
       created_at as updated_at \n\
      \       FROM plaid_tokens WHERE access_token IS NOT NULL AND \
       access_token != ''\n\
      \       UNION ALL\n\
      \       SELECT NULL, NULL, link_token, status, updated_at FROM \
       link_sessions\n\
      \     ) ORDER BY updated_at DESC LIMIT 1"
  in
  Caqti_lwt_unix.Pool.use
    (fun (module Conn : Caqti_lwt.CONNECTION) -> Conn.find_opt query ())
    pool
  >>= unwrap
