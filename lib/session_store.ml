open Lwt

type session = {
  session_id : string;
  item_id : string;
  access_token : string;
  created_at : string;
}

let sessions = ref []

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
  Lwt.return session

let find_session session_id =
  try
    let session = List.find (fun s -> s.session_id = session_id) !sessions in
    Lwt.return (Some session)
  with Not_found ->
    Lwt.return None

let find_session_by_item_id item_id =
  try
    let session = List.find (fun s -> s.item_id = item_id) !sessions in
    Lwt.return (Some session)
  with Not_found ->
    Lwt.return None

let delete_session session_id =
  sessions := List.filter (fun s -> s.session_id <> session_id) !sessions;
  Lwt.return_unit
