#!/bin/bash

# This script builds the root filesystem for both x86_64 and ARM architectures.

#!/bin/bash

set -e

# Allow using the new Debian builder non-destructively with --debian
USE_DEBIAN=0
DEBIAN_ARGS=()
OUTPUT_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --debian)
            USE_DEBIAN=1
            shift
            # remaining args passed-through to the debian builder
            DEBIAN_ARGS=("$@")
            break
            ;;
        --output-dir)
            OUTPUT_DIR="$2"
            shift 2
            ;;
        *)
            # leave positional args (like arch) after parsing known flags
            break
            ;;
    esac
done

# Compute default rootfs dirs if not overridden
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="$(basename "$REPO_ROOT")"
# Default output dir: build/{project}
if [[ -z "$OUTPUT_DIR" ]]; then
    OUTPUT_DIR="$REPO_ROOT/build/$PROJECT_NAME/rootfs"
fi

MINIMAL_ROOTFS_DIR="$OUTPUT_DIR/minimal"
DESKTOP_ROOTFS_DIR="$OUTPUT_DIR/desktop"

# Function to build root filesystem
# Build root filesystem function
build_rootfs() {
    local arch=$1
    local rootfs_dir=$2

    echo "Building root filesystem for architecture: $arch -> $rootfs_dir"

    # Create the root filesystem directory
    mkdir -p "$rootfs_dir"

    # Copy core packages
    cp -r packages/core/* "$rootfs_dir/"

    # Copy additional packages if they exist
    if [ -d "packages/extra" ]; then
        cp -r packages/extra/* "$rootfs_dir/"
    fi

    # Ensure etc exists and copy configuration files
    mkdir -p "$rootfs_dir/etc"
    cp configs/fstab "$rootfs_dir/etc/" || true
    cp configs/hostname "$rootfs_dir/etc/" || true

    echo "Root filesystem for $arch built successfully at $rootfs_dir"
}

# If requested, delegate to the Debian-specific builder (non-destructive)
if [[ "$USE_DEBIAN" -eq 1 ]]; then
    echo "Delegating to scripts/build-rootfs-debian.sh with args: ${DEBIAN_ARGS[*]}"
    if [[ -n "$OUTPUT_DIR" ]]; then
        DEBIAN_ARGS=("--rootfs" "$OUTPUT_DIR/debian-${DEBIAN_ARGS[0]:-bookworm}-amd64" "${DEBIAN_ARGS[@]}")
    fi
    exec "$(dirname "$0")/build-rootfs-debian.sh" "${DEBIAN_ARGS[@]}"
fi

# Build minimal root filesystem for both architectures (original flow)
build_rootfs "x86_64" "$MINIMAL_ROOTFS_DIR/x86_64"
build_rootfs "arm64" "$MINIMAL_ROOTFS_DIR/arm64"

# Build desktop root filesystem for both architectures
build_rootfs "x86_64" "$DESKTOP_ROOTFS_DIR/x86_64"
build_rootfs "arm64" "$DESKTOP_ROOTFS_DIR/arm64"

echo "All root filesystems built successfully."