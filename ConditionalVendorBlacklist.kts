#!/usr/bin/env kotlin

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import kotlin.system.exitProcess

/*
 * Conditional Vendor Module Blacklist
 *
 * Linux 5.15 and below:
 *   kernel/module.c
 *
 * Linux 6.1 and above:
 *   kernel/module/main.c
 *
 * Unsupported:
 *   Linux 5.16 - 5.19
 *   Linux 6.0
 *
 * Configuration:
 *   arch/arm64/Kconfig
 *
 * gki_defconfig is never modified.
 *
 * Transaction safety:
 *   - Preflight validation
 *   - Complete/partial patch detection
 *   - Full snapshots before modification
 *   - Atomic writes
 *   - Single rollback path
 *   - Rollback verification
 *   - Snapshot cleanup
 */

private const val KCONFIG_SYMBOL =
    "config DEBLOAT_VENDOR_MODULES"

private const val KCONFIG_ANCHOR =
    "source \"drivers/cpufreq/Kconfig\""

private const val MODULE_BLACKLIST_DECLARATION =
    "static char *module_blacklist;"

private const val CUSTOM_BLACKLIST_DECLARATION =
    "static const char *custom_module_blacklist = " +
        "CONFIG_DEBLOAT_VENDOR_MODULES;"

private const val STATIC_KEY_DECLARATION =
    "DEFINE_STATIC_KEY_TRUE(vendor_debloat_key);"

private const val BOOT_FUNCTION =
    "static bool __init is_normal_boot(void)"

private const val BOOT_INIT_FUNCTION =
    "static int __init init_vendor_debloat_boot_check(void)"

private const val BLACKLIST_FUNCTION =
    "static bool blacklisted(const char *module_name)"

private const val MODULE_BLACKLIST_PARAM =
    "core_param(module_blacklist, module_blacklist, charp, 0400);"

enum class PatchState {
    ABSENT,
    COMPLETE,
    PARTIAL
}

data class KernelVersion(
    val major: Int,
    val minor: Int
)

data class FileSnapshot(
    val original: File,
    val backup: File,
    val permissions: Set<PosixFilePermission>?
)

class ConfigurationException(
    message: String
) : RuntimeException(message)

fun configurationError(message: String): Nothing {
    throw ConfigurationException(message)
}

fun info(message: String) {
    println(message)
}

fun requireFile(
    file: File,
    description: String
) {
    if (!file.exists()) {
        configurationError(
            "$description does not exist: ${file.absolutePath}"
        )
    }

    if (!file.isFile) {
        configurationError(
            "$description is not a regular file: ${file.absolutePath}"
        )
    }

    if (!file.canRead()) {
        configurationError(
            "$description is not readable: ${file.absolutePath}"
        )
    }

    if (!file.canWrite()) {
        configurationError(
            "$description is not writable: ${file.absolutePath}"
        )
    }
}

fun atomicWrite(
    file: File,
    content: String
) {
    val parent =
        file.parentFile
            ?: configurationError(
                "Unable to determine parent directory for " +
                    file.absolutePath
            )

    val temporary =
        Files.createTempFile(
            parent.toPath(),
            ".${file.name}.",
            ".tmp"
        ).toFile()

    try {
        temporary.writeText(content)

        try {
            Files.setPosixFilePermissions(
                temporary.toPath(),
                Files.getPosixFilePermissions(
                    file.toPath()
                )
            )
        } catch (_: UnsupportedOperationException) {
            /*
             * Non-POSIX filesystem.
             */
        }

        try {
            Files.move(
                temporary.toPath(),
                file.toPath(),
                StandardCopyOption.ATOMIC_MOVE,
                StandardCopyOption.REPLACE_EXISTING
            )
        } catch (_: Exception) {
            Files.move(
                temporary.toPath(),
                file.toPath(),
                StandardCopyOption.REPLACE_EXISTING
            )
        }
    } finally {
        if (temporary.exists()) {
            temporary.delete()
        }
    }
}

fun parseKernelVersion(
    version: String
): KernelVersion {
    val match =
        Regex("""^(\d+)\.(\d+)""")
            .find(version)
            ?: configurationError(
                "Invalid KERNELVERSION: $version"
            )

    return KernelVersion(
        major = match.groupValues[1].toInt(),
        minor = match.groupValues[2].toInt()
    )
}

fun isSupportedKernelVersion(
    version: String
): Boolean {
    val kernel = parseKernelVersion(version)

    return when {
        kernel.major < 5 ->
            true

        kernel.major == 5 &&
            kernel.minor <= 15 ->
            true

        kernel.major >= 6 &&
            kernel.minor >= 1 ->
            true

        else ->
            false
    }
}

fun isLegacyKernel(
    version: String
): Boolean {
    val kernel = parseKernelVersion(version)

    return kernel.major < 6
}

fun normalizeModules(
    input: String
): List<String> {
    if (input.isBlank()) {
        configurationError(
            "Module Blacklist Cannot Be Empty"
        )
    }

    val modules =
        input
            .split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    if (modules.isEmpty()) {
        configurationError(
            "No Valid Modules Were Supplied"
        )
    }

    val invalid =
        modules.filterNot {
            it.matches(
                Regex("""^[A-Za-z0-9_]+$""")
            )
        }

    if (invalid.isNotEmpty()) {
        configurationError(
            "Invalid Kernel Module Name(s): " +
                invalid.joinToString(", ") +
                ". Only letters, numbers and underscores are allowed."
        )
    }

    return modules.distinct()
}

fun buildKconfigBlock(
    modules: List<String>
): String {
    val joined = modules.joinToString(",")

    return """
config DEBLOAT_VENDOR_MODULES
	string "Debloat specific custom modules"
	default "$joined"
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

extern char *saved_command_line;

DEFINE_STATIC_KEY_TRUE(vendor_debloat_key);

static bool __init is_normal_boot(void)
{
	const char *mode;

	mode = xbc_find_value("androidboot.mode", NULL);

	if (!mode) {
		char *p = strstr(saved_command_line, "androidboot.mode=");
		static char buf[32];

		if (p) {
			size_t len;

			p += strlen("androidboot.mode=");

			len = strcspn(p, " \t\n");

			if (len >= sizeof(buf))
				len = sizeof(buf) - 1;

			memcpy(buf, p, len);
			buf[len] = '\0';

			mode = buf;
		}
	}

	if (mode &&
	    (!strcmp(mode, "normal") ||
	     !strcmp(mode, "reboot")))
		return true;

	if (xbc_find_value(
		    "androidboot.force_normal_boot",
		    NULL) ||
	    strstr(
		    saved_command_line,
		    "androidboot.force_normal_boot"))
		return true;

	if (strstr(
		    saved_command_line,
		    "oplusboot.mode=normal") ||
	    strstr(
		    saved_command_line,
		    "oplusboot.mode=reboot"))
		return true;

	return false;
}

static int __init init_vendor_debloat_boot_check(void)
{
	if (is_normal_boot()) {
		pr_info(
			"Boot Mode: Standard state. "
			"Debloater remains ACTIVE.\n"
		);
	} else {
		pr_info(
			"Boot Mode: Non-standard boot detected. "
			"Disabling module debloater.\n"
		);

		static_branch_disable(&vendor_debloat_key);
	}

	return 0;
}

early_initcall(init_vendor_debloat_boot_check);

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

		if (strlen(module_name) == len &&
		    !memcmp(module_name, p, len))
			return true;

		if (p[len] == ',')
			len++;
	}

custom_blacklist:
	if (static_branch_likely(&vendor_debloat_key)) {
		if (!custom_module_blacklist ||
		    custom_module_blacklist[0] == '\0')
			goto out;

		for (p = custom_module_blacklist;
		     *p;
		     p += len) {
			len = strcspn(p, ",");

			if (strlen(module_name) == len &&
			    !memcmp(module_name, p, len))
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

fun extractKconfigBlock(
    source: String
): String? {
    val symbolIndex =
        source.indexOf(KCONFIG_SYMBOL)

    if (symbolIndex < 0) {
        return null
    }

    val nextConfig =
        Regex("""(?m)^config\s+""")
            .find(
                source,
                symbolIndex + KCONFIG_SYMBOL.length
            )

    val end =
        nextConfig?.range?.first
            ?: source.length

    return source.substring(
        symbolIndex,
        end
    )
}

fun detectKconfigState(
    source: String
): PatchState {
    if (!source.contains(KCONFIG_SYMBOL)) {
        return PatchState.ABSENT
    }

    val block =
        extractKconfigBlock(source)
            ?: return PatchState.PARTIAL

    val hasPrompt =
        block.contains(
            "string \"Debloat specific custom modules\""
        )

    val hasDefault =
        Regex(
            """(?m)^\s*default\s+"[^"]*"\s*$"""
        ).containsMatchIn(block)

    val hasHelp =
        block.contains(
            "Pass a comma-separated list of module names to block."
        )

    val hasExample =
        block.contains(
            "oplus_network_tuning,oplus_bsp_zsmalloc"
        )

    return if (
        hasPrompt &&
        hasDefault &&
        hasHelp &&
        hasExample
    ) {
        PatchState.COMPLETE
    } else {
        PatchState.PARTIAL
    }
}

fun detectBootModeState(
    source: String
): PatchState {
    val checks =
        listOf(
            source.contains(
                "#include <linux/bootconfig.h>"
            ),
            source.contains(
                "extern char *saved_command_line;"
            ),
            source.contains(
                STATIC_KEY_DECLARATION
            ),
            source.contains(
                BOOT_FUNCTION
            ),
            source.contains(
                "xbc_find_value(\"androidboot.mode\", NULL)"
            ),
            source.contains(
                "androidboot.force_normal_boot"
            ),
            source.contains(
                "oplusboot.mode=normal"
            ),
            source.contains(
                "oplusboot.mode=reboot"
            ),
            source.contains(
                BOOT_INIT_FUNCTION
            ),
            source.contains(
                "early_initcall("
            ),
            source.contains(
                "static_branch_disable(&vendor_debloat_key)"
            )
        )

    val count = checks.count { it }

    return when {
        count == 0 ->
            PatchState.ABSENT

        count == checks.size ->
            PatchState.COMPLETE

        else ->
            PatchState.PARTIAL
    }
}

fun detectBlacklistState(
    source: String
): PatchState {
    val checks =
        listOf(
            source.contains(
                CUSTOM_BLACKLIST_DECLARATION
            ),
            source.contains(
                BLACKLIST_FUNCTION
            ),
            source.contains(
                "goto custom_blacklist;"
            ),
            source.contains(
                "custom_blacklist:"
            ),
            source.contains(
                "custom_module_blacklist"
            ),
            source.contains(
                "static_branch_likely(&vendor_debloat_key)"
            ),
            source.contains(
                MODULE_BLACKLIST_PARAM
            )
        )

    val count = checks.count { it }

    return when {
        count == 0 ->
            PatchState.ABSENT

        count == checks.size ->
            PatchState.COMPLETE

        else ->
            PatchState.PARTIAL
    }
}

fun assertNotPartial(
    description: String,
    state: PatchState,
    file: File
) {
    if (state == PatchState.PARTIAL) {
        configurationError(
            "$description is partially applied in " +
                "${file.absolutePath}. " +
                "Refusing to modify the kernel automatically."
        )
    }
}

fun preflight(
    kconfig: File,
    moduleSource: File,
    legacy: Boolean
) {
    val kconfigText = kconfig.readText()
    val moduleText = moduleSource.readText()

    val kconfigState =
        detectKconfigState(kconfigText)

    val bootState =
        detectBootModeState(moduleText)

    val blacklistState =
        detectBlacklistState(moduleText)

    assertNotPartial(
        "DEBLOAT_VENDOR_MODULES Kconfig patch",
        kconfigState,
        kconfig
    )

    assertNotPartial(
        "Vendor boot-mode patch",
        bootState,
        moduleSource
    )

    assertNotPartial(
        "Vendor blacklist patch",
        blacklistState,
        moduleSource
    )

    if (kconfigState == PatchState.ABSENT &&
        !kconfigText.contains(KCONFIG_ANCHOR)
    ) {
        configurationError(
            "Unable to locate Kconfig insertion anchor: " +
                KCONFIG_ANCHOR
        )
    }

    if (bootState == PatchState.ABSENT) {
        val anchor =
            if (legacy) {
                "#define ARCH_SHF_SMALL 0\n#endif"
            } else {
                "#undef CREATE_TRACE_POINTS\n" +
                    "#include <trace/hooks/module.h>"
            }

        if (!moduleText.contains(anchor)) {
            configurationError(
                "Unable to locate boot-mode insertion anchor in " +
                    moduleSource.absolutePath
            )
        }
    }

    if (blacklistState == PatchState.ABSENT) {
        if (!moduleText.contains(
                MODULE_BLACKLIST_DECLARATION
            )
        ) {
            configurationError(
                "Unable to locate module_blacklist declaration in " +
                    moduleSource.absolutePath
            )
        }

        val functionStart =
            moduleText.indexOf(
                BLACKLIST_FUNCTION
            )

        if (functionStart < 0) {
            configurationError(
                "Unable to locate blacklisted() function in " +
                    moduleSource.absolutePath
            )
        }

        val functionEnd =
            moduleText.indexOf(
                MODULE_BLACKLIST_PARAM,
                functionStart
            )

        if (functionEnd < 0) {
            configurationError(
                "Unable to locate module_blacklist core_param() " +
                    "after blacklisted() in " +
                    moduleSource.absolutePath
            )
        }

        val existingFunction =
            moduleText.substring(
                functionStart,
                functionEnd
            )

        if (
            !existingFunction.contains(
                "if (!module_blacklist)"
            ) ||
            !existingFunction.contains(
                "strcspn"
            ) ||
            !existingFunction.contains(
                "memcmp"
            )
        ) {
            configurationError(
                "Unexpected blacklisted() implementation detected in " +
                    moduleSource.absolutePath +
                    ". Refusing to replace it."
            )
        }
    }

    info("✔️ Preflight validation passed")
}

fun configureKconfig(
    kconfig: File,
    modules: List<String>
) {
    val source = kconfig.readText()

    when (detectKconfigState(source)) {
        PatchState.PARTIAL ->
            configurationError(
                "Refusing to modify a partially applied Kconfig patch."
            )

        PatchState.COMPLETE -> {
            val existingBlock =
                extractKconfigBlock(source)
                    ?: configurationError(
                        "Unable to read existing " +
                            "DEBLOAT_VENDOR_MODULES block."
                    )

            val expectedDefault =
                "default \"" +
                    modules.joinToString(",") +
                    "\""

            if (existingBlock.contains(expectedDefault)) {
                info(
                    "ℹ️ DEBLOAT_VENDOR_MODULES Kconfig " +
                        "is already configured"
                )
                return
            }

            val updatedBlock =
                existingBlock.replace(
                    Regex(
                        """(?m)^(\s*)default\s+"[^"]*"\s*$"""
                    ),
                    "$1$expectedDefault"
                )

            if (updatedBlock == existingBlock) {
                configurationError(
                    "Unable to locate existing " +
                        "DEBLOAT_VENDOR_MODULES default."
                )
            }

            val start =
                source.indexOf(KCONFIG_SYMBOL)

            val end =
                start + existingBlock.length

            val updated =
                source.substring(0, start) +
                    updatedBlock +
                    source.substring(end)

            atomicWrite(kconfig, updated)

            info(
                "✔️ Updated CONFIG_DEBLOAT_VENDOR_MODULES " +
                    "default in arch/arm64/Kconfig"
            )

            return
        }

        PatchState.ABSENT -> Unit
    }

    val anchorIndex =
        source.indexOf(KCONFIG_ANCHOR)

    if (anchorIndex < 0) {
        configurationError(
            "Unable to locate Kconfig insertion anchor: " +
                KCONFIG_ANCHOR
        )
    }

    val insertPosition =
        anchorIndex + KCONFIG_ANCHOR.length

    val updated =
        source.substring(0, insertPosition) +
            "\n\n" +
            buildKconfigBlock(modules) +
            source.substring(insertPosition)

    atomicWrite(kconfig, updated)

    info(
        "✔️ Added CONFIG_DEBLOAT_VENDOR_MODULES " +
            "to arch/arm64/Kconfig"
    )
}

fun configureBootMode(
    moduleSource: File,
    legacy: Boolean
) {
    val source = moduleSource.readText()

    when (detectBootModeState(source)) {
        PatchState.COMPLETE -> {
            info(
                "ℹ️ Conditional vendor boot-mode " +
                    "logic already exists"
            )
            return
        }

        PatchState.PARTIAL ->
            configurationError(
                "Refusing to modify a partially applied " +
                    "boot-mode patch in " +
                    moduleSource.path
            )

        PatchState.ABSENT -> Unit
    }

    val anchor =
        if (legacy) {
            "#define ARCH_SHF_SMALL 0\n#endif"
        } else {
            "#undef CREATE_TRACE_POINTS\n" +
                "#include <trace/hooks/module.h>"
        }

    if (!source.contains(anchor)) {
        configurationError(
            "Unable to locate boot-mode insertion anchor in " +
                moduleSource.absolutePath
        )
    }

    val updated =
        source.replace(
            anchor,
            anchor +
                "\n\n" +
                buildBootModeBlock()
        )

    atomicWrite(moduleSource, updated)

    info(
        "✔️ Added patch-compatible OPlus boot-mode handling"
    )
}

fun configureBlacklistLogic(
    moduleSource: File
) {
    var source = moduleSource.readText()

    when (detectBlacklistState(source)) {
        PatchState.COMPLETE -> {
            info(
                "ℹ️ Conditional vendor blacklist " +
                    "logic already exists"
            )
            return
        }

        PatchState.PARTIAL ->
            configurationError(
                "Refusing to modify a partially applied " +
                    "vendor blacklist patch in " +
                    moduleSource.path
            )

        PatchState.ABSENT -> Unit
    }

    if (!source.contains(MODULE_BLACKLIST_DECLARATION)) {
        configurationError(
            "Unable to locate module_blacklist declaration in " +
                moduleSource.absolutePath
        )
    }

    source =
        source.replace(
            MODULE_BLACKLIST_DECLARATION,
            MODULE_BLACKLIST_DECLARATION +
                "\n" +
                CUSTOM_BLACKLIST_DECLARATION
        )

    val functionStart =
        source.indexOf(BLACKLIST_FUNCTION)

    if (functionStart < 0) {
        configurationError(
            "Unable to locate blacklisted() function in " +
                moduleSource.absolutePath
        )
    }

    val functionEnd =
        source.indexOf(
            MODULE_BLACKLIST_PARAM,
            functionStart
        )

    if (functionEnd < 0) {
        configurationError(
            "Unable to locate module_blacklist core_param() " +
                "after blacklisted() in " +
                moduleSource.absolutePath
        )
    }

    val existingFunction =
        source.substring(
            functionStart,
            functionEnd
        )

    if (
        !existingFunction.contains(
            "if (!module_blacklist)"
        ) ||
        !existingFunction.contains("strcspn") ||
        !existingFunction.contains("memcmp")
    ) {
        configurationError(
            "Unexpected blacklisted() implementation detected in " +
                moduleSource.absolutePath +
                ". Refusing to replace it."
        )
    }

    source =
        source.substring(0, functionStart) +
            buildBlacklistFunction() +
            source.substring(functionEnd)

    atomicWrite(moduleSource, source)

    info(
        "✔️ Added patch-compatible vendor module " +
            "blacklist logic"
    )
}

fun verify(
    kconfig: File,
    moduleSource: File,
    modules: List<String>
) {
    val kconfigText = kconfig.readText()
    val moduleText = moduleSource.readText()

    if (
        detectKconfigState(kconfigText) !=
        PatchState.COMPLETE
    ) {
        configurationError(
            "Verification failed: Kconfig patch is incomplete."
        )
    }

    val kconfigBlock =
        extractKconfigBlock(kconfigText)
            ?: configurationError(
                "Verification failed: " +
                    "DEBLOAT_VENDOR_MODULES block is missing."
            )

    val expectedDefault =
        "default \"" +
            modules.joinToString(",") +
            "\""

    if (!kconfigBlock.contains(expectedDefault)) {
        configurationError(
            "Verification failed: expected Kconfig default " +
                "is missing: $expectedDefault"
        )
    }

    if (
        detectBootModeState(moduleText) !=
        PatchState.COMPLETE
    ) {
        configurationError(
            "Verification failed: boot-mode implementation " +
                "is incomplete."
        )
    }

    if (
        detectBlacklistState(moduleText) !=
        PatchState.COMPLETE
    ) {
        configurationError(
            "Verification failed: blacklist implementation " +
                "is incomplete."
        )
    }

    val requiredStrings =
        listOf(
            "#include <linux/bootconfig.h>",
            "extern char *saved_command_line;",
            STATIC_KEY_DECLARATION,
            BOOT_FUNCTION,
            "xbc_find_value(\"androidboot.mode\", NULL)",
            "androidboot.force_normal_boot",
            "oplusboot.mode=normal",
            "oplusboot.mode=reboot",
            BOOT_INIT_FUNCTION,
            "early_initcall(",
            "static_branch_disable(&vendor_debloat_key)",
            CUSTOM_BLACKLIST_DECLARATION,
            "static_branch_likely(&vendor_debloat_key)",
            "custom_blacklist:"
        )

    for (required in requiredStrings) {
        if (!moduleText.contains(required)) {
            configurationError(
                "Verification failed: missing required component: " +
                    required
            )
        }
    }

    if (
        kconfigText
            .split(KCONFIG_SYMBOL)
            .size - 1 != 1
    ) {
        configurationError(
            "Verification failed: expected exactly one " +
                "DEBLOAT_VENDOR_MODULES symbol."
        )
    }

    if (
        moduleText
            .split(STATIC_KEY_DECLARATION)
            .size - 1 != 1
    ) {
        configurationError(
            "Verification failed: expected exactly one " +
                "vendor_debloat_key declaration."
        )
    }

    if (
        moduleText
            .split(CUSTOM_BLACKLIST_DECLARATION)
            .size - 1 != 1
    ) {
        configurationError(
            "Verification failed: expected exactly one " +
                "custom_module_blacklist declaration."
        )
    }

    info("✔️ Source verification passed")
}

fun createSnapshot(
    file: File
): FileSnapshot {
    val backup =
        Files.createTempFile(
            file.parentFile.toPath(),
            ".${file.name}.rollback.",
            ".bak"
        ).toFile()

    try {
        Files.copy(
            file.toPath(),
            backup.toPath(),
            StandardCopyOption.REPLACE_EXISTING
        )

        val permissions =
            try {
                Files.getPosixFilePermissions(
                    file.toPath()
                )
            } catch (_: UnsupportedOperationException) {
                null
            }

        return FileSnapshot(
            original = file,
            backup = backup,
            permissions = permissions
        )
    } catch (exception: Exception) {
        try {
            backup.delete()
        } catch (_: Exception) {
        }

        throw exception
    }
}

fun createSnapshots(
    files: List<File>
): List<FileSnapshot> {
    val snapshots =
        mutableListOf<FileSnapshot>()

    try {
        for (file in files) {
            snapshots += createSnapshot(file)
        }

        return snapshots
    } catch (exception: Exception) {
        snapshots.asReversed().forEach { snapshot ->
            try {
                snapshot.backup.delete()
            } catch (_: Exception) {
            }
        }

        throw ConfigurationException(
            "Unable to create complete rollback snapshot: " +
                (
                    exception.message
                        ?: exception::class.simpleName
                        ?: "Unknown error"
                )
        )
    }
}

fun restoreSnapshot(
    snapshot: FileSnapshot
) {
    Files.copy(
        snapshot.backup.toPath(),
        snapshot.original.toPath(),
        StandardCopyOption.REPLACE_EXISTING
    )

    snapshot.permissions?.let {
        Files.setPosixFilePermissions(
            snapshot.original.toPath(),
            it
        )
    }
}

fun rollback(
    snapshots: List<FileSnapshot>
): List<Throwable> {
    val failures =
        mutableListOf<Throwable>()

    info(
        "⚠️ Modification failed — starting rollback"
    )

    for (snapshot in snapshots.asReversed()) {
        try {
            restoreSnapshot(snapshot)

            info(
                "↩️ Restored ${snapshot.original.absolutePath}"
            )
        } catch (exception: Throwable) {
            failures += exception

            System.err.println(
                "::error::Rollback failed for " +
                    "${snapshot.original.absolutePath}: " +
                    (
                        exception.message
                            ?: exception::class.simpleName
                            ?: "Unknown error"
                    )
            )
        }
    }

    /*
     * Verify every snapshot after attempting all restores.
     */
    for (snapshot in snapshots) {
        try {
            val current =
                Files.readAllBytes(
                    snapshot.original.toPath()
                )

            val backup =
                Files.readAllBytes(
                    snapshot.backup.toPath()
                )

            if (!current.contentEquals(backup)) {
                failures +=
                    ConfigurationException(
                        "Rollback verification failed for " +
                            snapshot.original.absolutePath
                    )

                System.err.println(
                    "::error::Rollback verification failed for " +
                        snapshot.original.absolutePath
                )
            }
        } catch (exception: Throwable) {
            failures += exception

            System.err.println(
                "::error::Unable to verify rollback for " +
                    snapshot.original.absolutePath + ": " +
                    (
                        exception.message
                            ?: exception::class.simpleName
                            ?: "Unknown error"
                    )
            )
        }
    }

    return failures
}

fun cleanupSnapshots(
    snapshots: List<FileSnapshot>
) {
    for (snapshot in snapshots) {
        try {
            if (snapshot.backup.exists() &&
                !snapshot.backup.delete()
            ) {
                System.err.println(
                    "::warning::Unable to delete rollback snapshot: " +
                        snapshot.backup.absolutePath
                )
            }
        } catch (exception: Exception) {
            System.err.println(
                "::warning::Unable to delete rollback snapshot: " +
                    snapshot.backup.absolutePath +
                    ": " +
                    (
                        exception.message
                            ?: exception::class.simpleName
                            ?: "Unknown error"
                    )
            )
        }
    }
}

fun formatFailure(
    exception: Throwable
): String {
    return exception.message
        ?: exception::class.simpleName
        ?: "Unknown error"
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
            "/path/to/kernel_platform/common" \
            "oplus_secure_guard_new,oplus_bsp_zsmalloc" \
            "6.12"
        """.trimIndent()
    )
}

val kernelDir =
    File(args[0]).canonicalFile

val moduleInput =
    args[1]

val kernelVersion =
    args[2].trim()

try {
    if (!kernelDir.isDirectory) {
        configurationError(
            "Kernel source directory not found: " +
                kernelDir.absolutePath
        )
    }

    if (!isSupportedKernelVersion(kernelVersion)) {
        configurationError(
            "Unsupported KERNELVERSION: $kernelVersion. " +
                "Supported layouts are 5.15 and below, " +
                "or 6.1 and above. " +
                "5.16-5.19 and 6.0 are intentionally rejected."
        )
    }

    val modules =
        normalizeModules(moduleInput)

    val protectedModules =
        setOf(
            "coresight",
            "rust_binder",
            "msm_kgsl",
            "camera"
        )

    val protectedRequested =
        modules.filter {
            it in protectedModules
        }

    if (protectedRequested.isNotEmpty()) {
        configurationError(
            "Protected module(s) cannot be blacklisted: " +
                protectedRequested.joinToString(", ")
        )
    }

    val legacy =
        isLegacyKernel(kernelVersion)

    val kconfig =
        File(
            kernelDir,
            "arch/arm64/Kconfig"
        )

    val moduleSource =
        if (legacy) {
            File(
                kernelDir,
                "kernel/module.c"
            )
        } else {
            File(
                kernelDir,
                "kernel/module/main.c"
            )
        }

    info("")
    info("🛡️ Conditional Vendor Module Blacklist")
    info(
        "📂 Kernel Source : " +
            kernelDir.absolutePath
    )
    info(
        "📦 Kernel        : " +
            kernelVersion
    )
    info(
        "🧩 Implementation: " +
            if (legacy) {
                "kernel/module.c"
            } else {
                "kernel/module/main.c"
            }
    )
    info(
        "📦 Modules       : " +
            modules.joinToString(", ")
    )
    info(
        "📋 Configuration : arch/arm64/Kconfig"
    )
    info(
        "🚫 Defconfig     : Not modified"
    )
    info("")

    requireFile(
        kconfig,
        "ARM64 Kconfig"
    )

    requireFile(
        moduleSource,
        "Kernel module source"
    )

    info("🔎 Validating kernel source...")

    preflight(
        kconfig,
        moduleSource,
        legacy
    )

    /*
     * Important:
     *
     * Both snapshots are created before ANY modification.
     *
     * If the second snapshot fails, the first snapshot is
     * immediately cleaned up and the kernel remains untouched.
     */
    val snapshots =
        createSnapshots(
            listOf(
                kconfig,
                moduleSource
            )
        )

    var transactionCommitted =
        false

    try {
        configureKconfig(
            kconfig,
            modules
        )

        configureBootMode(
            moduleSource,
            legacy
        )

        configureBlacklistLogic(
            moduleSource
        )

        verify(
            kconfig,
            moduleSource,
            modules
        )

        transactionCommitted =
            true

        info(
            "✔️ Transaction committed successfully"
        )

    } catch (exception: Throwable) {

        val rollbackFailures =
            rollback(snapshots)

        if (rollbackFailures.isNotEmpty()) {
            System.err.println(
                "::error::Rollback completed with " +
                    "${rollbackFailures.size} failure(s)."
            )

            System.err.println(
                "::error::The kernel source may require " +
                    "manual restoration."
            )

            System.err.println(
                "::error::Original failure: " +
                    formatFailure(exception)
            )

            throw ConfigurationException(
                "Configuration failed and rollback was not " +
                    "fully successful."
            )
        }

        /*
         * Rollback succeeded completely.
         *
         * Re-throw the original failure rather than replacing
         * it with a generic rollback message.
         */
        throw exception

    } finally {
        /*
         * Backups are temporary transaction resources.
         *
         * They are deleted whether the transaction commits,
         * rolls back successfully, or rollback itself fails.
         */
        if (transactionCommitted) {
            info(
                "🧹 Cleaning committed transaction snapshots"
            )
        } else {
            info(
                "🧹 Cleaning rollback transaction snapshots"
            )
        }

        cleanupSnapshots(snapshots)
    }

    info("")
    info(
        "🎉 Conditional Vendor Module Blacklist Configured"
    )
    info(
        "📦 Kernel Version : " +
            kernelVersion
    )
    info(
        "📦 Module Source  : " +
            moduleSource.relativeTo(kernelDir)
    )
    info(
        "📋 Kconfig        : " +
            kconfig.relativeTo(kernelDir)
    )
    info(
        "📦 Blacklisted    : " +
            modules.joinToString(", ")
    )
    info(
        "🚫 gki_defconfig  : Not modified"
    )
    info("")

} catch (exception: Throwable) {
    fail(
        "Conditional vendor blacklist configuration failed: " +
            formatFailure(exception)
    )
}
