# Jetson Live ISO

Builds a bootable Ubuntu 24.04 (noble) live ISO for NVIDIA Jetson devices
running JetPack 7.2 (L4T r39.2.0). The ISO boots straight into a GNOME
desktop without modifying anything on the target device — useful for
repair, inspection, backup, and as a JetPack-7.2 installer all on one
USB stick.

Two parallel build scripts are provided because the GPU initialization
path differs significantly between the two SoC families:

| Script | Target | Output |
|---|---|---|
| `build-THOR-live-iso.sh` | Jetson AGX Thor (T264) | `build/jetson-thor-live.iso` |
| `build-ORIN-live-iso.sh` | Jetson AGX/NX/Nano Orin (T234) | `build/jetson-orin-live.iso` |

## Quick start

```bash
# Build a Thor live ISO (must run on a Thor host — arm64 native):
./build-THOR-live-iso.sh ./jetsoninstaller-r39.2.0-2026-06-01-23-53-13-arm64.iso

# Or, if the source ISO is already in this directory:
./build-THOR-live-iso.sh
```

The build runs ~25 minutes from a clean state (debootstrap ~5 min, apt
~5 min, mksquashfs ~15 min). Re-runs after a successful build are
incremental — most stages skip if their output already exists. To force
a full clean rebuild:

```bash
sudo rm -rf build/chroot
./build-THOR-live-iso.sh
```

Write the resulting ISO to a USB stick with Balena Etcher, `usb-creator-gtk`,
or `dd`. Each script prints the exact `dd`/Etcher commands at the end of
its run.

## What you need

- **Host**: arm64 (aarch64). The build does not cross-compile — run it on
  a Jetson device, not a desktop x86 box.
- **Source ISO**: `jetsoninstaller-r39.2.0-*.iso` from NVIDIA. The build
  reuses this ISO's UEFI boot artifacts, kernel, and platform packages.
- **Free disk**: ~20 GB in the directory where you run the script.
- **Tools**: `debootstrap`, `mtools`, `xorriso`, `squashfs-tools`. The
  scripts will `apt install` them if missing.

## Boot menu

The live ISO's GRUB menu has:

1. **Jetson Live Desktop (Repair / Inspect)** — default. Boots a full
   GNOME desktop session as user `ubuntu-server` (autologin, no password
   prompt). Nothing on the target device is touched.
2. **Live Text Shell (no GUI, for diagnostics)** — drops into a single-
   user rescue shell. Useful if the desktop boot regresses on a future
   JetPack release.
3. **Install Jetson ISO r39.2.0** — the original JetPack installer's
   six install entries (NVMe / USB / eMMC / microSD / rescue / disc check),
   preserved verbatim. The same USB stick is also a JetPack installer.
4. **Boot from next volume** / **UEFI Firmware Settings** — standard GRUB.

## Live system extras

Built into the squashfs:

- `nano`, `vim`, `less`, `iputils-ping`, `iputils-tracepath`
- `openssh-server` (running by default; set a password with
  `sudo passwd ubuntu-server` before the first SSH-in)
- All the `nvidia-l4t-*` userspace + kernel modules for whichever Jetson
  family the script targets, so `nvidia-smi`, CUDA, GBM, X11 etc. work.

The utility scripts in `utility-scripts/` are **not** baked into the ISO
(too easy for an unintended file to break GUI). To use them on a running
live system, `scp` whichever ones you want into `/usr/local/bin/`:

| Script | Purpose |
|---|---|
| `jetson-info` | One-screen status: SKU, JetPack version, RAM, NVP mode, lsblk, networking, thermals, GPU. |
| `jetson-mount-rootfs` | Mount the installed APP partition at `/mnt/jetson` (auto-detects via GPT label, FS label, or `/etc/nv_tegra_release`). |
| `jetson-chroot` | Set up bind mounts on a mounted `/mnt/jetson` and drop into a chroot shell. |
| `jetson-rescue` | One-shot combo: mount + chroot in one command. The usual choice for "boot live, fix installed system". |
| `jetson-backup` | `rsync -aAXH --numeric-ids` of an installed rootfs to local or remote. |

## Stages the build runs

| # | Step | Idempotent? |
|---|---|---|
| 0 | Check `arch=arm64`, resolve source ISO, auto-install build deps | yes |
| 1 | `xorriso -osirrox` → `iso-editable/` | skipped if `iso-editable/casper/` exists |
| 2 | `dd` extract EFI partition → `build/efi.img` | skipped if file exists |
| 3 | `debootstrap noble arm64` → `build/chroot/` | skipped if `chroot/etc/` exists |
| 4 | Bind-mount `/dev /proc /sys /run /dev/pts` + `iso-editable→/media/jetson`; configure apt sources | re-runs cheaply |
| 5 | Install `ubuntu-desktop-minimal`, casper, L4T stack, fonts, ssh, editors | apt handles dups |
| 6 | All chroot config — locale, fontconfig, dconf, ssh drop-in, motd, autologin, AccountsService, modprobe pre-deploy, BusID injector, runtime group-add unit, initrd | overwrites in place |
| 7 | Chroot cleanup (apt clean, machine-id reset, L4T skip-flags removal); `chown root:root` on `/chroot` | yes |
| 8 | `mksquashfs -comp xz -Xbcj arm` | always rebuilds |
| 9 | Copy squashfs+manifest+size into `casper/desktop/`, install `casper/initrd-live`, write grub.cfg, regenerate `md5sum.txt` | always |
| 10 | `xorriso -as mkisofs` with appended GPT EFI partition | always |

## Footguns folded into the scripts as comments

If you're reading through `build-THOR-live-iso.sh` and wondering why
something is done a particular way, every non-obvious choice has a
comment block above it. Highlights:

- **Must run on arm64.** No qemu cross-compile path.
- **`-Xbcj arm` for squashfs** — the Tegra kernel lacks `CONFIG_SQUASHFS_ZSTD`,
  so xz with the ARM BCJ filter is the right compression.
- **`COMPRESS=gzip` for initrd** — the L4T kernel deb doesn't ship
  `/boot/config-*` so initramfs-tools can't verify CONFIG_RD_ZSTD.
- **`live-media-path=/casper/desktop`** — casper auto-stacks every
  `*.squashfs` in `/casper/`; the JetPack ISO has six server-installer
  ones that would shadow our desktop overlay. Putting our squashfs in a
  subdirectory and pointing casper at it bypasses the stack.
- **The SSH drop-in clears `ExecStartPre`** because the main `ssh.service`
  runs `sshd -t` (config test) before our `ssh-keygen -A`; we reset the
  list and re-set it in the right order.
- **`chown root:root /chroot` before mksquashfs** — otherwise `/` in the
  live system ends up owned by the build user.

## The Thor-specific fixes

`build-THOR-live-iso.sh` includes a chain of fixes that are *not* needed
on Orin but are mandatory on Thor. If you're ever wondering "why is this
in the script", the deep reference is `openrm_tbz2.txt` (the authoritative
list of tbz2 packages that NVIDIA's `apply_binaries.sh --openrm` ships).
NVIDIA's apt-installable `.debs` are missing pieces that the tbz2 path
ships, and several modprobe configs / firmware blobs must be pre-deployed.
The script does this automatically.

The short list of T264-specific knobs the Thor script sets that the Orin
script doesn't:

- `/etc/nvidia-gpu-driver-override = openrm-l4t`
- `/etc/modprobe.d/nvidia-unifiedgpudisp.conf` with `NVreg_TegraGpuPgMask=512`
- `/etc/modprobe.d/nv-gpu-static-pg.conf` with `gpu_pg_mask_param=4294967295`
- `/opt/nvidia/l4t-gpusetup/gpu_pg_mask` overridden from the `.deb`'s
  fallback (`4294967295`) to Thor's value (`512`)
- DCE firmware (`display-t264-dce.bin` via `nvidia-l4t-firmware`)
- OPTEE userspace (`nvidia-l4t-optee`, runs `tee-supplicant`)
- A boot-time service that injects `BusID "PCI:1:0:0"` into `/etc/X11/xorg.conf`
- A boot-time service that adds uid 1000 (casper's `ubuntu-server`) to
  `video`, `render`, `gdm`, `audio`, `plugdev`, `weston-launch` groups

## Hardcoded values to revisit on a new JetPack release

| Variable | What it is | Re-derive with |
|---|---|---|
| `KVER="6.8.12-1021-tegra"` | Kernel package name `update-initramfs` builds against | `dpkg-deb -I` on the new `nvidia-l4t-kernel_*.deb` |
| `EFI_PART_START=8833024`, `EFI_PART_BLOCKS=1048576` | LBA-512 offset/size of GPT partition 2 in source ISO | `xorriso -indev <new-iso> -report_system_area plain \| grep -A1 'Appended2'` |
| Source ISO glob (`*.iso` by default) | Default-match pattern for source ISO | n/a, glob will pick whatever's present |

## After boot

- Username: `ubuntu-server`, hostname: `ubuntu-server` (set by casper from
  the source ISO's `.disk/info` flavour string).
- Password: empty (PAM autologin only). Set a password with
  `sudo passwd ubuntu-server` before SSH-in.
- The first ~7 kernel warnings in the top-left during boot are benign
  (regulator/HWPM probe noise). The GUI comes up after them.
- On shutdown the kernel will sometimes hang on 4+ USB read-after-end
  lines while detaching the live media. Press the Orin/Thor reset
  button to restart the board.

## License

This project's build scripts are MIT-licensed (see the header of each
script). The ISO they produce contains third-party packages (NVIDIA L4T,
Ubuntu) under their respective licenses; the MIT terms cover this
project's scripts only.
