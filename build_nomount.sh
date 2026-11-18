#!/usr/bin/env bash
set -e

CLANG_DIR="$PWD/clang/bin"
BAKASU_REPO="https://github.com/Bouteillepleine/OnePlus-BakaSu_NMS.git"

# 1. Cari defconfig Redmi Note 7 (prioritas varian perf)
DEFCONFIG_PATH=$(find arch/arm64/configs -name "*lavender*perf_defconfig" | head -n 1)
[ -z "$DEFCONFIG_PATH" ] && DEFCONFIG_PATH=$(find arch/arm64/configs -name "*lavender*defconfig" | head -n 1)
[ -z "$DEFCONFIG_PATH" ] && DEFCONFIG_PATH=$(find arch/arm64/configs -name "*sdm660*perf_defconfig" | head -n 1)

if [ -z "$DEFCONFIG_PATH" ]; then
    echo "[ERROR] File defconfig lavender/sdm660 tidak ditemukan!"
    exit 1
fi

DEFCONFIG="${DEFCONFIG_PATH#arch/arm64/configs/}"
echo "[INFO] Menggunakan defconfig: $DEFCONFIG"

# 2. Integrasi BakaSU_NMS (deteksi otomatis letak folder Kconfig)
if [ ! -e "drivers/kernelsu" ]; then
    echo "[INFO] Memasang BakaSU_NMS dari $BAKASU_REPO..."
    BAKASU_BRANCH=$(git ls-remote --symref "$BAKASU_REPO" HEAD | awk '/^ref:/ {sub(/refs\/heads\//, "", $2); print $2}')
    [ -z "$BAKASU_BRANCH" ] && BAKASU_BRANCH="NoMount"
    echo "[INFO] Branch BakaSU terdeteksi: $BAKASU_BRANCH"

    rm -rf KernelSU
    git clone --depth=1 -b "$BAKASU_BRANCH" "$BAKASU_REPO" KernelSU

    if [ -f "KernelSU/kernel/Kconfig" ]; then
        ln -sfn "$(pwd)/KernelSU/kernel" drivers/kernelsu
    elif [ -f "KernelSU/Kconfig" ]; then
        ln -sfn "$(pwd)/KernelSU" drivers/kernelsu
    else
        KSU_KCONFIG=$(find KernelSU -maxdepth 3 -name "Kconfig" | head -n 1)
        if [ -n "$KSU_KCONFIG" ]; then
            ln -sfn "$(pwd)/$(dirname "$KSU_KCONFIG")" drivers/kernelsu
        else
            echo "[ERROR] File Kconfig tidak ditemukan di dalam repo BakaSU!"
            ls -la KernelSU
            exit 1
        fi
    fi

    grep -q "drivers/kernelsu" drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    grep -q "drivers/kernelsu" drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
fi

# 3. Integrasi NoMount (hanya dipasang jika belum ada di dalam BakaSU_NMS)
if [ ! -d "fs/nomount" ] && ! grep -rqE "config NOMOUNT|nomount_init" KernelSU/ fs/ drivers/ 2>/dev/null; then
    echo "[INFO] Memasang NoMount (branch dev)..."
    curl -fsSL https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh | bash -s dev
else
    echo "[INFO] Dukungan NoMount sudah terdeteksi di source tree."
fi

# 4. Aktifkan flag kernel 4.4 yang diperlukan
for cfg in \
    CONFIG_NOMOUNT=y \
    CONFIG_KSU=y \
    CONFIG_KPROBES=y \
    CONFIG_HAVE_KPROBES=y \
    CONFIG_KPROBE_EVENTS=y \
    CONFIG_KALLSYMS=y \
    CONFIG_KALLSYMS_ALL=y \
    CONFIG_OVERLAY_FS=y; do
    grep -q "^$cfg" "$DEFCONFIG_PATH" || echo "$cfg" >> "$DEFCONFIG_PATH"
done

# 5. Compile kernel 4.4 sdm660 (Clang + GNU Linker + bypass warning C lama)
export PATH="$CLANG_DIR:$PATH"
export ARCH=arm64
export SUBARCH=arm64

make O=out ARCH=arm64 "$DEFCONFIG"

make -j"$(nproc --all)" O=out \
    ARCH=arm64 \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    KCFLAGS="-Wno-error"
