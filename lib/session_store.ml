type session = {
  session_id : string;
  item_id : string;
  access_token : string;
  created_at : string;
}

type link_session = {
  link_token : string;
  hosted_link_url : string option;
  status : string; (* pending, connected, error *)
  created_at : float;
}

let sessions : session list ref = ref []
let link_sessions : link_session list ref = ref []

let generate_session_id () =
  let chars = "abcdefghijklmnopqrstuvwxyz0123456789" in
  let result = Bytes.create 32 in
  for i = 0 to 31 do
    Bytes.set result i (String.get chars (Random.int (String.length chars)))
  done;
  Bytes.to_string result

let create_session item_id access_token =
  let session_id = generate_session_id () in
  let created_at = string_of_float (Unix.gettimeofday ()) in
  let session = { session_id; item_id; access_token; created_at } in
  sessions := session :: !sessions;
  session

let find_session session_id =
  try
    let session = List.find (fun s -> s.session_id = session_id) !sessions in
    Some session
  with Not_found ->
    None

let find_session_by_item_id item_id =
  try
    let session = List.find (fun s -> s.item_id = item_id) !sessions in
    Some session
  with Not_found ->
    None

let delete_session session_id =
  sessions := List.filter (fun s -> s.session_id <> session_id) !sessions

let save_link_session link_token hosted_link_url =
  let link_session = {
    link_token;
    hosted_link_url;
    status = "pending";
    created_at = Unix.gettimeofday ();
  } in
  link_sessions := link_session :: !link_sessions

let update_link_session_status link_token status =
  link_sessions := List.map (fun ls ->
    if ls.link_token = link_token then { ls with status } else ls
  ) !link_sessions

let get_current_status () =
  match !link_sessions with
  | [] -> None
  | ls :: _ -> Some (ls.link_token, ls.hosted_link_url, ls.status)

let get_link_session link_token =
  try
    Some (List.find (fun ls -> ls.link_token = link_token) !link_sessions)
  with Not_found ->
    None

let cleanup_expired_sessions () =
  let now = Unix.gettimeofday () in
  link_sessions := List.filter (fun ls ->
    ls.status <> "pending" || now -. ls.created_at < 600.0 (* 10 minutes *)
  ) !link_sessions