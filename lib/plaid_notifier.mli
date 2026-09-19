(** Broadcast of {!Plaid_event.event} values to the connected front-ends. *)

type subscriber = Plaid_event.event -> unit Lwt.t

(** Handle returned by {!subscribe}; the only way to stop receiving events.
    Identity of the closure is not usable for this — two listeners can pass
    the same function. *)
type subscription

val subscribe : subscriber -> subscription Lwt.t
val unsubscribe : subscription -> unit Lwt.t

(** [notify event] delivers to every current subscriber concurrently. A
    subscriber whose delivery raises — typically a client that hung up — is
    unsubscribed rather than retried. *)
val notify : Plaid_event.event -> unit Lwt.t

val subscriber_count : unit -> int
