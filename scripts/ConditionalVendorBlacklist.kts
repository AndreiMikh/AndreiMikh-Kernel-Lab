#!/usr/bin/env kotlin

import java.io.File
import java.nio.file.Files
import java.nio.file.StandardCopyOption
import java.nio.file.attribute.PosixFilePermission
import kotlin.system.exitProcess

/*
 * conditional vendor module blacklist
 *
 * supported:
 *   - linux 5.15 and below
 *   - linux 6.1 and above
 *
 * unsupported:
 *   - linux 5.16 - 5.19
 *   - linux 6.0
 *
 * transaction:
 *   - preflight validation
 *   - complete and partial patch detection
 *   - full snapshots before modification
 *   - atomic writes
 *   - single rollback path
 *   - rollback verification
 *   - snapshot cleanup
 *
 * kotlin script compatibility:
 *   - kotlinc-jvm 2.4.x
 *   - jre 17+
 */

/*
 * note:
 * kotlin script files executed with `kotlinc -script` do not reliably
 * accept `const val` declarations in every script scope/configuration
 *
 * use regular top-level vals instead
 */

private val KCONFIG_SYMBOL =
    "config DEBLOAT_VENDOR_MODULES"

private val KCONFIG_ANCHOR =
    "source \"drivers/cpufreq/Kconfig\""

private val MODULE_BLACKLIST_DECLARATION =
    "static char *module_blacklist;"

private val CUSTOM_BLACKLIST_DECLARATION =
    "static const char *custom_module_blacklist = " +
        "CONFIG_DEBLOAT_VENDOR_MODULES;"

private val STATIC_KEY_DECLARATION =
    "DEFINE_STATIC_KEY_TRUE(vendor_debloat_key);"

private val BOOT_FUNCTION =
    "static bool __init is_normal_boot(void)"

private val BOOT_INIT_FUNCTION =
    "static int __init init_vendor_debloat_boot_check(void)"

private val BLACKLIST_FUNCTION =
    "static bool blacklisted(const char *module_name)"

private val MODULE_BLACKLIST_PARAM =
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


fun configurationError(
    message: String
): Nothing {
    throw ConfigurationException(message)
}


fun fail(
    message: String
): Nothing {
    System.err.println(
        "::error::$message"
    )

    exitProcess(1)
}


fun info(
    message: String
) {
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
                "unable to determine parent directory for " +
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
             * Preserve behavior on non-posix filesystems.
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
                "invalid kernel version: $version"
            )

    return KernelVersion(
        major = match.groupValues[1].toInt(),
        minor = match.groupValues[2].toInt()
    )
}


fun isSupportedKernelVersion(
    version: String
): Boolean {
    val kernel =
        parseKernelVersion(version)

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
    val kernel =
        parseKernelVersion(version)

    return kernel.major < 6
}


/*
 * empty module input is valid
 *
 * this allows the caller to run the script when there are no conditional
 * modules to blacklist
 */
fun normalizeModules(
    input: String
): List<String> {
    if (input.isBlank()) {
        return emptyList()
    }

    val modules =
        input
            .split(',')
            .map { it.trim() }
            .filter { it.isNotEmpty() }

    if (modules.isEmpty()) {
        return emptyList()
    }

    val invalid =
        modules.filterNot {
            it.matches(
                Regex("""^[A-Za-z0-9_]+$""")
            )
        }

    if (invalid.isNotEmpty()) {
        configurationError(
            "invalid kernel module name(s): " +
                invalid.joinToString(", ") +
                " only letters, numbers and underscores are allowed"
        )
    }

    return modules.distinct()
}


fun buildKconfigBlock(
    modules: List<String>
): String {
    val joined =
        modules.joinToString(",")

    return """
config DEBLOAT_VENDOR_MODULES
	string "debloat specific custom modules"
	default "$joined"
	help
	  pass a comma-separated list of module names to block
	  example: "oplus_network_tuning,oplus_bsp_zsmalloc"

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
			"boot mode: standard state "
			"debloater remains active\n"
		);
	} else {
		pr_info(
			"boot mode: non-standard boot detected "
			"disabling module debloater\n"
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
            "string \"debloat specific custom modules\""
        )

    val hasDefault =
        Regex(
            """(?m)^\s*default\s+"[^"]*"\s*$"""
        ).containsMatchIn(block)

    val hasHelp =
        block.contains(
            "pass a comma-separated list of module names to block"
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

    val count =
        checks.count { it }

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

    val count =
        checks.count { it }

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
                "${file.absolutePath} refusing to modify the kernel automatically"
        )
    }
}


fun preflight(
    kconfig: File,
    moduleSource: File,
    legacy: Boolean
) {
    val kconfigText =
        kconfig.readText()

    val moduleText =
        moduleSource.readText()

    val kconfigState =
        detectKconfigState(kconfigText)

    val bootState =
        detectBootModeState(moduleText)

    val blacklistState =
        detectBlacklistState(moduleText)

    assertNotPartial(
        "debloat_vendor_modules kconfig patch",
        kconfigState,
        kconfig
    )

    assertNotPartial(
        "vendor boot-mode patch",
        bootState,
        moduleSource
    )

    assertNotPartial(
        "vendor blacklist patch",
        blacklistState,
        moduleSource
    )

    if (
        kconfigState == PatchState.ABSENT &&
        !kconfigText.contains(KCONFIG_ANCHOR)
    ) {
        configurationError(
            "unable to locate kconfig insertion anchor: " +
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
                "unable to locate boot-mode insertion anchor in " +
                    moduleSource.absolutePath
            )
        }
    }

    if (blacklistState == PatchState.ABSENT) {
        if (
            !moduleText.contains(
                MODULE_BLACKLIST_DECLARATION
            )
        ) {
            configurationError(
                "unable to locate module blacklist declaration in " +
                    moduleSource.absolutePath
            )
        }

        val functionStart =
            moduleText.indexOf(
                BLACKLIST_FUNCTION
            )

        if (functionStart < 0) {
            configurationError(
                "unable to locate blacklisted() function in " +
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
                "unable to locate module blacklist core param() " +
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
                "unexpected blacklisted() implementation detected in " +
                    moduleSource.absolutePath +
                    " refusing to replace it"
            )
        }
    }

    info("✔️ preflight validation passed")
}


fun configureKconfig(
    kconfig: File,
    modules: List<String>
) {
    val source =
        kconfig.readText()

    when (detectKconfigState(source)) {
        PatchState.PARTIAL ->
            configurationError(
                "refusing to modify a partially applied kconfig patch"
            )

        PatchState.COMPLETE -> {
            val existingBlock =
                extractKconfigBlock(source)
                    ?: configurationError(
                        "unable to read existing " +
                            "debloat_vendor_modules block"
                    )

            val expectedDefault =
                "default \"" +
                    modules.joinToString(",") +
                    "\""

            if (existingBlock.contains(expectedDefault)) {
                info(
                    "ℹ️ debloat vendor modules kconfig " +
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
                    "unable to locate existing " +
                        "debloat vendor modules default"
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

            atomicWrite(
                kconfig,
                updated
            )

            info(
                "✔️ updated config debloat vendor modules " +
                    "default in arch/arm64/kconfig"
            )

            return
        }

        PatchState.ABSENT -> Unit
    }

    val anchorIndex =
        source.indexOf(KCONFIG_ANCHOR)

    if (anchorIndex < 0) {
        configurationError(
            "unable to locate kconfig insertion anchor: " +
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

    atomicWrite(
        kconfig,
        updated
    )

    info(
        "✔️ added config debloat vendor modules " +
            "to arch/arm64/kconfig"
    )
}


fun configureBootMode(
    moduleSource: File,
    legacy: Boolean
) {
    val source =
        moduleSource.readText()

    when (detectBootModeState(source)) {
        PatchState.COMPLETE -> {
            info(
                "ℹ️ conditional vendor boot-mode " +
                    "logic already exists"
            )
            return
        }

        PatchState.PARTIAL ->
            configurationError(
                "refusing to modify a partially applied " +
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
            "unable to locate boot-mode insertion anchor in " +
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

    atomicWrite(
        moduleSource,
        updated
    )

    info(
        "✔️ added patch-compatible oplus boot-mode handling"
    )
}


fun configureBlacklistLogic(
    moduleSource: File
) {
    var source =
        moduleSource.readText()

    when (detectBlacklistState(source)) {
        PatchState.COMPLETE -> {
            info(
                "ℹ️ conditional vendor blacklist " +
                    "logic already exists"
            )
            return
        }

        PatchState.PARTIAL ->
            configurationError(
                "refusing to modify a partially applied " +
                    "vendor blacklist patch in " +
                    moduleSource.path
            )

        PatchState.ABSENT -> Unit
    }

    if (
        !source.contains(
            MODULE_BLACKLIST_DECLARATION
        )
    ) {
        configurationError(
            "unable to locate module blacklist declaration in " +
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
        source.indexOf(
            BLACKLIST_FUNCTION
        )

    if (functionStart < 0) {
        configurationError(
            "unable to locate blacklisted() function in " +
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
            "unable to locate module_blacklist core param() " +
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
        !existingFunction.contains(
            "strcspn"
        ) ||
        !existingFunction.contains(
            "memcmp"
        )
    ) {
        configurationError(
            "unexpected blacklisted() implementation detected in " +
                moduleSource.absolutePath +
                " refusing to replace it"
        )
    }

    source =
        source.substring(0, functionStart) +
            buildBlacklistFunction() +
            source.substring(functionEnd)

    atomicWrite(
        moduleSource,
        source
    )

    info(
        "✔️ added patch-compatible vendor module " +
            "blacklist logic"
    )
}


fun verify(
    kconfig: File,
    moduleSource: File,
    modules: List<String>
) {
    val kconfigText =
        kconfig.readText()

    val moduleText =
        moduleSource.readText()

    if (
        detectKconfigState(kconfigText) !=
        PatchState.COMPLETE
    ) {
        configurationError(
            "verification failed: kconfig patch is incomplete"
        )
    }

    val kconfigBlock =
        extractKconfigBlock(kconfigText)
            ?: configurationError(
                "verification failed: " +
                    "debloat_vendor_modules block is missing"
            )

    val expectedDefault =
        "default \"" +
            modules.joinToString(",") +
            "\""

    if (!kconfigBlock.contains(expectedDefault)) {
        configurationError(
            "verification failed: expected kconfig default " +
                "is missing: $expectedDefault"
        )
    }

    if (
        detectBootModeState(moduleText) !=
        PatchState.COMPLETE
    ) {
        configurationError(
            "verification failed: boot-mode implementation " +
                "is incomplete"
        )
    }

    if (
        detectBlacklistState(moduleText) !=
        PatchState.COMPLETE
    ) {
        configurationError(
            "verification failed: blacklist implementation " +
                "is incomplete"
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
                "verification failed: missing required component: " +
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
            "verification failed: expected exactly one " +
                "debloat vendor modules symbol"
        )
    }

    if (
        moduleText
            .split(STATIC_KEY_DECLARATION)
            .size - 1 != 1
    ) {
        configurationError(
            "verification failed: expected exactly one " +
                "vendor debloat key declaration"
        )
    }

    if (
        moduleText
            .split(CUSTOM_BLACKLIST_DECLARATION)
            .size - 1 != 1
    ) {
        configurationError(
            "verification failed: expected exactly one " +
                "custom module blacklist declaration"
        )
    }

    info("✔️ source verification passed")
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
            "unable to create complete rollback snapshot: " +
                (
                    exception.message
                        ?: exception::class.simpleName
                        ?: "unknown error"
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
        "⚠️ modification failed — starting rollback"
    )

    for (snapshot in snapshots.asReversed()) {
        try {
            restoreSnapshot(snapshot)

            info(
                "↩️ restored ${snapshot.original.absolutePath}"
            )
        } catch (exception: Throwable) {
            failures += exception

            System.err.println(
                "::error::rollback failed for " +
                    "${snapshot.original.absolutePath}: " +
                    (
                        exception.message
                            ?: exception::class.simpleName
                            ?: "unknown error"
                    )
            )
        }
    }

    /*
     * verify every snapshot after attempting all restores
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
                        "rollback verification failed for " +
                            snapshot.original.absolutePath
                    )

                System.err.println(
                    "::error::rollback verification failed for " +
                        snapshot.original.absolutePath
                )
            }
        } catch (exception: Throwable) {
            failures += exception

            System.err.println(
                "::error::unable to verify rollback for " +
                    snapshot.original.absolutePath + ": " +
                    (
                        exception.message
                            ?: exception::class.simpleName
                            ?: "unknown error"
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
            if (
                snapshot.backup.exists() &&
                !snapshot.backup.delete()
            ) {
                System.err.println(
                    "::warning::unable to delete rollback snapshot: " +
                        snapshot.backup.absolutePath
                )
            }
        } catch (exception: Exception) {
            System.err.println(
                "::warning::unable to delete rollback snapshot: " +
                    snapshot.backup.absolutePath +
                    ": " +
                    (
                        exception.message
                            ?: exception::class.simpleName
                            ?: "unknown error"
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
        ?: "unknown error"
}


/*
 * --------------------------------------------------------------------------
 * argument validation
 * --------------------------------------------------------------------------
 */

if (args.size < 3) {
    fail(
        """
        usage:
          kotlinc -script ConditionalVendorBlacklist.kts -- \
            <kerneldir> \
            <modules> \
            <kernelversion>
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
    /*
     * ----------------------------------------------------------------------
     * kernel validation
     * ----------------------------------------------------------------------
     */

    if (!kernelDir.isDirectory) {
        configurationError(
            "kernel source directory not found: " +
                kernelDir.absolutePath
        )
    }

    if (!isSupportedKernelVersion(kernelVersion)) {
        configurationError(
            "unsupported kernel version: $kernelVersion " +
                "supported layouts are 5.15 and below " +
                "or 6.1 and above " +
                "5.16-5.19 and 6.0 are intentionally rejected"
        )
    }


    /*
     * ----------------------------------------------------------------------
     * module validation
     * ----------------------------------------------------------------------
     */

    val modules =
        normalizeModules(moduleInput)

    val protectedModules =
        setOf(
            "coresight",
            "rust_binder",
            "msm_kgsl",
            "camera",
            "oplusboot",
            "rmnet_wlan",
            "rmnet_core",
            "msm_drm",
            "cnss2",
            "oplus_chg_v2",
            "reboot_mode",
            "rfkill",
            "bootloader_log"
        )

    val protectedRequested =
        modules.filter {
            it in protectedModules
        }

    if (protectedRequested.isNotEmpty()) {
        configurationError(
            "protected module(s) cannot be blacklisted: " +
                protectedRequested.joinToString(", ")
        )
    }


    /*
     * ----------------------------------------------------------------------
     * kernel layout
     * ----------------------------------------------------------------------
     */

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


    /*
     * ----------------------------------------------------------------------
     * display configuration
     * ----------------------------------------------------------------------
     */

    info("")
    info("🛡️ conditional vendor module blacklist")
    info(
        "📂 kernel source : " +
            kernelDir.absolutePath
    )
    info(
        "📦 kernel        : " +
            kernelVersion
    )
    info(
        "🧩 implementation: " +
            if (legacy) {
                "kernel/module.c"
            } else {
                "kernel/module/main.c"
            }
    )

    if (modules.isEmpty()) {
        info(
            "📦 modules       : none"
        )
    } else {
        info(
            "📦 modules       : " +
                modules.joinToString(", ")
        )
    }

    info(
        "📋 configuration : arch/arm64/Kconfig"
    )
    info(
        "🚫 defconfig     : not modified"
    )
    info("")


    /*
     * ----------------------------------------------------------------------
     * empty module list
     *
     * nothing needs to be modified if the caller supplied no modules
     * this is important for tcp = none or kernels with no conditional
     * blacklist requirement
     * ----------------------------------------------------------------------
     */

    if (modules.isEmpty()) {
        info(
            "ℹ️ no vendor modules requested"
        )
        info(
            "ℹ️ conditional vendor blacklist changes skipped"
        )
        info("")

        exitProcess(0)
    }


    /*
     * ----------------------------------------------------------------------
     * file validation
     * ----------------------------------------------------------------------
     */

    requireFile(
        kconfig,
        "arm64 kconfig"
    )

    requireFile(
        moduleSource,
        "kernel module source"
    )


    /*
     * ----------------------------------------------------------------------
     * preflight
     * ----------------------------------------------------------------------
 */

    info(
        "🔎 validating kernel source"
    )

    preflight(
        kconfig,
        moduleSource,
        legacy
    )


    /*
     * ----------------------------------------------------------------------
     * transaction snapshots
     *
     * both snapshots are created before any modification
     * ----------------------------------------------------------------------
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

        /*
         * --------------------------------------------------------------
         * apply kconfig
         * --------------------------------------------------------------
         */

        configureKconfig(
            kconfig,
            modules
        )


        /*
         * --------------------------------------------------------------
         * apply boot mode
         * --------------------------------------------------------------
         */

        configureBootMode(
            moduleSource,
            legacy
        )


        /*
         * --------------------------------------------------------------
         * apply blacklist logic
         * --------------------------------------------------------------
         */

        configureBlacklistLogic(
            moduleSource
        )


        /*
         * --------------------------------------------------------------
         * verify
         * --------------------------------------------------------------
         */

        verify(
            kconfig,
            moduleSource,
            modules
        )


        /*
         * --------------------------------------------------------------
         * commit
         * --------------------------------------------------------------
         */

        transactionCommitted =
            true

        info(
            "✔️ transaction committed successfully"
        )

    } catch (exception: Throwable) {

        val rollbackFailures =
            rollback(
                snapshots
            )

        if (rollbackFailures.isNotEmpty()) {

            System.err.println(
                "::error::rollback completed with " +
                    "${rollbackFailures.size} failure(s)"
            )

            System.err.println(
                "::error::the kernel source may require " +
                    "manual restoration"
            )

            System.err.println(
                "::error::original failure: " +
                    formatFailure(exception)
            )

            throw ConfigurationException(
                "configuration failed and rollback was not " +
                    "fully successful"
            )
        }

        /*
         * rollback succeeded completely
         * re-throw the original failure
         */

        throw exception

    } finally {

        if (transactionCommitted) {
            info(
                "🧹 cleaning committed transaction snapshots"
            )
        } else {
            info(
                "🧹 cleaning rollback transaction snapshots"
            )
        }

        cleanupSnapshots(
            snapshots
        )
    }


    /*
     * ----------------------------------------------------------------------
     * success
     * ----------------------------------------------------------------------
     */

    info("")
    info(
        "🎉 conditional vendor module blacklist configured"
    )
    info(
        "📦 kernel version : " +
            kernelVersion
    )
    info(
        "📦 module source  : " +
            moduleSource.relativeTo(kernelDir)
    )
    info(
        "📋 kconfig        : " +
            kconfig.relativeTo(kernelDir)
    )
    info(
        "📦 blacklisted    : " +
            modules.joinToString(", ")
    )
    info(
        "🚫 gki-defconfig  : not modified"
    )
    info("")

} catch (exception: Throwable) {

    fail(
        "conditional vendor blacklist configuration failed: " +
            formatFailure(exception)
    )
}
