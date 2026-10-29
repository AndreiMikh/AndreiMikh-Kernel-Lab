#!/usr/bin/env kotlin
import java.io.File
import kotlin.system.exitProcess

// ====================================================
// Basic File Helpers
// ====================================================
// Stop Immediately When Required Source or Header File is Missing
fun File.requireExists() {
    check(exists()) {
        "Required File Does Not Exist: $path"
    }
}
// Read File Into Mutable List so Patch Helpers can Edit Individual Lines
fun File.lines(): MutableList<String> =
    readLines().toMutableList()
fun File.writeLines(lines: List<String>) {
    writeText(lines.joinToString("\n") + "\n")
}
// Shorten Log Paths by Removing Configured Kernel Work-Directory Prefix
fun File.rel(): String =
    path.removePrefix("$workDir/").removePrefix("$workDir\\")

// ====================================================
// Safe Insert Helpers
// ====================================================
// Insert New Lines After First Matching Anchor; Avoid Duplicate Insertions
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
// Insert After Every Matching Anchor, Processing From Bottom to Top so Earlier Indexes Remain Valid
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
// Insert New Lines Immediately Before First Matching Anchor
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

// ====================================================
// Safe Delete Helpers
// ====================================================
// Remove Every Line Matching the Pattern and Report Whether the File Changed
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
// Remove Each Matching Line Plus the Requested Number of Following Lines
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
// Remove Delimited Block, Including its Start and End Marker Lines
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
        "Unterminated Delete Block in $path: ${start.pattern}"
    }
    if (changed) {
        writeLines(out)
    }
    return changed
}

// ====================================================
// Replace Helpers
// ====================================================
// Apply a Regex Replacement to Every Line and Write Only When a Change Occurred
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
// Replace Exact Whole-Line Matches; Unrelated Lines are Preserved Unchanged
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

// ====================================================
// Logging
// ====================================================
fun logApply(file: File, detail: String) =
    println("[Apply]   ${file.rel()} | $detail")
fun logPostfix(file: File, detail: String) =
    println("[PostFix] ${file.rel()} | $detail")
fun logRevert(file: File, detail: String) =
    println("[Revert]  ${file.rel()} | $detail")
fun logSkip(file: File, detail: String) =
    println("[Skip]    ${file.rel()} | $detail")

// ====================================================
// Environment
// ====================================================
// Select Compatibility Rules Using Kernel Branch Name Supplied by Workflow
val kernelModule =
    System.getenv("KERNELMODULE") ?: ""
// Parse Kernel Patch Sublevel; Use 0 if Environment Value is Absent or Invalid
val sublevel =
    (System.getenv("SUBLEVEL") ?: "0")
        .toIntOrNull() ?: 0
// First CLI Argument Selects Apply, PostFix, or Revert Mode
val mode =
    args.getOrNull(0) ?: "Apply"
// Second CLI Argument Selects Kernel Source Tree, with Common GKI Path as Default
val workDir =
    args.getOrNull(1)
        ?: "kernel_workspace/kernel_platform/common"
fun f(relPath: String) =
    File(workDir, relPath)

// ====================================================
// Common Anchors
// ====================================================
// Anchors Used to Identify Inline FDINFO Comment Block that Compatibility Patch Removes
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

// ====================================================
// Inotify FDInfo
// ====================================================
// Add Helper Only When it is Not Already Present, Making Operation Repeatable
fun addInotifyMarkUserMaskFunction(file: File) {
    if (file.readText().contains("inotify_mark_user_mask(")) {
        logSkip(file, "INOTIFY MARK USER MASK() Already Present")
        return
    }
    file.insertBeforeFirst(
        inotifyFdinfoFuncAnchor,
        *inotifyHelper.toTypedArray()
    )
    logApply(
        file,
        "Inserted Inotify Mark User Mask() Helper Before Inotify FDINFO()"
    )
}
// Adapt Inotify FDINFO Output to Expected SuSFS-Compatible Mask Representation
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
        "Replaced Mask Argument With Inotify Mark User Mask(Mark)"
    )
    file.replaceEachLine(
        Regex("""ignored_mask:%x"""),
        "ignored_mask:0"
    )
    logApply(
        file,
        "Replaced Ignored Mask:%X With Ignored Mask:0"
    )
    addInotifyMarkUserMaskFunction(file)
}
// Restore Original FDINFO Mask Expression and Remove Helper Introduced by applyFdinfo()
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

// ====================================================
// Android 15 VMA Compatibility Fixes
// ====================================================
// Apply Android 15 / 6.6 VMA Compatibility Edits to Task MMU C Source
fun applyAndroid15VmaBlock(
    taskMmu: File
) {
    taskMmu.requireExists()
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
        "Inserted Last VMA End Update After SMAP Gather Stats()"
    )
    val lines = taskMmu.lines()
    val updateIndex =
        lines.indexOfLast {
            it.contains("last_vma_end = vma->vm_end;")
        }
    check(updateIndex >= 0) {
        "Unable to Locate Inserted Last VMA End Assignment"
    }
    val ifIndex =
        (updateIndex - 1 downTo 0)
            .firstOrNull {
                Regex("""if\s*\(vma->vm_end > last_vma_end\)""")
                    .containsMatchIn(lines[it])
            }
    check(ifIndex != null) {
        "Unable to Locate VMA End Comparison"
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
        "Wrapped Last VMA End Update in Conditional Block"
    )
    taskMmu.insertAfterFirst(
        Regex("""int ret = 0, copied = 0;"""),
        "\tunsigned int nr_subpages = __PAGE_SIZE / PAGE_SIZE;",
        "\tpagemap_entry_t *res = NULL;"
    )
    logApply(
        taskMmu,
        "Added NR Subpages and Page Map Entry T Declarations"
    )
}
// Undo Android 15 VMA Edits, Including Inserted Declaration, Assignment and Brace
fun revertAndroid15VmaBlock(
    taskMmu: File
) {
    if (!taskMmu.exists()) return
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
}

// ====================================================
// Postfix Fixups
// ====================================================
// Apply Small Source-Level Compatibility Fixups After SuSFS Patch has been Applied
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
                "Inserted VMA Pad Start() Fallback"
            )
        }
        // Fold File Map Fixup Entry Compatibility
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
                        "Added Page Size Compat Headers Include"
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
                    "Inserted Fold File Map Fixup Entry() Stub"
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
                "Rewrote 4-Arg Set Nameidata() to 3-Arg Form"
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
                "Rewrote 3-Arguments Getname Flags() to 2-Arguments Form"
            )
        }
    }
}

// ====================================================
// Apply Compatibility Patches
// ====================================================
// Apply Version-Specific Compatibility Changes Based on Kernel Base and Sublevel
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
                "Normalized This Len/Min T() to Size T"
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
                "Added Linux/Mount ID Mapping Headers Include"
            )
            val openC =
                f("fs/open.c")
            openC.insertAfterFirst(
                Regex("""^#include <linux/compat\.h>$"""),
                "#include <linux/mnt_idmapping.h>"
            )
            logApply(
                openC,
                "Added Linux/Mount ID Mapping Headers Include"
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
                    "Removed Linux/Swap Slots Headers"
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
                "Added Trace/Hooks/Sched Headers"
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
                "Added Linux/DMA BUF Headers"
            )
        }
    }
    // Android 15 / 6.6 Apply Compatibility Patches
    if (kernelModule == "android15-6.6") {
        if (sublevel <= 30) {
            applyAndroid15VmaBlock(
                f("fs/proc/task_mmu.c")
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
                "Added Linux/Zswap Headers"
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
                "Added Linux/DMA BUF Headers"
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
                    "Removed Linux/DMA BUF Headers"
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
                    "Renamed VMA Data Pages to VMA Pages"
                )
            }
        }
    }
}

// ====================================================
// PostFix Compatibility Patches
// ====================================================
// Run Post-Patch Compatibility Adjustments Without Reapplying Patch Set
fun postfix() {
    applyPostPatchFixups()
}

// ====================================================
// Revert Compatibility Patches
// ====================================================
// Reverse Compatibility Edits Supported by Script
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
                    "Restored Int This Len/Min T(Int)"
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
                "Removed Linux/Mount ID Mapping Headers"
            )
            val openC =
                f("fs/open.c")
            openC.deleteLine(
                Regex("""^#include <linux/mnt_idmapping\.h>$""")
            )
            logRevert(
                openC,
                "Removed Linux/Mount ID Mapping Headers"
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
                    "Restored SuSFS IUID Into Mount() Form"
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
                    "Restored Linux/Swap Slots Headers"
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
                "Removed Trace/Hooks/Sched Headers"
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
                "Removed Linux/DMA BUF Headers"
            )
        }
    }
    // Android 15 / 6.6 Revert Compatibility Patches
    if (kernelModule == "android15-6.6") {
        if (sublevel <= 30) {
            revertAndroid15VmaBlock(
                f("fs/proc/task_mmu.c")
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
                "Removed Linux/Zswap Headers"
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
                "Removed Linux/DMA BUF Headers"
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
                    "Restored Linux/DMA BUF Headers"
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
                    "Restored VMA Data Pages"
                )
            }
        }
    }
}

// ====================================================
// Execution
// ====================================================
// Dispatch Requested Operation and Convert Failures Into Non-Zero Process Exit
try {
    when (mode) {
        "Apply" -> apply()
        "PostFix" -> postfix()
        "Revert" -> revert()
        else -> {
            println(
                "Usage: Kotlin SusfsCompat.kts <Apply|PostFix|Revert> [WorkDir]"
            )
            exitProcess(1)
        }
    }
    println(
        "🚀 SUSFS Compatibility: $mode Completed " +
        "(Android and Kernel Version = $kernelModule, Sublevel = $sublevel)"
    )
} catch (e: Exception) {
    System.err.println(
        "⚠️ Fake Patches Failed: ${e.message}"
    )
    exitProcess(1)
}
