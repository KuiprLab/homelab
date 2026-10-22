{inputs, ...}: let
  # comin supports one testing branch per host. The `.github/workflows/testing.yml`
  # workflow moves `testing/<host>` when a `testing/<host>/<feature>` branch is
  # pushed, so the agent still only has to poll a fixed ref.
  cominModule = {
    config,
    pkgs,
    ...
  }: {
    imports = [inputs.comin.nixosModules.comin];

    sops.secrets."deploy_webhook" = {
      sopsFile = ../secrets/shared/deploy-webhook;
      format = "binary";
      key = "";
      owner = "root";
    };

    services.comin = {
      enable = true;
      package = inputs.comin.packages.${pkgs.stdenv.hostPlatform.system}.comin;

      remotes = [
        {
          name = "origin";
          url = "https://github.com/KuiprLab/homelab.git";
          poller.period = 300;
          branches = {
            main = {
              name = "main";
              operation = "switch";
            };
            testing = {
              name = "testing/${config.networking.hostName}";
              operation = "test";
            };
          };
        }
      ];

      # Accept the user's SSH-signed commits and merge commits created by
      # GitHub. comin verifies the selected commit against either source.
      gpgPublicKeyPaths = ["${../keys/github-web-flow.asc}"];
      sshAllowedSignersPath = "${../keys/allowed_signers}";

      postDeploymentCommand = "${pkgs.writeShellApplication {
        name = "comin-notify";
        runtimeInputs = [
          pkgs.coreutils
          pkgs.curl
          pkgs.jq
        ];
        text = ''
          case "''${COMIN_STATUS:-}" in
            done) icon="✅" ;;
            failed) icon="❌" ;;
            *) exit 0 ;;
          esac

          webhook=$(cat ${config.sops.secrets."deploy_webhook".path})

          body=$(printf '%s %s %s\n%s\n\n%s\n%s' \
            "$icon" \
            "$COMIN_HOSTNAME" \
            "$COMIN_STATUS" \
            "commit: \`''${COMIN_GIT_SHA:0:7}\` on \`$COMIN_GIT_REF\`" \
            "$COMIN_GIT_MSG" \
            "''${COMIN_ERROR_MSG:-}")
          content=$(printf '%s' "$body" | cut -c1-1900)

          jq -n --arg content "$content" '{content: $content}' \
            | curl -fsS --max-time 15 --retry 2 -X POST "$webhook" \
                -H 'Content-Type: application/json' \
                -d @-
        '';
      }}/bin/comin-notify";
    };
  };
in {
  flake.nixosModules.comin = cominModule;
  flake.eclairNixosModules.comin = cominModule;
}
