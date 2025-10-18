#!/bin/bash

set -euo pipefail

# Clean the build/{project} directory safely.
# Usage: ./scripts/clean-build.sh [--yes] [--dry-run]

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="$(basename "$REPO_ROOT")"
BUILD_DIR="$REPO_ROOT/build/$PROJECT_NAME"

DRY=0
YES=0
REMOVE_INSTANCE=0
INSTANCE_NAME="stralyx"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run) DRY=1; shift ;;
    --yes|-y) YES=1; shift ;;
    --remove-instance) REMOVE_INSTANCE=1; shift ;;
    --instance-name) INSTANCE_NAME="$2"; shift 2 ;;
    *) echo "Unknown arg: $1"; exit 2 ;;
  esac
done

if [[ ! -d "$BUILD_DIR" ]]; then
  echo "Nothing to clean: $BUILD_DIR does not exist."
  # If requested, still attempt to remove the multipass instance even when build dir missing
  if [[ $REMOVE_INSTANCE -eq 1 ]]; then
    echo "Build dir missing but --remove-instance was requested; will attempt to remove instance: $INSTANCE_NAME"
  else
    exit 0
  fi
fi

echo "About to remove: $BUILD_DIR"
if [[ $DRY -eq 1 ]]; then
  echo "Dry run enabled — no files will be removed."
  exit 0
fi

if [[ $YES -ne 1 ]]; then
  read -p "Are you sure you want to remove $BUILD_DIR? Type 'yes' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "yes" ]]; then
    echo "Aborting. No files were removed."
    exit 0
  fi
fi

echo "Removing $BUILD_DIR ..."
rm -rf "$BUILD_DIR"
echo "Removed $BUILD_DIR"

remove_multipass_instance() {
  if ! command -v multipass >/dev/null 2>&1; then
    echo "multipass not found on PATH; cannot remove instance $INSTANCE_NAME."
    return 0
  fi

  if [[ $DRY -eq 1 ]]; then
    echo "Dry run: would remove multipass instance: $INSTANCE_NAME (multipass delete --purge $INSTANCE_NAME; multipass purge)"
    return 0
  fi

  if [[ $YES -ne 1 ]]; then
    read -p "Also remove multipass instance '$INSTANCE_NAME'? Type 'yes' to confirm: " CONF2
    if [[ "$CONF2" != "yes" ]]; then
      echo "Skipping multipass instance removal."
      return 0
    fi
  fi

  echo "Removing multipass instance: $INSTANCE_NAME"
  multipass delete --purge "$INSTANCE_NAME" || echo "Warning: multipass delete failed or instance not found"
  multipass purge || true
  echo "Multipass instance removal attempted for: $INSTANCE_NAME"
}

if [[ $REMOVE_INSTANCE -eq 1 ]]; then
  remove_multipass_instance
fi
