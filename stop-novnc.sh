#!/usr/bin/env bash
set -euo pipefail

# Stop novnc-run.sh QEMU + websockify processes
PID_FILE=".novnc_qemu.pid"

if [[ -f "$PID_FILE" ]]; then
  QPID=$(cat "$PID_FILE")
  echo "Killing QEMU process pid: $QPID"
  kill "$QPID" 2>/dev/null || true
  rm -f "$PID_FILE"
fi

# Kill websockify by process name (best-effort)
pkill -f websockify || true
pkill -f qemu-system-x86_64 || true

echo "Stopped noVNC-related processes (best-effort)."
