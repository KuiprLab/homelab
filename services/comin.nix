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
          timeout = 300;
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

          # comin computes this internally, but does not export it to post hooks.
          # For switch/test, /run/current-system is updated after activation;
          # a kernel mismatch means the running kernel is still the old one.
          reboot="unknown"
          if [ -e /run/current-system/kernel ] && [ -e /run/booted-system/kernel ]; then
            current_kernel=$(readlink -f /run/current-system/kernel 2>/dev/null || true)
            booted_kernel=$(readlink -f /run/booted-system/kernel 2>/dev/null || true)
            if [ -n "$current_kernel" ] && [ -n "$booted_kernel" ]; then
              if [ "$current_kernel" = "$booted_kernel" ]; then
                reboot="no"
              else
                reboot="yes"
              fi
            fi
          fi

          webhook=$(cat ${config.sops.secrets."deploy_webhook".path})
          commit_url="https://github.com/KuiprLab/homelab/commit/''${COMIN_GIT_SHA:-}"

          jq -n \
            --arg icon "$icon" \
            --arg host "''${COMIN_HOSTNAME:-unknown}" \
            --arg status "''${COMIN_STATUS:-}" \
            --arg sha "''${COMIN_GIT_SHA:-}" \
            --arg ref "''${COMIN_GIT_REF:-unknown}" \
            --arg msg "''${COMIN_GIT_MSG:-}" \
            --arg err "''${COMIN_ERROR_MSG:-}" \
            --arg reboot "$reboot" \
            --arg gen "''${COMIN_GENERATION:-}" \
            --arg commit_url "$commit_url" \
            '
              {
                embeds: [
                  {
                    title: (($icon + " " + $host + " — deployment " +
                      (if $status == "done" then "succeeded" else "failed" end))[0:256]),
                    description: (
                      if $status == "done" then
                        (if $msg == "" then "_No commit message._"
                         else "> " + ($msg | gsub("\n"; "\n> ")) end)
                      else
                        ("**Error**\n" +
                         (if $err == "" then "_No error message._"
                          else "> " + ($err | gsub("\n"; "\n> ")) end))
                      end
                    )[0:4000],
                    color: (if $status == "done" then 3066993 else 15158332 end),
                    fields: [
                      {
                        name: "Commit",
                        value: (if $sha == "" then "unknown"
                                else "[`" + ($sha[0:7]) + "`](" + $commit_url + ")" end),
                        inline: true
                      },
                      {name: "Branch", value: ("`" + $ref + "`"), inline: true},
                      {
                        name: "Reboot",
                        value: (if $reboot == "yes" then "⚠️ **required**"
                                elif $reboot == "no" then "✅ not required"
                                else "❔ unknown" end),
                        inline: true
                      }
                    ],
                    footer: {text: ("comin • " + $gen)},
                    timestamp: (now | todate)
                  }
                  + (if $sha == "" then {} else {url: $commit_url} end)
                ]
              }' \
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
