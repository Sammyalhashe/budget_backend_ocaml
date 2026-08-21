(* Signature verification checks, including the forgeries that matter.

   Real ES256 keys are generated here and real tokens signed with them, so
   these exercise the actual crypto path rather than a stand-in. Run with
   `dune test`. *)

open Budget_backend_lib

let failures = ref 0

let check name ~expected ~actual =
  let ok = expected = actual in
  if not ok then incr failures;
  Printf.printf "%-52s %s\n" name (if ok then "PASS" else "FAIL");
  if not ok then Printf.printf "    expected %s, got %s\n" expected actual

let describe = function
  | Ok () -> "accepted"
  | Error reason -> Plaid_jwt.reason_to_string reason

(* A token as Plaid builds them: ES256, kid in the header, body hash and
   issue time in the payload. *)
let sign_token ?(alg = `ES256) ?kid ?(iat_offset = 0.0) ~key ~body now =
  let payload =
    `Assoc
      [ ("iat", `Int (int_of_float (now +. iat_offset)))
      ; ( "request_body_sha256"
        , `String Digestif.SHA256.(to_hex (digest_string body)) )
      ]
  in
  let header = Jose.Header.make_header ~typ:"JWT" ~alg key in
  let header = { header with Jose.Header.kid } in
  match Jose.Jwt.sign ~header ~payload key with
  | Ok jwt -> Jose.Jwt.to_string jwt
  | Error (`Msg m) -> failwith ("could not sign test token: " ^ m)

let () =
  Mirage_crypto_rng_unix.use_default ();
  let now = 1_700_000_000.0 in
  let body = {|{"webhook_type":"LINK","webhook_code":"SESSION_FINISHED"}|} in

  (* jose has no make_priv_es256 helper, so build the JWK directly. *)
  let es256_key ~kid priv =
    Jose.Jwk.Es256_priv
      { alg = Some `ES256; kty = `EC; use = Some `Sig; kid; key = priv }
  in
  let priv = Mirage_crypto_ec.P256.Dsa.generate () |> fst in
  let key = es256_key ~kid:(Some "key-1") priv in
  let pub_jwk =
    match Jose.Jwk.of_pub_json (Jose.Jwk.to_pub_json key) with
    | Ok jwk -> jwk
    | Error _ -> failwith "could not derive the public JWK"
  in
  (* A second, unrelated key: what an attacker signing their own token has. *)
  let other =
    es256_key ~kid:(Some "key-1") (fst (Mirage_crypto_ec.P256.Dsa.generate ()))
  in

  let verify ?(body = body) ?(now = now) token =
    describe (Plaid_jwt.verify ~jwk:pub_jwk ~body ~now token)
  in

  check "a genuine token is accepted" ~expected:"accepted"
    ~actual:(verify (sign_token ~kid:"key-1" ~key ~body now));

  check "the kid is readable from the header" ~expected:"key-1"
    ~actual:
      (match
         Plaid_jwt.kid_of_token (sign_token ~kid:"key-1" ~key ~body now)
       with
      | Ok kid -> kid
      | Error reason -> Plaid_jwt.reason_to_string reason);

  (* Forgery 1: signed with a key we do not trust. *)
  check "a token signed by another key is rejected"
    ~expected:"signature does not match"
    ~actual:(verify (sign_token ~kid:"key-1" ~key:other ~body now));

  (* Forgery 2: the body was altered after signing, so the hash no longer
     matches even though the signature is genuine. *)
  check "an altered body is rejected"
    ~expected:"request body does not match request_body_sha256"
    ~actual:
      (verify ~body:{|{"webhook_type":"LINK","webhook_code":"TAMPERED"}|}
         (sign_token ~kid:"key-1" ~key ~body now));

  (* Forgery 3: alg none. Nothing to verify, so it must never be honoured. *)
  let unsecured =
    let b64 = Base64.encode_string ~pad:false ~alphabet:Base64.uri_safe_alphabet in
    b64 {|{"alg":"none","typ":"JWT","kid":"key-1"}|}
    ^ "."
    ^ b64
        (Printf.sprintf {|{"iat":%d,"request_body_sha256":"%s"}|}
           (int_of_float now)
           Digestif.SHA256.(to_hex (digest_string body)))
    ^ "."
  in
  check "an alg:none token is rejected" ~expected:"unsupported algorithm: none"
    ~actual:(verify unsecured);

  (* Forgery 4: algorithm confusion. The attacker takes the public key, which
     anyone can fetch from Plaid, and uses it as an HMAC secret. If the alg in
     the header were trusted, this would verify. *)
  let hmac_key = Jose.Jwk.make_oct (Jose.Jwk.to_pub_json_string pub_jwk) in
  check "an HS256 token signed with the public key is rejected"
    ~expected:"unsupported algorithm: HS256"
    ~actual:(verify (sign_token ~alg:`HS256 ~kid:"key-1" ~key:hmac_key ~body now));

  (* Replay: a genuine token, captured and resent an hour later. *)
  check "a replayed token is rejected" ~expected:"token is 3600s old"
    ~actual:
      (verify ~now:(now +. 3600.0) (sign_token ~kid:"key-1" ~key ~body now));

  check "a token just inside the window is accepted" ~expected:"accepted"
    ~actual:
      (verify ~now:(now +. 299.0) (sign_token ~kid:"key-1" ~key ~body now));

  check "a token with no kid is rejected" ~expected:"token header has no kid"
    ~actual:
      (match Plaid_jwt.kid_of_token (sign_token ~key ~body now) with
      | Ok kid -> "kid " ^ kid
      | Error reason -> Plaid_jwt.reason_to_string reason);

  check "a garbage token is rejected" ~expected:"malformed"
    ~actual:
      (match verify "not-a-jwt" with
      | s when String.length s >= 9 && String.sub s 0 9 = "malformed" ->
        "malformed"
      | s -> s);

  if !failures > 0 then (
    Printf.printf "\n%d check(s) failed\n" !failures;
    exit 1)
