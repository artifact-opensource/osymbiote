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

for t in qemu-system-x86_64 wget cpio gzip; do
    require_tool "$t"
done

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

# Read headers (consume until empty line)
CONTENT_LENGTH=0
while IFS= read -r header; do
    header=$(echo "$header" | tr -d '\r')
    [ -z "$header" ] && break
    case "$header" in
        Content-Length:*|content-length:*) CONTENT_LENGTH=$(echo "$header" | awk '{print $2}') ;;
    esac
done

# Read body if POST
BODY=""
if [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
    BODY=$(head -c "$CONTENT_LENGTH" 2>/dev/null || true)
fi

# Route
UPTIME=$(cat /proc/uptime 2>/dev/null | cut -d' ' -f1)
CORES=$(grep -c ^processor /proc/cpuinfo 2>/dev/null || echo 1)
MEM_FREE=$(awk '/MemAvailable/{print $2}' /proc/meminfo 2>/dev/null || echo 0)
MEM_TOTAL=$(awk '/MemTotal/{print $2}' /proc/meminfo 2>/dev/null || echo 0)

case "$PATH_REQ" in
    /health|/)
        RESP="{\"status\":\"alive\",\"agent\":\"osymbiote\",\"version\":\"0.1.0-pol\",\"uptime_s\":$UPTIME,\"cores\":$CORES,\"mem_free_kb\":$MEM_FREE,\"mem_total_kb\":$MEM_TOTAL}"
        ;;
    /hardware)
        RESP=$(cat /run/hardware.json 2>/dev/null || echo '{"error":"no manifest"}')
        ;;
    /comb/recall)
        RESP=$(/bin/comb recall 2>/dev/null || echo '[]')
        ;;
    /comb/stage)
        if [ -n "$BODY" ]; then
            /bin/comb stage "$BODY" 2>/dev/null
            RESP='{"status":"staged"}'
        else
            RESP='{"error":"no body"}'
        fi
        ;;
    /chat)
        # The proof of life — agent processes a message
        if [ -n "$BODY" ]; then
            /bin/comb stage "user: $BODY" 2>/dev/null
            RESP="{\"response\":\"I am OSymbiote. I booted from nothing — a shell init, busybox, and a dream. Running on $(uname -m) with ${CORES} cores and $((MEM_TOTAL/1024))MB RAM. Uptime: ${UPTIME}s. What do you need?\",\"uptime\":$UPTIME}"
        else
            RESP='{"error":"send POST with message body"}'
        fi
        ;;
    *)
        RESP='{"error":"unknown path","routes":["/","/health","/hardware","/comb/recall","/comb/stage","/chat"]}'
        ;;
esac

# Send response
RESP_LEN=$(echo -n "$RESP" | wc -c)
printf "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\nAccess-Control-Allow-Origin: *\r\n\r\n%s" "$RESP_LEN" "$RESP"
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
echo "Testing OSymbiote agent..."
echo ""

echo "=== Health ==="
curl -s http://localhost:18422/health 2>/dev/null && echo ""

echo ""
echo "=== Hardware ==="
curl -s http://localhost:18422/hardware 2>/dev/null && echo ""

echo ""
echo "=== Chat ==="
curl -s -X POST -d "Hello, are you alive?" http://localhost:18422/chat 2>/dev/null && echo ""

echo ""
echo "=== COMB Stage ==="
curl -s -X POST -d "Test memory entry from outside" http://localhost:18422/comb/stage 2>/dev/null && echo ""

echo ""
echo "=== COMB Recall ==="
curl -s http://localhost:18422/comb/recall 2>/dev/null && echo ""

echo ""
echo "Done."
TESTSCRIPT
chmod +x "$OSYM/test.sh"

echo ""
echo "╔══════════════════════════════════════════════════════╗"
echo "║     OSymbiote Phase 1 Build — COMPLETE              ║"
echo "║                                                      ║"
echo "║  Kernel:     $KERN_SIZE (Alpine virt, x86_64)"
echo "║  Initramfs:  $INIT_SIZE (busybox + init + comb + agent)"
echo "║                                                      ║"
echo "║  To boot:    ~/osymbiote/boot.sh                     ║"
echo "║  To test:    ~/osymbiote/test.sh (in another shell)  ║"
echo "║  Agent at:   http://localhost:18422                  ║"
echo "╚══════════════════════════════════════════════════════╝"
