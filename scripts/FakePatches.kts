#!/usr/bin/env kotlin

import java.io.File
import kotlin.system.exitProcess

fun File.edit(block: MutableList<String>.() -> Unit) {
    val lines = readLines().toMutableList()
    lines.block()
    writeText(lines.joinToString("\n") + "\n")
}

fun File.insertAfter(regex: Regex, vararg text: String) = edit {
    val out = mutableListOf<String>()
    forEach {
        out += it
        if (regex.containsMatchIn(it)) out += text
    }
    clear()
    addAll(out)
}

fun File.insertAfterFirst(regex: Regex, vararg text: String) = edit {
    indexOfFirst { regex.containsMatchIn(it) }
        .takeIf { it >= 0 }
        ?.let { addAll(it + 1, text.toList()) }
}

fun File.insertBefore(regex: Regex, vararg text: String) = edit {
    val out = mutableListOf<String>()
    forEach {
        if (regex.containsMatchIn(it)) out += text
        out += it
    }
    clear()
    addAll(out)
}

fun File.deleteLine(regex: Regex) = edit {
    removeAll { regex.containsMatchIn(it) }
}

fun File.deleteBlock(start: Regex, end: Regex) = edit {
    val out = mutableListOf<String>()
    var block = false

    forEach { line ->
        if (!block && start.containsMatchIn(line)) {
            block = true
        } else if (block) {
            if (end.containsMatchIn(line)) block = false
        } else {
            out += line
        }
    }

    clear()
    addAll(out)
}

fun File.replace(regex: Regex, replacement: String) = edit {
    forEachIndexed { i, line ->
        this[i] = regex.replace(line, replacement)
    }
}

fun File.replaceExact(old: String, new: String) = edit {
    forEachIndexed { i, line ->
        if (line == old) this[i] = new
    }
}

fun File.includeAfter(header: String, include: String) =
    insertAfter(Regex("^${Regex.escape(header)}$"), include)

fun File.includeAfterFirst(include: String) =
    insertAfterFirst(Regex("""^#include """), include)

val kernelModule = System.getenv("KERNELMODULE").orEmpty()
val sublevel = System.getenv("SUBLEVEL")?.toIntOrNull() ?: 0
val mode = args.getOrNull(0) ?: "apply"
val workDir = args.getOrNull(1) ?: "kernel_workspace/kernel_platform/common"

fun file(path: String) = File(workDir, path)
fun log(msg: String) = println("→ $msg")

val fdinfoStart = Regex("""^[ \t]*/\*$""")
val fdinfoEnd = Regex("""^[ \t]*u32 mask = mark->mask & IN_ALL_EVENTS;$""")
val inotifyFunc = Regex("""^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$""")

fun addInotifyHelper(f: File) {
    f.insertBeforeFirst(
        inotifyFunc,
        "static inline u32 inotify_mark_user_mask(struct fsnotify_mark *mark) {",
        "\treturn mark->mask & IN_ALL_EVENTS;",
        "}",
        ""
    )
}

fun applyFdinfo(f: File) {
    f.deleteBlock(fdinfoStart, fdinfoEnd)
    f.replace(
        Regex("""\bmask,\s*mark->ignored_mask"""),
        "inotify_mark_user_mask(mark)"
    )
    f.replace(
        Regex("""ignored_mask:%x"""),
        "ignored_mask:0"
    )
    log("Adding inotify_mark_user_mask()")
    addInotifyHelper(f)
}

fun applyVma(task: File, namespace: File) {
    task.insertAfter(
        Regex("""smap_gather_stats\(vma, &mss, last_vma_end\);"""),
        "last_vma_end = vma->vm_end;"
    )

    task.edit {
        val assignment = indexOfLast {
            it.contains("last_vma_end = vma->vm_end;")
        }

        if (assignment >= 0) {
            this[assignment] = "\t\t\t\t$this[assignment]"
            add(assignment + 1, "\t\t\t}")

            (assignment downTo 0).firstOrNull {
                Regex("""if\s*\(vma->vm_end > last_vma_end\)""")
                    .containsMatchIn(this[it])
            }?.let {
                this[it] = Regex("""\)\s*$""")
                    .replace(this[it], ") {")
            }
        }
    }

    namespace.includeAfter(
        "#include <trace/hooks/blk.h>",
        "#include <trace/hooks/fs.h>"
    )

    task.insertAfter(
        Regex("""int ret = 0, copied = 0;"""),
        "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;",
        "\tpagemap_entry_t *res = NULL;"
    )
}

fun revertVma(task: File, namespace: File) {
    namespace.deleteLine(
        Regex("""^#include <trace/hooks/fs\.h>$""")
    )

    task.deleteLine(
        Regex("""unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;""")
    )

    task.deleteLine(
        Regex("""pagemap_entry_t \*res = NULL;""")
    )
}

fun postFix() {
    val task = file("fs/proc/task_mmu.c")

    if (task.exists()) {
        var content = task.readText()

        if (
            content.contains("VMA_PAD_START(") &&
            !Regex(
                """#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START"""
            ).containsMatchIn(content)
        ) {
            task.edit {
                addAll(
                    1,
                    listOf(
                        "#ifndef VMA_PAD_START",
                        "#define VMA_PAD_START(vma) ((vma)->vm_end)",
                        "#endif"
                    )
                )
            }

            log("Added VMA_PAD_START fallback")
        }

        content = task.readText()

        if (
            content.contains("__fold_filemap_fixup_entry(") &&
            !Regex(
                """static\s+inline\s+void\s+__fold_filemap_fixup_entry"""
            ).containsMatchIn(content)
        ) {
            val header = file("include/linux/page_size_compat.h")

            if (
                header.exists() &&
                header.readText().contains("__fold_filemap_fixup_entry")
            ) {
                if (!content.contains("#include <linux/page_size_compat.h>")) {
                    task.edit {
                        add(1, "#include <linux/page_size_compat.h>")
                    }

                    log("Added page_size_compat.h include")
                }
            } else {
                task.edit {
                    val lastInclude =
                        indexOfLast {
                            it.trimStart().startsWith("#include")
                        }

                    val at =
                        if (lastInclude >= 0) lastInclude + 1 else 1

                    addAll(
                        at,
                        listOf(
                            "#ifndef __fold_filemap_fixup_entry",
                            "static inline void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end) { }",
                            "#endif /* __fold_filemap_fixup_entry */"
                        )
                    )
                }

                log("Added __fold_filemap_fixup_entry() stub")
            }
        }
    }

    if (kernelModule in setOf("android12-5.10", "android13-5.10")) {
        val namei = file("fs/namei.c")

        if (
            namei.exists() &&
            namei.readText().contains(
                "set_nameidata(nd, old_dfd, fake_filename, NULL)"
            )
        ) {
            log("Fixing set_nameidata() for 5.10")

            namei.replace(
                Regex(
                    """set_nameidata\(nd, old_dfd, fake_filename, NULL\)"""
                ),
                "set_nameidata(nd, old_dfd, fake_filename)"
            )
        }
    }

    if (kernelModule == "android16-6.12") {
        val openC = file("fs/open.c")

        if (
            openC.exists() &&
            openC.readText().contains(
                "getname_flags(filename, lookup_flags, NULL)"
            )
        ) {
            log("Fixing getname_flags() for 6.12")

            openC.replace(
                Regex(
                    """getname_flags\(filename, lookup_flags, NULL\)"""
                ),
                "getname_flags(filename, lookup_flags)"
            )
        }
    }
}

fun apply() {
    when (kernelModule) {
        "android12-5.10" -> {
            if (sublevel <= 43) {
                log("Android 12 5.10 base.c")

                file("fs/proc/base.c").replace(
                    Regex(
                        """(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,"""
                    ),
                    "size_t this_len = min_t(size_t,"
                )
            }

            if (sublevel <= 117) {
                log("Android 12 5.10 fdinfo.c")
                applyFdinfo(file("fs/notify/fdinfo.c"))
            }
        }

        "android13-5.10" -> {
            if (sublevel <= 107) {
                log("Android 13 5.10 fdinfo.c")
                applyFdinfo(file("fs/notify/fdinfo.c"))
            }
        }

        "android13-5.15" -> {
            if (sublevel <= 41) {
                log("Android 13 5.15 namespace/open/fdinfo")

                file("fs/namespace.c").includeAfter(
                    "#include <linux/shmem_fs.h>",
                    "#include <linux/mnt_idmapping.h>"
                )

                file("fs/open.c").includeAfter(
                    "#include <linux/compat.h>",
                    "#include <linux/mnt_idmapping.h>"
                )

                applyFdinfo(file("fs/notify/fdinfo.c"))
            }

            if (sublevel >= 123) {
                log("Android 13 5.15 memory.c")

                file("mm/memory.c").deleteLine(
                    Regex("""#include <linux/swap_slots\.h>""")
                )
            }

            if (sublevel >= 197) {
                log("Android 13 5.15 namespace.c")

                file("fs/namespace.c").deleteLine(
                    Regex("""^#include <trace/hooks/blk\.h>$""")
                )
            }

            if (sublevel >= 206) {
                log("Android 13 5.15 task_mmu.c")

                file("fs/proc/task_mmu.c").deleteLine(
                    Regex("""^#include <trace/hooks/mm\.h>$""")
                )
            }
        }

        "android14-6.1" -> {
            if (sublevel <= 25) {
                log("Android 14 6.1 sched.h")

                file("fs/proc/base.c").includeAfter(
                    "#include <trace/events/oom.h>",
                    "#include <trace/hooks/sched.h>"
                )
            }

            if (sublevel <= 141) {
                log("Android 14 6.1 dma-buf.h")

                file("fs/proc/base.c").includeAfter(
                    "#include <linux/cpufreq_times.h>",
                    "#include <linux/dma-buf.h>"
                )
            }

            if (sublevel >= 157) {
                log("Android 14 6.1 namespace.c")

                file("fs/namespace.c").deleteLine(
                    Regex("""^#include <trace/hooks/blk\.h>$""")
                )
            }
        }

        "android15-6.6" -> {
            if (sublevel <= 30) {
                log("Android 15 6.6 VMA")

                applyVma(
                    file("fs/proc/task_mmu.c"),
                    file("fs/namespace.c")
                )
            }

            if (sublevel <= 57) {
                log("Android 15 6.6 zswap.h")

                file("mm/memory.c").includeAfter(
                    "#include <linux/sched/sysctl.h>",
                    "#include <linux/zswap.h>"
                )
            }

            if (sublevel <= 92) {
                log("Android 15 6.6 dma-buf.h")

                file("fs/proc/base.c").includeAfter(
                    "#include <linux/cpufreq_times.h>",
                    "#include <linux/dma-buf.h>"
                )
            }
        }

        "android16-6.12" -> {
            if (sublevel >= 58) {
                log("Android 16 6.12 exec.c")

                file("fs/exec.c").deleteLine(
                    Regex("""^#include <linux/dma-buf\.h>$""")
                )
            }

            if (sublevel >= 69) {
                log("Android 16 6.12 task_mmu.c")

                file("fs/proc/task_mmu.c").replace(
                    Regex("""vma_data_pages"""),
                    "vma_pages"
                )
            }
        }
    }
}

fun revert() {
    when (kernelModule) {
        "android12-5.10" -> {
            if (sublevel <= 43) {
                log("Reverting Android 12 5.10 base.c")

                file("fs/proc/base.c").replaceExact(
                    "size_t this_len = min_t(size_t, count, PAGE_SIZE);",
                    "int this_len = min_t(int, count, PAGE_SIZE);"
                )
            }
        }

        "android13-5.15" -> {
            if (sublevel <= 41) {
                log("Reverting Android 13 5.15")

                file("fs/namespace.c").deleteLine(
                    Regex("""#include <linux/mnt_idmapping\.h>$""")
                )

                file("fs/open.c").deleteLine(
                    Regex("""#include <linux/mnt_idmapping\.h>$""")
                )

                file("fs/susfs.c").replace(
                    Regex.escape(
                        "i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val"
                    ).toRegex(),
                    "i_uid_into_mnt(&init_user_ns, &fi->inode).val"
                )

                file("fs/susfs.c").replace(
                    Regex.escape(
                        "i_uid_into_mnt(i_user_ns(inode), inode).val"
                    ).toRegex(),
                    "i_uid_into_mnt(&init_user_ns, inode).val"
                )
            }

            if (sublevel >= 123) {
                file("mm/memory.c").insertBefore(
                    Regex("""#ifdef CONFIG_KSU_SUSFS_SUS_MAP"""),
                    "#include <linux/swap_slots.h>"
                )
            }

            if (sublevel >= 197) {
                file("fs/namespace.c").insertAfter(
                    Regex("""^#include "internal\.h"$"""),
                    "#include <trace/hooks/blk.h>"
                )
            }

            if (sublevel >= 206) {
                file("fs/proc/task_mmu.c").insertAfter(
                    Regex("""^#include <linux/pkeys\.h>$"""),
                    "#include <trace/hooks/mm.h>"
                )
            }
        }

        "android14-6.1" -> {
            if (sublevel <= 25) {
                file("fs/proc/base.c").deleteLine(
                    Regex("""^#include <trace/hooks/sched\.h>$""")
                )
            }

            if (sublevel <= 141) {
                file("fs/proc/base.c").deleteLine(
                    Regex("""^#include <linux/dma-buf\.h>$""")
                )
            }
        }

        "android15-6.6" -> {
            if (sublevel <= 30) {
                log("Reverting Android 15 6.6 VMA")

                revertVma(
                    file("fs/proc/task_mmu.c"),
                    file("fs/namespace.c")
                )
            }

            if (sublevel <= 57) {
                file("mm/memory.c").deleteLine(
                    Regex("""^#include <linux/zswap\.h>$""")
                )
            }

            if (sublevel <= 92) {
                file("fs/proc/base.c").deleteLine(
                    Regex("""^#include <linux/dma-buf\.h>$""")
                )
            }
        }

        "android16-6.12" -> {
            if (sublevel >= 58) {
                file("fs/exec.c").includeAfterFirst(
                    "#include <linux/dma-buf.h>"
                )
            }

            if (sublevel >= 69) {
                file("fs/proc/task_mmu.c").replace(
                    Regex("""vma_pages"""),
                    "vma_data_pages"
                )
            }
        }
    }
}

when (mode) {
    "apply" -> apply()
    "postfix" -> postFix()
    "revert" -> revert()
    else -> {
        println(
            "Usage: kotlin FakePatches.kts " +
            "<apply|postfix|revert> [workDir]"
        )
        exitProcess(1)
    }
}
