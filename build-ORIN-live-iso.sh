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
#   build-ORIN-live-iso.sh [path/to/source.iso]
#
# Output:
#   $BUILD_DIR/jetson-orin-live.iso
#

set -euo pipefail

# ── Paths ────────────────────────────────────────────────────────────
HERE="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$HERE/build"
ISO_TREE="$HERE/iso-editable"
CHROOT="$BUILD_DIR/chroot"
OUTPUT_ISO="$BUILD_DIR/jetson-orin-live.iso"
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
sudo chroot "$CHROOT" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  apt-get install -y --no-install-recommends \
    ubuntu-desktop-minimal casper \
    discover laptop-detect os-prober network-manager \
    locales
'

log "Installing platform-specific packages from source ISO (~2 min)"
sudo chroot "$CHROOT" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  apt-get install -y --no-install-recommends \
    nvidia-l4t-core nvidia-l4t-configs nvidia-l4t-init \
    nvidia-l4t-firmware-nvgpu \
    nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-display-kernel \
    nvidia-l4t-3d-core nvidia-l4t-x11 \
    nvidia-l4t-multimedia-utils nvidia-l4t-libvulkan \
    nvidia-l4t-cuda nvidia-l4t-tools nvidia-l4t-nvpmodel \
    nvidia-l4t-nvfancontrol
'

log "Installing fonts, SSH, editors, network tools"
sudo chroot "$CHROOT" /bin/bash -c '
  export DEBIAN_FRONTEND=noninteractive LC_ALL=C
  apt-get install -y --no-install-recommends \
    fonts-ubuntu fonts-noto-mono fonts-noto-core fonts-noto-color-emoji \
    openssh-server openssh-client \
    iputils-ping iputils-tracepath \
    nano vim less
'

# ── 6. Configure chroot ──────────────────────────────────────────────
log "Locale + display manager"
sudo chroot "$CHROOT" /bin/bash -c '
  echo "en_US.UTF-8 UTF-8" > /etc/locale.gen
  locale-gen
  update-locale LANG=en_US.UTF-8
  echo "/usr/sbin/gdm3" > /etc/X11/default-display-manager
'

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

log "SSH: disable by default + drop-in to regen host keys on first start"
# The main ssh.service has ExecStartPre=/usr/sbin/sshd -t. With no host
# keys it fails. Drop-in clears the list and re-sets it so keygen runs
# first, then the config test.
sudo chroot "$CHROOT" systemctl disable ssh.service ssh.socket 2>&1 | tail -2 || true
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
  echo "[ Jetson Live ] To enable SSH-in:"
  echo "    sudo passwd ubuntu               # set a password"
  echo "    sudo systemctl enable --now ssh"
  echo
fi
EOF
sudo chmod 644 "$CHROOT/etc/profile.d/00-jetson-live.sh"

sudo tee "$CHROOT/etc/motd" > /dev/null <<'EOF'

  *** Jetson Live (Ubuntu 24.04 / JetPack 7.2) ***

  This is a live system running from removable media.
  Nothing is persisted across reboots unless you install
  to internal storage.

  Live user:  ubuntu  (empty password by default;
                       run "sudo passwd ubuntu" before SSH-in)

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
if getent passwd ubuntu >/dev/null 2>&1; then
    echo 'ubuntu:ubuntu' | chpasswd
fi
EOF
sudo chmod 755 "$CHROOT/usr/local/sbin/jetson-live-tweaks"

# The Tegra kernel package doesn't ship /boot/config-* so initramfs-tools
# can't verify CONFIG_RD_ZSTD. Use gzip; universally supported.
sudo sed -i 's/^COMPRESS=.*/COMPRESS=gzip/' "$CHROOT/etc/initramfs-tools/initramfs.conf"
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
# server-installer flow (they got overwritten earlier when we naively
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

    menuentry "Install on microSD (for AGX Orin, Orin Nano/NX)" {
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
log " 2. sudo apt install usb-creator-gtk and then: usb-creator-gtk; Click 'other' to select build/jetson-orin-live.iso"
log " 3. sudo wipefs -a /dev/sdX"
log "    sudo dd if=$OUTPUT_ISO of=/dev/sdX bs=4M status=progress conv=fsync oflag=direct"
log "    sudo sync"
