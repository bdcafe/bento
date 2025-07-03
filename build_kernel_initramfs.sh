#!/bin/bash
set -e

# ========= 配置部分 =========
LINUX_REPO=${LINUX_REPO:-https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git}
BUSYBOX_DIR=${BUSYBOX_DIR:-./busybox}
ROOTFS_DIR=${ROOTFS_DIR:-./rootfs}
OUTPUT_INITRAMFS=${OUTPUT_INITRAMFS:-./initramfs.cpio.gz}
OUTPUT_BZIMAGE=${OUTPUT_BZIMAGE:-./arch/x86/boot/bzImage}

# ========= 函数 =========

build_busybox() {
    echo "📦 编译 BusyBox 静态版本"
    if [ ! -d "$BUSYBOX_DIR" ]; then
        git clone https://git.busybox.net/busybox "$BUSYBOX_DIR"
    fi
    pushd "$BUSYBOX_DIR" >/dev/null
    make defconfig
    sed -i 's/.*CONFIG_STATIC.*/CONFIG_STATIC=y/' .config
    sed -i 's/^CONFIG_TC=y/# CONFIG_TC is not set/' .config
    make -j$(nproc)
    make CONFIG_PREFIX="$ROOTFS_DIR" install
    popd >/dev/null
}

build_rootfs() {
    echo "🗂 构建 rootfs"
    rm -rf "$ROOTFS_DIR"
    mkdir -p "$ROOTFS_DIR"/{dev,proc,sys}

    sudo mknod -m 600 "$ROOTFS_DIR"/dev/console c 5 1
    sudo mknod -m 666 "$ROOTFS_DIR"/dev/null c 1 3
    sudo mknod -m 666 "$ROOTFS_DIR"/dev/tty c 5 0

    cat << 'EOF' > "$ROOTFS_DIR/init"
#!/bin/sh
mount -t proc none /proc
mount -t sysfs none /sys
echo "✅ Init started"
exec /bin/sh
EOF

    chmod +x "$ROOTFS_DIR/init"
}

pack_initramfs() {
    echo "📦 打包 initramfs"
    pushd "$ROOTFS_DIR" >/dev/null
    find . -print0 | cpio --null -ov --format=newc | gzip -9 > "$OUTPUT_INITRAMFS"
    popd >/dev/null
}

build_kernel() {
    echo "🐧 编译 Linux 内核"
    make mrproper
    make defconfig

    # 开启调试信息（DWARF）
    scripts/config --disable DEBUG_INFO_NONE
    scripts/config --enable DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT
    scripts/config --enable DEBUG_KERNEL
    Scripts/config --enable FRAME_POINTER
    scripts/config --disable RANDOMIZE_BASE

    make -j$(nproc)
    popd >/dev/null
}

launch_qemu() {
    echo "🚀 使用 QEMU 启动内核"
    qemu-system-x86_64 \
        -kernel "$OUTPUT_BZIMAGE" \
        -initrd "$OUTPUT_INITRAMFS" \
        -append "console=ttyS0 init=/init" \
        -nographic
}

# ========= 主执行流程 =========

read -p "🔧 Step 1: 是否编译 BusyBox？(y/N) " yn
if [[ "$yn" == "y" ]]; then
    build_busybox
else
    echo "⏭ 跳过 BusyBox 编译"
fi

read -p "📂 Step 2: 是否构建 rootfs？(y/N) " yn
if [[ "$yn" == "y" ]]; then
    build_rootfs
else
    echo "⏭ 跳过 rootfs 构建"
fi

read -p "📦 Step 3: 是否打包 initramfs？(y/N) " yn
if [[ "$yn" == "y" ]]; then
    pack_initramfs
else
    echo "⏭ 跳过 initramfs 打包"
fi

read -p "🐧 Step 4: 是否编译 Linux 内核？(y/N) " yn
if [[ "$yn" == "y" ]]; then
    build_kernel
else
    echo "⏭ 跳过内核编译"
fi

read -p "🚀 Step 5: 是否启动 QEMU？(y/N) " yn
if [[ "$yn" == "y" ]]; then
    launch_qemu
else
    echo "⏭ 跳过 QEMU 启动"
fi
