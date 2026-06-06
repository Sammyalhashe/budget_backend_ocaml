{ pkgs, ... }:

{
  packages = (with pkgs.ocamlPackages; [
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
    lambda-term
  ]) ++ [
    pkgs.sops
    pkgs.sqlite
    pkgs.jq
    pkgs.ssh-to-age
  ];

  languages.ocaml.enable = true;

  enterShell = ''
    USER_SSH_KEY="$HOME/.ssh/id_ed25519"

    if [ -f "$USER_SSH_KEY" ]; then
      export SOPS_AGE_KEY=$(ssh-to-age -private-key < "$USER_SSH_KEY")

      eval $(sops -d --output-type json secrets.yaml 2>/dev/null | jq -r 'to_entries[] | select(.key | test("^PLAID")) | "export \(.key)=\(.value)"')

      export PLAID_ENV=sandbox
      echo "Secrets decrypted via $USER_SSH_KEY"
    else
      echo "SSH Key not found at $USER_SSH_KEY. Could not decrypt secrets."
    fi
  '';
}
