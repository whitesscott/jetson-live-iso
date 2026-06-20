#!/usr/bin/env bash
#
# Copyright (c) 2026 Scott White
#
# Licensed under the MIT License (see below). The ISO produced by this
# script bundles third-party packages and source-ISO contents under
# their respective licenses; the MIT terms below cover this script only.
#
# Permission is hereby granted, free of charge, to any person obtaining
# a copy of this software and associated documentation files (the
# "Software"), to deal in the Software without restriction, including
# without limitation the rights to use, copy, modify, merge, publish,
# distribute, sublicense, and/or sell copies of the Software, and to
# permit persons to whom the Software is furnished to do so, subject to
# the following conditions:
#
# The above copyright notice and this permission notice shall be
# included in all copies or substantial portions of the Software.
#
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
# EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
# MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
# NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
# LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
# OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
# WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
# ──────────────────────────────────────────────────────────────────────
#
# Reference build of an arm64 Ubuntu live ISO.
#
# Builds an Ubuntu 24.04 (noble) arm64 live ISO with a GNOME desktop
# session. Reuses a user-supplied source ISO's UEFI boot artifacts,
# kernel, and platform-specific packages; replaces its server rootfs
# with a freshly built ubuntu-desktop-minimal squashfs. The supplied
# ISO's original installer menu entries are preserved.
#
# Script must run on an arm64 / aarch64 host.
#
# What this script DOES need:
#   - Host: Ubuntu 24.04 arm64, sudo, network to ports.ubuntu.com
#   - Source ISO: a UEFI-bootable arm64 installer ISO with
#       /casper/{Image,initrd} and a /pool/ apt repo
#   - ~20 GB free disk in BUILD_DIR.
#   - apt packages: debootstrap mtools xorriso squashfs-tools (auto-installed).
#
# Usage:
#   build-THOR-live-iso.sh [path/to/source.iso]
#
# Output:
#   $BUILD_DIR/jetson-thor-live.iso


set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$HERE/build-thor"
ISO_TREE="$HERE/iso-editable-thor"
CHROOT="$BUILD_DIR/chroot"
OUTPUT_ISO="$BUILD_DIR/jetson-thor-live.iso"
EFI_IMG="$BUILD_DIR/efi.img"
KVER="6.8.12-1021-tegra"

# Hardcoded for the June 2026 source ISO layout. If a future source ISO
# uses a different partition layout these need re-deriving with
# `xorriso -indev <iso> -report_system_area plain`.
EFI_PART_START=8833024   # LBA-512 of GPT partition 2 ("Appended2") in source ISO
EFI_PART_BLOCKS=1048576  # 512 MB

# ── Helpers ──────────────────────────────────────────────────────────
log()  { printf '\033[1;34m::\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[1;31m!! %s\033[0m\n' "$*" >&2; exit 1; }

cleanup_mounts() {
    for d in media/jetson dev/pts dev proc sys run; do
        if sudo mountpoint -q "$CHROOT/$d" 2>/dev/null; then
            sudo umount "$CHROOT/$d" 2>/dev/null \
              || sudo umount -l "$CHROOT/$d" 2>/dev/null \
              || true
        fi
    done
}
trap cleanup_mounts EXIT

# ── 0. Prerequisites ─────────────────────────────────────────────────
[ "$(uname -m)" = aarch64 ] \
    || die "Must run on arm64 (no qemu support in this script)."

shopt -s nullglob
SOURCE_ISO="${1:-}"
if [ -z "$SOURCE_ISO" ]; then
    candidates=( "$HERE"/*.iso )
    [ ${#candidates[@]} -ge 1 ] \
        || die "No source ISO. Pass path as arg 1, or place a source .iso next to this script."
    SOURCE_ISO="${candidates[0]}"
fi
shopt -u nullglob
[ -f "$SOURCE_ISO" ] || die "Source ISO not found: $SOURCE_ISO"
log "Source ISO: $SOURCE_ISO"

need=()
for pkg in debootstrap mtools xorriso squashfs-tools; do
    dpkg -s "$pkg" >/dev/null 2>&1 || need+=("$pkg")
done
if [ ${#need[@]} -gt 0 ]; then
    log "Installing build tools: ${need[*]}"
    sudo apt-get update -qq
    sudo apt-get install -y "${need[@]}"
fi

mkdir -p "$BUILD_DIR"

# ── 1. Extract source ISO tree ───────────────────────────────────────
if [ ! -d "$ISO_TREE/casper" ]; then
    log "Extracting source ISO -> $ISO_TREE"
    mkdir -p "$ISO_TREE"
    xorriso -osirrox on -indev "$SOURCE_ISO" -extract / "$ISO_TREE" 2>&1 | tail -2
fi

# ── 2. Extract EFI partition (used as appended GPT part 2 on re-master) ─
if [ ! -s "$EFI_IMG" ]; then
    log "Extracting EFI partition -> $EFI_IMG (512 MB)"
    dd if="$SOURCE_ISO" of="$EFI_IMG" \
       bs=512 skip="$EFI_PART_START" count="$EFI_PART_BLOCKS" status=none
fi

# ── 3. Debootstrap noble arm64 base ──────────────────────────────────
if [ ! -d "$CHROOT/etc" ]; then
    log "debootstrap noble arm64 -> $CHROOT (~5 min)"
    sudo debootstrap --arch=arm64 --variant=minbase \
        --include=ca-certificates,gnupg,apt-utils \
        noble "$CHROOT" http://ports.ubuntu.com/ubuntu-ports/
fi

# ── 4. Bind-mount chroot, configure apt ──────────────────────────────
log "Mounting chroot binds + apt sources"
for d in dev proc sys run; do
    sudo mountpoint -q "$CHROOT/$d" || sudo mount --bind "/$d" "$CHROOT/$d"
done
sudo mountpoint -q "$CHROOT/dev/pts"     || sudo mount --bind /dev/pts "$CHROOT/dev/pts"
sudo mkdir -p "$CHROOT/media/jetson"
sudo mountpoint -q "$CHROOT/media/jetson" || sudo mount --bind "$ISO_TREE" "$CHROOT/media/jetson"
sudo cp /etc/resolv.conf "$CHROOT/etc/resolv.conf"

sudo tee "$CHROOT/etc/apt/sources.list" > /dev/null <<'EOF'
deb http://ports.ubuntu.com/ubuntu-ports noble main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-backports main restricted universe multiverse
deb [trusted=yes] file:///media/jetson noble main restricted
EOF

# nvidia-l4t-* preinst/postinst skip flag (avoids live-system hardware checks)
sudo mkdir -p "$CHROOT/opt/nvidia/l4t-packages"
sudo touch "$CHROOT/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-preinstall"
sudo touch "$CHROOT/opt/nvidia/l4t-packages/.nv-l4t-disable-boot-fw-update-in-postinstall"

sudo chroot "$CHROOT" apt-get update -qq 2>&1 | tail -3

# ── 5. Install packages ──────────────────────────────────────────────
log "Installing ubuntu-desktop-minimal + casper (~3 min)"
# gnome-keyring + libpam-gnome-keyring are Recommends of
# ubuntu-desktop-minimal that --no-install-recommends drops. Without
# them, /etc/pam.d/gdm-autologin's "auth optional pam_gnome_keyring.so"
# line trips ("PAM adding faulty module: pam_gnome_keyring.so") and
# gnome-shell's session init fails ("Child process was already dead").
# autologin then loops forever, never reaching a usable desktop.
sudo chroot "$CHROOT" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal casper \
    discover laptop-detect os-prober network-manager \
    locales \
    gnome-keyring libpam-gnome-keyring
'

log "Installing platform-specific packages from source ISO (~3 min)"
# Two parallel GPU stacks ship in this source ISO: nvgpu (Orin/T234) and
# openrm (Thor/T264). The Orin path uses the nvgpu kernel driver and a
# stub nvidia-smi; the Thor path uses the unified nvidia.ko (OpenRM)
# kernel driver and full nvidia-smi, and its userspace requires
# nvidia-l4t-gbm for Wayland/EGL buffer allocation. Install BOTH sides
# so the live ISO boots on either SoC family. nvidia-l4t-cuda's Depends
# line ("nvgpu | openrm") otherwise resolves to nvgpu only, which leaves
# Thor without any working GPU userspace and GDM crash-loops on it.
#
# nvidia-l4t-kernel-oot-modules + nvidia-l4t-kernel-module-configs are
# required: nvidia.ko links against symbols (get_drm_num_channels,
# host1x_syncpt_get_shim_info, ...) that live in NVIDIA's out-of-tree
# tegra-drm.ko / host1x.ko / nvhost-*.ko. Without them modprobe loads
# nvidia.ko, fails the symbol relocation, and prints the error in a
# tight loop. The -kernel-module-configs package ships
# /etc/modprobe.d/nvidia-preferred-oot-modules.conf which biases
# modprobe toward the OOT versions over the in-tree ones.
#
# nvidia-l4t-optee provides the OPTEE userspace (tee-supplicant et al.)
# that GSP firmware on the PCIe compute GPU uses to coordinate with the
# SoC display engine at 8808c00000.display. Without it, nvidia.ko sees
# its own PCIe device but "No compatible format found" / "Cannot find
# any crtc or sizes" -- there's no display surface bridge to the SoC
# engine -- and downstream the X session hits "Wait for channel idle
# timed out". The openrm tbz2 install set treats nv_optee.tbz2 as
# mandatory for Thor; I'd been missing it.
#
# vulkan-sc-{openrm,nvgpu} and multimedia-nvgpu are pulled in for parity
# with the openrm tbz2 install list, so the Vulkan SC ICD JSONs and
# nvgpu-side multimedia codecs are present.
#
# nvidia-l4t-firmware (umbrella SoC firmware, NOT the *-{nvgpu,openrm}
# variants) ships /lib/firmware/display-t{234,264}-dce.bin -- the
# Display Control Engine firmware. Without DCE firmware loaded, the
# DCE coprocessor at 8808000000.dce never boots; NVRM's RPC calls to
# it time out (NVRM_RPC_DCE NV_ERR_TIMEOUT in dmesg), nvidia-drm sees
# no display bridge to the SoC display engine, reports "No compatible
# format found" / "Cannot find any crtc or sizes", and Xorg's X driver
# hits "Wait for channel idle timed out". This is a third firmware
# package distinct from -nvgpu/-openrm despite the similar naming.
sudo chroot "$CHROOT" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  apt-get install -y --no-install-recommends \
    nvidia-l4t-core nvidia-l4t-configs nvidia-l4t-init \
    nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-display-kernel \
    nvidia-l4t-3d-core nvidia-l4t-x11 \
    nvidia-l4t-multimedia-utils nvidia-l4t-libvulkan \
    nvidia-l4t-cuda nvidia-l4t-tools nvidia-l4t-nvpmodel \
    nvidia-l4t-nvfancontrol \
    \
    nvidia-l4t-firmware \
    nvidia-l4t-firmware-nvgpu nvidia-l4t-cuda-nvgpu \
    nvidia-l4t-kernel-nvgpu \
    \
    nvidia-l4t-firmware-openrm nvidia-l4t-cuda-openrm \
    nvidia-l4t-init-openrm nvidia-l4t-kernel-openrm \
    nvidia-l4t-multimedia-openrm nvidia-l4t-video-codec-openrm \
    nvidia-l4t-gbm nvidia-l4t-xwayland nvidia-l4t-weston \
    \
    nvidia-l4t-kernel-oot-modules nvidia-l4t-kernel-module-configs \
    \
    nvidia-l4t-optee \
    nvidia-l4t-multimedia-nvgpu \
    nvidia-l4t-vulkan-sc-openrm nvidia-l4t-vulkan-sc-nvgpu
'

log "Installing fonts, SSH, editors, network tools"
# xserver-xorg-legacy ships /usr/lib/xorg/Xorg.wrap (setuid root). NVIDIA's
# X driver needs to bind /var/run/nvidia-xdriver-<rand> on startup; that
# directory is root-only, so Xorg must briefly hold root rights. Without
# Xorg.wrap, X runs as gdm (rootless), the socket bind returns EACCES,
# GPU device init fails, and the desktop never gets a working compositor.
# This is a Recommends of xserver-xorg-core which our --no-install-recommends
# install line drops; explicit here so future-us doesn't lose it again.
sudo chroot "$CHROOT" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  apt-get install -y --no-install-recommends \
    fonts-ubuntu fonts-noto-mono fonts-noto-core fonts-noto-color-emoji \
    openssh-server openssh-client \
    iputils-ping iputils-tracepath \
    nano vim less \
    wget curl \
    xserver-xorg-legacy \
    systemd systemd-sysv systemd-timesyncd libsystemd-shared
'

# ── 6. Configure chroot ──────────────────────────────────────────────
log "Locale + display manager"
sudo chroot "$CHROOT" /bin/bash -c '
  echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
  echo "/usr/sbin/gdm3" > /etc/X11/default-display-manager
'

# Casper derives the live username from .disk/info if FLAVOUR isn't set
# in casper.conf, so this source ISO ("Ubuntu-Server 24.04.3 ...") yields
# the user "ubuntu-server", not "ubuntu". Honor that -- pre-create the
# matching AccountsService config so GDM has a Session/XSession set for
# the user at autologin time. Without this, autologin starts X but no
# session ever runs inside it (GDM doesn't know what to launch).
sudo install -d -m 775 "$CHROOT/var/lib/AccountsService/users"
sudo tee "$CHROOT/var/lib/AccountsService/users/ubuntu-server" > /dev/null <<'EOF'
[User]
Session=ubuntu
XSession=ubuntu
SystemAccount=false
EOF
sudo chmod 600 "$CHROOT/var/lib/AccountsService/users/ubuntu-server"

# Boot-time: inject BusID into /etc/X11/xorg.conf if an NVIDIA PCIe GPU
# is present. Thor needs it (the OpenRM GPU is on PCIe at 01:00.0; without
# BusID Xorg's nvidia driver fails to attach and mutter renders the
# wallpaper but no UI surfaces). Orin's GPU is SoC-integrated (no PCIe
# device, the existing tegra-drm OutputClass snippet handles it), so the
# script no-ops there. The installed JetPack uses nvidia-xconfig at first
# boot to do this; we do the equivalent at every live boot.
sudo install -d -m 755 "$CHROOT/usr/local/sbin"
sudo tee "$CHROOT/usr/local/sbin/jetson-set-xorg-busid" > /dev/null <<'EOF'
#!/bin/sh
set -e
CONF=/etc/X11/xorg.conf
[ -f "$CONF" ] || exit 0
grep -qE '^\s*BusID' "$CONF" && exit 0

BDF=
for d in /sys/bus/pci/devices/*/; do
    [ "$(cat "$d/vendor" 2>/dev/null)" = "0x10de" ] || continue
    cls=$(cat "$d/class" 2>/dev/null)
    case "$cls" in
        0x030000|0x030200|0x038000) BDF=$(basename "$d"); break ;;
    esac
done
[ -n "$BDF" ] || exit 0

# BDF is e.g. "0000:01:00.0" -> bus=01 dev=00 func=0
core=${BDF#0000:}
bus_hex=${core%%:*}
rest=${core#*:}
dev_hex=${rest%.*}
func=${rest#*.}
bus_dec=$(printf '%d' "0x$bus_hex")
dev_dec=$(printf '%d' "0x$dev_hex")
BUSID="PCI:$bus_dec:$dev_dec:$func"

sed -i "/^Section \"Device\"/,/^EndSection/ {
    /Driver[[:space:]]\+\"nvidia\"/a\\    BusID       \"$BUSID\"
}" "$CONF"
echo "jetson-set-xorg-busid: injected $BUSID into $CONF"
EOF
sudo chmod 755 "$CHROOT/usr/local/sbin/jetson-set-xorg-busid"

sudo tee "$CHROOT/etc/systemd/system/jetson-set-xorg-busid.service" > /dev/null <<'EOF'
[Unit]
Description=Inject BusID into /etc/X11/xorg.conf for NVIDIA PCIe GPU
DefaultDependencies=no
After=local-fs.target systemd-tmpfiles-setup.service
Before=display-manager.service gdm.service gdm3.service
ConditionPathExists=/etc/X11/xorg.conf

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/jetson-set-xorg-busid

[Install]
WantedBy=display-manager.service
EOF
sudo chroot "$CHROOT" systemctl enable jetson-set-xorg-busid.service 2>&1 | tail -2 || true

# Force GDM to use X11. NVIDIA L4T's display stack on T264 (Thor) hits
# DRM format-negotiation issues under Wayland ("[drm] No compatible
# format found" + "nvidia-modeset: head configuration (0xff) is
# inconsistent"), which causes mutter to render the wallpaper but fail
# on per-popup surfaces -- menus don't open, the power-icon popover
# never appears. The installed JetPack 7.2 desktop runs on X11 (mutter-
# x11-frame is in its process list, not mutter-wayland). Match that.
sudo install -d -m 755 "$CHROOT/etc/gdm3"
# Replace custom.conf wholesale: enable autologin for the live
# "ubuntu-server" user AND disable Wayland. Casper-bottom/15autologin will sed-replace
# commented placeholders, but if our placeholders aren't in the right
# shape it silently no-ops -- safer to write the final config directly.
sudo tee "$CHROOT/etc/gdm3/custom.conf" > /dev/null <<'EOF'
# GDM configuration storage
#
# See /usr/share/gdm/gdm.schemas for a list of available options.

[daemon]
# Force Xorg session (NVIDIA L4T's display stack is fragile under Wayland
# on Thor; the installed JetPack desktop also uses X).
WaylandEnable=false

# Live-CD autologin. casper-bottom/15autologin's sed only fires against
# commented placeholders, and it gets the username from FLAVOUR (resolved
# from .disk/info -> "ubuntu-server" for this source ISO). We set it
# directly here so the file-shape doesn't matter.
AutomaticLoginEnable=true
AutomaticLogin=ubuntu-server

[security]

[xdmcp]

[chooser]

[debug]
EOF

log "Fontconfig: prefer Ubuntu Mono for monospace alias"
# 60-latin.conf (in fontconfig-config) pins DejaVu Sans Mono first.
# A match/prepend with binding=strong is the only override that wins.
sudo tee "$CHROOT/etc/fonts/conf.d/99-ubuntu-mono-default.conf" > /dev/null <<'EOF'
<?xml version="1.0"?>
<!DOCTYPE fontconfig SYSTEM "fonts.dtd">
<fontconfig>
  <match target="pattern">
    <test qual="any" name="family"><string>monospace</string></test>
    <edit name="family" mode="prepend" binding="strong">
      <string>Ubuntu Mono</string>
    </edit>
  </match>
</fontconfig>
EOF

log "dconf: GNOME Terminal default font"
sudo install -d -m 755 "$CHROOT/etc/dconf/db/local.d" "$CHROOT/etc/dconf/profile"
sudo tee "$CHROOT/etc/dconf/db/local.d/00-jetson-terminal" > /dev/null <<'EOF'
[org/gnome/terminal/legacy/profiles:/:b1dcc9dd-5262-4d8d-a863-c897e6d979b9]
use-system-font=false
font='Ubuntu Mono 12'
EOF
sudo tee "$CHROOT/etc/dconf/profile/user" > /dev/null <<'EOF'
user-db:user
system-db:local
EOF
sudo chroot "$CHROOT" dconf update

log "SSH: enable by default + drop-in to regen host keys on first start"
# The main ssh.service has ExecStartPre=/usr/sbin/sshd -t. With no host
# keys it fails. Drop-in clears the list and re-sets it so keygen runs
# first, then the config test. Host keys are removed at build time so
# every live boot generates a fresh, unique set on first start.
#
# NOTE: the live user "ubuntu-server" has an empty password by default and
# sshd's PermitEmptyPasswords defaults to "no", so SSH-in still requires
# `sudo passwd ubuntu-server` first (or an authorized_keys entry). The service
# itself is just listening and ready.
sudo chroot "$CHROOT" systemctl enable ssh.service 2>&1 | tail -2 || true
sudo rm -f "$CHROOT/etc/ssh/ssh_host_"*
sudo install -d -m 755 "$CHROOT/etc/systemd/system/ssh.service.d"
sudo tee "$CHROOT/etc/systemd/system/ssh.service.d/regen-host-keys.conf" > /dev/null <<'EOF'
[Service]
ExecStartPre=
ExecStartPre=/usr/bin/ssh-keygen -A
ExecStartPre=/usr/sbin/sshd -t
EOF

log "Login hint + motd + manual tweaks script"
sudo tee "$CHROOT/etc/profile.d/00-jetson-live.sh" > /dev/null <<'EOF'
if [ -f /cdrom/casper/desktop/filesystem.squashfs ] && [ -z "$JETSON_LIVE_HINT_SHOWN" ]; then
  export JETSON_LIVE_HINT_SHOWN=1
  echo
  echo "[ Jetson Live ] sshd is already running. To allow SSH-in:"
  echo "    sudo passwd ubuntu-server   # set a password (one-time)"
  echo "    ssh ubuntu-server@\$(hostname -I | awk '{print \$1}')"
  echo
fi
EOF
sudo chmod 644 "$CHROOT/etc/profile.d/00-jetson-live.sh"

sudo tee "$CHROOT/etc/motd" > /dev/null <<'EOF'

  *** Jetson Live (Ubuntu 24.04 / JetPack 7.2) ***

  This is a live system running from removable media.
  Nothing is persisted across reboots unless you install
  to internal storage.

  Live user:  ubuntu-server  (empty password by default)
  SSH:        sshd is running. Set a password with
                "sudo passwd ubuntu-server"
              before SSH-in works (empty passwords rejected).

  To install to disk:
    Reboot and choose "Install Jetson ISO r39.2.0" from the GRUB menu.

EOF

# Optional convenience script. NOT wired into systemd: an earlier attempt
# with After=casper-md5check.service + WantedBy=multi-user.target created
# a dependency cycle and broke boot. Run by hand if you want:
#   sudo /usr/local/sbin/jetson-live-tweaks
sudo install -d -m 755 "$CHROOT/usr/local/sbin"
sudo tee "$CHROOT/usr/local/sbin/jetson-live-tweaks" > /dev/null <<'EOF'
#!/bin/sh
set -e
[ -f /etc/apt/sources.list ] && sed -i '/^[[:space:]]*deb[[:space:]]\+cdrom:/d' /etc/apt/sources.list
for f in /etc/apt/sources.list.d/*.list; do
    [ -f "$f" ] || continue
    sed -i '/^[[:space:]]*deb[[:space:]]\+cdrom:/d' "$f"
done
if getent passwd ubuntu-server >/dev/null 2>&1; then
    echo 'ubuntu-server:ubuntu-server' | chpasswd
fi
EOF
sudo chmod 755 "$CHROOT/usr/local/sbin/jetson-live-tweaks"

# Live-system DNS: write a static /etc/resolv.conf with public fallbacks
# and tell NetworkManager not to overwrite it.
#
# Why static rather than systemd-resolved FallbackDNS: on this live
# system systemd-resolved isn't running (casper / NetworkManager handles
# resolv.conf instead). The noble default symlink
#   /etc/resolv.conf -> /run/systemd/resolve/resolv.conf
# is therefore a broken symlink at runtime and nothing resolves until
# NM rewrites it. NM-supplied DNS (DHCP, IPv6 RA) ends up in
# /run/NetworkManager/no-stub-resolv.conf but doesn't reach /etc/resolv.conf.
#
# Simplest reliable fix: replace the symlink with a real file holding
# 1.1.1.1 and 8.8.8.8, and tell NM rc-manager=unmanaged so it leaves
# the file alone. NM still resolves DNS internally for its own needs;
# legacy tools that getaddrinfo() through /etc/resolv.conf get the
# public servers.
log "Configuring live-system DNS (static /etc/resolv.conf with 1.1.1.1 + 8.8.8.8)"
sudo rm -f "$CHROOT/etc/resolv.conf"
sudo tee "$CHROOT/etc/resolv.conf" > /dev/null <<'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
EOF
sudo install -d -m 755 "$CHROOT/etc/NetworkManager/conf.d"
sudo tee "$CHROOT/etc/NetworkManager/conf.d/01-jetson-static-dns.conf" > /dev/null <<'EOF'
# Don't manage /etc/resolv.conf -- it's static, written by the live ISO
# build script with public DNS fallbacks. NM-supplied DNS (DHCP, IPv6 RA)
# is still tracked internally and visible via "nmcli dev show".
[main]
rc-manager=unmanaged
EOF

# Copy utility-scripts/ into /opt/utility-scripts/ in the chroot.
# Intentionally NOT on $PATH -- run as /opt/utility-scripts/<name> when
# wanted. Idempotent: install -m re-copies cleanly. Skipped if no
# utility-scripts/ directory exists alongside this build script.
# Also drop the NVIDIA L4T signing key next to the scripts so
# jetson-rescue can deploy the apt source onto a rescue target.
if [ -d "$HERE/utility-scripts" ]; then
    log "Installing utility-scripts -> /opt/utility-scripts/"
    sudo install -d -m 755 "$CHROOT/opt/utility-scripts"
    for f in "$HERE"/utility-scripts/*; do
        [ -f "$f" ] || continue
        sudo install -m 755 "$f" "$CHROOT/opt/utility-scripts/$(basename "$f")"
    done
    if [ -f "$HERE/apt/jetson-ota-public.asc" ]; then
        sudo install -m 644 "$HERE/apt/jetson-ota-public.asc" \
            "$CHROOT/opt/utility-scripts/jetson-ota-public.asc"
    fi
fi

# Quiet NetworkManager's "Activation of network connection failed"
# notification on the desktop. On Jetsons multiple Ethernet interfaces
# show up (mgbe0_0..mgbe3_0) and only one is typically plugged in; NM
# tries to activate all of them every ~30s and the gnome-shell notifier
# pops the failure each time.
#
# Two complementary knobs:
#   1. NM connection defaults: limit auto-connect retries to 1 so NM
#      stops retrying failed activations indefinitely. Wired connections
#      still come up on first try when a cable is present.
#   2. dconf: silence the gnome-shell "connection-removed"/"activation-
#      failed" notifications from NetworkManager source so they never
#      reach the screen.
sudo install -d -m 755 "$CHROOT/etc/NetworkManager/conf.d"
sudo tee "$CHROOT/etc/NetworkManager/conf.d/00-jetson-no-retry.conf" > /dev/null <<'EOF'
# Stop retrying failed auto-connect attempts. Cable-plugged wired ports
# still come up on their first attempt; ports with no cable / no DHCP
# server give up after one try instead of every 30s forever.
[connection]
connection.autoconnect-retries=1
EOF

sudo install -d -m 755 "$CHROOT/etc/dconf/db/local.d"
sudo tee "$CHROOT/etc/dconf/db/local.d/01-jetson-no-nm-notify" > /dev/null <<'EOF'
# Suppress GNOME notifications from the NetworkManager applet. With
# autoconnect-retries=1 above the underlying retry storm stops too, but
# this keeps any remaining transient errors from popping a toast.
[org/gnome/desktop/notifications/application/gnome-network-panel]
enable=false

[org/gnome/desktop/notifications/application/nm-applet]
enable=false
EOF
# dconf update was already invoked earlier in the script for the
# terminal-font defaults; we re-run it so this new key file is compiled.
sudo chroot "$CHROOT" dconf update

# Pre-deploy the OpenRM (Thor) display module configs that
# nv-load-display-modules.service would normally deploy at first boot.
# The service runs too late: kernel auto-loads nvgpu via udev before
# the service can drop `install nvgpu /bin/false` into modprobe.d/, so
# nvgpu claims the GPU and nvidia.ko fails to bind. Pre-deploying at
# build time puts the right config in /etc/modprobe.d/ before the first
# boot's modprobe walks the directory. Also write the matching stamp
# file so the boot service's "configuration unchanged" check passes
# and it no-ops instead of redoing the work.
#
# This bakes the squashfs to the openrm/Thor stack. The same ISO will
# still boot Orin from the rescue/install entries (they use a different
# initrd) but the Live Desktop entry's squashfs is now Thor-targeted.
# Add gdm (and gnome-initial-setup if present) to the "video" and "render"
# groups so GDM can open /dev/dri/card* and /dev/dri/renderD* to take DRM
# master. Without this, mutter can render the wallpaper via the existing
# framebuffer but cannot bind input devices, cannot accept VT switches
# (Ctrl+Alt+F-keys do nothing), and cannot create popup surfaces -- menus
# never appear. NVIDIA's nv-graphics.sh does this on installed systems;
# we replicate it at build time so the live ISO has it baked in.
log "Adding gdm to video + render groups"
sudo chroot "$CHROOT" /bin/bash -c '
  for u in gdm gnome-initial-setup; do
    getent passwd "$u" >/dev/null 2>&1 || continue
    for g in video render; do
      getent group "$g" >/dev/null 2>&1 || continue
      adduser --quiet "$u" "$g" 2>&1 | grep -v "Adding user" || true
    done
  done
  id gdm 2>/dev/null
'

# The autologin user (created at runtime by casper, uid=1000) ALSO needs
# the video+render groups, otherwise gnome-shell as that user fails with
# "NvRmMemInitNvmap failed: error Permission denied", crashes immediately,
# and gnome-session falls through to gnome-session-failed. We can't add
# at build time because casper creates the user at boot, so drop a tiny
# systemd one-shot that runs before display-manager.service.
sudo tee "$CHROOT/usr/local/sbin/jetson-add-live-user-groups" > /dev/null <<'EOF'
#!/bin/sh
# Find casper's live user (uid 1000) and ensure they can:
#   - video  : open /dev/nvmap + /dev/dri/card* (mode 0440/0660 root:video)
#   - render : open /dev/dri/renderD* (mode 0660 root:render)
#   - gdm    : read /run/user/1000/gdm/Xauthority (mode 0640 root:gdm)
#              without which gnome-shell can't authenticate to Xorg
#   - audio, plugdev : sundry desktop things
# Idempotent: adduser is a no-op when membership already exists.
set -e
LIVE_USER=$(getent passwd | awk -F: '$3 == 1000 {print $1; exit}')
[ -n "$LIVE_USER" ] || exit 0
for g in video render gdm audio plugdev weston-launch; do
    getent group "$g" >/dev/null 2>&1 || continue
    adduser --quiet "$LIVE_USER" "$g" 2>/dev/null || true
done
EOF
sudo chmod 755 "$CHROOT/usr/local/sbin/jetson-add-live-user-groups"

sudo tee "$CHROOT/etc/systemd/system/jetson-add-live-user-groups.service" > /dev/null <<'EOF'
[Unit]
Description=Add live user (uid 1000) to video + render groups
After=systemd-user-sessions.service
Before=display-manager.service gdm.service gdm3.service
ConditionPathExists=/cdrom/casper

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/sbin/jetson-add-live-user-groups

[Install]
WantedBy=display-manager.service
EOF
sudo chroot "$CHROOT" systemctl enable jetson-add-live-user-groups.service 2>&1 | tail -2 || true

# Three configs that NVIDIA's apply_binaries.sh --openrm (tbz2 path) drops on
# installed systems but that the apt-installable .deb doesn't ship.
# Without these:
#   - nvidia.ko boots without NVreg_TegraGpuPgMask=512 (Thor-specific
#     power-gating mask) -- GPU command channel hangs under load
#     ("Wait for channel idle timed out").
#   - nv-gpu-static-pg.ko has no gpu_pg_mask_param option, so the
#     install hook in nvidia-display.conf reads the wrong value.
#   - The softdep ordering "governor_pod_scaling pre nvidia" never
#     fires; nvidia.ko initializes against an unstable PM governor.
# gpu_pg_mask value is Thor (T264) specific: 512 vs the package default
# of 4294967295. Wrong value sets bits the SoC doesn't have, which is
# what causes channel timeouts even after DCE firmware loads cleanly.
log "Deploying missing NVIDIA modprobe configs (nvidia-unifiedgpudisp + nv-gpu-static-pg)"
sudo tee "$CHROOT/etc/modprobe.d/nvidia-unifiedgpudisp.conf" > /dev/null <<'EOF'
options nvidia NVreg_TegraGpuPgMask=512
options nvidia-drm modeset=1
softdep nvidia pre: governor_pod_scaling post: nvidia-uvm
EOF
sudo tee "$CHROOT/etc/modprobe.d/nv-gpu-static-pg.conf" > /dev/null <<'EOF'
options nv-gpu-static-pg gpu_pg_mask_param=4294967295
EOF
# Override the package's gpu_pg_mask default (4294967295) with the
# Thor-specific value (512). nvidia-display.conf's install hook reads
# this file at modprobe time and passes the value as gpu_pg_mask.
sudo install -d "$CHROOT/opt/nvidia/l4t-gpusetup"
sudo tee "$CHROOT/opt/nvidia/l4t-gpusetup/gpu_pg_mask" > /dev/null <<'EOF'
gpu_pg_mask_param=512
EOF

log "Pre-deploying OpenRM display module configs"
# Make the choice deterministic: nv-load-display-modules.sh honors this
# file ahead of /proc/device-tree autodetection. Pinning it to openrm-l4t
# ensures the right variant is selected even if the device-tree state is
# read oddly, a future kernel upgrade invalidates our stamp file, or the
# build host's SoC differs from the target's (build-on-Thor for Thor today,
# but flexible later).
echo "openrm-l4t" | sudo tee "$CHROOT/etc/nvidia-gpu-driver-override" > /dev/null

NV_CFG_DIR=/opt/nvidia/nv-disp-module-configs
NV_MODPROBE_SRC="$NV_CFG_DIR/nv-modprobe-openrm-l4t-display.conf"
NV_DEPMOD_SRC="$NV_CFG_DIR/nv-depmod-openrm-l4t-display.conf"
if [ -f "$CHROOT$NV_MODPROBE_SRC" ] && [ -f "$CHROOT$NV_DEPMOD_SRC" ]; then
    sudo install -d "$CHROOT/etc/modprobe.d" "$CHROOT/etc/depmod.d" \
                    "$CHROOT/var/lib/nvidia"
    sudo cp "$CHROOT$NV_MODPROBE_SRC" "$CHROOT/etc/modprobe.d/nvidia-display.conf"
    sudo cp "$CHROOT$NV_DEPMOD_SRC"   "$CHROOT/etc/depmod.d/nvidia-display.conf"
    # Add /opt/nvidia/l4t-gpu-libs/openrm to the dynamic linker path so
    # libcuda.so / libnvidia-vksc-*.so are found.
    echo "/opt/nvidia/l4t-gpu-libs/openrm" \
        | sudo tee "$CHROOT/etc/ld.so.conf.d/000-nvidia-gpu-libs.conf" > /dev/null
    # Refresh module dependencies for the L4T kernel we installed.
    sudo chroot "$CHROOT" depmod -a "$KVER"
    # Refresh ld.so cache so the new library path is picked up.
    sudo chroot "$CHROOT" ldconfig
    # Stamp file the boot service consults to decide whether to redeploy.
    L4T_INIT_VER=$(sudo chroot "$CHROOT" dpkg-query -W -f='${Version}' nvidia-l4t-init 2>/dev/null)
    echo "$NV_DEPMOD_SRC:$NV_MODPROBE_SRC:$KVER:$L4T_INIT_VER" \
        | sudo tee "$CHROOT/var/lib/nvidia/nv-display.stamp" > /dev/null
    log "  modprobe.d/nvidia-display.conf + depmod.d + ld.so.conf.d + stamp written"
else
    log "  WARN: OpenRM templates not found under $NV_CFG_DIR — skipping pre-deploy"
fi

# The Tegra kernel package doesn't ship /boot/config-* so initramfs-tools
# can't verify CONFIG_RD_ZSTD. Therefore use gzip; universally supported.
sudo sed -i 's/^COMPRESS=.*/COMPRESS=gzip/' "$CHROOT/etc/initramfs-tools/initramfs.conf"

# Quiet the "W: Possible missing firmware /lib/firmware/nvidia/tegraNNN/xusb.bin"
# warnings from update-initramfs. xhci_tegra is built-in and declares
# MODULE_FIRMWARE() for every Tegra generation it can drive, so the static
# check warns on every blob the chroot doesn't ship. Orin/Thor don't need
# these at runtime (USB enumerates without them), but copying the blobs
# in from the host's linux-firmware shipment silences the warnings and
# costs ~40 KB. update-initramfs only matches the uncompressed .bin name,
# so we zstd-decompress the host's .bin.zst into the chroot.
if command -v zstd >/dev/null 2>&1; then
    for gen in tegra124 tegra186 tegra194 tegra210; do
        src="/lib/firmware/nvidia/$gen/xusb.bin.zst"
        [ -f "$src" ] || continue
        dst_dir="$CHROOT/lib/firmware/nvidia/$gen"
        dst="$dst_dir/xusb.bin"
        [ -f "$dst" ] && continue
        sudo install -d "$dst_dir"
        sudo zstd -d -q -o "$dst" "$src"
    done
fi

log "Generating casper initrd for $KVER (~30 s)"
sudo chroot "$CHROOT" update-initramfs -c -k "$KVER" 2>&1 | tail -2

# ── 7. Cleanup chroot before squashfs ────────────────────────────────
log "Cleanup chroot"
sudo chroot "$CHROOT" /bin/bash -c '
  apt-get clean
  rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
  rm -f /var/log/*.log /var/log/*/*.log
  rm -f /etc/machine-id /var/lib/dbus/machine-id
  touch /etc/machine-id
  cat > /etc/apt/sources.list <<APT
deb http://ports.ubuntu.com/ubuntu-ports noble main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-updates main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-security main restricted universe multiverse
deb http://ports.ubuntu.com/ubuntu-ports noble-backports main restricted universe multiverse
APT
  rm -rf /opt/nvidia/l4t-packages
'

# Deploy the NVIDIA L4T apt repo so the live system can `apt install`
# nvidia-l4t-* packages without manually adding the source.
#   apt/jetson-ota-public.asc           -> /usr/share/keyrings/
#   apt/nvidia-l4t-apt-source.list      -> /etc/apt/sources.list.d/
# We pin the keyring on the deb lines (signed-by=...) so apt validates
# the signature without trusting the key globally.
if [ -f "$HERE/apt/jetson-ota-public.asc" ] \
   && [ -f "$HERE/apt/nvidia-l4t-apt-source.list" ]; then
    log "Deploying NVIDIA L4T apt source + signing key"
    sudo install -d -m 755 "$CHROOT/usr/share/keyrings" "$CHROOT/etc/apt/sources.list.d"
    sudo install -m 644 "$HERE/apt/jetson-ota-public.asc" \
        "$CHROOT/usr/share/keyrings/jetson-ota-public.asc"
    # Re-emit the source list with signed-by= so apt uses our keyring.
    sudo tee "$CHROOT/etc/apt/sources.list.d/nvidia-l4t.list" > /dev/null <<'NVIDIA_APT'
deb [signed-by=/usr/share/keyrings/jetson-ota-public.asc] https://repo.download.nvidia.com/jetson/common r39.2 main
deb [signed-by=/usr/share/keyrings/jetson-ota-public.asc] https://repo.download.nvidia.com/jetson/som r39.2 main
deb [signed-by=/usr/share/keyrings/jetson-ota-public.asc] https://repo.download.nvidia.com/jetson/ffmpeg r39.2 main
NVIDIA_APT
fi

# Baseline system clock. Jetson Thor / Orin have no RTC battery; on
# every cold boot the kernel falls back to its compile-time epoch
# (months in the past). apt rejects Ubuntu Release files as "not yet
# valid" until NTP sync completes. systemd-timesyncd reads the mtime of
# /var/lib/systemd/timesync/clock at every boot and bumps the system
# clock to at least that timestamp -- a "clock can never go backwards"
# guarantee. Touching the file here with the current build time means
# the live ISO always starts up at a timestamp newer than the Release
# files' signing date.
#
# Also enable timesyncd and configure NTP fallbacks (pool.ntp.org +
# time.cloudflare.com) so once the network comes up the clock syncs to
# real time within seconds. The default ntp.ubuntu.com fallback isn't
# always reachable.
log "Setting baseline system clock + enabling timesyncd"
sudo install -d -m 755 "$CHROOT/var/lib/systemd/timesync"
sudo touch "$CHROOT/var/lib/systemd/timesync/clock"
sudo install -d -m 755 "$CHROOT/etc/systemd/timesyncd.conf.d"
sudo tee "$CHROOT/etc/systemd/timesyncd.conf.d/jetson-ntp.conf" > /dev/null <<'EOF'
[Time]
NTP=pool.ntp.org time.cloudflare.com
FallbackNTP=ntp.ubuntu.com time.google.com
EOF
sudo chroot "$CHROOT" systemctl enable systemd-timesyncd.service 2>&1 | tail -2 || true

# mksquashfs records the root inode's uid/gid; chroot dir owned by builder
# would leak into the squashfs (uid 1000 owns "/" on live boot). Reset to root.
sudo chown root:root "$CHROOT"
cleanup_mounts

# ── 8. Build squashfs ────────────────────────────────────────────────
# xz + arm BCJ filter compresses arm64 binaries 8-12% better than zstd.
# zstd is also unavailable: the 6.8.12-tegra kernel lacks CONFIG_SQUASHFS_ZSTD.
log "Building squashfs (xz, ~15 min)"
SQUASHFS="$BUILD_DIR/filesystem.squashfs"
sudo rm -f "$SQUASHFS"
sudo mksquashfs "$CHROOT" "$SQUASHFS" \
    -comp xz -Xbcj arm \
    -noappend -no-progress -wildcards \
    -e proc/* sys/* dev/* run/* tmp/* \
       boot/initrd.img-* boot/Image \
       var/tmp/* var/cache/apt/archives/*.deb \
       var/lib/apt/lists/* opt/nvidia/l4t-packages \
    2>&1 | tail -3

# ── 9. Assemble ISO tree ─────────────────────────────────────────────
log "Installing squashfs into ISO tree"
CASPER="$ISO_TREE/casper"
sudo chmod -R u+w "$CASPER"
sudo mkdir -p "$CASPER/desktop"
sudo cp "$SQUASHFS" "$CASPER/desktop/filesystem.squashfs"
sudo chroot "$CHROOT" dpkg-query -W --showformat='${Package} ${Version}\n' \
    | sudo tee "$CASPER/desktop/filesystem.manifest" > /dev/null
sudo du -sx --block-size=1 "$CHROOT" | awk '{print $1}' \
    | sudo tee "$CASPER/desktop/filesystem.size" > /dev/null

# Install our desktop initrd alongside the original server-installer initrd.
# Live entries point at initrd-live; Install entries keep using initrd.
sudo cp "$CHROOT/boot/initrd.img-$KVER" "$CASPER/initrd-live"

# Restore the original placeholder filesystem.manifest/size used by the
# server-installer flow (they got overwritten earlier when I naively
# treated /casper/ as the live squashfs location).
TMP_RESTORE="$BUILD_DIR/restore"
mkdir -p "$TMP_RESTORE"
xorriso -osirrox on -indev "$SOURCE_ISO" \
    -extract /casper/filesystem.manifest "$TMP_RESTORE/fs.manifest" \
    -extract /casper/filesystem.size     "$TMP_RESTORE/fs.size" 2>&1 | tail -1
sudo cp "$TMP_RESTORE/fs.manifest" "$CASPER/filesystem.manifest"
sudo cp "$TMP_RESTORE/fs.size"     "$CASPER/filesystem.size"

log "Writing grub.cfg"
# Live entries use live-media-path=/casper/desktop so casper only sees our
# squashfs and doesn't auto-stack with the server-installer layered ones.
sudo tee "$ISO_TREE/boot/grub/grub.cfg" > /dev/null <<'GRUB_EOF'
set menu_color_normal=white/black
set menu_color_highlight=black/light-gray

insmod gzio

set default=0
set timeout=10

menuentry "Jetson Live Desktop (Repair / Inspect)" {
    linux /casper/Image boot=casper live-media-path=/casper/desktop quiet splash fsck.mode=skip mminit_loglevel=4 clk_ignore_unused pd_ignore_unused firmware_class.path=/etc/firmware fbcon=map:0 nospectre_bhb efi=runtime rd.driver.blacklist=nouveau nouveau.modeset=0 cloud-init=disabled
    initrd /casper/initrd-live
}

menuentry "Live Text Shell (no GUI, for diagnostics)" {
    linux /casper/Image boot=casper live-media-path=/casper/desktop boot-live-env fsck.mode=skip mminit_loglevel=4 clk_ignore_unused pd_ignore_unused firmware_class.path=/etc/firmware fbcon=map:0 nospectre_bhb efi=runtime rd.driver.blacklist=nouveau nouveau.modeset=0 cloud-init=disabled systemd.unit=rescue.target
    initrd /casper/initrd-live
}

submenu "Install Jetson ISO r39.2.0" {
    menuentry "Install on NVMe" {
        linux /casper/Image autoinstall fsck.mode=skip force-bootdisk=nvme0n1 mminit_loglevel=4 clk_ignore_unused pd_ignore_unused firmware_class.path=/etc/firmware fbcon=map:0 nospectre_bhb efi=runtime rd.driver.blacklist=nouveau nouveau.modeset=0 cloud-init=disabled loglevel=debug subiquity.debug
        initrd /casper/initrd
    }

    menuentry "Install on USB" {
        linux /casper/Image autoinstall fsck.mode=skip mminit_loglevel=4 clk_ignore_unused pd_ignore_unused firmware_class.path=/etc/firmware fbcon=map:0 nospectre_bhb efi=runtime rd.driver.blacklist=nouveau nouveau.modeset=0 cloud-init=disabled loglevel=debug subiquity.debug
        initrd /casper/initrd
    }

    menuentry "Install on eMMC (for AGX Orin)" {
        linux /casper/Image autoinstall fsck.mode=skip force-bootdisk=mmcblk0 mminit_loglevel=4 clk_ignore_unused pd_ignore_unused firmware_class.path=/etc/firmware fbcon=map:0 nospectre_bhb efi=runtime rd.driver.blacklist=nouveau nouveau.modeset=0 cloud-init=disabled loglevel=debug subiquity.debug
        initrd /casper/initrd
    }

    menuentry "Install on microSD (for Orin Nano/NX)" {
        linux /casper/Image autoinstall fsck.mode=skip force-bootdisk=mmcblkn mminit_loglevel=4 clk_ignore_unused pd_ignore_unused firmware_class.path=/etc/firmware fbcon=map:0 nospectre_bhb efi=runtime rd.driver.blacklist=nouveau nouveau.modeset=0 cloud-init=disabled loglevel=debug subiquity.debug
        initrd /casper/initrd
    }

    menuentry "Boot Into Rescue Shell" {
        linux /casper/Image autoinstall fsck.mode=skip boot-live-env systemd.unit=rescue.target mminit_loglevel=4 clk_ignore_unused pd_ignore_unused firmware_class.path=/etc/firmware fbcon=map:0 nospectre_bhb efi=runtime rd.driver.blacklist=nouveau nouveau.modeset=0
        initrd /casper/initrd
    }

    menuentry "Check Disc for Defects" {
        linux /casper/Image autoinstall md5checkdisc mminit_loglevel=4 clk_ignore_unused pd_ignore_unused firmware_class.path=/etc/firmware fbcon=map:0 nospectre_bhb efi=runtime rd.driver.blacklist=nouveau nouveau.modeset=0
        initrd /casper/initrd
    }
}

menuentry 'Boot from next volume' {
    exit 1
}

menuentry 'UEFI Firmware Settings' {
    fwsetup
}
GRUB_EOF

log "Regenerating md5sum.txt (~30 s)"
( cd "$ISO_TREE" \
  && sudo find . -type f -not -name 'md5sum.txt' -print0 \
     | xargs -0 md5sum \
     | sudo tee md5sum.txt > /dev/null )

# ── 10. Re-master ISO ────────────────────────────────────────────────
log "Re-mastering -> $OUTPUT_ISO"
xorriso -as mkisofs \
    -V 'jetsoninstaller-r39.2.0' \
    -o "$OUTPUT_ISO" \
    -r -J -joliet-long -iso-level 3 \
    -appended_part_as_gpt \
    -append_partition 2 0xef "$EFI_IMG" \
    -partition_offset 16 \
    -no-emul-boot \
    -e '--interval:appended_partition_2:all::' \
    "$ISO_TREE" 2>&1 | tail -4

log "Done: $OUTPUT_ISO  ($(du -h "$OUTPUT_ISO" | cut -f1))"
log ""
log "Burn with: 1, 2, or 3"
log " 1. Balena Etcher"
log " 2. sudo apt install usb-creator-gtk and then: usb-creator-gtk; Click 'other' to select build-thor/jetson-thor-live.iso"
log " 3. sudo wipefs -a /dev/sdX"
log "    sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync oflag=direct"
log "    sudo sync"
