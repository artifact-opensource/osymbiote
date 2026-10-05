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
    for p in qemu-system-x86-64 wget curl coreutils cpio gzip squashfs-tools; do
        pkg install -y "$p" 2>/dev/null || echo "  $p already installed or unavailable"
    done
else
    echo "  Non-Termux host detected; skipping pkg install."
fi

for t in wget cpio gzip unsquashfs; do
    require_tool "$t"
done
command -v qemu-system-x86_64 >/dev/null 2>&1 || echo "  WARN: qemu-system-x86_64 not found (build will still complete)."

# ═══════════════════════════════════════════════
# Step 2: Get x86_64 kernel (Alpine netboot)
# ═══════════════════════════════════════════════
echo "[2/6] Getting x86_64 kernel..."
PAIR_TMP="$(mktemp -d)"
BB_TMPDIR=""
cleanup_build_tmp() {
    [ -z "$PAIR_TMP" ] || rm -rf "$PAIR_TMP"
    [ -z "$BB_TMPDIR" ] || rm -rf "$BB_TMPDIR"
}
trap cleanup_build_tmp EXIT
download_file "$PAIR_TMP/vmlinuz" \
    "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/netboot/vmlinuz-virt" \
    "https://mirrors.edge.kernel.org/alpine/v3.21/releases/x86_64/netboot/vmlinuz-virt" || {
    echo "  ERROR: Cannot download kernel. Check internet."
    exit 1
}
download_file "$PAIR_TMP/initramfs-virt" \
    "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/netboot/initramfs-virt" || {
    echo "  ERROR: Cannot download Alpine initramfs (NIC modules)."
    exit 1
}
download_file "$PAIR_TMP/modloop-virt" \
    "https://dl-cdn.alpinelinux.org/alpine/v3.21/releases/x86_64/netboot/modloop-virt" || {
    echo "  ERROR: Cannot download matching Alpine module loop."
    exit 1
}
gzip -t "$PAIR_TMP/initramfs-virt" || {
    echo "  ERROR: Downloaded Alpine initramfs is invalid."
    exit 1
}
unsquashfs -s "$PAIR_TMP/modloop-virt" >/dev/null 2>&1 || {
    echo "  ERROR: Downloaded Alpine module loop is invalid."
    exit 1
}
mv "$PAIR_TMP/vmlinuz" "$BUILD/vmlinuz"
mv "$PAIR_TMP/initramfs-virt" "$BUILD/initramfs-virt"
mv "$PAIR_TMP/modloop-virt" "$BUILD/modloop-virt"
echo "  Kernel and module archives refreshed together: $(du -h "$BUILD/vmlinuz" | cut -f1)"

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
        BB_TMPDIR="$(mktemp -d)"
        APKINDEX_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/x86_64/APKINDEX.tar.gz"

        wget -q -O "$BB_TMPDIR/APKINDEX.tar.gz" "$APKINDEX_URL" 2>/dev/null || {
            echo "  ERROR: Cannot fetch Alpine APK index."
            exit 1
        }

        tar -xzf "$BB_TMPDIR/APKINDEX.tar.gz" -C "$BB_TMPDIR" APKINDEX
        BB_VER=$(
            awk -v RS='' '
                $0 ~ /\nP:busybox-static\n/ {
                    if (match($0, /\nV:([^\n]+)/, m)) {
                        print m[1]
                        exit
                    }
                }
            ' "$BB_TMPDIR/APKINDEX"
        )

        [ -n "${BB_VER:-}" ] || {
            echo "  ERROR: Could not resolve busybox-static version from Alpine index."
            exit 1
        }

        APK_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21/main/x86_64/busybox-static-${BB_VER}.apk"
        wget -q -O "$BB_TMPDIR/busybox.apk" "$APK_URL" 2>/dev/null || {
            echo "  ERROR: Cannot download Alpine busybox-static package."
            exit 1
        }

        if tar -tf "$BB_TMPDIR/busybox.apk" | grep -q '^bin/busybox.static$'; then
            tar -xzf "$BB_TMPDIR/busybox.apk" -C "$BB_TMPDIR" bin/busybox.static
            cp "$BB_TMPDIR/bin/busybox.static" "$BUILD/busybox-x86_64"
        elif tar -tf "$BB_TMPDIR/busybox.apk" | grep -q '^bin/busybox$'; then
            tar -xzf "$BB_TMPDIR/busybox.apk" -C "$BB_TMPDIR" bin/busybox
            cp "$BB_TMPDIR/bin/busybox" "$BUILD/busybox-x86_64"
        else
            echo "  ERROR: busybox binary not found in Alpine package."
            exit 1
        fi
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
           chmod chown cp mv rm ln touch stat sha256sum od sort uniq tee \
           clear find xargs printf stty setsid cttyhack ping top du env \
           basename dirname id whoami uptime which less more sync pidof \
           killall tcpsvd timeout egrep fgrep seq expr rev tac nslookup netstat \
           traceroute ifconfig route reboot poweroff halt; do
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

# ── NIC drivers (modules in the freshly downloaded Alpine virt kernel pair) ──
gzip -t "$BUILD/initramfs-virt" || {
    rm -f "$BUILD/vmlinuz" "$BUILD/initramfs-virt" "$BUILD/modloop-virt"
    echo "  ERROR: Alpine initramfs is corrupt."
    exit 1
}
MODTMP="$(mktemp -d)"
(mkdir -p "$MODTMP/lib/modules")
if ! (cd "$MODTMP" && zcat "$BUILD/initramfs-virt" | cpio -id --quiet \
    'lib/modules/*/kernel/drivers/net/ethernet/intel/e1000/*' \
    'lib/modules/*/kernel/drivers/net/virtio_net.ko*' \
    'lib/modules/*/kernel/drivers/net/net_failover.ko*' \
    'lib/modules/*/kernel/net/core/failover.ko*' \
    'lib/modules/*/kernel/net/packet/af_packet.ko*' 2>/dev/null); then
    rm -rf "$MODTMP" "$INITRD/lib/modules"
    rm -f "$BUILD/vmlinuz" "$BUILD/initramfs-virt" "$BUILD/modloop-virt"
    echo "  ERROR: Cannot extract NIC modules from Alpine initramfs."
    exit 1
fi
KERNEL_RELEASE="$(find "$MODTMP/lib/modules" -mindepth 1 -maxdepth 1 -type d -name '*-virt' | head -n 1 | sed 's#.*/##')"
if [ -z "$KERNEL_RELEASE" ] || ! unsquashfs -ll "$BUILD/modloop-virt" | grep "modules/$KERNEL_RELEASE/" >/dev/null; then
    rm -rf "$MODTMP" "$INITRD/lib/modules"
    rm -f "$BUILD/vmlinuz" "$BUILD/initramfs-virt" "$BUILD/modloop-virt"
    echo "  ERROR: Alpine module loop does not match kernel release ${KERNEL_RELEASE:-unknown}."
    exit 1
fi
if ! unsquashfs -f -d "$MODTMP/modloop" "$BUILD/modloop-virt" \
    "modules/$KERNEL_RELEASE/kernel/fs/9p/9p.ko" \
    "modules/$KERNEL_RELEASE/kernel/fs/netfs/netfs.ko" \
    "modules/$KERNEL_RELEASE/kernel/net/9p/9pnet.ko" \
    "modules/$KERNEL_RELEASE/kernel/net/9p/9pnet_virtio.ko" >/dev/null 2>&1; then
    rm -rf "$MODTMP" "$INITRD/lib/modules"
    rm -f "$BUILD/vmlinuz" "$BUILD/initramfs-virt" "$BUILD/modloop-virt"
    echo "  ERROR: Cannot extract 9p persistence modules."
    exit 1
fi
find "$MODTMP/modloop/modules/$KERNEL_RELEASE/kernel" -type f -name '*.ko*' -exec cp {} "$MODTMP/lib/modules/" \;
mkdir -p "$INITRD/lib/modules"
find "$MODTMP/lib/modules" -type f -name '*.ko*' -exec cp {} "$INITRD/lib/modules/" \;
rm -rf "$MODTMP"
if ! find "$INITRD/lib/modules" -maxdepth 1 -type f -name 'e1000.ko*' | grep -q .; then
    rm -f "$BUILD/vmlinuz" "$BUILD/initramfs-virt" "$BUILD/modloop-virt"
    echo "  ERROR: Required e1000 NIC module missing from Alpine initramfs."
    exit 1
fi
echo "  NIC modules: $(ls "$INITRD/lib/modules" | tr '\n' ' ')"

# ── Install OS overlay (init, shell, agent, UI, libs) ──
OVERLAY="$SCRIPT_DIR/overlay"
mkdir -p "$INITRD/usr/lib/osym" "$INITRD/usr/share/osym" "$INITRD/root" "$INITRD/etc/osymbiote"
install -m 0755 "$OVERLAY/init" "$INITRD/init"
install -m 0755 "$OVERLAY/osh" "$INITRD/bin/osh"
install -m 0755 "$OVERLAY/comb" "$INITRD/bin/comb"
install -m 0755 "$OVERLAY/udhcpc.sh" "$INITRD/etc/udhcpc.sh"
install -m 0755 "$OVERLAY/agent_handler.sh" "$INITRD/usr/lib/osym/agent_handler.sh"
install -m 0644 "$OVERLAY/lib.sh" "$INITRD/usr/lib/osym/lib.sh"
install -m 0644 "$OVERLAY/ui.html" "$INITRD/usr/share/osym/ui.html"
install -m 0644 "$OVERLAY/osymbiote.env.example" "$INITRD/etc/osymbiote/.env.example"
install -m 0644 "$OVERLAY/system.conf.example" "$INITRD/etc/osymbiote/system.conf.example"
install -m 0644 "$OSYM/VERSION" "$INITRD/etc/osymbiote/version"

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
#!/bin/bash
# OSymbiote — QEMU Boot (Proof of Life)
DIR="$(cd "$(dirname "$0")" && pwd)"
DATA_DIR="${OSYM_DATA_DIR:-$DIR/data}"
PERSIST="${OSYM_PERSIST:-1}"

echo "Booting OSymbiote..."
echo "  Kernel:    $DIR/build/vmlinuz"
echo "  Initramfs: $DIR/images/initramfs.cpio.gz"
echo "  RAM: 128MB, Port forward: host:8422 → guest:8422"
if [ "$PERSIST" = "1" ]; then
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    echo "  Data: $DATA_DIR (persistent)"
elif [ "$PERSIST" != "0" ]; then
    echo "Invalid OSYM_PERSIST value: use 1 or 0" >&2
    exit 1
fi
echo ""

QEMU_ARGS=(
    -m 128 \
    -kernel "$DIR/build/vmlinuz" \
    -initrd "$DIR/images/initramfs.cpio.gz" \
    -append "console=ttyS0 quiet panic=10" \
    -nographic \
    -no-reboot \
    -netdev user,id=net0,hostfwd=tcp::8422-:8422 \
    -device e1000,netdev=net0 \
    -smp 2 \
    -cpu max
)
if [ "$PERSIST" = "1" ]; then
    QEMU_ARGS+=( -virtfs "local,path=$DATA_DIR,mount_tag=osymdata,security_model=mapped-xattr,id=osymdata" )
fi
qemu-system-x86_64 "${QEMU_ARGS[@]}"

echo ""
echo "OSymbiote shut down."
BOOTSCRIPT
chmod +x "$OSYM/boot.sh"

# Also create a test script
cat > "$OSYM/test.sh" << 'TESTSCRIPT'
#!/bin/sh
set -eu

BASE_URL="${OSYM_BASE_URL:-http://localhost:8422}"
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
call "Data persistence status" "$BASE_URL/health"
call "System config (authed)" -H "$AUTH_COOKIE" "$BASE_URL/system/config"
call_expect_code "File write requires confirmation" "428" -H "$AUTH_COOKIE" -X POST "$BASE_URL/fs/write"
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
echo "║  Agent at:   http://localhost:8422                  ║"
echo "╚══════════════════════════════════════════════════════╝"
