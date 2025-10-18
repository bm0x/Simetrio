#!/bin/bash

set -e

# Define variables
REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT_NAME="$(basename "$REPO_ROOT")"
BUILD_DIR="$REPO_ROOT/build/$PROJECT_NAME"
OUTPUT_DIR="$BUILD_DIR/output"
IMAGE_NAME="${PROJECT_NAME}-image"
ARCHS=("x86_64" "arm64")

# Create output directory if it doesn't exist
# Create output directory if it doesn't exist
mkdir -p "$OUTPUT_DIR"

# Function to build image for a specific architecture
build_image() {
    local arch=$1
    echo "Building image for architecture: $arch (outputs -> $OUTPUT_DIR)"

    # Placeholder for actual image building commands
    # This could involve invoking build-rootfs.sh, packaging, etc.
    # Delegate to build-rootfs.sh; pass --output-dir to allow rootfs builders to write into the build directory
    ./scripts/build-rootfs.sh --output-dir "$BUILD_DIR/rootfs" $arch
    # Additional commands to create the image would go here

    echo "Image for $arch built successfully."
}

# Build images for all architectures
for arch in "${ARCHS[@]}"; do
    build_image $arch
done

echo "All images have been built and are located in $OUTPUT_DIR."