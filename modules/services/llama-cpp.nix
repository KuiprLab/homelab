{
  lib,
  config,
  ...
}: let
  inherit (lib) types;

  # ---- Process models in flake-parts scope ----
  models = config.flake.llamaCppModels;
  buildModels = builtins.filter (m: m.hash != null) models;
  runtimeModels = builtins.filter (m: m.hash == null) models;
in {
  options.flake = {
    llamaCppModels = lib.mkOption {
      type = types.listOf (
        types.submodule {
          options = {
            name = lib.mkOption {
              type = types.str;
              description = "Model label (used as filename in the store).";
            };
            url = lib.mkOption {
              type = types.str;
              description = "URL to the GGUF file on Hugging Face.";
            };
            hash = lib.mkOption {
              type = types.nullOr types.str;
              default = null;
              example = "sha256-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=";
              description = ''
                SHA256 SRI hash for build-time verification.
                If null, a runtime download service is used instead.
              '';
            };
          };
        }
      );
      default = [];
      description = "llama.cpp GGUF model definitions. Auto-downloaded.";
    };
  };

  config.flake = {
    caddyVirtualHosts."ai.int.kuipr.de" = {
      extraConfig = ''
        reverse_proxy 127.0.0.1:5890
      '';
      name = "Llama.cpp";
    };

    llamaCppModels = [
      {
        name = "Gemma";
        url = "https://huggingface.co/bartowski/google_gemma-4-E2B-it-GGUF/resolve/main/google_gemma-4-E2B-it-Q4_K_M.gguf?download=true";

        # Runtime download (no hash) — file is ~6GB, stored in /var/lib/llama-cpp/models/
        hash = null;
      }
    ];

    # Inner NixOS module — config here is NixOS config, NOT flake-parts config.
    # models/buildModels/runtimeModels are captured from the outer let (flake-parts scope).
    nixosModules.llama-cpp = {pkgs, ...}: let
      # Nix store paths for hashed models (pkgs.fetchurl only available in NixOS module scope)
      fetchedModels = builtins.listToAttrs (
        map (m: {
          inherit (m) name;
          value = pkgs.fetchurl {inherit (m) url hash;};
        })
        buildModels
      );

      # Primary model path = first model in the list
      primaryModel = lib.lists.optional (models != []) (
        if (builtins.head models).hash != null
        then "${fetchedModels.${(builtins.head models).name}}"
        else "/var/lib/llama-cpp/models/${(builtins.head models).name}.gguf"
      );
    in {
      hardware.graphics.extraPackages = with pkgs; [
        intel-compute-runtime
        vulkan-intel
      ];

      services = {
        open-webui = {
          enable = true;
          host = "0.0.0.0";
          environment = {
            ANONYMIZED_TELEMETRY = "False";
            DO_NOT_TRACK = "True";
            SCARF_NO_ANALYTICS = "True";
            # llama.cpp serves an OpenAI-compatible API, not the Ollama protocol
            OPENAI_API_BASE_URL = "http://127.0.0.1:1337/v1";
            OPENAI_API_KEY = "sk-no-key-required";
            # Disable authentication
            WEBUI_AUTH = "False";
          };
          openFirewall = true;
          port = 5890;
        };

        llama-cpp = {
          enable = true;
          package = pkgs.llama-cpp-vulkan;
          settings =
            {
              host = "127.0.0.1";
              port = 1337;
              n-gpu-layers = 999;
            }
            // lib.optionalAttrs (models != []) {
              model = lib.head primaryModel;
            };
        };
      };

      # ---- Runtime download for models without hash ----
      # No StateDirectory here — main service owns that. Script creates dir manually.
      systemd.services.llama-cpp-download = lib.mkIf (runtimeModels != []) {
        description = "Download llama.cpp GGUF models";
        before = ["llama-cpp.service"];
        requiredBy = ["llama-cpp.service"];
        unitConfig.RequiresMountsFor = "/var/lib/llama-cpp";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p /var/lib/llama-cpp/models
          ${builtins.concatStringsSep "\n" (
            map (m: ''
              if [ ! -f /var/lib/llama-cpp/models/${m.name}.gguf ]; then
                echo "Downloading ${m.name}..."
                ${pkgs.curl}/bin/curl -fLo /var/lib/llama-cpp/models/${m.name}.gguf \
                  "${m.url}"
                chmod 644 /var/lib/llama-cpp/models/${m.name}.gguf
              fi
            '')
            runtimeModels
          )}
        '';
      };

      # ---- Symlink Nix-store models into state dir ----
      systemd.services.llama-cpp-provision = lib.mkIf (buildModels != []) {
        description = "Provision Nix-store models for llama-cpp";
        before = ["llama-cpp.service"];
        requiredBy = ["llama-cpp.service"];
        after = ["llama-cpp-download.service"];
        unitConfig.RequiresMountsFor = "/var/lib/llama-cpp";
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
        };
        script = ''
          mkdir -p /var/lib/llama-cpp/models
          ${builtins.concatStringsSep "\n" (
            map (m: ''
              ln -sf ${fetchedModels.${m.name}} /var/lib/llama-cpp/models/${m.name}.gguf
            '')
            buildModels
          )}
        '';
      };
    };
  };
}
