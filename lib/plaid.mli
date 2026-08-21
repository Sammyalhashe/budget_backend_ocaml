(** Thin client over the Plaid HTTP API.

    Every call raises {!Plaid_error} on a non-2xx response rather than
    returning Plaid's error object, which would otherwise parse as a success
    with empty fields. *)

exception
  Plaid_error of { status : int; error_code : string; error_message : string }

(** Public HTTPS URL Plaid posts webhooks to, from [PLAID_WEBHOOK_URL]. *)
val webhook_url : string option

(** Creates a Link token. [hosted_link] requests a Plaid-hosted Link page and
    makes [hosted_link_url] available in the response. *)
val create_link_token :
  ?hosted_link:bool -> ?webhook:string -> unit -> Yojson.Safe.t Lwt.t

(** Exchanges a public token, returning the raw response alongside the
    extracted [item_id] and [access_token]. *)
val exchange_public_token :
  string -> (Yojson.Safe.t * string * string) Lwt.t

val get_transactions :
  string -> string -> string -> Yojson.Safe.t Lwt.t

(** Link session results, used by the polling fallback to recover a public
    token when no webhook arrives. *)
val get_link_token_results : string -> Yojson.Safe.t Lwt.t

val get_webhook_verification_key : ?key_id:string -> unit -> Yojson.Safe.t Lwt.t
val get_accounts : string -> Yojson.Safe.t Lwt.t
