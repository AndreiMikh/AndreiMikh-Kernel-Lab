#!/usr/bin/env bash
set -Eeuo pipefail

# FakePatches.sh
# Usage: ./FakePatches.sh <Apply|PostFix|Revert> [WorkDir]
# KERNELMODULE and SUBLEVEL are read from the environment.
#
# Python 3 is used for the line/regex editing primitives so Kotlin Regex and
# line-oriented file-editing behavior can be preserved reliably from Bash.

exec python3 - "$@" <<'PY'
import os
import re
import sys
from pathlib import Path

def fail(message):
    raise RuntimeError(message)

def require_exists(path):
    if not path.exists():
        fail(f"Required file does not exist: {path}")

def read_lines(path):
    return path.read_text().splitlines()

def write_lines(path, lines):
    path.write_text("\n".join(lines) + "\n")

def rel(path):
    value = str(path)
    return value.removeprefix(work_dir + "/").removeprefix(work_dir + "\\")

def insert_after_first(path, anchor, *new_lines):
    require_exists(path)
    lines = read_lines(path)
    if all(line in lines for line in new_lines):
        return False
    index = next((i for i, line in enumerate(lines) if anchor.search(line)), -1)
    if index < 0:
        fail(f"Anchor Not Found in {path}: {anchor.pattern}")
    lines[index + 1:index + 1] = new_lines
    write_lines(path, lines)
    return True

def insert_after(path, anchor, *new_lines):
    require_exists(path)
    lines = read_lines(path)
    changed = False
    for i in range(len(lines) - 1, -1, -1):
        if anchor.search(lines[i]):
            already_present = all(line in lines for line in new_lines)
            if not already_present:
                lines[i + 1:i + 1] = new_lines
                changed = True
    if not changed and not all(line in lines for line in new_lines):
        fail(f"Anchor Not Found in {path}: {anchor.pattern}")
    if changed:
        write_lines(path, lines)
    return changed

def insert_before_first(path, anchor, *new_lines):
    require_exists(path)
    lines = read_lines(path)
    if all(line in lines for line in new_lines):
        return False
    index = next((i for i, line in enumerate(lines) if anchor.search(line)), -1)
    if index < 0:
        fail(f"Anchor Not Found in {path}: {anchor.pattern}")
    lines[index:index] = new_lines
    write_lines(path, lines)
    return True

def delete_line(path, pattern):
    require_exists(path)
    lines = read_lines(path)
    filtered = [line for line in lines if not pattern.search(line)]
    if len(filtered) == len(lines):
        return False
    write_lines(path, filtered)
    return True

def delete_line_and_following(path, pattern, extra_lines):
    require_exists(path)
    source = read_lines(path)
    out, skip, changed = [], 0, False
    for line in source:
        if skip > 0:
            skip -= 1
            changed = True
            continue
        if pattern.search(line):
            skip = extra_lines
            changed = True
            continue
        out.append(line)
    if changed:
        write_lines(path, out)
    return changed

def delete_block(path, start, end):
    require_exists(path)
    source = read_lines(path)
    out, in_block, changed = [], False, False
    for line in source:
        if not in_block and start.search(line):
            in_block, changed = True, True
            continue
        if in_block:
            if end.search(line):
                in_block = False
            continue
        out.append(line)
    if in_block:
        fail(f"Unterminated Delete Block In {path}: {start.pattern}")
    if changed:
        write_lines(path, out)
    return changed

def replace_each_line(path, pattern, replacement):
    require_exists(path)
    source = read_lines(path)
    out, changed = [], False
    for line in source:
        replaced = pattern.sub(replacement, line)
        changed |= replaced != line
        out.append(replaced)
    if changed:
        write_lines(path, out)
    return changed

def replace_whole_line(path, old_line, new_line):
    require_exists(path)
    source = read_lines(path)
    changed = False
    out = []
    for line in source:
        if line == old_line:
            changed = True
            out.append(new_line)
        else:
            out.append(line)
    if changed:
        write_lines(path, out)
    return changed

def log_apply(path, detail): print(f"[APPLY]   {rel(path)} | {detail}")
def log_postfix(path, detail): print(f"[POSTFIX] {rel(path)} | {detail}")
def log_revert(path, detail): print(f"[REVERT]  {rel(path)} | {detail}")
def log_skip(path, detail): print(f"[SKIP]    {rel(path)} | {detail}")

kernel_module = os.getenv("KERNELMODULE", "")
try:
    sublevel = int(os.getenv("SUBLEVEL", "0"))
except ValueError:
    sublevel = 0
mode = sys.argv[1] if len(sys.argv) > 1 else "Apply"
work_dir = sys.argv[2] if len(sys.argv) > 2 else "kernel_workspace/kernel_platform/common"

def f(relative):
    return Path(work_dir) / relative

fdinfo_comment_start = re.compile(r"^[ \t]*/\*$")
fdinfo_comment_end = re.compile(r"^[ \t]*u32 mask = mark->mask & IN_ALL_EVENTS;$")
inotify_fdinfo_func_anchor = re.compile(r"^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$")
inotify_helper = [
    "static inline u32 inotify_mark_user_mask(struct fsnotify_mark *mark)",
    "{",
    "\treturn mark->mask & IN_ALL_EVENTS;",
    "}",
    "",
]

def add_inotify_mark_user_mask_function(path):
    if "inotify_mark_user_mask(" in path.read_text():
        log_skip(path, "INOTIFY-MARK-USER-MASK() Already Present")
        return
    insert_before_first(path, inotify_fdinfo_func_anchor, *inotify_helper)
    log_apply(path, "Inserted INOTIFY-MARK-USER-MASK() Helper Before INOTIFY-FDINFO()")

def apply_fdinfo(path):
    require_exists(path)
    content = path.read_text()
    if "inotify_mark_user_mask(" in content:
        log_skip(path, "FDINFO Patch Already Applied")
        return
    if "mask, mark.ignored_mask" not in content:
        fail(f"Expected FDINFO Mask Expression Not Found in {path}")
    delete_block(path, fdinfo_comment_start, fdinfo_comment_end)
    log_apply(path, "Removed Inline Mask-Calculation Comment Block")
    replace_each_line(path, re.compile(r"\bmask,\s*mark\.ignored_mask"), "inotify_mark_user_mask(mark)")
    log_apply(path, "Replaced Mask Argument With INOTIFY-MARK-USER-MASK(MARK)")
    replace_each_line(path, re.compile(r"ignored_mask:%x"), "ignored_mask:0")
    log_apply(path, "Replaced IGNORED-MASK:%X With IGNORED-MASK:0")
    add_inotify_mark_user_mask_function(path)

def revert_fdinfo(path):
    if not path.exists():
        log_skip(path, "FDINFO File Does Not Exist")
        return
    content = path.read_text()
    if "inotify_mark_user_mask(" not in content and "ignored_mask:0" not in content:
        log_skip(path, "FDINFO Patch Not Present")
        return
    replace_each_line(path, re.compile(r"inotify_mark_user_mask\(mark\)"), "mask")
    replace_each_line(path, re.compile(r"ignored_mask:0"), "ignored_mask:%x")
    delete_block(path, re.compile(r"^static inline u32 inotify_mark_user_mask\(struct fsnotify_mark \*mark\)$"), re.compile(r"^\}$"))
    log_revert(path, "Restored Original FDINFO Mask Handling")

def apply_android15_vma_block(task_mmu, namespace):
    require_exists(task_mmu)
    require_exists(namespace)
    content = task_mmu.read_text()
    if "unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;" in content:
        log_skip(task_mmu, "Android 15 VMA Patch Already Applied")
        return
    insert_after_first(task_mmu, re.compile(r"smap_gather_stats\(vma, &mss, last_vma_end\);"), "last_vma_end = vma->vm_end;")
    log_apply(task_mmu, "Inserted LAST-VMA-END Update After SMAPGATHERSTATS()")
    lines = read_lines(task_mmu)
    update_index = max((i for i, line in enumerate(lines) if "last_vma_end = vma->vm_end;" in line), default=-1)
    if update_index < 0: fail("Unable to Locate Inserted LAST-VMA-END Assignment")
    if_index = next((i for i in range(update_index - 1, -1, -1) if re.search(r"if\s*\(vma->vm_end > last_vma_end\)", lines[i])), None)
    if if_index is None: fail("Unable to Locate VMA-END Comparison")
    lines[if_index] = re.sub(r"\)\s*$", ") {", lines[if_index])
    lines[update_index] = "\t\t\t\t" + lines[update_index].lstrip()
    lines.insert(update_index + 1, "\t\t\t}")
    write_lines(task_mmu, lines)
    log_apply(task_mmu, "Wrapped LAST-VMA-END Update in Conditional Block")
    insert_after_first(namespace, re.compile(r"#include <trace/hooks/blk\.h>"), "#include <trace/hooks/fs.h>")
    log_apply(namespace, "Added TRACE/HOOKS/FS.H Include")
    insert_after_first(task_mmu, re.compile(r"int ret = 0, copied = 0;"), "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;", "\tpagemap_entry_t *res = NULL;")
    log_apply(task_mmu, "Added NR-SUBPAGES and PAGEMAP-ENTRY-T Declarations")

def revert_android15_vma_block(task_mmu, namespace):
    if not task_mmu.exists() or not namespace.exists():
        return
    delete_line(namespace, re.compile(r"^#include <trace/hooks/fs\.h>$"))
    delete_line(task_mmu, re.compile(r"^\s*unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;$"))
    delete_line(task_mmu, re.compile(r"^\s*pagemap_entry_t \*res = NULL;$"))
    delete_line(task_mmu, re.compile(r"^\s*last_vma_end = vma->vm_end;$"))
    replace_each_line(task_mmu, re.compile(r"if\s*\(vma->vm_end > last_vma_end\)\s*\{$"), "if (vma->vm_end > last_vma_end)")
    lines = read_lines(task_mmu)
    removed, out = False, []
    for line in lines:
        if not removed and line.strip() == "}" and any("if (vma->vm_end > last_vma_end)" in old for old in out):
            removed = True
            continue
        out.append(line)
    write_lines(task_mmu, out)
    log_revert(task_mmu, "Restored Original Android 15 VMA Block")
    log_revert(namespace, "Removed TRACE/HOOKS/FS.H Include")

def apply_post_patch_fixups():
    task_mmu = f("fs/proc/task_mmu.c")
    if task_mmu.exists():
        content = task_mmu.read_text()
        if ("VMA_PAD_START(" in content and
            not re.search(r"#include <linux/pgsize_migration(_inline)?\.h>", content) and
            not re.search(r"^\s*#define\s+VMA_PAD_START", content, re.M)):
            lines = read_lines(task_mmu)
            lines[1:1] = ["#ifndef VMA_PAD_START", "#define VMA_PAD_START(vma) ((vma)->vm_end)", "#endif"]
            write_lines(task_mmu, lines)
            log_postfix(task_mmu, "Inserted VMA-PAD-START() Fallback")
        content = task_mmu.read_text()
        if "__fold_filemap_fixup_entry(" in content and not re.search(r"static\s+inline\s+void\s+__fold_filemap_fixup_entry", content):
            header_file = f("include/linux/page_size_compat.h")
            header_declares_fn = header_file.exists() and "__fold_filemap_fixup_entry" in header_file.read_text()
            if header_declares_fn:
                if "#include <linux/page_size_compat.h>" not in content:
                    insert_after_first(task_mmu, re.compile(r"^#include "), "#include <linux/page_size_compat.h>")
                    log_postfix(task_mmu, "Added PAGE-SIZE-COMPAT.H Include")
            else:
                lines = read_lines(task_mmu)
                last_include = max((i for i, line in enumerate(lines) if line.lstrip().startswith("#include")), default=-1)
                insert_at = last_include + 1 if last_include >= 0 else 1
                lines[insert_at:insert_at] = ["#ifndef __fold_filemap_fixup_entry", "static inline void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end) { }", "#endif /* __fold_filemap_fixup_entry */"]
                write_lines(task_mmu, lines)
                log_postfix(task_mmu, "Inserted FOLD-FILEMAP-FIXUP-ENTRY() Stub")
    if kernel_module in ("android12-5.10", "android13-5.10"):
        namei = f("fs/namei.c")
        if namei.exists() and "set_nameidata(nd, old_dfd, fake_filename, NULL)" in namei.read_text():
            replace_each_line(namei, re.compile(r"set_nameidata\(nd, old_dfd, fake_filename, NULL\)"), "set_nameidata(nd, old_dfd, fake_filename)")
            log_postfix(namei, "Rewrote 4-Arg SET-NAMEIDATA() to 3-Arg Form")
    if kernel_module == "android16-6.12":
        open_c = f("fs/open.c")
        if open_c.exists() and "getname_flags(filename, lookup_flags, NULL)" in open_c.read_text():
            replace_each_line(open_c, re.compile(r"getname_flags\(filename, lookup_flags, NULL\)"), "getname_flags(filename, lookup_flags)")
            log_postfix(open_c, "Rewrote 3-Arg GETNAME-FLAGS() to 2-Arg Form")

def apply():
    if kernel_module == "android12-5.10":
        if sublevel <= 43:
            path = f("fs/proc/base.c")
            replace_each_line(path, re.compile(r"(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,"), "size_t this_len = min_t(size_t,")
            log_apply(path, "Normalized THIS-LEN/MIN-T() to SIZE-T")
        if sublevel <= 117: apply_fdinfo(f("fs/notify/fdinfo.c"))
    if kernel_module == "android13-5.10" and sublevel <= 107:
        apply_fdinfo(f("fs/notify/fdinfo.c"))
    if kernel_module == "android13-5.15":
        if sublevel <= 41:
            namespace = f("fs/namespace.c")
            insert_after_first(namespace, re.compile(r"^#include <linux/shmem_fs\.h>$"), "#include <linux/mnt_idmapping.h>")
            log_apply(namespace, "Added LINUX/MNT-IDMAPPING.H Include")
            open_c = f("fs/open.c")
            insert_after_first(open_c, re.compile(r"^#include <linux/compat\.h>$"), "#include <linux/mnt_idmapping.h>")
            log_apply(open_c, "Added LINUX/MNT-IDMAPPING.H Include")
            apply_fdinfo(f("fs/notify/fdinfo.c"))
        if sublevel >= 123:
            memory = f("mm/memory.c")
            if delete_line(memory, re.compile(r"#include <linux/swap_slots\.h>")): log_apply(memory, "Removed LINUX/SWAP-SLOTS.H")
        if sublevel >= 197:
            namespace = f("fs/namespace.c")
            if delete_line(namespace, re.compile(r"^#include <trace/hooks/blk\.h>$")): log_apply(namespace, "Removed TRACE/HOOKS/BLK.H")
        if sublevel >= 206:
            task_mmu = f("fs/proc/task_mmu.c")
            if delete_line(task_mmu, re.compile(r"^#include <trace/hooks/mm\.h>$")): log_apply(task_mmu, "Removed TRACE/HOOKS/MM.H")
    if kernel_module == "android14-6.1":
        if sublevel <= 25:
            base = f("fs/proc/base.c")
            insert_after_first(base, re.compile(r"^#include <trace/events/oom\.h>$"), "#include <trace/hooks/sched.h>")
            log_apply(base, "Added TRACE/HOOKS/SCHED.H")
        if sublevel <= 141:
            base = f("fs/proc/base.c")
            insert_after_first(base, re.compile(r"^#include <linux/cpufreq_times\.h>$"), "#include <linux/dma-buf.h>")
            log_apply(base, "Added LINUX/DMA-BUF.H")
        if sublevel >= 157:
            namespace = f("fs/namespace.c")
            if delete_line(namespace, re.compile(r"^#include <trace/hooks/blk\.h>$")): log_apply(namespace, "Removed TRACE/HOOKS/BLK.H")
            super_c = f("fs/super.c")
            if delete_line_and_following(super_c, re.compile(r"^#include <trace/hooks/fs\.h>$"), 1): log_apply(super_c, "Removed TRACE/HOOKS/FS.H And Following Line")
    if kernel_module == "android15-6.6":
        if sublevel <= 30: apply_android15_vma_block(f("fs/proc/task_mmu.c"), f("fs/namespace.c"))
        if sublevel <= 57:
            memory = f("mm/memory.c")
            insert_after_first(memory, re.compile(r"^#include <linux/sched/sysctl\.h>$"), "#include <linux/zswap.h>")
            log_apply(memory, "Added LINUX/ZSWAP.H")
        if sublevel <= 92:
            base = f("fs/proc/base.c")
            insert_after_first(base, re.compile(r"^#include <linux/cpufreq_times\.h>$"), "#include <linux/dma-buf.h>")
            log_apply(base, "Added LINUX/DMA-BUF.H")
    if kernel_module == "android16-6.12":
        if sublevel >= 58:
            exec_c = f("fs/exec.c")
            if delete_line(exec_c, re.compile(r"^#include <linux/dma-buf\.h>$")): log_apply(exec_c, "Removed LINUX/DMA-BUF.H")
        if sublevel >= 69:
            task_mmu = f("fs/proc/task_mmu.c")
            if replace_each_line(task_mmu, re.compile(r"vma_data_pages"), "vma_pages"): log_apply(task_mmu, "Renamed VMA-DATA-PAGES To VMA-PAGES")

def postfix():
    apply_post_patch_fixups()

def revert():
    if kernel_module == "android12-5.10":
        if sublevel <= 43:
            path = f("fs/proc/base.c")
            if replace_whole_line(path, "size_t this_len = min_t(size_t, count, PAGE_SIZE);", "int this_len = min_t(int, count, PAGE_SIZE);"):
                log_revert(path, "Restored INT THIS-LEN/MIN-T(INT)")
        if sublevel <= 117: revert_fdinfo(f("fs/notify/fdinfo.c"))
    if kernel_module == "android13-5.10" and sublevel <= 107: revert_fdinfo(f("fs/notify/fdinfo.c"))
    if kernel_module == "android13-5.15":
        if sublevel <= 41:
            namespace = f("fs/namespace.c")
            delete_line(namespace, re.compile(r"^#include <linux/mnt_idmapping\.h>$"))
            log_revert(namespace, "Removed LINUX/MNT-ID-MAPPING.H")
            open_c = f("fs/open.c")
            delete_line(open_c, re.compile(r"^#include <linux/mnt_idmapping\.h>$"))
            log_revert(open_c, "Removed LINUX/MNT-ID-MAPPING.H")
            susfs = f("fs/susfs.c")
            if susfs.exists():
                replace_each_line(susfs, re.compile(re.escape("i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val")), "i_uid_into_mnt(&init_user_ns, &fi->inode).val")
                replace_each_line(susfs, re.compile(re.escape("i_uid_into_mnt(i_user_ns(inode), inode).val")), "i_uid_into_mnt(&init_user_ns, inode).val")
                log_revert(susfs, "Restored SUSFS IUID-INTO-MNT() Form")
            revert_fdinfo(f("fs/notify/fdinfo.c"))
        if sublevel >= 123:
            memory = f("mm/memory.c")
            if "#include <linux/swap_slots.h>" not in memory.read_text():
                insert_before_first(memory, re.compile(r"#ifdef CONFIG_KSU_SUSFS_SUS_MAP"), "#include <linux/swap_slots.h>")
                log_revert(memory, "Restored LINUX/SWAP-SLOTS.H")
        if sublevel >= 197:
            namespace = f("fs/namespace.c")
            if "#include <trace/hooks/blk.h>" not in namespace.read_text():
                insert_after_first(namespace, re.compile(r'^#include "internal\.h"$'), "#include <trace/hooks/blk.h>")
                log_revert(namespace, "Restored TRACE/HOOKS/BLK.H")
        if sublevel >= 206:
            task_mmu = f("fs/proc/task_mmu.c")
            if "#include <trace/hooks/mm.h>" not in task_mmu.read_text():
                insert_after_first(task_mmu, re.compile(r"^#include <linux/pkeys\.h>$"), "#include <trace/hooks/mm.h>")
                log_revert(task_mmu, "Restored TRACE/HOOKS/MM.H")
    if kernel_module == "android14-6.1":
        if sublevel <= 25:
            base = f("fs/proc/base.c")
            delete_line(base, re.compile(r"^#include <trace/hooks/sched\.h>$"))
            log_revert(base, "Removed TRACE/HOOKS/SCHED.H")
        if sublevel <= 141:
            base = f("fs/proc/base.c")
            delete_line(base, re.compile(r"^#include <linux/dma-buf\.h>$"))
            log_revert(base, "Removed LINUX/DMA-BUF.H")
        if sublevel >= 157:
            namespace = f("fs/namespace.c")
            if "#include <trace/hooks/blk.h>" not in namespace.read_text():
                insert_after_first(namespace, re.compile(r'^#include "internal\.h"$'), "#include <trace/hooks/blk.h>")
            super_c = f("fs/super.c")
            if "#include <trace/hooks/fs.h>" not in super_c.read_text():
                insert_after_first(super_c, re.compile(r'^#include "internal\.h"$'), "#include <trace/hooks/fs.h>")
            log_revert(namespace, "Restored TRACE/HOOKS/BLK.H")
            log_revert(super_c, "Restored TRACE/HOOKS/FS.H")
    if kernel_module == "android15-6.6":
        if sublevel <= 30: revert_android15_vma_block(f("fs/proc/task_mmu.c"), f("fs/namespace.c"))
        if sublevel <= 57:
            memory = f("mm/memory.c")
            delete_line(memory, re.compile(r"^#include <linux/zswap\.h>$"))
            log_revert(memory, "Removed LINUX/ZSWAP.H")
        if sublevel <= 92:
            base = f("fs/proc/base.c")
            delete_line(base, re.compile(r"^#include <linux/dma-buf\.h>$"))
            log_revert(base, "Removed LINUX/DMABUF.H")
    if kernel_module == "android16-6.12":
        if sublevel >= 58:
            exec_c = f("fs/exec.c")
            if "#include <linux/dma-buf.h>" not in exec_c.read_text():
                insert_after_first(exec_c, re.compile(r"^#include "), "#include <linux/dma-buf.h>")
                log_revert(exec_c, "Restored LINUX/DMABUF.H")
        if sublevel >= 69:
            task_mmu = f("fs/proc/task_mmu.c")
            if "vma_pages" in task_mmu.read_text():
                replace_each_line(task_mmu, re.compile(r"vma_pages"), "vma_data_pages")
                log_revert(task_mmu, "Restored VMADATAPAGES")

try:
    if mode == "Apply":
        apply()
    elif mode == "PostFix":
        postfix()
    elif mode == "Revert":
        revert()
    else:
        print("Usage: FakePatches.sh <Apply|PostFix|Revert> [WorkDir]")
        sys.exit(1)
    print(f"🚀 Fake Patches: {mode} Completed (Android and Kernel Version = {kernel_module}, Sublevel = {sublevel})")
except Exception as exc:
    print(f"⚠️ Fake Patches Failed: {exc}", file=sys.stderr)
    sys.exit(1)
PY
