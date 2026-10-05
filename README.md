# OSymbiote

**The agent _is_ the operating system.**

OSymbiote boots a Linux kernel straight into a minimal BusyBox userland whose only job is to run one shell-script agent as PID 1. There's no desktop, no login manager, no systemd — the agent's init script mounts filesystems, brings up networking, and starts serving an HTTP API, all from one script. Four moving parts, not four hundred.

This isn't a rewrite of the kernel or a bypass of Linux internals — it's still a normal Linux kernel underneath. What's different is the userland: instead of hundreds of background services, there's exactly one process tree rooted in the agent, and everything that would normally be a separate daemon (networking setup, health checks, the web API) lives inside that one init script.

---

## Why

Most "AI OS" projects are Linux + a chatbot + a launcher, where the agent is just another background service competing for attention. OSymbiote flips the priority: the agent's init script *is* PID 1. If it dies, the system dies — which forces it to be the thing that keeps everything else alive, not the other way around.

**What exists today is Phase 1** — a proof-of-life build, not the full vision. See [BLUEPRINT.md](BLUEPRINT.md) for the long-term design (hybrid memory search, self-healing, multi-arch, bare-metal boot) — most of it is still unimplemented. This README only describes what currently runs.

---

## Architecture (today)

```
┌─────────────────────────────────────────────────────┐
│         /init  (PID 1, one shell script)             │
│   mount fs → bring up network → spawn HTTP handler    │
│   → supervise & restart the HTTP handler if it dies   │
├─────────────────────────────────────────────────────┤
│              Linux Kernel (Alpine virt)               │
├─────────────────────────────────────────────────────┤
│                    Hardware / QEMU                    │
└─────────────────────────────────────────────────────┘
```

The README previously described this as four separate subsystems ("Cortex", "Nerve", "Immune", "Shell") running independently. In the current code there is one init script and one request handler — the route groupings below are the closest real mapping:

- **Reasoning** — `/ai` and `/chat` proxy a prompt to an OpenAI-compatible LLM provider (OpenRouter by default). There is no on-box planning or autonomous decision-making yet.
- **Sensing** — `/health`, `/hardware`, and `/intent` read `/proc` and `/sys` on request. There's no background watcher or event bus — everything is pull-based, polled by the UI.
- **Healing** — the supervisor loop in `/init` restarts the HTTP handler if it dies. That's the entire self-healing story today.
- **Acting** — `/intent` runs a small set of read-only system queries; confirmed native tools can read files and propose file writes or root commands.

No systemd, no cron, no login manager — true today, same as the original claim.

---

## What It Does Today (Phase 1 — Proof of Life)

- **Boots to agent in a few seconds** on QEMU (x86_64)
- **BusyBox userland** — ~40 coreutils symlinks, a custom `comb` memory script, a shell
- **Networking** — DHCP via udhcpc on `eth0`/`ens0`/`enp0s3`
- **Boot shell (`osh`)** — the console drops into an interactive shell on boot (`help`, `status`, `chat`, `ask`, `llm …`, `sysconfig`, `prompt`, `history`, `memory`, `net`, `webpass`, `agent`, `doctor`); any other command runs as a normal BusyBox command. LLM settings and system policy are configured from the shell.
- **LLM tool use** — the portal offers file-read, file-write, and root-command tools. Each mutation requires a separate confirmation and server-side authorization.
- **Web portal** — single-file HTML/CSS/JS portal at `http://localhost:8422/ui` with Chat, History, Prompt, LLM & Provider, Memory, System, Network, Processes and Account panes
- **HTTP API** — a hand-rolled shell request handler, served per-connection by BusyBox `tcpsvd` (falls back to single-connection `nc -e` if `tcpsvd` is unavailable); not a real web server
- **Agent loop** — `/init` (PID 1) does hardware probing, network bring-up, then supervises the HTTP handler, restarting it if it exits
- **~1MB initramfs** — the whole image is close to a megabyte

### Boot Sequence

```
Power on → BIOS/UEFI → vmlinuz loads
  → initramfs unpacks
    → /init runs (PID 1 = the agent)
      → mount proc, sys, dev, tmp, run
      → bring up loopback + DHCP on the first available NIC
      → write /run/hardware.json
      → start the HTTP agent on :8422 (restarted automatically if it dies)
      → open the osh shell on the console (respawned on exit)
```

### Known limitations (read before relying on this)

- **Persistence depends on the boot method.** QEMU launchers share a host directory into guest `/data` by default, so settings survive VM restarts. Direct boots without a QEMU 9p share fall back to volatile initramfs storage.
- **HTTP concurrency depends on BusyBox applets.** The preferred `tcpsvd` server creates one handler per connection; the `nc -lk` fallback varies by BusyBox build. Requests have bounded header/body timeouts and a 64 KiB body limit. If neither forking server is available, the final `nc -e` fallback is serial.
- **Portal authorization is single-account.** The password creates one shared portal identity with one configured role; this is not multi-user Unix account isolation. Console commands run as root. Do not expose the portal to untrusted networks.
- **QEMU data is host-backed, not encrypted.** The default `data/` directory contains passwords, API keys, sessions, and user data. Restrict host access and back it up securely; the repository ignores this directory.
- **"Architecture-aware" intent routing is cosmetic.** `/intent` detects `x86_64`/`arm64`/`riscv64`/`generic` and reports it in the response, but every intent runs the exact same BusyBox command regardless of arch family — there are no real per-arch adapters yet.
- **No password recovery.** Once `/setup/init` runs, reset the password from the guest console with `webpass`, or remove the `data/osymbiote/auth/` directory while the VM is stopped.
- **`scripts/aegis-orchestrator.sh` is personal tooling**, not a general-purpose script — it hardcodes a specific device IP, username, and local filesystem path, and won't run for other contributors as-is.

---

## Quick Start

OSymbiote boots **inside a QEMU virtual machine**. The host (Linux, WSL2, or Termux on Android) never runs the agent directly — it hosts a VM that boots the agent as PID 1. This is the "boot-in environment": QEMU provides the virtual hardware, and OSymbiote boots into it like real hardware.

### Prerequisites

- QEMU (`qemu-system-x86_64`)
- Linux host, WSL2, or **Termux on Android**
- Internet connection (for the build step and for LLM calls)

### Termux (Android)

OSymbiote builds and runs fully inside Termux — no root required. The build script detects Termux automatically and installs what it needs via `pkg`:

```bash
pkg update -y && pkg upgrade -y
pkg install -y git
git clone <this-repo-url> osymbiote && cd osymbiote
bash scripts/build-phase1.sh   # installs qemu-system-x86-64, wget, curl, coreutils, cpio, gzip via pkg
./run.sh
```

`run.sh` also detects a missing `qemu-system-x86_64` on Termux and installs it via `pkg` automatically before booting.

### Build

```bash
./scripts/build-phase1.sh
```

This downloads an Alpine Linux kernel + modules, fetches a static BusyBox, assembles the initramfs, and produces a bootable image (`build/vmlinuz` + `images/initramfs.cpio.gz`).

### Run

```bash
./run.sh
```

Boots OSymbiote in QEMU with:
- 128MB RAM, 2 CPUs (override with `OSYM_RAM` / `OSYM_CPUS`)
- e1000 networking (DHCP via udhcpc inside the guest)
- Port forwarding: host `8422` → guest `8422` (override with `OSYM_PORT`)
- Serial console output (`-nographic`; `Ctrl+A X` to exit QEMU)
- `./run.sh --background` boots detached and polls `/health` to confirm the agent is alive
- Persistent guest `/data` shared with the host's ignored `data/` directory (override with `OSYM_DATA_DIR`; set `OSYM_PERSIST=0` for a volatile run)

### Access

- **Web UI:** `http://localhost:8422/ui`
- **API:** `http://localhost:8422/health`
- **Console:** QEMU serial output (stdio)

---

## API

The agent exposes a REST API on port `8422` (forwarded to host `8422` by default):

| Endpoint | Description |
|---|---|
| `/ui` | Single-file setup/login UI plus a tabbed dashboard (Chat, System, Memory, Network, Processes, Native tools) once authenticated |
| `/setup/status` | First-boot setup status |
| `/setup/init` (POST password body) | Initialize password (salted hash only) |
| `/auth/login` (POST password body) | Login and receive short-lived session cookie |
| `/auth/logout` | Clear session |
| `/health` | Agent health, setup/auth status, and basic system metrics |
| `/provider` | Active OpenAI-compatible provider settings |
| `/hardware` | Hardware manifest |
| `/chat` (POST body text) | Auth-required plain chat with the configured LLM (history-aware) |
| `/agent/tools` (POST JSON messages) | Auth-required OpenAI-compatible tool-calling round; execution is delegated to the user-confirmed native tool routes |
| `/llm` (GET / POST `key=value` lines) | Auth-required LLM config: `provider`, `base_url`, `model`, `api_key`, `temperature`, `max_tokens`, `history_turns`, `preset` |
| `/llm/test` (POST), `/llm/models` | Auth-required provider connectivity test / model list |
| `/prompt` (GET / POST text / DELETE) | Auth-required system prompt |
| `/history` (GET `?limit=N` / POST message / DELETE) | Auth-required conversation history |
| `/memory` (GET `?limit=N` / POST text / DELETE), `/memory/stats` | Auth-required COMB memory (aliases of `/comb/*`) |
| `/system/network`, `/system/processes`, `/system/disk`, `/system/memory` | Auth-required system views |
| `/system/config` (GET / POST `key=value` lines) | Auth-required role policy and file-owner settings |
| `/ai` (POST body text) | Auth-required OpenAI-compatible `/chat/completions` proxy |
| `/intent` or `/command` (POST body text) | Auth-required intent routing to arch-aware command adapters |
| `/comb/stage` (POST body text) | Auth-required append memory entry |
| `/comb/recall` | Auth-required read recent memory entries |
| `/fs/read` (POST, `X-OSYM-Path: /absolute/path`) | Auth-required text-file read, limited to 32 KiB |
| `/fs/write` (POST body text, `X-OSYM-Path: /absolute/path`) | Auth-required atomic text-file write; requires `X-OSYM-User-Confirmed: yes` |
| `/exec` (POST shell command body) | Auth-required root shell execution (30s timeout); requires `X-OSYM-User-Confirmed: yes` |

All responses are JSON with CORS headers.

### Setup and auth flow

On a fresh boot, only setup routes are available. Initialize with `POST /setup/init`, then login via `POST /auth/login`.  
Session auth uses a short-lived cookie (`osym_session`, 15 minutes). Sensitive routes enforce auth.
The portal supports LLM-proposed file reads, writes, and shell commands, with at most three model/tool rounds and two tool calls per round. Writes and root commands always require explicit per-operation confirmation; denied actions are returned to the model as tool results. This phase's image build remains x86_64/QEMU-focused; bare-metal and ARM64 boot support are not yet implemented.

Auth hardening included:
- rate limiting on setup/login endpoints
- temporary lockout/backoff after repeated failed logins
- password stored as salted SHA-256 hash (never plaintext)

### Secrets, settings, and roles

The boot image contains examples only, never real credentials. At startup, the guest copies `/etc/osymbiote/.env.example` and `/etc/osymbiote/system.conf.example` into `/data/osymbiote/.env` and `/data/osymbiote/system.conf` when those files do not already exist. Under QEMU, `/data` is backed by the host share; the `.env` file is set to mode `0600`. It uses raw `KEY=value` lines and is parsed using an allowlist, never sourced or evaluated. API keys set in the portal or with `llm key` are written there. The LLM endpoint only returns whether a key is set and a masked value.

Supported secret keys include `OSYM_OPENAI_API_KEY`, `OPENAI_API_KEY`, `OPENROUTER_API_KEY`, `ANTHROPIC_API_KEY`, `GEMINI_API_KEY`, and `GROQ_API_KEY`. Optional routing defaults are `OSYM_OPENAI_BASE_URL`, `OSYM_OPENAI_MODEL`, and `OSYM_AI_PROVIDER`; saved LLM settings take precedence over these defaults. A process environment value takes precedence over the corresponding `.env` value. Never commit real keys or bake them into a generated image.

`system.conf` is separate from secrets. Its validated settings are:

| Setting | Purpose | Default |
|---|---|---|
| `web_role` | Role assigned to the one portal identity | `admin` |
| `fs_read_role` | Minimum role for read-only system/file/config views | `viewer` |
| `fs_write_role` | Minimum role for file writes | `admin` |
| `exec_role` | Minimum role for root command execution | `root` |
| `config_role` | Minimum role for changing system policy over HTTP | `root` |
| `sudo_mode` | `confirm` requires explicit confirmation; `disabled` blocks web root commands | `confirm` |
| `owner_uid`, `owner_gid` | Numeric ownership applied to files written through the portal | `0`, `0` |

Roles are ordered `viewer < operator < admin < root`. Change settings on the console with `sysconfig show` and `sysconfig set <key> <value>`; `/system/config` supports authenticated reads and updates for identities meeting `config_role`. These role gates do not create Unix users, drop the handler's root privileges, or protect the console shell. The current single-password session design cannot assign different roles to different people.

### OpenAI-compatible provider defaults

NIC drivers (`e1000`, `virtio_net`, `af_packet`) are pulled from Alpine's `initramfs-virt` at build time and loaded by init, since the Alpine virt kernel ships them as modules. The agent prefers BusyBox `tcpsvd` for per-connection handling, with `nc` fallbacks depending on applet support.

- Provider: `openrouter`
- Base URL: `https://openrouter.ai/api/v1`
- Model: `openrouter/free`

`/ai` forwards your request to `${base_url}/chat/completions` and uses the model above.  
Set the API key via the portal (LLM & Provider), `POST /llm` with `api_key=...`, or `llm key <key>` in the shell. These write the secret to `.env`, not the non-secret LLM settings file. `/ai` also accepts an `Authorization` header override.

To smoke-test provider tool calls, send `X-Tool-Call-Test: 1` to `/ai`.  
`test.sh` runs this tool-call check automatically when `OPENROUTER_AUTH_HEADER` is set.

### Architecture-aware intent routing

`/intent` and `/command` map canonical intents (network, disk usage, process list, memory, uptime) to BusyBox commands, and the response reports a detected arch family: `x86_64`, `arm64`, `riscv64`, or `generic`.  
Today this is capability detection, not real per-arch logic — every family runs the same BusyBox command. The arch field exists so future per-arch adapters have somewhere to plug in.

---

## Roadmap

| Phase | Milestone | Status |
|---|---|---|
| **1** | Proof of Life — boots, networks, serves HTTP API + UI, agent supervisor loop | ✅ Working (QEMU host-backed `/data`; direct boots may be volatile) |
| **2** | Cortex Integration — LLM reasoning, tool use, autonomous decisions | 🟡 LLM chat and bounded, user-confirmed tool calls exist; no autonomous planning |
| **3** | Nerve Layer — hardware sensors, filesystem watchers, event bus | Planned — today is poll-based, not event-driven |
| **4** | Immune System — self-healing, process resurrection, resource management | Planned — today is a restart-if-dead loop for one process |
| **5** | Persistent Memory — survives reboots, learns from history | 🟡 `/data` survives QEMU restarts; indexing/search and hardware storage discovery remain planned |
| **6** | Multi-Agent — spawn child agents, coordinate across machines | Planned — not started |
| **7** | Bare Metal — real hardware boot, ARM64 support, GPU passthrough | Planned — only tested under QEMU x86_64 today |

---

## Project Structure

```
osymbiote/
├── BLUEPRINT.md              # Long-term technical vision (mostly unimplemented)
├── README.md                 # This file
├── LICENSE                   # MIT
├── run.sh                    # Boot OSymbiote in QEMU (host-side launcher)
├── boot.sh                   # Generated snapshot of build-phase1.sh's boot helper
├── test.sh                   # Generated snapshot of build-phase1.sh's smoke test
├── scripts/
│   ├── build-phase1.sh       # Downloads kernel + busybox and builds the initramfs
│   ├── overlay/              # Guest sources, config examples and files installed into initramfs
│   └── aegis-orchestrator.sh # Personal deployment tooling (hardcoded host/path, not portable)
├── build/                    # Build output (gitignored): assembled initramfs tree
└── images/                   # Built kernel + initramfs images (gitignored)
```

There is no `www/` directory and no `cgi-bin` — the UI, HTTP route handler, shell and `comb` memory tool live in `scripts/overlay/` and are copied into the initramfs by `scripts/build-phase1.sh`. `boot.sh` and `test.sh` are still generated by the build script.

---

## Design Philosophy

**Minimalism is not a constraint — it's the architecture.** The whole initramfs is close to 1MB. Almost everything in it is BusyBox symlinks plus one handful of generated shell scripts.

**The agent is not a service.** It doesn't run _on_ the OS. Its init script _is_ PID 1. If that script's main loop dies, the restart supervisor brings the HTTP handler back — but if `/init` itself crashes, the whole VM goes down with it, same as any init process.

**The agent talks to hardware through the normal Linux interfaces** — `/proc`, `/sys`, BusyBox utilities — not through custom syscalls. "Direct access" here means "no systemd/desktop layer in between," not "bypassing the kernel."

**Network is the nervous system.** The agent's LLM-backed reasoning (`/ai`, `/chat`) needs outbound network access to an LLM provider. No network means no LLM response — the rest of the HTTP API still works offline.

**Few processes, not forty.** The initramfs doesn't start a desktop, cron, or systemd units. The process tree is: `/init`, the HTTP handler loop, and whatever one-shot command the agent is currently executing.

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
