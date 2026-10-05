# Roadmap and support status

This roadmap describes current scope as of OSymbiote 0.4.0. Planned entries are direction, not delivery commitments.

## Available now

- Minimal BusyBox guest, PID 1 initialization, console `osh`, and supervised HTTP handler.
- Authenticated portal with first-boot password setup, provider configuration, chat, history, memory, and system views.
- Fixed LLM tool allowlist for text file read, text file write, and root command execution.
- Explicit confirmation precondition for web-mediated file writes and commands, in addition to authentication and role checks.
- x86_64 image build/launcher.
- ARM64 QEMU `virt` image build/launcher; build artifacts have passed checks, but runtime boot is not yet verified here.
- Versioned x86_64 hybrid ISO, raw disk-image, and USB-image packaging; media boot has not been hardware-certified.
- QEMU-backed `/data` persistence using 9p when the share mounts successfully.

## Known limits

- No vendor-board or bare-metal image support, board certification, or automated hardware test matrix.
- No autonomous planning or unrestricted background agent execution.
- Portal identity is a shared account, not Unix user isolation.
- HTTP has no built-in TLS.
- Persistent storage is QEMU-share-specific; non-QEMU boot does not automatically discover a persistent disk.
- Architecture labels in intent responses are informational, not board-specific adapters.
- UI, API, and configuration formats have no 1.0 compatibility guarantee.

## Planned direction

1. Boot-test and automate runtime smoke testing for x86_64 and generic ARM64 media/QEMU targets.
2. Define a maintainable architecture/build interface shared by x86_64 and ARM64 targets.
3. Design board-specific support independently, beginning with documented firmware, kernel, device-tree, artifact, and validation requirements.
4. Improve storage discovery and persistence beyond the QEMU-only 9p workflow.
5. Expand diagnostics and test coverage before adding broader root-capable agent operations.

No specific vendor platform is considered supported until its boot artifact and end-to-end validation process are documented and reproducible.
