# Reconcile Gotify applications and tokens.
#
# Gotify has no declarative app/token config; applications are SQLite rows.
# This timer creates the applications declared in Nix and writes their tokens
# to /var/lib/gotify-provision. Tokens never enter git.
#
# Icons are names from selfh.st/icons (or full URLs) in Nix. Gotify only
# accepts an uploaded image, not an icon URL, so the reconciler resolves the
# name to https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/<name>.png and
# POSTs it to /application/<id>/image. A reference file and a hash prevent a
# re-upload on every run. Supported formats: PNG, JPEG, GIF. Gotify does not
# accept SVG or WebP.
#
# The reconciler authenticates with HTTP Basic auth, so the Gotify container
# keeps GOTIFY_LOCALAUTH_ENABLED=true. The web UI still uses OIDC because
# GOTIFY_OIDC_AUTO_REDIRECT is set. There are two local users:
#
#   admin  -- sops password, used only to create/update the provision user.
#   daniel -- sops password, owns the applications. It is the same username
#             as the Authelia user, and GOTIFY_OIDC_LINK_BY_USERNAME=true
#             links the OIDC identity to it. The iOS client token is therefore
#             owned by the same user as the applications.
#
# A failed run exits 0: a missing Gotify must not abort a deployment. The
# timer retries every five minutes.
_: let
  mkProvision = {
    apps,
    baseUrl,
    gotifyDeps ? [],
    defineAdminSecret ? false,
  }: {
    config,
    lib,
    pkgs,
    ...
  }: let
    provisionUser = "daniel";
    script = pkgs.writeShellApplication {
      name = "gotify-provision";
      runtimeInputs = [pkgs.curl pkgs.jq pkgs.coreutils];
      text = ''
        BASE=${baseUrl}
        TOKEN_DIR=/var/lib/gotify-provision
        APPS_JSON=${lib.escapeShellArg (builtins.toJSON apps)}
        USER_NAME=${lib.escapeShellArg provisionUser}

        # Wait for Gotify. A missing server is a retry, not a failure.
        ready=false
        for _ in $(seq 1 60); do
          if curl -fsS --max-time 5 "$BASE/health" >/dev/null 2>&1; then
            ready=true
            break
          fi
          sleep 2
        done
        if [ "$ready" != true ]; then
          echo "gotify not reachable at $BASE; retrying on the next timer run" >&2
          exit 0
        fi

        set -a
        # shellcheck disable=SC1091
        . ${config.sops.secrets."gotify/admin".path}
        set +a

        admin_pass="$GOTIFY_DEFAULTUSER_PASS"
        user_pass="$GOTIFY_PROVISION_USER_PASS"

        admin_api() {
          curl -fsS --max-time 15 -u "admin:$admin_pass" \
            -H 'Content-Type: application/json' "$@"
        }

        user_api() {
          curl -fsS --max-time 15 -u "$USER_NAME:$user_pass" \
            -H 'Content-Type: application/json' "$@"
        }

        user_upload() {
          curl -fsS --max-time 30 -u "$USER_NAME:$user_pass" "$@"
        }

        # Ensure the local provision user exists and has the sops password.
        # If the OIDC login auto-registered the user first, this adds a local
        # password to that same row instead of creating a duplicate.
        users=$(admin_api "$BASE/user" 2>/dev/null || true)
        if [ -z "$users" ]; then
          echo "could not list gotify users; retrying on the next timer run" >&2
          exit 0
        fi
        user_id=$(printf '%s' "$users" | jq -r --arg n "$USER_NAME" '.[] | select(.name == $n) | .id' | head -n1)
        if [ -z "$user_id" ]; then
          admin_api -X POST "$BASE/user" \
            -d "$(jq -n --arg n "$USER_NAME" --arg p "$user_pass" '{name: $n, pass: $p, admin: true}')" \
            >/dev/null 2>&1 || true
        else
          admin_api -X POST "$BASE/user/$user_id" \
            -d "$(jq -n --arg n "$USER_NAME" --arg p "$user_pass" '{name: $n, pass: $p, admin: true}')" \
            >/dev/null 2>&1 || true
        fi

        apps_json=$(user_api "$BASE/application" 2>/dev/null || true)
        if [ -z "$apps_json" ]; then
          echo "could not list gotify applications as $USER_NAME; retrying on the next timer run" >&2
          exit 0
        fi

        mapfile -t APPS < <(jq -r 'keys[]' <<<"$APPS_JSON")
        for app in "''${APPS[@]}"; do
          token_file="$TOKEN_DIR/$app.token"
          icon_ref=$(jq -r --arg n "$app" '.[$n].icon // empty' <<<"$APPS_JSON")
          id=$(printf '%s' "$apps_json" | jq -r --arg n "$app" '.[] | select(.name == $n) | .id' | head -n1)

          if [ -n "$id" ] && [ -s "$token_file" ]; then
            echo "gotify app $app already provisioned"
          else
            token=""
            if [ -n "$id" ]; then
              token=$(user_api -X PUT "$BASE/application/$id/security" \
                -d '{"regenerateToken":true}' 2>/dev/null \
                | jq -r '.regenerateToken.token // empty' 2>/dev/null || true)
            else
              response=$(user_api -X POST "$BASE/application" \
                -d "$(jq -n --arg n "$app" '{name: $n}')" 2>/dev/null || true)
              token=$(printf '%s' "$response" | jq -r '.token // empty' 2>/dev/null || true)
              id=$(printf '%s' "$response" | jq -r '.id // empty' 2>/dev/null || true)
            fi

            if [ -z "$token" ]; then
              echo "could not provision gotify app $app" >&2
              continue
            fi

            install -m 0400 /dev/null "$token_file"
            printf '%s' "$token" > "$token_file"
            echo "provisioned gotify app $app"

            if [ "$app" = "beets" ]; then
              install -m 0400 /dev/null "$TOKEN_DIR/beets.env"
              printf 'GOTIFY_TOKEN=%s\n' "$token" > "$TOKEN_DIR/beets.env"
            fi
          fi

          if [ -n "$icon_ref" ] && [ -n "$id" ]; then
            case "$icon_ref" in
              http://*|https://*) icon_url="$icon_ref" ;;
              *) icon_url="https://cdn.jsdelivr.net/gh/selfhst/icons@main/png/$icon_ref.png" ;;
            esac
            icon_file="$TOKEN_DIR/$app.icon"
            hash_file="$TOKEN_DIR/$app.icon.sha256"
            ref_file="$TOKEN_DIR/$app.icon.ref"
            current_image=$(printf '%s' "$apps_json" | jq -r --arg n "$app" '.[] | select(.name == $n) | .image' | head -n1)
            old_ref=$(cat "$ref_file" 2>/dev/null || true)

            # Skip the download when the app already has a custom image and
            # the configured icon reference did not change. This avoids
            # hammering the icon CDN every five minutes.
            if [ "$current_image" != "static/defaultapp.png" ] && [ "$icon_ref" = "$old_ref" ] && [ -s "$hash_file" ]; then
              :
            elif curl -fsSL --max-time 20 "$icon_url" -o "$icon_file"; then
              hash=$(sha256sum "$icon_file" | cut -d' ' -f1)
              if user_upload -X POST "$BASE/application/$id/image" \
                -F "file=@$icon_file;filename=icon.png" >/dev/null 2>&1; then
                install -m 0400 /dev/null "$hash_file"
                printf '%s' "$hash" > "$hash_file"
                install -m 0400 /dev/null "$ref_file"
                printf '%s' "$icon_ref" > "$ref_file"
                echo "uploaded icon for $app"
              else
                echo "could not upload icon for $app" >&2
              fi
            else
              echo "could not download icon for $app" >&2
            fi
          fi
        done
      '';
    };
  in {
    sops.secrets = lib.optionalAttrs defineAdminSecret {
      "gotify/admin" = {
        sopsFile = ../../secrets/shared/gotify-admin.env;
        format = "dotenv";
        key = "";
        owner = "root";
      };
    };

    systemd.services.gotify-provision = {
      description = "Reconcile Gotify applications and tokens";
      after = ["network-online.target"] ++ gotifyDeps;
      wants = ["network-online.target"] ++ gotifyDeps;
      serviceConfig = {
        Type = "oneshot";
        StateDirectory = "gotify-provision";
        StateDirectoryMode = "0700";
        ExecStart = lib.getExe script;
      };
    };

    systemd.timers.gotify-provision = {
      description = "Reconcile Gotify applications every five minutes";
      wantedBy = ["timers.target"];
      timerConfig = {
        OnBootSec = "30s";
        OnUnitActiveSec = "5min";
        Persistent = true;
      };
    };
  };
in {
  flake.nixosModules.gotifyProvision = mkProvision {
    apps = {
      comin-sorbet = {
        icon = "nixos";
      };
      beets = {
        icon = "beets";
      };
      healthchecks = {
        icon = "healthchecks";
      };
      beszel = {
        icon = "beszel";
      };
    };
    baseUrl = "http://127.0.0.1:8085";
    gotifyDeps = ["podman-gotify.service"];
  };

  flake.eclairNixosModules.gotifyProvision = mkProvision {
    apps = {
      comin-eclair = {
        icon = "nixos";
      };
    };
    baseUrl = "https://gotify.ext.kuipr.de";
    defineAdminSecret = true;
  };
}
