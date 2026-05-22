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
