#!/bin/bash
# OSymbiote — Run the agent OS in QEMU
# Usage: ./run.sh [--background]

set -e
cd "$(dirname "$0")"

KERNEL="build/vmlinuz"
INITRD="images/initramfs.cpio.gz"
PORT="${OSYM_PORT:-18422}"
RAM="${OSYM_RAM:-128}"
CPUS="${OSYM_CPUS:-2}"

if [ ! -f "$KERNEL" ] || [ ! -f "$INITRD" ]; then
    echo "Missing kernel or initramfs. Run: bash scripts/build-phase1.sh"
    exit 1
fi

echo "┌──────────────────────────────────┐"
echo "│  OSymbiote — Starting...         │"
echo "│  API: http://localhost:$PORT      │"
echo "│  RAM: ${RAM}MB, CPUs: $CPUS       │"
echo "└──────────────────────────────────┘"

QEMU_ARGS=(
    -m "$RAM"
    -kernel "$KERNEL"
    -initrd "$INITRD"
    -append "console=ttyS0 quiet panic=10"
    -nographic
    -no-reboot
    -netdev "user,id=net0,hostfwd=tcp::${PORT}-:8422"
    -device "e1000,netdev=net0"
    -smp "$CPUS"
    -cpu max
)

if [ "$1" = "--background" ]; then
    qemu-system-x86_64 "${QEMU_ARGS[@]}" &>/dev/null &
    QEMU_PID=$!
    echo "QEMU PID: $QEMU_PID"
    sleep 5
    HEALTH_OK=0
    for path in "/health" "/cgi-bin/api/health" "/cgi-bin/api?action=status" "/"; do
        if curl -s --max-time 3 "http://127.0.0.1:${PORT}${path}" | grep -q '"status":"alive"\|alive'; then
            HEALTH_OK=1
            break
        fi
    done
    if [ "$HEALTH_OK" -eq 1 ]; then
        echo "✅ OSymbiote is ALIVE"
    else
        echo "⚠️  Health check failed (may still be booting)"
    fi
else
    exec qemu-system-x86_64 "${QEMU_ARGS[@]}"
fi
