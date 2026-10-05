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
