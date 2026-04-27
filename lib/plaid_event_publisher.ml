open Lwt

type subscriber = Plaid_event.event -> unit Lwt.t

let subscribers : subscriber list ref = ref []
let subscribe f = subscribers := f :: !subscribers

let publish event =
  let rec publish_to_subscribers = function
    | [] -> Lwt.return_unit
    | subscriber :: rest ->
      subscriber event >>= fun () -> publish_to_subscribers rest
  in
  publish_to_subscribers !subscribers
