#!/usr/bin/env bash
set -eo pipefail

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

# 2. Integrasi BakaSU (salin langsung + folder uapi agar aman untuk O=out 4.4)
if [ ! -e "drivers/kernelsu" ]; then
    echo "[INFO] Mengkloning BakaSU dari $BAKASU_REPO (branch: $BAKASU_BRANCH)..."
    rm -rf KernelSU drivers/kernelsu
    git clone --depth=1 -b "$BAKASU_BRANCH" "$BAKASU_REPO" KernelSU

    if [ -d "KernelSU/kernel" ]; then
        cp -rf KernelSU/kernel drivers/kernelsu
    else
        cp -rf KernelSU drivers/kernelsu
    fi
    if [ -d "KernelSU/uapi" ]; then
        cp -rf KernelSU/uapi drivers/kernelsu/uapi
        [ ! -e "drivers/uapi" ] && cp -rf KernelSU/uapi drivers/uapi
    fi

    grep -q "drivers/kernelsu" drivers/Kconfig || sed -i '/endmenu/i source "drivers/kernelsu/Kconfig"' drivers/Kconfig
    grep -q "drivers/kernelsu" drivers/Makefile || echo 'obj-$(CONFIG_KSU) += kernelsu/' >> drivers/Makefile
fi

# 2b. Konversi Kbuild BakaSU (arm64), shim header, & tambalan LSM/VFS Linux 4.4.302
if [ -d "drivers/kernelsu" ]; then
    echo "[INFO] Menyesuaikan BakaSU untuk arsitektur arm64 dan API Linux 4.4.302..."
    DEFCONFIG_FILE="$DEFCONFIG_PATH" python3 - << 'EOF'
import os, pathlib, re, subprocess

ksu_dir = pathlib.Path("drivers/kernelsu")
kbuild_f = ksu_dir / "Kbuild"
makefile_f = ksu_dir / "Makefile"

# Buat shim header untuk header <linux/...> yang belum ada di kernel 4.4
shims = {
    "linux/pgtable.h": "#include <linux/mm.h>\n#include <asm/pgtable.h>\n",
    "linux/set_memory.h": "#include <asm/cacheflush.h>\n",
    "linux/sched/signal.h": "#include <linux/sched.h>\n",
    "linux/sched/task.h": "#include <linux/sched.h>\n",
    "linux/sched/mm.h": "#include <linux/sched.h>\n#include <linux/mm.h>\n",
    "linux/sched/user.h": "#include <linux/sched.h>\n",
    "linux/minmax.h": "#include <linux/kernel.h>\n",
    "linux/bits.h": "#include <linux/bitops.h>\n",
    "linux/build_bug.h": "#include <linux/bug.h>\n",
    "linux/stdarg.h": "#include <stdarg.h>\n",
    "linux/overflow.h": (
        "#include <linux/kernel.h>\n"
        "#ifndef struct_size\n"
        "#define struct_size(p, member, count) (sizeof(*(p)) + sizeof(*(p)->member) * (count))\n"
        "#endif\n"
    ),
}
for rel_h, body in shims.items():
    if not (pathlib.Path("include") / rel_h).exists():
        dst = ksu_dir / "include" / rel_h
        dst.parent.mkdir(parents=True, exist_ok=True)
        guard = "_KSU_SHIM_" + re.sub(r'[^A-Za-z0-9]', '_', rel_h).upper()
        dst.write_text(f"#ifndef {guard}\n#define {guard}\n{body}#endif\n")

# Deteksi otomatis simbol Kconfig untuk Manual Hook di BakaSU
manual_syms = set(["KSU_MANUAL_HOOK"])
disable_syms = set(["KSU_WITH_KPROBES", "KSU_TRACEPOINT_HOOK", "KSU_SUSFS", "KSU_LKM"])
for kc_file in ksu_dir.rglob("Kconfig*"):
    ktxt = kc_file.read_text(errors="ignore")
    for m in re.finditer(r'^\s*config\s+([A-Z0-9_]+)', ktxt, re.M):
        sym = m.group(1)
        if "MANUAL" in sym and "HOOK" in sym:
            manual_syms.add(sym)
        elif any(x in sym for x in ("KPROBE", "TRACEPOINT", "SUSFS", "LKM")):
            disable_syms.add(sym)

defcfg_p = pathlib.Path(os.environ["DEFCONFIG_FILE"])
dtxt = defcfg_p.read_text()
for sym in manual_syms | disable_syms:
    dtxt = re.sub(rf'^.*CONFIG_{sym}\b.*$\n?', '', dtxt, flags=re.M)
for sym in sorted(disable_syms):
    dtxt += f"\n# CONFIG_{sym} is not set"
for sym in sorted(manual_syms):
    dtxt += f"\nCONFIG_{sym}=y"
defcfg_p.write_text(dtxt + "\n")
print("[OK] Kconfig Manual Hook aktif:", ", ".join(sorted(manual_syms)))

# Baca Kbuild BakaSU sebelum dikonversi ke Makefile 4.4
raw = ""
if kbuild_f.exists():
    raw = kbuild_f.read_text()
    kbuild_f.unlink()
elif makefile_f.exists():
    raw = makefile_f.read_text()

raw = re.sub(r'\\\r?\n', ' ', raw)

# Jalankan aturan generator header (.h) dari Kbuild (seperti compat/syscall_no.h)
cmds = {}
for m in re.finditer(r'^\s*cmd_([A-Za-z0-9_]+)\s*:?=\s*(.+)$', raw, re.M):
    cmds[m.group(1)] = m.group(2).strip()

for m in re.finditer(r'^\s*([^\s:#]+\.h)\s*:\s*([^\n]+)', raw, re.M):
    target_raw = m.group(1).strip()
    deps_raw = m.group(2).strip()
    pos = m.end()
    recipe_lines = []
    for rline in raw[pos:].splitlines():
        if not rline.strip():
            continue
        if rline.startswith(("\t", " ")) and not rline.lstrip().startswith("#"):
            recipe_lines.append(rline.strip())
        else:
            break
    if not recipe_lines:
        continue

    def expand_vars(s, tgt, deps):
        first_dep = deps.split()[0] if deps.split() else ""
        s = s.replace("$@", tgt).replace("$<", first_dep).replace("$^", deps)
        s = s.replace("$(srctree)", ".").replace("$(objtree)", ".")
        s = s.replace("$(src)", "drivers/kernelsu").replace("$(obj)", "drivers/kernelsu")
        s = s.replace("$(SRCARCH)", "arm64").replace("$(ARCH)", "arm64")
        s = s.replace("$(CC)", "clang").replace("$(CPP)", "clang -E")
        s = s.replace("$(HOSTCC)", "gcc").replace("$(AWK)", "awk")
        s = s.replace("$(SED)", "sed").replace("$(PERL)", "perl")
        s = s.replace("$(PYTHON3)", "python3").replace("$(PYTHON)", "python3")
        return s

    tgt_path = expand_vars(target_raw, "", "")
    deps_exp = expand_vars(deps_raw, tgt_path, "")
    pathlib.Path(tgt_path).parent.mkdir(parents=True, exist_ok=True)

    for r in recipe_lines:
        cm = re.match(r'^\$\(call\s+(?:if_changed(?:_dep|_rule)?,)?cmd,([A-Za-z0-9_]+)\)', r)
        if cm and cm.group(1) in cmds:
            cmd_str = expand_vars(cmds[cm.group(1)], tgt_path, deps_exp)
        else:
            cmd_str = expand_vars(r.lstrip("@- "), tgt_path, deps_exp)
        subprocess.run(cmd_str, shell=True, check=False)

# Fallback jika compat/syscall_no.h belum terbuat atau kosong
sys_h = ksu_dir / "compat" / "syscall_no.h"
if not sys_h.exists() or sys_h.stat().st_size == 0:
    u32_map = {}
    u32_p = pathlib.Path("arch/arm64/include/asm/unistd32.h")
    if u32_p.exists():
        for line in u32_p.read_text(errors="ignore").splitlines():
            um = re.match(r'^\s*#\s*define\s+__NR_([A-Za-z0-9_]+)\s+(\d+)', line)
            if um:
                u32_map[um.group(1)] = um.group(2)
    u64_map = {}
    for up in [pathlib.Path("include/uapi/asm-generic/unistd.h"), pathlib.Path("arch/arm64/include/uapi/asm/unistd.h")]:
        if up.exists():
            for line in up.read_text(errors="ignore").splitlines():
                um = re.match(r'^\s*#\s*define\s+__NR(?:3264)?_([A-Za-z0-9_]+)\s+(\d+)', line)
                if um:
                    u64_map[um.group(1)] = um.group(2)

    lines = ["#ifndef __KSU_COMPAT_SYSCALL_NO_H", "#define __KSU_COMPAT_SYSCALL_NO_H", "#include <asm/unistd.h>"]
    for name, num in sorted(u32_map.items()):
        lines.append(f"#ifndef __NR_compat_{name}\n#define __NR_compat_{name} {num}\n#endif")
        lines.append(f"#ifndef KSU_COMPAT_NR_{name}\n#define KSU_COMPAT_NR_{name} {num}\n#endif")
    for name, num in sorted(u64_map.items()):
        lines.append(f"#ifndef __NR_{name}\n#define __NR_{name} {num}\n#endif")
    lines.append("#endif")
    sys_h.parent.mkdir(parents=True, exist_ok=True)
    sys_h.write_text("\n".join(lines) + "\n")
    print(f"[OK] Fallback syscall_no.h dibuat ({len(u32_map)} compat syscalls)")

# Susun daftar objek .o KHUSUS arsitektur arm64
active_lines = []
skip_stack = []
for line in raw.splitlines():
    s = line.strip()
    if not s or s.startswith("#"):
        continue
    if s.startswith(("ifeq ", "ifneq ", "ifdef ", "ifndef ")):
        low = s.lower()
        is_neg = s.startswith(("ifneq ", "ifndef "))
        if any(k in low for k in ("susfs", "lkm", "tracepoint", "kprobes", "syscall_hook", "inline_hook")):
            skip_stack.append(not is_neg)
        elif "manual" in low and "hook" in low:
            skip_stack.append(is_neg)
        elif any(k in low for k in ("config_arm64", "aarch64")):
            skip_stack.append(is_neg)
        elif any(k in low for k in ("config_arm", "config_x86", "config_riscv", "arm32", "x86_64", "riscv")):
            skip_stack.append(not is_neg)
        else:
            skip_stack.append(False)
        continue
    elif s == "else":
        if skip_stack:
            skip_stack[-1] = not skip_stack[-1]
        continue
    elif s == "endif":
        if skip_stack:
            skip_stack.pop()
        continue
    if not any(skip_stack):
        active_lines.append(s)

objs = []
for s in active_lines:
    if re.match(r'^(kernelsu-objs|kernelsu-y|obj-\$\(CONFIG_KSU\))\s*[:+]?=', s):
        part = s.split("=", 1)[1]
        for tok in part.split():
            tok = tok.replace("$(src)/", "").replace("$(obj)/", "")
            if not tok.endswith(".o") or tok == "kernelsu.o":
                continue
            if any(arch in tok.lower() for arch in ("x86", "arm32", "riscv", "hook/arm/")):
                continue
            if tok not in objs:
                objs.append(tok)

if not objs:
    for p in sorted(ksu_dir.rglob("*.c")):
        rel = p.relative_to(ksu_dir).as_posix()
        if any(x in rel.lower() for x in ("test", "example", "susfs", "lkm", "tracepoint", "kprobes", "x86", "arm32", "riscv", "hook/arm/")):
            continue
        objs.append(rel[:-2] + ".o")

obj_list = " \\\n\t".join(objs)
manual_defs = " ".join(f"-DCONFIG_{s}=1" for s in sorted(manual_syms))
mk = f"""# Kbuild 4.4 Makefile for BakaSU (arm64 only)
obj-$(CONFIG_KSU) += kernelsu.o
kernelsu-objs := {obj_list}

ccflags-y += -I$(srctree)/drivers/kernelsu
ccflags-y += -I$(srctree)/drivers/kernelsu/include
ccflags-y += -I$(srctree)/drivers/kernelsu/compat
ccflags-y += -I$(srctree)/drivers/kernelsu/core
ccflags-y += -I$(srctree)/drivers/kernelsu/feature
ccflags-y += -I$(srctree)/drivers/kernelsu/hook
ccflags-y += -I$(srctree)/drivers/kernelsu/hook/arm64
ccflags-y += -I$(srctree)/drivers/kernelsu/infra
ccflags-y += -I$(srctree)/drivers/kernelsu/manager
ccflags-y += -I$(srctree)/drivers/kernelsu/policy
ccflags-y += -I$(srctree)/drivers/kernelsu/runtime
ccflags-y += -I$(srctree)/drivers/kernelsu/selinux
ccflags-y += -I$(srctree)/drivers/kernelsu/supercall
ccflags-y += -I$(srctree)/drivers/kernelsu/uapi
ccflags-y += -I$(objtree)/drivers/kernelsu
ccflags-y += -I$(srctree)/KernelSU/kernel
ccflags-y += -I$(srctree)/KernelSU/kernel/include
ccflags-y += -I$(srctree)/KernelSU/uapi
ccflags-y += -I$(srctree)/security/selinux
ccflags-y += -I$(srctree)/security/selinux/include
ccflags-y += -I$(objtree)/security/selinux
ccflags-y += -I$(objtree)/security/selinux/include
ccflags-y += {manual_defs} -DKSU_MANUAL_HOOK=1
ccflags-y += -DKSU_GIT_VERSION=14762 -DKSU_VERSION=14762 -DKSU_VERSION_FULL=\\"v3.0.0-bakasu\\"
ccflags-y += -DEXPECTED_SIZE=0x033b -DEXPECTED_HASH=\\"0000000000000000000000000000000000000000000000000000000000000000\\"
ccflags-y += -Wno-implicit-function-declaration -Wno-strict-prototypes -Wno-int-conversion -Wno-gcc-compat
ccflags-y += -Wno-declaration-after-statement -Wno-unused-function -Wno-unused-variable -Wno-error
subdir-ccflags-y += $(ccflags-y)
"""
makefile_f.write_text(mk)
print(f"[OK] Makefile Kbuild 4.4 (arm64) dibuat ({len(objs)} objek)")

# Patch lsm_hook_magic.c agar memakai struct list_head (Linux 4.4) bukan struct hlist_head (4.17+)
lsm_h = pathlib.Path("include/linux/lsm_hooks.h").read_text(errors="ignore")
for lsm_file in ksu_dir.rglob("*lsm_hook_magic*.c"):
    ltxt = lsm_file.read_text(errors="ignore")
    if "hlist_node" not in lsm_h:
        ltxt = ltxt.replace("struct hlist_head", "struct list_head")
        ltxt = ltxt.replace("struct hlist_node", "struct list_head")
        ltxt = re.sub(
            r'hook->list\.list\.next\s*=\s*head->first\s*;',
            'list_add_tail_rcu(&hook->list.list, head);',
            ltxt
        )
        ltxt = re.sub(
            r'if\s*\(\s*head->first\s*\)\s*head->first->pprev\s*=\s*&hook->list\.list\.next\s*;',
            '',
            ltxt,
            flags=re.DOTALL
        )
        ltxt = re.sub(r'hook->list\.list\.pprev\s*=\s*&head->first\s*;', '', ltxt)
        ltxt = re.sub(
            r'(?:rcu_assign_pointer|WRITE_ONCE)\s*\(\s*head->first\s*,\s*&hook->list\.list\s*\)\s*;',
            '',
            ltxt
        )
        ltxt = re.sub(
            r'hlist_add_head_rcu\s*\(\s*&hook->list\.list\s*,\s*head\s*\)\s*;',
            'list_add_tail_rcu(&hook->list.list, head);',
            ltxt
        )
        ltxt = ltxt.replace("->head->first", "->head->next")
        ltxt = ltxt.replace("head->first", "head->next")
        ltxt = ltxt.replace("hlist_for_each_entry", "list_for_each_entry")
        ltxt = ltxt.replace("hlist_del_rcu", "list_del_rcu")
    if not re.search(r'\bchar\s*\*\s*lsm\b', lsm_h):
        ltxt = re.sub(r'^(\s*hook->list\.lsm\s*=.*)$', r'// [4.4-compat] \1', ltxt, flags=re.M)
    lsm_file.write_text(ltxt)
    print("[OK] lsm_hook_magic.c disesuaikan dengan struct list_head Linux 4.4")

# Pastikan variabel hook global tidak tertahan keyword 'static'
for cfile in ksu_dir.rglob("*.c"):
    ctxt = cfile.read_text(errors="ignore")
    new_ctxt = re.sub(
        r'\bstatic\s+(bool\s+ksu_(?:execveat|vfs_read|input)_hook\b)',
        r'\1',
        ctxt
    )
    if new_ctxt != ctxt:
        cfile.write_text(new_ctxt)

# Sesuaikan struct file_operations di file_wrapper.c dengan include/linux/fs.h kernel 4.4
fs_h = pathlib.Path("include/linux/fs.h").read_text(errors="ignore")
for fw_file in ksu_dir.rglob("*file_wrapper*.c"):
    ftxt = fw_file.read_text(errors="ignore")
    if "iterate_shared" not in fs_h:
        ftxt = ftxt.replace(".iterate_shared", ".iterate")
    for member in ("copy_file_range", "clone_file_range", "dedupe_file_range",
                   "remap_file_range", "fadvise", "uring_cmd", "uring_cmd_iopoll"):
        if member not in fs_h:
            ftxt = re.sub(rf'^(\s*\.{member}\s*=.*)$', r'// [4.4-compat] \1', ftxt, flags=re.M)
    fw_file.write_text(ftxt)
    print("[OK] file_wrapper.c disesuaikan dengan struct file_operations 4.4")

# Pindai seluruh header include/linux/*.h untuk mencegah redefinition di kernel_compat.h
existing_funcs = set()
for hdr in pathlib.Path("include/linux").glob("*.h"):
    try:
        htxt = hdr.read_text(errors="ignore")
        for m in re.finditer(r'\bstatic\s+(?:__always_)?inline\s+[^;\{]+?\b([a-zA-Z_]\w*)\s*\(', htxt):
            existing_funcs.add(m.group(1))
        for m in re.finditer(r'^\s*#\s*define\s+([a-zA-Z_]\w*)\s*\(', htxt, re.M):
            existing_funcs.add(m.group(1))
    except Exception:
        pass

kc_path = ksu_dir / "compat" / "kernel_compat.h"
if kc_path.exists():
    kc = kc_path.read_text()
    pat = re.compile(r'\bstatic\s+(?:__always_)?inline\s+[^;\{]+?\b([a-zA-Z_]\w*)\s*\([^;\{]*?\)\s*\{')
    out = []
    idx = 0
    removed = []
    while idx < len(kc):
        m = pat.search(kc, idx)
        if not m:
            out.append(kc[idx:])
            break
        fn_name = m.group(1)
        brace_start = m.end() - 1
        depth = 1
        j = brace_start + 1
        while j < len(kc) and depth > 0:
            if kc[j] == '{':
                depth += 1
            elif kc[j] == '}':
                depth -= 1
            j += 1
        if fn_name in existing_funcs:
            out.append(kc[idx:m.start()])
            out.append(f"/* [4.4.302-compat] {fn_name} sudah ada di header kernel */\n")
            removed.append(fn_name)
        else:
            out.append(kc[idx:j])
        idx = j
    kc_path.write_text("".join(out))
    print("[OK] Duplikat di kernel_compat.h dihapus:", ", ".join(removed) if removed else "tidak ada")
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
sed -i '/CONFIG_LOCALVERSION=/d;/CONFIG_LOCALVERSION_AUTO/d' "$DEFCONFIG_PATH"
echo 'CONFIG_LOCALVERSION="-XtrSolRadical"' >> "$DEFCONFIG_PATH"
echo '# CONFIG_LOCALVERSION_AUTO is not set' >> "$DEFCONFIG_PATH"

for cfg in \
    CONFIG_NOMOUNT=y \
    CONFIG_KSU=y \
    CONFIG_KALLSYMS=y \
    CONFIG_KALLSYMS_ALL=y \
    CONFIG_OVERLAY_FS=y; do
    grep -q "^$cfg" "$DEFCONFIG_PATH" || echo "$cfg" >> "$DEFCONFIG_PATH"
done

# 7. Compile kernel 4.4 sdm660 (tangkap baris error murni jika gagal)
export PATH="$CLANG_DIR:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="XtRs"
export KBUILD_BUILD_HOST="Lavender"

make O=out ARCH=arm64 "$DEFCONFIG"

if ! make -j"$(nproc --all)" O=out \
    ARCH=arm64 \
    CC=clang \
    CLANG_TRIPLE=aarch64-linux-gnu- \
    CROSS_COMPILE=aarch64-linux-gnu- \
    CROSS_COMPILE_ARM32=arm-linux-gnueabi- \
    KCFLAGS="-Wno-error" 2>&1 | tee /tmp/build.log; then
    echo "================ EXACT COMPILER ERRORS ================"
    grep -n -C 4 -E ":\s*(fatal )?error:" /tmp/build.log | tail -n 50 || true
    echo "======================================================="
    exit 1
fi
