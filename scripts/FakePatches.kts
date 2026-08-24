#!/usr/bin/env kotlin
import java.io.File
import kotlin.system.exitProcess

fun File.insertAfter(anchor: Regex, vararg newLines: String) {
    val out = mutableListOf<String>()
    for (line in readLines()) {
        out.add(line)
        if (anchor.containsMatchIn(line)) out.addAll(newLines)
    }
    writeText(out.joinToString("\n") + "\n")
}

fun File.insertAfterFirst(anchor: Regex, vararg newLines: String) {
    val out = mutableListOf<String>()
    var inserted = false
    for (line in readLines()) {
        out.add(line)
        if (!inserted && anchor.containsMatchIn(line)) {
            out.addAll(newLines)
            inserted = true
        }
    }
    writeText(out.joinToString("\n") + "\n")
}

fun File.insertBefore(anchor: Regex, vararg newLines: String) {
    val out = mutableListOf<String>()
    for (line in readLines()) {
        if (anchor.containsMatchIn(line)) out.addAll(newLines)
        out.add(line)
    }
    writeText(out.joinToString("\n") + "\n")
}

fun File.insertBeforeFirst(anchor: Regex, vararg newLines: String) {
    val out = mutableListOf<String>()
    var inserted = false
    for (line in readLines()) {
        if (!inserted && anchor.containsMatchIn(line)) {
            out.addAll(newLines)
            inserted = true
        }
        out.add(line)
    }
    writeText(out.joinToString("\n") + "\n")
}

fun File.deleteLine(pattern: Regex) {
    val out = readLines().filterNot { pattern.containsMatchIn(it) }
    writeText(out.joinToString("\n") + "\n")
}

fun File.deleteBlock(start: Regex, end: Regex) {
    val out = mutableListOf<String>()
    var inBlock = false
    for (line in readLines()) {
        if (!inBlock && start.containsMatchIn(line)) {
            inBlock = true
            continue
        }
        if (inBlock) {
            if (end.containsMatchIn(line)) inBlock = false
            continue
        }
        out.add(line)
    }
    writeText(out.joinToString("\n") + "\n")
}

fun File.replaceEachLine(pattern: Regex, replacement: String) {
    val out = readLines().map { pattern.replace(it, replacement) }
    writeText(out.joinToString("\n") + "\n")
}

fun File.replaceWholeLine(oldLine: String, newLine: String) {
    val out = readLines().map { if (it == oldLine) newLine else it }
    writeText(out.joinToString("\n") + "\n")
}

val kernelModule = System.getenv("KERNELMODULE") ?: ""
val sublevel = (System.getenv("SUBLEVEL") ?: "0").toIntOrNull() ?: 0
val mode = args.getOrNull(0) ?: "apply"
val workDir = args.getOrNull(1) ?: "kernel_workspace/kernel_platform/common"

fun f(relPath: String) = File(workDir, relPath)
fun File.rel(): String = this.path.removePrefix("$workDir/").removePrefix("$workDir\\")
fun logApply(file: File, detail: String) = println("[APPLY]-${file.rel()}: $detail")
fun logPostfix(file: File, detail: String) = println("[POSTFIX]-${file.rel()}: $detail")
fun logRevert(file: File, detail: String) = println("[REVERT]-${file.rel()}: $detail")

val fdinfoCommentStart = Regex("""^[ \t]*/\*$""")
val fdinfoCommentEnd = Regex("""^[ \t]*u32 mask = mark->mask & IN_ALL_EVENTS;$""")

val inotifyFdinfoFuncAnchor = Regex("""^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$""")

fun addInotifyMarkUserMaskFunction(file: File) {
    file.insertBeforeFirst(
        inotifyFdinfoFuncAnchor,
        "static inline u32 inotify_mark_user_mask(struct fsnotify_mark *mark)",
        "{",
        "\treturn mark->mask & IN_ALL_EVENTS;",
        "}",
        ""
    )
}

fun applyFdinfo(file: File) {
    file.deleteBlock(fdinfoCommentStart, fdinfoCommentEnd)
    logApply(file, "REMOVED INLINE MASK-COMPUTATION COMMENT BLOCK ENDING AT 'U32 MASK = MARK->MASK & IN_ALL_EVENTS;' INSIDE INOTIFY_FDINFO()")
    file.replaceEachLine(Regex("""\bmask,\s*mark\.ignored_mask"""), "inotify_mark_user_mask(mark)")
    logApply(file, "REPLACED SEQ_PRINTF ARGUMENT 'MASK, MARK->IGNORED_MASK' WITH INOTIFY_MARK_USER_MASK(MARK) CALL")
    file.replaceEachLine(Regex("""ignored_mask:%x"""), "ignored_mask:0")
    logApply(file, "REPLACED FORMAT SPECIFIER 'IGNORED_MASK:%X' WITH LITERAL 'IGNORED_MASK:0'")
    addInotifyMarkUserMaskFunction(file)
    logApply(file, "INSERTED NEW STATIC INLINE INOTIFY_MARK_USER_MASK() HELPER FUNCTION BEFORE INOTIFY_FDINFO()")
}

fun applyAndroid15VmaBlock(taskMmu: File, namespace: File) {
    taskMmu.insertAfter(
        Regex("""smap_gather_stats\(vma, &mss, last_vma_end\);"""),
        "last_vma_end = vma->vm_end;"
    )
    logApply(taskMmu, "INSERTED 'LAST_VMA_END = VMA->VM_END;' IMMEDIATELY AFTER THE SMAP_GATHER_STATS() CALL")

    val lines = taskMmu.readLines().toMutableList()
    val ifPattern = Regex("""if\s*\(vma->vm_end > last_vma_end\)""")
    val trailingParen = Regex("""\)\s*$""")

    for (i in lines.indices.reversed()) {
        if (lines[i].contains("last_vma_end = vma->vm_end;")) {
            lines[i] = "\t\t\t\t" + lines[i]
            lines.add(i + 1, "\t\t\t}")
            for (j in i downTo 0) {
                if (ifPattern.containsMatchIn(lines[j])) {
                    lines[j] = trailingParen.replace(lines[j], ") {")
                    break
                }
            }
            break
        }
    }

    taskMmu.writeText(lines.joinToString("\n") + "\n")
    logApply(taskMmu, "OPENED A NEW '{ ... }' BLOCK AROUND THE LAST_VMA_END UPDATE AND RE-INDENTED THE STATEMENT")

    namespace.insertAfter(
        Regex("""#include <trace/hooks/blk\.h>"""),
        "#include <trace/hooks/fs.h>"
    )
    logApply(namespace, "ADDED #INCLUDE <TRACE/HOOKS/FS.H> DIRECTLY AFTER #INCLUDE <TRACE/HOOKS/BLK.H>")

    taskMmu.insertAfter(
        Regex("""int ret = 0, copied = 0;"""),
        "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;",
        "\tpagemap_entry_t *res = NULL;"
    )
    logApply(taskMmu, "DECLARED NR_SUBPAGES AND PAGEMAP_ENTRY_T *RES AFTER 'INT RET = 0, COPIED = 0;'")
}

fun revertAndroid15VmaBlock(taskMmu: File, namespace: File) {
    namespace.deleteLine(Regex("""#include <trace/hooks/fs\.h>"""))
    logRevert(namespace, "REMOVED #INCLUDE <TRACE/HOOKS/FS.H>")

    taskMmu.deleteLine(Regex("""unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;"""))
    logRevert(taskMmu, "REMOVED NR_SUBPAGES DECLARATION")

    taskMmu.deleteLine(Regex("""pagemap_entry_t \*res = NULL;"""))
    logRevert(taskMmu, "REMOVED PAGEMAP_ENTRY_T *RES DECLARATION")
}

fun applyPostPatchFixups() {
    val taskMmu = f("fs/proc/task_mmu.c")

    if (taskMmu.exists()) {
        val content = taskMmu.readText()

        if (
            content.contains("VMA_PAD_START(") &&
            !Regex("""#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START""").containsMatchIn(content)
        ) {
            val lines = taskMmu.readLines().toMutableList()

            lines.addAll(
                1,
                listOf(
                    "#ifndef VMA_PAD_START",
                    "#define VMA_PAD_START(vma) ((vma)->vm_end)",
                    "#endif"
                )
            )

            taskMmu.writeText(lines.joinToString("\n") + "\n")
            logPostfix(taskMmu, "INSERTED FALLBACK MACRO '#DEFINE VMA_PAD_START(VMA) ((VMA)->VM_END)'")
        }

        val content2 = taskMmu.readText()

        if (
            content2.contains("__fold_filemap_fixup_entry(") &&
            !Regex("""static\s+inline\s+void\s+__fold_filemap_fixup_entry""").containsMatchIn(content2)
        ) {
            val headerFile = f("include/linux/page_size_compat.h")
            val headerDeclaresFn =
                headerFile.exists() && headerFile.readText().contains("__fold_filemap_fixup_entry")

            if (headerDeclaresFn) {
                if (!content2.contains("#include <linux/page_size_compat.h>")) {
                    val lines = taskMmu.readLines().toMutableList()
                    lines.add(1, "#include <linux/page_size_compat.h>")
                    taskMmu.writeText(lines.joinToString("\n") + "\n")
                    logPostfix(taskMmu, "ADDED #INCLUDE <LINUX/PAGE_SIZE_COMPAT.H>")
                }
            } else {
                val lines = taskMmu.readLines().toMutableList()
                val lastIncludeIdx = lines.indexOfLast { it.trimStart().startsWith("#include") }
                val insertAt = if (lastIncludeIdx >= 0) lastIncludeIdx + 1 else 1

                lines.addAll(
                    insertAt,
                    listOf(
                        "#ifndef __fold_filemap_fixup_entry",
                        "static inline void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end) { }",
                        "#endif /* __fold_filemap_fixup_entry */"
                    )
                )

                taskMmu.writeText(lines.joinToString("\n") + "\n")
                logPostfix(taskMmu, "INSERTED NO-OP STATIC INLINE __FOLD_FILEMAP_FIXUP_ENTRY() STUB")
            }
        }
    }

    if (kernelModule == "android12-5.10" || kernelModule == "android13-5.10") {
        val namei = f("fs/namei.c")

        if (
            namei.exists() &&
            namei.readText().contains("set_nameidata(nd, old_dfd, fake_filename, NULL)")
        ) {
            namei.replaceEachLine(
                Regex("""set_nameidata\(nd, old_dfd, fake_filename, NULL\)"""),
                "set_nameidata(nd, old_dfd, fake_filename)"
            )
            logPostfix(namei, "REWROTE 4-ARG SET_NAMEIDATA() CALLS TO THE 3-ARG FORM")
        }
    }

    if (kernelModule == "android16-6.12") {
        val openC = f("fs/open.c")

        if (
            openC.exists() &&
            openC.readText().contains("getname_flags(filename, lookup_flags, NULL)")
        ) {
            openC.replaceEachLine(
                Regex("""getname_flags\(filename, lookup_flags, NULL\)"""),
                "getname_flags(filename, lookup_flags)"
            )
            logPostfix(openC, "REWROTE 3-ARG GETNAME_FLAGS() CALLS TO THE 2-ARG FORM")
        }
    }
}

fun apply() {
    if (kernelModule == "android12-5.10") {
        if (sublevel <= 43) {
            val file = f("fs/proc/base.c")

            file.replaceEachLine(
                Regex("""(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,"""),
                "size_t this_len = min_t(size_t,"
            )

            logApply(file, "NORMALIZED THIS_LEN DECLARATION AND MIN_T() CALL TO USE SIZE_T")
        }

        if (sublevel <= 117) {
            applyFdinfo(f("fs/notify/fdinfo.c"))
        }
    }

    if (kernelModule == "android13-5.10") {
        if (sublevel <= 107) {
            applyFdinfo(f("fs/notify/fdinfo.c"))
        }
    }

    if (kernelModule == "android13-5.15") {
        if (sublevel <= 41) {
            val namespace = f("fs/namespace.c")

            namespace.insertAfter(
                Regex("""^#include <linux/shmem_fs\.h>$"""),
                "#include <linux/mnt_idmapping.h>"
            )

            logApply(namespace, "ADDED #INCLUDE <LINUX/MNT_IDMAPPING.H> AFTER #INCLUDE <LINUX/SHMEM_FS.H>")

            val openC = f("fs/open.c")

            openC.insertAfter(
                Regex("""^#include <linux/compat\.h>$"""),
                "#include <linux/mnt_idmapping.h>"
            )

            logApply(openC, "ADDED #INCLUDE <LINUX/MNT_IDMAPPING.H> AFTER #INCLUDE <LINUX/COMPAT.H>")

            applyFdinfo(f("fs/notify/fdinfo.c"))
        }

        if (sublevel >= 123) {
            val memory = f("mm/memory.c")
            memory.deleteLine(Regex("""#include <linux/swap_slots\.h>"""))
            logApply(memory, "REMOVED #INCLUDE <LINUX/SWAP_SLOTS.H>")
        }

        if (sublevel >= 197) {
            val namespace = f("fs/namespace.c")
            namespace.deleteLine(Regex("""^#include <trace/hooks/blk\.h>$"""))
            logApply(namespace, "REMOVED #INCLUDE <TRACE/HOOKS/BLK.H>")
        }

        if (sublevel >= 206) {
            val taskMmu = f("fs/proc/task_mmu.c")
            taskMmu.deleteLine(Regex("""^#include <trace/hooks/mm\.h>$"""))
            logApply(taskMmu, "REMOVED #INCLUDE <TRACE/HOOKS/MM.H>")
        }
    }

    if (kernelModule == "android14-6.1") {
        if (sublevel <= 25) {
            val base = f("fs/proc/base.c")

            base.insertAfter(
                Regex("""^#include <trace/events/oom\.h>$"""),
                "#include <trace/hooks/sched.h>"
            )

            logApply(base, "ADDED #INCLUDE <TRACE/HOOKS/SCHED.H> AFTER #INCLUDE <TRACE/EVENTS/OOM.H>")
        }

        if (sublevel <= 141) {
            val base = f("fs/proc/base.c")

            base.insertAfter(
                Regex("""^#include <linux/cpufreq_times\.h>$"""),
                "#include <linux/dma-buf.h>"
            )

            logApply(base, "ADDED #INCLUDE <LINUX/DMA-BUF.H> AFTER #INCLUDE <LINUX/CPUFREQ_TIMES.H>")
        }

        if (sublevel >= 157) {
            val namespace = f("fs/namespace.c")
            namespace.deleteLine(Regex("""^#include <trace/hooks/blk\.h>$"""))
            logApply(namespace, "REMOVED #INCLUDE <TRACE/HOOKS/BLK.H>")
        }
    }

    if (kernelModule == "android15-6.6") {
        if (sublevel <= 30) {
            applyAndroid15VmaBlock(
                f("fs/proc/task_mmu.c"),
                f("fs/namespace.c")
            )
        }

        if (sublevel <= 57) {
            val memory = f("mm/memory.c")

            memory.insertAfter(
                Regex("""^#include <linux/sched/sysctl\.h>$"""),
                "#include <linux/zswap.h>"
            )

            logApply(memory, "ADDED #INCLUDE <LINUX/ZSWAP.H> AFTER #INCLUDE <LINUX/SCHED/SYSCTL.H>")
        }

        if (sublevel <= 92) {
            val base = f("fs/proc/base.c")

            base.insertAfter(
                Regex("""^#include <linux/cpufreq_times\.h>$"""),
                "#include <linux/dma-buf.h>"
            )

            logApply(base, "ADDED #INCLUDE <LINUX/DMA-BUF.H> AFTER #INCLUDE <LINUX/CPUFREQ_TIMES.H>")
        }
    }

    if (kernelModule == "android16-6.12") {
        if (sublevel >= 58) {
            val exec = f("fs/exec.c")
            exec.deleteLine(Regex("""^#include <linux/dma-buf\.h>$"""))
            logApply(exec, "REMOVED #INCLUDE <LINUX/DMA-BUF.H>")
        }

        if (sublevel >= 69) {
            val taskMmu = f("fs/proc/task_mmu.c")
            taskMmu.replaceEachLine(Regex("""vma_data_pages"""), "vma_pages")
            logApply(taskMmu, "RENAMED ALL OCCURRENCES OF VMA_DATA_PAGES TO VMA_PAGES")
        }
    }
}

fun postfix() {
    applyPostPatchFixups()
}

fun revert() {
    if (kernelModule == "android12-5.10") {
        if (sublevel <= 43) {
            val file = f("fs/proc/base.c")

            file.replaceWholeLine(
                "size_t this_len = min_t(size_t, count, PAGE_SIZE);",
                "int this_len = min_t(int, count, PAGE_SIZE);"
            )

            logRevert(file, "RESTORED 'INT THIS_LEN = MIN_T(INT, COUNT, PAGE_SIZE);'")
        }
    }

    if (kernelModule == "android13-5.15") {
        if (sublevel <= 41) {
            val namespace = f("fs/namespace.c")
            namespace.deleteLine(Regex("""#include <linux/mnt_idmapping\.h>$"""))
            logRevert(namespace, "REMOVED #INCLUDE <LINUX/MNT_IDMAPPING.H>")

            val openC = f("fs/open.c")
            openC.deleteLine(Regex("""#include <linux/mnt_idmapping\.h>$"""))
            logRevert(openC, "REMOVED #INCLUDE <LINUX/MNT_IDMAPPING.H>")

            val susfs = f("fs/susfs.c")

            susfs.replaceEachLine(
                Regex(Regex.escape("i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val")),
                "i_uid_into_mnt(&init_user_ns, &fi->inode).val"
            )

            logRevert(susfs, "REVERTED I_UID_INTO_MNT() CALL FOR FI->INODE")

            susfs.replaceEachLine(
                Regex(Regex.escape("i_uid_into_mnt(i_user_ns(inode), inode).val")),
                "i_uid_into_mnt(&init_user_ns, inode).val"
            )

            logRevert(susfs, "REVERTED I_UID_INTO_MNT() CALL FOR INODE")
        }

        if (sublevel >= 123) {
            val memory = f("mm/memory.c")

            memory.insertBefore(
                Regex("""#ifdef CONFIG_KSU_SUSFS_SUS_MAP"""),
                "#include <linux/swap_slots.h>"
            )

            logRevert(memory, "RESTORED #INCLUDE <LINUX/SWAP_SLOTS.H>")
        }

        if (sublevel >= 197) {
            val namespace = f("fs/namespace.c")

            namespace.insertAfter(
                Regex("""^#include "internal\.h"$"""),
                "#include <trace/hooks/blk.h>"
            )

            logRevert(namespace, "RESTORED #INCLUDE <TRACE/HOOKS/BLK.H>")
        }

        if (sublevel >= 206) {
            val taskMmu = f("fs/proc/task_mmu.c")

            taskMmu.insertAfter(
                Regex("""^#include <linux/pkeys\.h>$"""),
                "#include <trace/hooks/mm.h>"
            )

            logRevert(taskMmu, "RESTORED #INCLUDE <TRACE/HOOKS/MM.H>")
        }
    }

    if (kernelModule == "android14-6.1") {
        if (sublevel <= 25) {
            val base = f("fs/proc/base.c")
            base.deleteLine(Regex("""^#include <trace/hooks/sched\.h>$"""))
            logRevert(base, "REMOVED #INCLUDE <TRACE/HOOKS/SCHED.H>")
        }

        if (sublevel <= 141) {
            val base = f("fs/proc/base.c")
            base.deleteLine(Regex("""^#include <linux/dma-buf\.h>$"""))
            logRevert(base, "REMOVED #INCLUDE <LINUX/DMA-BUF.H>")
        }
    }

    if (kernelModule == "android15-6.6") {
        if (sublevel <= 30) {
            revertAndroid15VmaBlock(
                f("fs/proc/task_mmu.c"),
                f("fs/namespace.c")
            )
        }

        if (sublevel <= 57) {
            val memory = f("mm/memory.c")
            memory.deleteLine(Regex("""^#include <linux/zswap\.h>$"""))
            logRevert(memory, "REMOVED #INCLUDE <LINUX/ZSWAP.H>")
        }

        if (sublevel <= 92) {
            val base = f("fs/proc/base.c")
            base.deleteLine(Regex("""^#include <linux/dma-buf\.h>$"""))
            logRevert(base, "REMOVED #INCLUDE <LINUX/DMA-BUF.H>")
        }
    }

    if (kernelModule == "android16-6.12") {
        if (sublevel >= 58) {
            val exec = f("fs/exec.c")

            exec.insertAfterFirst(
                Regex("""^#include """),
                "#include <linux/dma-buf.h>"
            )

            logRevert(exec, "RESTORED #INCLUDE <LINUX/DMA-BUF.H>")
        }

        if (sublevel >= 69) {
            val taskMmu = f("fs/proc/task_mmu.c")
            taskMmu.replaceEachLine(Regex("""vma_pages"""), "vma_data_pages")
            logRevert(taskMmu, "RENAMED ALL OCCURRENCES OF VMA_PAGES BACK TO VMA_DATA_PAGES")
        }
    }
}

when (mode) {
    "apply" -> apply()
    "postfix" -> postfix()
    "revert" -> revert()
    else -> {
        println("USAGE: KOTLIN FAKEPATCHES.KTS <APPLY|POSTFIX|REVERT> [WORKDIR]")
        exitProcess(1)
    }
}
