#!/usr/bin/env bash
# Builds the homelab-seed installer image (Linux, macOS, WSL).
# Windows users without a Linux shell use build.ps1 instead.
#
# The build runs in a privileged Docker container, so the host only needs Docker.
set -euo pipefail

REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
CONFIG=$REPO_DIR/config.env
OUT=$REPO_DIR/out
XZ=false
MODE=build
BUILDER_IMAGE=homelab-seed-builder:local

usage() {
    cat <<EOF
Usage: $0 [options]

  -c, --config FILE   configuration file (default: config.env)
  -o, --output DIR    output directory (default: out/)
      --xz            compress the image with xz
      --bundle        only validate the configuration and pack it into
                      <output>/config.bundle.b64, to be stored as a CI secret
  -h, --help          show this help

Files referenced in the configuration must be inside the directory of the
configuration file.
EOF
}

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

while (($#)); do
    case $1 in
        -c | --config) CONFIG=${2:?}; shift 2 ;;
        -o | --output) OUT=${2:?}; shift 2 ;;
        --xz) XZ=true; shift ;;
        --bundle) MODE=bundle; shift ;;
        -h | --help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done

[[ -f $CONFIG ]] || die "$CONFIG not found. Create it with: cp config.example.env config.env"
command -v docker >/dev/null || die "Docker is required: https://docs.docker.com/get-docker/"
docker info >/dev/null 2>&1 || die "Docker is not running or not accessible"

CONFIG_DIR=$(cd "$(dirname "$CONFIG")" && pwd)
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)

echo "==> Preparing the builder container"
docker build --quiet -t "$BUILDER_IMAGE" "$REPO_DIR/builder" >/dev/null

docker run --rm --privileged \
    -e SEED_CONFIG_NAME="$(basename "$CONFIG")" \
    -e SEED_VERSION="$(git -C "$REPO_DIR" describe --always --dirty 2>/dev/null || echo unknown)" \
    -e SEED_XZ="$XZ" -e SEED_MODE="$MODE" \
    -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
    -v "$REPO_DIR:/src:ro" \
    -v "$CONFIG_DIR:/config:ro" \
    -v homelab-seed-cache:/cache \
    -v homelab-seed-work:/work \
    -v "$OUT:/out" \
    "$BUILDER_IMAGE" bash /src/builder/build-image.sh
