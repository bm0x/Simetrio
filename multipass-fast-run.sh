#!/usr/bin/env bash
set -euo pipefail

# multipass-fast-run.sh
# Quick helper to mount (or transfer) the current repo into a multipass instance
# and run the Debian rootfs builder there in one command.
# Usage: ./scripts/multipass-fast-run.sh [--name NAME] [--arch amd64] [--suite bookworm] [--with-kde]

NAME="stralyx"
ARCH="amd64"
SUITE="bookworm"
WITH_KDE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --arch) ARCH="$2"; shift 2;;
    --suite) SUITE="$2"; shift 2;;
    --with-kde) WITH_KDE=1; shift;;
    -h|--help) echo "Usage: $0 [--name NAME] [--arch ARCH] [--suite SUITE] [--with-kde]"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

# find multipass binary (reuse same locations as other scripts)
MULTIPASS_BIN=""
if command -v multipass >/dev/null 2>&1; then
  MULTIPASS_BIN="$(command -v multipass)"
elif [[ -x "/opt/homebrew/bin/multipass" ]]; then
  MULTIPASS_BIN="/opt/homebrew/bin/multipass"
elif [[ -x "/usr/local/bin/multipass" ]]; then
  MULTIPASS_BIN="/usr/local/bin/multipass"
elif [[ -x "/Applications/Multipass.app/Contents/MacOS/multipass" ]]; then
  MULTIPASS_BIN="/Applications/Multipass.app/Contents/MacOS/multipass"
fi

if [[ -z "$MULTIPASS_BIN" ]]; then
  echo "multipass not found. Install it first (brew install --cask multipass)" >&2
  exit 1
fi

REPO_HOST_PATH="$(pwd)"

echo "Attempting to mount repository into instance '$NAME'"
if "$MULTIPASS_BIN" mount "$REPO_HOST_PATH" "$NAME":/home/ubuntu/Stralyx; then
  echo "Mounted repo into $NAME:/home/ubuntu/Stralyx"
else
  echo "Mount failed, falling back to transfer (this will copy the repo into the VM)"
  "$MULTIPASS_BIN" transfer -r "$REPO_HOST_PATH" "$NAME":/home/ubuntu/Stralyx
fi

echo "Running build inside instance $NAME"
BUILD_CMD="cd /home/ubuntu/Stralyx && sudo ./scripts/build-rootfs-debian.sh --arch $ARCH --suite $SUITE"
if [[ $WITH_KDE -eq 1 ]]; then
  BUILD_CMD="$BUILD_CMD --with-kde"
fi

if "$MULTIPASS_BIN" exec "$NAME" -- bash -lc "$BUILD_CMD"; then
  echo "Build command finished (check output above for details)"
else
  echo "Build command failed. Inspect the instance logs or run the exec command manually to debug." >&2
  exit 2
fi

echo "If you want an image (.img) in output/, run the create-image step in the VM or use ./scripts/multipass-run.sh which does that automatically."

