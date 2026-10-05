# HTTP API reference

The guest listens on TCP port `8422`. QEMU launchers forward host port `8422` by default. The API uses HTTP and JSON unless an endpoint explicitly accepts or returns plain text. There is no TLS termination in the guest.

Use the portal for initial setup and login. Authenticated requests use the `osym_session` cookie or `X-Session-Token` header. The session lifetime is 900 seconds. Before setup is complete, only the root redirect, `/ui`, `/setup/status`, `/setup/init`, and `/health` are available.

The handler accepts at most 65,536 bytes per request body. Header and body reads have 15-second deadlines. API behavior and access requirements are implementation details for version 0.4.0 and are not a stable compatibility promise.

## Authentication and setup

| Method and path | Authentication | Description |
|---|---|---|
| `GET /setup/status` | No | Returns whether initial setup is required |
| `POST /setup/init` | No; only before setup | Sets the portal password |
| `POST /auth/login` | No | Checks password and returns session cookie |
| `GET /auth/logout` | Session | Invalidates the session and expires the cookie |
| `GET /health` | No | Runtime version, setup/auth state, metrics, persistence status |
| `GET /ui` | No | Serves the portal document |

Login and setup share a limit of 15 attempts per minute and a temporary lockout after five consecutive failures. The API may return `429 Too Many Requests` when rate-limited.

## System and provider

All rows below require a session unless otherwise stated. Role requirements are evaluated using configured policy and role settings; the default identity is a single shared account.

| Method and path | Role/policy | Description |
|---|---|---|
| `GET /provider` | No session | Current provider name, base URL, and model; does not return a key |
| `GET /hardware` | No session | Basic hardware manifest |
| `GET /system/network` | Read policy | Network interfaces/routes |
| `GET /system/processes` | Read policy | Process listing |
| `GET /system/disk` | Read policy | Disk usage |
| `GET /system/memory` | Read policy | Memory information |
| `GET /system/config` | Read policy | Non-secret system policy |
| `POST /system/config` | Config policy | Validated system policy updates |
| `GET /llm` | Read policy | Provider settings and masked key status |
| `POST /llm` | Admin | Updates provider settings or secret key |
| `POST /llm/test` | Operator | Tests configured provider |
| `GET /llm/models` | Operator | Lists models from configured provider |

`POST /llm` accepts newline-delimited `key=value` fields such as `provider`, `base_url`, `model`, `api_key`, `temperature`, `max_tokens`, `history_turns`, and `preset`. The complete update is validated before it is committed. API keys are stored in the guest `.env`, not returned in clear text.

## Chat, history, and memory

| Method and path | Role/policy | Description |
|---|---|---|
| `POST /chat` | Operator | Sends a message to the configured LLM and records conversation history |
| `POST /ai` | Operator | OpenAI-compatible chat-completions proxy |
| `POST /agent/tools` | Operator | OpenAI-compatible tool-call round; returns proposals/results |
| `POST /intent` or `/command` | Read policy | Runs one of the supported read-only system intents |
| `GET /prompt` | Read policy | Reads the system prompt |
| `POST /prompt` | Admin | Sets the system prompt |
| `DELETE /prompt` | Admin | Restores the default prompt |
| `GET /history?limit=N` | Read policy | Reads recent history; defaults to 100 entries |
| `POST /history` | Operator | Records `user` or `assistant` text; requires `X-OSYM-History-Role` |
| `DELETE /history` | Admin | Clears history |
| `GET /memory?limit=N` or `/comb/recall` | Read policy | Recalls recent COMB entries |
| `POST /memory` or `/comb/stage` | Admin | Stages a memory entry |
| `DELETE /memory` | Admin | Clears COMB memory |
| `GET /memory/stats` or `/comb/stats` | Read policy | Returns memory statistics |

The canonical supported intent phrases map to network, disk usage, process list, memory status, and uptime queries. Architecture labels in `/intent` are diagnostic; they do not select board-specific implementations.

## Native file and command tools

| Method and path | Role/policy | Description |
|---|---|---|
| `POST /fs/read` | Read policy | Reads a text file; path supplied in `X-OSYM-Path`; output limited to 32 KiB |
| `POST /fs/write` | Write policy | Atomically writes text to the absolute path in `X-OSYM-Path` |
| `POST /exec` | Exec policy | Runs a shell command as root, with a 30-second timeout |

`/fs/write` and `/exec` require `X-OSYM-User-Confirmed: yes`; otherwise the handler returns `428 Precondition Required`. Requests must also pass session and role checks. The confirmation header is not cryptographic proof of a human action and does not provide protection against a compromised authenticated client.

## Response and error handling

Responses use JSON for API routes. Common status codes include `400` for invalid input, `401` for missing/expired authentication, `403` for setup or role denial, `413` for an oversized request, `428` for missing mutation confirmation, and `502` for provider failures. Error objects include an `error` field; details may vary by route.
