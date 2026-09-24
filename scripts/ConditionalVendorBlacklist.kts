#!/usr/bin/env kotlin

import java.io.File
import kotlin.system.exitProcess

/*
 * Conditional Vendor Module Blacklist
 *
 * Supports:
 *   - Linux 5.15 and below  -> kernel/module.c
 *   - Linux 6.1 and above   -> kernel/module/main.c
 *
 * Based on:
 *   Bouteillepleine:
 *   "Support conditional vendor modules blacklisting"
 *
 * Arguments:
 *   1. Kernel source directory
 *   2. Comma-separated module list
 *   3. KERNELVERSION
 *
 * Example:
 *   kotlinc -script ConditionalVendorBlacklist.kts -- \
 *     "$KDIR" \
 *     "oplus_secure_guard_new" \
 *     "$KERNELVERSION"
 */

fun fail(message: String): Nothing {
    System.err.println("::error::$message")
    exitProcess(1)
}

fun info(message: String) {
    println(message)
}

fun requireFile(file: File, description: String) {
    if (!file.isFile) {
        fail("$description not found: ${file.absolutePath}")
    }
}

fun writeFile(file: File, content: String) {
    file.writeText(content)
}

fun parseKernelVersion(version: String): Pair<Int, Int> {
    val match = Regex("""^(\d+)\.(\d+)""").find(version)
        ?: fail("Invalid KERNELVERSION: $version")

    return Pair(
        match.groupValues[1].toInt(),
        match.groupValues[2].toInt()
    )
}

fun isSupportedKernelVersion(version: String): Boolean {
    val (major, minor) = parseKernelVersion(version)

    return when {
        major == 5 && minor <= 15 -> true
        major >= 6 -> true
        else -> false
    }
}

fun isLegacyKernel(version: String): Boolean {
    val (major, minor) = parseKernelVersion(version)

    return major == 5 && minor <= 15
}

fun normalizeModules(input: String): List<String> {
    if (input.isBlank()) {
        fail("Module blacklist cannot be empty")
    }

    val modules = input
        .split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() }

    if (modules.isEmpty()) {
        fail("No valid modules were supplied")
    }

    val invalid = modules.filterNot {
        it.matches(Regex("""^[A-Za-z0-9_]+$"""))
    }

    if (invalid.isNotEmpty()) {
        fail(
            "Invalid kernel module name(s): ${invalid.joinToString(", ")}. " +
            "Only letters, numbers and underscores are allowed."
        )
    }

    return modules.distinct()
}

fun buildKconfigBlock(): String {
    return """
config DEBLOAT_VENDOR_MODULES
	string "Debloat specific custom modules"
	default ""
	help
	  Pass a comma-separated list of module names to block.
	  Example: "oplus_network_tuning,oplus_bsp_zsmalloc"

""".trimIndent()
}

fun buildBootModeBlock(): String {
    return """
#ifndef __GENKSYMS__
#include <linux/bootconfig.h>
#endif

DEFINE_STATIC_KEY_TRUE(vendor_debloat_key);

static int __init parse_oplus_boot_mode(char *boot_mode_oplus)
{
	const char *mode;

	mode = (char *)xbc_find_value("androidboot.mode", NULL);
	if (!mode)
		mode = boot_mode_oplus;

	if (!mode)
		return 0;

	if (strcmp(mode, "normal") == 0 || strcmp(mode, "reboot") == 0) {
		pr_info("Oplus Boot Mode: Standard state (%s). Debloater remains ACTIVE.\n", mode);
	} else {
		pr_info("Oplus Boot Mode: Non Standard detected (%s). Disabling module debloater.\n", mode);
		static_branch_disable(&vendor_debloat_key);
	}

	return 1;
}
__setup("oplusboot.mode=", parse_oplus_boot_mode);

""".trimIndent()
}

fun buildBlacklistFunction(): String {
    return """
static bool blacklisted(const char *module_name)
{
	const char *p;
	size_t len;

	if (!module_blacklist)
		goto custom_blacklist;

	for (p = module_blacklist; *p; p += len) {
		len = strcspn(p, ",");
		if (strlen(module_name) == len && !memcmp(module_name, p, len))
			return true;
		if (p[len] == ',')
			len++;
	}

custom_blacklist:
	if (static_branch_likely(&vendor_debloat_key)) {
		if (!custom_module_blacklist || custom_module_blacklist[0] == '\0')
			goto out;

		for (p = custom_module_blacklist; *p; p += len) {
			len = strcspn(p, ",");
			if (strlen(module_name) == len && !memcmp(module_name, p, len))
				return true;
			if (p[len] == ',')
				len++;
		}
	}

out:
	return false;
}

""".trimIndent()
}

fun configureKconfig(kconfig: File) {
    var source = kconfig.readText()

    if (source.contains("config DEBLOAT_VENDOR_MODULES")) {
        info("ℹ️ DEBLOAT_VENDOR_MODULES Kconfig symbol already exists")
        return
    }

    val anchor = "source \"drivers/cpufreq/Kconfig\""

    val anchorIndex = source.indexOf(anchor)

    if (anchorIndex < 0) {
        fail(
            "Unable to locate Kconfig insertion anchor: $anchor"
        )
    }

    val insertPosition = anchorIndex + anchor.length

    val updated = buildString {
        append(source.substring(0, insertPosition))
        append("\n\n")
        append(buildKconfigBlock())
        append(source.substring(insertPosition))
    }

    writeFile(kconfig, updated)

    info("✔️ Added CONFIG_DEBLOAT_VENDOR_MODULES to arch/arm64/Kconfig")
}

fun configureBootMode(moduleSource: File, legacy: Boolean) {
    var source = moduleSource.readText()

    if (source.contains("DEFINE_STATIC_KEY_TRUE(vendor_debloat_key);") ||
        source.contains("__setup(\"oplusboot.mode=\", parse_oplus_boot_mode);")
    ) {
        info("ℹ️ Conditional vendor boot-mode logic already exists")
        return
    }

    val bootModeBlock = buildBootModeBlock()

    val anchor: String

    if (legacy) {
        /*
         * 5.15 and below:
         *
         * #define ARCH_SHF_SMALL 0
         * #endif
         */
        anchor = "#define ARCH_SHF_SMALL 0\n#endif"

        if (!source.contains(anchor)) {
            fail(
                "Unable to locate 5.15-and-below boot-mode insertion anchor " +
                "in ${moduleSource.path}"
            )
        }
    } else {
        /*
         * 6.1+:
         *
         * #undef CREATE_TRACE_POINTS
         * #include <trace/hooks/module.h>
         */
        anchor = "#undef CREATE_TRACE_POINTS\n#include <trace/hooks/module.h>"

        if (!source.contains(anchor)) {
            fail(
                "Unable to locate 6.1+ boot-mode insertion anchor " +
                "in ${moduleSource.path}"
            )
        }
    }

    source = source.replace(
        anchor,
        anchor + "\n\n" + bootModeBlock,
        ignoreCase = false
    )

    writeFile(moduleSource, source)

    info("✔️ Added Conditional OPlus Boot-Mode Handling")
}

fun configureBlacklistLogic(moduleSource: File) {
    var source = moduleSource.readText()

    if (source.contains("static const char *custom_module_blacklist = CONFIG_DEBLOAT_VENDOR_MODULES;") ||
        source.contains("static_branch_likely(&vendor_debloat_key)")
    ) {
        info("ℹ️ Conditional Vendor Blacklist Logic Already Exists")

        if (!source.contains(
                "static const char *custom_module_blacklist = CONFIG_DEBLOAT_VENDOR_MODULES;"
            )
        ) {
            fail(
                "Vendor Blacklist Implementation Appears Partially Applied in " +
                moduleSource.path
            )
        }

        return
    }

    val declarationAnchor = "static char *module_blacklist;"

    if (!source.contains(declarationAnchor)) {
        fail(
            "Unable to Locate Module Blacklist Declaration in ${moduleSource.path}"
        )
    }

    source = source.replace(
        declarationAnchor,
        declarationAnchor +
            "\nstatic const char *custom_module_blacklist = CONFIG_DEBLOAT_VENDOR_MODULES;",
        ignoreCase = false
    )

    val functionStart = source.indexOf("static bool blacklisted(const char *module_name)")
    val functionEnd = source.indexOf(
        "core_param(module_blacklist, module_blacklist, charp, 0400);",
        functionStart
    )

    if (functionStart < 0) {
        fail(
            "Unable to locate blacklisted() function in ${moduleSource.path}"
        )
    }

    if (functionEnd < 0) {
        fail(
            "Unable to locate module_blacklist core_param() after blacklisted() " +
            "in ${moduleSource.path}"
        )
    }

    val existingFunction = source.substring(functionStart, functionEnd)

    /*
     * Safety check:
     *
     * We expect the original upstream implementation to contain
     * module_blacklist handling before replacing it.
     */
    if (!existingFunction.contains("if (!module_blacklist)") ||
        !existingFunction.contains("strcspn") ||
        !existingFunction.contains("memcmp")
    ) {
        fail(
            "Unexpected blacklisted() implementation detected in " +
            "${moduleSource.path}. Refusing to replace it."
        )
    }

    source = source.substring(0, functionStart) +
        buildBlacklistFunction() +
        source.substring(functionEnd)

    writeFile(moduleSource, source)

    info("✔️ Added Conditional Vendor Module Blacklist Logic")
}

fun configureDefconfig(
    defconfig: File,
    modules: List<String>
) {
    val lines = defconfig.readLines().toMutableList()

    /*
     * Remove previous definition so repeated runs remain idempotent.
     */
    lines.removeAll {
        it.startsWith("CONFIG_DEBLOAT_VENDOR_MODULES=")
    }

    val joined = modules.joinToString(",")

    lines.add(
        "CONFIG_DEBLOAT_VENDOR_MODULES=\"$joined\""
    )

    writeFile(
        defconfig,
        lines.joinToString("\n") + "\n"
    )

    info(
        "✔️ Configured CONFIG_DEBLOAT_VENDOR_MODULES=\"$joined\""
    )
}

fun verify(
    kconfig: File,
    moduleSource: File,
    defconfig: File,
    modules: List<String>
) {
    val kconfigText = kconfig.readText()
    val moduleText = moduleSource.readText()
    val defconfigText = defconfig.readText()

    if (!kconfigText.contains("config DEBLOAT_VENDOR_MODULES")) {
        fail("Verification failed: Kconfig symbol is missing")
    }

    if (!moduleText.contains(
            "DEFINE_STATIC_KEY_TRUE(vendor_debloat_key);"
        )
    ) {
        fail("Verification failed: vendor_debloat_key is missing")
    }

    if (!moduleText.contains(
            "xbc_find_value(\"androidboot.mode\", NULL)"
        )
    ) {
        fail("Verification failed: androidboot.mode handling is missing")
    }

    if (!moduleText.contains(
            "__setup(\"oplusboot.mode=\", parse_oplus_boot_mode);"
        )
    ) {
        fail("Verification failed: oplusboot.mode setup handler is missing")
    }

    if (!moduleText.contains(
            "static const char *custom_module_blacklist = CONFIG_DEBLOAT_VENDOR_MODULES;"
        )
    ) {
        fail("Verification failed: custom blacklist declaration is missing")
    }

    if (!moduleText.contains(
            "static_branch_likely(&vendor_debloat_key)"
        )
    ) {
        fail("Verification failed: vendor blacklist static branch is missing")
    }

    val expected = modules.joinToString(",")

    val expectedDefconfig =
        "CONFIG_DEBLOAT_VENDOR_MODULES=\"$expected\""

    if (!defconfigText.contains(expectedDefconfig)) {
        fail(
            "Verification Failed: Expected Defconfig Entry is Missing: " +
            expectedDefconfig
        )
    }

    info("✔️ Source Verification Passed")
}

if (args.size < 3) {
    fail(
        """
        Usage:
          kotlinc -script ConditionalVendorBlacklist.kts -- \
            <KERNEL_DIR> \
            <MODULES> \
            <KERNELVERSION>

        Example:
          kotlinc -script ConditionalVendorBlacklist.kts -- \
            "$GITHUB_WORKSPACE/kernel_workspace/kernel_platform/common" \
            "oplus_secure_guard_new" \
            "6.12"
        """.trimIndent()
    )
}

val kernelDir = File(args[0]).canonicalFile
val moduleInput = args[1]
val KERNELVERSION = args[2].trim()

if (!kernelDir.isDirectory) {
    fail("Kernel source directory not found: ${kernelDir.absolutePath}")
}

if (!isSupportedKernelVersion(KERNELVERSION)) {
    fail(
        "Unsupported Kernel Version: $KERNELVERSION. " +
        "Supported Versions are 5.15 and Below, or 6.1 and Above"
    )
}

val modules = normalizeModules(moduleInput)

val protectedModules = setOf(
    "coresight",
    "rust_binder",
    "msm_kgsl",
    "camera"
)

val protectedRequested = modules.filter {
    it in protectedModules
}

if (protectedRequested.isNotEmpty()) {
    fail(
        "Protected module(s) cannot be blacklisted: " +
        protectedRequested.joinToString(", ")
    )
}

val legacy = isLegacyKernel(KERNELVERSION)

val kconfig = File(
    kernelDir,
    "arch/arm64/Kconfig"
)

val defconfig = File(
    kernelDir,
    "arch/arm64/configs/gki_defconfig"
)

val moduleSource = if (legacy) {
    File(kernelDir, "kernel/module.c")
} else {
    File(kernelDir, "kernel/module/main.c")
}

info("")
info("🛡️ Conditional Vendor Module Blacklist")
info("📂 Kernel Source : ${kernelDir.absolutePath}")
info("📦 Kernel        : $KERNELVERSION")
info(
    "🧩 Implementation : " +
        if (legacy) "kernel/module.c (5.15 and below)"
        else "kernel/module/main.c (6.1+)"
)
info("📦 Modules       : ${modules.joinToString(", ")}")
info("")

requireFile(kconfig, "ARM64 Kconfig")
requireFile(defconfig, "GKI defconfig")
requireFile(moduleSource, "Kernel module source")

info("🔎 Validating Kernel Source...")

val originalKconfig = kconfig.readText()
val originalModuleSource = moduleSource.readText()
val originalDefconfig = defconfig.readText()

try {
    /*
     * Kconfig
     */
    configureKconfig(kconfig)

    /*
     * Boot-Mode Handling
     */
    configureBootMode(moduleSource, legacy)

    /*
     * Custom Blacklist Logic
     */
    configureBlacklistLogic(moduleSource)

    /*
     * Defconfig
     */
    configureDefconfig(defconfig, modules)

    /*
     * Final Verification
     */
    verify(
        kconfig,
        moduleSource,
        defconfig,
        modules
    )

} catch (exception: Exception) {

    /*
     * Transaction-Style Rollback
     * If Anything Fails During Modification, Restore All Three Files to their Original State
     */
    info("⚠️ Modification Failed — Restoring Original Kernel Files")

    writeFile(kconfig, originalKconfig)
    writeFile(moduleSource, originalModuleSource)
    writeFile(defconfig, originalDefconfig)

    fail(
        "Conditional Vendor Blacklist Configuration Failed: " +
        (exception.message ?: exception::class.simpleName)
    )
}

info("")
info("🎉 Conditional Vendor Module Blacklist Configured")
info("📦 Kernel Version : $KERNELVERSION")
info("📦 Module Source  : ${moduleSource.relativeTo(kernelDir)}")
info("📦 Blacklisted    : ${modules.joinToString(", ")}")
info("")
