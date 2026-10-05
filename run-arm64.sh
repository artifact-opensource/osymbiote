#!/bin/bash
# Run the ARM64 QEMU virt reference image.

set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
KERNEL="$DIR/build/arm64/vmlinuz"
INITRD="$DIR/images/arm64-initramfs.cpio.gz"
QEMU_BIN="${OSYM_QEMU:-qemu-system-aarch64}"
PORT="${OSYM_PORT:-8422}"
RAM="${OSYM_RAM:-512}"
CPUS="${OSYM_CPUS:-2}"
DATA_DIR="${OSYM_DATA_DIR:-$DIR/data}"
PERSIST="${OSYM_PERSIST:-1}"

if [ ! -f "$KERNEL" ] || [ ! -f "$INITRD" ]; then
    echo "Missing ARM64 kernel or initramfs. Run: bash scripts/build-arm64.sh" >&2
    exit 1
fi
if ! command -v "$QEMU_BIN" >/dev/null 2>&1; then
    echo "Missing $QEMU_BIN. Install QEMU's ARM system emulator (for example, qemu-system-arm)." >&2
    exit 1
fi
if [ "$PERSIST" != 1 ] && [ "$PERSIST" != 0 ]; then
    echo "Invalid OSYM_PERSIST value: use 1 or 0" >&2
    exit 1
fi

QEMU_ARGS=(
    -machine virt
    -cpu max
    -m "$RAM"
    -smp "$CPUS"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "console=ttyAMA0 quiet panic=10"
    -nographic
    -no-reboot
    -netdev "user,id=net0,hostfwd=tcp::${PORT}-:8422"
    -device "virtio-net-pci,netdev=net0"
)
if [ "$PERSIST" = 1 ]; then
    mkdir -p "$DATA_DIR"
    chmod 700 "$DATA_DIR"
    QEMU_ARGS+=( -virtfs "local,path=$DATA_DIR,mount_tag=osymdata,security_model=mapped-xattr,id=osymdata" )
fi

echo "OSymbiote ARM64 QEMU virt"
echo "  API: http://localhost:$PORT"
echo "  RAM: ${RAM}MB, CPUs: $CPUS"
if [ "$PERSIST" = 1 ]; then
    echo "  Data: $DATA_DIR (persistent)"
fi

if [ "${1:-}" = "--background" ]; then
    "$QEMU_BIN" "${QEMU_ARGS[@]}" >/dev/null 2>&1 &
    QEMU_PID=$!
    echo "QEMU PID: $QEMU_PID"
    sleep 5
    if ! kill -0 "$QEMU_PID" 2>/dev/null; then
        echo "QEMU exited during startup. Check host QEMU support." >&2
        exit 1
    fi
    if curl -fsS --max-time 3 "http://127.0.0.1:${PORT}/health" | grep -Eq '"status"[[:space:]]*:[[:space:]]*"alive"'; then
        echo "OSymbiote is ALIVE"
    else
        echo "Health check failed (the guest may still be booting)." >&2
    fi
else
    exec "$QEMU_BIN" "${QEMU_ARGS[@]}"
fi
