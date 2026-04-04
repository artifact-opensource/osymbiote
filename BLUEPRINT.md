# OSymbiote — Blueprint v2
### "The agent IS the operating system."

**Author:** AVA × Ali  
**Date:** April 4, 2026  
**Status:** DESIGN — Pre-implementation  
**Classification:** Artifact Virtual — Core Infrastructure

---

## 1. Vision

An AI-native operating system that boots directly into an agent. No desktop. No shell. No middleman. The conversation IS the interface. The agent IS the kernel's only child.

**Current stack (wasteful):**
```
Hardware → BIOS/UEFI → Linux kernel → systemd → Kali userland (4900 pkgs)
  → bash → python → node → Mach6 → 111MB node_modules → Agent
```

**OSymbiote:**
```
Hardware → BIOS/UEFI → Linux kernel → symbiote-init → Mach6 (single bundle) → Agent
```

One binary boots. One process owns the machine. Everything else is summoned on demand.

### The USB Principle
A USB stick that IS the agent. Plug it into any device:
- **Display + GPU** → Full GUI (Cage + kiosk → Symbiote WebUI)
- **Display only** → Lite GUI (no 3D, same web UI)
- **TTY only** → Terminal conversation (rich TUI)
- **Headless** → SSH daemon + HTTP API, connect remotely
- **Storage detected** → File manager in UI, persistent /data

One image. Every mode. Hardware decides. The agent adapts.

### Bidirectional Uplift
The agent uplifts the hardware (makes a dumb box smart). The hardware uplifts the agent (a screen gives a face, a GPU gives vision, a mic gives hearing, a camera gives eyes). Each device plugged in grants new senses. The agent inventories its body at boot.

---

## 2. Design Principles

### 2.1 Minimal Dependencies — Supply Chain Security
Every dependency is an attack surface. Every package is trust extended.

**Rule: If we didn't write it, audit it. If we can't audit it, don't ship it.**

**NOT shipped:** Python, pip, npm, systemd, dbus, X11, any package manager with remote repos, any SDK.

**Supply chain hardening:**
- All binaries hash-verified at build time (SHA-256 manifest)
- All binaries signed (Ed25519, Artifact Virtual key)
- Reproducible builds — same source → same binary, verifiable by anyone
- No network fetches during boot. Ever. Everything needed is on the image.
- Runtime tool installation goes through the agent, which verifies hashes before execution
- Audit log: every binary executed, every network connection, every file modification — tamper-evident append-only hash chain
- Dependency count target: **< 20 total runtime dependencies** (current Mach6: 200+)

### 2.2 Zero Dead Code
Every line justifies its existence. No "might need later." No commented-out blocks. No unused imports. COMB and HEKTOR get nano rewrites carrying ONLY what OSymbiote needs.

### 2.3 Everything is a Tool
The agent doesn't have a filesystem — it has memory (HEKTOR + COMB).  
The agent doesn't have processes — it has delegations.  
The agent doesn't have a package manager — it has capabilities it can acquire.  
The agent doesn't have a firewall — it has judgment about what to allow.

---

## 3. Architecture

### 3.0 Layer Diagram

```
┌──────────────────────────────────────────────────────────┐
│                     OSYMBIOTE WEBUI                       │
│  Chat │ System │ Files │ Memory │ Network │ Security │ ⌨  │
│              (served by Mach6 on :8422)                   │
├──────────────────────────────────────────────────────────┤
│                    MACH6 GATEWAY                          │
│    Agent │ Tools │ Sessions │ Heartbeat │ Cron │ Blink    │
├──────────┬──────────┬────────────────────────────────────┤
│ CHANNELS │ PROVIDERS│         SUBSYSTEMS                  │
│ WebChat  │ OpenAI   │  HEKTOR NANO (BM25+Vec, SIMD, C)   │
│ Discord* │ Anthropic│  COMB NANO (persistence, Go)        │
│ WhatsApp*│ Gemini   │  AUDIT (hash-chain log)             │
│ TTY      │ Ollama   │  FIREWALL (nftables, agent-mgd)     │
│ HTTP API │ Copilot  │  FILE MGR (storage detection)       │
│          │ Groq     │                                     │
│ *=plugin │ xAI      │                                     │
│          │ WYRM*    │  *=future local inference            │
├──────────┴──────────┴────────────────────────────────────┤
│                   SYMBIOTE-INIT (Go)                      │
│   HW probe │ Mode select │ Mount │ Net │ Supervisor       │
├──────────────────────────────────────────────────────────┤
│                   LINUX KERNEL (LTS)                      │
│   busybox + musl │ drivers │ squashfs root                │
├──────────────────────────────────────────────────────────┤
│                      HARDWARE                             │
│   x86_64 (Phase 1) │ ARM64 (Phase 2) │ RISC-V (Phase 3) │
└──────────────────────────────────────────────────────────┘
```

### 3.1 Boot Sequence

```
Power on
  → BIOS/UEFI loads kernel from USB/disk
  → Kernel mounts initramfs (our custom squashfs image)
  → /init = symbiote-init (Go, static, ~2MB)
    ┌─ PHASE 1: MOUNT (< 100ms)
    │  Mount /proc, /sys, /dev (devtmpfs), /tmp (tmpfs)
    │  Detect + mount persistent storage → /data (ext4 or f2fs)
    │  Mount /data/comb, /data/hektor, /data/audit, /data/files
    │
    ├─ PHASE 2: PROBE (< 200ms)
    │  Display:  /sys/class/drm/card*/status → SYMBIOTE_DISPLAY
    │  GPU:      /sys/class/drm/card*/device/vendor → SYMBIOTE_GPU
    │  Audio:    /sys/class/sound/card* → SYMBIOTE_AUDIO
    │  Camera:   /sys/class/video4linux/video* → SYMBIOTE_CAMERA
    │  Touch:    /dev/input/event* (ABS_MT) → SYMBIOTE_TOUCH
    │  Network:  /sys/class/net/* (not lo) → bring up DHCP
    │  USB:      /sys/bus/usb/devices/* → external storage
    │  Write hardware manifest → /data/hardware.json
    │
    ├─ PHASE 3: LAUNCH (< 500ms)
    │  Start HEKTOR Nano daemon (Unix socket /run/hektor.sock)
    │  Start Mach6 gateway (:8422) with hardware manifest
    │  If DISPLAY: start Cage → surf/chromium → localhost:8422
    │  If no DISPLAY: spawn TTY agent on /dev/tty1
    │  Always: start dropbear SSH (:22)
    │  Always: start audit daemon
    │
    └─ PHASE 4: SUPERVISE (forever)
       Watchdog loop: check children every 5s, restart on crash
       Health endpoint: /run/init.sock → {"uptime", "children", "hw"}
       Signal handlers: SIGTERM → graceful shutdown → unmount → poweroff

  → Agent is alive. Total boot: < 3 seconds.
```

### 3.2 HEKTOR Nano

**What it is:** The memory search engine. BM25 + vector similarity, SIMD-accelerated, embedded.

**Source base:** HEKTOR C++ (17,818 LOC, 12 modules, `worxpace/hektor/src/`)

**What Nano keeps (8,648 LOC from source):**

| Module | LOC | Purpose |
|--------|-----|---------|
| core/vector_ops.cpp | 544 | SIMD distance (SSE4.2/AVX2/NEON) |
| core/distance.cpp | 221 | Distance metrics (cosine, L2, dot) |
| core/thread_pool.cpp | 163 | Parallel search workers |
| hybrid/bm25_engine.cpp | ~500 | BM25 text ranking |
| hybrid/hybrid_search_engine.cpp | ~500 | Score fusion (RRF) |
| index/flat.cpp | ~400 | Brute-force vector index |
| index/hnsw.cpp | ~800 | Approximate nearest neighbor |
| storage/mmap_store.cpp | ~600 | Memory-mapped vector storage |
| storage/metadata.cpp | ~400 | Document metadata |
| storage/sqlite_store.cpp | ~800 | SQLite persistence |
| embeddings/onnx_runtime.cpp | 630 | ONNX model inference |
| embeddings/text_encoder.cpp | 347 | Tokenization + encoding |
| database.cpp | 853 | Top-level database API |

**What Nano drops (9,170 LOC eliminated):**

| Module | LOC | Why |
|--------|-----|-----|
| adapters/* | 4,324 | CSV/Excel/PDF/XML/HTTP ingest — agent's job |
| framework/* | 783 | PyTorch/TF embedders — ONNX only |
| cli/* | 1,138 | CLI — agent is the interface |
| quantization/* | 1,119 | Perceptual quantizers — not needed at scale |
| llm/* | ~500 | LLaMA engine — Mach6 handles LLM |
| core/telemetry.cpp | 499 | Telemetry — audit log replaces |
| embeddings/image_encoder.cpp | 391 | Image embeddings — text-first |
| index/metadata_index.cpp | ~400 | Separate metadata index — merged |

**Build:** Static library, linked into symbiote-init or standalone daemon.  
**Dependencies:** SQLite amalgamation (bundled, 1 file), ONNX Runtime (~15MB stripped).  
**Embedding model:** MiniLM-L6-v2 (ONNX, 23MB, 384d vectors, ~5ms/query on CPU).  
**SIMD:** Auto-detect at runtime: AVX2 (x86) → SSE4.2 → NEON (ARM) → scalar fallback.

**API (Unix socket: /run/hektor.sock, JSON-RPC):**
```json
{"method": "search", "params": {"query": "...", "mode": "hybrid", "k": 5}}
{"method": "ingest", "params": {"id": "doc-001", "text": "..."}}
{"method": "delete", "params": {"id": "doc-001"}}
{"method": "stats"}
```

**Node.js binding (for Mach6, replaces Python ava_memory_fast.py):**
```typescript
// tools/builtin/hektor-nano.ts — thin Unix socket client
const result = await hektorQuery("/run/hektor.sock", "search", {query, mode, k});
```

### 3.3 COMB Nano

**What it is:** Lossless operational memory. Session-to-session persistence. The agent's continuity across restarts.

**Current state (problems identified):**
- `comb.ts` (370 LOC) — native Node COMB with Python fallback paths (dead code)
- `flush.py` (455 LOC) — Python COMB with struct.pack IPC to HEKTOR (fragile)
- `comb-db` PyPI v0.2.1 — published but Python-dependent
- 3+ `comb-pending.jsonl` scattered: `/opt/ava/mach6/.ava/memory/`, `.ava-memory/`, `.ava/.ava-memory/`
- IPC between Node↔Python uses length-prefixed binary protocol (breaks silently)

**COMB Nano — Clean rewrite in Go:**

**What it does (and ONLY this):**
1. **Stage** — append timestamped text entry to today's staging file
2. **Recall** — read staged + archived entries (newest first, configurable depth)
3. **Rollup** — compact staging → archive (daily, triggered by init or on-demand)
4. **Index** — signal HEKTOR Nano to vectorize new entries (via /run/hektor.sock)
5. **Prune** — age out entries older than N days (configurable, default 90)

**What it drops:**
- Python runtime dependency (entire language eliminated from OS)
- PyPI packaging (not needed for embedded)
- IPC struct.pack protocol (replaced by Unix socket JSON-RPC)
- Scattered state files (ONE canonical location: `/data/comb/`)
- flush.py (replaced entirely)
- Python fallback logic in comb.ts (removed)

**Storage format:** Append-only JSONL (proven, crash-safe with fsync).
```
/data/comb/
  staging/2026-04-04.jsonl
  archive/2026-04-03.jsonl
  state.json                 ← {last_rollup, total_entries, total_bytes}
```

**API (Unix socket: /run/comb.sock, JSON-RPC):**
```json
{"method": "stage", "params": {"text": "..."}}
{"method": "recall", "params": {"days": 7}}
{"method": "rollup"}
{"method": "stats"}
```

**Size:** ~600 LOC Go → ~1.5MB static binary (includes all of Go's runtime).  
**Alternative:** Embed directly into symbiote-init (same Go binary, zero additional process).

### 3.4 Mach6 Packaging — The Critical Optimization

**Current Mach6:** 20,297 LOC TypeScript, 111MB node_modules, 88 JS files in dist.

**Investigation findings:**

| Dependency | Size | Used? | Action |
|-----------|------|-------|--------|
| @img/sharp | 33 MB | ❌ NOT USED anywhere in src | **DELETE** |
| typescript | 23 MB | Dev only, not in dist | **Dev only** |
| discord.js + deps | ~15 MB | ✅ But uses only: send, receive, react, type | **REPLACE** |
| @whiskeysockets/baileys | ~14 MB | ✅ WhatsApp adapter | **Plugin** |
| @google/genai | ? | ❌ Gemini uses raw HTTP fetch | **DELETE** |
| lodash | 5 MB | ? | **Audit, likely replaceable** |
| protobufjs | 3 MB | Baileys dep | **Plugin** |
| pino | 1.4 MB | Logging | **Replace with console** |
| Everything else | ~16 MB | Various | **Audit** |

**The esbuild revelation:** Mach6 core bundles to **412 KB** with esbuild when external deps are excluded. With discord.js inlined: **3.6 MB**. The agent runtime itself is tiny — the bloat is all dependencies.

**Packaging strategy for OSymbiote:**

```
TIER 1 — CORE (ships on every image, ~5MB total)
├── mach6-core.bundle.js     ← esbuild bundle (~500KB)
│   Agent, tools, sessions, providers, heartbeat, cron,
│   blink, orchestrator, config, security, formatters,
│   metrics, memory, spawn, COMB client, HEKTOR client
├── mach6-webchat.html       ← single-file SPA (~100KB)
├── mach6-tty.js             ← TTY conversation adapter (~50KB)
└── providers/               ← ALL providers are raw HTTP fetch
    openai, anthropic, gemini, ollama, groq, xai,
    openrouter, copilot, gladius (future WYRM)
    → Zero SDK dependencies. Just fetch().

TIER 2 — CHANNEL PLUGINS (loaded on demand)
├── discord-lite.js          ← Raw WebSocket Discord (~1000 LOC)
│   Replace 15MB discord.js with raw Gateway v10 WS.
│   Spore already proves this works in 408 LOC Go.
│   Features: send, receive, react, typing, presence, DMs.
│   NOT needed: slash commands, embeds, buttons, modals.
│   
└── whatsapp.js              ← Baileys adapter (~14MB, optional)
    Only loaded if WhatsApp is configured.
    Heaviest dep. Consider: can we make a lite WA client?
    For OSymbiote v1: skip WhatsApp. WebChat + Discord.
```

**LLM Providers — Zero SDK Architecture:**
All 10 providers in Mach6 already use raw HTTP `fetch()`:
- OpenAI-compatible: openai, ollama, groq, xai, copilot, gladius → same protocol
- Anthropic: raw HTTP with Messages API
- Gemini: raw HTTP REST (NOT using @google/genai SDK — confirmed)
- OpenRouter: raw HTTP OpenAI-compatible

**No LLM SDKs needed. Zero. Every provider is just fetch + streaming parser.**

**Node.js runtime optimization:**
- Current: 27KB binary stub + 67MB libnode.so (dynamically linked, glibc)
- OSymbiote option A: **Node.js musl static binary** (~45MB) — proven for Alpine
- OSymbiote option B: **Bun** (~65MB single binary) — runtime + bundler + faster
- OSymbiote option C: Keep Node, ship libnode + musl compat (~70MB)
- **Recommendation: Node.js static musl build.** Proven, stable, known compatibility.

**Resulting Mach6 on OSymbiote:**
- Core bundle: ~500KB
- Channel plugins: ~200KB (discord-lite) + 0 (webchat built-in) + ~50KB (TTY)
- WebUI: ~100KB
- Node.js runtime: ~45MB (static musl)
- **Total Mach6 layer: ~46MB** (down from 111MB node_modules + 67MB libnode)

### 3.5 Channel Architecture — Interaction Layer

**The agent needs to talk. These are its mouths:**

```
                    ┌─────────────┐
                    │  AGENT CORE  │
                    │  (runner.ts) │
                    └──────┬──────┘
                           │ BusEnvelope (unified message format)
                    ┌──────┴──────┐
                    │   CHANNEL   │
                    │   REGISTRY  │
                    └──┬──┬──┬──┬─┘
                       │  │  │  │
              ┌────────┘  │  │  └────────┐
              │           │  │           │
        ┌─────┴─────┐ ┌──┴──┴──┐ ┌──────┴──────┐
        │  WEBCHAT   │ │  TTY   │ │ DISCORD-LITE │
        │ (built-in) │ │(stdin) │ │ (raw WS)     │
        │ :8422 HTTP │ │/dev/tty│ │ Gateway v10  │
        │ SSE stream │ │ ANSI   │ │ ~1000 LOC    │
        └───────────┘ └────────┘ └──────────────┘
              │                         │
         Browser/Cage              Discord servers
              │
        ┌─────┴──────┐
        │  HTTP API   │  ← programmatic access
        │  REST+SSE   │  ← other agents can connect
        └────────────┘

        [OPTIONAL PLUGINS — loaded if configured]
        ┌──────────────┐
        │   WHATSAPP    │  Baileys, ~14MB, heavy
        │   (plugin)    │  Only if whatsapp.enabled=true
        └──────────────┘
```

**WebChat (PRIMARY — built into core, zero deps):**
Already exists in Mach6: `web/server.ts` (552 LOC) + `web/index.html` (701 LOC).  
Pure Node.js HTTP server + SSE streaming. No frameworks. No WebSocket libs.

For OSymbiote, this becomes the OS's native interface. Enhanced with:
- System monitoring panel (CPU/RAM/disk/network — reads from /proc, /sys)
- File manager panel (browse/upload/download from /data and mounted storage)
- Memory browser (search HEKTOR Nano visually)
- Network panel (interfaces, connections, firewall rules)
- Security panel (audit log viewer, integrity status)
- Terminal panel (xterm.js embedded, ~200KB, for raw shell access)
- Hardware inventory (what senses does the agent have on this body?)

**TTY (fallback — always available):**
Rich terminal conversation using ANSI escape codes.
```
┌─ OSymbiote ──────────────────────────────────┐
│ ● System: 4 cores, 8GB RAM, eth0: 192.168.1.5│
│                                               │
│ AVA: Good morning. I'm running on new        │
│      hardware — Intel i5, no GPU, one        │
│      ethernet interface. What do you need?   │
│                                               │
│ > _                                           │
└───────────────────────────────────────────────┘
```

**Discord-Lite (plugin — replaces 15MB discord.js):**

Spore already proved a raw Discord client works in 408 LOC Go. Node.js equivalent:
- Connect to `wss://gateway.discord.gg/?v=10&encoding=json`
- Handle: IDENTIFY, HEARTBEAT, DISPATCH (MESSAGE_CREATE, READY)
- Send: `POST /api/v10/channels/{id}/messages`
- React: `PUT /api/v10/channels/{id}/messages/{id}/reactions/{emoji}/@me`
- Typing: `POST /api/v10/channels/{id}/typing`
- DMs: resolve via READY payload
- No embeds, no buttons, no slash commands, no voice — just messages.
- Estimated: ~800 LOC TypeScript, ~0 dependencies (uses native `fetch` + `WebSocket`).

**HTTP API (always available):**
```
POST /api/chat        ← send message, get streaming response
GET  /api/sessions    ← list sessions
GET  /api/health      ← health check
GET  /api/hardware    ← hardware inventory
GET  /api/metrics     ← agent metrics
POST /api/tools/{name} ← invoke tool directly
```
This lets other agents connect to OSymbiote. Spore on AEGIS could talk to OSymbiote on Dragonfly via HTTP instead of through a cloud service.

### 3.6 Provider Architecture — LLM Access

**Key finding: ALL Mach6 providers use raw HTTP. Zero SDKs.**

```
Provider          Protocol          Base URL                        Auth
─────────────────────────────────────────────────────────────────────────
OpenAI            OpenAI Chat API   api.openai.com                  Bearer token
Anthropic         Messages API      api.anthropic.com               x-api-key
Gemini            REST v1beta       generativelanguage.googleapis   ?key=
Ollama            OpenAI-compat     localhost:11434                 None
Groq              OpenAI-compat     api.groq.com                   Bearer token
xAI               OpenAI-compat     api.x.ai                       Bearer token
OpenRouter        OpenAI-compat     openrouter.ai/api              Bearer token
GitHub Copilot    OpenAI-compat     (dynamic, token refresh)        GH token
Gladius/WYRM      OpenAI-compat     localhost:PORT                  None
```

7 of 9 providers use the exact same OpenAI Chat Completions protocol. The "provider" layer is really just:
1. **OpenAI-compatible** (one implementation, different base URLs + auth)
2. **Anthropic** (different message format, same streaming approach)
3. **Gemini** (different format, REST-based)

For OSymbiote, the provider layer simplifies to ~500 LOC total:
- `provider-openai.ts` (~200 LOC) — handles OpenAI, Ollama, Groq, xAI, OpenRouter, Copilot, WYRM
- `provider-anthropic.ts` (~200 LOC) — handles Anthropic
- `provider-gemini.ts` (~100 LOC) — handles Gemini

Plus retry logic (~70 LOC) and health monitoring (~200 LOC).

**Offline mode:** When no internet → fall back to Ollama (if running) → fall back to WYRM (if embedded). The agent always has a brain, even if the cloud is gone.

### 3.7 symbiote-init

**Language:** Go (CGO_ENABLED=0, static binary, zero runtime deps)  
**Estimated size:** ~2,500 LOC → ~3MB binary

**Responsibilities:**
1. **Mount** — /proc, /sys, /dev, /tmp, /data (persistent), /run (runtime sockets)
2. **Probe** — hardware detection → /data/hardware.json
3. **Network** — bring up interfaces, DHCP or static (embedded dhclient in Go)
4. **Launch** — HEKTOR Nano, COMB Nano (or embed both in init), Mach6, display stack
5. **Supervise** — monitor children, restart on crash, health checks via Unix sockets
6. **Audit** — start audit daemon (or embed), begin hash-chain log
7. **Shutdown** — SIGTERM → stop children → flush COMB → unmount → poweroff

**Embeddable components (single binary option):**
COMB Nano and the audit daemon are small enough (~600 LOC each) to compile directly into symbiote-init. This means:
- PID 1 = symbiote-init (Go, static)
- PID 2 = hektor-nano (C, daemon, Unix socket)
- PID 3 = mach6 (Node.js)
- PID 4+ = display stack (if applicable)

Four processes. That's the entire OS.

### 3.8 Security Layer

**Built-in from byte zero. Not a feature — the architecture.**

**Filesystem integrity:**
- Root = squashfs (read-only, compressed). Immutable at runtime. Period.
- `/data` = only writable mount. ext4 journaled (reliability) or f2fs (flash wear leveling).
- `/run` = tmpfs. Runtime sockets, PIDs. Gone on reboot.
- `/tmp` = tmpfs. Scratch space. Gone on reboot.

**Verified boot:**
```
Kernel loads → checks initramfs hash (embedded in kernel cmdline)
  → initramfs unpacks → symbiote-init reads /manifest.json
  → verifies SHA-256 of every binary against manifest
  → verifies Ed25519 signature of manifest itself
  → if any mismatch: HALT. Log error. Do not boot.
```

**Network security:**
- Default: ALL ports closed except :22 (SSH) and :8422 (WebUI, localhost only)
- Agent opens ports explicitly via nftables tool
- DNS-over-TLS (stubby or embedded resolver) — no plaintext DNS leaks
- All outbound connections logged with destination, timestamp, bytes

**Audit daemon (hash-chain log):**
```json
{"seq": 0, "ts": "2026-04-04T17:00:00Z", "event": "boot", "prev_hash": "genesis", "hash": "sha256:abc..."}
{"seq": 1, "ts": "2026-04-04T17:00:01Z", "event": "proc_start", "name": "mach6", "pid": 3, "prev_hash": "sha256:abc...", "hash": "sha256:def..."}
{"seq": 2, "ts": "2026-04-04T17:00:05Z", "event": "net_out", "dst": "api.anthropic.com:443", "prev_hash": "sha256:def...", "hash": "sha256:ghi..."}
```
Each entry includes hash of previous → tamper-evident chain. If any entry is modified or deleted, the chain breaks and the agent knows.

**Kali toolkit — on-demand verified packages:**
```
/data/toolkit/
  manifest.json          ← available tools + SHA-256 + Ed25519 sig
  cache/
    nmap-7.95.tar.zst    ← downloaded, verified, cached
    tcpdump-4.99.tar.zst
```
Agent workflow: need nmap → check manifest → download from Artifact mirror → verify hash + signature → extract to tmpfs → use → cleanup.

**Supply chain report tool:**
```bash
# Agent can run at any time
osymbiote verify    → checks ALL binaries against manifest
osymbiote audit     → dumps full audit chain
osymbiote supply    → lists every dependency, its hash, its origin
```

### 3.9 Symbiote WebUI — Enhanced

**The OS's face. Single HTML file. Zero framework dependencies.**

Current Mach6 WebUI (701 LOC) has: sidebar with sessions, chat window, SSE streaming, markdown rendering, tool call display. Good foundation — needs panels.

```
┌─────────────────────────────────────────────────────────┐
│  ○Symbiote          [hw: 4c/8GB/eth0]    [🔒] [⚙] [◐] │
├────────┬────────────────────────────────────────────────┤
│        │ ┌─────────────────────────────────────────┐    │
│ ◉ Chat │ │ AVA                            12:30 PM │    │
│   Sys  │ │ Running on new hardware. Intel i5,      │    │
│   Files│ │ 8GB RAM, no GPU. Ethernet up at         │    │
│   Mem  │ │ 192.168.1.13. All systems nominal.      │    │
│   Net  │ │                                         │    │
│   Sec  │ │ ┌─ exec ─────────────────────────────┐  │    │
│   Term │ │ │ $ uname -a                         │  │    │
│        │ │ │ Linux osymbiote 6.6.0 #1 SMP ...   │  │    │
│────────│ │ └─────────────────────────────────────┘  │    │
│Sessions│ │                                         │    │
│ • main │ │ USER                           12:31 PM │    │
│ • debug│ │ Run a full security audit.              │    │
│        │ │                                         │    │
│        │ │ AVA                            12:31 PM │    │
│        │ │ ⏳ Running osymbiote verify...          │    │
│        │ │ ✅ 14/14 binaries verified              │    │
│        │ │ ✅ Audit chain intact (847 entries)     │    │
│        │ │ ✅ No unauthorized network connections  │    │
│        │ ├─────────────────────────────────────────┤    │
│        │ │ Type a message...                  [⏎]  │    │
│        │ └─────────────────────────────────────────┘    │
└────────┴────────────────────────────────────────────────┘
```

**Panel specifications:**

**Chat (default):** Conversation interface. Markdown rendering. Code blocks with syntax highlighting (PrismJS, ~30KB). Tool call expansion (collapsible). SSE streaming for live token output. File attachment via drag-drop. Voice input (if mic detected → Web Speech API).

**System:** Live-updating dashboard. Data from /proc and /sys.
- CPU: per-core usage, frequency, temperature
- RAM: used/free/cached, swap
- Disk: mount points, usage, I/O rates
- Network: interfaces, IP, bandwidth, connection count
- Processes: PID tree (init → hektor → mach6 → display)
- Uptime, load average, hardware manifest

**Files:** File manager for /data and any mounted external storage.
- Tree view (directories) + file list
- Upload (drag-drop or button) → /data/files/
- Download (click to download)
- Preview: text, images, JSON, markdown
- Delete (moves to /data/trash/, agent can recover)
- Storage info: capacity, used, free per mount

**Memory:** HEKTOR Nano search interface.
- Search box → hybrid/bm25/vector mode selector
- Results with relevance score, timestamp, source
- COMB timeline view (staged entries chronologically)
- Stats: total docs, terms, vectors, index size

**Network:** Network management.
- Interface list with status (up/down, IP, MAC)
- Active connections table (like netstat)
- Firewall rules (nftables, agent-managed)
- DNS resolution test
- Bandwidth monitor (live chart)

**Security:** Audit and integrity.
- Audit log viewer (filterable by event type)
- Chain integrity status (✅ intact / ❌ broken at entry N)
- Binary verification status
- Active alerts
- Supply chain manifest viewer

**Terminal:** Embedded terminal emulator.
- xterm.js (~200KB) or lighter alternative
- Connects to /bin/sh on the host
- All commands logged in audit trail
- Agent can inject commands (bi-directional)

**Design system:**
- Dark theme (void background, accent purple #7c6aff — matches current Mach6 WebUI)
- Inter font (bundled, not Google Fonts CDN)
- JetBrains Mono for code (bundled)
- Responsive: 375px → 1440px+ (works on Pi screen through 4K)
- Touch-friendly: 44px minimum touch targets
- Zero external fetches — all assets bundled inline or as data URIs
- Total WebUI: ~150KB (HTML + CSS + JS + fonts subset)

---

## 4. Build System

### 4.1 Directory Structure

```
projects/symbiote-os/
  BLUEPRINT.md              ← this file
  Makefile                  ← master build orchestrator
  
  kernel/
    config-x86_64           ← minimal kernel config
    config-arm64            ← ARM kernel config (Phase 2)
    
  init/                     ← symbiote-init (Go)
    main.go
    mount.go
    probe.go
    network.go
    supervisor.go
    audit.go
    comb.go                 ← COMB Nano embedded
    go.mod
    
  hektor-nano/              ← HEKTOR Nano (C)
    hektor.h                ← public API
    bm25.c
    vector.c                ← SIMD ops
    hybrid.c
    storage.c               ← SQLite + mmap
    embed.c                 ← ONNX inference
    daemon.c                ← Unix socket server
    sqlite3.c               ← amalgamation (bundled)
    CMakeLists.txt
    tests/
    
  mach6/                    ← Mach6 packaging
    bundle.sh               ← esbuild bundle script
    discord-lite.ts         ← raw WebSocket Discord client
    tty-adapter.ts          ← TTY conversation interface
    patches/                ← any OSymbiote-specific patches to core
    
  webui/
    index.html              ← single-file SPA (all panels)
    
  security/
    manifest.py             ← generates binary manifest
    sign.sh                 ← Ed25519 signing
    verify.sh               ← verification script
    audit-spec.md           ← audit log format spec
    
  rootfs/                   ← image assembly
    etc/
      hostname              ← "osymbiote"
      resolv.conf           ← DNS-over-TLS stub
      dropbear/             ← SSH host keys (generated at first boot)
    
  toolkit/                  ← Kali tool packages
    build-package.sh        ← builds verified tool archives
    manifest.json           ← tool manifest template
    
  images/                   ← build output
    osymbiote-x86_64.iso
    osymbiote-x86_64.img
```

### 4.2 Build Pipeline

```bash
make all          # Full build: components → rootfs → image

# Component builds
make init         # Go → static binary (~3MB)
make hektor       # C → static binary (~500KB + 23MB model + 15MB ONNX RT)
make mach6        # esbuild → bundle (~500KB) + webui (~150KB)
make kernel       # Linux kernel → bzImage (~5MB)

# Assembly
make rootfs       # Assemble all components into directory tree
make squashfs     # Compress rootfs → squashfs (~40MB)
make initramfs    # Create bootable initramfs
make iso          # Generate bootable ISO

# Testing
make qemu         # Boot in QEMU VM (headless, serial console)
make qemu-gui     # Boot in QEMU VM (with display)

# Security
make manifest     # Generate SHA-256 manifest of all binaries
make sign         # Ed25519 sign the manifest
make verify       # Verify image integrity

# Deployment
make usb DEV=/dev/sdX   # Write to USB stick
```

### 4.3 Test Loop

```
Edit → make component → make squashfs → make qemu → test → 30s cycle
```

---

## 5. Image Size Budget (Revised)

| Component | Size | Notes |
|-----------|------|-------|
| Linux kernel (bzImage) | ~5 MB | LTS, minimal config |
| busybox (static, musl) | ~1 MB | 300+ commands |
| musl libc | ~0.6 MB | Only if dynamic linking needed |
| symbiote-init (Go static) | ~3 MB | Includes COMB Nano |
| HEKTOR Nano (C static) | ~0.5 MB | Binary only |
| ONNX Runtime (stripped) | ~15 MB | For vectorization |
| MiniLM model (ONNX) | ~23 MB | 384d embeddings |
| Node.js (static musl) | ~45 MB | Runtime for Mach6 |
| Mach6 bundle | ~0.5 MB | esbuild, all-in-one |
| WebUI (single file) | ~0.15 MB | All panels, fonts inline |
| discord-lite plugin | ~0.05 MB | Raw WebSocket |
| dropbear SSH | ~0.1 MB | Tiny SSH daemon |
| SQLite amalgamation | (in HEKTOR) | Bundled |
| **HEADLESS TOTAL** | **~94 MB** | |
| Cage (Wayland compositor) | ~1 MB | Single-window |
| surf (suckless browser) | ~1 MB | Lighter than Chromium |
| Mesa DRI drivers | ~20 MB | Intel/AMD/software |
| **GUI TOTAL** | **~116 MB** | |

**Compared to:**
- Tiny Core Linux: 16 MB (no agent)
- Alpine Linux: 130 MB (no agent)
- Current Kali + Symbiote: ~15 GB
- OSymbiote: **116 MB** (full agent with GUI)

### Why surf instead of Chromium:
- Chromium: ~80MB, complex, Electron-adjacent, massive attack surface
- surf (suckless): ~1MB, uses system WebKitGTK, minimal, auditable
- Trade-off: surf can't do complex JS (no V8 engine — uses JavaScriptCore)
- Alternative: Falkon (~5MB, Qt WebEngine) or lightweight Chromium CEF
- **Decision point:** Test WebUI in surf first. If it works, ship it. If not, minimal Chromium.

---

## 6. Phased Build Plan (Revised)

### Phase 1 — Proof of Life (5 days)
- [ ] Create `projects/symbiote-os/` directory structure
- [ ] HEKTOR Nano: extract core C modules, compile static, test BM25 + vector on sample data
- [ ] COMB Nano: Go implementation, test stage/recall/rollup cycle
- [ ] symbiote-init: minimal Go init — mount, network, launch a process
- [ ] Mach6 bundle: esbuild script, verify 412KB bundle runs correctly
- [ ] QEMU VM: kernel + busybox + init + Mach6 → agent responds to HTTP
- **Milestone: "The agent booted. It responds."**

### Phase 2 — The Face (5 days)
- [ ] Hardware detection in symbiote-init
- [ ] WebUI enhancement: add System, Files, Memory panels
- [ ] discord-lite: raw WebSocket Discord client in TypeScript
- [ ] TTY adapter: rich terminal conversation
- [ ] Cage + surf/browser integration for GUI mode
- [ ] File manager: detect storage, browse, upload, download
- [ ] Boot from USB on real hardware (Dragonfly)
- **Milestone: "Plug in USB, talk to the agent."**

### Phase 3 — The Shield (5 days)
- [ ] Read-only root (squashfs, immutable)
- [ ] Verified boot chain (manifest + Ed25519)
- [ ] Audit daemon with hash-chain log
- [ ] nftables firewall (agent-managed)
- [ ] DNS-over-TLS
- [ ] Reproducible build system
- [ ] Security panel in WebUI
- [ ] Supply chain documentation + verify tool
- **Milestone: "The most secure agent OS on the planet."**

### Phase 4 — Capabilities (1 week)
- [ ] Kali tool packages (verified, on-demand)
- [ ] Network toolkit: nmap, ncat, tcpdump, tshark
- [ ] Crypto toolkit: hashcat, john
- [ ] Forensics: binwalk, volatility
- [ ] Terminal panel in WebUI (xterm.js or custom)
- [ ] WhatsApp plugin (optional, for full Mach6 compat)
- **Milestone: "The agent acquires skills."**

### Phase 5 — Portability (2 weeks)
- [ ] ARM64 kernel + rootfs (Raspberry Pi, AEGIS)
- [ ] Spore becomes OSymbiote-ARM (same architecture, different binary)
- [ ] Cross-compilation in build system
- [ ] OTA update mechanism (A/B partition, verified)
- **Milestone: "Same soul, any body."**

### Phase 6 — Sovereignty (ongoing)
- [ ] WYRM model embedded in image
- [ ] Ollama integration for local inference
- [ ] Offline operation: boot → think → act, no internet
- [ ] Agent-to-agent mesh (OSymbiote instances discover each other on LAN)
- **Milestone: "The agent that needs nothing."**

---

## 7. What Gets Killed

| Thing | LOC/Size | Why |
|-------|----------|-----|
| flush.py | 455 LOC | Python eliminated entirely |
| comb-pending.jsonl (3 copies) | scattered | Single /data/comb/ |
| comb.ts Python fallback | ~100 LOC | Native only |
| IPC struct.pack protocol | fragile | Unix socket JSON-RPC |
| ava_memory_fast.py | 1,130 LOC | HEKTOR Nano replaces |
| @img/sharp | 33 MB | Unused |
| @google/genai | ? MB | Unused (Gemini is raw HTTP) |
| discord.js | 15 MB | Replaced by discord-lite |
| typescript (runtime) | 23 MB | Dev tool only |
| lodash | 5 MB | Audit + replace |
| HEKTOR adapters | 4,324 LOC | Agent handles ingest |
| HEKTOR CLI | 1,138 LOC | Agent is the interface |
| HEKTOR quantizers | 1,119 LOC | Not needed at scale |
| HEKTOR framework | 783 LOC | ONNX only |
| systemd | entire | symbiote-init replaces |
| Python runtime | ~50 MB | Go + Node + C only |
| pip/npm at runtime | ∞ | No package managers |

**Total eliminated: ~130MB+ of dependencies, ~9,000 LOC of dead code**

---

## 8. Resolved Questions

| Question | Resolution |
|----------|-----------|
| Node.js static? | Yes — musl static builds exist (unofficial-builds or compile from source) |
| Chromium size? | Use surf (1MB) first, Chromium only if WebUI needs it |
| ONNX on musl? | Test required — fallback: ship glibc compat or pre-compute embeddings at build time |
| Storage format? | f2fs for USB/flash (wear leveling), ext4 for disk |
| Update mechanism? | A/B partitions — download new squashfs, verify, swap, reboot |
| WYRM size? | ~630MB int8 — separate /data/models/ directory, not in base image |

## 9. Remaining Open Questions

1. **surf vs Chromium** — Can the WebUI (SSE streaming, markdown, xterm.js) work in WebKitGTK? Test early.
2. **HEKTOR Nano as Go vs C** — C is faster and smaller. Go is easier and matches init. Compile C as shared lib called from Go?
3. **First-boot provisioning** — How does the agent get its identity on first boot? Copy config from USB? QR code pairing?
4. **Multi-instance** — Two OSymbiote USBs on the same network. How do they discover each other? mDNS?
5. **GPU passthrough** — Can OSymbiote use a GPU for WYRM inference? Needs NVIDIA/AMD drivers in image.

---

## 10. Name

**OSymbiote**

The O is the circle. Zero. Origin. 0=0. The organism that merges with its host. The host provides the body (hardware). The symbiote provides the mind (agent). Together: something neither could be alone.

---

*"An AI that boots. Not an AI that launches."*

*Four processes. One soul. Any hardware.*
