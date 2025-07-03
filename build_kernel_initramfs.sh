#!/bin/bash
set -e

# ====== 配置默认路径 ======
LINUX_DIR=${LINUX_DIR:-./linux}
BUSYBOX_DIR=${BUSYBOX_DIR:-./busybox}
ROOTFS_DIR=${ROOTFS_DIR:-./rootfs}
OUTPUT_INITRAMFS=${OUTPUT_INITRAMFS:-./initramfs.cpio.gz}
OUTPUT_BZIMAGE=${OUTPUT_BZIMAGE:-./arch/x86/boot/bzImage}
DISK_IMG=${DISK_IMG:-./extroot.img}
DISK_SIZE=${DISK_SIZE:-10G}

# ====== 编译 BusyBox ======
build_busybox() {
    echo "📦 编译 BusyBox..."
    [ ! -d "$BUSYBOX_DIR" ] && git clone https://git.busybox.net/busybox "$BUSYBOX_DIR"
    pushd "$BUSYBOX_DIR" >/dev/null
    make distclean
    make defconfig
    sed -i 's/.*CONFIG_STATIC.*/CONFIG_STATIC=y/' .config
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
    make -j$(nproc)
    make CONFIG_PREFIX="$ROOTFS_DIR" install
    popd >/dev/null
}

# ====== 构建 rootfs ======
build_rootfs() {
    echo "📂 构建 rootfs..."
    rm -rf "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR"/{dev,proc,sys}

    sudo mknod -m 600 "$ROOTFS_DIR/dev/console" c 5 1
    sudo mknod -m 666 "$ROOTFS_DIR/dev/null" c 1 3
    sudo mknod -m 666 "$ROOTFS_DIR/dev/tty" c 5 0
    sudo mknod -m 666 "$ROOTFS_DIR/dev/random" c 1 8

    cat << 'EOF' > "$ROOTFS_DIR/init"
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
echo "✅ Init started"
/bin/sh
EOF
    chmod +x "$ROOTFS_DIR/init"
}

# ====== 打包 initramfs ======
pack_initramfs() {
    echo "📦 打包 initramfs..."
    pushd "$ROOTFS_DIR" >/dev/null
    find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$OUTPUT_INITRAMFS"
    popd >/dev/null
}

# ====== 编译内核 ======
build_kernel() {
    echo "🐧 编译 Linux 内核..."
    [ ! -d "$LINUX_DIR" ] && git clone --depth=1 https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git "$LINUX_DIR"
    pushd "$LINUX_DIR" >/dev/null
    make mrproper
    make defconfig
    scripts/config --disable DEBUG_INFO_NONE
    scripts/config --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
    scripts/config --enable DEBUG_KERNEL
    scripts/config --enable FRAME_POINTER
    scripts/config --disable RANDOMIZE_BASE
    make -j$(nproc)
    popd >/dev/null
}

# ====== 创建 10G ext4 磁盘镜像并复制 rootfs ======
build_disk_image() {
    echo "💽 创建 $DISK_SIZE ext4 根磁盘镜像..."
    dd if=/dev/zero of="$DISK_IMG" bs=1M count=0 seek=$((10*1024)) status=progress
    mkfs.ext4 -F "$DISK_IMG"

    echo "📁 挂载磁盘并复制 rootfs..."
    TMPMNT=$(mktemp -d)
    sudo mount "$DISK_IMG" "$TMPMNT"
    sudo cp -a "$ROOTFS_DIR"/* "$TMPMNT"
    sudo umount "$TMPMNT"
    rmdir "$TMPMNT"
    echo "✅ 磁盘镜像创建完成：$DISK_IMG"
}

# ====== 启动 QEMU ======
launch_qemu() {
    echo "🚀 启动 QEMU..."
    [ ! -f "$OUTPUT_BZIMAGE" ] && { echo "❌ bzImage 不存在: $OUTPUT_BZIMAGE"; exit 1; }
    [ ! -f "$OUTPUT_INITRAMFS" ] && { echo "❌ initramfs 不存在: $OUTPUT_INITRAMFS"; exit 1; }
    [ ! -f "$DISK_IMG" ] && { echo "❌ 磁盘镜像不存在: $DISK_IMG"; exit 1; }

    read -p "❓ 是否启用调试模式？(y/N) " yn
    if [[ "$yn" == "y" || "$yn" == "Y" ]]; then
        echo "⚙️ 启用调试模式..."
        DEBUG_APPEND="debug debug_verbose=1 loglevel=8"
        QEMU_EXTRA="-s -S"
    else
        DEBUG_APPEND=""
        QEMU_EXTRA=""
    fi

    qemu-system-x86_64 \
        -m 2048 \
        -kernel "$OUTPUT_BZIMAGE" \
        -initrd "$OUTPUT_INITRAMFS" \
        -append "console=ttyS0 init=/init root=/dev/sda rw $DEBUG_APPEND" \
        -hda "$DISK_IMG" \
        -nographic \
        $QEMU_EXTRA
}

# ====== 执行流程 ======
read -p "🔧 Step 1: 编译 BusyBox？(y/N) " yn; [[ "$yn" == "y" ]] && build_busybox
read -p "📂 Step 2: 构建 rootfs？(y/N) " yn; [[ "$yn" == "y" ]] && build_rootfs
read -p "📦 Step 3: 打包 initramfs？(y/N) " yn; [[ "$yn" == "y" ]] && pack_initramfs
read -p "🐧 Step 4: 编译内核？(y/N) " yn; [[ "$yn" == "y" ]] && build_kernel
read -p "💽 Step 5: 创建并写入 10G 根磁盘镜像？(y/N) " yn; [[ "$yn" == "y" ]] && build_disk_image

echo "🚀 Step 6: 启动 QEMU（默认启动）"
launch_qemu
