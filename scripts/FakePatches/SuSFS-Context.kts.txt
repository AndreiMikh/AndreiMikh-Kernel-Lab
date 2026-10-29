#!/usr/bin/env kotlin
import java.io.File
import kotlin.system.exitProcess

// ====================================================
// Environment
// ====================================================
// Select Kernel Branch Name Supplied by Workflow
val kernelModule =
    System.getenv("KERNELMODULE") ?: ""
// Parse Kernel Patch Sublevel; Use 0 if Environment Value is Absent or Invalid
val sublevel =
    (System.getenv("SUBLEVEL") ?: "0")
        .toIntOrNull() ?: 0
// Select Kernel Source Tree, with Common GKI Path as Default
val workDir =
    args.getOrNull(0)
        ?: "kernel_workspace/kernel_platform/common"
val patchFile =
    args.getOrNull(1) ?: run {
        println("Usage: kotlin SusfsContext.kts <WorkDir> <PatchFile>")
        exitProcess(1)
    }
fun f(relPath: String) =
    File(workDir, relPath)
fun logContext(file: File, detail: String) =
    println("[Context] ${file.path.removePrefix("$workDir/").removePrefix("$workDir\\")} | $detail")

// ====================================================
// SUSFS Patch Context Restoration
// ====================================================
// Recognize Trace-Hook Includes and General C/C++ Include Directives While Parsing Patch Context
val traceHookInclude = Regex("""^#include\s+(<trace/hooks/[^>]+>)\s*$""")
val anyInclude = Regex("""^#include\s+([<"][^>"]+[>"])\s*$""")

// Collect Include Lines From First Hunk of Each Diff so Missing SuSFS Patch Context can be Restored
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

// Create a Guarded Placeholder Only For a Missing Trace/Hooks Header Needed as Patch Context
fun ensureContextStub(include: String): File? {
    val relativeHeader = include.removePrefix("<").removeSuffix(">")
    if (!relativeHeader.startsWith("trace/hooks/")) return null
    val header = f("include/$relativeHeader")
    if (header.exists()) return null
    header.parentFile.mkdirs()
    val guard = "_SUSFS_CONTEXT_STUB_" +
        relativeHeader.replace(Regex("""\W"""), "_").uppercase()
    header.writeText(
        "/* Stub created by SusfsContext. */\n" +
        "#ifndef $guard\n#define $guard\n#endif\n"
    )
    logContext(header, "Created Guarded Context-Only Stub")
    return header
}

// Restore Required Trace-Hook Include Context and Create Any Required Context-Only Stub Headers
fun restorePatchContext(patch: File) {
    check(patch.isFile) { "SUSFS Patch File Does Not Exist: ${patch.path}" }
    val plan = parsePatchContext(patch.readLines())
    check(plan.isNotEmpty()) {
        "No Include Context Could be Parsed From SUSFS Patch: ${patch.path}"
    }
    var restoredCount = 0
    var stubCount = 0
    for ((relativePath, includes) in plan) {
        if (includes.none { traceHookInclude.matches("#include $it") }) continue
        val target = f(relativePath)
        if (!target.isFile) {
            logContext(target, "Skipped Because Patched Source File Does Not Exist")
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
                restoredCount++
                changed = true
                logContext(target, "Restored Missing Patch Context: $expected")
            }
            val stub = ensureContextStub(include)
            if (stub != null) stubCount++
        }
        if (changed) target.writeText(lines.joinToString("\n") + "\n")
    }
    // Older Android 13 / 5.15 Baselines may Lack Mount ID Mapping Header; Create a Context-Only Stub
    if (kernelModule == "android13-5.15" && sublevel <= 41) {
        val idmap = f("include/linux/mnt_idmapping.h")
        if (!idmap.exists()) {
            idmap.parentFile.mkdirs()
            idmap.writeText(
                "/* Stub Created by SuSFS Context Script, Mount ID Mapping Helpers are Provided Elsewhere on Baseline */\n"
            )
            stubCount++
            logContext(idmap, "Created Compatibility Stub For Missing Mount ID Mapping Headers")
        }
    }
    println("[Context] Restored $restoredCount Include(s), Created $stubCount Stub Header(s)")
    if (restoredCount == 0 && stubCount == 0) {
        println("[Context] Patch Context Already Completed; Nothing Changed")
    }
}

restorePatchContext(File(patchFile))
