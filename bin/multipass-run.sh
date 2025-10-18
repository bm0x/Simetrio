#!/usr/bin/env bash
set -euo pipefail

# multipass-run.sh
# Helper to automate building the Debian rootfs inside a Multipass VM on macOS.
# Usage: ./scripts/multipass-run.sh [--name stralyx] [--mem 4G] [--cpus 2] [--disk 20G] [--with-kde]

NAME="stralyx"
MEM="2G"
CPUS=2
DISK="15G"
WITH_KDE=0
WITH_CALAMARES=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --name) NAME="$2"; shift 2;;
    --mem) MEM="$2"; shift 2;;
    --cpus) CPUS="$2"; shift 2;;
    --disk) DISK="$2"; shift 2;;
    --with-kde) WITH_KDE=1; shift;;
  --with-calamares) WITH_CALAMARES=1; shift;;
    -h|--help) echo "Usage: $0 [--name] [--mem] [--cpus] [--disk] [--with-kde]"; exit 0;;
    *) echo "Unknown arg: $1"; exit 1;;
  esac
done

MULTIPASS_BIN=""
# Prefer whichever multipass is available: PATH first, then common locations
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
  cat <<MSG
multipass is not found on your PATH or in common install locations.
If you just installed it via Homebrew, try opening the app once so its helper
daemon finishes installing:

  open /Applications/Multipass.app

Then run one of the following to diagnose:

  which multipass || echo 'not on PATH'
  ls -l /opt/homebrew/bin/multipass /usr/local/bin/multipass /Applications/Multipass.app/Contents/MacOS/multipass

If you want, you can add the binary to your PATH or restart your shell.
Install via Homebrew if needed:

  brew install --cask multipass

Exiting.
MSG
  exit 1
fi

echo "Using multipass binary at: $MULTIPASS_BIN"

echo "Launching multipass instance: $NAME (memory=$MEM cpus=$CPUS disk=$DISK)"
# multipass CLI expects the image as a positional argument. Try common aliases until one works.
IMAGE_CHOICES=("22.04" "jammy" "ubuntu:22.04" "24.04" "noble" "focal" "20.04")
LAUNCHED=0
if "$MULTIPASS_BIN" list --format csv | grep -q "^$NAME,"; then
  echo "Instance $NAME already exists — reusing it."
  LAUNCHED=1
else
  for IMG in "${IMAGE_CHOICES[@]}"; do
    echo "Trying image: $IMG"
    if "$MULTIPASS_BIN" launch --name "$NAME" --memory "$MEM" --disk "$DISK" --cpus "$CPUS" "$IMG"; then
      LAUNCHED=1
      echo "Launched instance $NAME with image $IMG"
      break
    else
      echo "Failed to launch with image $IMG, trying next"
    fi
  done
  if [[ $LAUNCHED -eq 0 ]]; then
    echo "Unable to launch any of the tested images. Run '$MULTIPASS_BIN find' to list available images." >&2
    exit 2
  fi
fi

echo "Mounting current repository into the VM"
REPO_HOST_PATH="$(pwd)"
echo "Waiting for instance to be ready..."
sleep 2
if ! "$MULTIPASS_BIN" list --format csv | grep -q "^$NAME,"; then
  echo "Instance $NAME does not appear in multipass list after launch." >&2
  exit 3
fi

# Attempt to mount the repo; if already mounted, continue
if ! "$MULTIPASS_BIN" mount "$REPO_HOST_PATH" "$NAME":/home/ubuntu/Stralyx 2>/tmp/multipass-mount.err; then
  if grep -q "is already mounted" /tmp/multipass-mount.err 2>/dev/null; then
    echo "Repository already mounted in instance $NAME, continuing..."
  else
    cat /tmp/multipass-mount.err >&2
    rm -f /tmp/multipass-mount.err
    exit 4
  fi
  rm -f /tmp/multipass-mount.err
fi

echo "Installing dependencies and running build inside VM"
# compute project name and VM-local build/output paths to match new build layout
PROJECT_NAME="$(basename "$REPO_HOST_PATH")"
# Use a VM-local directory for debootstrap to avoid host-mount nodev/noexec restrictions
VMLOCAL_ROOTFS_BASE="/home/ubuntu/debian-rootfs"
BUILD_ROOTFS_VM="$VMLOCAL_ROOTFS_BASE/debian-bookworm-amd64"
IMAGE_VM_PATH="/home/ubuntu/Stralyx/build/${PROJECT_NAME}/output/debian-smoke.img"

REMOTE_SCRIPT=$(cat <<'REMOTE'
set -euo pipefail
sudo apt update
sudo apt install -y debootstrap qemu qemu-system-x86 qemu-user-static e2fsprogs git python3-venv
sudo mkdir -p "__IMAGE_DIR__"
sudo mkdir -p "__VMLOCAL_ROOTFS_BASE__"
sudo chown ubuntu:ubuntu "__VMLOCAL_ROOTFS_BASE__"
cd /home/ubuntu/Stralyx
# Remove any previous VM-local rootfs to ensure a clean build
if [[ -d "__BUILD_ROOTFS_VM__" ]]; then
  echo "Removing existing VM-local rootfs at __BUILD_ROOTFS_VM__ to perform a clean build"
  sudo rm -rf "__BUILD_ROOTFS_VM__"
fi
 sudo ./scripts/build-rootfs-debian.sh --arch amd64 --suite bookworm --rootfs "__BUILD_ROOTFS_VM__" __WITH_KDE_FLAG__ __WITH_CALAMARES_FLAG__
REMOTE
)

# substitute placeholders with actual paths (safe)
REMOTE="$REMOTE_SCRIPT"
REMOTE=${REMOTE//__IMAGE_DIR__/${IMAGE_VM_PATH%/*}}
REMOTE=${REMOTE//__VMLOCAL_ROOTFS_BASE__/$VMLOCAL_ROOTFS_BASE}
REMOTE=${REMOTE//__BUILD_ROOTFS_VM__/$BUILD_ROOTFS_VM}
if [[ $WITH_KDE -eq 1 ]]; then
  REMOTE=${REMOTE//__WITH_KDE_FLAG__/--with-kde}
else
  REMOTE=${REMOTE//__WITH_KDE_FLAG__/}
fi
if [[ $WITH_CALAMARES -eq 1 ]]; then
  REMOTE=${REMOTE//__WITH_CALAMARES_FLAG__/--with-calamares}
else
  REMOTE=${REMOTE//__WITH_CALAMARES_FLAG__/}
fi

"$MULTIPASS_BIN" exec "$NAME" -- bash -lc "$REMOTE"

echo "Creating a partitioned, bootable .img from rootfs inside VM and placing it in the mounted repo output/"
CREATE_IMG_REMOTE=$(cat <<'IMG'
set -euo pipefail
IMAGE="__IMAGE_VM_PATH__"
BUILD_ROOTFS="__BUILD_ROOTFS_VM__"
IMG_SIZE_MB=2048

# create image file
sudo dd if=/dev/zero of="$IMAGE" bs=1M count=$IMG_SIZE_MB

# create msdos partition table and one partition spanning the disk
sudo parted --script "$IMAGE" mklabel msdos mkpart primary ext4 1MiB 100%

# attach loop device with partition scanning
LOOP=$(sudo losetup --find --show --partscan "$IMAGE")
PART="${LOOP}p1"

# wait for partition node
for i in 1 2 3 4 5; do
  if [[ -e "$PART" ]]; then break; fi
  sleep 0.5
done
if [[ ! -e "$PART" ]]; then
  echo "Partition device not found: $PART" >&2
  sudo losetup -d "$LOOP" || true
  exit 1
fi

# format and mount
sudo mkfs.ext4 -F "$PART"
sudo mkdir -p /mnt/debian-img
sudo mount "$PART" /mnt/debian-img

# copy rootfs into the mounted partition
sudo cp -a "$BUILD_ROOTFS"/* /mnt/debian-img/

# ensure /boot exists
sudo mkdir -p /mnt/debian-img/boot

# prepare chroot environment and install grub
sudo mount --bind /dev /mnt/debian-img/dev
sudo mount -t proc /proc /mnt/debian-img/proc
sudo mount -t sysfs /sys /mnt/debian-img/sys
sudo cp /etc/resolv.conf /mnt/debian-img/etc/ || true

# attempt to install grub packages and embed grub into the disk
sudo chroot /mnt/debian-img /bin/bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y grub-pc grub-pc-bin grub-common --no-install-recommends || true"
DISKDEV="$LOOP"
sudo chroot /mnt/debian-img /bin/bash -c "grub-install --target=i386-pc --recheck --boot-directory=/boot $DISKDEV || true"
sudo chroot /mnt/debian-img /bin/bash -c "update-grub || true"

# cleanup mounts and loop device
sudo umount /mnt/debian-img/dev || true
sudo umount /mnt/debian-img/proc || true
sudo umount /mnt/debian-img/sys || true
sudo umount /mnt/debian-img || true
sudo losetup -d "$LOOP" || true
IMG
)

# substitute placeholders with actual values
CREATE_IMG_REMOTE=${CREATE_IMG_REMOTE//__IMAGE_VM_PATH__/$IMAGE_VM_PATH}
CREATE_IMG_REMOTE=${CREATE_IMG_REMOTE//__BUILD_ROOTFS_VM__/$BUILD_ROOTFS_VM}

"$MULTIPASS_BIN" exec "$NAME" -- bash -lc "$CREATE_IMG_REMOTE"

echo "Bootable image created at host path: $REPO_HOST_PATH/build/${PROJECT_NAME}/output/debian-smoke.img"
echo "You can now run ./scripts/novnc-run.sh build/${PROJECT_NAME}/output/debian-smoke.img on your mac to view it in the browser."

echo "Finalizing VM-local rootfs (install kernel meta-package, create user, configure autologin if requested)"
CHROOT_SCRIPT=$(cat <<'CHROOT'
set -euo pipefail
ROOTFS="__BUILD_ROOTFS_VM__"

echo "Mounting pseudo-filesystems for chroot: $ROOTFS"
sudo mount --bind /dev "$ROOTFS/dev"
sudo mount -t proc /proc "$ROOTFS/proc"
sudo mount -t sysfs /sys "$ROOTFS/sys"
sudo cp /etc/resolv.conf "$ROOTFS/etc/" || true

echo "Installing kernel meta-package (linux-image-amd64) inside chroot"
sudo chroot "$ROOTFS" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends linux-image-amd64 || true"

echo "Ensuring user 'stralyx' exists and has sudo"
if ! sudo chroot "$ROOTFS" id -u stralyx >/dev/null 2>&1; then
  sudo chroot "$ROOTFS" /bin/bash -c "useradd -m -s /bin/bash -G sudo stralyx || true"
  sudo chroot "$ROOTFS" /bin/bash -c "echo 'stralyx:password' | chpasswd || true"
fi

# Configure SDDM autologin if KDE requested
if [[ "__WITH_KDE_FLAG__" == "--with-kde" ]]; then
  sudo mkdir -p "$ROOTFS/etc/sddm.conf.d"
  cat <<'SDDM' | sudo tee "$ROOTFS/etc/sddm.conf.d/10-autologin.conf" >/dev/null
[Autologin]
User=stralyx
Session=plasma.desktop
Relogin=false
SDDM
fi

echo "Regenerating initramfs and updating grub inside chroot"
sudo chroot "$ROOTFS" /bin/bash -c "update-initramfs -u || true"
sudo chroot "$ROOTFS" /bin/bash -c "update-grub || true"

# Install Calamares installer in the chroot if requested
if [[ "__WITH_CALAMARES_FLAG__" == "--with-calamares" ]]; then
  echo "Installing Calamares in chroot"
  sudo chroot "$ROOTFS" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends calamares || true"
fi

echo "Cleaning up chroot mounts"
sudo umount "$ROOTFS/dev" || true
sudo umount "$ROOTFS/proc" || true
sudo umount "$ROOTFS/sys" || true
CHROOT
)

CHROOT_RUN=${CHROOT_SCRIPT//__BUILD_ROOTFS_VM__/$BUILD_ROOTFS_VM}
if [[ $WITH_KDE -eq 1 ]]; then
  CHROOT_RUN=${CHROOT_RUN//__WITH_KDE_FLAG__/--with-kde}
else
  CHROOT_RUN=${CHROOT_RUN//__WITH_KDE_FLAG__/}
fi

if [[ $WITH_CALAMARES -eq 1 ]]; then
  CHROOT_RUN=${CHROOT_RUN//__WITH_CALAMARES_FLAG__/--with-calamares}
else
  CHROOT_RUN=${CHROOT_RUN//__WITH_CALAMARES_FLAG__/}
fi

# Execute the chroot finalization inside the Multipass instance
echo "Executing chroot finalization inside instance $NAME"
"$MULTIPASS_BIN" exec "$NAME" -- bash -lc "$CHROOT_RUN"


