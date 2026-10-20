#!/usr/bin/env python3
import os
import re
import sys
from pathlib import Path

# ==========================
# Environment
# ==========================
kernelModule = os.getenv("KERNELMODULE", "")
try:
    sublevel = int(os.getenv("SUBLEVEL", "0"))
except (TypeError, ValueError):
    sublevel = 0
mode = sys.argv[1] if len(sys.argv) > 1 else "Apply"
workDir = Path(sys.argv[2] if len(sys.argv) > 2 else "kernel_workspace/kernel_platform/common")


def f(relPath):
    return workDir / relPath


def regex(pattern):
    return re.compile(pattern)


# ==========================
# Basic File Helpers
# ==========================
def require_exists(path):
    if not path.exists():
        raise RuntimeError(f"Required file does not exist: {path}")


def lines(path):
    return path.read_text().splitlines()


def write_lines(path, content):
    path.write_text("\n".join(content) + "\n")


def rel(path):
    return str(path).removeprefix(str(workDir) + "/").removeprefix(str(workDir) + "\\")


# ==========================
# Safe Insert Helpers
# ==========================
def insert_after_first(path, anchor, *new_lines):
    require_exists(path)
    content = lines(path)
    if all(line in content for line in new_lines):
        return False
    index = next((i for i, line in enumerate(content) if anchor.search(line)), -1)
    if index < 0:
        raise RuntimeError(f"Anchor Not Found in {path}: {anchor.pattern}")
    content[index + 1:index + 1] = list(new_lines)
    write_lines(path, content)
    return True


def insert_after(path, anchor, *new_lines):
    require_exists(path)
    content = lines(path)
    changed = False
    for i in range(len(content) - 1, -1, -1):
        if anchor.search(content[i]):
            already_present = all(line in content for line in new_lines)
            if not already_present:
                content[i + 1:i + 1] = list(new_lines)
                changed = True
    if not changed and not all(line in content for line in new_lines):
        raise RuntimeError(f"Anchor Not Found in {path}: {anchor.pattern}")
    if changed:
        write_lines(path, content)
    return changed


def insert_before_first(path, anchor, *new_lines):
    require_exists(path)
    content = lines(path)
    if all(line in content for line in new_lines):
        return False
    index = next((i for i, line in enumerate(content) if anchor.search(line)), -1)
    if index < 0:
        raise RuntimeError(f"Anchor Not Found in {path}: {anchor.pattern}")
    content[index:index] = list(new_lines)
    write_lines(path, content)
    return True


# ==========================
# Safe Delete Helpers
# ==========================
def delete_line(path, pattern):
    require_exists(path)
    content = lines(path)
    filtered = [line for line in content if not pattern.search(line)]
    if len(filtered) == len(content):
        return False
    write_lines(path, filtered)
    return True


def delete_line_and_following(path, pattern, extra_lines):
    require_exists(path)
    source = lines(path)
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
    source = lines(path)
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
        raise RuntimeError(f"Unterminated Delete Block In {path}: {start.pattern}")
    if changed:
        write_lines(path, out)
    return changed


# ==========================
# Replace Helpers
# ==========================
def replace_each_line(path, pattern, replacement):
    require_exists(path)
    source = lines(path)
    out = [pattern.sub(replacement, line) for line in source]
    if out == source:
        return False
    write_lines(path, out)
    return True


def replace_whole_line(path, old_line, new_line):
    require_exists(path)
    source = lines(path)
    out = [new_line if line == old_line else line for line in source]
    if out == source:
        return False
    write_lines(path, out)
    return True


# ==========================
# Logging
# ==========================
def log_apply(path, detail):
    print(f"[APPLY]   {rel(path)} | {detail}")


def log_postfix(path, detail):
    print(f"[POSTFIX] {rel(path)} | {detail}")


def log_revert(path, detail):
    print(f"[REVERT]  {rel(path)} | {detail}")


def log_skip(path, detail):
    print(f"[SKIP]    {rel(path)} | {detail}")


# ==========================
# Common Anchors
# ==========================
fdinfoCommentStart = regex(r"^[ \t]*/\*$")
fdinfoCommentEnd = regex(r"^[ \t]*u32 mask = mark->mask & IN_ALL_EVENTS;$")
inotifyFdinfoFuncAnchor = regex(r"^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$")
inotifyHelper = [
    "static inline u32 inotify_mark_user_mask(struct fsnotify_mark *mark)",
    "{",
    "\treturn mark->mask & IN_ALL_EVENTS;",
    "}",
    "",
]


# ==========================
# Inotify FDInfo
# ==========================
def add_inotify_mark_user_mask(path):
    if "inotify_mark_user_mask(" in path.read_text():
        log_skip(path, "INOTIFY-MARK-USER-MASK() Already Present")
        return
    insert_before_first(path, inotifyFdinfoFuncAnchor, *inotifyHelper)
    log_apply(path, "Inserted INOTIFY-MARK-USER-MASK() Helper Before INOTIFY-FDINFO()")


def apply_fdinfo(path):
    require_exists(path)
    content = path.read_text()
    if "inotify_mark_user_mask(" in content:
        log_skip(path, "FDINFO Patch Already Applied")
        return
    if "mask, mark.ignored_mask" not in content:
        raise RuntimeError(f"Expected FDINFO Mask Expression Not Found in {path}")
    delete_block(path, fdinfoCommentStart, fdinfoCommentEnd)
    log_apply(path, "Removed Inline Mask-Calculation Comment Block")
    replace_each_line(path, regex(r"\bmask,\s*mark\.ignored_mask"), "inotify_mark_user_mask(mark)")
    log_apply(path, "Replaced Mask Argument With INOTIFY-MARK-USER-MASK(MARK)")
    replace_each_line(path, regex(r"ignored_mask:%x"), "ignored_mask:0")
    log_apply(path, "Replaced IGNORED-MASK:%X With IGNORED-MASK:0")
    add_inotify_mark_user_mask(path)


def revert_fdinfo(path):
    if not path.exists():
        log_skip(path, "FDINFO File Does Not Exist")
        return
    content = path.read_text()
    if "inotify_mark_user_mask(" not in content and "ignored_mask:0" not in content:
        log_skip(path, "FDINFO Patch Not Present")
        return
    replace_each_line(path, regex(r"inotify_mark_user_mask\(mark\)"), "mask")
    replace_each_line(path, regex(r"ignored_mask:0"), "ignored_mask:%x")
    delete_block(path, regex(r"^static inline u32 inotify_mark_user_mask\(struct fsnotify_mark \*mark\)$"), regex(r"^\}$"))
    log_revert(path, "Restored Original FDINFO Mask Handling")


# ==========================
# Android 15 VMA Compatibility
# ==========================
def apply_android15_vma_block(taskMmu, namespace):
    require_exists(taskMmu)
    require_exists(namespace)
    content = taskMmu.read_text()
    if "unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;" in content:
        log_skip(taskMmu, "Android 15 VMA Patch Already Applied")
        return
    insert_after_first(taskMmu, regex(r"smap_gather_stats\(vma, &mss, last_vma_end\);"), "last_vma_end = vma->vm_end;")
    log_apply(taskMmu, "Inserted LAST-VMA-END Update After SMAPGATHERSTATS()")
    content_lines = lines(taskMmu)
    updateIndex = max((i for i, line in enumerate(content_lines) if "last_vma_end = vma->vm_end;" in line), default=-1)
    if updateIndex < 0:
        raise RuntimeError("Unable to Locate Inserted LAST-VMA-END Assignment")
    ifIndex = next((i for i in range(updateIndex - 1, -1, -1) if regex(r"if\s*\(vma->vm_end > last_vma_end\)").search(content_lines[i])), None)
    if ifIndex is None:
        raise RuntimeError("Unable to Locate VMA-END Comparison")
    content_lines[ifIndex] = regex(r"\)\s*$").sub(") {", content_lines[ifIndex])
    content_lines[updateIndex] = "\t\t\t\t" + content_lines[updateIndex].lstrip()
    content_lines.insert(updateIndex + 1, "\t\t\t}")
    write_lines(taskMmu, content_lines)
    log_apply(taskMmu, "Wrapped LAST-VMA-END Update in Conditional Block")
    insert_after_first(namespace, regex(r"#include <trace/hooks/blk\.h>"), "#include <trace/hooks/fs.h>")
    log_apply(namespace, "Added TRACE/HOOKS/FS.H Include")
    insert_after_first(taskMmu, regex(r"int ret = 0, copied = 0;"), "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;", "\tpagemap_entry_t *res = NULL;")
    log_apply(taskMmu, "Added NR-SUBPAGES and PAGEMAP-ENTRY-T Declarations")


def revert_android15_vma_block(taskMmu, namespace):
    if not taskMmu.exists() or not namespace.exists():
        return
    delete_line(namespace, regex(r"^#include <trace/hooks/fs\.h>$"))
    delete_line(taskMmu, regex(r"^\s*unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;$"))
    delete_line(taskMmu, regex(r"^\s*pagemap_entry_t \*res = NULL;$"))
    delete_line(taskMmu, regex(r"^\s*last_vma_end = vma->vm_end;$"))
    replace_each_line(taskMmu, regex(r"if\s*\(vma->vm_end > last_vma_end\)\s*\{$"), "if (vma->vm_end > last_vma_end)")
    content_lines, removed, out = lines(taskMmu), False, []
    for line in content_lines:
        if not removed and line.strip() == "}" and any("if (vma->vm_end > last_vma_end)" in prev for prev in out):
            removed = True
            continue
        out.append(line)
    write_lines(taskMmu, out)
    log_revert(taskMmu, "Restored Original Android 15 VMA Block")
    log_revert(namespace, "Removed TRACE/HOOKS/FS.H Include")


# ==========================
# Postfix Fixups
# ==========================
def apply_post_patch_fixups():
    taskMmu = f("fs/proc/task_mmu.c")
    if taskMmu.exists():
        content = taskMmu.read_text()
        if ("VMA_PAD_START(" in content
                and not regex(r"#include <linux/pgsize_migration(_inline)?\.h>").search(content)
                and not regex(r"^\s*#define\s+VMA_PAD_START").search(content)):
            content_lines = lines(taskMmu)
            content_lines[1:1] = ["#ifndef VMA_PAD_START", "#define VMA_PAD_START(vma) ((vma)->vm_end)", "#endif"]
            write_lines(taskMmu, content_lines)
            log_postfix(taskMmu, "Inserted VMA-PAD-START() Fallback")
        content = taskMmu.read_text()
        if ("__fold_filemap_fixup_entry(" in content
                and not regex(r"static\s+inline\s+void\s+__fold_filemap_fixup_entry").search(content)):
            headerFile = f("include/linux/page_size_compat.h")
            headerDeclaresFn = headerFile.exists() and "__fold_filemap_fixup_entry" in headerFile.read_text()
            if headerDeclaresFn:
                if "#include <linux/page_size_compat.h>" not in content:
                    insert_after_first(taskMmu, regex(r"^#include "), "#include <linux/page_size_compat.h>")
                    log_postfix(taskMmu, "Added PAGE-SIZE-COMPAT.H Include")
            else:
                content_lines = lines(taskMmu)
                lastInclude = max((i for i, line in enumerate(content_lines) if line.lstrip().startswith("#include")), default=-1)
                insertAt = lastInclude + 1 if lastInclude >= 0 else 1
                content_lines[insertAt:insertAt] = [
                    "#ifndef __fold_filemap_fixup_entry",
                    "static inline void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end) { }",
                    "#endif /* __fold_filemap_fixup_entry */",
                ]
                write_lines(taskMmu, content_lines)
                log_postfix(taskMmu, "Inserted FOLD-FILEMAP-FIXUP-ENTRY() Stub")

    # Android 12 / 13 Nameidata Compatibility
    if kernelModule in ("android12-5.10", "android13-5.10"):
        namei = f("fs/namei.c")
        if namei.exists() and "set_nameidata(nd, old_dfd, fake_filename, NULL)" in namei.read_text():
            replace_each_line(namei, regex(r"set_nameidata\(nd, old_dfd, fake_filename, NULL\)"), "set_nameidata(nd, old_dfd, fake_filename)")
            log_postfix(namei, "Rewrote 4-Arg SET-NAMEIDATA() to 3-Arg Form")

    # Android 16 Getname-Flags Compatibility
    if kernelModule == "android16-6.12":
        openC = f("fs/open.c")
        if openC.exists() and "getname_flags(filename, lookup_flags, NULL)" in openC.read_text():
            replace_each_line(openC, regex(r"getname_flags\(filename, lookup_flags, NULL\)"), "getname_flags(filename, lookup_flags)")
            log_postfix(openC, "Rewrote 3-Arg GETNAME-FLAGS() to 2-Arg Form")


# ==========================
# Apply Compatibility Patches
# ==========================
def apply():
    if kernelModule == "android12-5.10":
        if sublevel <= 43:
            path = f("fs/proc/base.c")
            replace_each_line(path, regex(r"(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,"), "size_t this_len = min_t(size_t,")
            log_apply(path, "Normalized THIS-LEN/MIN-T() to SIZE-T")
        if sublevel <= 117:
            apply_fdinfo(f("fs/notify/fdinfo.c"))

    if kernelModule == "android13-5.10" and sublevel <= 107:
        apply_fdinfo(f("fs/notify/fdinfo.c"))

    if kernelModule == "android13-5.15":
        if sublevel <= 41:
            namespace = f("fs/namespace.c")
            insert_after_first(namespace, regex(r"^#include <linux/shmem_fs\.h>$"), "#include <linux/mnt_idmapping.h>")
            log_apply(namespace, "Added LINUX/MNT-IDMAPPING.H Include")
            openC = f("fs/open.c")
            insert_after_first(openC, regex(r"^#include <linux/compat\.h>$"), "#include <linux/mnt_idmapping.h>")
            log_apply(openC, "Added LINUX/MNT-IDMAPPING.H Include")
            apply_fdinfo(f("fs/notify/fdinfo.c"))
        if sublevel >= 123:
            memory = f("mm/memory.c")
            if delete_line(memory, regex(r"#include <linux/swap_slots\.h>")):
                log_apply(memory, "Removed LINUX/SWAP-SLOTS.H")
        if sublevel >= 197:
            namespace = f("fs/namespace.c")
            if delete_line(namespace, regex(r"^#include <trace/hooks/blk\.h>$")):
                log_apply(namespace, "Removed TRACE/HOOKS/BLK.H")
        if sublevel >= 206:
            taskMmu = f("fs/proc/task_mmu.c")
            if delete_line(taskMmu, regex(r"^#include <trace/hooks/mm\.h>$")):
                log_apply(taskMmu, "Removed TRACE/HOOKS/MM.H")

    if kernelModule == "android14-6.1":
        if sublevel <= 25:
            base = f("fs/proc/base.c")
            insert_after_first(base, regex(r"^#include <trace/events/oom\.h>$"), "#include <trace/hooks/sched.h>")
            log_apply(base, "Added TRACE/HOOKS/SCHED.H")
        if sublevel <= 141:
            base = f("fs/proc/base.c")
            insert_after_first(base, regex(r"^#include <linux/cpufreq_times\.h>$"), "#include <linux/dma-buf.h>")
            log_apply(base, "Added LINUX/DMA-BUF.H")
        if sublevel >= 157:
            namespace = f("fs/namespace.c")
            if delete_line(namespace, regex(r"^#include <trace/hooks/blk\.h>$")):
                log_apply(namespace, "Removed TRACE/HOOKS/BLK.H")
            superC = f("fs/super.c")
            if delete_line_and_following(superC, regex(r"^#include <trace/hooks/fs\.h>$"), 1):
                log_apply(superC, "Removed TRACE/HOOKS/FS.H And Following Line")

    if kernelModule == "android15-6.6":
        if sublevel <= 30:
            apply_android15_vma_block(f("fs/proc/task_mmu.c"), f("fs/namespace.c"))
        if sublevel <= 57:
            memory = f("mm/memory.c")
            insert_after_first(memory, regex(r"^#include <linux/sched/sysctl\.h>$"), "#include <linux/zswap.h>")
            log_apply(memory, "Added LINUX/ZSWAP.H")
        if sublevel <= 92:
            base = f("fs/proc/base.c")
            insert_after_first(base, regex(r"^#include <linux/cpufreq_times\.h>$"), "#include <linux/dma-buf.h>")
            log_apply(base, "Added LINUX/DMA-BUF.H")

    if kernelModule == "android16-6.12":
        if sublevel >= 58:
            execFile = f("fs/exec.c")
            if delete_line(execFile, regex(r"^#include <linux/dma-buf\.h>$")):
                log_apply(execFile, "Removed LINUX/DMA-BUF.H")
        if sublevel >= 69:
            taskMmu = f("fs/proc/task_mmu.c")
            if replace_each_line(taskMmu, regex(r"vma_data_pages"), "vma_pages"):
                log_apply(taskMmu, "Renamed VMA-DATA-PAGES To VMA-PAGES")


# ==========================
# PostFix Compatibility Patches
# ==========================
def postfix():
    apply_post_patch_fixups()


# ==========================
# Revert Compatibility Patches
# ==========================
def revert():
    if kernelModule == "android12-5.10":
        if sublevel <= 43:
            path = f("fs/proc/base.c")
            if replace_whole_line(path, "size_t this_len = min_t(size_t, count, PAGE_SIZE);", "int this_len = min_t(int, count, PAGE_SIZE);"):
                log_revert(path, "Restored INT THIS-LEN/MIN-T(INT)")
        if sublevel <= 117:
            revert_fdinfo(f("fs/notify/fdinfo.c"))

    if kernelModule == "android13-5.10" and sublevel <= 107:
        revert_fdinfo(f("fs/notify/fdinfo.c"))

    if kernelModule == "android13-5.15":
        if sublevel <= 41:
            namespace = f("fs/namespace.c")
            delete_line(namespace, regex(r"^#include <linux/mnt_idmapping\.h>$"))
            log_revert(namespace, "Removed LINUX/MNT-ID-MAPPING.H")
            openC = f("fs/open.c")
            delete_line(openC, regex(r"^#include <linux/mnt_idmapping\.h>$"))
            log_revert(openC, "Removed LINUX/MNT-ID-MAPPING.H")
            susfs = f("fs/susfs.c")
            if susfs.exists():
                replace_each_line(susfs, regex(re.escape("i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val")), "i_uid_into_mnt(&init_user_ns, &fi->inode).val")
                replace_each_line(susfs, regex(re.escape("i_uid_into_mnt(i_user_ns(inode), inode).val")), "i_uid_into_mnt(&init_user_ns, inode).val")
                log_revert(susfs, "Restored SUSFS IUID-INTO-MNT() Form")
            revert_fdinfo(f("fs/notify/fdinfo.c"))
        if sublevel >= 123:
            memory = f("mm/memory.c")
            if "#include <linux/swap_slots.h>" not in memory.read_text():
                insert_before_first(memory, regex(r"#ifdef CONFIG_KSU_SUSFS_SUS_MAP"), "#include <linux/swap_slots.h>")
                log_revert(memory, "Restored LINUX/SWAP-SLOTS.H")
        if sublevel >= 197:
            namespace = f("fs/namespace.c")
            if "#include <trace/hooks/blk.h>" not in namespace.read_text():
                insert_after_first(namespace, regex(r'^#include "internal\.h"$'), "#include <trace/hooks/blk.h>")
                log_revert(namespace, "Restored TRACE/HOOKS/BLK.H")
        if sublevel >= 206:
            taskMmu = f("fs/proc/task_mmu.c")
            if "#include <trace/hooks/mm.h>" not in taskMmu.read_text():
                insert_after_first(taskMmu, regex(r"^#include <linux/pkeys\.h>$"), "#include <trace/hooks/mm.h>")
                log_revert(taskMmu, "Restored TRACE/HOOKS/MM.H")

    if kernelModule == "android14-6.1":
        if sublevel <= 25:
            base = f("fs/proc/base.c")
            delete_line(base, regex(r"^#include <trace/hooks/sched\.h>$"))
            log_revert(base, "Removed TRACE/HOOKS/SCHED.H")
        if sublevel <= 141:
            base = f("fs/proc/base.c")
            delete_line(base, regex(r"^#include <linux/dma-buf\.h>$"))
            log_revert(base, "Removed LINUX/DMA-BUF.H")
        if sublevel >= 157:
            namespace = f("fs/namespace.c")
            if "#include <trace/hooks/blk.h>" not in namespace.read_text():
                insert_after_first(namespace, regex(r'^#include "internal\.h"$'), "#include <trace/hooks/blk.h>")
            superC = f("fs/super.c")
            if "#include <trace/hooks/fs.h>" not in superC.read_text():
                insert_after_first(superC, regex(r'^#include "internal\.h"$'), "#include <trace/hooks/fs.h>")
            log_revert(namespace, "Restored TRACE/HOOKS/BLK.H")
            log_revert(superC, "Restored TRACE/HOOKS/FS.H")

    if kernelModule == "android15-6.6":
        if sublevel <= 30:
            revert_android15_vma_block(f("fs/proc/task_mmu.c"), f("fs/namespace.c"))
        if sublevel <= 57:
            memory = f("mm/memory.c")
            delete_line(memory, regex(r"^#include <linux/zswap\.h>$"))
            log_revert(memory, "Removed LINUX/ZSWAP.H")
        if sublevel <= 92:
            base = f("fs/proc/base.c")
            delete_line(base, regex(r"^#include <linux/dma-buf\.h>$"))
            log_revert(base, "Removed LINUX/DMABUF.H")

    if kernelModule == "android16-6.12":
        if sublevel >= 58:
            execFile = f("fs/exec.c")
            if "#include <linux/dma-buf.h>" not in execFile.read_text():
                insert_after_first(execFile, regex(r"^#include "), "#include <linux/dma-buf.h>")
                log_revert(execFile, "Restored LINUX/DMABUF.H")
        if sublevel >= 69:
            taskMmu = f("fs/proc/task_mmu.c")
            if "vma_pages" in taskMmu.read_text():
                replace_each_line(taskMmu, regex(r"vma_pages"), "vma_data_pages")
                log_revert(taskMmu, "Restored VMADATAPAGES")


# ==========================
# Main
# ==========================
try:
    if mode == "Apply":
        apply()
    elif mode == "PostFix":
        postfix()
    elif mode == "Revert":
        revert()
    else:
        print("Usage: Python FakePatches.py <Apply|PostFix|Revert> [WorkDir]")
        sys.exit(1)
    print(f"🚀 Fake Patches: {mode} Completed (Android and Kernel Version = {kernelModule}, Sublevel = {sublevel})")
except Exception as e:
    print(f"⚠️ Fake Patches Failed: {e}", file=sys.stderr)
    sys.exit(1)
