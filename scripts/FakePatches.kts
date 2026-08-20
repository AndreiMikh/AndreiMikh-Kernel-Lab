#!/usr/bin/env kotlin

import java.io.File
import kotlin.system.exitProcess

/** sed '/pattern/a text' — Insert multiple lines after every matching line */
fun File.insertAfter(anchor: Regex, vararg newLines: String) {
    val out = mutableListOf<String>()

    for (line in readLines()) {
        out.add(line)

        if (anchor.containsMatchIn(line)) {
            out.addAll(newLines)
        }
    }

    writeText(out.joinToString("\n") + "\n")
}

/** Insert multiple lines after the first matching line only */
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

/** sed '/pattern/i text' — Insert multiple lines before every matching line */
fun File.insertBefore(anchor: Regex, vararg newLines: String) {
    val out = mutableListOf<String>()

    for (line in readLines()) {
        if (anchor.containsMatchIn(line)) {
            out.addAll(newLines)
        }

        out.add(line)
    }

    writeText(out.joinToString("\n") + "\n")
}

/** Insert multiple lines before the first matching line only */
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

/** sed '/pattern/d' — Delete all matching lines */
fun File.deleteLine(pattern: Regex) {
    val out = readLines().filterNot {
        pattern.containsMatchIn(it)
    }

    writeText(out.joinToString("\n") + "\n")
}

/**
 * sed '/start/,/end/d' —
 * Delete entire blocks from the start match through the end match,
 * including both boundary lines. Supports multiple blocks.
 */
fun File.deleteBlock(start: Regex, end: Regex) {
    val out = mutableListOf<String>()
    var inBlock = false

    for (line in readLines()) {

        if (!inBlock && start.containsMatchIn(line)) {
            inBlock = true
            continue
        }

        if (inBlock) {
            if (end.containsMatchIn(line)) {
                inBlock = false
            }

            continue
        }

        out.add(line)
    }

    writeText(out.joinToString("\n") + "\n")
}

/**
 * perl -pe 's/pattern/repl/' —
 * Perform a regex replacement on every line.
 * Supports regex capture groups such as \1.
 */
fun File.replaceEachLine(pattern: Regex, replacement: String) {
    val out = readLines().map {
        pattern.replace(it, replacement)
    }

    writeText(out.joinToString("\n") + "\n")
}

/** sed 's/exact_old/exact_new/' — Replace an entire line exactly */
fun File.replaceWholeLine(oldLine: String, newLine: String) {
    val out = readLines().map {
        if (it == oldLine) newLine else it
    }

    writeText(out.joinToString("\n") + "\n")
}


/* ============================================================
 * Environment / Arguments
 * ============================================================ */

val kernelModule = System.getenv("KERNELMODULE") ?: ""

val sublevel =
    (System.getenv("SUBLEVEL") ?: "0").toIntOrNull() ?: 0

val mode = args.getOrNull(0) ?: "apply"
// apply | postfix | revert

val workDir =
    args.getOrNull(1)
        ?: "kernel_workspace/kernel_platform/common"

fun f(relPath: String) = File(workDir, relPath)


/* ============================================================
 * Common Regex Patterns
 * ============================================================ */

val fdinfoCommentStart =
    Regex("""^[ \t]*/\*$""")

val fdinfoCommentEnd =
    Regex(
        """^[ \t]*u32 mask = mark->mask & IN_ALL_EVENTS;$"""
    )

val inotifyFdinfoFuncAnchor =
    Regex(
        """^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$"""
    )


/* ============================================================
 * Inotify / fdinfo Helpers
 * ============================================================ */

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

    file.deleteBlock(
        fdinfoCommentStart,
        fdinfoCommentEnd
    )

    file.replaceEachLine(
        Regex("""\bmask,\s*mark->ignored_mask"""),
        "inotify_mark_user_mask(mark)"
    )

    file.replaceEachLine(
        Regex("""ignored_mask:%x"""),
        "ignored_mask:0"
    )

    println(
        "Adding inotify_mark_user_mask function definition"
    )

    addInotifyMarkUserMaskFunction(file)
}


/* ============================================================
 * Android 15 6.6 — SUBLEVEL <= 30
 * ============================================================ */

fun applyAndroid15VmaBlock(
    taskMmu: File,
    namespace: File
) {

    /*
     * 1. Insert:
     *
     *     last_vma_end = vma->vm_end;
     *
     * after the line containing:
     *
     *     smap_gather_stats(vma, &mss, last_vma_end);
     */
    taskMmu.insertAfter(
        Regex(
            """smap_gather_stats\(vma, &mss, last_vma_end\);"""
        ),
        "last_vma_end = vma->vm_end;"
    )

    /*
     * 2. Starting from the end of the file, find the last occurrence
     * of:
     *
     *     last_vma_end = vma->vm_end;
     *
     * Add indentation and insert a closing brace after it.
     *
     * Then search backward for the nearest:
     *
     *     if (vma->vm_end > last_vma_end)
     *
     * and change the closing ')' to ') {'.
     */
    val lines = taskMmu.readLines().toMutableList()

    val ifPattern =
        Regex(
            """if\s*\(vma->vm_end > last_vma_end\)"""
        )

    val trailingParen =
        Regex("""\)\s*$""")

    for (i in lines.indices.reversed()) {

        if (
            lines[i].contains(
                "last_vma_end = vma->vm_end;"
            )
        ) {

            lines[i] =
                "\t\t\t\t" + lines[i]

            lines.add(
                i + 1,
                "\t\t\t}"
            )

            for (j in i downTo 0) {

                if (ifPattern.containsMatchIn(lines[j])) {

                    lines[j] =
                        trailingParen.replace(
                            lines[j],
                            ") {"
                        )

                    break
                }
            }

            break
        }
    }

    taskMmu.writeText(
        lines.joinToString("\n") + "\n"
    )

    /*
     * 3. namespace.c:
     *
     * Insert trace/hooks/fs.h after:
     *
     *     #include <trace/hooks/blk.h>
     */
    namespace.insertAfter(
        Regex(
            """#include <trace/hooks/blk\.h>"""
        ),
        "#include <trace/hooks/fs.h>"
    )

    /*
     * 4. task_mmu.c:
     *
     * Insert the following two lines after:
     *
     *     int ret = 0, copied = 0;
     */
    taskMmu.insertAfter(
        Regex(
            """int ret = 0, copied = 0;"""
        ),
        "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;",
        "\tpagemap_entry_t *res = NULL;"
    )
}

fun revertAndroid15VmaBlock(
    taskMmu: File,
    namespace: File
) {

    namespace.deleteLine(
        Regex(
            """#include <trace/hooks/fs\.h>"""
        )
    )

    taskMmu.deleteLine(
        Regex(
            """unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;"""
        )
    )

    taskMmu.deleteLine(
        Regex(
            """pagemap_entry_t \*res = NULL;"""
        )
    )
}


/* ============================================================
 * Post-Patch Fixups
 * ============================================================ */

fun applyPostPatchFixups() {

    val taskMmu =
        f("fs/proc/task_mmu.c")

    if (taskMmu.exists()) {

        val content =
            taskMmu.readText()

        /*
         * Add a fallback definition for VMA_PAD_START
         * when the required definition/header is unavailable.
         */
        if (
            content.contains("VMA_PAD_START(") &&
            !Regex(
                """#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START"""
            ).containsMatchIn(content)
        ) {

            val lines =
                taskMmu.readLines().toMutableList()

            lines.addAll(
                1,
                listOf(
                    "#ifndef VMA_PAD_START",
                    "#define VMA_PAD_START(vma) ((vma)->vm_end)",
                    "#endif"
                )
            )

            taskMmu.writeText(
                lines.joinToString("\n") + "\n"
            )

            println(
                "Added VMA_PAD_START fallback definition to fs/proc/task_mmu.c"
            )
        }

        /*
         * Add or provide a fallback for
         * __fold_filemap_fixup_entry().
         */
        val content2 =
            taskMmu.readText()

        if (
            content2.contains(
                "__fold_filemap_fixup_entry("
            ) &&
            !Regex(
                """static\s+inline\s+void\s+__fold_filemap_fixup_entry"""
            ).containsMatchIn(content2)
        ) {

            val headerFile =
                f("include/linux/page_size_compat.h")

            val headerDeclaresFn =
                headerFile.exists() &&
                headerFile.readText()
                    .contains(
                        "__fold_filemap_fixup_entry"
                    )

            if (headerDeclaresFn) {

                if (
                    !content2.contains(
                        "#include <linux/page_size_compat.h>"
                    )
                ) {

                    val lines =
                        taskMmu.readLines()
                            .toMutableList()

                    lines.add(
                        1,
                        "#include <linux/page_size_compat.h>"
                    )

                    taskMmu.writeText(
                        lines.joinToString("\n") + "\n"
                    )

                    println(
                        "Added page_size_compat.h include to fs/proc/task_mmu.c"
                    )
                }

            } else {

                val lines =
                    taskMmu.readLines()
                        .toMutableList()

                val lastIncludeIdx =
                    lines.indexOfLast {
                        it.trimStart()
                            .startsWith("#include")
                    }

                val insertAt =
                    if (lastIncludeIdx >= 0) {
                        lastIncludeIdx + 1
                    } else {
                        1
                    }

                lines.addAll(
                    insertAt,
                    listOf(
                        "#ifndef __fold_filemap_fixup_entry",
                        "static inline void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end) { }",
                        "#endif /* __fold_filemap_fixup_entry */"
                    )
                )

                taskMmu.writeText(
                    lines.joinToString("\n") + "\n"
                )

                println(
                    "page_size_compat.h missing or doesn't declare " +
                    "__fold_filemap_fixup_entry on this baseline; " +
                    "added local stub to fs/proc/task_mmu.c"
                )
            }
        }
    }

    /*
     * Android 12 / Android 13 5.10:
     * Convert the 4-argument set_nameidata() call
     * to the 3-argument version.
     */
    if (
        kernelModule == "android12-5.10" ||
        kernelModule == "android13-5.10"
    ) {

        val namei =
            f("fs/namei.c")

        if (
            namei.exists() &&
            namei.readText().contains(
                "set_nameidata(nd, old_dfd, fake_filename, NULL)"
            )
        ) {

            println(
                "Fixing set_nameidata calls for 5.10 (4-arg -> 3-arg)"
            )

            namei.replaceEachLine(
                Regex(
                    """set_nameidata\(nd, old_dfd, fake_filename, NULL\)"""
                ),
                "set_nameidata(nd, old_dfd, fake_filename)"
            )
        }
    }
}


/* ============================================================
 * Apply Patches
 * ============================================================ */

fun apply() {

    /* --------------------------------------------------------
     * Android 12 - 5.10
     * -------------------------------------------------------- */

    if (kernelModule == "android12-5.10") {

        if (sublevel <= 43) {

            println(
                "Applying base.c Android 12 5.10 Fake Patch"
            )

            f("fs/proc/base.c").replaceEachLine(
                Regex(
                    """(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,"""
                ),
                "size_t this_len = min_t(size_t,"
            )
        }

        if (sublevel <= 117) {

            println(
                "Applying fdinfo.c Android 12 5.10 Fake Patch"
            )

            applyFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }
    }


    /* --------------------------------------------------------
     * Android 13 - 5.10
     * -------------------------------------------------------- */

    if (kernelModule == "android13-5.10") {

        if (sublevel <= 107) {

            println(
                "Applying fdinfo.c Android 13 5.10 Fake Patch"
            )

            applyFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }
    }


    /* --------------------------------------------------------
     * Android 13 - 5.15
     * -------------------------------------------------------- */

    if (kernelModule == "android13-5.15") {

        if (sublevel <= 41) {

            println(
                "Applying namespace.c Android 13 5.15 SUSFS fixes"
            )

            f("fs/namespace.c").insertAfter(
                Regex(
                    """^#include <linux/shmem_fs\.h>$"""
                ),
                "#include <linux/mnt_idmapping.h>"
            )

            println(
                "Applying open.c Android 13 5.15 Fake Patch"
            )

            f("fs/open.c").insertAfter(
                Regex(
                    """^#include <linux/compat\.h>$"""
                ),
                "#include <linux/mnt_idmapping.h>"
            )

            println(
                "Applying fdinfo.c Android 13 5.15 Fake Patch"
            )

            applyFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }

        if (sublevel >= 123) {

            println(
                "Applying memory.c Android 13 5.15 Fake Patch"
            )

            f("mm/memory.c").deleteLine(
                Regex(
                    """#include <linux/swap_slots\.h>"""
                )
            )
        }

        if (sublevel >= 197) {

            println(
                "Applying namespace.c Android 13 5.15 Fake Patch"
            )

            f("fs/namespace.c").deleteLine(
                Regex(
                    """^#include <trace/hooks/blk\.h>$"""
                )
            )
        }

        if (sublevel >= 206) {

            println(
                "Applying task_mmu.c Android 13 5.15 Fake Patch"
            )

            f("fs/proc/task_mmu.c").deleteLine(
                Regex(
                    """^#include <trace/hooks/mm\.h>$"""
                )
            )
        }
    }


    /* --------------------------------------------------------
     * Android 14 - 6.1
     * -------------------------------------------------------- */

    if (kernelModule == "android14-6.1") {

        if (sublevel <= 25) {

            println(
                "Applying base.c Android 14 6.1 Fake Patch"
            )

            f("fs/proc/base.c").insertAfter(
                Regex(
                    """^#include <trace/events/oom\.h>$"""
                ),
                "#include <trace/hooks/sched.h>"
            )
        }

        if (sublevel <= 141) {

            println(
                "Applying base.c Android 14 6.1 Fake Patch"
            )

            f("fs/proc/base.c").insertAfter(
                Regex(
                    """^#include <linux/cpufreq_times\.h>$"""
                ),
                "#include <linux/dma-buf.h>"
            )
        }

        if (sublevel >= 157) {

            println(
                "Applying namespace.c Android 14 6.1 Fake Patch"
            )

            f("fs/namespace.c").deleteLine(
                Regex(
                    """^#include <trace/hooks/blk\.h>$"""
                )
            )
        }
    }


    /* --------------------------------------------------------
     * Android 15 - 6.6
     * -------------------------------------------------------- */

    if (kernelModule == "android15-6.6") {

        if (sublevel <= 30) {

            println(
                "Applying task_mmu.c, namespace.c Android 15 6.6 Fake Patch"
            )

            applyAndroid15VmaBlock(
                f("fs/proc/task_mmu.c"),
                f("fs/namespace.c")
            )
        }

        if (sublevel <= 57) {

            println(
                "Applying memory.c Android 15 6.6 Fake Patch"
            )

            f("mm/memory.c").insertAfter(
                Regex(
                    """^#include <linux/sched/sysctl\.h>$"""
                ),
                "#include <linux/zswap.h>"
            )
        }

        if (sublevel <= 92) {

            println(
                "Applying base.c Android 15 6.6 Fake Patch"
            )

            f("fs/proc/base.c").insertAfter(
                Regex(
                    """^#include <linux/cpufreq_times\.h>$"""
                ),
                "#include <linux/dma-buf.h>"
            )
        }
    }


    /* --------------------------------------------------------
     * Android 16 - 6.12
     * -------------------------------------------------------- */

    if (kernelModule == "android16-6.12") {

        if (sublevel >= 58) {

            println(
                "Applying exec.c Android 16 6.12 Fake Patch"
            )

            f("fs/exec.c").deleteLine(
                Regex(
                    """^#include <linux/dma-buf\.h>$"""
                )
            )
        }

        if (sublevel >= 69) {

            println(
                "Applying task_mmu.c Android 16 6.12 Fake Patch"
            )

            f("fs/proc/task_mmu.c").replaceEachLine(
                Regex(
                    """vma_data_pages"""
                ),
                "vma_pages"
            )
        }
    }
}


/* ============================================================
 * Postfix
 * ============================================================ */

fun postfix() {
    applyPostPatchFixups()
}


/* ============================================================
 * Revert Patches
 * ============================================================ */

fun revert() {

    /* --------------------------------------------------------
     * Android 12 - 5.10
     * -------------------------------------------------------- */

    if (kernelModule == "android12-5.10") {

        if (sublevel <= 43) {

            println(
                "Reverting base.c Android 12 5.10 Fake Patch"
            )

            f("fs/proc/base.c").replaceWholeLine(
                "size_t this_len = min_t(size_t, count, PAGE_SIZE);",
                "int this_len = min_t(int, count, PAGE_SIZE);"
            )
        }
    }


    /* --------------------------------------------------------
     * Android 13 - 5.15
     * -------------------------------------------------------- */

    if (kernelModule == "android13-5.15") {

        if (sublevel <= 41) {

            println(
                "Reverting namespace.c Android 13 5.15 Fake Patch"
            )

            f("fs/namespace.c").deleteLine(
                Regex(
                    """#include <linux/mnt_idmapping\.h>$"""
                )
            )

            println(
                "Reverting open.c Android 13 5.15 Fake Patch"
            )

            f("fs/open.c").deleteLine(
                Regex(
                    """#include <linux/mnt_idmapping\.h>$"""
                )
            )

            f("fs/susfs.c").replaceEachLine(
                Regex(
                    Regex.escape(
                        "i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val"
                    )
                ),
                "i_uid_into_mnt(&init_user_ns, &fi->inode).val"
            )

            f("fs/susfs.c").replaceEachLine(
                Regex(
                    Regex.escape(
                        "i_uid_into_mnt(i_user_ns(inode), inode).val"
                    )
                ),
                "i_uid_into_mnt(&init_user_ns, inode).val"
            )
        }

        if (sublevel >= 123) {

            println(
                "Reverting memory.c Android 13 5.15 Fake Patch"
            )

            f("mm/memory.c").insertBefore(
                Regex(
                    """#ifdef CONFIG_KSU_SUSFS_SUS_MAP"""
                ),
                "#include <linux/swap_slots.h>"
            )
        }

        if (sublevel >= 197) {

            println(
                "Reverting namespace.c Android 13 5.15 Fake Patch"
            )

            f("fs/namespace.c").insertAfter(
                Regex(
                    """^#include "internal\.h"$"""
                ),
                "#include <trace/hooks/blk.h>"
            )
        }

        if (sublevel >= 206) {

            println(
                "Reverting task_mmu.c Android 13 5.15 Fake Patch"
            )

            f("fs/proc/task_mmu.c").insertAfter(
                Regex(
                    """^#include <linux/pkeys\.h>$"""
                ),
                "#include <trace/hooks/mm.h>"
            )
        }
    }


    /* --------------------------------------------------------
     * Android 14 - 6.1
     * -------------------------------------------------------- */

    if (kernelModule == "android14-6.1") {

        if (sublevel <= 25) {

            println(
                "Reverting base.c Android 14 6.1 Fake Patch"
            )

            f("fs/proc/base.c").deleteLine(
                Regex(
                    """^#include <trace/hooks/sched\.h>$"""
                )
            )
        }

        if (sublevel <= 141) {

            println(
                "Reverting base.c Android 14 6.1 Fake Patch"
            )

            f("fs/proc/base.c").deleteLine(
                Regex(
                    """^#include <linux/dma-buf\.h>$"""
                )
            )
        }
    }


    /* --------------------------------------------------------
     * Android 15 - 6.6
     * -------------------------------------------------------- */

    if (kernelModule == "android15-6.6") {

        if (sublevel <= 30) {

            println(
                "Reverting task_mmu.c, namespace.c Android 15 6.6 Fake Patch"
            )

            revertAndroid15VmaBlock(
                f("fs/proc/task_mmu.c"),
                f("fs/namespace.c")
            )
        }

        if (sublevel <= 57) {

            println(
                "Reverting memory.c Android 15 6.6 Fake Patch"
            )

            f("mm/memory.c").deleteLine(
                Regex(
                    """^#include <linux/zswap\.h>$"""
                )
            )
        }

        if (sublevel <= 92) {

            println(
                "Reverting base.c Android 15 6.6 Fake Patch"
            )

            f("fs/proc/base.c").deleteLine(
                Regex(
                    """^#include <linux/dma-buf\.h>$"""
                )
            )
        }
    }


    /* --------------------------------------------------------
     * Android 16 - 6.12
     * -------------------------------------------------------- */

    if (kernelModule == "android16-6.12") {

        if (sublevel >= 58) {

            println(
                "Reverting exec.c Android 16 6.12 Fake Patch"
            )

            f("fs/exec.c").insertAfterFirst(
                Regex("""^#include """),
                "#include <linux/dma-buf.h>"
            )
        }

        if (sublevel >= 69) {

            println(
                "Reverting task_mmu.c Android 16 6.12 Fake Patch"
            )

            f("fs/proc/task_mmu.c").replaceEachLine(
                Regex(
                    """vma_pages"""
                ),
                "vma_data_pages"
            )
        }
    }
}


/* ============================================================
 * Main
 * ============================================================ */

when (mode) {

    "apply" -> apply()

    "postfix" -> postfix()

    "revert" -> revert()

    else -> {

        println(
            "Usage: kotlin PatchFakePatches.main.kts " +
            "<apply|postfix|revert> [workDir]"
        )

        exitProcess(1)
    }
}
