
Simetrio — unified build & test helper
=====================================

Overview
--------
Simetrio is a lightweight wrapper around the repository's existing build, VM and web UI tooling. It provides:

- A compact CLI (`scripts/simetrio`) that orchestrates build, noVNC serve, cleanup and preflight checks.
- An optional full-screen, colored TUI (`scripts/simetrio_tui.py`) implemented with Textual for interactive use.
- Small helper scripts (bash) that do the heavy lifting (Debian rootfs build with debootstrap, creating a bootable image in a Multipass VM on macOS, serving a QEMU VM over a browser using noVNC).

Goals and design principles
---------------------------
- Non-destructive defaults: nothing is removed or overwritten unless the user passes an explicit confirmation flag (e.g. `--yes`).
- Preserve existing behavior: most logic is delegated to the repo's bash scripts to avoid duplicating complex, battle-tested steps.
- Host portability: on macOS the scripts prefer to run debootstrap and disk-image creation inside a Multipass Linux instance to avoid host mount restrictions (nodev/noexec). On Linux the scripts can run locally and use QEMU/KVM where available.
- UX-first tooling: provide an approachable TUI for interactive workflows while keeping the CLI for scripting and CI.

Contents of this folder
-----------------------
- `simetrio` — Python CLI entrypoint (executable). Use for scripted or interactive management.
- `simetrio_tui.py` — optional full-screen Textual TUI (requires textual + rich). When present it is launched by `simetrio` without extra args if your terminal supports tty.
- `requirements-simetrio.txt` — minimal dependency list for the TUI (textual, rich pins).

Key workflows and scripts
-------------------------
This project delegates work to existing bash scripts in the repository. The most important scripts are:

- `multipass-run.sh`
	- High-level purpose: perform a Debian-based rootfs build using `debootstrap` inside a Multipass VM (macOS-friendly) and produce a bootable disk image (.img) with a partition table and GRUB installed.
	- When to use: use this when you want a bootable Debian image that you can test in QEMU or flash to media.
	- Important flags: `--name` (multipass instance name), `--mem`, `--cpus`, `--disk`, `--with-kde`, `--with-calamares`.

- `build-rootfs-debian.sh`
	- High-level purpose: debootstrap a Debian root filesystem (bookworm by default) with optional packages installed inside the chroot (kernel meta-package, KDE groups, and a best-effort Calamares install).
	- Notes: when running on macOS we avoid debootstrapping directly into host-mounted directories (nodev/noexec) and instead run it inside Multipass.

- `novnc-run.sh`
	- High-level purpose: prepare a small noVNC runtime (venv + websockify) and launch QEMU to expose the generated .img as a VNC server proxied to the browser.
	- When to use: after you have a bootable .img and want to expose it via a browser-based VNC (noVNC) for testing.

- `clean-build.sh` and `stop-novnc.sh`
	- Helpers to remove build artifacts and stop any running QEMU/noVNC processes. `clean-build.sh` can also delete the Multipass instance when asked explicitly.

How to use the CLI
------------------
From the repository root:

- Run a quick preflight check to ensure basic tools are available and script syntax looks sane:

```bash
./scripts/simetrio check
```

- Build a bootable Debian image (multipass flow on macOS):

```bash
./scripts/simetrio build --name stralyx --mem 4G --cpus 2 --disk 20G --with-kde --with-calamares
```

- Serve an image via noVNC (requires `novnc-run.sh` to be present and QEMU available):

```bash
./scripts/simetrio novnc build/Stralyx/output/debian-smoke.img
```

- Stop any noVNC/QEMU run started by the scripts:

```bash
./scripts/simetrio stop
```

- Clean build artifacts and optionally remove the Multipass instance (opt-in):

```bash
./scripts/simetrio clean --yes --remove-instance --instance-name stralyx
```

Interactive TUI
---------------
If you prefer a visual interface, the TUI uses Textual and can be run directly:

1) Install dependencies (one-time):

```bash
python3 -m pip install -r scripts/requirements-simetrio.txt
```

2) Start the TUI:

```bash
./scripts/simetrio    # when run without args it will prefer to launch the TUI if available
# or directly
```

TUI features
- Left-hand menu with common actions (Build, Run noVNC, Clean, Stop, Preflight).
- Parameter form to fill instance name, memory, CPUs, disk, and checkboxes for KDE / Calamares.
- Live output pane that streams the invoked script's stdout/stderr.
- "Copy Log" button that copies the full internal log buffer to the system clipboard (macOS: `pbcopy`; Wayland: `wl-copy`; X11: `xclip`) or writes to a temp file if clipboard utilities are not available.

Design & implementation notes
-----------------------------
- The TUI intentionally delegates to the same bash scripts the CLI uses. This keeps behaviour consistent and avoids duplicating system-level steps (partitioning, grub-install, debootstrap logic).
- On macOS we discovered that debootstrap fails when run into host-mounted folders mounted with `nodev`/`noexec` flags (the `mknod` syscall is restricted). To mitigate this the Multipass flow runs debootstrap inside a VM-local directory (`/home/ubuntu/debian-rootfs/...`) and produces the output image inside the VM where `losetup`, `parted`, and `grub-install` can operate normally.
- The image creation flow creates a partition table and installs GRUB in the image's loop device; simply copying files to a raw file without installing a bootloader will not produce a bootable image.

Flags and opt-in behaviour
-------------------------
- `--with-kde` — installs KDE packages (task-kde-desktop/metapackages) inside the chroot so the resulting image boots into a desktop session.
- `--with-calamares` — best-effort install of Calamares inside the chroot; availability depends on the distro's repos and the chroot environment.
- `--yes` — confirm destructive actions in `clean` (required to remove build artifacts and/or a Multipass instance).

Troubleshooting
---------------
If the TUI fails to start, or you see unexpected errors:

1) Confirm Textual is installed and the right Python interpreter is used:

```bash
python3 -c "import textual, rich; print(textual.__version__, rich.__version__)"
```

2) If the TUI crashes, a combined log is captured at `build/logs/simetrio-tui.log` when `simetrio` runs the TUI non-interactively. When you run the TUI interactively the output appears on your terminal.

3) If the TUI starts but the "Copy Log" button doesn't move data to your clipboard, confirm one of the clipboard utilities exists on your host:

- macOS: `pbcopy` (usually present)
- Wayland: `wl-copy` (from wl-clipboard)
- X11: `xclip`

If none exist the TUI will write a temp file and print its path in the output pane.

4) Multipass-specific:
- If `debootstrap` fails with `mknod: Operation not permitted` this usually means debootstrap was attempted in a host-mounted directory with restrictive mount options. Re-run using the `multipass-run.sh` flow which runs debootstrap inside the VM-local directory.

5) Boot issues:
- If the created image isn't booting, make sure the `multipass-run.sh` log includes `grub-install` success messages and `update-grub` output. If GRUB isn't installed the image will not be bootable.

Install Multipass
-----------------
To use the `multipass-run.sh` flow you need Multipass installed on your host. Short platform instructions and quick verification steps are below.

macOS
- Homebrew (recommended):

```bash
# Install Homebrew (if you don't have it):
# /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
brew install --cask multipass
```

- Direct installer: download the .dmg from https://multipass.run and run the installer.

Notes macOS: Multipass uses the Hypervisor.framework on Intel and Apple Silicon; VirtualBox isn't required. On Apple Silicon make sure to use the ARM-compatible build supplied by the installer/Homebrew.

Windows
- MSI installer: download from https://multipass.run and run as Administrator.
- winget (Windows 10/11):

```powershell
winget install --id Canonical.Multipass -e
```

- Chocolatey:

```powershell
choco install multipass
```

Notes Windows: Multipass on Windows commonly uses Hyper-V or WSL2 integration. On Windows Home you may need to enable the Virtual Machine Platform / WSL2. Run the installer with elevated privileges.

Linux
- Snap (recommended on many distros):

```bash
sudo snap install multipass --classic
```

- Debian/Ubuntu (apt):

```bash
sudo apt update
sudo apt install -y multipass
```

If your distro doesn't provide snap or a package, see the Multipass website for distro-specific instructions.

Quick verification
- Check version:

```bash
multipass version
```

- List instances:

```bash
multipass ls
```

- Launch a test VM, run a command and remove it:

```bash
multipass launch --name simetrio-test --mem 1G --cpus 1 --disk 2G
multipass exec simetrio-test -- uname -a
multipass delete simetrio-test
multipass purge
```

Virtualization & permissions notes
- Ensure hardware virtualization is enabled in BIOS/UEFI on physical machines.
- On macOS and Windows you usually don't need to run Multipass as root after installation, but the installer/activation may require elevated privileges.
- If you see permissions or hypervisor backend errors, inspect Multipass logs (`multipass logs <instance>`).

Development notes for contributors
----------------------------------
- Keep the heavy system logic in the existing bash scripts. The Python CLI/TUI should remain a thin orchestration and UX layer.
- When editing the TUI prefer stable textual APIs. Different textual versions changed minor CSS/constructor behavior; avoid using nonstandard `App(title=...)` kwargs or undefined CSS variables.
- If you add more clipboard-related features, consider using a small cross-platform library (pyperclip) to simplify fallbacks.

