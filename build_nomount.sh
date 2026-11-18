#!/usr/bin/env bash
set -e

CLANG_DIR="$PWD/clang/bin"
BAKASU_REPO="https://github.com/Baka-SU/BakaSU.git"
BAKASU_BRANCH="main"

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

# 2. Integrasi BakaSU (branch main)
if [ ! -e "drivers/kernelsu" ]; then
    echo "[INFO] Memasang BakaSU dari $BAKASU_REPO (branch: $BAKASU_BRANCH)..."
    rm -rf KernelSU
    git clone --depth=1 -b "$BAKASU_BRANCH" "$BAKASU_REPO" KernelSU

    if [ -f "KernelSU/kernel/Kconfig" ]; then
        ln -sfn "$(pwd)/KernelSU/kernel" drivers/kernelsu
    elif [ -f "KernelSU/Kconfig" ]; then
        ln -sfn "$(pwd)/KernelSU" drivers/kernelsu
    else
        echo "[ERROR] File Kconfig tidak ditemukan di dalam $BAKASU_REPO!"
        exit 1
    fi

    grep -q "drivers/kernelsu" drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    grep -q "drivers/kernelsu" drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
fi

# 2b. Patch kompatibilitas Kbuild/Makefile BakaSU untuk kernel 4.4
if [ -f "drivers/kernelsu/Makefile" ]; then
    echo "[INFO] Menyesuaikan Makefile BakaSU untuk Kbuild 4.4..."
    python3 - << 'EOF'
import pathlib, re

mk_p = pathlib.Path("drivers/kernelsu/Makefile")
mk = mk_p.read_text()

# Pastikan KSU_GIT_VERSION selalu memiliki nilai valid
if "KSU_GIT_VERSION" in mk:
    mk = "KSU_GIT_VERSION := 12000\n" + mk

# Hapus baris Kbuild modern yang sering gagal di Makefile.modbuiltin 4.4
cleaned = []
for line in mk.splitlines():
    if any(bad in line for bad in ("$(error", "check_kallsyms", "KSU_EXPECTED_SIZE", "KSU_EXPECTED_HASH")):
        cleaned.append("# " + line)
    else:
        cleaned.append(line)

mk_p.write_text("\n".join(cleaned) + "\n")
print("[OK] Makefile BakaSU disesuaikan untuk kernel 4.4")
EOF
fi

# 3. Terapkan Manual Hooks BakaSU untuk kernel non-GKI 4.4
echo "[INFO] Memasang manual hooks pada fs/ dan drivers/input/..."
python3 - << 'EOF'
import pathlib, re

# Hook 1: fs/exec.c
exec_p = pathlib.Path("fs/exec.c")
if exec_p.exists():
    txt = exec_p.read_text()
    if "ksu_handle_execveat" not in txt:
        decl = (
            "#ifdef CONFIG_KSU\n"
            "extern bool ksu_execveat_hook __read_mostly;\n"
            "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n"
            "                               void *envp, int *flags);\n"
            "extern int ksu_handle_execveat_sucompat(int *fd, struct filename **filename_ptr,\n"
            "                                        void *argv, void *envp, int *flags);\n"
            "#endif\n"
        )
        hook = (
            "#ifdef CONFIG_KSU\n"
            "\tif (unlikely(ksu_execveat_hook))\n"
            "\t\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
            "\telse\n"
            "\t\tksu_handle_execveat_sucompat(&fd, &filename, &argv, &envp, &flags);\n"
            "#endif\n"
        )
        txt = re.sub(r'(static\s+int\s+do_execveat_common\s*\()', decl + r'\1', txt, count=1)
        txt = re.sub(r'(\n\s*if\s*\(\s*IS_ERR\s*\(\s*filename\s*\)\s*\))', "\n" + hook + r'\1', txt, count=1)
        exec_p.write_text(txt)
        print("[OK] Patched fs/exec.c")

# Hook 2: fs/open.c
open_p = pathlib.Path("fs/open.c")
if open_p.exists():
    txt = open_p.read_text()
    if "ksu_handle_faccessat" not in txt:
        decl = (
            "#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_faccessat(int *dfd, const char __user **filename_user, int *mode,\n"
            "                                int *flags);\n"
            "#endif\n"
        )
        hook = (
            "#ifdef CONFIG_KSU\n"
            "\tksu_handle_faccessat(&dfd, &filename, &mode, NULL);\n"
            "#endif\n"
        )
        txt = re.sub(r'(SYSCALL_DEFINE3\s*\(\s*faccessat\b)', decl + r'\1', txt, count=1)
        txt = re.sub(r'(\n\s*if\s*\(\s*mode\s*&\s*~S_IRWXO\s*\))', "\n" + hook + r'\1', txt, count=1)
        open_p.write_text(txt)
        print("[OK] Patched fs/open.c")

# Hook 3: fs/read_write.c
rw_p = pathlib.Path("fs/read_write.c")
if rw_p.exists():
    txt = rw_p.read_text()
    if "ksu_handle_vfs_read" not in txt:
        decl = (
            "#ifdef CONFIG_KSU\n"
            "extern bool ksu_vfs_read_hook __read_mostly;\n"
            "extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n"
            "                               size_t *count_ptr, loff_t **pos);\n"
            "#endif\n"
        )
        hook = (
            "#ifdef CONFIG_KSU\n"
            "\tif (unlikely(ksu_vfs_read_hook))\n"
            "\t\tksu_handle_vfs_read(&file, &buf, &count, &pos);\n"
            "#endif\n"
        )
        txt = re.sub(r'(ssize_t\s+vfs_read\s*\()', decl + r'\1', txt, count=1)
        txt = re.sub(r'(\n\s*if\s*\(\s*!\s*\(\s*file->f_mode\s*&\s*FMODE_READ\s*\)\s*\))', "\n" + hook + r'\1', txt, count=1)
        rw_p.write_text(txt)
        print("[OK] Patched fs/read_write.c")

# Hook 4: fs/stat.c
stat_p = pathlib.Path("fs/stat.c")
if stat_p.exists():
    txt = stat_p.read_text()
    if "ksu_handle_stat" not in txt:
        decl = (
            "#ifdef CONFIG_KSU\n"
            "extern int ksu_handle_stat(int *dfd, const char __user **filename_user, int *flags);\n"
            "#endif\n"
        )
        hook = (
            "#ifdef CONFIG_KSU\n"
            "\tksu_handle_stat(&dfd, &filename, &flag);\n"
            "#endif\n"
        )
        txt = re.sub(r'(int\s+vfs_fstatat\s*\()', decl + r'\1', txt, count=1)
        txt = re.sub(r'(\n\s*if\s*\(\s*\(\s*flag\s*&\s*~\s*\(\s*AT_SYMLINK_NOFOLLOW)', "\n" + hook + r'\1', txt, count=1)
        stat_p.write_text(txt)
        print("[OK] Patched fs/stat.c")

# Hook 5: drivers/input/input.c
inp_p = pathlib.Path("drivers/input/input.c")
if inp_p.exists():
    txt = inp_p.read_text()
    if "ksu_handle_input_handle_event" not in txt:
        decl = (
            "#ifdef CONFIG_KSU\n"
            "extern bool ksu_input_hook __read_mostly;\n"
            "extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n"
            "#endif\n"
        )
        hook = (
            "#ifdef CONFIG_KSU\n"
            "\tif (unlikely(ksu_input_hook))\n"
            "\t\tksu_handle_input_handle_event(&type, &code, &value);\n"
            "#endif\n"
        )
        txt = re.sub(r'(void\s+input_event\s*\()', decl + r'\1', txt, count=1)
        txt = re.sub(r'(\n\s*if\s*\(\s*is_event_supported\s*\(\s*type\s*,)', "\n" + hook + r'\1', txt, count=1)
        inp_p.write_text(txt)
        print("[OK] Patched drivers/input/input.c")
EOF

# 4. Integrasi NoMount (branch dev)
if [ ! -d "fs/nomount" ] && ! grep -rqE "config NOMOUNT|nomount_init" KernelSU/ fs/ drivers/ 2>/dev/null; then
    echo "[INFO] Memasang NoMount (branch dev)..."
    curl -fsSL https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh | bash -s dev
fi

# 5. Patch kompatibilitas VFS Linux 4.4 untuk fs/nomount
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
        if func_name == "full_name_hash" and len(args) == 3:
            out.append(f"full_name_hash({args[1]}, {args[2]})")
        elif func_name == "__vfs_getxattr" and len(args) >= 5:
            size_arg = re.sub(r'\bFLAGS_VAL\b', '', args[4]).strip()
            out.append(f"vfs_getxattr({args[0]}, {args[2]}, {args[3]}, {size_arg})")
        else:
            out.append(code[m.start():j])
        i = j
    return ''.join(out)

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

c_path = pathlib.Path("fs/nomount/nomount.c")
if c_path.exists():
    c = c_path.read_text()
    c = c.replace("iterate_shared", "iterate")
    c = parse_call_args(c, "full_name_hash")
    c = parse_call_args(c, "__vfs_getxattr")

    c = re.sub(
        r'(static\s+int\s+nm_\w*rename\s*\([^)]*?),\s*unsigned\s+int\s+flags\s*\)\s*\{',
        r'\1)\n{\n    unsigned int flags = 0;',
        c,
        flags=re.DOTALL
    )
    c = re.sub(r'(->rename\s*\([^;]*?),\s*flags\s*\)', r'\1)', c, flags=re.DOTALL)

    c = re.sub(
        r'static\s+const\s+char\s*\*\s*nm_get_link\s*\(\s*struct\s+dentry\s*\*\s*dentry\s*,\s*struct\s+inode\s*\*\s*inode\s*,\s*struct\s+delayed_call\s*\*\s*done\s*\)\s*\{',
        'static const char *nm_follow_link(struct dentry *dentry, void **cookie)\n{\n    struct inode *inode = d_inode(dentry);',
        c
    )
    c = c.replace("->get_link(target_dentry, real_inode, done)", "->follow_link(target_dentry, cookie)")
    c = c.replace("->get_link", "->follow_link")
    c = c.replace(".get_link = nm_get_link", ".follow_link = nm_follow_link")
    c = c.replace(".get_link = nm_follow_link", ".follow_link = nm_follow_link")

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

# 6. Aktifkan konfigurasi BakaSU Manual Hook + NoMount + Nama Kernel XtrSolRadical
sed -i '/CONFIG_KSU_WITH_KPROBES/d;/CONFIG_KSU_TRACEPOINT_HOOK/d;/CONFIG_KSU_SUSFS/d' "$DEFCONFIG_PATH"
echo "# CONFIG_KSU_WITH_KPROBES is not set" >> "$DEFCONFIG_PATH"
echo "# CONFIG_KSU_TRACEPOINT_HOOK is not set" >> "$DEFCONFIG_PATH"
echo "# CONFIG_KSU_SUSFS is not set" >> "$DEFCONFIG_PATH"

sed -i '/CONFIG_LOCALVERSION=/d;/CONFIG_LOCALVERSION_AUTO/d' "$DEFCONFIG_PATH"
echo 'CONFIG_LOCALVERSION="-XtrSolRadical"' >> "$DEFCONFIG_PATH"
echo '# CONFIG_LOCALVERSION_AUTO is not set' >> "$DEFCONFIG_PATH"

for cfg in \
    CONFIG_NOMOUNT=y \
    CONFIG_KSU=y \
    CONFIG_KSU_MANUAL_HOOK=y \
    CONFIG_KALLSYMS=y \
    CONFIG_KALLSYMS_ALL=y \
    CONFIG_OVERLAY_FS=y; do
    grep -q "^$cfg" "$DEFCONFIG_PATH" || echo "$cfg" >> "$DEFCONFIG_PATH"
done

# 7. Compile kernel 4.4 sdm660
export PATH="$CLANG_DIR:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="XtRs"
export KBUILD_BUILD_HOST="Lavender"

make O=out ARCH=arm64 "$DEFCONFIG"

make -j"$(nproc --all)" O=out \
    ARCH=arm64 \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    KCFLAGS="-Wno-error"
