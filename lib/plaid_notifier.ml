type subscriber = Plaid_event.event -> unit Lwt.t

let subscribers : subscriber list ref = ref []
let mutex = Lwt_mutex.create ()

let add_subscriber f =
  Lwt_mutex.with_lock mutex (fun () ->
    subscribers := f :: !subscribers;
    Lwt.return_unit
  )

let remove_subscriber f =
  Lwt_mutex.with_lock mutex (fun () ->
    subscribers := List.filter (fun g -> g != f) !subscribers;
    Lwt.return_unit
  )

let notify event =
  Lwt_mutex.with_lock mutex (fun () ->
    let subs = !subscribers in
    Lwt_list.iter_s (fun f -> f event) subs
  )