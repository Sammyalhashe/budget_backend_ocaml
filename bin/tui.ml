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

(* Static frame around the spinner line, which render_spinner redraws in place. *)
let render_waiting term url =
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S "  If your browser didn't open, visit:"] >>= fun () ->
  print_styled term [S "  "; B_fg LTerm_style.blue; S url; E_fg] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S "  [o] open browser   [q] cancel"] >>= fun () ->
  LTerm.flush term

let render_busy term msg =
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S ("  " ^ msg)] >>= fun () ->
  LTerm.flush term

let money amount currency =
  Printf.sprintf "%.2f %s" amount (Option.value currency ~default:"")

let render_accounts term item_id accounts =
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term
    [ S "  "; B_fg LTerm_style.green; S "Connected"; E_fg
    ; S ("  item " ^ item_id) ]
  >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  Lwt_list.iter_s
    (fun (account : Backend_client.account) ->
      let label =
        match account.mask with
        | Some mask -> account.name ^ " ••" ^ mask
        | None -> account.name
      in
      let balance =
        match account.balance with
        | Some amount -> money amount account.currency
        | None -> "—"
      in
      print_styled term
        [ S (Printf.sprintf "  %-32s %18s  %s" label balance
               (Option.value account.subtype ~default:"")) ])
    accounts
  >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  (if accounts = [] then
     print_styled term [S "  No accounts reported for this item."]
   else Lwt.return_unit)
  >>= fun () ->
  print_styled term
    [S "  [t] transactions   [r] refresh   [n] connect another   [q] quit"]
  >>= fun () ->
  LTerm.flush term

let render_transactions term transactions =
  LTerm.clear_screen term >>= fun () ->
  LTerm.goto term { LTerm_geom.row = 0; col = 0 } >>= fun () ->
  print_styled term [B_bold true; S "Budget Backend"; E_bold] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S "  Transactions, last 30 days"] >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  (* Whatever the terminal height, the list has to stop somewhere; the newest
     are the ones worth showing. *)
  let shown = List.filteri (fun i _ -> i < 20) transactions in
  Lwt_list.iter_s
    (fun (transaction : Backend_client.transaction) ->
      print_styled term
        [ S (Printf.sprintf "  %-12s %-34s %14s" transaction.date
               transaction.description
               (money transaction.amount transaction.currency)) ])
    shown
  >>= fun () ->
  (if transactions = [] then
     print_styled term [S "  Nothing in this window."]
   else Lwt.return_unit)
  >>= fun () ->
  print_styled term [S ""] >>= fun () ->
  print_styled term [S "  [a] accounts   [q] quit"] >>= fun () ->
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
    let rec start_screen () =
      (* The connection lives in the backend, not here, so a TUI started
         after a previous run's authentication opens on the accounts. *)
      render_busy term "Checking connection..." >>= fun () ->
      Backend_client.status () >>= function
      | Ok (Backend_client.Connected { item_id; _ }) -> accounts_screen item_id
      | Ok _ -> idle_screen ()
      | Error e -> error_screen (Backend_client.error_to_string e)

    and idle_screen () =
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
        render_waiting term auth.hosted_link_url >>= fun () ->
        LTerm.hide_cursor term >>= fun () ->
        LTerm.flush term >>= fun () ->

        (* Two ways to hear that the session finished, raced against each
           other. The event stream is the webhook path arriving as it
           happens; wait-auth is a long poll, and calling it is also what
           makes the backend fall back to polling Plaid when no webhook ever
           shows up. Whichever answers first settles the screen.

           The event only carries the item id, so a connection reported that
           way is looked up afterwards rather than read out of the frame. *)
        let http_task = Backend_client.await_auth ~link_token:auth.link_token in
        let cancelled = ref false in

        let spinner =
          let rec loop i =
            match Lwt.state http_task with
            | Lwt.Sleep ->
              render_spinner term i "Waiting for authentication..." >>= fun () ->
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
              end else if is_char ev 'o' then begin
                open_browser auth.hosted_link_url;
                loop ()
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
           | Lwt.Return (Ok r) -> accounts_screen r.item_id
           | Lwt.Return (Error e) -> error_screen (Backend_client.error_to_string e)
           | Lwt.Fail exn -> error_screen (Printexc.to_string exn)
           | Lwt.Sleep -> error_screen "Unexpected state")

    (* Authenticated, so the data the whole flow exists to reach is now one
       request away. *)
    and accounts_screen item_id =
      render_busy term "Fetching accounts..." >>= fun () ->
      Backend_client.accounts () >>= function
      | Error e -> error_screen (Backend_client.error_to_string e)
      | Ok accounts ->
        render_accounts term item_id accounts >>= fun () ->
        let rec keys () =
          LTerm.read_event term >>= fun ev ->
          if is_char ev 'q' || is_key ev LTerm_key.Escape then Lwt.return_unit
          else if is_char ev 't' then transactions_screen item_id
          else if is_char ev 'r' then accounts_screen item_id
          else if is_char ev 'n' then auth_flow ()
          else keys ()
        in
        keys ()

    and transactions_screen item_id =
      render_busy term "Fetching transactions..." >>= fun () ->
      Backend_client.transactions () >>= function
      | Error e -> error_screen (Backend_client.error_to_string e)
      | Ok transactions ->
        render_transactions term transactions >>= fun () ->
        let rec keys () =
          LTerm.read_event term >>= fun ev ->
          if is_char ev 'q' || is_key ev LTerm_key.Escape then Lwt.return_unit
          else if is_char ev 'a' then accounts_screen item_id
          else keys ()
        in
        keys ()

    and error_screen msg =
      render_error term msg >>= fun () ->
      wait_for_action ()

    and wait_for_action () =
      LTerm.read_event term >>= fun ev ->
      if is_char ev 'q' || is_key ev LTerm_key.Escape then Lwt.return_unit
      else if is_key ev LTerm_key.Enter then idle_screen ()
      else wait_for_action ()
    in

    start_screen ()
  ) cleanup

let () = Lwt_main.run (run ())
