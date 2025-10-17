#!/bin/bash

# This script signs the generated image for verification and security.

IMAGE_PATH="$1"
SIGNATURE_PATH="$2"
KEY_PATH="$3"

if [[ -z "$IMAGE_PATH" || -z "$SIGNATURE_PATH" || -z "$KEY_PATH" ]]; then
    echo "Usage: $0 <image-path> <signature-path> <key-path>"
    exit 1
fi

if [[ ! -f "$IMAGE_PATH" ]]; then
    echo "Error: Image file '$IMAGE_PATH' does not exist."
    exit 1
fi

if [[ ! -f "$KEY_PATH" ]]; then
    echo "Error: Key file '$KEY_PATH' does not exist."
    exit 1
fi

# Sign the image
openssl dgst -sha256 -sign "$KEY_PATH" -out "$SIGNATURE_PATH" "$IMAGE_PATH"

if [[ $? -eq 0 ]]; then
    echo "Image signed successfully. Signature saved to '$SIGNATURE_PATH'."
else
    echo "Error signing the image."
    exit 1
fi