(* Checks on the database invariants that the auth flow depends on.

   Runs against a real SQLite file, created in dune's sandbox directory, so no
   mocking is needed. Run with `dune test`. *)

open Lwt.Infix
open Budget_backend_lib

let failures = ref 0

let check name ~expected ~actual =
  let ok = expected = actual in
  if not ok then incr failures;
  Printf.printf "%-46s %s\n" name (if ok then "PASS" else "FAIL");
  if not ok then Printf.printf "    expected %s, got %s\n" expected actual

let check_bool name ~expected ~actual =
  check name ~expected:(string_of_bool expected) ~actual:(string_of_bool actual)

let () =
  Lwt_main.run
    ( Db.init () >>= fun () ->
      (* The claim is what stops the webhook and the polling fallback both
         exchanging the same single-use public token. *)
      Db.save_link_session ~link_token:"lt-race" ~hosted_link_url:"u"
        ~status:"pending"
      >>= fun () ->
      Lwt.both (Db.claim_exchange "lt-race") (Db.claim_exchange "lt-race")
      >>= fun (a, b) ->
      check_bool "concurrent claims: exactly one wins" ~expected:true
        ~actual:(a <> b);

      Db.claim_exchange "lt-race" >>= fun again ->
      check_bool "re-claiming a claimed session fails" ~expected:false
        ~actual:again;

      Db.claim_exchange "lt-nonexistent" >>= fun unknown ->
      check_bool "an unknown link token cannot be claimed" ~expected:false
        ~actual:unknown;

      Db.release_exchange "lt-race" >>= fun () ->
      Db.claim_exchange "lt-race" >>= fun after_release ->
      check_bool "releasing allows a later claim" ~expected:true
        ~actual:after_release;

      Db.save_link_session ~link_token:"lt8" ~hosted_link_url:"u"
        ~status:"pending"
      >>= fun () ->
      Lwt_list.map_p (fun _ -> Db.claim_exchange "lt8") [ 1; 2; 3; 4; 5; 6; 7; 8 ]
      >>= fun results ->
      check "eight concurrent claims yield one winner" ~expected:"1"
        ~actual:
          (string_of_int (List.length (List.filter (fun x -> x) results)));

      (* A completed auth must be reportable, which the previous UNION-based
         status query could not express. *)
      Db.save_token "item-1" "access-xyz" (Some "lt-race") >>= fun () ->
      Db.mark_exchange_done "lt-race" >>= fun () ->
      Db.get_current_status () >>= fun status ->
      check "a completed auth reports Connected" ~expected:"item-1/access-xyz"
        ~actual:
          (match status with
          | Db.Connected { item_id; access_token; _ } ->
            item_id ^ "/" ^ access_token
          | Db.Pending _ -> "Pending"
          | Db.Auth_failed _ -> "Auth_failed"
          | Db.Disconnected -> "Disconnected");

      Db.save_link_session ~link_token:"lt-new" ~hosted_link_url:"u"
        ~status:"pending"
      >>= fun () ->
      Db.get_current_status () >>= fun status ->
      check "a new session does not hide an existing token"
        ~expected:"Connected"
        ~actual:(match status with Db.Connected _ -> "Connected" | _ -> "hidden");

      (* One Link session can add several items. *)
      Db.save_token "item-2" "access-2" (Some "lt-race") >>= fun () ->
      Lwt.catch
        (fun () ->
          Db.get_tokens_by_session "lt-race" >|= fun tokens ->
          check "two items in one session are both readable" ~expected:"2"
            ~actual:(string_of_int (List.length tokens)))
        (fun exn ->
          check "two items in one session are both readable" ~expected:"2"
            ~actual:("raised " ^ Printexc.to_string exn);
          Lwt.return_unit) );
  if !failures > 0 then (
    Printf.printf "\n%d check(s) failed\n" !failures;
    exit 1)
