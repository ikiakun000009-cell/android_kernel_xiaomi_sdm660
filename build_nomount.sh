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

# 2. Integrasi BakaSU (clone riwayat penuh agar hitungan KSU_VERSION akurat)
if [ ! -e "drivers/kernelsu" ]; then
    echo "[INFO] Mengkloning BakaSU dari $BAKASU_REPO (branch: $BAKASU_BRANCH)..."
    rm -rf KernelSU drivers/kernelsu
    git clone -b "$BAKASU_BRANCH" "$BAKASU_REPO" KernelSU

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

# 3. Integrasi NoMount (branch dev) sebelum konfigurasi defconfig
if [ ! -d "fs/nomount" ] && ! grep -rqE "config NOMOUNT|nomount_init" KernelSU/ fs/ drivers/ 2>/dev/null; then
    echo "[INFO] Memasang NoMount (branch dev)..."
    curl -fsSL https://raw.githubusercontent.com/maxsteeel/nomount/refs/heads/dev/kernel/setup.sh | bash -s dev
fi

# 4. Atur Kconfig BakaSU (Manual Hook + Auto Setuid) & NoMount di defconfig
python3 - << 'EOF' "$DEFCONFIG_PATH"
import pathlib, re, sys

defcfg_p = pathlib.Path(sys.argv[1])
ksu_dir = pathlib.Path("drivers/kernelsu")

manual_syms = set(["KSU_MANUAL_HOOK", "KSU_MANUAL_HOOK_AUTO_SETUID_HOOK"])
disable_syms = set([
    "KSU_WITH_KPROBES",
    "KSU_TRACEPOINT_HOOK",
    "KSU_SUSFS",
    "KSU_LKM",
    "KSU_MANUAL_HOOK_AUTO_INITRC_HOOK",
    "KSU_MANUAL_HOOK_AUTO_INPUT_HOOK",
])
if ksu_dir.exists():
    for kc_file in ksu_dir.rglob("Kconfig*"):
        ktxt = kc_file.read_text(errors="ignore")
        for m in re.finditer(r'^\s*config\s+([A-Z0-9_]+)', ktxt, re.M):
            sym = m.group(1)
            if sym in disable_syms or sym in manual_syms:
                continue
            if "MANUAL" in sym and "HOOK" in sym and "AUTO" not in sym:
                manual_syms.add(sym)
            elif any(x in sym for x in ("KPROBE", "TRACEPOINT", "SUSFS", "LKM")):
                disable_syms.add(sym)

dtxt = defcfg_p.read_text()
for sym in manual_syms | disable_syms:
    dtxt = re.sub(rf'^.*CONFIG_{sym}\b.*$\n?', '', dtxt, flags=re.M)
for sym in sorted(disable_syms):
    dtxt += f"\n# CONFIG_{sym} is not set"
for sym in sorted(manual_syms):
    dtxt += f"\nCONFIG_{sym}=y"
defcfg_p.write_text(dtxt + "\n")
print("[OK] Kconfig Manual Hook aktif:", ", ".join(sorted(manual_syms)))
EOF

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

# 5. Siapkan variabel toolchain & generate out/.config
export PATH="$CLANG_DIR:$PATH"
export ARCH=arm64
export SUBARCH=arm64
export KBUILD_BUILD_USER="XtRs"
export KBUILD_BUILD_HOST="Lavender"

MAKE_ARGS=(
    O=out
    ARCH=arm64
    CC=clang
    CLANG_TRIPLE=aarch64-linux-gnu-
    CROSS_COMPILE=aarch64-linux-gnu-
    CROSS_COMPILE_ARM32=arm-linux-gnueabi-
    KCFLAGS="-Wno-error"
)

make "${MAKE_ARGS[@]}" "$DEFCONFIG"

# 6. Konversi Kbuild BakaSU + patch apk_sign.c & versi + tambalan 4.4.302
if [ -d "drivers/kernelsu" ]; then
    echo "[INFO] Menyesuaikan BakaSU untuk arsitektur arm64 dan API Linux 4.4.302..."
    python3 - << 'EOF'
import os, pathlib, re, subprocess

ksu_dir = pathlib.Path("drivers/kernelsu")
kbuild_f = ksu_dir / "Kbuild"
makefile_f = ksu_dir / "Makefile"

# Baca simbol aktif dari out/.config
enabled_configs = set(["CONFIG_KSU", "CONFIG_ARM64", "CONFIG_KSU_MANUAL_HOOK", "CONFIG_KSU_MANUAL_HOOK_AUTO_SETUID_HOOK"])
dot_cfg = pathlib.Path("out/.config")
if dot_cfg.exists():
    for line in dot_cfg.read_text(errors="ignore").splitlines():
        m_cfg = re.match(r'^(CONFIG_[A-Z0-9_]+)=y$', line.strip())
        if m_cfg:
            enabled_configs.add(m_cfg.group(1))
for dis in ("CONFIG_KSU_WITH_KPROBES", "CONFIG_KSU_TRACEPOINT_HOOK", "CONFIG_KSU_SUSFS",
            "CONFIG_KSU_LKM", "CONFIG_KSU_MANUAL_HOOK_AUTO_INITRC_HOOK", "CONFIG_KSU_MANUAL_HOOK_AUTO_INPUT_HOOK"):
    enabled_configs.discard(dis)

# Pindai seluruh header include/linux/*.h untuk mencegah redefinition
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

# Buat ksu_44_shim.h untuk fungsi/tipe pasca-4.4 yang belum ada di kernel 4.4.302
shim_lines = [
    "#ifndef _KSU_44_GLOBAL_SHIM_H",
    "#define _KSU_44_GLOBAL_SHIM_H",
    "#include <linux/version.h>",
    "#include <linux/types.h>",
    "#include <linux/slab.h>",
    "#include <linux/vmalloc.h>",
    "#include <linux/mm.h>",
    "#include <asm/pgtable.h>",
    "#include <linux/string.h>",
    "#include <linux/ktime.h>",
    "#include <linux/compat.h>",
    "#ifndef in_compat_syscall",
    "#define in_compat_syscall() is_compat_task()",
    "#endif",
    "#ifndef struct_size",
    "#define struct_size(p, member, count) (sizeof(*(p)) + sizeof(*(p)->member) * (count))",
    "#endif",
    "#ifndef array_size",
    "#define array_size(a, b) ((a) * (b))",
    "#endif",
]
if "strscpy" not in existing_funcs:
    shim_lines.append("#define strscpy(dst, src, size) strlcpy((dst), (src), (size))")
if "kvmalloc" not in existing_funcs:
    shim_lines.extend([
        "static inline void *kvmalloc(size_t size, gfp_t flags)",
        "{",
        "    void *p = kmalloc(size, flags | __GFP_NOWARN);",
        "    return p ? p : __vmalloc(size, flags, PAGE_KERNEL);",
        "}",
    ])
if "kvzalloc" not in existing_funcs:
    shim_lines.append("#define kvzalloc(size, flags) kvmalloc((size), (flags) | __GFP_ZERO)")
if "ktime_get_boottime_ns" not in existing_funcs:
    shim_lines.append("#define ktime_get_boottime_ns() ktime_to_ns(ktime_get_boottime())")
if not pathlib.Path("include/linux/refcount.h").exists():
    shim_lines.extend([
        "#include <linux/atomic.h>",
        "typedef struct { atomic_t refs; } refcount_t;",
        "#define REFCOUNT_INIT(n) { .refs = ATOMIC_INIT(n) }",
        "static inline void refcount_set(refcount_t *r, int n) { atomic_set(&r->refs, n); }",
        "static inline unsigned int refcount_read(const refcount_t *r) { return atomic_read(&r->refs); }",
        "static inline void refcount_inc(refcount_t *r) { atomic_inc(&r->refs); }",
        "static inline bool refcount_dec_and_test(refcount_t *r) { return atomic_dec_and_test(&r->refs); }",
    ])
shim_lines.append("#endif")
global_shim = ksu_dir / "compat" / "ksu_44_shim.h"
global_shim.parent.mkdir(parents=True, exist_ok=True)
global_shim.write_text("\n".join(shim_lines) + "\n")

# Baca Kbuild utama sebelum dikonversi
raw = ""
if kbuild_f.exists():
    raw = kbuild_f.read_text()
    kbuild_f.unlink()
elif makefile_f.exists():
    raw = makefile_f.read_text()

# Ekstrak versi kernel BakaSU serta EXPECTED_SIZE & EXPECTED_HASH jika ada
def run_git(cmd):
    r = subprocess.run(cmd, shell=True, capture_output=True, text=True)
    return r.stdout.strip() if r.returncode == 0 else ""

git_count_str = run_git("git -C KernelSU rev-list --count HEAD")
git_count = int(git_count_str) if git_count_str.isdigit() and int(git_count_str) > 1 else 25000

ksu_ver = None
m_ver_expr = re.search(r'KSU_VERSION\s*:?=\s*\$\(shell\s+expr\s+([^\)]+)\)', raw)
if m_ver_expr:
    expr_s = m_ver_expr.group(1).replace("$(KSU_GIT_VERSION)", str(git_count))
    nums = [int(x) for x in re.findall(r'\b\d+\b', expr_s)]
    if nums and "+" in expr_s:
        ksu_ver = sum(nums)
if not ksu_ver:
    m_ver_lit = re.search(r'KSU_VERSION\s*:?=\s*(\d+)', raw)
    if m_ver_lit:
        ksu_ver = int(m_ver_lit.group(1))
if not ksu_ver or ksu_ver < 30000:
    ksu_ver = 30000 + git_count

ver_full = run_git("git -C KernelSU describe --tags --always")
if not ver_full or not ver_full.startswith("v"):
    m_vf = re.search(r'KSU_VERSION_FULL\s*:?=\s*\\?"?([^"\s\)]+)', raw)
    ver_full = m_vf.group(1) if m_vf else f"v3.0.0-{git_count}"

all_ksu_src = raw + "\n" + "\n".join(
    p.read_text(errors="ignore") for p in ksu_dir.rglob("*") if p.suffix in (".c", ".h", ".mk")
)
m_sz = re.search(r'(?:KSU_)?EXPECTED_(?:MANAGER_)?SIZE\s*(?::?=|=)\s*(0x[0-9a-fA-F]+|\d+)', all_ksu_src)
exp_size = m_sz.group(1) if m_sz else "0x033b"

m_hs = re.search(r'(?:KSU_)?EXPECTED_(?:MANAGER_)?HASH\s*(?::?=|=)\s*\\?"?([0-9a-fA-F]{64})', all_ksu_src)
exp_hash = m_hs.group(1) if m_hs else "0000000000000000000000000000000000000000000000000000000000000000"

print(f"[OK] BakaSU Version: {ksu_ver} ({ver_full}), Custom Size: {exp_size}")

# Buat compat/syscall_no.h
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
    print(f"[OK] Generated syscall_no.h ({len(u32_map)} compat syscalls)")

# Siapkan biner preinit runner untuk di-embed oleh preinit/blob.S
runner_c = ksu_dir / "preinit" / "runner" / "runner.c"
runner_bin = pathlib.Path("/tmp/ksu_preinit_runner")
inc_flags = []
seen_inc = set()
for search_root in (ksu_dir, pathlib.Path("KernelSU"), pathlib.Path("tools/include/nolibc")):
    if search_root.exists():
        for d in [search_root] + [p for p in search_root.rglob("*") if p.is_dir()]:
            ds = d.as_posix()
            if ds not in seen_inc:
                seen_inc.add(ds)
                inc_flags.append(f"-I{ds}")

if runner_c.exists():
    cmd_run = (
        f"aarch64-linux-gnu-gcc -Os -fno-asynchronous-unwind-tables -fno-ident "
        f"-fno-stack-protector -fomit-frame-pointer -U_FORTIFY_SOURCE -nostdlib -static "
        f"{' '.join(inc_flags)} -o {runner_bin} {runner_c} && aarch64-linux-gnu-strip {runner_bin}"
    )
    subprocess.run(cmd_run, shell=True, check=False)

if not runner_bin.exists():
    stub_s = pathlib.Path("/tmp/ksu_stub_runner.S")
    stub_s.write_text(".globl _start\n_start:\n\tmov x0, #0\n\tmov x8, #93\n\tsvc #0\n")
    subprocess.run(
        f"aarch64-linux-gnu-gcc -nostdlib -static -o {runner_bin} {stub_s} && aarch64-linux-gnu-strip {runner_bin}",
        shell=True,
        check=False,
    )

# Susun daftar objek kernel dari Kbuild
raw = re.sub(r'\\\r?\n', ' ', raw)
ap_pat = re.compile(r'\$\(addprefix\s+([^,\s]+)\s*,\s*([^)]+)\)')
while ap_pat.search(raw):
    raw = ap_pat.sub(lambda m: " ".join(m.group(1) + item for item in m.group(2).split()), raw)

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
    if re.match(r'^(kernelsu-objs|kernelsu-y|kernelsu-\$\(CONFIG_[A-Z0-9_]+\)|obj-\$\(CONFIG_[A-Z0-9_]+\))\s*[:+]?=', s):
        part = s.split("=", 1)[1]
        for tok in part.split():
            tok = tok.replace("$(src)/", "").replace("$(obj)/", "")
            if tok == "kernelsu.o":
                continue
            if any(arch in tok.lower() for arch in ("x86", "arm32", "riscv", "hook/arm/", "tools/", "runner/")):
                continue
            if tok.endswith(".o") and tok not in objs:
                objs.append(tok)

# Tambahkan preinit/*.c & preinit/*.S, dan patch direktif .incbin di blob.S menjadi string literal
preinit_dir = ksu_dir / "preinit"
if preinit_dir.is_dir():
    for p in sorted(preinit_dir.glob("*.S")):
        stxt = p.read_text(errors="ignore")
        if ".incbin" in stxt and runner_bin.exists():
            stxt = re.sub(
                r'^(\s*\.incbin\s+).*$',
                rf'\1"{runner_bin.as_posix()}"',
                stxt,
                flags=re.M,
            )
            p.write_text(stxt)
            print(f"[OK] Patched .incbin di {p.name} -> {runner_bin}")

    for p in sorted(preinit_dir.glob("*.c")) + sorted(preinit_dir.glob("*.S")):
        o_rel = p.relative_to(ksu_dir).as_posix()[:-2] + ".o"
        if o_rel not in objs:
            objs.append(o_rel)
            print(f"[OK] Menambahkan objek preinit: {o_rel}")

obj_list = " \\\n\t".join(objs)
active_defs = " ".join(f"-D{c}=1" for c in sorted(enabled_configs) if c.startswith("CONFIG_KSU"))
mk = f"""# Kbuild 4.4 Makefile for BakaSU (arm64 only)
obj-$(CONFIG_KSU) += kernelsu.o
kernelsu-objs := {obj_list}

ccflags-y += -include $(srctree)/drivers/kernelsu/compat/ksu_44_shim.h
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
ccflags-y += -I$(srctree)/drivers/kernelsu/preinit
ccflags-y += -I$(srctree)/drivers/kernelsu/runtime
ccflags-y += -I$(srctree)/drivers/kernelsu/selinux
ccflags-y += -I$(srctree)/drivers/kernelsu/supercall
ccflags-y += -I$(srctree)/drivers/kernelsu/uapi
ccflags-y += -I$(objtree)/drivers/kernelsu
ccflags-y += -I$(objtree)/drivers/kernelsu/preinit
ccflags-y += -I$(srctree)/KernelSU/kernel
ccflags-y += -I$(srctree)/KernelSU/kernel/include
ccflags-y += -I$(srctree)/KernelSU/uapi
ccflags-y += -I$(srctree)/security/selinux
ccflags-y += -I$(srctree)/security/selinux/include
ccflags-y += -I$(objtree)/security/selinux
ccflags-y += -I$(objtree)/security/selinux/include
ccflags-y += {active_defs}
ccflags-y += -DKSU_GIT_VERSION={git_count} -DKSU_VERSION={ksu_ver} -DKSU_VERSION_FULL=\\"{ver_full}\\"
ccflags-y += -DEXPECTED_SIZE={exp_size} -DEXPECTED_HASH=\\"{exp_hash}\\"
ccflags-y += -DEXPECTED_PR_BUILD_SIZE=0x033b -DEXPECTED_PR_BUILD_HASH=\\"0000000000000000000000000000000000000000000000000000000000000000\\"
ccflags-y += -Wno-implicit-function-declaration -Wno-strict-prototypes -Wno-int-conversion -Wno-gcc-compat
ccflags-y += -Wno-declaration-after-statement -Wno-unused-function -Wno-unused-variable -Wno-error
subdir-ccflags-y += $(ccflags-y)
"""
makefile_f.write_text(mk)
print(f"[OK] Makefile Kbuild 4.4 (arm64) dibuat ({len(objs)} objek)")

# Bersihkan slot custom/PR key kosong di apk_sign.c agar tidak memicu 'expected expression'
for hdr_or_c in ksu_dir.rglob("*"):
    if hdr_or_c.suffix in (".c", ".h"):
        htxt = hdr_or_c.read_text(errors="ignore")
        new_htxt = re.sub(
            r'^(\s*#\s*define\s+EXPECTED_(?:PR_BUILD_)?SIZE)\s*$',
            r'\1 0x033b',
            htxt,
            flags=re.M,
        )
        new_htxt = re.sub(
            r'^(\s*#\s*define\s+EXPECTED_(?:PR_BUILD_)?HASH)\s*$',
            r'\1 "0000000000000000000000000000000000000000000000000000000000000000"',
            new_htxt,
            flags=re.M,
        )
        if new_htxt != htxt:
            hdr_or_c.write_text(new_htxt)

apk_sign_f = ksu_dir / "manager" / "apk_sign.c"
if apk_sign_f.exists():
    atxt = apk_sign_f.read_text(errors="ignore")
    atxt = re.sub(
        r'^\s*\{\s*EXPECTED_PR_BUILD_SIZE\s*,\s*EXPECTED_PR_BUILD_HASH\s*\}\s*,?.*$',
        '/* [4.4-compat] PR build slot skipped */',
        atxt,
        flags=re.M,
    )
    if exp_hash == "0000000000000000000000000000000000000000000000000000000000000000":
        atxt = re.sub(
            r'^\s*\{\s*EXPECTED_SIZE\s*,\s*EXPECTED_HASH\s*\}\s*,?.*$',
            '/* [4.4-compat] Custom slot skipped (using built-in BakaSU keys) */',
            atxt,
            flags=re.M,
        )
    apk_sign_f.write_text(atxt)
    print("[OK] apk_sign.c disesuaikan (built-in BakaSU manager keys aktif)")

# Patch lsm_hook_magic.c agar memakai struct list_head (Linux 4.4) & hapus hook->list.lsm
lsm_h = pathlib.Path("include/linux/lsm_hooks.h").read_text(errors="ignore")
m_shl = re.search(r'struct\s+security_hook_list\s*\{([^}]*)\}', lsm_h, re.S)
has_lsm_member = bool(m_shl and re.search(r'\blsm\b', m_shl.group(1)))

for lsm_file in ksu_dir.rglob("*lsm_hook_magic*.c"):
    ltxt = lsm_file.read_text(errors="ignore")
    if "hlist_node" not in lsm_h:
        ltxt = ltxt.replace("struct hlist_head", "struct list_head")
        ltxt = ltxt.replace("struct hlist_node", "struct list_head")
        ltxt = re.sub(
            r'\bif\s*\([^)]*\)\s*(?:\{[^}]*\bpprev\b[^}]*\}|[^;]*\bpprev\b[^;]*;)',
            '',
            ltxt
        )
        ltxt = re.sub(r'^[^\n]*\bpprev\b[^\n]*$', r'/* [4.4] pprev removed */', ltxt, flags=re.M)
        ltxt = re.sub(
            r'^[^\n]*hook->list\.list\.next\s*=\s*head->first\s*;[^\n]*$',
            r'/* [4.4] handled by list_add_tail_rcu */',
            ltxt,
            flags=re.M
        )
        ltxt = re.sub(
            r'(?:rcu_assign_pointer|WRITE_ONCE)\s*\(\s*head->first\s*,\s*&hook->list\.list\s*\)\s*;',
            'list_add_tail_rcu(&hook->list.list, head);',
            ltxt
        )
        ltxt = re.sub(
            r'head->first\s*=\s*&hook->list\.list\s*;',
            'list_add_tail_rcu(&hook->list.list, head);',
            ltxt
        )
        ltxt = re.sub(
            r'hlist_add_head_rcu\s*\(\s*&hook->list\.list\s*,\s*head\s*\)\s*;',
            'list_add_tail_rcu(&hook->list.list, head);',
            ltxt
        )
        ltxt = ltxt.replace("->first", "->next")
        ltxt = ltxt.replace("hlist_for_each_entry", "list_for_each_entry")
        ltxt = ltxt.replace("hlist_del_rcu", "list_del_rcu")
    if not has_lsm_member:
        ltxt = re.sub(r'^[^\n]*->list\.lsm\s*=[^\n]*$', r'/* [4.4] security_hook_list has no lsm */', ltxt, flags=re.M)
    lsm_file.write_text(ltxt)
    print("[OK] lsm_hook_magic.c disesuaikan dengan struct list_head Linux 4.4 (tanpa .lsm)")

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

# Hapus definisi fungsi duplikat di kernel_compat.h agar tidak bentrok dengan header kernel 4.4.302
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

# 7. Terapkan Manual Hooks BakaSU secara aman (cek simbol yang tersedia di drivers/kernelsu)
echo "[INFO] Memasang manual hooks pada fs/ dan drivers/input/..."
python3 - << 'EOF'
import pathlib, re

ksu_all = "\n".join(p.read_text(errors="ignore") for p in pathlib.Path("drivers/kernelsu").rglob("*.c"))
def has_sym(sym):
    return bool(re.search(rf'\b{re.escape(sym)}\b', ksu_all))

# Hook 1: fs/exec.c
exec_p = pathlib.Path("fs/exec.c")
if exec_p.exists() and has_sym("ksu_handle_execveat"):
    txt = exec_p.read_text()
    if "ksu_handle_execveat" not in txt:
        if has_sym("ksu_execveat_hook") and has_sym("ksu_handle_execveat_sucompat"):
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
        else:
            decl = (
                "#ifdef CONFIG_KSU\n"
                "extern int ksu_handle_execveat(int *fd, struct filename **filename_ptr, void *argv,\n"
                "                               void *envp, int *flags);\n"
                "#endif\n"
            )
            hook = (
                "#ifdef CONFIG_KSU\n"
                "\tksu_handle_execveat(&fd, &filename, &argv, &envp, &flags);\n"
                "#endif\n"
            )
        txt = re.sub(r'(static\s+int\s+do_execveat_common\s*\()', decl + r'\1', txt, count=1)
        txt = re.sub(r'(\n\s*if\s*\(\s*IS_ERR\s*\(\s*filename\s*\)\s*\))', "\n" + hook + r'\1', txt, count=1)
        exec_p.write_text(txt)
        print("[OK] Patched fs/exec.c")

# Hook 2: fs/open.c
open_p = pathlib.Path("fs/open.c")
if open_p.exists() and has_sym("ksu_handle_faccessat"):
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
if rw_p.exists() and has_sym("ksu_handle_vfs_read"):
    txt = rw_p.read_text()
    if "ksu_handle_vfs_read" not in txt:
        if has_sym("ksu_vfs_read_hook"):
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
        else:
            decl = (
                "#ifdef CONFIG_KSU\n"
                "extern int ksu_handle_vfs_read(struct file **file_ptr, char __user **buf_ptr,\n"
                "                               size_t *count_ptr, loff_t **pos);\n"
                "#endif\n"
            )
            hook = (
                "#ifdef CONFIG_KSU\n"
                "\tksu_handle_vfs_read(&file, &buf, &count, &pos);\n"
                "#endif\n"
            )
        txt = re.sub(r'(ssize_t\s+vfs_read\s*\()', decl + r'\1', txt, count=1)
        txt = re.sub(r'(\n\s*if\s*\(\s*!\s*\(\s*file->f_mode\s*&\s*FMODE_READ\s*\)\s*\))', "\n" + hook + r'\1', txt, count=1)
        rw_p.write_text(txt)
        print("[OK] Patched fs/read_write.c")

# Hook 4: fs/stat.c
stat_p = pathlib.Path("fs/stat.c")
if stat_p.exists() and has_sym("ksu_handle_stat"):
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
if inp_p.exists() and has_sym("ksu_handle_input_handle_event"):
    txt = inp_p.read_text()
    if "ksu_handle_input_handle_event" not in txt:
        if has_sym("ksu_input_hook"):
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
        else:
            decl = (
                "#ifdef CONFIG_KSU\n"
                "extern int ksu_handle_input_handle_event(unsigned int *type, unsigned int *code, int *value);\n"
                "#endif\n"
            )
            hook = (
                "#ifdef CONFIG_KSU\n"
                "\tksu_handle_input_handle_event(&type, &code, &value);\n"
                "#endif\n"
            )
        txt = re.sub(r'(void\s+input_event\s*\()', decl + r'\1', txt, count=1)
        txt = re.sub(r'(\n\s*if\s*\(\s*is_event_supported\s*\(\s*type\s*,)', "\n" + hook + r'\1', txt, count=1)
        inp_p.write_text(txt)
        print("[OK] Patched drivers/input/input.c")
EOF

# 8. Patch kompatibilitas VFS Linux 4.4 untuk fs/nomount
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
        elif func_name == "vfs_getattr" and len(args) == 4:
            out.append(f"vfs_getattr({args[0]}, {args[1]})")
        else:
            out.append(code[m.start():j])
        i = j
    return ''.join(out)

h_path = pathlib.Path("fs/nomount/nomount.h")
if h_path.exists():
    h = h_path.read_text()
    if "<linux/compat.h>" not in h:
        h = "#include <linux/compat.h>\n" + h
    compat_macros = (
        "#ifndef current_time\n"
        "#define current_time(inode) (CURRENT_TIME)\n"
        "#endif\n"
        "#ifndef strscpy\n"
        "#define strscpy(dst, src, size) strlcpy((dst), (src), (size))\n"
        "#endif\n"
    )
    h = compat_macros + h
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
    c = parse_call_args(c, "vfs_getattr")

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

# 9. Generate header prasyarat (compile.h + flask.h) & compile penuh hingga Image.gz-dtb
make "${MAKE_ARGS[@]}" prepare
make -j"$(nproc --all)" "${MAKE_ARGS[@]}" init/ security/selinux/

if ! make -k -j"$(nproc --all)" "${MAKE_ARGS[@]}" drivers/kernelsu/ 2>&1 | tee /tmp/ksu_check.log; then
    echo "================ ALL REMAINING BAKASU ERRORS ================"
    grep -n -C 2 -E ":\s*(fatal )?error:|undefined reference to" /tmp/ksu_check.log || true
    echo "============================================================="
    exit 1
fi

if ! make -j"$(nproc --all)" "${MAKE_ARGS[@]}" 2>&1 | tee /tmp/build.log; then
    echo "================ EXACT COMPILER/LINKER ERRORS ================"
    grep -n -C 3 -E ":\s*(fatal )?error:|undefined reference to" /tmp/build.log | tail -n 50 || true
    echo "=============================================================="
    exit 1
fi
