open Lwt

type subscriber = Plaid_event.event -> unit Lwt.t

let subscribers = Hashtbl.create 16
let mutex = Lwt_mutex.create ()

let add_subscriber f =
  Lwt_mutex.with_lock mutex (fun () ->
    Hashtbl.add subscribers f ()
  )

let remove_subscriber f =
  Lwt_mutex.with_lock mutex (fun () ->
    Hashtbl.remove subscribers f
  )

let notify event =
  Lwt_mutex.with_lock mutex (fun () ->
    let subs = Hashtbl.find_all subscribers (fun _ -> true) in
    Lwt_list.iter_s (fun f -> f event) subs
  )
