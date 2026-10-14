# Tidal Connect — cast endpoint for the TIDAL mobile app, outputting to the
# Bedroom speaker (Bluetooth, connected to sorbet by the bt-speaker user
# service).
#
# Tidal Connect is closed source and only exists as leaked armhf iFi binaries;
# there is no x86_64 build (verified across the whole ifi-tidal-release
# lineage in early 2026). So the arm image runs under qemu-user binfmt
# emulation on sorbet.
#
# Audio path (upstream targets a HifiBerry DAC on the Pi's own /dev/snd,
# which is impossible here twice over: sorbet has no such DAC, and kernel
# ALSA ioctls all fail with ENOTTY under qemu-user emulation):
#
#   container (ALSA "pulse" PCM) -> alsa-lib pulse plugin (injected armhf
#   libs, pkgs/tidal-connect-pulse-libs) -> host PipeWire pulse socket ->
#   default sink (the Bedroom speaker once bt-speaker has connected it).
#
# The pulse PCM comes from an /etc/asound.conf mounted into the container;
# config-defined devices with a `hint` block are listed by
# snd_device_name_hint without any kernel ioctls, so the binary's portaudio
# layer initializes under emulation and opens "pulse".
#
# Port 2019: the binary serves its control websocket on 2019 (the port it
# advertises via mDNS, which the TIDAL app connects to). Caddy's admin API
# must not use the 2019 default — services/caddy.nix pins it to 2020.
#
# Vendored scripts: ../../pkgs/tidal-connect-docker (TonyTromp
# tidal-connect-docker, adapted). The upstream volume-bridge is not vendored:
# it syncs phone volume to a hardware ALSA mixer, which does not exist here.
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
      pulseLibs = pkgs.callPackage ../../pkgs/tidal-connect-pulse-libs {};
      containerUnit = "${backend}-${containerName}";
      # ALSA config inside the container: redirect the "pulse" PCM to the
      # plugin (mounted below at alsa-lib's compiled plugin path) and expose
      # it to snd_device_name_hint. The !pulse override plus a live plugin
      # definition means portaudio's `pulse` device name resolves.
      asoundConf = pkgs.writeText "tidal-connect-asound.conf" ''
        pcm.!pulse {
          type pulse
          hint {
            show on
            description "PipeWire"
          }
        }
        ctl.!pulse {
          type pulse
        }
      '';
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

      virtualisation.oci-containers.containers.${containerName} = {
        inherit image;
        autoStart = true;
        environment = {
          FRIENDLY_NAME = friendlyName;
          MODEL_NAME = friendlyName;
          # "pulse" is an ALSA PCM defined in the mounted asound.conf, not a
          # hardware device.
          PLAYBACK_DEVICE = "pulse";
          MQA_PASSTHROUGH = "false";
          MQA_CODEC = "false";
          # The armhf pulse plugin + its dependency closure; alsa-lib 1.1.3
          # ignores ALSA_PLUGIN_DIR, so the libs must sit at the compiled
          # plugin path (volume mount below).
          LD_LIBRARY_PATH = "/usr/lib/arm-linux-gnueabihf/alsa-lib";
          # Host PipeWire's pulse socket (rootful container, so read through
          # the bind mount; the socket is world-accessible rw).
          PULSE_SERVER = "unix:/run/pulse/native";
        };
        volumes = [
          # Vendored entrypoint (same flags as upstream) over the image's copy
          "${scripts}/bin/entrypoint.sh:/entrypoint.sh:ro"
          # Pulse plugin + libs, at alsa-lib's compiled plugin dir
          "${pulseLibs}/alsa-lib:/usr/lib/arm-linux-gnueabihf/alsa-lib:ro"
          # "pulse" PCM definition (see asoundConf)
          "${asoundConf}:/etc/asound.conf:ro"
          # Host PipeWire pulse socket for audio output
          "/run/user/1000/pulse:/run/pulse"
          # avahi announce: the binary registers _tidalconnect._tcp through
          # the system bus (not the avahi socket directly), so dbus must be
          # mounted; the daemon socket dir comes along for good measure
          "/run/dbus:/var/run/dbus"
          "/run/avahi-daemon:/var/run/avahi-daemon"
        ];
        extraOptions = [
          # mDNS discovery must be visible on the LAN
          "--network=host"
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
