#!/usr/bin/env bash
set -euo pipefail

# novnc-run.sh
# Minimal, self-contained runner to test a disk image with noVNC in the browser.
# It clones noVNC into tooling/novnc (if needed), creates a local Python venv with
# websockify, starts QEMU with a VNC display bound to localhost, and runs websockify
# to serve the noVNC web UI on http://localhost:6080
#
# Usage:
#   ./scripts/novnc-run.sh /path/to/image.img
#
# Notes:
# - Browsers can't speak raw VNC/TCP, so a websocket-to-tcp proxy (websockify) is required.
#   This script keeps that proxy inside the repo (not an external service) so no external
#   intermediary is needed beyond the local host process.
# - The script binds VNC to localhost only for safety.
# - Requires: python3, git, qemu-system-x86_64 (or qemu-system-aarch64 for arm images).

IMAGE_PATH="${1:-/tmp/debian-smoke.img}"
NOVNC_DIR="$(pwd)/tooling/novnc"
VENV_DIR="$(pwd)/.venv-novnc"
QEMU_BIN="qemu-system-x86_64"
QEMU_VNC_DISPLAY=1
WEBSOCKIFY_PORT=6080

if [[ ! -f "$IMAGE_PATH" ]]; then
  echo "Image not found: $IMAGE_PATH"
  echo "You can create one via tests/qemu-smoke.sh or specify an existing image."
  exit 1
fi

if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
  echo "QEMU binary not found: $QEMU_BIN"
  echo "Install qemu-system-x86_64 and re-run."
  exit 1
fi

echo "Preparing noVNC in $NOVNC_DIR"
if [[ ! -d "$NOVNC_DIR" ]]; then
  git clone https://github.com/novnc/noVNC.git "$NOVNC_DIR"
fi

echo "Preparing Python virtualenv (websockify) in $VENV_DIR"
if [[ ! -d "$VENV_DIR" ]]; then
  python3 -m venv "$VENV_DIR"
  "$VENV_DIR/bin/pip" install --upgrade pip
  "$VENV_DIR/bin/pip" install websockify
fi

echo "Starting QEMU with VNC bound to 127.0.0.1:${QEMU_VNC_DISPLAY} (TCP port $((5900+QEMU_VNC_DISPLAY)))"
# Determine whether to enable KVM
QEMU_OPTS=""
if [[ "$(uname -s)" == "Linux" && -e /dev/kvm ]]; then
  QEMU_OPTS="-enable-kvm"
fi
# start qemu in background, snapshot mode so image is not altered
"$QEMU_BIN" -hda "$IMAGE_PATH" -m 2048 -vnc 127.0.0.1:${QEMU_VNC_DISPLAY} -snapshot -no-reboot $QEMU_OPTS &
QEMU_PID=$!

echo "Started QEMU (pid $QEMU_PID). Starting websockify to expose noVNC on http://localhost:${WEBSOCKIFY_PORT}"
"$VENV_DIR/bin/websockify" --web "$NOVNC_DIR" ${WEBSOCKIFY_PORT} 127.0.0.1:$((5900+QEMU_VNC_DISPLAY)) &
WEBSOCKIFY_PID=$!

echo "noVNC available at: http://localhost:${WEBSOCKIFY_PORT}/vnc.html"
echo "To stop: kill $WEBSOCKIFY_PID $QEMU_PID"

wait $WEBSOCKIFY_PID || true
