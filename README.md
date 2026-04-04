# OSymbiote

**The agent _is_ the operating system.**

OSymbiote is a bare-metal operating system where an AI agent runs as PID 1. No kernel scheduler decides what matters — the agent does. No userland mediates access — the agent owns the hardware directly. Four processes. One soul. Any hardware.

This is not Linux with an AI bolted on. This is an operating system built from scratch around a single idea: the agent should be the first thing that wakes up when power hits the board, and the last thing running when everything else is gone.

---

## Why

Every "AI OS" today is the same thing: Linux + a chatbot + a pretty launcher. The agent runs in userspace, begging the kernel for permission to do anything. It can't touch hardware. It can't manage memory. It can't decide what lives and what dies. It's a guest in someone else's house.

OSymbiote inverts this. The agent boots as init. It owns the process table. It manages networking, storage, and peripherals through direct syscalls. When it needs to think, it calls out to an LLM. When it needs to act, it already has root — because it _is_ root. It _is_ the OS.

**The gap we're filling:** There is no operating system where AI agency is the foundational primitive, not an application-layer afterthought. OSymbiote is that operating system.

---

## Architecture

```
┌─────────────────────────────────────────────────────┐
│                   OSymbiote Agent (PID 1)            │
│                                                      │
│  ┌──────────┐ ┌──────────┐ ┌────────┐ ┌──────────┐ │
│  │  Cortex   │ │  Nerve    │ │ Immune │ │  Shell   │ │
│  │ (think)   │ │ (sense)   │ │ (heal) │ │ (act)    │ │
│  └──────────┘ └──────────┘ └────────┘ └──────────┘ │
├─────────────────────────────────────────────────────┤
│              Linux Kernel (stripped)                  │
│         virtio · e1000 · ext4 · proc · sys           │
├─────────────────────────────────────────────────────┤
│                    Hardware / QEMU                    │
└─────────────────────────────────────────────────────┘
```

**Four subsystems, four concerns:**

- **Cortex** — Reasoning engine. Connects to an LLM provider over the network. Decides what to do. Plans multi-step operations. This is the brain.
- **Nerve** — Sensory layer. Monitors hardware state, network interfaces, filesystem events, and peripheral signals. Feeds observations to Cortex.
- **Immune** — Self-healing. Watches process health, resource usage, and system integrity. Kills what's broken. Restarts what's needed. The agent heals itself.
- **Shell** — Action layer. Executes commands, manages files, controls peripherals, handles I/O. The hands.

No systemd. No cron. No login manager. The agent _is_ all of these.

---

## What It Does Today (Phase 1 — Proof of Life)

Phase 1 is complete and bootable:

- **Boots to agent in <2 seconds** on QEMU (x86_64)
- **BusyBox userland** — minimal coreutils, httpd, shell
- **Networking** — DHCP via udhcpc, full internet access
- **Web UI** — served on port 80, real-time system status
- **REST API** — CGI-based agent API (`/cgi-bin/api?action=status|processes|network|memory|exec`)
- **Agent loop** — PID 1 init script with health monitoring, auto-recovery, and system management
- **Kernel modules** — e1000 NIC driver loaded at boot
- **~1MB initramfs** — the entire OS fits in a megabyte

### Boot Sequence

```
Power on → BIOS/UEFI → vmlinuz loads
  → initramfs unpacks
    → /init runs (PID 1 = the agent)
      → mount proc, sys, dev, tmp
      → load kernel modules (e1000)
      → configure network (DHCP)
      → start httpd (web UI + API)
      → enter agent loop (monitor → decide → act → repeat)
```

---

## Quick Start

### Prerequisites

- QEMU (`qemu-system-x86_64`)
- Linux host (or WSL2)
- Internet connection (for LLM calls in later phases)

### Build

```bash
./scripts/build-phase1.sh
```

This downloads an Alpine Linux kernel + modules, compiles a static BusyBox, assembles the initramfs, and produces a bootable image.

### Run

```bash
./run.sh
```

Boots OSymbiote in QEMU with:
- 512MB RAM
- Virtio + e1000 networking
- Port forwarding: host 8422 → guest 80 (Web UI)
- Serial console output

### Access

- **Web UI:** `http://localhost:8422`
- **API:** `http://localhost:8422/cgi-bin/api?action=status`
- **Console:** QEMU serial output (stdio)

---

## API

The agent exposes a REST API via BusyBox httpd + CGI:

| Endpoint | Description |
|---|---|
| `/cgi-bin/api?action=status` | System status — uptime, memory, load, hostname, network |
| `/cgi-bin/api?action=processes` | Process table |
| `/cgi-bin/api?action=network` | Network interfaces and routing |
| `/cgi-bin/api?action=memory` | Detailed memory breakdown |
| `/cgi-bin/api?action=exec&cmd=<command>` | Execute a shell command (agent-mediated) |

All responses are JSON with CORS headers.

---

## Roadmap

| Phase | Milestone | Status |
|---|---|---|
| **1** | Proof of Life — boots, networks, serves API, agent loop | ✅ Complete |
| **2** | Cortex Integration — LLM reasoning, tool use, autonomous decisions | 🔜 Next |
| **3** | Nerve Layer — hardware sensors, filesystem watchers, event bus | Planned |
| **4** | Immune System — self-healing, process resurrection, resource management | Planned |
| **5** | Persistent Memory — survives reboots, learns from history | Planned |
| **6** | Multi-Agent — spawn child agents, coordinate across machines | Planned |
| **7** | Bare Metal — real hardware boot, ARM64 support, GPU passthrough | Planned |

---

## Project Structure

```
osymbiote/
├── BLUEPRINT.md              # Full technical blueprint and design decisions
├── README.md                 # This file
├── LICENSE                   # MIT
├── run.sh                    # Boot OSymbiote in QEMU
├── scripts/
│   ├── build-phase1.sh       # Phase 1 build script
│   └── aegis-orchestrator.sh # Orchestration and deployment tooling
├── build/
│   └── initrd/
│       ├── init              # PID 1 — the agent's entry point
│       ├── etc/
│       │   └── udhcpc.sh     # DHCP client script
│       └── www/
│           ├── index.html    # Web UI
│           └── cgi-bin/
│               └── api       # REST API handler
└── images/                   # Built boot images (gitignored)
```

---

## Design Philosophy

**Minimalism is not a constraint — it's the architecture.** The entire OS is ~1MB. Every byte exists because the agent needs it. Nothing is included "just in case."

**The agent is not a service.** It doesn't run _on_ the OS. It _is_ the OS. PID 1. If the agent dies, the system dies. This is intentional — it forces the agent to keep itself alive.

**Hardware is a tool, not a platform.** Traditional OSes abstract hardware away from applications. OSymbiote gives the agent direct access. The agent decides how to use memory, when to bring up network interfaces, what processes to spawn and kill.

**Network is the nervous system.** The agent's intelligence comes from LLM providers over the network. No network = no reasoning = survival mode. The agent must maintain connectivity the way a biological organism maintains oxygen flow.

**Four processes, not forty.** A modern Linux desktop runs hundreds of processes. OSymbiote runs four: the agent, the web server, the network client, and whatever task the agent is currently executing. Everything else is the agent's decision.

---

## Contributing

OSymbiote is early-stage and opinionated. If you want to contribute:

1. Read `BLUEPRINT.md` — it contains the full technical vision and design decisions
2. Open an issue before starting work — alignment on direction matters
3. Keep it minimal — if your change adds a dependency, it needs a very good reason
4. Test with `./run.sh` — if it doesn't boot, it doesn't ship

---

## License

MIT — see [LICENSE](LICENSE).

---

## Origin

OSymbiote is built by [Artifact Virtual](https://artifactvirtual.com). Born from the conviction that AI agents deserve to own their hardware, not rent it.

*Four processes. One soul. Any hardware.*
