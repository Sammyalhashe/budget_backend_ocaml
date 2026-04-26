{
  description = "Budget Backend OCaml Development Environment";

  inputs = {
    nixpkgs.url = "github:nixos/nixpkgs/nixpkgs-unstable";
    flake-utils.url = "github:numtide/flake-utils";
    sops-nix.url = "github:Mic92/sops-nix";
  };

  outputs =
    {
      self,
      nixpkgs,
      flake-utils,
      sops-nix,
    }@inputs:
    flake-utils.lib.eachDefaultSystem (
      system:
      let
        pkgs = import nixpkgs { inherit system; };
      in
      {
        devShells.default = pkgs.mkShell {
          nativeBuildInputs = [
            sops-nix.packages.${system}.sops-import-keys-hook
          ];
          buildInputs =
            (with pkgs.ocamlPackages; [
              ocaml
              dune_3
              findlib
              dream
              yojson
              cohttp-lwt
              cohttp-lwt-unix
              lwt_ppx
              jose
              caqti
              caqti-lwt
              caqti-driver-sqlite3
              lwt
              ocaml-lsp
            ])
            ++ [
              pkgs.sops
              pkgs.sqlite
              pkgs.jq
              pkgs.ssh-to-age
            ];

          shellHook = ''
            USER_SSH_KEY="$HOME/.ssh/id_ed25519"

            if [ -f "$USER_SSH_KEY" ]; then
              export SOPS_AGE_KEY=$(${pkgs.ssh-to-age}/bin/ssh-to-age -private-key < "$USER_SSH_KEY")
              
              # Decrypt and export Plaid secrets
              eval $(sops -d --output-type json secrets.yaml | ${pkgs.jq}/bin/jq -r 'to_entries[] | select(.key | test("^PLAID")) | "export \(.key)=\(.value)"')
              
              export PLAID_ENV=sandbox
              echo "✅ Secrets decrypted via $USER_SSH_KEY"
            else
              echo "❌ SSH Key not found at $USER_SSH_KEY. Could not decrypt secrets."
            fi
          '';
        };

        defaultPackage = pkgs.stdenv.mkDerivation {
          name = "budget-backend";
          src = ./.;
          buildInputs =
            (with pkgs.ocamlPackages; [
              ocaml
              dune_3
              findlib
              dream
              yojson
              cohttp-lwt
              cohttp-lwt-unix
              lwt_ppx
              jose
              caqti
              caqti-lwt
              caqti-driver-sqlite3
              lwt # Added Lwt runtime library
            ])
            ++ [
              pkgs.sops
              pkgs.sqlite
            ];
          buildPhase = "dune build";
          installPhase = ''
            mkdir -p $out/bin
            cp _build/default/*.exe $out/bin/
          '';
        };
      }
    );
}
