# Self-hosted GitHub runner on sorbet + the actions-deploy script it triggers.
# actions-deploy rebuilds sorbet, then deploys eclair from sorbet via
# deploy-rs (built here — never on the 1-vCPU VPS) over the tailnet.
{inputs, ...}: {
  flake.nixosModules.gh_runner = {
    config,
    pkgs,
    ...
  }: {
    sops.secrets = {
      "gh_runner" = {
        sopsFile = ../../secrets/sorbet/github-runner;
        format = "binary";
        key = "";
      };

      "deploy_webhook" = {
        sopsFile = ../../secrets/shared/deploy-webhook;
        format = "binary";
        key = "";
        owner = "root";
      };

      # Dedicated ed25519 key for deploying eclair from CI. Pubkey lives in
      # modules/hosts/eclair/configuration.nix.
      "eclair-deploy-key" = {
        sopsFile = ../../secrets/sorbet/eclair-deploy-key;
        format = "binary";
        key = "";
        owner = "root";
        mode = "0600";
      };
    };

    environment.systemPackages = [
      (pkgs.writeShellApplication {
        name = "actions-deploy";
        runtimeInputs = [
          pkgs.curl
          pkgs.jq
          pkgs.dix
          pkgs.coreutils
          pkgs.openssh
          # Pinned to the flake input rather than resolved via the registry.
          inputs.deploy-rs.packages.x86_64-linux.deploy-rs
        ];
        text = ''
          WEBHOOK=$(cat ${config.sops.secrets."deploy_webhook".path})

          OLD=$(find /nix/var/nix/profiles -maxdepth 1 -name 'system-*-link' | sort -t- -k2 -n | tail -1)

          EXIT=0
          nixos-rebuild switch --flake "github:KuiprLab/sorbet.nix#sorbet" > /tmp/deploy.log 2>&1 || EXIT=$?

          NEW=/run/current-system

          DIFF=$(dix --color never "''${OLD}" "''${NEW}" 2>/dev/null || echo "Could not generate diff")

          # Deploy eclair from here over the tailnet. Building happens on
          # sorbet (remoteBuild = false on the eclair node), the VPS only
          # receives the closure.
          ECLAIR_EXIT=0
          deploy -s "github:KuiprLab/sorbet.nix#eclair" \
            --ssh-opts "-o StrictHostKeyChecking=accept-new -i ${config.sops.secrets."eclair-deploy-key".path}" \
            > /tmp/deploy-eclair.log 2>&1 || ECLAIR_EXIT=$?

          if [ "''${EXIT}" -eq 0 ]; then
            SORBET_STATUS="SUCCESS: sorbet deploy succeeded"
          else
            SORBET_STATUS="FAILED: sorbet deploy failed (exit ''${EXIT})"
          fi
          if [ "''${ECLAIR_EXIT}" -eq 0 ]; then
            ECLAIR_STATUS="SUCCESS: eclair deploy succeeded"
          else
            ECLAIR_STATUS="FAILED: eclair deploy failed (exit ''${ECLAIR_EXIT})"
          fi

          if [ "''${EXIT}" -eq 0 ] && [ "''${ECLAIR_EXIT}" -eq 0 ]; then
            # Skip notification when nothing changed on sorbet
            if [ -z "''${DIFF}" ]; then
              exit 0
            fi
            BODY=$(printf "%s\n%s\n%s\n%s\n%s\n%s" \
              "''${SORBET_STATUS}" \
              "''${ECLAIR_STATUS}" \
              "**Changes (sorbet):**" \
              '```diff' \
              "''${DIFF}" \
              '```')
          else
            if [ "''${EXIT}" -ne 0 ]; then
              ERRORS=$(tail -20 /tmp/deploy.log)
            else
              ERRORS=$(tail -20 /tmp/deploy-eclair.log)
            fi
            BODY=$(printf "%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s\n%s" \
              "''${SORBET_STATUS}" \
              "''${ECLAIR_STATUS}" \
              "**Changes attempted (sorbet):**" \
              '```diff' \
              "''${DIFF}" \
              '```' \
              "**Error:**" \
              '```' \
              "''${ERRORS}" \
              '```')
          fi

          CONTENT=$(printf '%s' "''${BODY}" | head -c 1900)

          curl -s -X POST "''${WEBHOOK}" \
            -H "Content-Type: application/json" \
            -d "{\"content\": $(printf '%s' "''${CONTENT}" | jq -Rs .)}"
        '';
      })
    ];

    services.github-runners = {
      deploy = {
        enable = true;
        name = "deploy-runner";
        tokenFile = config.sops.secrets."gh_runner".path;
        url = "https://github.com/KuiprLab/sorbet.nix";
        serviceOverrides = {
          restartIfChanged = false;
          X-StopOnReconfiguration = false;
        };
      };
    };
  };
}
