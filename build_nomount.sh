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

# 2. Ambil source BakaSU / KernelSU-Next
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
        echo "[INFO] Menggunakan KernelSU-Next..."
        curl -LSs "https://raw.githubusercontent.com/KernelSU-Next/KernelSU-Next/next/kernel/setup.sh" | bash -s next
    fi

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

# 3. Integrasi NoMount (branch dev)
if [ ! -d "fs/nomount" ] && ! grep -rqE "config NOMOUNT|nomount_init" KernelSU/ fs/ drivers/ 2>/dev/null; then
    echo "[INFO] Memasang NoMount (branch dev)..."
    curl -fsSL https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh | bash -s dev
fi

# 4. Patch kompatibilitas VFS Linux 4.4 untuk fs/nomount
if [ -d "fs/nomount" ]; then
    echo "[INFO] Menerapkan patch kompatibilitas Linux 4.4 pada fs/nomount..."
    python3 - << 'EOF'
import re, pathlib

def parse_call_args(code, func_name):
    out = []
    i = 0
    n = len(code)
    pat = re.compile(r'\b' + re.escape(func_name) + r'\s*\(')
    while i < n:
        m = pat.search(code, i)
        if not m:
            out.append(code[i:])
            break
        out.append(code[i:m.start()])
        start = m.end()
        depth = 1
        j = start
        args = []
        arg_start = start
        while j < n and depth > 0:
            ch = code[j]
            if ch == '(':
                depth += 1
            elif ch == ')':
                depth -= 1
                if depth == 0:
                    args.append(code[arg_start:j].strip())
            elif ch == ',' and depth == 1:
                args.append(code[arg_start:j].strip())
                arg_start = j + 1
            j += 1
        yield_args = args
        if func_name == "full_name_hash" and len(yield_args) == 3:
            out.append(f"full_name_hash({yield_args[1]}, {yield_args[2]})")
        elif func_name == "__vfs_getxattr" and len(yield_args) >= 5:
            size_arg = re.sub(r'\bFLAGS_VAL\b', '', yield_args[4]).strip()
            out.append(f"vfs_getxattr({yield_args[0]}, {yield_args[2]}, {yield_args[3]}, {size_arg})")
        else:
            out.append(code[m.start():j])
        i = j
    return ''.join(out)

# Patch nomount.h
h_path = pathlib.Path("fs/nomount/nomount.h")
if h_path.exists():
    h = h_path.read_text()
    if "<linux/compat.h>" not in h:
        h = "#include <linux/compat.h>\n" + h
    h = h.replace("in_compat_syscall()", "is_compat_task()")
    h = h.replace("iterate_shared", "iterate")
    h = parse_call_args(h, "full_name_hash")
    lookup_fn = (
        "static inline struct dentry *nm_lookup_one_len_unlocked(const char *name, struct dentry *base, int len)\n"
        "{\n"
        "    struct dentry *d;\n"
        "    mutex_lock(&base->d_inode->i_mutex);\n"
        "    d = lookup_one_len(name, base, len);\n"
        "    mutex_unlock(&base->d_inode->i_mutex);\n"
        "    return d;\n"
        "}"
    )
    h = re.sub(r'#\s*define\s+nm_lookup_one_len_unlocked\s+lookup_one_len_unlocked', lookup_fn, h)
    h_path.write_text(h)

# Patch nomount.c
c_path = pathlib.Path("fs/nomount/nomount.c")
if c_path.exists():
    c = c_path.read_text()
    c = c.replace("iterate_shared", "iterate")
    c = parse_call_args(c, "full_name_hash")
    c = parse_call_args(c, "__vfs_getxattr")

    # 4.4 rename() hanya menerima 4 argumen (tanpa flags)
    c = re.sub(
        r'(static\s+int\s+nm_\w*rename\s*\([^)]*?),\s*unsigned\s+int\s+flags\s*\)\s*\{',
        r'\1)\n{\n    unsigned int flags = 0;',
        c,
        flags=re.DOTALL
    )
    c = re.sub(r'(->rename\s*\([^;]*?),\s*flags\s*\)', r'\1)', c, flags=re.DOTALL)

    # 4.4 memakai follow_link(dentry, cookie) bukan get_link(dentry, inode, done)
    c = re.sub(
        r'static\s+const\s+char\s*\*\s*nm_get_link\s*\(\s*struct\s+dentry\s*\*\s*dentry\s*,\s*struct\s+inode\s*\*\s*inode\s*,\s*struct\s+delayed_call\s*\*\s*done\s*\)\s*\{',
        'static const char *nm_follow_link(struct dentry *dentry, void **cookie)\n{\n    struct inode *inode = d_inode(dentry);',
        c
    )
    c = c.replace("->get_link(target_dentry, real_inode, done)", "->follow_link(target_dentry, cookie)")
    c = c.replace("->get_link", "->follow_link")
    c = c.replace(".get_link = nm_get_link", ".follow_link = nm_follow_link")
    c = c.replace(".get_link = nm_follow_link", ".follow_link = nm_follow_link")

    # 4.4 xattr handler tanpa parameter inode
    c = re.sub(
        r'(static\s+int\s+nm_xattr_get\s*\(\s*const\s+struct\s+xattr_handler\s*\*\s*\w+\s*,\s*struct\s+dentry\s*\*\s*dentry\s*,)\s*struct\s+inode\s*\*\s*inode\s*,',
        r'\1',
        c
    )
    c = re.sub(
        r'(static\s+int\s+nm_xattr_get\s*\([^)]+\)\s*\{)',
        r'\1\n    struct inode *inode = d_inode(dentry);',
        c
    )
    c = re.sub(
        r'(static\s+int\s+nm_xattr_set\s*\(\s*const\s+struct\s+xattr_handler\s*\*\s*\w+\s*,)\s*[^,]*\bstruct\s+dentry\s*\*\s*dentry\s*,\s*struct\s+inode\s*\*\s*inode\s*,',
        r'\1 struct dentry *dentry,',
        c
    )
    c = re.sub(
        r'(static\s+int\s+nm_xattr_set\s*\([^)]+\)\s*\{)',
        r'\1\n    struct inode *inode = d_inode(dentry);',
        c
    )
    c = re.sub(
        r'proxy->orig->get\s*\(\s*proxy->orig\s*,\s*dentry\s*,\s*inode\s*,\s*name\s*,\s*buffer\s*,\s*size[^\)]*\)',
        'proxy->orig->get(proxy->orig, dentry, name, buffer, size)',
        c
    )
    c = re.sub(
        r'proxy->orig->set\s*\(\s*proxy->orig\s*,[^,]*\bdentry\s*,\s*inode\s*,\s*name\s*,\s*buffer\s*,\s*size\s*,\s*flags\s*\)',
        'proxy->orig->set(proxy->orig, dentry, name, buffer, size, flags)',
        c
    )
    c_path.write_text(c)
print("[INFO] Patch Linux 4.4 pada fs/nomount selesai.")
EOF
fi

# 5. Aktifkan flag kernel 4.4 yang diperlukan
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

# 6. Compile kernel 4.4 sdm660 (Clang + GNU Linker + bypass warning C lama)
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
