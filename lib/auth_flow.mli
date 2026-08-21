(** Completing a Plaid Link session, shared by the webhook and the polling
    fallback so the two cannot drift apart. *)

type outcome =
  | Connected of { item_id : string; access_token : string }
  | Already_claimed  (** Another path won the claim and will record it. *)
  | Failed of string

type wait_result =
  | Wait_connected of { item_id : string; access_token : string }
  | Wait_connected_unknown_token
      (** Session reached 'connected' but no token row is readable. *)
  | Wait_failed of string
  | Wait_timeout

(** [exchange ~link_token ~public_tokens] claims the session and, if it wins,
    exchanges every public token and records the results. Releases the claim on
    failure so the other path is not locked out. Safe to call concurrently. *)
val exchange :
  link_token:string -> public_tokens:string list -> outcome Lwt.t

(** [wait_for_completion ~link_token ~log ()] blocks until the session
    completes by either path. Watches the database for [fallback_after]
    seconds, then polls Plaid directly, giving up after [timeout]. *)
val wait_for_completion :
     ?timeout:float
  -> ?fallback_after:float
  -> link_token:string
  -> log:(string -> unit)
  -> unit
  -> wait_result Lwt.t
