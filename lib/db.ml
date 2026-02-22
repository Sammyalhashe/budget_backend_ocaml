open Lwt.Infix
open Caqti_request.Infix

let db_uri = Uri.of_string "sqlite3:budget.db"

let pool =
  match Caqti_lwt_unix.connect_pool db_uri with
  | Ok pool -> pool
  | Error err -> failwith (Caqti_error.show err)

let or_fail = function
  | Ok x -> Lwt.return x
  | Error err -> Lwt.fail_with (Caqti_error.show err)

let init () =
  let query = (Caqti_type.unit ->. Caqti_type.unit) 
    "CREATE TABLE IF NOT EXISTS plaid_tokens (item_id TEXT PRIMARY KEY, access_token TEXT NOT NULL)" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query ()
  ) pool >>= or_fail

let save_token item_id access_token =
  let query = (Caqti_type.(t2 string string) ->. Caqti_type.unit)
    "INSERT OR REPLACE INTO plaid_tokens (item_id, access_token) VALUES (?, ?)" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.exec query (item_id, access_token)
  ) pool >>= or_fail

let get_tokens () =
  let query = (Caqti_type.unit ->* Caqti_type.(t2 string string))
    "SELECT item_id, access_token FROM plaid_tokens" in
  Caqti_lwt_unix.Pool.use (fun (module Conn : Caqti_lwt.CONNECTION) ->
    Conn.collect_list query ()
  ) pool >>= or_fail
