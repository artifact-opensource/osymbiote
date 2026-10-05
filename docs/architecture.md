# Architecture and support

OSymbiote 0.4.0 is an experimental Linux guest built around BusyBox and shell scripts. Linux remains the kernel; OSymbiote supplies a minimal initramfs and an agent-facing runtime.

## Runtime overview

```text
Host or hardware
  -> Linux kernel and initramfs
    -> /init (scripts/overlay/init; PID 1)
      -> mount proc, sys, dev, tmp, run
      -> attempt QEMU 9p mount at /data
      -> probe system information and bring up DHCP
      -> supervise HTTP agent on guest TCP 8422
      -> respawn osh on the console
```

PID 1 mounts pseudo-filesystems, attempts to load available network and persistence modules, prepares configuration, records basic hardware information, starts the HTTP handler, and respawns the console shell. The agent is not the Linux kernel and does not currently make autonomous system decisions.

The guest implementation is shared from `scripts/overlay/`. The x86_64 and ARM64 build scripts install those sources into their own initramfs images. `osh` and the HTTP handler use `scripts/overlay/lib.sh` for shared settings, authentication, prompt, and history behavior.

## Components

| Component | Responsibility |
|---|---|
| `/init` | Guest initialization, network setup, service supervision, console shell respawn |
| `osh` | Interactive BusyBox-compatible console shell and OSymbiote commands |
| HTTP handler | One-request shell handler behind BusyBox `tcpsvd` or available `nc` applets |
| Portal | Single-file HTML/CSS/JavaScript client served at `/ui` |
| `lib.sh` | Shared shell helpers for config, secrets, auth, provider calls, history, and tools |
| `comb` | Append and recall text memory entries |
| `/data` | Persistent settings and state only when supplied by the QEMU 9p share |

The HTTP server is a constrained shell-script implementation, not a general-purpose web server. It accepts request bodies up to 64 KiB, places a 15-second bound on request/header/body reads, and may fall back to a serial `nc -e` listener depending on BusyBox applets.

## Supported targets

| Target | Build status | Runtime status | Notes |
|---|---|---|---|
| x86_64 QEMU | Builder available | QEMU launcher available | Alpine `virt` kernel; e1000 and virtio network support |
| ARM64 QEMU `virt` | Builder available; artifact checks passed | Not runtime-verified in this environment | Alpine AArch64 `virt` kernel and BusyBox; uses `virtio-net-pci` |
| Raspberry Pi, Rockchip, NXP i.MX, Jetson, Qualcomm, ARM FVP | Not implemented | Not supported/certified | Requires target-specific firmware, boot flow, kernel configuration/drivers, DTBs, and testing |
| Other bare-metal systems | Not implemented | Not supported/certified | No general installer or hardware certification process exists |

The project does not claim support for all boards in a SoC family. A successful cross-architecture image build is not evidence of runtime compatibility.

## Data and persistence

QEMU launchers pass a host directory as a 9p share tagged `osymdata`. The init script loads available 9p modules and mounts that share at guest `/data`. If the mount is unavailable, the guest falls back to the initramfs filesystem and reports data as volatile through `/health`. A direct boot has no automatic persistent-storage discovery.

The same data directory can contain credentials, password hashes, sessions, history, LLM configuration, and memory. Host filesystem permissions and backups therefore matter; see [Security](security.md).

## Network and interfaces

The init script scans non-loopback interfaces exposed in `/sys/class/net`, attempts DHCP on available interfaces, and uses the supplied `udhcpc` hook to configure address, route, and DNS. The QEMU launchers forward host port 8422 to guest port 8422.
