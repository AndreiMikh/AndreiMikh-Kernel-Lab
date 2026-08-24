#!/usr/bin/env kotlin

import java.io.File
import kotlin.system.exitProcess

val kernelModule = System.getenv("KERNELMODULE").orEmpty()
val sublevel = System.getenv("SUBLEVEL")?.toIntOrNull() ?: 0
val mode = args.getOrNull(0) ?: "apply"
val workDir = args.getOrNull(1) ?: "kernel_workspace/kernel_platform/common"

fun file(path: String) = File(workDir, path)

fun requireFile(path: String): File {
    val f = file(path)
    if (!f.exists()) error("Required file not found: ${f.path}")
    return f
}

fun log(msg: String) = println("→ $msg")

fun File.edit(block: MutableList<String>.() -> Boolean): Boolean {
    val lines = readLines().toMutableList()
    val changed = lines.block()
    if (changed) writeText(lines.joinToString("\n") + "\n")
    return changed
}

fun File.insertAfter(regex: Regex, vararg text: String): Boolean {
    if (!exists()) error("File not found: $path")

    return edit {
        if (text.all { it in this }) return@edit false

        val out = mutableListOf<String>()
        var changed = false

        forEach { line ->
            out += line
            if (regex.containsMatchIn(line)) {
                out += text
                changed = true
            }
        }

        if (!changed) return@edit false

        clear()
        addAll(out)
        true
    }
}

fun File.insertAfterFirst(regex: Regex, vararg text: String): Boolean {
    if (!exists()) error("File not found: $path")

    return edit {
        if (text.all { it in this }) return@edit false

        val index = indexOfFirst { regex.containsMatchIn(it) }
        if (index < 0) return@edit false

        addAll(index + 1, text.toList())
        true
    }
}

fun File.insertBefore(regex: Regex, vararg text: String): Boolean {
    if (!exists()) error("File not found: $path")

    return edit {
        if (text.all { it in this }) return@edit false

        val out = mutableListOf<String>()
        var changed = false

        forEach { line ->
            if (regex.containsMatchIn(line)) {
                out += text
                changed = true
            }
            out += line
        }

        if (!changed) return@edit false

        clear()
        addAll(out)
        true
    }
}

fun File.deleteLine(regex: Regex): Boolean {
    if (!exists()) error("File not found: $path")

    return edit {
        val oldSize = size
        removeAll { regex.containsMatchIn(it) }
        size != oldSize
    }
}

fun File.deleteBlock(start: Regex, end: Regex): Boolean {
    if (!exists()) error("File not found: $path")

    return edit {
        val out = mutableListOf<String>()
        var inBlock = false
        var changed = false

        forEach { line ->
            if (!inBlock && start.containsMatchIn(line)) {
                inBlock = true
                changed = true
            } else if (inBlock) {
                if (end.containsMatchIn(line)) inBlock = false
            } else {
                out += line
            }
        }

        if (!changed) return@edit false

        clear()
        addAll(out)
        true
    }
}

fun File.replace(regex: Regex, replacement: String): Int {
    if (!exists()) error("File not found: $path")

    var count = 0

    edit {
        forEachIndexed { i, line ->
            val replaced = regex.replace(line, replacement)

            if (replaced != line) {
                this[i] = replaced
                count++
            }
        }

        count > 0
    }

    return count
}

fun File.replaceExact(old: String, new: String): Boolean {
    if (!exists()) error("File not found: $path")

    return edit {
        var changed = false

        forEachIndexed { i, line ->
            if (line == old) {
                this[i] = new
                changed = true
            }
        }

        changed
    }
}

fun File.includeAfter(header: String, include: String) =
    insertAfter(
        Regex("^${Regex.escape(header)}$"),
        include
    )

fun File.includeAfterFirst(include: String) =
    insertAfterFirst(
        Regex("""^#include """),
        include
    )

fun logChange(changed: Boolean, message: String) {
    if (changed) log(message)
}

fun requireMatch(f: File, regex: Regex, description: String) {
    if (!f.readText().contains(regex)) {
        error("Required pattern not found in ${f.path}: $description")
    }
}

val fdinfoStart = Regex("""^[ \t]*/\*$""")
val fdinfoEnd = Regex("""^[ \t]*u32 mask = mark->mask & IN_ALL_EVENTS;$""")
val inotifyFunc = Regex(
    """^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$"""
)

fun addInotifyHelper(f: File) {
    if (f.readText().contains("inotify_mark_user_mask(")) return

    f.insertBeforeFirst(
        inotifyFunc,
        "static inline u32 inotify_mark_user_mask(struct fsnotify_mark *mark) {",
        "\treturn mark->mask & IN_ALL_EVENTS;",
        "}",
        ""
    )

    log("Added inotify_mark_user_mask()")
}

fun applyFdinfo(f: File) {
    requireFile(f.relativeTo(File(workDir)).path)

    f.deleteBlock(fdinfoStart, fdinfoEnd)

    val maskChanged = f.replace(
        Regex("""\bmask,\s*mark->ignored_mask"""),
        "inotify_mark_user_mask(mark)"
    )

    val ignoredChanged = f.replace(
        Regex("""ignored_mask:%x"""),
        "ignored_mask:0"
    )

    addInotifyHelper(f)

    if (maskChanged > 0 || ignoredChanged > 0) {
        log("Applied fdinfo compatibility fix")
    }
}

fun applyVma(task: File, namespace: File) {
    requireFile("fs/proc/task_mmu.c")
    requireFile("fs/namespace.c")

    logChange(
        task.insertAfter(
            Regex("""smap_gather_stats\(vma, &mss, last_vma_end\);"""),
            "last_vma_end = vma->vm_end;"
        ),
        "Added last_vma_end assignment"
    )

    task.edit {
        val assignment = indexOfLast {
            it.contains("last_vma_end = vma->vm_end;")
        }

        if (assignment < 0) return@edit false

        val alreadyWrapped =
            assignment + 1 < size &&
            this[assignment + 1].trim() == "}"

        if (alreadyWrapped) return@edit false

        this[assignment] = "\t\t\t\t$this[assignment]"
        add(assignment + 1, "\t\t\t}")

        val ifIndex = (assignment downTo 0).firstOrNull {
            Regex("""if\s*\(vma->vm_end > last_vma_end\)""")
                .containsMatchIn(this[it])
        } ?: return@edit true

        this[ifIndex] = Regex("""\)\s*$""")
            .replace(this[ifIndex], ") {")

        true
    }

    logChange(
        namespace.includeAfter(
            "#include <trace/hooks/blk.h>",
            "#include <trace/hooks/fs.h>"
        ),
        "Added trace/hooks/fs.h"
    )

    logChange(
        task.insertAfter(
            Regex("""int ret = 0, copied = 0;"""),
            "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;",
            "\tpagemap_entry_t *res = NULL;"
        ),
        "Added VMA compatibility variables"
    )
}

fun revertVma(task: File, namespace: File) {
    requireFile("fs/proc/task_mmu.c")
    requireFile("fs/namespace.c")

    namespace.deleteLine(
        Regex("""^#include <trace/hooks/fs\.h>$""")
    )

    task.deleteLine(
        Regex("""^\s*unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;$""")
    )

    task.deleteLine(
        Regex("""^\s*pagemap_entry_t \*res = NULL;$""")
    )

    task.edit {
        val closing = indexOfFirst {
            it.trim() == "}" &&
            it != last()
        }

        if (closing < 0) return@edit false

        val assignment = (closing downTo 0).firstOrNull {
            this[it].contains("last_vma_end = vma->vm_end;")
        } ?: return@edit false

        val ifIndex = (assignment downTo 0).firstOrNull {
            Regex("""if\s*\(vma->vm_end > last_vma_end\)""")
                .containsMatchIn(this[it])
        } ?: return@edit false

        this.removeAt(closing)
        this[assignment - if (closing < assignment) 1 else 0] =
            this[assignment - if (closing < assignment) 1 else 0]
                .removePrefix("\t\t\t\t")

        val actualIf = ifIndex - if (closing < ifIndex) 1 else 0

        if (actualIf in indices) {
            this[actualIf] = Regex("""\)\s*\{$""")
                .replace(this[actualIf], ")")
        }

        true
    }
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
                true
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
                header.readText().contains(
                    "__fold_filemap_fixup_entry"
                )
            ) {
                if (
                    !content.contains(
                        "#include <linux/page_size_compat.h>"
                    )
                ) {
                    task.insertAfterFirst(
                        Regex("""^#include """),
                        "#include <linux/page_size_compat.h>"
                    )

                    log("Added page_size_compat.h include")
                }
            } else {
                task.edit {
                    val lastInclude = indexOfLast {
                        it.trimStart().startsWith("#include")
                    }

                    val at =
                        if (lastInclude >= 0) lastInclude + 1
                        else 1

                    addAll(
                        at,
                        listOf(
                            "#ifndef __fold_filemap_fixup_entry",
                            "static inline void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end) { }",
                            "#endif /* __fold_filemap_fixup_entry */"
                        )
                    )

                    true
                }

                log("Added __fold_filemap_fixup_entry() stub")
            }
        }
    }

    if (
        kernelModule == "android12-5.10" ||
        kernelModule == "android13-5.10"
    ) {
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
                val f = requireFile("fs/proc/base.c")
                log("Android 12 5.10 base.c")

                f.replace(
                    Regex(
                        """(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,"""
                    ),
                    "size_t this_len = min_t(size_t,"
                )
            }

            if (sublevel <= 117) {
                log("Android 12 5.10 fdinfo.c")
                applyFdinfo(requireFile("fs/notify/fdinfo.c"))
            }
        }

        "android13-5.10" -> {
            if (sublevel <= 107) {
                log("Android 13 5.10 fdinfo.c")
                applyFdinfo(requireFile("fs/notify/fdinfo.c"))
            }
        }

        "android13-5.15" -> {
            if (sublevel <= 41) {
                log("Android 13 5.15 namespace/open/fdinfo")

                requireFile("fs/namespace.c").includeAfter(
                    "#include <linux/shmem_fs.h>",
                    "#include <linux/mnt_idmapping.h>"
                )

                requireFile("fs/open.c").includeAfter(
                    "#include <linux/compat.h>",
                    "#include <linux/mnt_idmapping.h>"
                )

                applyFdinfo(requireFile("fs/notify/fdinfo.c"))
            }

            if (sublevel >= 123) {
                log("Android 13 5.15 memory.c")

                requireFile("mm/memory.c").deleteLine(
                    Regex("""^#include <linux/swap_slots\.h>$""")
                )
            }

            if (sublevel >= 197) {
                log("Android 13 5.15 namespace.c")

                requireFile("fs/namespace.c").deleteLine(
                    Regex("""^#include <trace/hooks/blk\.h>$""")
                )
            }

            if (sublevel >= 206) {
                log("Android 13 5.15 task_mmu.c")

                requireFile("fs/proc/task_mmu.c").deleteLine(
                    Regex("""^#include <trace/hooks/mm\.h>$""")
                )
            }
        }

        "android14-6.1" -> {
            if (sublevel <= 25) {
                log("Android 14 6.1 sched.h")

                requireFile("fs/proc/base.c").includeAfter(
                    "#include <trace/events/oom.h>",
                    "#include <trace/hooks/sched.h>"
                )
            }

            if (sublevel <= 141) {
                log("Android 14 6.1 dma-buf.h")

                requireFile("fs/proc/base.c").includeAfter(
                    "#include <linux/cpufreq_times.h>",
                    "#include <linux/dma-buf.h>"
                )
            }

            if (sublevel >= 157) {
                log("Android 14 6.1 namespace.c")

                requireFile("fs/namespace.c").deleteLine(
                    Regex("""^#include <trace/hooks/blk\.h>$""")
                )
            }
        }

        "android15-6.6" -> {
            if (sublevel <= 30) {
                log("Android 15 6.6 VMA")

                applyVma(
                    requireFile("fs/proc/task_mmu.c"),
                    requireFile("fs/namespace.c")
                )
            }

            if (sublevel <= 57) {
                log("Android 15 6.6 zswap.h")

                requireFile("mm/memory.c").includeAfter(
                    "#include <linux/sched/sysctl.h>",
                    "#include <linux/zswap.h>"
                )
            }

            if (sublevel <= 92) {
                log("Android 15 6.6 dma-buf.h")

                requireFile("fs/proc/base.c").includeAfter(
                    "#include <linux/cpufreq_times.h>",
                    "#include <linux/dma-buf.h>"
                )
            }
        }

        "android16-6.12" -> {
            if (sublevel >= 58) {
                log("Android 16 6.12 exec.c")

                requireFile("fs/exec.c").deleteLine(
                    Regex("""^#include <linux/dma-buf\.h>$""")
                )
            }

            if (sublevel >= 69) {
                log("Android 16 6.12 task_mmu.c")

                requireFile("fs/proc/task_mmu.c").replace(
                    Regex("""vma_data_pages"""),
                    "vma_pages"
                )
            }
        }

        else -> log("No apply patches for $kernelModule")
    }
}

fun revert() {
    when (kernelModule) {
        "android12-5.10" -> {
            if (sublevel <= 43) {
                log("Reverting Android 12 5.10 base.c")

                requireFile("fs/proc/base.c").replaceExact(
                    "size_t this_len = min_t(size_t, count, PAGE_SIZE);",
                    "int this_len = min_t(int, count, PAGE_SIZE);"
                )
            }
        }

        "android13-5.15" -> {
            if (sublevel <= 41) {
                log("Reverting Android 13 5.15")

                requireFile("fs/namespace.c").deleteLine(
                    Regex("""^#include <linux/mnt_idmapping\.h>$""")
                )

                requireFile("fs/open.c").deleteLine(
                    Regex("""^#include <linux/mnt_idmapping\.h>$""")
                )

                requireFile("fs/susfs.c").replace(
                    Regex.escape(
                        "i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val"
                    ).toRegex(),
                    "i_uid_into_mnt(&init_user_ns, &fi->inode).val"
                )

                requireFile("fs/susfs.c").replace(
                    Regex.escape(
                        "i_uid_into_mnt(i_user_ns(inode), inode).val"
                    ).toRegex(),
                    "i_uid_into_mnt(&init_user_ns, inode).val"
                )
            }

            if (sublevel >= 123) {
                requireFile("mm/memory.c").insertBefore(
                    Regex("""#ifdef CONFIG_KSU_SUSFS_SUS_MAP"""),
                    "#include <linux/swap_slots.h>"
                )
            }

            if (sublevel >= 197) {
                requireFile("fs/namespace.c").insertAfter(
                    Regex("""^#include "internal\.h"$"""),
                    "#include <trace/hooks/blk.h>"
                )
            }

            if (sublevel >= 206) {
                requireFile("fs/proc/task_mmu.c").insertAfter(
                    Regex("""^#include <linux/pkeys\.h>$"""),
                    "#include <trace/hooks/mm.h>"
                )
            }
        }

        "android14-6.1" -> {
            if (sublevel <= 25) {
                requireFile("fs/proc/base.c").deleteLine(
                    Regex("""^#include <trace/hooks/sched\.h>$""")
                )
            }

            if (sublevel <= 141) {
                requireFile("fs/proc/base.c").deleteLine(
                    Regex("""^#include <linux/dma-buf\.h>$""")
                )
            }
        }

        "android15-6.6" -> {
            if (sublevel <= 30) {
                log("Reverting Android 15 6.6 VMA")

                revertVma(
                    requireFile("fs/proc/task_mmu.c"),
                    requireFile("fs/namespace.c")
                )
            }

            if (sublevel <= 57) {
                requireFile("mm/memory.c").deleteLine(
                    Regex("""^#include <linux/zswap\.h>$""")
                )
            }

            if (sublevel <= 92) {
                requireFile("fs/proc/base.c").deleteLine(
                    Regex("""^#include <linux/dma-buf\.h>$""")
                )
            }
        }

        "android16-6.12" -> {
            if (sublevel >= 58) {
                requireFile("fs/exec.c").includeAfterFirst(
                    "#include <linux/dma-buf.h>"
                )
            }

            if (sublevel >= 69) {
                requireFile("fs/proc/task_mmu.c").replace(
                    Regex("""vma_pages"""),
                    "vma_data_pages"
                )
            }
        }

        else -> log("No revert patches for $kernelModule")
    }
}

fun validate() {
    log("Validating $kernelModule sublevel $sublevel")

    val missing = mutableListOf<String>()

    fun check(path: String) {
        if (!file(path).exists()) missing += path
    }

    when (kernelModule) {
        "android12-5.10" -> {
            if (sublevel <= 43) check("fs/proc/base.c")
            if (sublevel <= 117) check("fs/notify/fdinfo.c")
        }

        "android13-5.10" -> {
            if (sublevel <= 107) check("fs/notify/fdinfo.c")
        }

        "android13-5.15" -> {
            if (sublevel <= 41) {
                check("fs/namespace.c")
                check("fs/open.c")
                check("fs/notify/fdinfo.c")
            }
            if (sublevel >= 123) check("mm/memory.c")
            if (sublevel >= 197) check("fs/namespace.c")
            if (sublevel >= 206) check("fs/proc/task_mmu.c")
        }

        "android14-6.1" -> {
            if (sublevel <= 141) check("fs/proc/base.c")
            if (sublevel >= 157) check("fs/namespace.c")
        }

        "android15-6.6" -> {
            if (sublevel <= 30) {
                check("fs/proc/task_mmu.c")
                check("fs/namespace.c")
            }
            if (sublevel <= 57) check("mm/memory.c")
            if (sublevel <= 92) check("fs/proc/base.c")
        }

        "android16-6.12" -> {
            if (sublevel >= 58) check("fs/exec.c")
            if (sublevel >= 69) check("fs/proc/task_mmu.c")
            check("fs/open.c")
        }
    }

    if (missing.isNotEmpty()) {
        error(
            "Validation failed. Missing files:\n" +
            missing.joinToString("\n") { "  - $it" }
        )
    }

    log("Validation passed")
}

when (mode) {
    "apply" -> {
        apply()
        postFix()
        validate()
    }

    "postfix" -> {
        postFix()
        validate()
    }

    "revert" -> {
        revert()
        validate()
    }

    "check", "validate" -> validate()

    else -> {
        println(
            "Usage: kotlin FakePatches.kts " +
            "<apply|postfix|revert|check> [workDir]"
        )
        exitProcess(1)
    }
}
