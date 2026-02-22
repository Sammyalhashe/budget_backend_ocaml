open Lwt

type subscriber = event -> unit Lwt.t

let subscribers = ref []

let subscribe f =
  subscribers := f :: !subscribers

let publish event =
  let rec publish_to_subscribers = function
    | [] -> Lwt.return_unit
    | subscriber :: rest ->
      subscriber event >>= fun () ->
      publish_to_subscribers rest
  in
  publish_to_subscribers !subscribers
