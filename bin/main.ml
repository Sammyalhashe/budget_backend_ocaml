(* Simple OCaml Dream server entry point *)

let () =
  Dream.run
  @@ Dream.logger
  @@ Dream.router [
    Dream.get "/"
      (fun _ ->
        Dream.html "Hello World!");
  ]
