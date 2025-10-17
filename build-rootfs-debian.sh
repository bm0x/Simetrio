#!/bin/bash
set -euo pipefail

# build-rootfs-debian.sh
# Non-intrusive helper to create a Debian-based rootfs using debootstrap.
# Designed to coexist with existing scripts in the repo (does not modify them).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

ARCH="amd64"
SUITE="bookworm"
MIRROR="http://deb.debian.org/debian"
# Default rootfs under build/{project}/rootfs when not overridden
PROJECT_NAME="$(basename "$REPO_ROOT")"
ROOTFS_DIR="${REPO_ROOT}/build/${PROJECT_NAME}/rootfs/debian-${SUITE}-${ARCH}"
DRY_RUN=0
KERNEL_PACKAGE="linux-image-6.1"
INSTALL_KDE=0
INSTALL_CALAMARES=0

usage(){
  cat <<EOF
Usage: $0 [options]

Options:
  --arch <amd64|arm64>        Architecture (default: amd64)
  --suite <suite>             Debian suite (default: bookworm)
  --mirror <mirror_url>       Debian mirror (default: http://deb.debian.org/debian)
  --rootfs <path>             Output rootfs directory (default: rootfs/debian-<suite>-<arch>)
  --kernel <package>          Kernel package name to install (default: linux-image-6.1)
  --with-kde                  Install KDE Plasma (task-kde-desktop)
  --with-calamares            Install Calamares installer (best-effort)
  --dry-run                   Do everything except actual debootstrap/chroot changes
  -h, --help                  Show this help

This script is non-destructive by default. It will refuse to overwrite an existing
rootfs directory unless you remove it first or pass a different --rootfs path.
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --arch) ARCH="$2"; shift 2;;
    --suite) SUITE="$2"; shift 2;;
    --mirror) MIRROR="$2"; shift 2;;
    --rootfs) ROOTFS_DIR="$2"; shift 2;;
    --dry-run) DRY_RUN=1; shift;;
    --kernel) KERNEL_PACKAGE="$2"; shift 2;;
    --with-kde) INSTALL_KDE=1; shift;;
    --with-calamares) INSTALL_CALAMARES=1; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown option: $1"; usage; exit 1;;
  esac
done

echo "Configuration: arch=$ARCH suite=$SUITE mirror=$MIRROR rootfs=$ROOTFS_DIR kernel=$KERNEL_PACKAGE with_kde=$INSTALL_KDE dry_run=$DRY_RUN"

if [[ $DRY_RUN -eq 1 ]]; then
  echo "Dry run mode: no changes will be made. Exiting."; exit 0
fi

if [[ -e "$ROOTFS_DIR" ]]; then
  echo "Rootfs directory $ROOTFS_DIR already exists. To avoid accidental data loss this script will not overwrite it."
  echo "Remove it first or provide a different --rootfs path."; exit 1
fi

if ! command -v debootstrap >/dev/null 2>&1; then
  echo "debootstrap not found. Install it on the host (e.g. apt install debootstrap) and re-run."; exit 1
fi

mkdir -p "$ROOTFS_DIR"

echo "Starting debootstrap for $ARCH/$SUITE into $ROOTFS_DIR"

if [[ "$ARCH" == "amd64" || "$ARCH" == "x86_64" ]]; then
  debootstrap --arch=amd64 "$SUITE" "$ROOTFS_DIR" "$MIRROR"
elif [[ "$ARCH" == "arm64" || "$ARCH" == "aarch64" ]]; then
  # Foreign bootstrap then second-stage with qemu-aarch64-static
  debootstrap --arch=arm64 --foreign "$SUITE" "$ROOTFS_DIR" "$MIRROR"
  if ! command -v qemu-aarch64-static >/dev/null 2>&1; then
    echo "qemu-aarch64-static not found. Install qemu-user-static to complete second-stage.";
    echo "After installing, run: cp /usr/bin/qemu-aarch64-static $ROOTFS_DIR/usr/bin/ && chroot $ROOTFS_DIR /debootstrap/debootstrap --second-stage";
    exit 1
  fi
  cp /usr/bin/qemu-aarch64-static "$ROOTFS_DIR/usr/bin/"
  chroot "$ROOTFS_DIR" /debootstrap/debootstrap --second-stage
else
  echo "Unsupported architecture: $ARCH"; exit 1
fi

# Prepare for chroot operations
mount --bind /dev "$ROOTFS_DIR/dev"
mount -t proc /proc "$ROOTFS_DIR/proc"
mount --bind /sys "$ROOTFS_DIR/sys"
cp /etc/resolv.conf "$ROOTFS_DIR/etc/"

echo "Running apt-get update and installing base packages"
chroot "$ROOTFS_DIR" /bin/bash -c "apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends locales ca-certificates systemd-sysv initramfs-tools sudo net-tools iproute2"

echo "Installing kernel package: $KERNEL_PACKAGE"
chroot "$ROOTFS_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ${KERNEL_PACKAGE} || echo 'Warning: kernel package install failed or not available.'"

if [[ $INSTALL_KDE -eq 1 ]]; then
  echo "Installing KDE Plasma (task-kde-desktop and sddm)"
  chroot "$ROOTFS_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get install -y task-kde-desktop sddm --no-install-recommends || apt-get install -y plasma-desktop sddm --no-install-recommends"

  echo "Configuring SDDM and default KDE settings in /etc/skel to preserve UX/UI for new users"
  cat > "$ROOTFS_DIR/etc/skel/.xsession" <<'XSESSION'
#!/bin/sh
exec startplasma-x11
XSESSION
  chmod 755 "$ROOTFS_DIR/etc/skel/.xsession"

  # Minimal SDDM config to select Plasma by default
  mkdir -p "$ROOTFS_DIR/etc/sddm.conf.d"
  cat > "$ROOTFS_DIR/etc/sddm.conf.d/10-plasma.conf" <<'SDDM'
[Autologin]
Relogin=false

[Theme]
Current=breeze
SDDM
fi

echo "Cleaning apt cache"
chroot "$ROOTFS_DIR" /bin/bash -c "apt-get clean && rm -rf /var/lib/apt/lists/*"

if [[ $INSTALL_CALAMARES -eq 1 ]]; then
  echo "Attempting to install Calamares in the rootfs (best-effort)."
  chroot "$ROOTFS_DIR" /bin/bash -c "DEBIAN_FRONTEND=noninteractive apt-get update && apt-get install -y --no-install-recommends calamares || echo 'Calamares not available; skipping.'"
fi

echo "Unmounting proc/sys/dev and finishing"
umount "$ROOTFS_DIR/proc" || true
umount "$ROOTFS_DIR/sys" || true
umount "$ROOTFS_DIR/dev" || true

echo "Debian rootfs created at: $ROOTFS_DIR"
