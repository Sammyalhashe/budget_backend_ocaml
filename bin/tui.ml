let spinner_frames = [| "⠋"; "⠙"; "⠹"; "⠸"; "⠼"; "⠴"; "⠦"; "⠧"; "⠇"; "⠏" |]

let clear_screen () =
  print_string "\027[2J\027[H";
  flush stdout

let hide_cursor () = print_string "\027[?25l"; flush stdout
let show_cursor () = print_string "\027[?25h"; flush stdout

let green s = Printf.sprintf "\027[32m%s\027[0m" s
let red s = Printf.sprintf "\027[31m%s\027[0m" s
let bold s = Printf.sprintf "\027[1m%s\027[0m" s

let open_browser url =
  let cmd =
    if Sys.file_exists "/usr/bin/open" then "open"
    else "xdg-open"
  in
  ignore (Sys.command (cmd ^ " " ^ Filename.quote url))

let read_key () =
  let open Lwt.Infix in
  let buf = Bytes.create 1 in
  Lwt_unix.read Lwt_unix.stdin buf 0 1 >>= fun n ->
  if n > 0 then Lwt.return_some (Bytes.get buf 0)
  else Lwt.return_none

let set_raw_mode () =
  let open Unix in
  let attr = tcgetattr stdin in
  let raw = { attr with c_icanon = false; c_echo = false; c_vmin = 0; c_vtime = 0 } in
  tcsetattr stdin TCSANOW raw;
  attr

let wait_with_spinner msg check_done =
  let open Lwt.Infix in
  hide_cursor ();
  let rec loop i =
    if Atomic.get check_done then Lwt.return_unit
    else begin
      let frame = spinner_frames.(i mod Array.length spinner_frames) in
      print_string (Printf.sprintf "\r  %s %s" frame msg);
      flush stdout;
      Lwt_unix.sleep 0.08 >>= fun () ->
      loop (i + 1)
    end
  in
  loop 0

let run () =
  let open Lwt.Infix in
  let orig_attr = set_raw_mode () in
  let restore () = Unix.tcsetattr Unix.stdin Unix.TCSANOW orig_attr; show_cursor () in

  let rec main_loop () =
    clear_screen ();
    print_string (Printf.sprintf "\n  %s\n\n  Press Enter to connect your bank account.\n  Press q to quit.\n\n" (bold "Budget Backend"));
    flush stdout;

    let rec wait_for_key () =
      read_key () >>= function
      | Some 'q' -> restore (); Lwt.return_unit
      | Some '\n' | Some '\r' -> auth_flow ()
      | _ -> Lwt_unix.sleep 0.05 >>= fun () -> wait_for_key ()
    in
    wait_for_key ()

  and auth_flow () =
    clear_screen ();
    print_string (Printf.sprintf "\n  %s\n\n  Starting auth...\n" (bold "Budget Backend"));
    flush stdout;

    match Backend_client.start_auth () with
    | Error e ->
      clear_screen ();
      print_string (Printf.sprintf "\n  %s\n\n  %s\n\n  Press Enter to retry, q to quit.\n"
        (bold "Budget Backend") (red (Backend_client.error_to_string e)));
      flush stdout;
      wait_for_action ()
    | Ok auth ->
      open_browser auth.hosted_link_url;
      clear_screen ();
      print_string (Printf.sprintf "\n  %s\n\n" (bold "Budget Backend"));
      flush stdout;

      let done_flag = Atomic.make false in
      let result_ref = Atomic.make (Error Backend_client.Timeout) in

      let _worker = Lwt.async (fun () ->
        Lwt_preemptive.detach (fun () ->
          let r = Backend_client.wait_auth ~link_token:auth.link_token in
          Atomic.set result_ref r;
          Atomic.set done_flag true
        ) ()
      ) in

      let cancel_flag = Atomic.make false in
      let _input = Lwt.async (fun () ->
        let rec check () =
          if Atomic.get done_flag then Lwt.return_unit
          else
            read_key () >>= function
            | Some 'q' -> Atomic.set cancel_flag true; Lwt.return_unit
            | _ -> Lwt_unix.sleep 0.05 >>= fun () -> check ()
        in
        check ()
      ) in

      wait_with_spinner "Waiting for authentication... (complete login in browser)" done_flag >>= fun () ->

      if Atomic.get cancel_flag then begin
        restore (); Lwt.return_unit
      end else begin
        let result = Atomic.get result_ref in
        show_cursor ();
        clear_screen ();
        (match result with
         | Ok r ->
           print_string (Printf.sprintf "\n  %s\n\n  %s\n\n  Item: %s\n\n  Press Enter to return, q to quit.\n"
             (bold "Budget Backend") (green "Connected!") r.item_id);
           flush stdout;
           wait_for_action ()
         | Error e ->
           print_string (Printf.sprintf "\n  %s\n\n  %s\n\n  Press Enter to retry, q to quit.\n"
             (bold "Budget Backend") (red (Backend_client.error_to_string e)));
           flush stdout;
           wait_for_action ())
      end

  and wait_for_action () =
    let rec loop () =
      read_key () >>= function
      | Some 'q' -> restore (); Lwt.return_unit
      | Some '\n' | Some '\r' -> main_loop ()
      | _ -> Lwt_unix.sleep 0.05 >>= fun () -> loop ()
    in
    loop ()
  in

  Lwt.finalize main_loop (fun () -> restore (); Lwt.return_unit)

let () = Lwt_main.run (run ())
