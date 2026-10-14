{
  lib,
  stdenvNoCC,
  libarchive,
  xz,
  fetchurl,
}:
# ARMhf libpulse + alsa-lib pulse plugin, extracted from Debian (Stretch)
# archive debs and shipped as a flat library directory.
#
# Why: the Tidal Connect container image is Raspbian Stretch armhf with only
# a bare libasound 2. alsa-lib 1.1.x loads PCM plugins from the compiled-in
# path /usr/lib/arm-linux-gnueabihf/alsa-lib/ and ignores the
# ALSA_PLUGIN_DIR env var (verified with 1.1.3), so this whole directory is
# bind-mounted over that path inside the container (ro). The pulse plugin
# then opens the host PipeWire pulse socket instead of kernel ALSA, which is
# impossible under qemu-user (every ALSA control ioctl returns ENOTTY).
#
# The TIDAL binary's portaudio layer enumerates devices via
# snd_device_name_hint; config-defined devices with a `hint` block (the
# asound.conf mounted by services/music/tidal-connect.nix) are listed
# without any kernel ioctls, so "pulse" shows up in the device list and
# portaudio initializes.
#
# Dependency closure (SONAMEs of libasound_module_pcm_pulse.so, computed
# with /lib/ld-linux-armhf.so.3 --list inside the container): libpulse +
# libpulsecommon (X11 chain: Xtst Xi Xfixes X11 X11-xcb xcb Xau Xdmcp),
# dbus+expat, cap, asyncns, sndfile(+FLAC ogg vorbis vorbisenc), systemd
# (+lzma lz4 gcrypt gpg-error), wrap, selinux(+pcre). glibc-provided
# (libc, libgcc_s, libnsl, libresolv) come from the image itself.
stdenvNoCC.mkDerivation {
  pname = "tidal-connect-pulse-libs";
  version = "stretch";

  # Debian Stretch (armhf) debs from archive.debian.org, matching the image's
  # Raspbian Stretch ABI. Filenames URL-encode the epoch prefix (%3a = ':').
  srcs =
    map (
      {
        sub,
        name,
        hash,
      }:
        fetchurl {
          url = "http://archive.debian.org/debian/pool/main/${sub}/${name}";
          inherit hash;
        }
    ) [
      {
        sub = "a/alsa-plugins";
        name = "libasound2-plugins_1.1.1-1_armhf.deb";
        hash = "sha256-pUonJpKbqc0RPE5mUP1q7refwzHyecCx18YY77NA45I=";
      }
      {
        sub = "p/pulseaudio";
        name = "libpulse0_10.0-1+deb9u1_armhf.deb";
        hash = "sha256-ALSkp8adMYIztpfHQhLSEvNfm+0xojiH12ssxl4DVJY=";
      }
      {
        sub = "d/dbus";
        name = "libdbus-1-3_1.10.32-0+deb9u1_armhf.deb";
        hash = "sha256-1NMWT6Wy//g7jjT7v5wFlFC88utovQazcs9wUerNjY0=";
      }
      {
        sub = "e/expat";
        name = "libexpat1_2.2.0-2+deb9u3_armhf.deb";
        hash = "sha256-bshcUz9nTJ7RAbQQxzb9k7GAVqNJyVXjHkFAaUiTmbM=";
      }
      {
        sub = "liba/libasyncns";
        name = "libasyncns0_0.8-6_armhf.deb";
        hash = "sha256-bAiwPYBwXv+w9SH5ihu5Q0ePv/Z2dCfUuBnzVM1gLpk=";
      }
      {
        sub = "libs/libsndfile";
        name = "libsndfile1_1.0.27-3_armhf.deb";
        hash = "sha256-gbJD1pNppiuVbejToA2aQl/EGKbfJoo/LY+e54ECPec=";
      }
      {
        sub = "libv/libvorbis";
        name = "libvorbis0a_1.3.5-4+deb9u2_armhf.deb";
        hash = "sha256-8W6OJb4T2cgNQ0v79yblib9Z1oBaIZq0on3n5dti64g=";
      }
      {
        sub = "libv/libvorbis";
        name = "libvorbisenc2_1.3.5-4+deb9u2_armhf.deb";
        hash = "sha256-o9mb8hYr0L3mtuWoUmzumQ7NWeadChFYV99j+/dY2I8=";
      }
      {
        sub = "libo/libogg";
        name = "libogg0_1.3.2-1_armhf.deb";
        hash = "sha256-bZcdORW6UfYCrC/bY5Af6eA5rhk/WGbVO4TRSZIS3mY=";
      }
      {
        sub = "f/flac";
        name = "libflac8_1.3.2-1_armhf.deb";
        hash = "sha256-zaVpARe0fVSvA5VxXLAwGCTZoJ+RkTEMpcfC+T8xxiU=";
      }
      {
        sub = "t/tcp-wrappers";
        name = "libwrap0_7.6.q-26_armhf.deb";
        hash = "sha256-YBt3PDCjP8KqqUu/3mWD+NhUr9auj+DUpa8g0vT6s5g=";
      }
      {
        sub = "libx/libx11";
        name = "libx11-6_1.6.4-3+deb9u1_armhf.deb";
        hash = "sha256-CioYHAY1X7BmZErhtlPw4wzcwl4Q4FkYZAxOhpiUjhI=";
      }
      {
        sub = "libx/libx11";
        name = "libx11-xcb1_1.6.4-3+deb9u1_armhf.deb";
        hash = "sha256-Rp2DgAbz8hgoPOmzon99Q7lqEe40D2I4VLCYZ8fA8ek=";
      }
      {
        sub = "libx/libxcb";
        name = "libxcb1_1.12-1_armhf.deb";
        hash = "sha256-yXkRHxksjPZbg+J+wYHM3DGhxfRIvK/K+Wm0JQLPelw=";
      }
      {
        sub = "libx/libxau";
        name = "libxau6_1.0.8-1_armhf.deb";
        hash = "sha256-XAOV15zxasuGcI7Tf6W/MXNM3gF3Gl0ibHqJ9hEQi/c=";
      }
      {
        sub = "libx/libxdmcp";
        name = "libxdmcp6_1.1.2-3_armhf.deb";
        hash = "sha256-rUeFjtxkafgoihMjjuU8EvV0Vja/DcEvznmNsnGGAr0=";
      }
      {
        sub = "libx/libxtst";
        name = "libxtst6_1.2.3-1_armhf.deb";
        hash = "sha256-oOSAQt5dapRlxcq9XjRBfVRuu14MSn75nbDqMpdrY24=";
      }
      {
        sub = "libx/libxi";
        name = "libxi6_1.7.9-1_armhf.deb";
        hash = "sha256-oc1QL3jfj74DfdSgpIOptzA43ouaCF8H6YheCNCGfwA=";
      }
      {
        sub = "libx/libxfixes";
        name = "libxfixes3_5.0.3-1_armhf.deb";
        hash = "sha256-E/6k/lRaDC6+3pw2pf/ndsNgwzyBebhZT89kLlPH7wE=";
      }
      {
        sub = "libs/libselinux";
        name = "libselinux1_2.6-3+b3_armhf.deb";
        hash = "sha256-TE43P+fcJtKswwX6PXFJDea/0M1hMIeRrt0qYb/OuZI=";
      }
      {
        sub = "p/pcre3";
        name = "libpcre3_8.39-3_armhf.deb";
        hash = "sha256-wbInr9VAdVWEQ/Rv35sICMXe2O/HoN3oTL2ROVZb8BY=";
      }
      {
        sub = "libc/libcap2";
        name = "libcap2_2.25-1_armhf.deb";
        hash = "sha256-D68PVewku/uTT0nWUGRhjClRdwNmb2XInlwYPjD8GZA=";
      }
      {
        sub = "s/systemd";
        name = "libsystemd0_232-25+deb9u12_armhf.deb";
        hash = "sha256-L16u2UW1vpbyAPy/S6wv7/xibHJiPIAq2hv13pXp+cM=";
      }
      {
        sub = "x/xz-utils";
        name = "liblzma5_5.2.2-1.2+b1_armhf.deb";
        hash = "sha256-F/cuLsxKtoeZUquo6kjHlNy1PUWTFb+uqRylVRIpEjU=";
      }
      {
        sub = "l/lz4";
        name = "liblz4-1_0.0~r131-2+b1_armhf.deb";
        hash = "sha256-X8+3B8i1cH7b6/vYDuET9z3x1sDUYxSWDnf6HbVJXdI=";
      }
      {
        sub = "libg/libgcrypt20";
        name = "libgcrypt20_1.7.6-2+deb9u3_armhf.deb";
        hash = "sha256-EhGOYMRcU6MluppcemC9fy+9vCgiv4e3m1eOik4gw5w=";
      }
      {
        sub = "libg/libgpg-error";
        name = "libgpg-error0_1.26-2_armhf.deb";
        hash = "sha256-Mzdurnnin6ld1SENrhVqZwRYUfdx0g9/jG12PtEy+1c=";
      }
    ];

  nativeBuildInputs = [libarchive xz];

  unpackPhase = ''
    runHook preUnpack
    for src in $srcs; do
      # .deb = ar archive wrapping control.tar.* + data.tar.* (xz or gz)
      member=$(bsdtar -tf "$src" | grep -m1 '^data\.tar\.')
      bsdtar -xOf "$src" "$member" | bsdtar -xf -
    done
    runHook postUnpack
  '';

  installPhase = ''
    mkdir -p $out/alsa-lib
    find . -name "*.so*" -exec cp -a {} $out/alsa-lib/ \;
  '';

  # Flat dir with .so symlinks and versioned files copied in; no
  # patching/moving required, so skip the stdenv fixups entirely.
  dontFixup = true;

  meta = with lib; {
    description = "Debian Stretch armhf libpulse + alsa-lib pulse plugin, for the Tidal Connect container";
    platforms = ["x86_64-linux"];
  };
}
