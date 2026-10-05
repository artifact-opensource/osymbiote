# Quick start

This guide builds and runs the current OSymbiote guest in QEMU. It describes development/test targets, not a supported installation process for physical hardware.

## Requirements

For either target:

- Linux, WSL2, macOS, or Termux with Bash and a supported host toolchain.
- Internet access to retrieve Alpine Linux and BusyBox build inputs.
- `wget`, `gzip`, `cpio`, `tar`, `file`, and `unsquashfs` (`squashfs-tools`).

To run the x86_64 guest, install `qemu-system-x86_64`. To run ARM64 `virt`, install QEMU's AArch64 system emulator, typically `qemu-system-aarch64` or a package such as `qemu-system-arm`.

The build scripts may complete without QEMU installed; QEMU is required to start the corresponding guest. The ARM64 launcher has not been boot-tested in every host environment.

## Package ISO, disk, and USB images

Image packaging requires GRUB's `grub-mkrescue`, the GRUB boot modules for the target, and `xorriso`. On Debian or Ubuntu, install:

```sh
sudo apt-get install grub-common grub-pc-bin grub-efi-amd64-bin xorriso mtools
```

After building the x86_64 image, create three separately named, versioned artifacts and SHA-256 sidecars:

```sh
bash scripts/package-images.sh x86_64
```

Outputs are written under `images/`:

```text
osymbiote-0.4.0-x86_64.iso
osymbiote-0.4.0-x86_64-disk.img
osymbiote-0.4.0-x86_64-usb.img
```

They are hybrid boot images. The `.disk.img` and `.usb.img` files are intentionally separate raw copies of the generated ISO, not writable root disks or an installer that partitions a computer. They contain a live kernel/initramfs; persistent storage is not provisioned by these images. Secure Boot is not supported by these unsigned artifacts.

The script also accepts `arm64` after `bash scripts/build-arm64.sh` when the host has ARM64 GRUB EFI modules (commonly provided by `grub-efi-arm64-bin`):

```sh
bash scripts/package-images.sh arm64
```

This creates ARM64 UEFI media for compatible UEFI systems. Install `grub-efi-arm64-bin`, `xorriso`, and `mtools` on the packaging host. It is not a vendor-specific Pi, Rockchip, i.MX, Jetson, Qualcomm, or ARM FVP image, and the ARM64 media path is not certified or runtime-verified here.

### Verify and inspect

From the repository root, verify an artifact against its checksum:

```sh
cd images
sha256sum -c osymbiote-0.4.0-x86_64-usb.img.sha256
```

Mount an ISO or hybrid image read-only on Linux:

```sh
sudo mkdir -p /mnt/osymbiote
sudo mount -o loop,ro images/osymbiote-0.4.0-x86_64.iso /mnt/osymbiote
find /mnt/osymbiote -maxdepth 3 -type f
sudo umount /mnt/osymbiote
```

### Burn optical media

Use a trusted disc-burning application and select the `.iso` as an image; do not copy the ISO as a regular file onto a data disc. For a command-line burner, follow the tool's device syntax and verify the selected optical device before writing.

### Write bootable USB media

Writing the raw USB image erases the selected device. Identify the whole removable device carefully (not a partition), unmount its mounted partitions, and verify the checksum before writing. On Linux:

```sh
lsblk
sudo umount /dev/sdX1  # repeat for any mounted partitions on the selected device
sudo dd if=images/osymbiote-0.4.0-x86_64-usb.img of=/dev/sdX bs=4M status=progress conv=fsync
sync
```

Replace `/dev/sdX` with the correct whole device. Never paste the example unchanged: selecting the wrong device can destroy data. On macOS, use Disk Utility's device list and a trusted image writer, or adapt the target to the correct whole-disk `/dev/rdiskN` only after verifying it with `diskutil list`.

### Boot and use

Boot the computer from the optical/USB media using its firmware boot menu. On x86_64, choose the display-console or serial-console GRUB entry as appropriate. Firmware may need Secure Boot disabled. The live guest serves the portal on guest port 8422; bare-metal systems have no host port forwarding, so use the guest's DHCP address and a trusted network. The first-boot password setup and provider configuration are described above.

These images do not install OSymbiote to an internal drive. They also do not automatically persist settings across power-off; persistence currently depends on the QEMU 9p share.

## Build and run x86_64

From the repository root:

```sh
bash scripts/build-phase1.sh
./run.sh
```

The builder writes `build/vmlinuz` and `images/initramfs.cpio.gz`. The launcher defaults to 128 MiB RAM, two CPUs, a host port of 8422, and persistent host data under `data/`.

## Build and run ARM64 QEMU `virt`

```sh
bash scripts/build-arm64.sh
./run-arm64.sh
```

The builder creates `build/arm64/` and `images/arm64-initramfs.cpio.gz`. The launcher uses the QEMU `virt` machine, serial console, and virtio network device. This is not a vendor board image.

## First boot

1. Open `http://localhost:8422/ui`.
2. Create the initial portal password using the setup page.
3. Sign in with that password.
4. Configure an OpenAI-compatible provider URL, model, and API key in **LLM & Provider**.
5. Test connectivity, then use Chat or the console `osh` shell.

The system has no default portal password. Password setup is stored under guest `/data/osymbiote/auth/` when persistent storage is available. Do not put API keys in source files or generated images.

## Launcher options

Both launchers accept these environment variables:

| Variable | Default | Purpose |
|---|---:|---|
| `OSYM_PORT` | `8422` | Host port forwarded to guest port 8422 |
| `OSYM_RAM` | x86_64: `128`; ARM64: `512` | Guest memory in MiB |
| `OSYM_CPUS` | `2` | Guest CPU count |
| `OSYM_DATA_DIR` | repository `data/` | Host directory shared with guest `/data` |
| `OSYM_PERSIST` | `1` | `1` enables the QEMU 9p share; `0` disables it |

Examples:

```sh
OSYM_RAM=512 OSYM_CPUS=4 ./run.sh
OSYM_PERSIST=0 ./run-arm64.sh
OSYM_PORT=18422 OSYM_DATA_DIR="$HOME/osym-data" ./run.sh
./run.sh --background
```

The background option starts QEMU detached and checks `/health` after a short delay; a failed health check may mean the guest is still booting. Stop a background instance using the printed QEMU PID.

## Next steps

- Review [Security](security.md) before configuring external access.
- Review [Operations](operations.md) for data retention and troubleshooting.
- See the [API reference](api-reference.md) for HTTP endpoints.
