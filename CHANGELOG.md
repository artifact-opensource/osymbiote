# Changelog

Notable user-visible changes are recorded here. Version numbers follow the repository-wide policy in [docs/versioning.md](docs/versioning.md).

## [0.4.0] - 2026-10-05

### Added

- ARM64 QEMU `virt` image builder and launcher using Alpine AArch64 kernel/module inputs and ARM64 BusyBox.
- Optional persistent `/data` sharing for QEMU through 9p.
- Professional user, architecture, API, security, operations, development, roadmap, and versioning documentation.
- Canonical `VERSION` metadata exposed by the guest `/health` endpoint.
- Versioned hybrid ISO, disk-image, and USB-image packaging from built x86_64 or ARM64 artifacts.

### Changed

- Guest networking scans available non-loopback interfaces instead of relying on a fixed set of interface names.
- Root README now describes current support boundaries and links to task-focused documentation.

### Limitations

- ARM64 image building and artifact checks passed; runtime boot was not verified in this environment.
- GRUB/xorriso-generated media still require boot testing on actual firmware; the raw `.img` variants are copies of the hybrid ISO, not writable root disks.
- Vendor-board and bare-metal targets are not implemented or certified.
