open Lwt.Infix

(* Plaid's response is returned as-is: its top-level "link_token" is the string
   the browser page passes to Plaid.create. Wrapping it in another object
   nested that string one level too deep and broke /link. *)
let create_link_token () = Plaid.create_link_token ()

let get_transactions access_token start_date end_date =
  Plaid.get_transactions access_token start_date end_date >>= fun json ->
  Lwt.return json
