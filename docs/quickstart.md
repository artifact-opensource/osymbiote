# Quick start

This guide builds and runs the current OSymbiote guest in QEMU. It describes development/test targets, not a supported installation process for physical hardware.

## Requirements

For either target:

- Linux, WSL2, macOS, or Termux with Bash and a supported host toolchain.
- Internet access to retrieve Alpine Linux and BusyBox build inputs.
- `wget`, `gzip`, `cpio`, `tar`, `file`, and `unsquashfs` (`squashfs-tools`).

To run the x86_64 guest, install `qemu-system-x86_64`. To run ARM64 `virt`, install QEMU's AArch64 system emulator, typically `qemu-system-aarch64` or a package such as `qemu-system-arm`.

The build scripts may complete without QEMU installed; QEMU is required to start the corresponding guest. The ARM64 launcher has not been boot-tested in every host environment.

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
