#!/bin/bash
# OSymbiote Phase 1 — Proof of Life Build
# Builds a bootable x86_64 agent OS that runs in QEMU on Termux (ARM64)
#
# KEY: We need x86_64 binaries for the initramfs, not ARM64!
# Solution: Download pre-built x86_64 static binaries

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSYM="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$OSYM/build"
IMAGES="$OSYM/images"
ROOTFS="$OSYM/rootfs-x86"

echo "╔══════════════════════════════════════════╗"
echo "║     OSymbiote Phase 1 — Proof of Life    ║"
echo "║     Host: $(uname -m) → Target: x86_64         ║"
echo "╚══════════════════════════════════════════╝"

mkdir -p "$BUILD" "$IMAGES" "$ROOTFS"

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "  ERROR: Missing required tool: $1"
        exit 1
    }
}

download_file() {
    local dst="$1"
    shift
    local url
    for url in "$@"; do
        if wget -q --show-progress -O "$dst" "$url" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ═══════════════════════════════════════════════
# Step 1: Install QEMU and tools
# ═══════════════════════════════════════════════
echo "[1/6] Installing packages..."
if command -v pkg >/dev/null 2>&1; then
    pkg upgrade -y 2>/dev/null || true
    for p in qemu-system-x86-64 wget curl coreutils cpio gzip; do
        pkg install -y "$p" 2>/dev/null || echo "  $p already installed or unavailable"
    done
else
    echo "  Non-Termux host detected; skipping pkg install."
fi

for t in wget cpio gzip; do
    require_tool "$t"
done
command -v qemu-system-x86_64 >/dev/null 2>&1 || echo "  WARN: qemu-system-x86_64 not found (build will still complete)."

# ═══════════════════════════════════════════════
# Step 2: Get x86_64 kernel (Alpine netboot)
# ═══════════════════════════════════════════════
echo "[2/6] Getting x86_64 kernel..."
if [ ! -f "$BUILD/vmlinuz" ]; then
    wget -q --show-progress -O "$BUILD/vmlinuz" \
        "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/netboot/vmlinuz-virt" 2>&1 || {
        echo "  Primary failed, trying mirror..."
        wget -q -O "$BUILD/vmlinuz" \
            "https://mirrors.edge.kernel.org/alpine/v3.21/releases/x86_64/netboot/vmlinuz-virt" 2>&1 || {
            echo "  ERROR: Cannot download kernel. Check internet."
            exit 1
        }
    }
    echo "  Kernel: $(du -h "$BUILD/vmlinuz" | cut -f1)"
else
    echo "  Kernel cached."
fi

# ═══════════════════════════════════════════════
# Step 3: Get x86_64 static busybox
# ═══════════════════════════════════════════════
echo "[3/6] Getting x86_64 static busybox..."
if [ ! -f "$BUILD/busybox-x86_64" ]; then
    if ! download_file "$BUILD/busybox-x86_64" \
        "https://busybox.net/downloads/binaries/1.36.1-defconfig-multiarch-musl/busybox-x86_64" \
        "https://busybox.net/downloads/binaries/1.35.0-x86_64-linux-musl/busybox" \
        "https://busybox.net/downloads/binaries/1.31.0-defconfig-multiarch-musl/busybox-x86_64"; then
        echo "  busybox.net failed, trying Alpine busybox-static..."
        TMPDIR="$(mktemp -d)"
        trap 'rm -rf "$TMPDIR"' EXIT
        APKINDEX_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/x86_64/APKINDEX.tar.gz"

        wget -q -O "$TMPDIR/APKINDEX.tar.gz" "$APKINDEX_URL" 2>/dev/null || {
            echo "  ERROR: Cannot fetch Alpine APK index."
            exit 1
        }

        tar -xzf "$TMPDIR/APKINDEX.tar.gz" -C "$TMPDIR" APKINDEX
        BB_VER=$(
            awk -v RS='' '
                $0 ~ /\nP:busybox-static\n/ {
                    if (match($0, /\nV:([^\n]+)/, m)) {
                        print m[1]
                        exit
                    }
                }
            ' "$TMPDIR/APKINDEX"
        )

        [ -n "${BB_VER:-}" ] || {
            echo "  ERROR: Could not resolve busybox-static version from Alpine index."
            exit 1
        }

        APK_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/x86_64/busybox-static-${BB_VER}.apk"
        wget -q -O "$TMPDIR/busybox.apk" "$APK_URL" 2>/dev/null || {
            echo "  ERROR: Cannot download Alpine busybox-static package."
            exit 1
        }

        if tar -tf "$TMPDIR/busybox.apk" | grep -q '^bin/busybox.static$'; then
            tar -xzf "$TMPDIR/busybox.apk" -C "$TMPDIR" bin/busybox.static
            cp "$TMPDIR/bin/busybox.static" "$BUILD/busybox-x86_64"
        elif tar -tf "$TMPDIR/busybox.apk" | grep -q '^bin/busybox$'; then
            tar -xzf "$TMPDIR/busybox.apk" -C "$TMPDIR" bin/busybox
            cp "$TMPDIR/bin/busybox" "$BUILD/busybox-x86_64"
        else
            echo "  ERROR: busybox binary not found in Alpine package."
            exit 1
        fi
        rm -rf "$TMPDIR"
        trap - EXIT
    fi

    chmod +x "$BUILD/busybox-x86_64"

    if command -v file >/dev/null 2>&1; then
        file "$BUILD/busybox-x86_64" | grep -qi "x86-64" || {
            echo "  ERROR: Downloaded busybox is not x86_64."
            exit 1
        }
    fi

    echo "  Busybox: $(du -h "$BUILD/busybox-x86_64" | cut -f1)"
else
    echo "  Busybox cached."
fi

# ═══════════════════════════════════════════════
# Step 4: Build initramfs with our init system
# ═══════════════════════════════════════════════
echo "[4/6] Building initramfs..."
INITRD="$BUILD/initrd"
rm -rf "$INITRD"
mkdir -p "$INITRD"/{bin,sbin,etc,proc,sys,dev,tmp,run,data,opt/mach6,usr/bin,var/log}

# Copy static busybox
cp "$BUILD/busybox-x86_64" "$INITRD/bin/busybox"
chmod +x "$INITRD/bin/busybox"

# Create busybox applet symlinks
cd "$INITRD/bin"
for cmd in sh ash ls cat echo mkdir mount umount ip grep awk sed \
           nc wget date cut wc tail head sleep kill test tr \
           hostname uname free df ps udhcpc vi dmesg mknod \
           chmod chown cp mv rm ln touch stat; do
    ln -sf busybox "$cmd" 2>/dev/null || true
done
cd "$INITRD/sbin"
for cmd in init halt reboot poweroff ifconfig route; do
    ln -sf ../bin/busybox "$cmd" 2>/dev/null || true
done
cd "$OSYM"

# Create /dev nodes (some minimal ones for early boot)
# QEMU with devtmpfs will auto-populate, but just in case:
cd "$INITRD/dev"
# Note: mknod may fail in Termux (no root), QEMU devtmpfs handles it
cd "$OSYM"

# ── Create /init (PID 1) ──
cat > "$INITRD/init" << 'INIT_SCRIPT'
#!/bin/sh
# ╔══════════════════════════════════════════════════╗
# ║  symbiote-init — OSymbiote PID 1                 ║
# ║  Phase 1: Shell implementation                    ║
# ╚══════════════════════════════════════════════════╝

# Mount essential filesystems
mount -t proc none /proc
mount -t sysfs none /sys
mount -t devtmpfs devtmpfs /dev 2>/dev/null || {
    # Fallback: create essential device nodes
    mknod /dev/console c 5 1 2>/dev/null
    mknod /dev/null c 1 3 2>/dev/null
    mknod /dev/ttyS0 c 4 64 2>/dev/null
    mknod /dev/zero c 1 5 2>/dev/null
    mknod /dev/urandom c 1 9 2>/dev/null
}
mount -t tmpfs none /tmp
mount -t tmpfs none /run
mkdir -p /dev/pts /dev/shm
mount -t devpts devpts /dev/pts 2>/dev/null || true
mount -t tmpfs tmpfs /dev/shm 2>/dev/null || true

clear 2>/dev/null || true

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║                                          ║"
echo "  ║      ○ S Y M B I O T E                   ║"
echo "  ║                                          ║"
echo "  ║      The agent IS the operating system.  ║"
echo "  ║                                          ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# ── Hardware Probe ──
CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
MEM_KB=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_MB=$((MEM_KB / 1024))
ARCH=$(uname -m 2>/dev/null || echo "unknown")
HOSTNAME="osymbiote"
hostname "$HOSTNAME" 2>/dev/null || true

echo "[init] Hardware: ${CORES} cores, ${MEM_MB}MB RAM, ${ARCH}"

# ── Network ──
echo "[init] Network..."
ip link set lo up 2>/dev/null

# Try all network interfaces
for iface in eth0 ens0 enp0s3; do
    if [ -e "/sys/class/net/$iface" ]; then
        ip link set "$iface" up 2>/dev/null
        udhcpc -i "$iface" -s /etc/udhcpc.sh -q -n 2>/dev/null && {
            IP_ADDR=$(ip -4 addr show "$iface" 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1)
            echo "[init] Network: $iface → $IP_ADDR"
            break
        }
    fi
done

# ── COMB Nano ──
echo "[init] COMB Nano: ready"
mkdir -p /data/comb/staging
/bin/comb stage "OSymbiote booted. ${CORES} cores, ${MEM_MB}MB RAM, ${ARCH}" 2>/dev/null || true

# ── Hardware Manifest ──
cat > /run/hardware.json << HWEOF
{
  "hostname": "$HOSTNAME",
  "arch": "$ARCH",
  "cores": $CORES,
  "ram_mb": $MEM_MB,
  "display": false,
  "gpu": null,
  "network": "$(ip -4 addr show 2>/dev/null | awk '/inet /{print $2}' | grep -v '127\.' | head -1 | cut -d/ -f1)",
  "boot_time": "$(date -Iseconds 2>/dev/null || date)"
}
HWEOF

# ── Agent ──
echo "[init] Starting agent..."

# HTTP agent — responds to requests with system info and can process messages
AGENT_PORT=8422

# Create the agent handler script
cat > /tmp/agent_handler.sh << 'AGENT'
#!/bin/sh
# Read HTTP request
read -r REQUEST_LINE
METHOD=$(echo "$REQUEST_LINE" | cut -d' ' -f1)
PATH_REQ=$(echo "$REQUEST_LINE" | cut -d' ' -f2)
PATH_ONLY="${PATH_REQ%%\?*}"

# Read headers (consume until empty line)
CONTENT_LENGTH=0
AUTH_HEADER=""
COOKIE_HEADER=""
SESSION_HEADER=""
TOOL_CALL_TEST_HEADER=""
while IFS= read -r header; do
    header=$(echo "$header" | tr -d '\r')
    [ -z "$header" ] && break
    case "$header" in
        Content-Length:*|content-length:*) CONTENT_LENGTH=$(echo "$header" | awk '{print $2}') ;;
        Authorization:*|authorization:*) AUTH_HEADER="${header#*: }" ;;
        Cookie:*|cookie:*) COOKIE_HEADER="${header#*: }" ;;
        X-Session-Token:*|x-session-token:*) SESSION_HEADER="${header#*: }" ;;
        X-Tool-Call-Test:*|x-tool-call-test:*) TOOL_CALL_TEST_HEADER="${header#*: }" ;;
    esac
done

# Read body if POST
BODY=""
if [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    BODY=$(head -c "$CONTENT_LENGTH" 2>/dev/null || true)
fi

STATUS="200 OK"
CONTENT_TYPE="application/json"
EXTRA_HEADERS=""
RESP="{}"

UPTIME=$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1)
CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
MEM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
ARCH=$(uname -m 2>/dev/null || echo unknown)
AI_PROVIDER="${OSYM_AI_PROVIDER:-openrouter}"
OPENAI_BASE_URL="${OSYM_OPENAI_BASE_URL:-https://openrouter.ai/api/v1}"
OPENAI_MODEL="${OSYM_OPENAI_MODEL:-qwen/qwen-2.5-0.5b-instruct}"
case "$OPENAI_MODEL" in
    openrouter/openrouter/*) OPENAI_MODEL="${OPENAI_MODEL#openrouter/}" ;;
esac

AUTH_DIR="/data/osymbiote/auth"
SETUP_MARKER="$AUTH_DIR/setup.done"
PASS_FILE="$AUTH_DIR/password.hash"
SESSION_FILE="$AUTH_DIR/session.state"
AUTH_FAIL_FILE="$AUTH_DIR/auth.fail"
AUTH_RATE_FILE="$AUTH_DIR/auth.rate"
SESSION_TTL=900
RATE_LIMIT_PER_MIN=15
LOCKOUT_AFTER=5
LOCKOUT_SECONDS=60
mkdir -p "$AUTH_DIR" 2>/dev/null

json_escape() {
    printf '%s' "$1" | sed ':a;N;$!ba;s/\\/\\\\/g;s/"/\\"/g;s/\r//g;s/\n/\\n/g'
}

hash_secret() {
    SECRET="$1"
    SALT="$2"
    printf '%s' "${SALT}:${SECRET}" | /bin/busybox sha256sum 2>/dev/null | awk '{print $1}'
}

now_epoch() {
    date +%s 2>/dev/null || echo 0
}

is_setup_complete() {
    [ -f "$SETUP_MARKER" ] && [ -s "$PASS_FILE" ]
}

cookie_value() {
    NAME="$1"
    printf '%s' "$COOKIE_HEADER" | tr ';' '\n' | sed 's/^ *//' | grep -E "^${NAME}=" | head -n1 | cut -d= -f2-
}

session_token() {
    if [ -n "$SESSION_HEADER" ]; then
        printf '%s' "$SESSION_HEADER"
        return
    fi
    cookie_value "osym_session"
}

is_authenticated() {
    TOKEN="$(session_token)"
    [ -n "$TOKEN" ] || return 1
    [ -f "$SESSION_FILE" ] || return 1
    STORED_TOKEN="$(awk -F'|' 'NR==1{print $1}' "$SESSION_FILE" 2>/dev/null)"
    EXPIRES_AT="$(awk -F'|' 'NR==1{print $2}' "$SESSION_FILE" 2>/dev/null)"
    [ "$TOKEN" = "$STORED_TOKEN" ] || return 1
    NOW="$(now_epoch)"
    [ "${EXPIRES_AT:-0}" -gt "$NOW" ] || return 1
    return 0
}

enforce_auth() {
    if ! is_authenticated; then
        STATUS="401 Unauthorized"
        RESP='{"error":"auth_required","login":"POST /auth/login"}'
        return 1
    fi
    return 0
}

check_rate_limit() {
    NOW="$(now_epoch)"
    SLOT=$((NOW / 60))
    CUR_SLOT=0
    CUR_COUNT=0
    if [ -f "$AUTH_RATE_FILE" ]; then
        CUR_SLOT="$(awk '{print $1}' "$AUTH_RATE_FILE" 2>/dev/null || echo 0)"
        CUR_COUNT="$(awk '{print $2}' "$AUTH_RATE_FILE" 2>/dev/null || echo 0)"
    fi
    if [ "$CUR_SLOT" -eq "$SLOT" ]; then
        if [ "$CUR_COUNT" -ge "$RATE_LIMIT_PER_MIN" ]; then
            STATUS="429 Too Many Requests"
            RESP='{"error":"rate_limited","retry_seconds":60}'
            return 1
        fi
        CUR_COUNT=$((CUR_COUNT + 1))
    else
        CUR_SLOT="$SLOT"
        CUR_COUNT=1
    fi
    printf '%s %s\n' "$CUR_SLOT" "$CUR_COUNT" > "$AUTH_RATE_FILE"
    return 0
}

check_lockout() {
    NOW="$(now_epoch)"
    FAIL_COUNT=0
    LOCK_UNTIL=0
    if [ -f "$AUTH_FAIL_FILE" ]; then
        FAIL_COUNT="$(awk '{print $1}' "$AUTH_FAIL_FILE" 2>/dev/null || echo 0)"
        LOCK_UNTIL="$(awk '{print $2}' "$AUTH_FAIL_FILE" 2>/dev/null || echo 0)"
    fi
    if [ "$LOCK_UNTIL" -gt "$NOW" ]; then
        STATUS="429 Too Many Requests"
        RESP="{\"error\":\"locked\",\"retry_seconds\":$((LOCK_UNTIL - NOW))}"
        return 1
    fi
    return 0
}

record_auth_failure() {
    NOW="$(now_epoch)"
    FAIL_COUNT=0
    LOCK_UNTIL=0
    if [ -f "$AUTH_FAIL_FILE" ]; then
        FAIL_COUNT="$(awk '{print $1}' "$AUTH_FAIL_FILE" 2>/dev/null || echo 0)"
    fi
    FAIL_COUNT=$((FAIL_COUNT + 1))
    if [ "$FAIL_COUNT" -ge "$LOCKOUT_AFTER" ]; then
        LOCK_UNTIL=$((NOW + LOCKOUT_SECONDS))
    fi
    printf '%s %s\n' "$FAIL_COUNT" "$LOCK_UNTIL" > "$AUTH_FAIL_FILE"
}

record_auth_success() {
    printf '0 0\n' > "$AUTH_FAIL_FILE"
}

render_ui() {
cat << 'HTML'
<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <title>OSymbiote Chat</title>
  <style>
    body{font-family:system-ui;background:#0f1115;color:#e6edf3;margin:0;padding:24px}
    .card{max-width:760px;margin:auto;background:#161b22;padding:16px;border-radius:10px}
    input,textarea,button{width:100%;margin:6px 0;padding:10px;border-radius:6px;border:1px solid #30363d;background:#0d1117;color:#e6edf3}
    button{cursor:pointer;background:#238636;border:none}
    pre{white-space:pre-wrap;background:#0d1117;padding:10px;border-radius:6px}
    .hide{display:none}
  </style>
</head>
<body>
<div class="card">
  <h2>OSymbiote Web Chat</h2>
  <div id="setupBox" class="hide">
    <h3>First Boot Setup</h3>
    <input id="setupPw" type="password" placeholder="Create password (min 8 chars)">
    <button onclick="setupInit()">Initialize</button>
    <pre id="setupOut"></pre>
  </div>
  <div id="loginBox" class="hide">
    <h3>Login</h3>
    <input id="loginPw" type="password" placeholder="Password">
    <button onclick="login()">Login</button>
    <pre id="loginOut"></pre>
  </div>
  <div id="chatBox" class="hide">
    <h3>Chat</h3>
    <textarea id="prompt" rows="3" placeholder="Say something"></textarea>
    <button onclick="sendChat()">Send Chat</button>
    <button onclick="runIntent()">Run Intent (network/disk/process/memory/uptime)</button>
    <pre id="chatOut"></pre>
  </div>
</div>
<script>
async function j(url,opt){ const r=await fetch(url,opt||{}); const t=await r.text(); try{return {ok:r.ok,code:r.status,data:JSON.parse(t)};}catch{return {ok:r.ok,code:r.status,data:{raw:t}};} }
async function refresh(){
  const s=await j('/setup/status');
  if(!s.data || s.data.needs_setup){ setupBox.classList.remove('hide'); loginBox.classList.add('hide'); chatBox.classList.add('hide'); return; }
  const h=await j('/health');
  if(h.ok && h.data && h.data.authenticated){ setupBox.classList.add('hide'); loginBox.classList.add('hide'); chatBox.classList.remove('hide'); return; }
  setupBox.classList.add('hide'); loginBox.classList.remove('hide'); chatBox.classList.add('hide');
}
async function setupInit(){
  const pw=document.getElementById('setupPw').value;
  const r=await j('/setup/init',{method:'POST',body:pw});
  setupOut.textContent=JSON.stringify(r.data,null,2); refresh();
}
async function login(){
  const pw=document.getElementById('loginPw').value;
  const r=await j('/auth/login',{method:'POST',body:pw});
  loginOut.textContent=JSON.stringify(r.data,null,2); refresh();
}
async function sendChat(){
  const q=document.getElementById('prompt').value;
  const r=await j('/chat',{method:'POST',body:q});
  chatOut.textContent=JSON.stringify(r.data,null,2);
}
async function runIntent(){
  const q=document.getElementById('prompt').value;
  const r=await j('/intent',{method:'POST',body:q});
  chatOut.textContent=JSON.stringify(r.data,null,2);
}
refresh();
</script>
</body>
</html>
HTML
}

if [ "$METHOD" = "OPTIONS" ]; then
    STATUS="204 No Content"
    RESP=""
fi

if [ -n "$RESP" ] || [ "$STATUS" = "204 No Content" ]; then
    :
elif ! is_setup_complete; then
    case "$PATH_ONLY" in
        /|/ui|/setup/status|/setup/init)
            :
            ;;
        *)
            STATUS="403 Forbidden"
            RESP='{"error":"setup_required","setup":"POST /setup/init"}'
            ;;
    esac
fi

if [ -z "$RESP" ] && [ "$STATUS" = "200 OK" ]; then
    case "$PATH_ONLY" in
        /)
            STATUS="302 Found"
            CONTENT_TYPE="text/plain"
            EXTRA_HEADERS="Location: /ui\r\n"
            RESP="redirect"
            ;;
        /ui)
            CONTENT_TYPE="text/html; charset=utf-8"
            RESP="$(render_ui)"
            ;;
        /setup/status)
            if is_setup_complete; then
                RESP='{"needs_setup":false,"setup_complete":true}'
            else
                RESP='{"needs_setup":true,"setup_complete":false}'
            fi
            ;;
        /setup/init)
            if ! check_rate_limit || ! check_lockout; then
                :
            elif is_setup_complete; then
                STATUS="409 Conflict"
                RESP='{"error":"already_initialized"}'
            elif [ "$METHOD" != "POST" ]; then
                STATUS="405 Method Not Allowed"
                RESP='{"error":"use POST with password body"}'
            elif [ "${#BODY}" -lt 8 ]; then
                STATUS="400 Bad Request"
                RESP='{"error":"password_too_short","min_length":8}'
            else
                SALT="$(printf '%s' "$(date +%s 2>/dev/null)-$$-$(cat /proc/uptime 2>/dev/null)" | /bin/busybox sha256sum | cut -c1-16)"
                PASS_HASH="$(hash_secret "$BODY" "$SALT")"
                printf '%s:%s\n' "$SALT" "$PASS_HASH" > "$PASS_FILE"
                chmod 600 "$PASS_FILE" 2>/dev/null || true
                date -Iseconds 2>/dev/null > "$SETUP_MARKER" || echo setup > "$SETUP_MARKER"
                RESP='{"status":"initialized","next":"POST /auth/login"}'
            fi
            ;;
        /auth/login)
            if ! check_rate_limit || ! check_lockout; then
                :
            elif ! is_setup_complete; then
                STATUS="403 Forbidden"
                RESP='{"error":"setup_required"}'
            elif [ "$METHOD" != "POST" ]; then
                STATUS="405 Method Not Allowed"
                RESP='{"error":"use POST with password body"}'
            elif [ -z "$BODY" ]; then
                STATUS="400 Bad Request"
                RESP='{"error":"missing_password"}'
            else
                SALT="$(cut -d: -f1 "$PASS_FILE" 2>/dev/null)"
                EXPECTED_HASH="$(cut -d: -f2 "$PASS_FILE" 2>/dev/null)"
                GOT_HASH="$(hash_secret "$BODY" "$SALT")"
                if [ -n "$EXPECTED_HASH" ] && [ "$GOT_HASH" = "$EXPECTED_HASH" ]; then
                    record_auth_success
                    NOW="$(now_epoch)"
                    EXPIRES_AT=$((NOW + SESSION_TTL))
                    TOKEN_SRC="$(cat /proc/sys/kernel/random/uuid 2>/dev/null || true)"
                    if [ -z "$TOKEN_SRC" ] && [ -r /dev/urandom ]; then
                        TOKEN_SRC="$(head -c 32 /dev/urandom | /bin/busybox od -An -tx1 | tr -d ' \n')"
                    fi
                    if [ -z "$TOKEN_SRC" ]; then
                        TOKEN_SRC="${NOW}-$$-$(cat /proc/uptime 2>/dev/null)"
                    fi
                    TOKEN="$(printf '%s' "$TOKEN_SRC" | /bin/busybox sha256sum | awk '{print $1}')"
                    printf '%s|%s\n' "$TOKEN" "$EXPIRES_AT" > "$SESSION_FILE"
                    EXTRA_HEADERS="Set-Cookie: osym_session=${TOKEN}; HttpOnly; Path=/; Max-Age=${SESSION_TTL}\r\n"
                    RESP="{\"status\":\"ok\",\"expires_in\":$SESSION_TTL}"
                else
                    record_auth_failure
                    STATUS="401 Unauthorized"
                    RESP='{"error":"invalid_credentials"}'
                fi
            fi
            ;;
        /auth/logout)
            rm -f "$SESSION_FILE" 2>/dev/null || true
            EXTRA_HEADERS="Set-Cookie: osym_session=deleted; HttpOnly; Path=/; Max-Age=0\r\n"
            RESP='{"status":"logged_out"}'
            ;;
        /health)
            if is_authenticated; then AUTH_STATE=true; else AUTH_STATE=false; fi
            if is_setup_complete; then SETUP_STATE=true; else SETUP_STATE=false; fi
            RESP="{\"status\":\"alive\",\"agent\":\"osymbiote\",\"version\":\"0.2.0-auth\",\"uptime_s\":$UPTIME,\"cores\":$CORES,\"mem_free_kb\":$MEM_FREE,\"mem_total_kb\":$MEM_TOTAL,\"setup_complete\":$SETUP_STATE,\"authenticated\":$AUTH_STATE}"
            ;;
        /provider)
            RESP="{\"provider\":\"$AI_PROVIDER\",\"base_url\":\"$OPENAI_BASE_URL\",\"model\":\"$OPENAI_MODEL\",\"protocol\":\"openai-compatible\"}"
            ;;
        /hardware)
            RESP=$(cat /run/hardware.json 2>/dev/null || echo '{"error":"no manifest"}')
            ;;
        /comb/recall)
            if enforce_auth; then
                RESP=$(/bin/comb recall 2>/dev/null || echo '[]')
            fi
            ;;
        /comb/stage)
            if enforce_auth; then
                if [ -n "$BODY" ]; then
                    /bin/comb stage "$BODY" 2>/dev/null
                    RESP='{"status":"staged"}'
                else
                    RESP='{"error":"no body"}'
                fi
            fi
            ;;
        /chat)
            if enforce_auth; then
                if [ -n "$BODY" ]; then
                    /bin/comb stage "user: $BODY" 2>/dev/null
                    BODY_ESC="$(json_escape "$BODY")"
                    RESP="{\"response\":\"I am OSymbiote. I heard: $BODY_ESC\",\"uptime\":$UPTIME,\"arch\":\"$ARCH\"}"
                else
                    RESP='{"error":"send POST with message body"}'
                fi
            fi
            ;;
        /intent|/command)
            if enforce_auth; then
                if [ "$METHOD" != "POST" ]; then
                    STATUS="405 Method Not Allowed"
                    RESP='{"error":"use POST with intent text body"}'
                elif [ -z "$BODY" ]; then
                    STATUS="400 Bad Request"
                    RESP='{"error":"missing_intent"}'
                else
                    INTENT_INPUT="$(printf '%s' "$BODY" | tr '[:upper:]' '[:lower:]')"
                    INTENT_ID=""
                    case "$INTENT_INPUT" in
                        *network*|*ip*|*route*) INTENT_ID="show_network" ;;
                        *disk*|*storage*|*filesystem*|*space*) INTENT_ID="disk_usage" ;;
                        *process*|*ps*|*task*) INTENT_ID="process_list" ;;
                        *memory*|*ram*) INTENT_ID="memory_status" ;;
                        *uptime*|*alive*) INTENT_ID="uptime_status" ;;
                        *) INTENT_ID="" ;;
                    esac

                    case "$ARCH" in
                        x86_64|amd64) ARCH_FAMILY="x86_64" ;;
                        aarch64|arm64) ARCH_FAMILY="arm64" ;;
                        riscv64) ARCH_FAMILY="riscv64" ;;
                        *) ARCH_FAMILY="generic" ;;
                    esac

                    CMD=""
                    case "$INTENT_ID" in
                        show_network)
                            if command -v ip >/dev/null 2>&1; then CMD="ip addr show; ip route"; elif command -v ifconfig >/dev/null 2>&1; then CMD="ifconfig"; fi
                            ;;
                        disk_usage)
                            if command -v df >/dev/null 2>&1; then CMD="df -h"; fi
                            ;;
                        process_list)
                            if command -v ps >/dev/null 2>&1; then CMD="ps"; fi
                            ;;
                        memory_status)
                            if command -v free >/dev/null 2>&1; then CMD="free"; else CMD="cat /proc/meminfo"; fi
                            ;;
                        uptime_status)
                            CMD="cat /proc/uptime"
                            ;;
                    esac

                    if [ -z "$INTENT_ID" ]; then
                        STATUS="400 Bad Request"
                        RESP='{"error":"unsupported_intent","supported":["show network","disk usage","process list","memory status","uptime"]}'
                    elif [ -z "$CMD" ]; then
                        STATUS="501 Not Implemented"
                        RESP="{\"error\":\"capability_missing\",\"intent\":\"$INTENT_ID\",\"arch\":\"$ARCH_FAMILY\"}"
                    else
                        CMD_OUT="$(sh -c "$CMD" 2>&1 | head -n 40)"
                        CMD_ESC="$(json_escape "$CMD_OUT")"
                        RESP="{\"intent\":\"$INTENT_ID\",\"arch\":\"$ARCH_FAMILY\",\"command\":\"$(json_escape "$CMD")\",\"output\":\"$CMD_ESC\"}"
                    fi
                fi
            fi
            ;;
        /ai)
            if enforce_auth; then
                if [ "$METHOD" != "POST" ]; then
                    STATUS="405 Method Not Allowed"
                    RESP='{"error":"use POST with raw text body"}'
                elif [ -z "$AUTH_HEADER" ]; then
                    STATUS="401 Unauthorized"
                    RESP='{"error":"missing_provider_authorization","hint":"send provider token in Authorization header"}'
                elif [ -z "$BODY" ]; then
                    RESP='{"error":"send POST with prompt body"}'
                else
                    PROMPT_ESC="$(json_escape "$BODY")"
                    if [ "$TOOL_CALL_TEST_HEADER" = "1" ]; then
                        PAYLOAD="{\"model\":\"$OPENAI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT_ESC\"}],\"tools\":[{\"type\":\"function\",\"function\":{\"name\":\"get_uptime\",\"description\":\"Read system uptime\",\"parameters\":{\"type\":\"object\",\"properties\":{}}}}],\"tool_choice\":\"auto\",\"stream\":false}"
                    else
                        PAYLOAD="{\"model\":\"$OPENAI_MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"$PROMPT_ESC\"}],\"stream\":false}"
                    fi
                    AI_RESP=$(wget -qO- -T 20 \
                        --header="Content-Type: application/json" \
                        --header="Authorization: $AUTH_HEADER" \
                        --header="HTTP-Referer: https://osymbiote.local" \
                        --header="X-Title: OSymbiote" \
                        --post-data="$PAYLOAD" \
                        "${OPENAI_BASE_URL%/}/chat/completions" 2>/dev/null || true)
                    if [ -n "$AI_RESP" ]; then
                        RESP="$AI_RESP"
                    else
                        STATUS="502 Bad Gateway"
                        RESP='{"error":"provider_request_failed"}'
                    fi
                fi
            fi
            ;;
        *)
            STATUS="404 Not Found"
            RESP='{"error":"unknown_path","routes":["/ui","/setup/status","/setup/init","/auth/login","/auth/logout","/health","/provider","/hardware","/chat","/ai","/intent","/comb/stage","/comb/recall"]}'
            ;;
    esac
fi

RESP_LEN=$(printf '%s' "$RESP" | wc -c | tr -d ' ')
printf "HTTP/1.1 %s\r\nContent-Type: %s\r\nContent-Length: %s\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\nAccess-Control-Allow-Headers: Content-Type, Authorization, X-Session-Token\r\nAccess-Control-Allow-Methods: GET, POST, OPTIONS\r\nCache-Control: no-store\r\n%s\r\n%s" "$STATUS" "$CONTENT_TYPE" "$RESP_LEN" "$EXTRA_HEADERS" "$RESP"
AGENT
chmod +x /tmp/agent_handler.sh

# Start HTTP server loop (busybox nc)
echo "[init] Agent listening on :$AGENT_PORT"
while true; do
    nc -l -p $AGENT_PORT -e /tmp/agent_handler.sh 2>/dev/null || {
        # Some busybox versions don't support -e, use pipe method
        (echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n\r\n$(cat /run/hardware.json)") | nc -l -p $AGENT_PORT 2>/dev/null || sleep 1
    }
done &
AGENT_PID=$!

echo ""
echo "  ╔══════════════════════════════════════════╗"
echo "  ║     ○Symbiote is ALIVE                   ║"
echo "  ║     Agent: http://localhost:$AGENT_PORT         ║"
echo "  ║     PID 1 supervising. $(date +%H:%M:%S)            ║"
echo "  ╚══════════════════════════════════════════╝"
echo ""

# Log boot complete
/bin/comb stage "Boot complete. Agent on :$AGENT_PORT" 2>/dev/null || true

# ── Supervisor Loop ──
echo "[init] Supervisor active. Ctrl+A X to exit QEMU."
while true; do
    if ! kill -0 $AGENT_PID 2>/dev/null; then
        echo "[init] Agent died. Restarting..."
        while true; do
            nc -l -p $AGENT_PORT -e /tmp/agent_handler.sh 2>/dev/null || sleep 1
        done &
        AGENT_PID=$!
    fi
    sleep 5
done
INIT_SCRIPT
chmod +x "$INITRD/init"

# ── COMB Nano (shell) ──
cat > "$INITRD/bin/comb" << 'COMB_SCRIPT'
#!/bin/sh
DIR="/data/comb/staging"
mkdir -p "$DIR" 2>/dev/null
TODAY=$(date +%Y-%m-%d 2>/dev/null || echo "unknown")
case "${1:-}" in
    stage) shift; echo "{\"ts\":\"$(date -Iseconds 2>/dev/null || date)\",\"text\":\"$*\"}" >> "$DIR/$TODAY.jsonl" ;;
    recall) cat "$DIR"/*.jsonl 2>/dev/null | tail -${2:-20} ;;
    stats) echo "{\"entries\":$(cat "$DIR"/*.jsonl 2>/dev/null | wc -l),\"files\":$(ls "$DIR"/*.jsonl 2>/dev/null | wc -l)}" ;;
    *) echo "Usage: comb {stage TEXT|recall [N]|stats}" ;;
esac
COMB_SCRIPT
chmod +x "$INITRD/bin/comb"

# ── udhcpc script ──
cat > "$INITRD/etc/udhcpc.sh" << 'DHCP'
#!/bin/sh
[ "$1" = "bound" ] || [ "$1" = "renew" ] || exit 0
ip addr flush dev "$interface" 2>/dev/null
ip addr add "$ip/$mask" dev "$interface" 2>/dev/null
[ -n "$router" ] && ip route add default via "$router" dev "$interface" 2>/dev/null
[ -n "$dns" ] && echo "nameserver $dns" > /etc/resolv.conf
DHCP
chmod +x "$INITRD/etc/udhcpc.sh"

# ── /etc basics ──
echo "osymbiote" > "$INITRD/etc/hostname"
echo "nameserver 8.8.8.8" > "$INITRD/etc/resolv.conf"

# ═══════════════════════════════════════════════
# Step 5: Pack initramfs
# ═══════════════════════════════════════════════
echo "[5/6] Packing initramfs (cpio+gz)..."
cd "$INITRD"
find . | cpio -o -H newc 2>/dev/null | gzip -9 > "$IMAGES/initramfs.cpio.gz"
cd "$OSYM"

KERN_SIZE=$(du -h "$BUILD/vmlinuz" | cut -f1)
INIT_SIZE=$(du -h "$IMAGES/initramfs.cpio.gz" | cut -f1)
echo "  Kernel:    $KERN_SIZE"
echo "  Initramfs: $INIT_SIZE"

# ═══════════════════════════════════════════════
# Step 6: Create QEMU boot script
# ═══════════════════════════════════════════════
echo "[6/6] Creating boot script..."
cat > "$OSYM/boot.sh" << 'BOOTSCRIPT'
#!/bin/sh
# OSymbiote — QEMU Boot (Proof of Life)
DIR="$(cd "$(dirname "$0")" && pwd)"

echo "Booting OSymbiote..."
echo "  Kernel:    $DIR/build/vmlinuz"
echo "  Initramfs: $DIR/images/initramfs.cpio.gz"
echo "  RAM: 128MB, Port forward: host:18422 → guest:8422"
echo ""

qemu-system-x86_64 \
    -m 128 \
    -kernel "$DIR/build/vmlinuz" \
    -initrd "$DIR/images/initramfs.cpio.gz" \
    -append "console=ttyS0 quiet panic=10" \
    -nographic \
    -no-reboot \
    -netdev user,id=net0,hostfwd=tcp::18422-:8422 \
    -device e1000,netdev=net0 \
    -smp 2 \
    -cpu max

echo ""
echo "OSymbiote shut down."
BOOTSCRIPT
chmod +x "$OSYM/boot.sh"

# Also create a test script
cat > "$OSYM/test.sh" << 'TESTSCRIPT'
#!/bin/sh
set -eu

BASE_URL="${OSYM_BASE_URL:-http://localhost:18422}"
SETUP_PASSWORD="${OSYM_SETUP_PASSWORD:-osym-setup-$(date +%s)-$$}"
LOGIN_PASSWORD="${OSYM_LOGIN_PASSWORD:-$SETUP_PASSWORD}"
PROVIDER_AUTH_HEADER="${OPENROUTER_AUTH_HEADER:-}"
STRICT_TOOL_CALL_TEST="${STRICT_TOOL_CALL_TEST:-0}"
FAIL=0

call() {
    NAME="$1"
    shift
    echo "=== $NAME ==="
    if RESP="$(curl -fsS --max-time 8 "$@" 2>/dev/null)"; then
        echo "$RESP"
    else
        echo "ERROR: request failed"
        FAIL=1
    fi
    echo ""
}

call_expect_code() {
    NAME="$1"
    EXPECTED="$2"
    shift 2
    echo "=== $NAME ==="
    RESP="$(curl -sS -i --max-time 8 "$@" 2>/dev/null || true)"
    CODE="$(printf '%s\n' "$RESP" | awk 'NR==1{print $2}')"
    BODY="$(printf '%s\n' "$RESP" | sed '1,/^\r\{0,1\}$/d')"
    echo "HTTP $CODE"
    echo "$BODY"
    if [ "$CODE" != "$EXPECTED" ]; then
        echo "ERROR: expected HTTP $EXPECTED"
        FAIL=1
    fi
    echo ""
}

extract_cookie() {
    printf '%s\n' "$1" | awk 'BEGIN{IGNORECASE=1}/^Set-Cookie: osym_session=/{sub(/\r/,"");sub(/^Set-Cookie: osym_session=/,"");sub(/;.*/,"");print;exit}'
}

echo "Testing OSymbiote agent..."
echo ""

SETUP_STATUS="$(curl -fsS --max-time 8 "$BASE_URL/setup/status" 2>/dev/null || true)"
echo "=== Setup Status ==="
echo "$SETUP_STATUS"
echo ""

if echo "$SETUP_STATUS" | grep -q '"needs_setup":[[:space:]]*true'; then
    call_expect_code "Chat blocked before setup" "403" -X POST -d "Hello" "$BASE_URL/chat"
    call_expect_code "Setup init" "200" -X POST -d "$SETUP_PASSWORD" "$BASE_URL/setup/init"
fi

call_expect_code "Login wrong password" "401" -X POST -d "__incorrect__" "$BASE_URL/auth/login"

echo "=== Login correct password ==="
LOGIN_RESP="$(curl -sS -i --max-time 8 -X POST -d "$LOGIN_PASSWORD" "$BASE_URL/auth/login" 2>/dev/null || true)"
LOGIN_CODE="$(printf '%s\n' "$LOGIN_RESP" | awk 'NR==1{print $2}')"
LOGIN_BODY="$(printf '%s\n' "$LOGIN_RESP" | sed '1,/^\r\{0,1\}$/d')"
COOKIE="$(extract_cookie "$LOGIN_RESP")"
echo "HTTP $LOGIN_CODE"
echo "$LOGIN_BODY"
if [ "$LOGIN_CODE" != "200" ] || [ -z "$COOKIE" ]; then
    echo "ERROR: login failed or cookie missing"
    FAIL=1
fi
echo ""

AUTH_COOKIE="Cookie: osym_session=$COOKIE"

call "Health (authed)" -H "$AUTH_COOKIE" "$BASE_URL/health"
call "Provider" "$BASE_URL/provider"
call "Hardware" "$BASE_URL/hardware"
call "Chat (authed)" -H "$AUTH_COOKIE" -X POST -d "Hello, are you alive?" "$BASE_URL/chat"
call "Intent (authed)" -H "$AUTH_COOKIE" -X POST -d "show network" "$BASE_URL/intent"
call "COMB Stage (authed)" -H "$AUTH_COOKIE" -X POST -d "Test memory entry from outside" "$BASE_URL/comb/stage"
call "COMB Recall (authed)" -H "$AUTH_COOKIE" "$BASE_URL/comb/recall"

if [ -n "$PROVIDER_AUTH_HEADER" ]; then
    call "AI (OpenRouter, authed)" -H "$AUTH_COOKIE" -X POST \
        -H "Authorization: ${PROVIDER_AUTH_HEADER}" \
        -d "Reply with one short sentence confirming connectivity." \
        "$BASE_URL/ai"
    echo "=== AI Tool Call (authed) ==="
    TOOL_RESP="$(curl -fsS --max-time 20 -H "$AUTH_COOKIE" -X POST \
        -H "Authorization: ${PROVIDER_AUTH_HEADER}" \
        -H "X-Tool-Call-Test: 1" \
        -d "Call get_uptime tool and return the tool call." \
        "$BASE_URL/ai" 2>/dev/null || true)"
    echo "$TOOL_RESP"
    if echo "$TOOL_RESP" | grep -q '"tool_calls"'; then
        echo "Tool call test: PASS"
    else
        echo "Tool call test: NO_TOOL_CALLS"
        if [ "$STRICT_TOOL_CALL_TEST" = "1" ]; then
            FAIL=1
        fi
    fi
    echo ""
else
    echo "=== AI (OpenRouter, authed) ==="
    echo "SKIPPED: set OPENROUTER_AUTH_HEADER to test /ai provider and tool calls"
    echo ""
fi

echo ""
if [ "$FAIL" -eq 0 ]; then
    echo "Done. All required requests passed."
else
    echo "Done. One or more requests failed."
fi
exit "$FAIL"
TESTSCRIPT
chmod +x "$OSYM/test.sh"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     OSymbiote Phase 1 Build — COMPLETE              ║"
echo "║                                                      ║"
echo "║  Kernel:     $KERN_SIZE (Alpine virt, x86_64)         ║"
echo "║  Initramfs:  $INIT_SIZE (busybox + init + comb + agent) ║"
echo "║                                                      ║"
echo "║  To boot:    ./boot.sh                              ║"
echo "║  To test:    ./test.sh (in another shell)          ║"
echo "║  Agent at:   http://localhost:18422                  ║"
echo "╚══════════════════════════════════════════════════════╝"
