{ lib, ocamlPackages }:

ocamlPackages.buildDunePackage {
  pname = "budget_backend";
  version = "0.1.0";
  src = ./.;

  buildInputs = with ocamlPackages; [
    dream
    yojson
    cohttp-lwt
    cohttp-lwt-unix
    lwt_ppx
  ];
}