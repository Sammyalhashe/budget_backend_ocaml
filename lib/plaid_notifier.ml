(* Fan-out of Plaid events to whoever is currently listening: the SSE stream
   and the WebSocket, both of which come and go with their client. *)

open Lwt.Infix

type subscriber = Plaid_event.event -> unit Lwt.t
type subscription = int

let subscribers : (subscription, subscriber) Hashtbl.t = Hashtbl.create 4
let next_id = ref 0
let mutex = Lwt_mutex.create ()

let subscribe f =
  Lwt_mutex.with_lock mutex (fun () ->
    let id = !next_id in
    incr next_id;
    Hashtbl.replace subscribers id f;
    Lwt.return id)

let unsubscribe id =
  Lwt_mutex.with_lock mutex (fun () ->
    Hashtbl.remove subscribers id;
    Lwt.return_unit)

let subscriber_count () = Hashtbl.length subscribers

(* The lock covers the snapshot of the table, not the delivery: a subscriber
   writing to a stalled socket would otherwise hold every other subscriber —
   and the webhook handler that called [notify] — behind it. A delivery that
   raises means the peer is gone, so the subscriber is dropped rather than
   left to fail on every future event. *)
let notify event =
  Lwt_mutex.with_lock mutex (fun () ->
    Lwt.return (Hashtbl.fold (fun id f acc -> (id, f) :: acc) subscribers []))
  >>= fun current ->
  Lwt_list.iter_p
    (fun (id, f) ->
      Lwt.catch (fun () -> f event) (fun _ -> unsubscribe id))
    current
