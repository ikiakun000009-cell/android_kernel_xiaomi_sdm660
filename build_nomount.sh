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

# 2. Integrasi BakaSU_NMS
if [ ! -d "KernelSU" ] && [ ! -d "drivers/kernelsu" ]; then
    echo "[INFO] Memasang BakaSU_NMS dari $BAKASU_REPO..."
    BAKASU_BRANCH=$(git ls-remote --symref "$BAKASU_REPO" HEAD | awk '/^ref:/ {sub(/refs\/heads\//, "", $2); print $2}')
    [ -z "$BAKASU_BRANCH" ] && BAKASU_BRANCH="main"
    echo "[INFO] Branch BakaSU terdeteksi: $BAKASU_BRANCH"

    RAW_SETUP="https://raw.githubusercontent.com/Bouteillepleine/OnePlus-BakaSu_NMS/$BAKASU_BRANCH/kernel/setup.sh"
    if curl -fsSL "$RAW_SETUP" -o /tmp/bakasu_setup.sh; then
        bash /tmp/bakasu_setup.sh "$BAKASU_BRANCH"
        if [ -d "KernelSU/.git" ] && ! git -C KernelSU remote -v | grep -qi "Bouteillepleine/OnePlus-BakaSu_NMS"; then
            rm -rf KernelSU
            git clone --depth=1 -b "$BAKASU_BRANCH" "$BAKASU_REPO" KernelSU
        fi
    else
        git clone --depth=1 -b "$BAKASU_BRANCH" "$BAKASU_REPO" KernelSU
        ln -sf "$(pwd)/KernelSU/kernel" drivers/kernelsu
        grep -q "drivers/kernelsu" drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
        grep -q "drivers/kernelsu" drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
    fi
fi

# 3. Integrasi NoMount (hanya dipasang jika belum ada di dalam BakaSU_NMS)
if [ ! -d "fs/nomount" ] && ! grep -rq "CONFIG_NOMOUNT" fs/ drivers/ 2>/dev/null; then
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

# 5. Compile kernel 4.4 sdm660
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
