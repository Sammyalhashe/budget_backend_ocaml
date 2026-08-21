(* Plaid webhook signature verification: the pure half.

   Plaid signs every webhook with an ES256 JWT in the Plaid-Verification
   header. The JWT's request_body_sha256 claim covers the exact bytes of the
   request body, so a valid signature proves both origin and integrity.

   Nothing here does I/O: the caller supplies the key and the current time.
   That keeps every check unit-testable without a network or a clock, which
   matters most for the forgery cases. *)

type reason =
  | Malformed of string
  | Unsupported_alg of string
  | Missing_kid
  | Invalid_signature
  | Missing_claim of string
  | Body_mismatch
  | Stale of int  (* age in seconds *)

let reason_to_string = function
  | Malformed msg -> "malformed token: " ^ msg
  | Unsupported_alg alg -> "unsupported algorithm: " ^ alg
  | Missing_kid -> "token header has no kid"
  | Invalid_signature -> "signature does not match"
  | Missing_claim claim -> "token is missing the " ^ claim ^ " claim"
  | Body_mismatch -> "request body does not match request_body_sha256"
  | Stale age -> Printf.sprintf "token is %ds old" age

(* Plaid's own guidance; also the window a captured webhook could be replayed
   in. *)
let default_max_age = 300.0

(* Byte-by-byte comparison with an early exit would leak, through timing, how
   much of the expected hash a forged body got right. *)
let equal_constant_time a b =
  if String.length a <> String.length b then false
  else begin
    let acc = ref 0 in
    String.iteri
      (fun i c -> acc := !acc lor (Char.code c lxor Char.code b.[i]))
      a;
    !acc = 0
  end

(* Parses without verifying, then rejects any algorithm but ES256.

   This check has to happen before the signature is examined. Trusting the
   token's own alg is the classic JWT forgery: "none" asks us to skip
   verification entirely, and "HS256" asks us to treat the public key as an
   HMAC secret, which an attacker also holds. *)
let parse token =
  (* unsafe_of_string does not catch everything: a token that is not three
     base64url segments raises rather than returning Error, and this input is
     attacker-controlled. Letting that escape turns a forged header into a 500,
     which Plaid then retries. *)
  match
    try Jose.Jwt.unsafe_of_string token
    with exn -> Error (`Msg (Printexc.to_string exn))
  with
  | Error (`Msg msg) -> Error (Malformed msg)
  | Error `Not_json -> Error (Malformed "payload is not JSON")
  | Error `Not_supported -> Error (Malformed "unsupported token")
  | Ok jwt ->
    let header = jwt.Jose.Jwt.header in
    (match header.Jose.Header.alg with
     | `ES256 -> Ok jwt
     | alg -> Error (Unsupported_alg (Jose.Jwa.alg_to_string alg)))

(* Which key signed this, so the caller knows what to fetch. The token is
   still entirely untrusted at this point. *)
let kid_of_token token =
  match parse token with
  | Error reason -> Error reason
  | Ok jwt ->
    (match jwt.Jose.Jwt.header.Jose.Header.kid with
     | Some kid -> Ok kid
     | None -> Error Missing_kid)

let verify ?(max_age = default_max_age) ~jwk ~body ~now token =
  match parse token with
  | Error reason -> Error reason
  | Ok jwt ->
    (match Jose.Jwt.validate_signature ~jwk jwt with
     | Error _ -> Error Invalid_signature
     | Ok jwt ->
       (match Jose.Jwt.get_string_claim jwt "request_body_sha256" with
        | None -> Error (Missing_claim "request_body_sha256")
        | Some expected ->
          let actual = Digestif.SHA256.(to_hex (digest_string body)) in
          if not (equal_constant_time expected actual) then Error Body_mismatch
          else
            (match Jose.Jwt.get_int_claim jwt "iat" with
             | None -> Error (Missing_claim "iat")
             | Some iat ->
               let age = now -. float_of_int iat in
               if age > max_age then Error (Stale (int_of_float age))
               else Ok ())))
