{
  description = "Budget Backend OCaml Development Environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
  };

  outputs = { self, nixpkgs, flake-utils }:
    flake-utils.lib.eachDefaultSystem (system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          buildInputs = (with pkgs.ocamlPackages; [
            ocaml
            dune_3
            findlib
            dream
            yojson
            cohttp-lwt
            cohttp-lwt-unix
            lwt_ppx
            ocaml-lsp
            caqti
            caqti-lwt
            caqti-driver-sqlite3
          ]) ++ [ 
            pkgs.sops
            pkgs.sqlite 
          ];
        };

        defaultPackage = pkgs.stdenv.mkDerivation {
          name = "budget-backend";
          src = ./.;
          buildInputs = (
            with pkgs.ocamlPackages; [
              ocaml
              dune_3
              findlib
              dream
              yojson
              cohttp-lwt
              cohttp-lwt-unix
              lwt_ppx
              caqti
              caqti-lwt
              caqti-driver-sqlite3
            ]
          ) ++ [
            pkgs.sops
            pkgs.sqlite
          ];
        };
      }
    );
}
