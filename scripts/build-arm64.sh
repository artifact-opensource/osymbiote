#!/bin/bash
# Build the ARM64 QEMU virt reference image.

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
OSYM="$(cd "$SCRIPT_DIR/.." && pwd)"
BUILD="$OSYM/build/arm64"
PAIR_TMP="$(mktemp -d)"
BUILD_STAGE="$PAIR_TMP/build"
IMAGES="$OSYM/images"
INITRD="$BUILD_STAGE/initrd"
BB_TMPDIR=""
trap 'rm -rf "$PAIR_TMP"; [ -z "$BB_TMPDIR" ] || rm -rf "$BB_TMPDIR"' EXIT

require_tool() {
    command -v "$1" >/dev/null 2>&1 || {
        echo "ERROR: Missing required tool: $1" >&2
        exit 1
    }
}

download_file() {
    local destination="$1"
    local url="$2"
    wget -q -O "$destination" "$url" || {
        rm -f "$destination"
        echo "ERROR: Download failed: $url" >&2
        exit 1
    }
}

for tool in wget gzip cpio unsquashfs tar awk file find install; do
    require_tool "$tool"
done
mkdir -p "$BUILD_STAGE" "$IMAGES"

echo "[1/5] Downloading matching Alpine ARM64 kernel and modules..."
BASE_URL="https://dl-cdn.alpinelinux.org/alpine/v3.21"
NETBOOT_URL="$BASE_URL/releases/aarch64/netboot"
download_file "$PAIR_TMP/vmlinuz" "$NETBOOT_URL/vmlinuz-virt"
download_file "$PAIR_TMP/initramfs-virt" "$NETBOOT_URL/initramfs-virt"
download_file "$PAIR_TMP/modloop-virt" "$NETBOOT_URL/modloop-virt"
gzip -t "$PAIR_TMP/initramfs-virt"
unsquashfs -s "$PAIR_TMP/modloop-virt" >/dev/null 2>&1 || {
    echo "ERROR: Downloaded Alpine ARM64 module archive is invalid." >&2
    exit 1
}
file "$PAIR_TMP/vmlinuz" | grep -Eqi 'ARM aarch64|AArch64|ARM64' || {
    echo "ERROR: Alpine kernel is not an ARM64 image." >&2
    exit 1
}
mv "$PAIR_TMP/vmlinuz" "$BUILD_STAGE/vmlinuz"
mv "$PAIR_TMP/initramfs-virt" "$BUILD_STAGE/initramfs-virt"
mv "$PAIR_TMP/modloop-virt" "$BUILD_STAGE/modloop-virt"

echo "[2/5] Downloading static ARM64 BusyBox..."
BB_TMPDIR="$(mktemp -d)"
download_file "$BB_TMPDIR/APKINDEX.tar.gz" "$BASE_URL/main/aarch64/APKINDEX.tar.gz"
tar -xzf "$BB_TMPDIR/APKINDEX.tar.gz" -C "$BB_TMPDIR" APKINDEX
BB_VER="$(sed -n '/^P:busybox-static$/,/^$/ { /^V:/ { s/^V://; p; q; } }' "$BB_TMPDIR/APKINDEX")"
[ -n "$BB_VER" ] || {
    echo "ERROR: Could not resolve busybox-static from the Alpine ARM64 package index." >&2
    exit 1
}
download_file "$BB_TMPDIR/busybox.apk" "$BASE_URL/main/aarch64/busybox-static-${BB_VER}.apk"
if tar -tzf "$BB_TMPDIR/busybox.apk" | grep -qx 'bin/busybox.static'; then
    tar -xzf "$BB_TMPDIR/busybox.apk" -C "$BB_TMPDIR" bin/busybox.static
    cp "$BB_TMPDIR/bin/busybox.static" "$BUILD_STAGE/busybox-arm64"
elif tar -tzf "$BB_TMPDIR/busybox.apk" | grep -qx 'bin/busybox'; then
    tar -xzf "$BB_TMPDIR/busybox.apk" -C "$BB_TMPDIR" bin/busybox
    cp "$BB_TMPDIR/bin/busybox" "$BUILD_STAGE/busybox-arm64"
else
    echo "ERROR: Static BusyBox was not found in the Alpine package." >&2
    exit 1
fi
chmod 0755 "$BUILD_STAGE/busybox-arm64"
file "$BUILD_STAGE/busybox-arm64" | grep -Eqi 'ARM aarch64|AArch64|ARM64' || {
    echo "ERROR: Downloaded BusyBox is not an ARM64 binary." >&2
    exit 1
}

echo "[3/5] Assembling ARM64 initramfs..."
rm -rf "$INITRD"
mkdir -p "$INITRD"/{bin,sbin,etc,proc,sys,dev,tmp,run,data,opt/mach6,usr/bin,var/log,lib/modules}
cp "$BUILD_STAGE/busybox-arm64" "$INITRD/bin/busybox"
for cmd in sh ash ls cat echo mkdir mount umount ip grep awk sed nc wget date cut wc tail head sleep kill test tr \
           hostname uname free df ps udhcpc vi dmesg mknod chmod chown cp mv rm ln touch stat sha256sum od sort uniq tee \
           clear find xargs printf stty setsid cttyhack ping top du env basename dirname id whoami uptime which less more \
           sync pidof killall tcpsvd timeout egrep fgrep seq expr rev tac nslookup netstat traceroute ifconfig route reboot poweroff halt; do
    ln -sf busybox "$INITRD/bin/$cmd"
done
for cmd in init halt reboot poweroff ifconfig route; do
    ln -sf ../bin/busybox "$INITRD/sbin/$cmd"
done

MODULE_STAGE="$PAIR_TMP/initramfs-modules"
mkdir -p "$MODULE_STAGE"
gzip -dc "$BUILD_STAGE/initramfs-virt" | (cd "$MODULE_STAGE" && cpio -id --quiet \
    'lib/modules/*/kernel/drivers/net/virtio_net.ko*' \
    'lib/modules/*/kernel/drivers/virtio/virtio*.ko*' \
    'lib/modules/*/kernel/net/core/failover.ko*' \
    'lib/modules/*/kernel/net/packet/af_packet.ko*') 2>/dev/null
KERNEL_RELEASE="$(gzip -dc "$BUILD_STAGE/initramfs-virt" | cpio -it 2>/dev/null \
    | sed -n 's#^lib/modules/\([^/]*\)/.*#\1#p' | head -n 1)"
if [ -z "$KERNEL_RELEASE" ] || ! unsquashfs -ll "$BUILD_STAGE/modloop-virt" | grep -F "modules/$KERNEL_RELEASE/" >/dev/null; then
    echo "ERROR: Alpine ARM64 module archive does not match kernel release ${KERNEL_RELEASE:-unknown}." >&2
    exit 1
fi
MODTMP="$PAIR_TMP/modloop-modules"
mkdir -p "$MODTMP"
if ! unsquashfs -f -d "$MODTMP" "$BUILD_STAGE/modloop-virt" \
    "modules/$KERNEL_RELEASE/kernel/fs/9p/9p.ko" \
    "modules/$KERNEL_RELEASE/kernel/fs/netfs/netfs.ko" \
    "modules/$KERNEL_RELEASE/kernel/net/9p/9pnet.ko" \
    "modules/$KERNEL_RELEASE/kernel/net/9p/9pnet_virtio.ko" >/dev/null 2>&1; then
    echo "ERROR: Cannot extract 9p persistence modules from Alpine ARM64 module archive." >&2
    exit 1
fi
while IFS= read -r -d '' module; do
    cp "$module" "$INITRD/lib/modules/"
done < <(find "$MODULE_STAGE/lib/modules" "$MODTMP/modules/$KERNEL_RELEASE/kernel" -type f -name '*.ko*' -print0)
if ! find "$INITRD/lib/modules" -type f -name 'virtio_net.ko*' | grep -q .; then
    echo "ERROR: Required virtio-net module is missing from Alpine ARM64 kernel files." >&2
    exit 1
fi

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
echo "osymbiote" > "$INITRD/etc/hostname"
echo "nameserver 8.8.8.8" > "$INITRD/etc/resolv.conf"

echo "[4/5] Packing ARM64 initramfs..."
(
    cd "$INITRD"
    find . -print0 | cpio --null -o -H newc 2>/dev/null | gzip -9 > "$PAIR_TMP/arm64-initramfs.cpio.gz"
)
gzip -t "$PAIR_TMP/arm64-initramfs.cpio.gz"

rm -f "$IMAGES/arm64-initramfs.cpio.gz"
rm -rf "$BUILD/initrd"
mv "$BUILD_STAGE/initrd" "$BUILD/initrd"
mv "$BUILD_STAGE/vmlinuz" "$BUILD/vmlinuz"
mv "$BUILD_STAGE/initramfs-virt" "$BUILD/initramfs-virt"
mv "$BUILD_STAGE/modloop-virt" "$BUILD/modloop-virt"
mv "$BUILD_STAGE/busybox-arm64" "$BUILD/busybox-arm64"
mv "$PAIR_TMP/arm64-initramfs.cpio.gz" "$IMAGES/arm64-initramfs.cpio.gz"

echo "[5/5] ARM64 QEMU virt image ready."
echo "  Kernel:    $BUILD/vmlinuz ($(du -h "$BUILD/vmlinuz" | cut -f1))"
echo "  Initramfs: $IMAGES/arm64-initramfs.cpio.gz ($(du -h "$IMAGES/arm64-initramfs.cpio.gz" | cut -f1))"
echo "  Boot with: ./run-arm64.sh"
