(** SQLite persistence.

    Two tables, with deliberately distinct notions of identity:

    - [plaid_tokens] — one row per linked item, keyed by Plaid's [item_id]. Its
      [session_id] column records which flow produced it: the link token for
      the hosted-link flow, or a caller-supplied label for the browser flow.
    - [link_sessions] — one row per authentication attempt, keyed by the Plaid
      link token. [status] tracks the user-visible progress
      (pending/connected/error); [exchange_status] is the claim used to stop
      the webhook and the polling fallback both exchanging the same token.

    The database file is [budget.db], resolved relative to the working
    directory. *)

(** Creates the tables if absent. Call once at startup. *)
val init : unit -> unit Lwt.t

(** {1 Tokens} *)

val save_token : string -> string -> string option -> unit Lwt.t
val mark_token_error : string -> unit Lwt.t
val delete_errored_tokens : unit -> unit Lwt.t
val get_tokens : unit -> (string * string * string option) list Lwt.t

(** All tokens produced by one link session. A session can add several items,
    so this returns a list. *)
val get_tokens_by_session : string -> (string * string) list Lwt.t

(** {1 Link sessions} *)

val save_link_session :
  link_token:string -> hosted_link_url:string -> status:string -> unit Lwt.t

(** Returns [(link_token, hosted_link_url, status, updated_at)]. *)
val get_link_session :
  string -> (string * string * string * string) option Lwt.t

val update_link_session_status : string -> string -> unit Lwt.t

val get_all_link_sessions :
  unit -> (string * string * string * string * string) list Lwt.t

(** {1 Exchange claim}

    Guards the single-use public token against being exchanged twice. *)

(** Atomically claims the session, returning [true] only to the caller that won
    and [false] to everyone else, including for an unknown link token. *)
val claim_exchange : string -> bool Lwt.t

(** Releases a claim so another path can retry after a failed exchange. *)
val release_exchange : string -> unit Lwt.t

(** Marks the exchange done and the session connected. *)
val mark_exchange_done : string -> unit Lwt.t

(** {1 Aggregate status} *)

type connection_status =
  | Connected of { item_id : string; access_token : string; updated_at : string }
  | Pending of { link_token : string; updated_at : string }
  | Auth_failed of { link_token : string; updated_at : string }
  | Disconnected

(** A usable token takes precedence over link-session state, so starting a new
    session does not hide an existing connection. *)
val get_current_status : unit -> connection_status Lwt.t
