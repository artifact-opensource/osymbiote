# Operations and troubleshooting

## Persistent data

The QEMU launchers enable a host directory share by default:

- Host: repository `data/`, or `OSYM_DATA_DIR`
- Guest: `/data`
- Mechanism: QEMU 9p with tag `osymdata`

The guest loads available 9p modules and attempts to mount the share early in boot. `/health` reports `data_persistent: true` only when that mount succeeded. `OSYM_PERSIST=0` disables the share. Direct hardware boots do not currently discover or mount persistent storage automatically.

Stop the VM before editing files in the host data directory. Back up this directory securely because it may contain authentication state and API keys.

## Launcher configuration

| Variable | Purpose |
|---|---|
| `OSYM_PORT` | Host TCP port forwarded to guest 8422 |
| `OSYM_RAM` | Guest RAM in MiB |
| `OSYM_CPUS` | Guest CPU count |
| `OSYM_DATA_DIR` | Host directory shared as guest `/data` |
| `OSYM_PERSIST` | `1` to share data, `0` for volatile state |
| `OSYM_QEMU` | ARM64 launcher only; override QEMU executable |

The ARM64 launcher defaults to 512 MiB; x86_64 defaults to 128 MiB. Both default to two CPUs and host port 8422.

## Health and diagnostics

`GET /health` reports runtime status, version, uptime, CPU/memory metrics, setup/authentication state, and whether `/data` is persistent. The `osh` console offers `help`, `status`, `doctor`, `net`, `llm`, `history`, and other guest commands. QEMU serial output carries initialization and network messages.

There is no general logging service. The console output and live `/proc` and `/sys` state are the primary diagnostics.

## Troubleshooting

### Build fails because a host tool is missing

Install the tool named in the error. The build scripts require `wget`, `gzip`, `cpio`, and `unsquashfs`; the ARM64 builder also uses `tar`, `file`, and standard shell utilities. QEMU is not required to assemble images.

### Launcher says the kernel or initramfs is missing

Run the matching builder from the repository root:

```sh
bash scripts/build-phase1.sh   # x86_64
bash scripts/build-arm64.sh    # ARM64 virt
```

### QEMU executable is missing

Install a QEMU system emulator for the target architecture. For x86_64 use `qemu-system-x86_64`; for ARM64 use `qemu-system-aarch64`. The ARM64 image can be built on another host even when the local host cannot run ARM emulation.

### Browser cannot connect

Confirm the guest reached the initialization-complete message, the correct launcher is still running, and the selected host port is available. For a custom port, open `http://localhost:${OSYM_PORT}/ui`. Check `GET /health`; QEMU background health polling is a short initial check, not a continuous service monitor.

### Provider requests fail

Check outbound guest networking, provider URL, model, API key, and provider availability. Configure the key in the portal or with the guest `llm key` command. Provider errors are returned as HTTP `502` in applicable routes.

### Settings disappear after shutdown

Check `/health` for `data_persistent`. Verify the launcher used `OSYM_PERSIST=1` and a writable host data directory. If the share did not mount, the guest warns during boot and operates with volatile state.

### Forget or reset the portal password

When the guest is stopped, remove the `auth/` directory from `data/osymbiote/` (or from the configured host data directory) to trigger first-boot setup again. This also invalidates saved session state. Keep a backup if other files in the data directory must be preserved.

### ARM64 guest does not boot

The ARM64 image has passed build and artifact checks but has not been validated on every QEMU host. Confirm the host has ARM system emulation, run `./run-arm64.sh` with the matching image, and capture serial output. Do not infer vendor-board support from QEMU `virt` behavior.
