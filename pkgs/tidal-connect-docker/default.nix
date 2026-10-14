{
  lib,
  stdenvNoCC,
}:
# Vendored orchestration scripts from TonyTromp/tidal-connect-docker
# (rev 690b76ff8c6596f2e66b347b875544e5607ca645, 2025-12-21).
#
# Only the shell scripts are vendored. The docker image itself (armhf
# binaries, no x86_64 build of Tidal Connect exists) is pulled prebuilt and
# runs under binfmt/qemu emulation; see services/music/tidal-connect.nix.
#
# Adaptations for NixOS:
#   - docker CLI replaced with podman (sorbet exposes podman via the
#     docker-compat socket)
#   - the watchdog restarts the service through the oci-containers systemd
#     unit instead of docker-compose (unit name via TIDAL_UNIT env)
#   - logs go to the journal, not /var/log
#   - dropped: Beocreate/AudioControl2 integration, docker-compose/.env
#     generation, volume-bridge (the snd-aloop loopback device has no
#     hardware mixer for it to sync)
#
# entrypoint.sh keeps its upstream shebang on purpose: it runs inside the
# debian-based container, not on the host. The host-side scripts are
# patchShebangs'd so systemd can exec them directly.
stdenvNoCC.mkDerivation {
  pname = "tidal-connect-docker-scripts";
  version = "unstable-2025-12-21";

  src = lib.cleanSource ./scripts;

  installPhase = ''
    mkdir -p $out/bin
    for f in *; do
      install -m755 "$f" "$out/bin/$f"
    done
  '';

  postFixup = ''
    patchShebangs --host $out/bin/wait-for-avahi.sh \
      $out/bin/wait-for-mdns-clear.sh \
      $out/bin/tidal-watchdog.sh \
      $out/bin/check-tidal-status.sh
  '';
}
