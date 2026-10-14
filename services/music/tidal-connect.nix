# Tidal Connect — cast endpoint for the TIDAL mobile app, outputting to the
# Bedroom speaker (Bluetooth, connected to sorbet by the bt-speaker user
# service).
#
# Tidal Connect is closed source and only exists as leaked armhf iFi binaries;
# there is no x86_64 build (verified across the whole ifi-tidal-release
# lineage in early 2026). So the arm image runs under qemu-user binfmt
# emulation on sorbet.
#
# Audio path (upstream targets a HifiBerry DAC on the Pi's own /dev/snd):
#   container (ALSA hw) -> snd-aloop kernel loopback -> PipeWire loopback
#   module -> default sink (the BT speaker once connected).
# The container gets /dev/snd but only plays to the Loopback card, so it does
# not fight PipeWire for the real hardware.
#
# Vendored scripts: ../../pkgs/tidal-connect-docker (TonyTromp
# tidal-connect-docker, adapted). The upstream volume-bridge is not vendored:
# it syncs phone volume to a hardware ALSA mixer, which the loopback card
# does not have.
{lib, ...}: let
  friendlyName = "Bedroom";
  containerName = "tidal-connect";
  # The image is armhf-only; digest pins the arm/linux manifest.
  image = "docker.io/edgecrush3r/tidal-connect@sha256:4c4cf9508d947306f3ce2d7c8766392197fa19f046a5a88e79428b8974c2dbcc";
in {
  flake = {
    nixosModules.tidal-connect = {
      config,
      pkgs,
      ...
    }: let
      inherit (config.virtualisation.oci-containers) backend;
      scripts = pkgs.callPackage ../../pkgs/tidal-connect-docker {};
      containerUnit = "${backend}-${containerName}";
    in {
      # qemu-user emulation for the armhf container. preferStaticEmulators is
      # required, not optional: without a static emulator the binfmt rule
      # lacks the fix-binary (F) flag, so the kernel tries to resolve the
      # qemu interpreter inside the container and every exec dies with ENOENT
      # ("exec container process ... No such file or directory").
      boot.binfmt = {
        emulatedSystems = ["armv7l-linux"];
        preferStaticEmulators = true;
      };

      # Loopback sound card the container plays into. PipeWire captures the
      # other side of the loopback below.
      boot.kernelModules = ["snd-aloop"];

      # Bridge the loopback card into PipeWire: capture from the card's ALSA
      # source node, play to the default sink. No playback target is set on
      # purpose, so the stream follows the default sink (the Bedroom speaker
      # when bt-speaker has connected it).
      services.pipewire.extraConfig.pipewire."10-tidal-connect-loopback" = {
        "context.modules" = [
          {
            "name" = "libpipewire-module-loopback";
            "args" = {
              "node.description" = "Tidal Connect";
              "capture.props" = {
                "node.name" = "tidal-connect-capture";
                "node.target" = "alsa_input.platform-snd_aloop.0.analog-stereo";
                "audio.position" = ["FL" "FR"];
              };
              "playback.props" = {
                "node.name" = "tidal-connect-playback";
                "audio.position" = ["FL" "FR"];
              };
            };
          }
        ];
      };

      virtualisation.oci-containers.containers.${containerName} = {
        inherit image;
        autoStart = true;
        environment = {
          FRIENDLY_NAME = friendlyName;
          MODEL_NAME = friendlyName;
          # Inside the container this is an ALSA device string; the loopback
          # card is the only thing it is allowed to open.
          PLAYBACK_DEVICE = "hw:CARD=Loopback,DEV=0";
          MQA_PASSTHROUGH = "false";
          MQA_CODEC = "false";
        };
        volumes = [
          # Vendored entrypoint (same flags as upstream) over the image's copy
          "${scripts}/bin/entrypoint.sh:/entrypoint.sh:ro"
          # The arm binary talks to the host avahi daemon over its socket for
          # mDNS registration (host networking alone does not expose it)
          "/var/run/avahi-daemon/socket:/var/run/avahi-daemon/socket"
        ];
        extraOptions = [
          # mDNS discovery must be visible on the LAN
          "--network=host"
          "--device=/dev/snd"
        ];
      };

      systemd.services.${containerUnit} = {
        after = ["avahi-daemon.service"];
        # wait-for-mdns-clear.sh probes registrations with avahi-browse
        path = [pkgs.avahi];
        # Vendored guards: don't race avahi at boot and don't collide with a
        # stale mDNS registration after rapid restarts / hard power-offs.
        preStart = ''
          ${scripts}/bin/wait-for-avahi.sh
          ${scripts}/bin/wait-for-mdns-clear.sh ${lib.escapeShellArg friendlyName}
        '';
      };

      systemd.services.tidal-watchdog = {
        description = "Tidal Connect watchdog";
        after = ["${containerUnit}.service"];
        wantedBy = ["multi-user.target"];
        path = [pkgs.podman];
        environment = {
          CONTAINER_NAME = containerName;
          TIDAL_UNIT = containerUnit;
        };
        serviceConfig = {
          ExecStart = "${scripts}/bin/tidal-watchdog.sh";
          Restart = "always";
          # No hardening: the watchdog must be able to systemctl-restart the
          # container unit and needs full podman access.
        };
      };
    };
  };
}
