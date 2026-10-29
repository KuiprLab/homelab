#!/usr/bin/env bash

set -euo pipefail

PLATFORM="${1:-linux-x64}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
DEFAULT_NIX="$REPO_ROOT/pkgs/unifi-os-server-image/default.nix"
MODULE_NIX="$REPO_ROOT/pkgs/unifi-os-server-image/module.nix"
UNIFI_MODULE="$REPO_ROOT/services/unifi.nix"

# perl -i exits 0 on a missing file, so `set -e` would not catch a stale path.
for target in "$DEFAULT_NIX" "$MODULE_NIX" "$UNIFI_MODULE"; do
  if [[ ! -f $target ]]; then
    echo "ERROR: target file not found: $target" >&2
    echo "A path near the top of this script is stale." >&2
    exit 1
  fi
done

echo "Querying Ubiquiti firmware API for platform: $PLATFORM ..."

FIRMWARE_JSON=$(curl -fsSL \
  "https://fw-update.ui.com/api/firmware-latest?filter=eq~~product~~UniFi-OS-Server&filter=eq~~channel~~release&filter=eq~~platform~~${PLATFORM}")

VERSION=$(echo "$FIRMWARE_JSON" | jq -r '._embedded.firmware[0].version')
DOWNLOAD_URL=$(echo "$FIRMWARE_JSON" | jq -r '._embedded.firmware[0]._links.data.href')
SHA256_HEX=$(echo "$FIRMWARE_JSON" | jq -r '._embedded.firmware[0].sha256_checksum')

if [[ -z $VERSION || $VERSION == "null" ]]; then
  echo "ERROR: Could not parse version from API response." >&2
  echo "Response was: $FIRMWARE_JSON" >&2
  exit 1
fi

VERSION="${VERSION#v}"

echo "Latest version : $VERSION"
echo "Download URL   : $DOWNLOAD_URL"

CURRENT_VERSION=$(perl -ne 'print $1 if /version \? "([^"]+)"/' "$DEFAULT_NIX")
if [[ $VERSION == "$CURRENT_VERSION" ]]; then
  echo "Already at latest version $VERSION — nothing to do."
  exit 0
fi

SHA256_SRI="sha256-$(printf '%s' "$SHA256_HEX" | xxd -r -p | base64)"
echo "SHA256 (SRI)   : $SHA256_SRI"

TMPDIR=$(mktemp -d)
trap 'rm -rf "$TMPDIR"' EXIT

echo "Downloading installer (~$(echo "$FIRMWARE_JSON" | jq '._embedded.firmware[0].file_size / 1048576 | floor')  MB)..."
INSTALLER="$TMPDIR/unifi-os-installer"
curl -f --progress-bar -o "$INSTALLER" "$DOWNLOAD_URL"

cd "$TMPDIR"

if command -v binwalk &>/dev/null; then
  binwalk -e ./unifi-os-installer >/dev/null 2>&1
else
  echo "binwalk not found in PATH, trying via nix run ..."
  nix run nixpkgs#binwalk -- -e ./unifi-os-installer >/dev/null 2>&1
fi

IMAGE_TAR=$(find . -type f -name image.tar | head -n1)
if [[ -z $IMAGE_TAR ]]; then
  echo "ERROR: Could not find image.tar in extracted installer." >&2
  exit 1
fi

IMAGE_TAG=$(tar -xOf "$IMAGE_TAR" manifest.json | jq -r '.[0].RepoTags[0]')

if [[ -z $IMAGE_TAG || $IMAGE_TAG == "null" ]]; then
  echo "ERROR: Could not extract RepoTags from manifest.json." >&2
  exit 1
fi

echo "imageTag       : $IMAGE_TAG"

cd "$REPO_ROOT"

echo "Updating $DEFAULT_NIX ..."
VERSION="$VERSION" perl -i -pe \
  's/(version \? ")[^"]*"/$1$ENV{VERSION}"/' "$DEFAULT_NIX"
DOWNLOAD_URL="$DOWNLOAD_URL" perl -i -pe \
  's|^(\s+url \? ")[^"]*"|$1$ENV{DOWNLOAD_URL}"| if !/^\s*#/' "$DEFAULT_NIX"

echo "Updating $MODULE_NIX ..."
IMAGE_TAG="$IMAGE_TAG" perl -i -pe \
  's/(imageTag = ")[^"]*"/$1$ENV{IMAGE_TAG}"/' "$MODULE_NIX"

echo "Updating $UNIFI_MODULE ..."
SHA256_SRI="$SHA256_SRI" perl -i -pe \
  's/(sha256 = ")[^"]*"/$1$ENV{SHA256_SRI}"/' "$UNIFI_MODULE"
if grep -q 'imageTag = "' "$UNIFI_MODULE"; then
  IMAGE_TAG="$IMAGE_TAG" perl -i -pe \
    's/(imageTag = ")[^"]*"/$1$ENV{IMAGE_TAG}"/' "$UNIFI_MODULE"
fi

echo ""
echo "Done! Updated $CURRENT_VERSION → $VERSION"
echo "  imageTag : $IMAGE_TAG"
echo "  sha256   : $SHA256_SRI"
