(** Plaid webhook signature verification, without I/O.

    Keys and the current time are supplied by the caller; fetching and caching
    keys is {!Plaid_webhook}'s job. *)

type reason =
  | Malformed of string
  | Unsupported_alg of string
  | Missing_kid
  | Invalid_signature
  | Missing_claim of string
  | Body_mismatch
  | Stale of int  (** Age in seconds. *)

val reason_to_string : reason -> string

(** Plaid's recommended replay window, in seconds. *)
val default_max_age : float

(** The [kid] naming the key that signed this token, so the caller can fetch
    it. Rejects any algorithm but ES256 first; the token is untrusted here. *)
val kid_of_token : string -> (string, reason) result

(** [verify ~jwk ~body ~now token] checks, in order: that the algorithm is
    ES256, that the signature matches [jwk], that SHA-256 of [body] equals the
    [request_body_sha256] claim, and that [iat] is no more than [max_age]
    seconds before [now].

    [body] must be the raw bytes received. Re-serialised JSON will not hash to
    the same value. *)
val verify :
     ?max_age:float
  -> jwk:Jose.Jwk.public Jose.Jwk.t
  -> body:string
  -> now:float
  -> string
  -> (unit, reason) result
