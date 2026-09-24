#!/usr/bin/env kotlin

import java.io.File
import kotlin.system.exitProcess

/*
 * Conditional Vendor Module Blacklist
 *
 * Supports:
 *   - Linux 5.15 And Below -> kernel/module.c
 *   - Linux 6.1 And Above  -> kernel/module/main.c
 *
 * Arguments:
 *   1. Kernel Source Directory
 *   2. Comma-Separated Module List
 *   3. KERNELVERSION
 *
 * Example:
 *   kotlinc -script ConditionalVendorBlacklist.kts -- \
 *     "/path/to/kernel_platform/common" \
 *     "oplus_secure_guard_new" \
 *     "6.12"
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
        fail("Module Blacklist Cannot Be Empty")
    }

    val modules = input
        .split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() }

    if (modules.isEmpty()) {
        fail("No Valid Modules Were Supplied")
    }

    val invalid = modules.filterNot {
        it.matches(Regex("""^[A-Za-z0-9_]+$"""))
    }

    if (invalid.isNotEmpty()) {
        fail(
            "Invalid Kernel Module Name(s): ${invalid.joinToString(", ")}. " +
                "Only Letters, Numbers And Underscores Are Allowed."
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
    val source = kconfig.readText()

    if (source.contains("config DEBLOAT_VENDOR_MODULES")) {
        info("ℹ️ DEBLOAT_VENDOR_MODULES Kconfig Symbol Already Exists")
        return
    }

    val anchor = "source \"drivers/cpufreq/Kconfig\""
    val anchorIndex = source.indexOf(anchor)

    if (anchorIndex < 0) {
        fail(
            "Unable To Locate Kconfig Insertion Anchor: $anchor"
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

    info("✔️ Added CONFIG_DEBLOAT_VENDOR_MODULES To arch/arm64/Kconfig")
}

fun configureBootMode(
    moduleSource: File,
    legacy: Boolean
) {
    var source = moduleSource.readText()

    if (
        source.contains(
            "DEFINE_STATIC_KEY_TRUE(vendor_debloat_key);"
        ) ||
        source.contains(
            "__setup(\"oplusboot.mode=\", parse_oplus_boot_mode);"
        )
    ) {
        info("ℹ️ Conditional Vendor Boot-Mode Logic Already Exists")
        return
    }

    val bootModeBlock = buildBootModeBlock()

    val anchor: String

    if (legacy) {
        /*
         * Linux 5.15 And Below:
         *
         * #define ARCH_SHF_SMALL 0
         * #endif
         */
        anchor = "#define ARCH_SHF_SMALL 0\n#endif"

        if (!source.contains(anchor)) {
            fail(
                "Unable To Locate 5.15-And-Below Boot-Mode Insertion " +
                    "Anchor In ${moduleSource.path}"
            )
        }
    } else {
        /*
         * Linux 6.1+:
         *
         * #undef CREATE_TRACE_POINTS
         * #include <trace/hooks/module.h>
         */
        anchor =
            "#undef CREATE_TRACE_POINTS\n#include <trace/hooks/module.h>"

        if (!source.contains(anchor)) {
            fail(
                "Unable To Locate 6.1+ Boot-Mode Insertion Anchor " +
                    "In ${moduleSource.path}"
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

    val customDeclaration =
        "static const char *custom_module_blacklist = " +
            "CONFIG_DEBLOAT_VENDOR_MODULES;"

    if (
        source.contains(customDeclaration) ||
        source.contains(
            "static_branch_likely(&vendor_debloat_key)"
        )
    ) {
        info("ℹ️ Conditional Vendor Blacklist Logic Already Exists")

        if (!source.contains(customDeclaration)) {
            fail(
                "Vendor Blacklist Implementation Appears Partially " +
                    "Applied In ${moduleSource.path}"
            )
        }

        return
    }

    val declarationAnchor = "static char *module_blacklist;"

    if (!source.contains(declarationAnchor)) {
        fail(
            "Unable To Locate Module Blacklist Declaration In " +
                moduleSource.path
        )
    }

    source = source.replace(
        declarationAnchor,
        declarationAnchor + "\n$customDeclaration",
        ignoreCase = false
    )

    val functionStart =
        source.indexOf(
            "static bool blacklisted(const char *module_name)"
        )

    if (functionStart < 0) {
        fail(
            "Unable To Locate blacklisted() Function In " +
                moduleSource.path
        )
    }

    val functionEnd = source.indexOf(
        "core_param(module_blacklist, module_blacklist, charp, 0400);",
        functionStart
    )

    if (functionEnd < 0) {
        fail(
            "Unable To Locate module_blacklist core_param() After " +
                "blacklisted() In ${moduleSource.path}"
        )
    }

    val existingFunction =
        source.substring(functionStart, functionEnd)

    /*
     * Safety Check:
     *
     * Verify That The Expected Upstream Implementation Is Present
     * Before Replacing blacklisted().
     */
    if (
        !existingFunction.contains("if (!module_blacklist)") ||
        !existingFunction.contains("strcspn") ||
        !existingFunction.contains("memcmp")
    ) {
        fail(
            "Unexpected blacklisted() Implementation Detected In " +
                "${moduleSource.path}. Refusing To Replace It."
        )
    }

    source =
        source.substring(0, functionStart) +
            buildBlacklistFunction() +
            source.substring(functionEnd)

    writeFile(moduleSource, source)

    info("✔️ Added Conditional Vendor Module Blacklist Logic")
}

fun configureDefconfig(
    defconfig: File,
    modules: List<String>
) {
    val lines = defconfig
        .readLines()
        .toMutableList()

    /*
     * Remove Any Previous Definition So Repeated Runs Remain
     * Idempotent.
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
        fail(
            "Verification Failed: Kconfig Symbol Is Missing"
        )
    }

    if (
        !moduleText.contains(
            "DEFINE_STATIC_KEY_TRUE(vendor_debloat_key);"
        )
    ) {
        fail(
            "Verification Failed: vendor_debloat_key Is Missing"
        )
    }

    if (
        !moduleText.contains(
            "xbc_find_value(\"androidboot.mode\", NULL)"
        )
    ) {
        fail(
            "Verification Failed: androidboot.mode Handling Is Missing"
        )
    }

    if (
        !moduleText.contains(
            "__setup(\"oplusboot.mode=\", parse_oplus_boot_mode);"
        )
    ) {
        fail(
            "Verification Failed: oplusboot.mode Setup Handler Is Missing"
        )
    }

    if (
        !moduleText.contains(
            "static const char *custom_module_blacklist = " +
                "CONFIG_DEBLOAT_VENDOR_MODULES;"
        )
    ) {
        fail(
            "Verification Failed: Custom Blacklist Declaration Is Missing"
        )
    }

    if (
        !moduleText.contains(
            "static_branch_likely(&vendor_debloat_key)"
        )
    ) {
        fail(
            "Verification Failed: Vendor Blacklist Static Branch Is Missing"
        )
    }

    val expected = modules.joinToString(",")

    val expectedDefconfig =
        "CONFIG_DEBLOAT_VENDOR_MODULES=\"$expected\""

    if (!defconfigText.contains(expectedDefconfig)) {
        fail(
            "Verification Failed: Expected Defconfig Entry Is Missing: " +
                expectedDefconfig
        )
    }

    info("✔️ Source Verification Passed")
}

/*
 * Argument Validation
 *
 * The Script Is Intentionally Independent Of GitHub Actions.
 * The Kernel Path Is Supplied By args[0], So There Is No Direct
 * Reference To GITHUB_WORKSPACE Here.
 */
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
            "/path/to/kernel_platform/common" \
            "oplus_secure_guard_new" \
            "6.12"
        """.trimIndent()
    )
}

val kernelDir = File(args[0]).canonicalFile
val moduleInput = args[1]
val kernelVersion = args[2].trim()

if (!kernelDir.isDirectory) {
    fail(
        "Kernel Source Directory Not Found: " +
            kernelDir.absolutePath
    )
}

if (!isSupportedKernelVersion(kernelVersion)) {
    fail(
        "Unsupported Kernel Version: $kernelVersion. " +
            "Supported Versions Are 5.15 And Below, Or 6.1 And Above."
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
        "Protected Module(s) Cannot Be Blacklisted: " +
            protectedRequested.joinToString(", ")
    )
}

val legacy = isLegacyKernel(kernelVersion)

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
info("📦 Kernel        : $kernelVersion")
info(
    "🧩 Implementation : " +
        if (legacy) {
            "kernel/module.c (5.15 And Below)"
        } else {
            "kernel/module/main.c (6.1+)"
        }
)
info("📦 Modules       : ${modules.joinToString(", ")}")
info("")

requireFile(kconfig, "ARM64 Kconfig")
requireFile(defconfig, "GKI defconfig")
requireFile(moduleSource, "Kernel Module Source")

info("🔎 Validating Kernel Source...")

/*
 * Keep Original Contents So The Entire Operation Can Be Rolled
 * Back If Any Modification Or Verification Fails.
 */
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
    configureBootMode(
        moduleSource,
        legacy
    )

    /*
     * Custom Blacklist Logic
     */
    configureBlacklistLogic(moduleSource)

    /*
     * Defconfig
     */
    configureDefconfig(
        defconfig,
        modules
    )

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
     *
     * Restore All Modified Files If Any Operation Fails.
     */
    info(
        "⚠️ Modification Failed — " +
            "Restoring Original Kernel Files"
    )

    writeFile(
        kconfig,
        originalKconfig
    )

    writeFile(
        moduleSource,
        originalModuleSource
    )

    writeFile(
        defconfig,
        originalDefconfig
    )

    fail(
        "Conditional Vendor Blacklist Configuration Failed: " +
            (exception.message
                ?: exception::class.simpleName)
    )
}

info("")
info("🎉 Conditional Vendor Module Blacklist Configured")
info("📦 Kernel Version : $kernelVersion")
info(
    "📦 Module Source  : " +
        moduleSource.relativeTo(kernelDir)
)
info(
    "📦 Blacklisted    : " +
        modules.joinToString(", ")
)
info("")
