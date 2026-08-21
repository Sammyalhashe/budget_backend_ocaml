(** Receiving and acting on Plaid webhooks.

    Only [LINK]/[SESSION_FINISHED], [LINK]/[ITEM_ADD_RESULT] and [ITEM]/[ERROR]
    are acted on; everything else is accepted and ignored. *)

type webhook_event = {
  webhook_type : string;
  webhook_code : string;
  link_token : string option;
  item_id : string option;
  public_token : string option;
  public_tokens : string list option;
  status : string option;
  link_session_id : string option;
  environment : string option;
  raw : Yojson.Safe.t;
}

(** Parses, verifies and acts on a webhook body. Returns the parsed event so
    the caller can echo it back.

    {b Signature verification is not implemented}: this accepts any body. *)
val handle_webhook :
     body:string
  -> headers:(string * string) list
  -> (webhook_event, string) result Lwt.t
