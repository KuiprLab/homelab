# Not containerized: comin is the deploy mechanism itself. A container would
# have to rebuild and switch the host it runs on.
{inputs, ...}: let
  # comin supports one testing branch per host. The name is `testing-<host>`
  # and not `testing/<host>`: git cannot hold `testing/sorbet` and
  # `testing/sorbet/<feature>` at once, and the collision is fatal, not
  # cosmetic -- a fetch that meets both refs leaves a directory where the
  # branch ref has to be written, which breaks every later fetch (including
  # `main`). Feature branches therefore live under `feat/` or `fix/`; the
  # commit to test is pushed to `testing-<host>` itself.
  cominModule = {
    config,
    pkgs,
    ...
  }: let
    # Sorbet posts directly to the local container; eclair has to go through
    # Pangolin. The token is written by gotify-provision.service.
    gotifyBase =
      if config.networking.hostName == "sorbet"
      then "http://127.0.0.1:8085"
      else "https://gotify.ext.kuipr.de";
    gotifyTokenFile = "/var/lib/gotify-provision/comin-${config.networking.hostName}.token";
  in {
    imports = [inputs.comin.nixosModules.comin];

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
              name = "testing-${config.networking.hostName}";
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
            done) icon="✅"; priority=5; status_word="succeeded" ;;
            failed) icon="❌"; priority=8; status_word="failed" ;;
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

          token_file=${gotifyTokenFile}
          if [ ! -s "$token_file" ]; then
            echo "gotify token not provisioned yet; skipping notification" >&2
            exit 0
          fi
          GOTIFY_TOKEN=$(cat "$token_file")

          gotify_url="${gotifyBase}/message?token=$GOTIFY_TOKEN"
          host="''${COMIN_HOSTNAME:-unknown}"
          sha="''${COMIN_GIT_SHA:-}"
          commit_url="https://github.com/KuiprLab/homelab/commit/$sha"

          message=$(jq -nr \
            --arg status "''${COMIN_STATUS:-}" \
            --arg sha "$sha" \
            --arg ref "''${COMIN_GIT_REF:-unknown}" \
            --arg msg "''${COMIN_GIT_MSG:-}" \
            --arg err "''${COMIN_ERROR_MSG:-}" \
            --arg reboot "$reboot" \
            --arg gen "''${COMIN_GENERATION:-}" \
            --arg commit_url "$commit_url" \
            '
              "**Commit:** " +
              (if $sha == "" then "unknown"
               else "[`" + ($sha[0:7]) + "`](" + $commit_url + ")" end) +
              "\n**Branch:** `" + $ref + "`" +
              "\n**Reboot:** " + (
                if $reboot == "yes" then "⚠️ **required**"
                elif $reboot == "no" then "✅ not required"
                else "❔ unknown" end) +
              "\n**Generation:** " + $gen +
              (if $status == "done" then
                 (if $msg == "" then "\n\n_No commit message._"
                  else "\n\n> " + ($msg | gsub("\n"; "\n> ")) end)
               else
                 "\n\n**Error**\n" +
                 (if $err == "" then "_No error message._"
                  else "> " + ($err | gsub("\n"; "\n> ")) end)
               end)
            ')

          jq -n \
            --arg title "$icon $host — deployment $status_word" \
            --arg message "$message" \
            --argjson priority "$priority" \
            '{title: $title, message: $message, priority: $priority, extras: {"client::display": {contentType: "text/markdown"}}}' \
            | curl -fsS --max-time 15 --retry 2 -X POST "$gotify_url" \
                -H 'Content-Type: application/json' \
                -d @- \
            || echo "gotify notification failed" >&2
        '';
      }}/bin/comin-notify";
    };
  };
in {
  flake.nixosModules.comin = cominModule;
  flake.eclairNixosModules.comin = cominModule;
}
