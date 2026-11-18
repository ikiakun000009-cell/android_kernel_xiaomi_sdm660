#!/usr/bin/env bash
set -e

CLANG_DIR="$PWD/clang/bin"
BAKASU_META_REPO="https://github.com/Bouteillepleine/OnePlus-BakaSu_NMS.git"

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

# 2. Ambil source BakaSU asli dari manifest/konfigurasi OnePlus-BakaSu_NMS
if [ ! -e "drivers/kernelsu" ]; then
    echo "[INFO] Membaca manifest BakaSU dari $BAKASU_META_REPO..."
    rm -rf /tmp/bakasu_meta KernelSU
    git clone --depth=1 "$BAKASU_META_REPO" /tmp/bakasu_meta

    FOUND_SETUP=$(grep -rhoE 'https://raw\.githubusercontent\.com/[^"'\''[:space:])]+setup\.sh' /tmp/bakasu_meta 2>/dev/null | head -n 1 || true)
    FOUND_REPO=$(grep -rhoE 'https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+' /tmp/bakasu_meta 2>/dev/null | grep -vi "OnePlus-BakaSu_NMS" | grep -iE "bakasu|kernelsu|sukisu" | head -n 1 || true)

    if [ -n "$FOUND_SETUP" ]; then
        echo "[INFO] Menjalankan setup.sh dari manifest: $FOUND_SETUP"
        SETUP_ARG=$(grep -hoE "${FOUND_SETUP}[^|]*\|[[:space:]]*bash[[:space:]]+-s[[:space:]]+[A-Za-z0-9_.-]+" /tmp/bakasu_meta 2>/dev/null | awk '{print $NF}' | head -n 1 || true)
        if [ -n "$SETUP_ARG" ]; then
            curl -fsSL "$FOUND_SETUP" | bash -s "$SETUP_ARG"
        else
            curl -fsSL "$FOUND_SETUP" | bash -
        fi
    elif [ -n "$FOUND_REPO" ]; then
        echo "[INFO] Mengkloning source BakaSU terdeteksi: $FOUND_REPO"
        git clone --depth=1 "$FOUND_REPO" KernelSU
    else
        echo "[INFO] Menampilkan referensi dari manifest:"
        grep -rnE "http|Baka|ksu" /tmp/bakasu_meta/manifests /tmp/bakasu_meta/README.md 2>/dev/null | head -n 15 || true
        echo "[INFO] Menggunakan fallback KernelSU-Next..."
        curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s next
    fi

    # Pastikan symlink drivers/kernelsu terpasang jika belum dibuat oleh setup.sh
    if [ ! -e "drivers/kernelsu" ] && [ -d "KernelSU" ]; then
        if [ -f "KernelSU/kernel/Kconfig" ]; then
            ln -sfn "$(pwd)/KernelSU/kernel" drivers/kernelsu
        elif [ -f "KernelSU/Kconfig" ]; then
            ln -sfn "$(pwd)/KernelSU" drivers/kernelsu
        fi
        grep -q "drivers/kernelsu" drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
        grep -q "drivers/kernelsu" drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
    fi
fi

# 3. Integrasi NoMount (hanya dipasang jika belum ada di dalam source tree)
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
