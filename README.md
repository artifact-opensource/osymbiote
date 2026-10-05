# OSymbiote

**An experimental, minimal Linux guest with an authenticated agent API and console shell.**

[![Versioning: SemVer](https://img.shields.io/badge/versioning-SemVer-blue)](docs/versioning.md)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![Targets](https://img.shields.io/badge/QEMU-x86__64%20%7C%20ARM64-informational)](#supported-targets)

OSymbiote boots a Linux kernel into a small BusyBox initramfs. Its PID 1 script initializes devices and networking, supervises the HTTP handler, and keeps the `osh` console shell available. An optional OpenAI-compatible provider supplies chat and bounded tool proposals. OSymbiote is an early-stage project; it is not a general-purpose desktop OS or a certified bare-metal distribution.

## Current status

| Capability | Status |
|---|---|
| x86_64 initramfs build | Build script available; QEMU runtime support depends on host installation |
| ARM64 QEMU `virt` image | Image builder and launcher available; boot has not been verified in this environment |
| x86_64 ISO, disk, and USB images | Separate versioned artifacts can be packaged from the x86_64 build |
| Vendor ARM boards and bare metal | Not implemented or certified |
| Authenticated HTTP portal and API | Available; single shared portal identity |
| LLM chat and tool proposals | Available for configured providers; write and command operations require an authenticated request and confirmation header |
| Persistent guest data | Available when launched with the QEMU 9p share; other boot modes may be volatile |

See [the support matrix](docs/architecture.md#supported-targets) and [roadmap](docs/roadmap.md) for scope and validation status.

## Quick start

### x86_64

Requirements: Bash, `wget`, `gzip`, `cpio`, `unsquashfs` from `squashfs-tools`, and QEMU (`qemu-system-x86_64`) to run.

```sh
bash scripts/build-phase1.sh
./run.sh
```

To also package a bootable ISO and raw disk/USB images, install the GRUB and `xorriso` host tools and run `bash scripts/package-images.sh x86_64`.

### ARM64 QEMU `virt`

Requirements: the build tools above and `qemu-system-aarch64` to run.

```sh
bash scripts/build-arm64.sh
./run-arm64.sh
```

The ARM64 image is a generic QEMU reference target, not a Raspberry Pi, Rockchip, i.MX, Jetson, Qualcomm, or ARM FVP image. Both launchers forward host port `8422` to guest port `8422` and share host `data/` with guest `/data` by default.

The package script can also create ARM64 UEFI media when ARM64 GRUB EFI modules are installed; physical-board compatibility is not implied.

Open `http://localhost:8422/ui`. On first boot, initialize the portal password and then sign in. Configure an LLM provider and API key in the portal or through `osh`. For the complete setup, options, and security constraints, see the [Quick Start guide](docs/quickstart.md).

## Security notice

The portal uses HTTP without TLS and the guest console runs as root. The single portal password is not Unix account isolation. Root command execution and file writes are high-impact capabilities; confirmation is enforced by the API header but is not a substitute for an encrypted, trusted channel. Run only in a trusted environment, keep the forwarded port private, and do not expose the service to untrusted networks. Review [Security](docs/security.md) before configuring credentials or using native tools.

## Documentation

- [Documentation index](docs/README.md)
- [Quick start](docs/quickstart.md)
- [Architecture and support matrix](docs/architecture.md)
- [HTTP API reference](docs/api-reference.md)
- [Security model and operational guidance](docs/security.md)
- [Operations and troubleshooting](docs/operations.md)
- [Development and contribution guide](docs/development.md)
- [Roadmap and platform support](docs/roadmap.md)
- [Release and file-versioning policy](docs/versioning.md)
- [Changelog](CHANGELOG.md)
- [Long-term design blueprint](BLUEPRINT.md) (aspirational; not a description of shipped functionality)

## Repository layout

```text
VERSION                         Canonical project version
README.md                       Project overview and entry point
CHANGELOG.md                    User-visible release history
docs/                           User, developer, API, security, and operations docs
scripts/build-phase1.sh         x86_64 image builder
scripts/build-arm64.sh          ARM64 QEMU virt image builder
scripts/package-images.sh       Versioned ISO, disk, and USB image packager
scripts/overlay/                Guest init, shell, HTTP handler, UI, and shared library
run.sh                          x86_64 QEMU launcher
run-arm64.sh                    ARM64 QEMU virt launcher
boot.sh, test.sh                Generated x86_64 helper scripts
```

## License

OSymbiote is licensed under the [MIT License](LICENSE).
