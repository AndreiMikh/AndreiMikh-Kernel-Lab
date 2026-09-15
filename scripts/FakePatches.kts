```kotlin
#!/usr/bin/env kotlin

import java.io.File
import kotlin.system.exitProcess

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
        if (anchor.containsMatchIn(line)) {
            out.addAll(newLines)
        }

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
    val out = readLines().filterNot {
        pattern.containsMatchIn(it)
    }

    writeText(out.joinToString("\n") + "\n")
}

/** sed '/pattern/,+N d' — delete matching line and the following N lines */
fun File.deleteLineAndFollowing(pattern: Regex, extraLines: Int) {
    val out = mutableListOf<String>()
    var skip = 0

    for (line in readLines()) {
        if (skip > 0) {
            skip--
            continue
        }

        if (pattern.containsMatchIn(line)) {
            skip = extraLines
            continue
        }

        out.add(line)
    }

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
            if (end.containsMatchIn(line)) {
                inBlock = false
            }

            continue
        }

        out.add(line)
    }

    writeText(out.joinToString("\n") + "\n")
}

fun File.replaceEachLine(pattern: Regex, replacement: String) {
    val out = readLines().map {
        pattern.replace(it, replacement)
    }

    writeText(out.joinToString("\n") + "\n")
}

fun File.replaceWholeLine(oldLine: String, newLine: String) {
    val out = readLines().map {
        if (it == oldLine) newLine else it
    }

    writeText(out.joinToString("\n") + "\n")
}

val kernelModule = System.getenv("KERNELMODULE") ?: ""
val sublevel = (System.getenv("SUBLEVEL") ?: "0").toIntOrNull() ?: 0

val mode = args.getOrNull(0) ?: "apply"
val workDir = args.getOrNull(1)
    ?: "kernel_workspace/kernel_platform/common"

fun f(relPath: String) = File(workDir, relPath)

fun File.rel(): String =
    this.path
        .removePrefix("$workDir/")
        .removePrefix("$workDir\\")

fun logApply(file: File, detail: String) =
    println("[APPLY]-${file.rel()}: $detail")

fun logPostfix(file: File, detail: String) =
    println("[POSTFIX]-${file.rel()}: $detail")

fun logRevert(file: File, detail: String) =
    println("[REVERT]-${file.rel()}: $detail")


val fdinfoCommentStart =
    Regex("""^[ \t]*/\*$""")

val fdinfoCommentEnd =
    Regex("""^[ \t]*u32 mask = mark->mask & IN_ALL_EVENTS;$""")

val inotifyFdinfoFuncAnchor =
    Regex("""^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$""")


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

    logApply(
        file,
        "REMOVED INLINE MASK-COMPUTATION COMMENT BLOCK ENDING AT 'U32 MASK = MARK->MASK & IN_ALL_EVENTS;' INSIDE INOTIFY_FDINFO()"
    )

    file.replaceEachLine(
        Regex("""\bmask,\s*mark\.ignored_mask"""),
        "inotify_mark_user_mask(mark)"
    )

    logApply(
        file,
        "REPLACED SEQ_PRINTF ARGUMENT 'MASK, MARK->IGNORED_MASK' WITH INOTIFY_MARK_USER_MASK(MARK) CALL"
    )

    file.replaceEachLine(
        Regex("""ignored_mask:%x"""),
        "ignored_mask:0"
    )

    logApply(
        file,
        "REPLACED FORMAT SPECIFIER 'IGNORED_MASK:%X' WITH LITERAL 'IGNORED_MASK:0'"
    )

    addInotifyMarkUserMaskFunction(file)

    logApply(
        file,
        "INSERTED NEW STATIC INLINE INOTIFY_MARK_USER_MASK() HELPER FUNCTION BEFORE INOTIFY_FDINFO()"
    )
}


fun applyAndroid15VmaBlock(
    taskMmu: File,
    namespace: File
) {
    taskMmu.insertAfter(
        Regex("""smap_gather_stats\(vma, &mss, last_vma_end\);"""),
        "last_vma_end = vma->vm_end;"
    )

    logApply(
        taskMmu,
        "INSERTED 'LAST_VMA_END = VMA->VM_END;' IMMEDIATELY AFTER THE SMAP_GATHER_STATS() CALL"
    )

    val lines = taskMmu.readLines().toMutableList()

    val ifPattern =
        Regex("""if\s*\(vma->vm_end > last_vma_end\)""")

    val trailingParen =
        Regex("""\)\s*$""")

    for (i in lines.indices.reversed()) {
        if (lines[i].contains("last_vma_end = vma->vm_end;")) {
            lines[i] = "\t\t\t\t" + lines[i]

            lines.add(
                i + 1,
                "\t\t\t}"
            )

            for (j in i downTo 0) {
                if (ifPattern.containsMatchIn(lines[j])) {
                    lines[j] = trailingParen.replace(
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

    logApply(
        taskMmu,
        "OPENED A NEW '{ ... }' BLOCK AROUND THE LAST_VMA_END UPDATE AND RE-INDENTED THE STATEMENT"
    )

    namespace.insertAfter(
        Regex("""#include <trace/hooks/blk\.h>"""),
        "#include <trace/hooks/fs.h>"
    )

    logApply(
        namespace,
        "ADDED #INCLUDE <TRACE/HOOKS/FS.H> DIRECTLY AFTER #INCLUDE <TRACE/HOOKS/BLK.H>"
    )

    taskMmu.insertAfter(
        Regex("""int ret = 0, copied = 0;"""),
        "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;",
        "\tpagemap_entry_t *res = NULL;"
    )

    logApply(
        taskMmu,
        "DECLARED NR_SUBPAGES AND PAGEMAP_ENTRY_T *RES AFTER 'INT RET = 0, COPIED = 0;'"
    )
}


fun revertAndroid15VmaBlock(
    taskMmu: File,
    namespace: File
) {
    namespace.deleteLine(
        Regex("""#include <trace/hooks/fs\.h>""")
    )

    logRevert(
        namespace,
        "REMOVED #INCLUDE <TRACE/HOOKS/FS.H>"
    )

    taskMmu.deleteLine(
        Regex("""unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;""")
    )

    logRevert(
        taskMmu,
        "REMOVED NR_SUBPAGES DECLARATION"
    )

    taskMmu.deleteLine(
        Regex("""pagemap_entry_t \*res = NULL;""")
    )

    logRevert(
        taskMmu,
        "REMOVED PAGEMAP_ENTRY_T *RES DECLARATION"
    )
}


fun applyPostPatchFixups() {
    val taskMmu = f("fs/proc/task_mmu.c")

    if (taskMmu.exists()) {
        val content = taskMmu.readText()

        if (
            content.contains("VMA_PAD_START(") &&
            !Regex(
                """#include <linux/pgsize_migration(_inline)?\.h>|define VMA_PAD_START"""
            ).containsMatchIn(content)
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

            taskMmu.writeText(
                lines.joinToString("\n") + "\n"
            )

            logPostfix(
                taskMmu,
                "INSERTED FALLBACK MACRO '#DEFINE VMA_PAD_START(VMA) ((VMA)->VM_END)'"
            )
        }

        val content2 = taskMmu.readText()

        if (
            content2.contains("__fold_filemap_fixup_entry(") &&
            !Regex(
                """static\s+inline\s+void\s+__fold_filemap_fixup_entry"""
            ).containsMatchIn(content2)
        ) {
            val headerFile =
                f("include/linux/page_size_compat.h")

            val headerDeclaresFn =
                headerFile.exists() &&
                headerFile.readText()
                    .contains("__fold_filemap_fixup_entry")

            if (headerDeclaresFn) {
                if (
                    !content2.contains(
                        "#include <linux/page_size_compat.h>"
                    )
                ) {
                    val lines =
                        taskMmu.readLines().toMutableList()

                    lines.add(
                        1,
                        "#include <linux/page_size_compat.h>"
                    )

                    taskMmu.writeText(
                        lines.joinToString("\n") + "\n"
                    )

                    logPostfix(
                        taskMmu,
                        "ADDED #INCLUDE <LINUX/PAGE_SIZE_COMPAT.H>"
                    )
                }
            } else {
                val lines =
                    taskMmu.readLines().toMutableList()

                val lastIncludeIdx =
                    lines.indexOfLast {
                        it.trimStart().startsWith("#include")
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

                logPostfix(
                    taskMmu,
                    "INSERTED NO-OP STATIC INLINE __FOLD_FILEMAP_FIXUP_ENTRY() STUB"
                )
            }
        }
    }

    if (
        kernelModule == "android12-5.10" ||
        kernelModule == "android13-5.10"
    ) {
        val namei = f("fs/namei.c")

        if (
            namei.exists() &&
            namei.readText()
                .contains(
                    "set_nameidata(nd, old_dfd, fake_filen_
```
