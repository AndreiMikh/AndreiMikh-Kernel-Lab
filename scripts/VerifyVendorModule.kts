#!/usr/bin/env kotlin

import java.io.File
import kotlin.system.exitProcess

class VerificationException(
    message: String
) : RuntimeException(message)

fun fail(
    message: String
): Nothing {
    System.err.println("::error::$message")
    exitProcess(1)
}

fun normalizeModules(
    value: String
): List<String> {
    if (value.isBlank()) {
        return emptyList()
    }

    return value
        .split(',')
        .map { it.trim() }
        .filter { it.isNotEmpty() }
        .also { modules ->
            modules.forEach { module ->
                if (!Regex("^[A-Za-z0-9_]+$").matches(module)) {
                    throw VerificationException(
                        "invalid vendor module name: $module"
                    )
                }
            }
        }
        .distinct()
}

fun moduleExistsInSource(
    kernelSource: File,
    module: String
): Boolean {
    val process =
        ProcessBuilder(
            "grep",
            "-RIl",
            "--exclude-dir=.git",
            "--exclude-dir=out",
            "--exclude-dir=build",
            "--exclude-dir=.repo",
            "--",
            module,
            kernelSource.path
        )
            .redirectErrorStream(true)
            .start()

    val output =
        process.inputStream
            .bufferedReader()
            .readLines()

    val exitCode =
        process.waitFor()

    return when (exitCode) {
        0 -> {
            System.err.println(
                "✔️ found vendor module reference: $module"
            )

            output
                .take(5)
                .forEach { path ->
                    System.err.println(
                        "   📍 $path"
                    )
                }

            if (output.size > 5) {
                System.err.println(
                    "   ... and ${output.size - 5} more matches"
                )
            }

            true
        }

        1 -> {
            System.err.println(
                "⚠️ vendor module not found in source: $module"
            )

            false
        }

        else -> {
            throw VerificationException(
                "failed while searching for vendor module '$module' " +
                    "(grep exit code: $exitCode)"
            )
        }
    }
}

fun verifyModules(
    kernelSource: File,
    modules: List<String>
) {
    if (modules.isEmpty()) {
        System.err.println(
            "ℹ️ no vendor modules configured for verification"
        )
        return
    }

    System.err.println(
        "🔎 verifying configured vendor modules"
    )

    System.err.println(
        "📦 modules: ${modules.joinToString(",")}"
    )

    val missingModules =
        mutableListOf<String>()

    modules.forEach { module ->
        System.err.println()
        System.err.println(
            "🔍 searching source for: $module"
        )

        val found =
            moduleExistsInSource(
                kernelSource,
                module
            )

        if (!found) {
            missingModules += module
        }
    }

    System.err.println()

    if (missingModules.isNotEmpty()) {
        System.err.println(
            "⚠️ vendor module verification failed"
        )

        System.err.println(
            "⚠️ missing module(s): " +
                missingModules.joinToString(",")
        )

        System.err.println(
            "⏭️ conditional vendor module blacklist must be skipped"
        )

        throw VerificationException(
            "one or more configured vendor modules were not found"
        )
    }

    System.err.println(
        "✔️ all configured vendor modules were found in source"
    )
}

fun main(
    args: Array<String>
) {
    if (args.size < 2) {
        fail(
            """
            usage:
              VerifyVendorModules.kts <kernel-source> <modules>

            example:
              VerifyVendorModules.kts \
                /path/to/kernel_platform/common \
                oplus_networks_tuning
            """.trimIndent()
        )
    }

    val kernelSource =
        File(args[0])

    if (!kernelSource.isDirectory) {
        fail(
            "kernel source directory not found: " +
                kernelSource.path
        )
    }

    val modules =
        try {
            normalizeModules(args[1])
        } catch (error: VerificationException) {
            fail(
                error.message
                    ?: "module validation failed"
            )
        }

    System.err.println(
        "🛡️ vendor module source verification"
    )

    System.err.println(
        "📂 kernel source : ${kernelSource.path}"
    )

    System.err.println(
        "📦 modules       : " +
            if (modules.isEmpty()) {
                "none"
            } else {
                modules.joinToString(",")
            }
    )

    try {
        verifyModules(
            kernelSource,
            modules
        )
    } catch (error: VerificationException) {
        fail(
            error.message
                ?: "vendor module verification failed"
        )
    } catch (error: Exception) {
        fail(
            "vendor module verification failed: " +
                "${error.message ?: error::class.simpleName}"
        )
    }
}
