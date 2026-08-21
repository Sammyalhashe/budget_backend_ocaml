(* Completing a Plaid Link session.

   A session can finish along two paths: Plaid posts a webhook, or wait-auth
   gives up waiting after a while and polls Plaid itself. Both then have to
   exchange the same single-use public token, so both go through [exchange],
   and Db.claim_exchange decides which one proceeds. Keeping that logic here
   means the two paths cannot drift apart. *)

open Lwt.Infix

type outcome =
  | Connected of { item_id : string; access_token : string }
  (* Another path got there first; it will record the result. *)
  | Already_claimed
  | Failed of string

type wait_result =
  | Wait_connected of { item_id : string; access_token : string }
  (* The session reached 'connected' but no token row is readable. *)
  | Wait_connected_unknown_token
  | Wait_failed of string
  | Wait_timeout

(* Claims the session and, if it wins the claim, exchanges every public token
   the session produced. On failure the claim is released so the other path is
   not locked out, and the session is marked errored so callers stop waiting. *)
let exchange ~link_token ~public_tokens =
  Db.claim_exchange link_token >>= function
  | false -> Lwt.return Already_claimed
  | true ->
    Lwt.catch
      (fun () ->
        Lwt_list.map_s
          (fun public_token ->
            Plaid.exchange_public_token public_token
            >>= fun (_, item_id, access_token) ->
            Db.save_token item_id access_token (Some link_token) >>= fun () ->
            Lwt.return (item_id, access_token))
          public_tokens
        >>= fun saved ->
        match saved with
        | (item_id, access_token) :: _ ->
          Db.mark_exchange_done link_token >>= fun () ->
          Lwt.return (Connected { item_id; access_token })
        | [] ->
          Db.release_exchange link_token >>= fun () ->
          Lwt.return (Failed "no public tokens to exchange"))
      (fun exn ->
        Db.release_exchange link_token >>= fun () ->
        Db.update_link_session_status link_token "error" >>= fun () ->
        Lwt.return (Failed (Printexc.to_string exn)))

(* Plaid's /link/token/get response nests the public token several levels
   down, and any level may be absent while the session is still in progress. *)
let public_token_of_link_results json =
  let open Yojson.Safe.Util in
  try
    json |> member "link_sessions" |> to_list
    |> List.find_map (fun session ->
         match
           session |> member "results" |> member "item_add_results" |> to_list
         with
         | result :: _ -> result |> member "public_token" |> to_string_option
         | [] -> None)
  with _ -> None

(* Blocks until the session completes, by either path.

   For the first [fallback_after] seconds this only watches the database, on
   the assumption the webhook will arrive and record the result. After that it
   assumes the webhook is not coming — misconfigured URL, tunnel down — and
   polls Plaid directly. *)
let wait_for_completion ?(timeout = 300.0) ?(fallback_after = 30.0) ~link_token
      ~log () =
  let start_time = Unix.gettimeofday () in
  let rec poll () =
    let elapsed = Unix.gettimeofday () -. start_time in
    if elapsed > timeout then Lwt.return Wait_timeout
    else
      Db.get_link_session link_token >>= function
      | Some (_, _, "connected", _) ->
        Db.get_tokens_by_session link_token >>= (function
        | (item_id, access_token) :: _ ->
          Lwt.return (Wait_connected { item_id; access_token })
        | [] -> Lwt.return Wait_connected_unknown_token)
      | Some (_, _, "error", _) -> Lwt.return (Wait_failed "Auth failed")
      | _ ->
        if elapsed < fallback_after then Lwt_unix.sleep 1.0 >>= poll_again
        else begin
          log "wait-auth: webhook not received, polling Plaid";
          Lwt.catch
            (fun () ->
              Plaid.get_link_token_results link_token
              >|= fun json -> Ok (public_token_of_link_results json))
            (fun exn -> Lwt.return (Error (Printexc.to_string exn)))
          >>= function
          (* A Plaid error here is usually persistent (bad credentials, dead
             link token), so fail rather than spin until the timeout. *)
          | Error msg -> Lwt.return (Wait_failed msg)
          | Ok None -> Lwt_unix.sleep 2.0 >>= poll_again
          | Ok (Some public_token) ->
            exchange ~link_token ~public_tokens:[ public_token ] >>= (function
            | Connected { item_id; access_token } ->
              Lwt.return (Wait_connected { item_id; access_token })
            | Already_claimed -> Lwt_unix.sleep 1.0 >>= poll_again
            | Failed msg -> Lwt.return (Wait_failed msg))
        end
  and poll_again () = poll () in
  poll ()
