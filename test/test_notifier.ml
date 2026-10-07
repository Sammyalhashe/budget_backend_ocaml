(* Checks on the broadcast the front-ends hang off: an event that never
   reaches a listener leaves the TUI waiting on an authentication that has
   already completed. Run with `dune test`. *)

open Lwt.Infix
open Budget_backend_lib

let failures = ref 0

let check name ~expected ~actual =
  let ok = expected = actual in
  if not ok then incr failures;
  Printf.printf "%-46s %s\n" name (if ok then "PASS" else "FAIL");
  if not ok then Printf.printf "    expected %s, got %s\n" expected actual

let connected () =
  Plaid_event.auth_connected ~item_id:"item-1" ~link_token:(Some "lt-1")

let () =
  Lwt_main.run
    ( (* Round trip: the TUI reads these fields back off the wire, so a field
         dropped by the encoder is a front-end that cannot tell which session
         an event belongs to. *)
      let decoded = Plaid_event.of_json (Plaid_event.to_json (connected ())) in
      check "an event survives the JSON round trip"
        ~expected:"auth_connected/item-1/lt-1"
        ~actual:
          (Printf.sprintf "%s/%s/%s"
             (Plaid_event.event_type_to_string decoded.Plaid_event.event_type)
             decoded.Plaid_event.item_id
             (Option.value decoded.Plaid_event.link_token ~default:"none"));

      let received = ref [] in
      Plaid_notifier.subscribe (fun event ->
        received := event.Plaid_event.item_id :: !received;
        Lwt.return_unit)
      >>= fun subscription ->
      Plaid_notifier.notify (connected ()) >>= fun () ->
      check "a subscriber receives a broadcast" ~expected:"[item-1]"
        ~actual:(Printf.sprintf "[%s]" (String.concat ";" !received));

      Plaid_notifier.unsubscribe subscription >>= fun () ->
      Plaid_notifier.notify (connected ()) >>= fun () ->
      check "an unsubscribed listener receives nothing further"
        ~expected:"[item-1]"
        ~actual:(Printf.sprintf "[%s]" (String.concat ";" !received));

      (* Two listeners can pass the same closure, so a subscription has to be
         identified by its handle and not by the function. *)
      let deliveries = ref 0 in
      let listener _ =
        incr deliveries;
        Lwt.return_unit
      in
      Plaid_notifier.subscribe listener >>= fun first ->
      Plaid_notifier.subscribe listener >>= fun _second ->
      Plaid_notifier.unsubscribe first >>= fun () ->
      Plaid_notifier.notify (connected ()) >>= fun () ->
      check "unsubscribing one of two identical listeners keeps the other"
        ~expected:"1" ~actual:(string_of_int !deliveries);

      (* A client that hung up fails its write. Kept on the list it would
         fail on every future event, so the broadcast drops it. *)
      Plaid_notifier.subscribe (fun _ -> Lwt.fail_with "socket closed")
      >>= fun _dead ->
      let before = Plaid_notifier.subscriber_count () in
      Plaid_notifier.notify (connected ()) >>= fun () ->
      check "a failing subscriber is dropped"
        ~expected:(string_of_int (before - 1))
        ~actual:(string_of_int (Plaid_notifier.subscriber_count ()));

      (* One stalled delivery must not hold up the others: the webhook
         handler waits on notify before answering Plaid. *)
      let fast = ref false in
      let stalled, _never = Lwt.wait () in
      Plaid_notifier.subscribe (fun _ -> stalled) >>= fun _ ->
      Plaid_notifier.subscribe (fun _ ->
        fast := true;
        Lwt.return_unit)
      >>= fun _ ->
      let broadcast = Plaid_notifier.notify (connected ()) in
      Lwt.pause () >>= fun () ->
      check "a stalled subscriber does not block the others" ~expected:"true"
        ~actual:(string_of_bool !fast);
      (* Nor may it hold up notify itself: [Auth_flow.exchange] broadcasts
         before answering wait-auth or Plaid, and a write to a dead stream
         can stay pending forever. *)
      Lwt.pick
        [ (broadcast >|= fun () -> "resolved")
        ; (Lwt_unix.sleep 1.0 >|= fun () -> "pending")
        ]
      >>= fun outcome ->
      check "a stalled subscriber does not block notify" ~expected:"resolved"
        ~actual:outcome;
      Lwt.return_unit );
  if !failures > 0 then (
    Printf.printf "\n%d check(s) failed\n" !failures;
    exit 1)
