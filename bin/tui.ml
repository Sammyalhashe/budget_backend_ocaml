open Lwt.Infix
open LTerm_text

let spinner_frames = [| "⠋"; "⠙"; "⠹"; "⠸"; "⠼"; "⠴"; "⠦"; "⠧"; "⠇"; "⠏" |]

let open_browser url =
  let cmd =
    if Sys.file_exists "/usr/bin/open" then "open"
    else "xdg-open"
  in
  ignore (Sys.command (cmd ^ " " ^ Filename.quote url))

let print_styled term fragments =
  let text = eval fragments in
  LTerm.fprintls term text

let render_idle term =
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
  LTerm.fprints term (eval [S ""]) >>= fun () ->
  print_styled term [S "  Press Enter to connect your bank account."] >>= fun () ->
  print_styled term [S "  Press q to quit."] >>= fun () ->
  LTerm.flush term

let render_spinner term frame msg =
  let s = spinner_frames.(frame mod Array.length spinner_frames) in
  LTerm.goto term { LTerm_geom.row = 2; col = 0 } >>= fun () ->
  LTerm.clear_line term >>= fun () ->
  print_styled term [B_fg LTerm_style.cyan; S ("  " ^ s); E_fg; S (" " ^ msg)] >>= fun () ->
  LTerm.flush term

let render_connected term item_id =
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S "  "; B_fg LTerm_style.green; S "Connected!"; E_fg] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S ("  Item: " ^ item_id)] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S "  Press Enter to return, q to quit."] >>= fun () ->
  LTerm.flush term

let render_error term msg =
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S "  "; B_fg LTerm_style.red; S "Error: "; E_fg; S msg] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S "  Press Enter to retry, q to quit."] >>= fun () ->
  LTerm.flush term

let is_key ev code =
  match ev with
  | LTerm_event.Key { LTerm_key.code = c; _ } -> c = code
  | _ -> false

let is_char ev ch =
  match ev with
  | LTerm_event.Key { LTerm_key.code = LTerm_key.Char c; _ } -> Uchar.to_int c = Char.code ch
  | _ -> false

let run () =
  Lazy.force LTerm.stdout >>= fun term ->
  LTerm.enter_raw_mode term >>= fun mode ->

  let cleanup () =
    LTerm.show_cursor term >>= fun () ->
    LTerm.leave_raw_mode term mode
  in

  Lwt.finalize (fun () ->
    let rec idle_screen () =
      render_idle term >>= fun () ->
      LTerm.read_event term >>= fun ev ->
      if is_char ev 'q' || is_key ev LTerm_key.Escape then Lwt.return_unit
      else if is_key ev LTerm_key.Enter then auth_flow ()
      else idle_screen ()

    and auth_flow () =
      LTerm.clear_screen term >>= fun () ->
      LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
      print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
      print_styled term [S ""] >>= fun () ->
      print_styled term [S "  Starting auth..."] >>= fun () ->
      LTerm.flush term >>= fun () ->

      Backend_client.start_auth () >>= function
      | Error e -> error_screen (Backend_client.error_to_string e)
      | Ok auth ->
        open_browser auth.hosted_link_url;
        LTerm.clear_screen term >>= fun () ->
        LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
        print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
        print_styled term [S ""] >>= fun () ->
        LTerm.hide_cursor term >>= fun () ->
        LTerm.flush term >>= fun () ->

        let http_task = Backend_client.wait_auth ~link_token:auth.link_token in
        let cancelled = ref false in

        let spinner =
          let rec loop i =
            match Lwt.state http_task with
            | Lwt.Sleep ->
              render_spinner term i "Waiting for authentication... (complete login in browser)" >>= fun () ->
              Lwt_unix.sleep 0.08 >>= fun () ->
              loop (i + 1)
            | _ -> Lwt.return_unit
          in
          loop 0
        in

        let input_watch =
          let rec loop () =
            match Lwt.state http_task with
            | Lwt.Sleep ->
              LTerm.read_event term >>= fun ev ->
              if is_char ev 'q' || is_key ev LTerm_key.Escape then begin
                cancelled := true;
                Lwt.cancel http_task;
                Lwt.return_unit
              end else loop ()
            | _ -> Lwt.return_unit
          in
          loop ()
        in

        let http_done = http_task >>= fun _ -> Lwt.return_unit in
        Lwt.pick [spinner; http_done; input_watch] >>= fun () ->
        Lwt.cancel spinner;
        Lwt.cancel input_watch;
        LTerm.show_cursor term >>= fun () ->

        if !cancelled then idle_screen ()
        else
          (match Lwt.state http_task with
           | Lwt.Return (Ok r) -> connected_screen r.item_id
           | Lwt.Return (Error e) -> error_screen (Backend_client.error_to_string e)
           | Lwt.Fail exn -> error_screen (Printexc.to_string exn)
           | Lwt.Sleep -> error_screen "Unexpected state")

    and connected_screen item_id =
      render_connected term item_id >>= fun () ->
      wait_for_action ()

    and error_screen msg =
      render_error term msg >>= fun () ->
      wait_for_action ()

    and wait_for_action () =
      LTerm.read_event term >>= fun ev ->
      if is_char ev 'q' || is_key ev LTerm_key.Escape then Lwt.return_unit
      else if is_key ev LTerm_key.Enter then idle_screen ()
      else wait_for_action ()
    in

    idle_screen ()
  ) cleanup

let () = Lwt_main.run (run ())
