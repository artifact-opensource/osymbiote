#!/bin/bash
# Package a built initramfs target as a hybrid ISO, disk image, and USB image.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSYM="$(cd "$SCRIPT_DIR/.." && pwd)"
VERSION="$(tr -d '[:space:]' < "$OSYM/VERSION")"
ARCH="${1:-x86_64}"
IMAGES="$OSYM/images"
mkdir -p "$IMAGES"
STAGE="$(mktemp -d "$IMAGES/.package-${ARCH}.XXXXXX")"
trap 'rm -rf "$STAGE"' EXIT

[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || {
    echo "ERROR: VERSION must contain a semantic version." >&2
    exit 1
}
case "$ARCH" in
    x86_64)
        KERNEL="$OSYM/build/vmlinuz"
        INITRD="$IMAGES/initramfs.cpio.gz"
        GRUB_PLATFORM_DIR=""
        ;;
    arm64)
        KERNEL="$OSYM/build/arm64/vmlinuz"
        INITRD="$IMAGES/arm64-initramfs.cpio.gz"
        GRUB_PLATFORM_DIR="${OSYM_GRUB_ARM64_DIR:-/usr/lib/grub/arm64-efi}"
        ;;
    *)
        echo "Usage: $0 [x86_64|arm64]" >&2
        exit 2
        ;;
esac

for tool in grub-mkrescue xorriso mformat sha256sum cp file; do
    command -v "$tool" >/dev/null 2>&1 || {
        echo "ERROR: Missing required image packaging tool: $tool" >&2
        exit 1
    }
done
if [ "$ARCH" = arm64 ] && [ ! -d "$GRUB_PLATFORM_DIR" ]; then
    echo "ERROR: ARM64 GRUB modules not found at $GRUB_PLATFORM_DIR." >&2
    echo "Install arm64-efi GRUB modules or set OSYM_GRUB_ARM64_DIR." >&2
    exit 1
fi
if [ ! -s "$KERNEL" ] || [ ! -s "$INITRD" ]; then
    echo "ERROR: Missing $ARCH kernel or initramfs. Build it before packaging." >&2
    exit 1
fi

TREE="$STAGE/tree"
mkdir -p "$TREE/boot/grub"
cp "$KERNEL" "$TREE/boot/vmlinuz"
cp "$INITRD" "$TREE/boot/initramfs.cpio.gz"

if [ "$ARCH" = x86_64 ]; then
    cat > "$TREE/boot/grub/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=5

menuentry "OSymbiote x86_64 (display console)" {
    linux /boot/vmlinuz console=tty0 quiet panic=10
    initrd /boot/initramfs.cpio.gz
}

menuentry "OSymbiote x86_64 (serial console)" {
    linux /boot/vmlinuz console=ttyS0,115200n8 quiet panic=10
    initrd /boot/initramfs.cpio.gz
}
GRUBCFG
    grub-mkrescue --product-name="OSymbiote" --product-version="$VERSION" \
        -o "$STAGE/osymbiote.iso" "$TREE"
else
    cat > "$TREE/boot/grub/grub.cfg" <<'GRUBCFG'
set default=0
set timeout=5

menuentry "OSymbiote ARM64 QEMU virt (serial console)" {
    linux /boot/vmlinuz console=ttyAMA0 quiet panic=10
    initrd /boot/initramfs.cpio.gz
}
GRUBCFG
    grub-mkrescue --directory="$GRUB_PLATFORM_DIR" \
        --product-name="OSymbiote ARM64" --product-version="$VERSION" \
        -o "$STAGE/osymbiote.iso" "$TREE"
fi

[ -s "$STAGE/osymbiote.iso" ] || {
    echo "ERROR: GRUB did not produce an ISO image." >&2
    exit 1
}
file "$STAGE/osymbiote.iso" | grep -qi 'ISO 9660' || {
    echo "ERROR: Packaged image is not recognized as ISO 9660." >&2
    exit 1
}

PREFIX="$IMAGES/osymbiote-$VERSION-$ARCH"
cp "$STAGE/osymbiote.iso" "$STAGE/$ARCH.iso"
cp "$STAGE/osymbiote.iso" "$STAGE/$ARCH-disk.img"
cp "$STAGE/osymbiote.iso" "$STAGE/$ARCH-usb.img"
mv "$STAGE/$ARCH.iso" "$PREFIX.iso"
mv "$STAGE/$ARCH-disk.img" "$PREFIX.disk.img"
mv "$STAGE/$ARCH-usb.img" "$PREFIX.usb.img"
for image in "$PREFIX.iso" "$PREFIX.disk.img" "$PREFIX.usb.img"; do
    (cd "$IMAGES" && sha256sum "$(basename "$image")" > "$(basename "$image").sha256")
done

echo "Created versioned hybrid boot images:"
printf '  ISO:  %s.iso\n' "$PREFIX"
printf '  Disk: %s.disk.img\n' "$PREFIX"
printf '  USB:  %s.usb.img\n' "$PREFIX"
echo "The disk and USB images are raw copies of the hybrid ISO, not writable system disks."
