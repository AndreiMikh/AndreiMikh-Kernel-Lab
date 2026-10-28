#!/usr/bin/env kotlin
import java.io.File
import kotlin.system.exitProcess

// ==========================
// Basic File Helpers
// ==========================
fun File.requireExists() {
    check(exists()) {
        "Required file does not exist: $path"
    }
}
fun File.lines(): MutableList<String> =
    readLines().toMutableList()
fun File.writeLines(lines: List<String>) {
    writeText(lines.joinToString("\n") + "\n")
}
fun File.rel(): String =
    path.removePrefix("$workDir/").removePrefix("$workDir\\")

// ==========================
// Safe Insert Helpers
// ==========================
fun File.insertAfterFirst(
    anchor: Regex,
    vararg newLines: String
): Boolean {
    requireExists()
    val lines = lines()
    if (newLines.all { it in lines }) {
        return false
    }
    val index = lines.indexOfFirst { anchor.containsMatchIn(it) }
    check(index >= 0) {
        "Anchor Not Found in $path: ${anchor.pattern}"
    }
    lines.addAll(index + 1, newLines.toList())
    writeLines(lines)
    return true
}
fun File.insertAfter(
    anchor: Regex,
    vararg newLines: String
): Boolean {
    requireExists()
    val lines = lines()
    var changed = false
    for (i in lines.indices.reversed()) {
        if (anchor.containsMatchIn(lines[i])) {
            val alreadyPresent =
                newLines.all { it in lines }
            if (!alreadyPresent) {
                lines.addAll(i + 1, newLines.toList())
                changed = true
            }
        }
    }
    check(changed || newLines.all { it in lines }) {
        "Anchor Not Found in $path: ${anchor.pattern}"
    }
    if (changed) {
        writeLines(lines)
    }
    return changed
}
fun File.insertBeforeFirst(
    anchor: Regex,
    vararg newLines: String
): Boolean {
    requireExists()
    val lines = lines()
    if (newLines.all { it in lines }) {
        return false
    }
    val index = lines.indexOfFirst { anchor.containsMatchIn(it) }
    check(index >= 0) {
        "Anchor Not Found in $path: ${anchor.pattern}"
    }
    lines.addAll(index, newLines.toList())
    writeLines(lines)
    return true
}

// ==========================
// Safe Delete Helpers
// ==========================
fun File.deleteLine(pattern: Regex): Boolean {
    requireExists()
    val lines = lines()
    val filtered = lines.filterNot { pattern.containsMatchIn(it) }
    if (filtered.size == lines.size) {
        return false
    }
    writeLines(filtered)
    return true
}
fun File.deleteLineAndFollowing(
    pattern: Regex,
    extraLines: Int
): Boolean {
    requireExists()
    val source = lines()
    val out = mutableListOf<String>()
    var skip = 0
    var changed = false
    for (line in source) {
        if (skip > 0) {
            skip--
            changed = true
            continue
        }
        if (pattern.containsMatchIn(line)) {
            skip = extraLines
            changed = true
            continue
        }
        out.add(line)
    }
    if (changed) {
        writeLines(out)
    }
    return changed
}
fun File.deleteBlock(
    start: Regex,
    end: Regex
): Boolean {
    requireExists()
    val source = lines()
    val out = mutableListOf<String>()
    var inBlock = false
    var changed = false
    for (line in source) {
        if (!inBlock && start.containsMatchIn(line)) {
            inBlock = true
            changed = true
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
    check(!inBlock) {
        "Unterminated Delete Block In $path: ${start.pattern}"
    }
    if (changed) {
        writeLines(out)
    }
    return changed
}

// ==========================
// Replace Helpers
// ==========================
fun File.replaceEachLine(
    pattern: Regex,
    replacement: String
): Boolean {
    requireExists()
    val source = lines()
    var changed = false
    val out = source.map { line ->
        val replaced = pattern.replace(line, replacement)
        if (replaced != line) {
            changed = true
        }
        replaced
    }
    if (changed) {
        writeLines(out)
    }
    return changed
}
fun File.replaceWholeLine(
    oldLine: String,
    newLine: String
): Boolean {
    requireExists()
    val source = lines()
    var changed = false
    val out = source.map {
        if (it == oldLine) {
            changed = true
            newLine
        } else {
            it
        }
    }
    if (changed) {
        writeLines(out)
    }
    return changed
}

// ==========================
// Logging
// ==========================
fun logApply(file: File, detail: String) =
    println("[APPLY]   ${file.rel()} | $detail")
fun logPostfix(file: File, detail: String) =
    println("[POSTFIX] ${file.rel()} | $detail")
fun logRevert(file: File, detail: String) =
    println("[REVERT]  ${file.rel()} | $detail")
fun logSkip(file: File, detail: String) =
    println("[SKIP]    ${file.rel()} | $detail")
fun logContext(file: File, detail: String) =
    println("[CONTEXT] ${file.rel()} | $detail")

// ==========================
// Environment
// ==========================
val kernelModule =
    System.getenv("KERNELMODULE") ?: ""
val sublevel =
    (System.getenv("SUBLEVEL") ?: "0")
        .toIntOrNull() ?: 0
val mode =
    args.getOrNull(0) ?: "Apply"
val workDir =
    args.getOrNull(1)
        ?: "kernel_workspace/kernel_platform/common"
fun f(relPath: String) =
    File(workDir, relPath)

// ==========================
// Common Anchors
// ==========================
val fdinfoCommentStart =
    Regex("""^[ \t]*/\*$""")
val fdinfoCommentEnd =
    Regex("""^[ \t]*u32 mask = mark->mask & IN_ALL_EVENTS;$""")
val inotifyFdinfoFuncAnchor =
    Regex(
        """^static void inotify_fdinfo\(struct seq_file \*m, struct fsnotify_mark \*mark\)$"""
    )
val inotifyHelper =
    listOf(
        "static inline u32 inotify_mark_user_mask(struct fsnotify_mark *mark)",
        "{",
        "\treturn mark->mask & IN_ALL_EVENTS;",
        "}",
        ""
    )

// ==========================
// Inotify FDInfo
// ==========================
fun addInotifyMarkUserMaskFunction(file: File) {
    if (file.readText().contains("inotify_mark_user_mask(")) {
        logSkip(file, "INOTIFY-MARK-USER-MASK() Already Present")
        return
    }
    file.insertBeforeFirst(
        inotifyFdinfoFuncAnchor,
        *inotifyHelper.toTypedArray()
    )
    logApply(
        file,
        "Inserted INOTIFY-MARK-USER-MASK() Helper Before INOTIFY-FDINFO()"
    )
}
fun applyFdinfo(file: File) {
    file.requireExists()
    val content = file.readText()
    if (content.contains("inotify_mark_user_mask(")) {
        logSkip(file, "FDINFO Patch Already Applied")
        return
    }
    check(
        content.contains("mask, mark.ignored_mask")
    ) {
        "Expected FDINFO Mask Expression Not Found in ${file.path}"
    }
    file.deleteBlock(
        fdinfoCommentStart,
        fdinfoCommentEnd
    )
    logApply(
        file,
        "Removed Inline Mask-Calculation Comment Block"
    )
    file.replaceEachLine(
        Regex("""\bmask,\s*mark\.ignored_mask"""),
        "inotify_mark_user_mask(mark)"
    )
    logApply(
        file,
        "Replaced Mask Argument With INOTIFY-MARK-USER-MASK(MARK)"
    )
    file.replaceEachLine(
        Regex("""ignored_mask:%x"""),
        "ignored_mask:0"
    )
    logApply(
        file,
        "Replaced IGNORED-MASK:%X With IGNORED-MASK:0"
    )
    addInotifyMarkUserMaskFunction(file)
}
fun revertFdinfo(file: File) {
    if (!file.exists()) {
        logSkip(file, "FDINFO File Does Not Exist")
        return
    }
    val content = file.readText()
    if (
        !content.contains("inotify_mark_user_mask(") &&
        !content.contains("ignored_mask:0")
    ) {
        logSkip(file, "FDINFO Patch Not Present")
        return
    }
    file.replaceEachLine(
        Regex("""inotify_mark_user_mask\(mark\)"""),
        "mask"
    )
    file.replaceEachLine(
        Regex("""ignored_mask:0"""),
        "ignored_mask:%x"
    )
    file.deleteBlock(
        Regex(
            """^static inline u32 inotify_mark_user_mask\(struct fsnotify_mark \*mark\)$"""
        ),
        Regex("""^\}$""")
    )
    logRevert(
        file,
        "Restored Original FDINFO Mask Handling"
    )
}

// ==========================
// Android 15 VMA Compatibility
// ==========================
fun applyAndroid15VmaBlock(
    taskMmu: File,
    namespace: File
) {
    taskMmu.requireExists()
    namespace.requireExists()
    val content = taskMmu.readText()
    if (content.contains("unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;")) {
        logSkip(
            taskMmu,
            "Android 15 VMA Patch Already Applied"
        )
        return
    }
    taskMmu.insertAfterFirst(
        Regex("""smap_gather_stats\(vma, &mss, last_vma_end\);"""),
        "last_vma_end = vma->vm_end;"
    )
    logApply(
        taskMmu,
        "Inserted LAST-VMA-END Update After SMAPGATHERSTATS()"
    )
    val lines = taskMmu.lines()
    val updateIndex =
        lines.indexOfLast {
            it.contains("last_vma_end = vma->vm_end;")
        }
    check(updateIndex >= 0) {
        "Unable to Locate Inserted LAST-VMA-END Assignment"
    }
    val ifIndex =
        (updateIndex - 1 downTo 0)
            .firstOrNull {
                Regex("""if\s*\(vma->vm_end > last_vma_end\)""")
                    .containsMatchIn(lines[it])
            }
    check(ifIndex != null) {
        "Unable to Locate VMA-END Comparison"
    }
    lines[ifIndex!!] =
        lines[ifIndex].replace(
            Regex("""\)\s*$"""),
            ") {"
        )
    lines[updateIndex] =
        "\t\t\t\t" + lines[updateIndex].trimStart()
    lines.add(
        updateIndex + 1,
        "\t\t\t}"
    )
    taskMmu.writeLines(lines)
    logApply(
        taskMmu,
        "Wrapped LAST-VMA-END Update in Conditional Block"
    )
    namespace.insertAfterFirst(
        Regex("""#include <trace/hooks/blk\.h>"""),
        "#include <trace/hooks/fs.h>"
    )
    logApply(
        namespace,
        "Added TRACE/HOOKS/FS.H Include"
    )
    taskMmu.insertAfterFirst(
        Regex("""int ret = 0, copied = 0;"""),
        "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;",
        "\tpagemap_entry_t *res = NULL;"
    )
    logApply(
        taskMmu,
        "Added NR-SUBPAGES and PAGEMAP-ENTRY-T Declarations"
    )
}
fun revertAndroid15VmaBlock(
    taskMmu: File,
    namespace: File
) {
    if (!taskMmu.exists()) return
    if (!namespace.exists()) return

    namespace.deleteLine(
        Regex("""^#include <trace/hooks/fs\.h>$""")
    )
    taskMmu.deleteLine(
        Regex(
            """^\s*unsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;$"""
        )
    )
    taskMmu.deleteLine(
        Regex(
            """^\s*pagemap_entry_t \*res = NULL;$"""
        )
    )

    // Restore Inserted Assignment Safely
    taskMmu.deleteLine(
        Regex("""^\s*last_vma_end = vma->vm_end;$""")
    )

    // Restore Conditional Form if Added Brace Remains
    taskMmu.replaceEachLine(
        Regex(
            """if\s*\(vma->vm_end > last_vma_end\)\s*\{$"""
        ),
        "if (vma->vm_end > last_vma_end)"
    )
    // Remove Extra Brace Generated by Patch
    val lines = taskMmu.lines()
    var removed = false
    val out = mutableListOf<String>()
    for (line in lines) {
        if (
            !removed &&
            line.trim() == "}" &&
            out.any {
                it.contains("if (vma->vm_end > last_vma_end)")
            }
        ) {
            removed = true
            continue
        }
        out.add(line)
    }
    taskMmu.writeLines(out)
    logRevert(
        taskMmu,
        "Restored Original Android 15 VMA Block"
    )
    logRevert(
        namespace,
        "Removed TRACE/HOOKS/FS.H Include"
    )
}

// ==========================
// ==========================
 // SUSFS Patch Context Restoration
// ==========================
val traceHookInclude = Regex("""^#include\s+(<trace/hooks/[^>]+>)\s*$""")
val anyInclude = Regex("""^#include\s+([<"][^>"]+[>"])\s*$""")
val contextManifest = File(
    (File(workDir).absoluteFile.parentFile ?: File(workDir).absoluteFile),
    ".fakepatches-context-manifest"
)

fun parsePatchContext(patchLines: List<String>): Map<String, List<String>> {
    val result = linkedMapOf<String, List<String>>()
    var currentFile: String? = null
    var inFirstHunk = false
    var firstHunkSeen = false
    var hunkLines = mutableListOf<String>()

    fun flushHunk() {
        val path = currentFile
        if (path != null && inFirstHunk) {
            val includes = hunkLines
                .filter { it.startsWith(" ") }
                .mapNotNull { line ->
                    anyInclude.find(line.drop(1).trim())?.groupValues?.get(1)
                }
            if (includes.isNotEmpty()) result[path] = includes
        }
        hunkLines = mutableListOf()
        inFirstHunk = false
    }

    for (line in patchLines) {
        if (line.startsWith("diff --git ")) {
            flushHunk()
            currentFile = Regex("""^diff --git a/(\S+) b/""")
                .find(line)?.groupValues?.get(1)
            firstHunkSeen = false
            continue
        }
        if (line.startsWith("@@")) {
            if (firstHunkSeen) {
                flushHunk()
                currentFile = null
                continue
            }
            firstHunkSeen = true
            inFirstHunk = true
            continue
        }
        if (inFirstHunk) hunkLines.add(line)
    }
    flushHunk()
    return result
}

fun ensureContextStub(include: String): File? {
    val relativeHeader = include.removePrefix("<").removeSuffix(">")
    if (!relativeHeader.startsWith("trace/hooks/")) return null

    val header = f("include/$relativeHeader")
    if (header.exists()) return null

    header.parentFile.mkdirs()
    val guard = "_FAKEPATCHES_CONTEXT_" +
        relativeHeader.replace(Regex("""\W"""), "_").uppercase()
    header.writeText(
        "/* Generated by FakePatches for SUSFS patch context only. */\n" +
        "#ifndef $guard\n#define $guard\n#endif\n"
    )
    logContext(header, "Created guarded context-only stub")
    return header
}

fun restorePatchContext(patch: File) {
    check(patch.isFile) { "SUSFS patch file does not exist: ${patch.path}" }

    val plan = parsePatchContext(patch.readLines())
    check(plan.isNotEmpty()) {
        "No include context could be parsed from SUSFS patch: ${patch.path}"
    }

    val manifestEntries = mutableListOf<String>()
    var restoredCount = 0
    var stubCount = 0

    for ((relativePath, includes) in plan) {
        if (includes.none { traceHookInclude.matches("#include $it") }) continue

        val target = f(relativePath)
        if (!target.isFile) {
            logContext(target, "Skipped because patched source file does not exist")
            continue
        }

        val lines = target.readLines().toMutableList()
        var cursor = 0
        var changed = false

        for (include in includes) {
            val expected = "#include $include"
            val found = (cursor until lines.size).firstOrNull {
                lines[it].trim() == expected
            }

            if (!traceHookInclude.matches(expected)) {
                if (found != null) cursor = found + 1
                continue
            }

            if (found != null) {
                cursor = found + 1
            } else {
                val insertionIndex = cursor.coerceIn(0, lines.size)
                lines.add(insertionIndex, expected)
                cursor = insertionIndex + 1
                manifestEntries.add("I\t${target.absolutePath}\t$expected")
                restoredCount++
                changed = true
                logContext(target, "Restored missing patch context: $expected")
            }

            val stub = ensureContextStub(include)
            if (stub != null) {
                manifestEntries.add("S\t${stub.absolutePath}")
                stubCount++
            }
        }

        if (changed) target.writeLines(lines)
    }

    if (kernelModule == "android13-5.15" && sublevel <= 41) {
        val idmap = f("include/linux/mnt_idmapping.h")
        if (!idmap.exists()) {
            idmap.parentFile.mkdirs()
            idmap.writeText(
                "/* Generated by FakePatches: mnt idmap helpers are provided elsewhere on this baseline. */\n"
            )
            manifestEntries.add("S\t${idmap.absolutePath}")
            stubCount++
            logContext(idmap, "Created compatibility stub for missing mnt_idmapping.h")
        }
    }

    if (manifestEntries.isNotEmpty()) {
        val previous = if (contextManifest.isFile) contextManifest.readLines() else emptyList()
        contextManifest.writeLines((previous + manifestEntries).distinct())
    }

    println("[CONTEXT] Restored $restoredCount include(s), created $stubCount stub header(s)")
    if (restoredCount == 0 && stubCount == 0) {
        println("[CONTEXT] Patch context already complete; nothing changed")
    }
}

fun revertPatchContext() {
    if (!contextManifest.isFile) {
        println("[CONTEXT] No generated context files to revert")
        return
    }

    val entries = contextManifest.readLines()
    var removedIncludes = 0
    var removedStubs = 0

    for (entry in entries.asReversed()) {
        val parts = entry.split("\t", limit = 3)
        when (parts.firstOrNull()) {
            "I" -> {
                if (parts.size < 3) continue
                val target = File(parts[1])
                if (target.isFile && target.deleteLine(Regex(Regex.escape(parts[2])))) {
                    removedIncludes++
                    logContext(target, "Removed generated context include: ${parts[2]}")
                }
            }
            "S" -> {
                val path = parts.getOrNull(1) ?: continue
                val stub = File(path)
                if (stub.isFile && stub.delete()) {
                    removedStubs++
                    logContext(stub, "Removed generated stub header")
                }
            }
        }
    }

    contextManifest.delete()
    println("[CONTEXT] Reverted $removedIncludes include(s), removed $removedStubs stub header(s)")
}

// Postfix Fixups
// ==========================
fun applyPostPatchFixups() {
    val taskMmu =
        f("fs/proc/task_mmu.c")
    if (taskMmu.exists()) {
        var content = taskMmu.readText()
     
        // VMA-PAD-START Fallback
        if (
            content.contains("VMA_PAD_START(") &&
            !Regex(
                """#include <linux/pgsize_migration(_inline)?\.h>"""
            ).containsMatchIn(content) &&
            !Regex(
                """^\s*#define\s+VMA_PAD_START"""
            ).containsMatchIn(content)
        ) {
            val lines = taskMmu.lines()
            lines.addAll(
                1,
                listOf(
                    "#ifndef VMA_PAD_START",
                    "#define VMA_PAD_START(vma) ((vma)->vm_end)",
                    "#endif"
                )
            )
            taskMmu.writeLines(lines)
            logPostfix(
                taskMmu,
                "Inserted VMA-PAD-START() Fallback"
            )
        }

        // FOLD-FILEMAP-FIXUP-ENTRY Compatibility
        content = taskMmu.readText()
        if (
            content.contains("__fold_filemap_fixup_entry(") &&
            !Regex(
                """static\s+inline\s+void\s+__fold_filemap_fixup_entry"""
            ).containsMatchIn(content)
        ) {
            val headerFile =
                f("include/linux/page_size_compat.h")
            val headerDeclaresFn =
                headerFile.exists() &&
                headerFile.readText()
                    .contains("__fold_filemap_fixup_entry")
            if (headerDeclaresFn) {
                if (
                    !content.contains(
                        "#include <linux/page_size_compat.h>"
                    )
                ) {
                    taskMmu.insertAfterFirst(
                        Regex("""^#include """),
                        "#include <linux/page_size_compat.h>"
                    )
                    logPostfix(
                        taskMmu,
                        "Added PAGE-SIZE-COMPAT.H Include"
                    )
                }
            } else {
                val lines = taskMmu.lines()
                val lastInclude =
                    lines.indexOfLast {
                        it.trimStart().startsWith("#include")
                    }
                val insertAt =
                    if (lastInclude >= 0)
                        lastInclude + 1
                    else
                        1
                lines.addAll(
                    insertAt,
                    listOf(
                        "#ifndef __fold_filemap_fixup_entry",
                        "static inline void __fold_filemap_fixup_entry(struct vma_iterator *iter, unsigned long *end) { }",
                        "#endif /* __fold_filemap_fixup_entry */"
                    )
                )
                taskMmu.writeLines(lines)
                logPostfix(
                    taskMmu,
                    "Inserted FOLD-FILEMAP-FIXUP-ENTRY() Stub"
                )
            }
        }
    }

    // Android 12 / 13 Nameidata Compatibility
    if (
        kernelModule == "android12-5.10" ||
        kernelModule == "android13-5.10"
    ) {
        val namei = f("fs/namei.c")
        if (
            namei.exists() &&
            namei.readText()
                .contains(
                    "set_nameidata(nd, old_dfd, fake_filename, NULL)"
                )
        ) {
            namei.replaceEachLine(
                Regex(
                    """set_nameidata\(nd, old_dfd, fake_filename, NULL\)"""
                ),
                "set_nameidata(nd, old_dfd, fake_filename)"
            )
            logPostfix(
                namei,
                "Rewrote 4-Arg SET-NAMEIDATA() to 3-Arg Form"
            )
        }
    }

    // Android 16 Getname-Flags Compatibility
    if (kernelModule == "android16-6.12") {
        val openC = f("fs/open.c")
        if (
            openC.exists() &&
            openC.readText()
                .contains(
                    "getname_flags(filename, lookup_flags, NULL)"
                )
        ) {
            openC.replaceEachLine(
                Regex(
                    """getname_flags\(filename, lookup_flags, NULL\)"""
                ),
                "getname_flags(filename, lookup_flags)"
            )
            logPostfix(
                openC,
                "Rewrote 3-Arg GETNAME-FLAGS() to 2-Arg Form"
            )
        }
    }
}

// ==========================
// Apply Compatibility Patches
// ==========================
fun apply() {
    // Android 12 / 5.10 Apply Compatibility Patches
    if (kernelModule == "android12-5.10") {
        if (sublevel <= 43) {
            val file = f("fs/proc/base.c")
            file.replaceEachLine(
                Regex(
                    """(int|size_t)\s+this_len\s*=\s*min_t\s*\(\s*\1\s*,"""
                ),
                "size_t this_len = min_t(size_t,"
            )
            logApply(
                file,
                "Normalized THIS-LEN/MIN-T() to SIZE-T"
            )
        }
        if (sublevel <= 117) {
            applyFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }
    }

    // Android 13 / 5.10 Apply Compatibility Patches
    if (kernelModule == "android13-5.10") {
        if (sublevel <= 107) {
            applyFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }
    }

    // Android 13 / 5.15 Apply Compatibility Patches
    if (kernelModule == "android13-5.15") {
        if (sublevel <= 41) {
            val namespace =
                f("fs/namespace.c")
            namespace.insertAfterFirst(
                Regex("""^#include <linux/shmem_fs\.h>$"""),
                "#include <linux/mnt_idmapping.h>"
            )
            logApply(
                namespace,
                "Added LINUX/MNT-IDMAPPING.H Include"
            )
            val openC =
                f("fs/open.c")
            openC.insertAfterFirst(
                Regex("""^#include <linux/compat\.h>$"""),
                "#include <linux/mnt_idmapping.h>"
            )
            logApply(
                openC,
                "Added LINUX/MNT-IDMAPPING.H Include"
            )
            applyFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }
        if (sublevel >= 123) {
            val memory =
                f("mm/memory.c")
            if (
                memory.deleteLine(
                    Regex("""#include <linux/swap_slots\.h>""")
                )
            ) {
                logApply(
                    memory,
                    "Removed LINUX/SWAP-SLOTS.H"
                )
            }
        }
    }

    // Android 14 / 6.1 Apply Compatibility Patches
    if (kernelModule == "android14-6.1") {
        if (sublevel <= 25) {
            val base =
                f("fs/proc/base.c")
            base.insertAfterFirst(
                Regex("""^#include <trace/events/oom\.h>$"""),
                "#include <trace/hooks/sched.h>"
            )
            logApply(
                base,
                "Added TRACE/HOOKS/SCHED.H"
            )
        }
        if (sublevel <= 141) {
            val base =
                f("fs/proc/base.c")
            base.insertAfterFirst(
                Regex("""^#include <linux/cpufreq_times\.h>$"""),
                "#include <linux/dma-buf.h>"
            )
            logApply(
                base,
                "Added LINUX/DMA-BUF.H"
            )
        }
    }

    // Android 15 / 6.6 Apply Compatibility Patches
    if (kernelModule == "android15-6.6") {
        if (sublevel <= 30) {
            applyAndroid15VmaBlock(
                f("fs/proc/task_mmu.c"),
                f("fs/namespace.c")
            )
        }
        if (sublevel <= 57) {
            val memory =
                f("mm/memory.c")
            memory.insertAfterFirst(
                Regex("""^#include <linux/sched/sysctl\.h>$"""),
                "#include <linux/zswap.h>"
            )
            logApply(
                memory,
                "Added LINUX/ZSWAP.H"
            )
        }
        if (sublevel <= 92) {
            val base =
                f("fs/proc/base.c")
            base.insertAfterFirst(
                Regex("""^#include <linux/cpufreq_times\.h>$"""),
                "#include <linux/dma-buf.h>"
            )
            logApply(
                base,
                "Added LINUX/DMA-BUF.H"
            )
        }
    }

    // Android 16 / 6.12 Apply Compatibility Patches
    if (kernelModule == "android16-6.12") {
        if (sublevel >= 58) {
            val exec =
                f("fs/exec.c")
            if (
                exec.deleteLine(
                    Regex("""^#include <linux/dma-buf\.h>$""")
                )
            ) {
                logApply(
                    exec,
                    "Removed LINUX/DMA-BUF.H"
                )
            }
        }
        if (sublevel >= 69) {
            val taskMmu =
                f("fs/proc/task_mmu.c")
            if (
                taskMmu.replaceEachLine(
                    Regex("""vma_data_pages"""),
                    "vma_pages"
                )
            ) {
                logApply(
                    taskMmu,
                    "Renamed VMA-DATA-PAGES To VMA-PAGES"
                )
            }
        }
    }
}

// ==========================
// PostFix Compatibility Patches
// ==========================
fun postfix() {
    applyPostPatchFixups()
}

// ==========================
// Revert Compatibility Patches
// ==========================
fun revert() {
    // Android 12 / 5.10 Revert Compatibility Patches
    if (kernelModule == "android12-5.10") {
        if (sublevel <= 43) {
            val file =
                f("fs/proc/base.c")
            if (
                file.replaceWholeLine(
                    "size_t this_len = min_t(size_t, count, PAGE_SIZE);",
                    "int this_len = min_t(int, count, PAGE_SIZE);"
                )
            ) {
                logRevert(
                    file,
                    "Restored INT THIS-LEN/MIN-T(INT)"
                )
            }
        }
        if (sublevel <= 117) {
            revertFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }
    }

    // Android 13 / 5.10 Revert Compatibility Patches
    if (kernelModule == "android13-5.10") {
        if (sublevel <= 107) {
            revertFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }
    }

    // Android 13 / 5.15 Revert Compatibility Patches
    if (kernelModule == "android13-5.15") {
        if (sublevel <= 41) {
            val namespace =
                f("fs/namespace.c")
            namespace.deleteLine(
                Regex("""^#include <linux/mnt_idmapping\.h>$""")
            )
            logRevert(
                namespace,
                "Removed LINUX/MNT-ID-MAPPING.H"
            )
            val openC =
                f("fs/open.c")
            openC.deleteLine(
                Regex("""^#include <linux/mnt_idmapping\.h>$""")
            )
            logRevert(
                openC,
                "Removed LINUX/MNT-ID-MAPPING.H"
            )
            val susfs =
                f("fs/susfs.c")
            if (susfs.exists()) {
                susfs.replaceEachLine(
                    Regex.escape(
                        "i_uid_into_mnt(i_user_ns(&fi->inode), &fi->inode).val"
                    ).toRegex(),
                    "i_uid_into_mnt(&init_user_ns, &fi->inode).val"
                )
                susfs.replaceEachLine(
                    Regex.escape(
                        "i_uid_into_mnt(i_user_ns(inode), inode).val"
                    ).toRegex(),
                    "i_uid_into_mnt(&init_user_ns, inode).val"
                )
                logRevert(
                    susfs,
                    "Restored SUSFS IUID-INTO-MNT() Form"
                )
            }
            revertFdinfo(
                f("fs/notify/fdinfo.c")
            )
        }
        if (sublevel >= 123) {
            val memory =
                f("mm/memory.c")
            if (
                !memory.readText()
                    .contains("#include <linux/swap_slots.h>")
            ) {
                memory.insertBeforeFirst(
                    Regex("""#ifdef CONFIG_KSU_SUSFS_SUS_MAP"""),
                    "#include <linux/swap_slots.h>"
                )
                logRevert(
                    memory,
                    "Restored LINUX/SWAP-SLOTS.H"
                )
            }
        }
    }

    // Android 14 / 6.1 Revert Compatibility Patches
    if (kernelModule == "android14-6.1") {
        if (sublevel <= 25) {
            val base =
                f("fs/proc/base.c")
            base.deleteLine(
                Regex("""^#include <trace/hooks/sched\.h>$""")
            )
            logRevert(
                base,
                "Removed TRACE/HOOKS/SCHED.H"
            )
        }
        if (sublevel <= 141) {
            val base =
                f("fs/proc/base.c")
            base.deleteLine(
                Regex("""^#include <linux/dma-buf\.h>$""")
            )
            logRevert(
                base,
                "Removed LINUX/DMA-BUF.H"
            )
        }
    }

    // Android 15 / 6.6 Revert Compatibility Patches
    if (kernelModule == "android15-6.6") {
        if (sublevel <= 30) {
            revertAndroid15VmaBlock(
                f("fs/proc/task_mmu.c"),
                f("fs/namespace.c")
            )
        }
        if (sublevel <= 57) {
            val memory =
                f("mm/memory.c")
            memory.deleteLine(
                Regex("""^#include <linux/zswap\.h>$""")
            )
            logRevert(
                memory,
                "Removed LINUX/ZSWAP.H"
            )
        }
        if (sublevel <= 92) {
            val base =
                f("fs/proc/base.c")
            base.deleteLine(
                Regex("""^#include <linux/dma-buf\.h>$""")
            )
            logRevert(
                base,
                "Removed LINUX/DMABUF.H"
            )
        }
    }

    // Android 16 / 6.12 Revert Compatibility Patches
    if (kernelModule == "android16-6.12") {
        if (sublevel >= 58) {
            val exec =
                f("fs/exec.c")
            if (
                !exec.readText()
                    .contains("#include <linux/dma-buf.h>")
            ) {
                exec.insertAfterFirst(
                    Regex("""^#include """),
                    "#include <linux/dma-buf.h>"
                )
                logRevert(
                    exec,
                    "Restored LINUX/DMABUF.H"
                )
            }
        }
        if (sublevel >= 69) {
            val taskMmu =
                f("fs/proc/task_mmu.c")
            if (
                taskMmu.readText()
                    .contains("vma_pages")
            ) {
                taskMmu.replaceEachLine(
                    Regex("""vma_pages"""),
                    "vma_data_pages"
                )
                logRevert(
                    taskMmu,
                    "Restored VMADATAPAGES"
                )
            }
        }
    }
    revertPatchContext()
}

// ==========================
// Main
// ==========================
try {
    when (mode) {
        "Apply" -> apply()
        "Context" -> restorePatchContext(
            File(args.getOrNull(2) ?: run {
                println("Usage: kotlin FakePatches.kts Context <WorkDir> <PatchFile>")
                exitProcess(1)
            })
        )
        "PostFix" -> postfix()
        "Revert" -> revert()
        else -> {
            println(
                "Usage: Kotlin FakePatches.kts <Apply|Context|PostFix|Revert> [WorkDir] [PatchFile]"
            )
            exitProcess(1)
        }
    }
    println(
        "🚀 Fake Patches: $mode Completed " +
        "(Android and Kernel Version = $kernelModule, Sublevel = $sublevel)"
    )
} catch (e: Exception) {
    System.err.println(
        "⚠️ Fake Patches Failed: ${e.message}"
    )
    exitProcess(1)
}
