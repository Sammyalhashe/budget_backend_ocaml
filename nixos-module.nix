{ config, lib, pkgs, ... }:

let
  cfg = config.services.budget-backend;
  inherit (lib) mkEnableOption mkOption types;
in
{
  options.services.budget-backend = {
    enable = mkEnableOption "Budget Backend Service";

    package = mkOption {
      type = types.package;
      description = "The budget backend package to use.";
      default = pkgs.ocamlPackages.callPackage ./default.nix {};
    };

    port = mkOption {
      type = types.port;
      default = 5000;
      description = "Port to listen on.";
    };
    
    secretsFile = mkOption {
      type = types.path;
      default = ./secrets.yaml;
      description = "Path to the sops encrypted secrets file.";
    };
  };

  config = lib.mkIf cfg.enable {
    # Define sops secrets
    sops.secrets.PLAID_CLIENT_ID = {
      sopsFile = cfg.secretsFile;
      format = "yaml";
    };
    sops.secrets.PLAID_SECRET = {
      sopsFile = cfg.secretsFile;
      format = "yaml";
    };

    # Create an environment file template
    sops.templates."budget-backend.env".content = ''
      PLAID_CLIENT_ID=${config.sops.placeholder.PLAID_CLIENT_ID}
      PLAID_SECRET=${config.sops.placeholder.PLAID_SECRET}
      PORT=${toString cfg.port}
    '';

    # Create a system user for the service
    users.users.budget-backend = {
      isSystemUser = true;
      group = "budget-backend";
      description = "Budget Backend Service User";
    };
    users.groups.budget-backend = {};

    systemd.services.budget-backend = {
      description = "Budget Backend Service";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" ];
      
      serviceConfig = {
        ExecStart = "${cfg.package}/bin/main.exe";
        User = "budget-backend";
        Group = "budget-backend";
        Restart = "always";
        
        # Load environment variables from the generated template file
        EnvironmentFile = config.sops.templates."budget-backend.env".path;
        
        # Security hardening
        DynamicUser = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
      };
    };
  };
}
