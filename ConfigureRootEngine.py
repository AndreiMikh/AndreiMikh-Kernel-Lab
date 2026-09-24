#!/usr/bin/env python3

import os
import re
import subprocess
import sys
from pathlib import Path

def run_command(command, cwd=None, check=True, stdout=None, stdin=None):
    return subprocess.run(
        command,
        cwd=cwd,
        check=check,
        stdout=stdout,
        stdin=stdin,
        text=True,
    )

def gitlatesttag(repo):
    try:
        result = subprocess.run(
            [
                "git",
                "ls-remote",
                "--tags",
                "--sort=v:refname",
                f"https://github.com/{repo}.git",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )

        tags = []
        for line in result.stdout.splitlines():
            parts = line.split()
            if len(parts) < 2:
                continue
            ref = parts[1]
            if not ref.startswith("refs/tags/"):
                continue
            tag = ref[len("refs/tags/"):]
            if tag.endswith("^{}"):
                continue
            tags.append(tag)
        return tags[-1] if tags else "v0.0.0"
    except Exception:
        return "v0.0.0"

def getcommitcount(cwd):
    try:
        result = subprocess.run(
            ["git", "rev-list", "--count", "HEAD"],
            cwd=cwd,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        value = result.stdout.strip()
        return value if value else "0"
    except Exception:
        return "0"

def setupengine(repo, branch, argument, cwd):
    print(f"🔗 Setup Repository : {repo}")
    print(f"🌿 Setup Branch     : {branch}")
    print(f"📌 Setup Argument   : {argument}")

    url = f"https://raw.githubusercontent.com/{repo}/{branch}/kernel/setup.sh"
    curl = subprocess.Popen(
        ["curl", "-fsSL", url],
        stdout=subprocess.PIPE,
    )

    try:
        bash = subprocess.run(
            ["bash", "-s", "--", argument],
            stdin=curl.stdout,
            cwd=cwd,
            check=True,
            text=True,
        )
    finally:
        if curl.stdout is not None:
            curl.stdout.close()
    curl_returncode = curl.wait()
    if curl_returncode != 0:
        raise subprocess.CalledProcessError(curl_returncode, ["curl", "-fsSL", url])
    return bash

def write_github_output(name, value):
    github_output = os.environ.get("GITHUB_OUTPUT")
    if not github_output:
        raise RuntimeError("GITHUB_OUTPUT is not set")
    with open(github_output, "a", encoding="utf-8") as output:
        output.write(f"{name}={value}\n")

def write_github_env(name, value):
    github_env = os.environ.get("GITHUB_ENV")
    if not github_env:
        raise RuntimeError("GITHUB_ENV is not set")
    with open(github_env, "a", encoding="utf-8") as env_file:
        env_file.write(f"{name}={value}\n")

def main():
    ROOTBRANCHSOURCE = os.environ.get("ROOTBRANCHSOURCE", "")
    ROOTENGINE = os.environ.get("ROOTENGINE", "")
    MANAGERBRANCH = ""
    BRANCHPATH = ""
    MANAGERARTIFACT = ""
    KSUREPO = ""

    # Resolve Root Source
    if ROOTBRANCHSOURCE == "SukiSU-Ultra-Builtin":
        MANAGERBRANCH = "main"
        BRANCHPATH = "builtin"
        MANAGERARTIFACT = "manager"
    elif ROOTBRANCHSOURCE == "KernelSU-Next-Dev-SUSFS":
        MANAGERBRANCH = "dev-susfs"
        MANAGERARTIFACT = "manager"
    elif ROOTBRANCHSOURCE == "KernelSU-Next-Dev":
        MANAGERBRANCH = "dev"
        MANAGERARTIFACT = "manager-spoofed"
    elif ROOTBRANCHSOURCE == "KernelSU-Main":
        MANAGERBRANCH = "main"
        MANAGERARTIFACT = "manager"
    elif ROOTBRANCHSOURCE == "ReSukiSU-Main":
        MANAGERBRANCH = "main"
        MANAGERARTIFACT = "Manager-release"
    elif ROOTBRANCHSOURCE == "ReSukiSU-Dev":
        MANAGERBRANCH = "dev"
        MANAGERARTIFACT = "Manager-release"
    else:
        print(f"⚠️ Unsupported Root Source: {ROOTBRANCHSOURCE}")
        sys.exit(1)

    # Resolve Root Engine Repository
    if ROOTENGINE == "SukiSU-Ultra":
        KSUREPO = "SukiSU-Ultra/SukiSU-Ultra"
    elif ROOTENGINE == "KernelSU-Next":
        KSUREPO = "KernelSU-Next/KernelSU-Next"
    elif ROOTENGINE == "ReSukiSU":
        KSUREPO = "ReSukiSU/ReSukiSU"
    elif ROOTENGINE == "KernelSU":
        KSUREPO = "tiann/KernelSU"
    else:
        print(f"⚠️ Unsupported Root Engine: {ROOTENGINE}")
        sys.exit(1)

    # Validate Resolution
    if not MANAGERBRANCH:
        print("⚠️ Failed to Resolve Manager Branch")
        sys.exit(1)

    if not KSUREPO:
        print("⚠️ Failed to Resolve Root Engine Repository")
        sys.exit(1)

    write_github_output("managerbranch", MANAGERBRANCH)
    write_github_output("branchpath", BRANCHPATH)
    write_github_output("managerartifact", MANAGERARTIFACT)
    write_github_output("ksurepo", KSUREPO)

    print("------------------------------")
    print("✔️ Root Engine Source Resolved")
    print(f"📦 Engine     : {ROOTENGINE}")
    print(f"📂 Repository : {KSUREPO}")
    print(f"🌿 Branch     : {MANAGERBRANCH}")
    print(f"📁 Setup Repo : {BRANCHPATH}")
    print(f"📦 Artifact   : {MANAGERARTIFACT}")
    print("------------------------------")

    KERNEL_PLATFORM = (
        Path(os.environ["GITHUB_WORKSPACE"])
        / "kernel_workspace"
        / "kernel_platform"
    )

    os.chdir(KERNEL_PLATFORM)
    SUSFS = os.environ.get("SUSFSREPOSITORY", "")
    KCDIR = KERNEL_PLATFORM / "common"
    DEFCONFIG = KCDIR / "arch" / "arm64" / "configs" / "gki_defconfig"

    # Helpers

    # SukiSU-Ultra
    if ROOTENGINE == "SukiSU-Ultra":
        print("🚀 Setting Up SukiSU-Ultra...")
        # SukiSU-Ultra Builtin Setup
        setupengine(
            KSUREPO,
            MANAGERBRANCH,
            BRANCHPATH,
            KERNEL_PLATFORM,
        )
        kernelsu_dir = KERNEL_PLATFORM / "KernelSU"
        if not kernelsu_dir.is_dir():
            print("⚠️ SukiSU-Ultra Directory Not Found")
            sys.exit(1)
        os.chdir(kernelsu_dir)

        # Get Current Git Commit Hash
        result = subprocess.run(
            ["git", "rev-parse", "--short=8", "HEAD"],
            stdout=subprocess.PIPE,
            text=True,
            check=True,
        )
        GITCOMMITHASH = result.stdout.strip()
        print(f"🔖 Current Commit Hash : {GITCOMMITHASH}")

        # Get Main Branch Commit Count
        result = subprocess.run(
            ["git", "rev-list", "--count", "main"],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )
        COMMITCOUNT = result.stdout.strip() or "0"
        if re.fullmatch(r"[0-9]+", COMMITCOUNT):
            KSUVERSION = int(COMMITCOUNT) + 37185
        else:
            KSUVERSION = 114514

        print(f"📦 SukiSU-Ultra Version : {KSUVERSION}")
        print(f"🔖 SukiSU-Ultra Commit  : {GITCOMMITHASH}")

        # Store Version Information
        write_github_env("KSUVERSION", KSUVERSION)
        write_github_env("KSUVER", KSUVERSION)
        write_github_env("GITCOMMITHASH", GITCOMMITHASH)

        # Verify Native SukiSU-Ultra Version Logic
        print("🔍 Verifying SukiSU-Ultra Version Definitions...")
        makefile = Path("kernel") / "Makefile"
        if makefile.is_file():
            pattern = re.compile(
                r"^VERSION_BASE|^VERSION_OFFSET|^KSU_VERSION_FULL|^VERSION_TAG"
            )

            for line_number, line in enumerate(
                makefile.read_text(encoding="utf-8", errors="replace").splitlines(),
                start=1,
            ):
                if pattern.search(line):
                    print(f"{line_number}:{line}")
        print("🎉 SukiSU-Ultra Setup Complete")

    # ReSukiSU
    elif ROOTENGINE == "ReSukiSU":
        print("🚀 Setting Up ReSukiSU...")
        setupengine(
            KSUREPO,
            MANAGERBRANCH,
            MANAGERBRANCH,
            KERNEL_PLATFORM,
        )

        kernelsu_dir = KERNEL_PLATFORM / "KernelSU"
        if not kernelsu_dir.is_dir():
            print("⚠️ ReSukiSU Directory was Not Created")
            sys.exit(1)
        os.chdir(kernelsu_dir)
        CURRENTBRANCH = ""
        try:
            result = subprocess.run(
                ["git", "branch", "--show-current"],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )
            CURRENTBRANCH = result.stdout.strip()
        except Exception:
            CURRENTBRANCH = ""
        CURRENTBRANCH = CURRENTBRANCH or "HEAD"
        COMMITCOUNT = getcommitcount(Path.cwd())
        if re.fullmatch(r"[0-9]+", COMMITCOUNT):
            KSUVERSION = int(COMMITCOUNT) + 30700
        else:
            KSUVERSION = 30700
        write_github_env("KSUVERSION", KSUVERSION)

        # Force Simple Tag-Based Full-Name Format
        if DEFCONFIG.is_file():
            lines = DEFCONFIG.read_text(
                encoding="utf-8",
                errors="replace",
            ).splitlines()
            lines = [
                line
                for line in lines
                if not line.startswith("CONFIG_KSU_FULL_NAME_FORMAT=")
            ]

            lines.append('CONFIG_KSU_FULL_NAME_FORMAT="%%TAG_NAME%%"')
            DEFCONFIG.write_text(
                "\n".join(lines) + "\n",
                encoding="utf-8",
            )
        print(f"🌿 Branch           : {CURRENTBRANCH}")
        print(f"🔢 KSU Version      : {KSUVERSION}")
        print("🎉 ReSukiSU Setup Complete")

    # KernelSU-Next
    elif ROOTENGINE == "KernelSU-Next":
        print("🚀 Setting Up KernelSU-Next...")
        setupengine(
            KSUREPO,
            MANAGERBRANCH,
            MANAGERBRANCH,
            KERNEL_PLATFORM,
        )

        kernelsu_dir = KERNEL_PLATFORM / "KernelSU-Next"
        if not kernelsu_dir.is_dir():
            print("⚠️ KernelSU-Next Directory was Not Created")
            sys.exit(1)
        os.chdir(kernelsu_dir)
        COMMITCOUNT = getcommitcount(Path.cwd())
        if re.fullmatch(r"[0-9]+", COMMITCOUNT):
            KSUVERSION = int(COMMITCOUNT) + 30000
        else:
            KSUVERSION = 30000
        write_github_env("KSUVERSION", KSUVERSION)

        # Version Fallback
        kbuild = Path("kernel") / "Kbuild"
        if kbuild.is_file():
            lines = kbuild.read_text(
                encoding="utf-8",
                errors="replace",
            ).splitlines()
            changed = False
            for index, line in enumerate(lines):
                if line.startswith("KSU_VERSION_FALLBACK := "):
                    lines[index] = f"KSU_VERSION_FALLBACK := {KSUVERSION}"
                    changed = True

            # Tag fallback
            KSU_GIT_TAG = gitlatesttag(KSUREPO)
            for index, line in enumerate(lines):
                if line.startswith("KSU_VERSION_TAG_FALLBACK := "):
                    lines[index] = (
                        f"KSU_VERSION_TAG_FALLBACK := {KSU_GIT_TAG}"
                    )
                    changed = True
            if changed:
                kbuild.write_text(
                    "\n".join(lines) + "\n",
                    encoding="utf-8",
                )
        else:
            KSU_GIT_TAG = gitlatesttag(KSUREPO)

        # KernelSU-Next SELinux Fix
        STATICSELINUX = Path("kernel") / "feature" / "selinux_hide.c"
        if STATICSELINUX.is_file():
            selinux_text = STATICSELINUX.read_text(
                encoding="utf-8",
                errors="replace",
            )

            if re.search(
                r"^static (int|void) security_"
                r"(context_to_sid|sid_to_context|compute_av_user)_with_policy\(",
                selinux_text,
                flags=re.MULTILINE,
            ):
                selinux_text = re.sub(
                    r"^static int security_context_to_sid_with_policy\(",
                    "int security_context_to_sid_with_policy(",
                    selinux_text,
                    flags=re.MULTILINE,
                )
                selinux_text = re.sub(
                    r"^static int security_sid_to_context_with_policy\(",
                    "int security_sid_to_context_with_policy(",
                    selinux_text,
                    flags=re.MULTILINE,
                )
                selinux_text = re.sub(
                    r"^static void security_compute_av_user_with_policy\(",
                    "void security_compute_av_user_with_policy(",
                    selinux_text,
                    flags=re.MULTILINE,
                )
                STATICSELINUX.write_text(
                    selinux_text,
                    encoding="utf-8",
                )
                print("✔️ KernelSU-Next SELinux Fix Applied")

        # SUSFS Inline Hook Mode
        dispatch = Path("kernel") / "supercall" / "dispatch.c"
        if SUSFS != "-1" and dispatch.is_file():
            dispatch_text = dispatch.read_text(
                encoding="utf-8",
                errors="replace",
            )
            dispatch_text = re.sub(
                r"#ifdef CONFIG_HAVE_SYSCALL_TRACEPOINTS.*?#endif",
                'strscpy(cmd.mode, "Inline", sizeof(cmd.mode));',
                dispatch_text,
                flags=re.DOTALL,
            )
            dispatch.write_text(
                dispatch_text,
                encoding="utf-8",
            )
            print("✔️ SUSFS Hook Mode Set to Inline")
        print(f"🌿 Branch           : {MANAGERBRANCH}")
        print(f"🏷️ Latest Tag       : {KSU_GIT_TAG}")
        print(f"🔢 KSU Version      : {KSUVERSION}")
        print("🎉 KernelSU-Next Setup Complete")

    # KernelSU
    elif ROOTENGINE == "KernelSU":
        print("🚀 Setting Up KernelSU...")
        setupengine(
            KSUREPO,
            MANAGERBRANCH,
            MANAGERBRANCH,
            KERNEL_PLATFORM,
        )

        kernelsu_dir = KERNEL_PLATFORM / "KernelSU"
        if not kernelsu_dir.is_dir():
            print("⚠️ KernelSU Directory was Not Created")
            sys.exit(1)
        os.chdir(kernelsu_dir)
        COMMITCOUNT = getcommitcount(Path.cwd())
        if re.fullmatch(r"[0-9]+", COMMITCOUNT):
            KSUVERSION = int(COMMITCOUNT) + 30000
        else:
            KSUVERSION = 30000
        write_github_env("KSUVERSION", KSUVERSION)

        # KernelSU Version Fallback
        kbuild = Path("kernel") / "Kbuild"
        if kbuild.is_file():
            lines = kbuild.read_text(
                encoding="utf-8",
                errors="replace",
            ).splitlines()
            changed = False
            for index, line in enumerate(lines):
                if line.startswith("KSU_VERSION_FALLBACK := "):
                    lines[index] = f"KSU_VERSION_FALLBACK := {KSUVERSION}"
                    changed = True
            # DKSU Version
            for index, line in enumerate(lines):
                if re.match(r"^DKSU_VERSION\s*=", line):
                    lines[index] = f"DKSU_VERSION={KSUVERSION}"
                    changed = True
            if changed:
                kbuild.write_text(
                    "\n".join(lines) + "\n",
                    encoding="utf-8",
                )

        print(f"🌿 Branch           : {MANAGERBRANCH}")
        print(f"🔢 KSU Version      : {KSUVERSION}")
        print("🎉 KernelSU Setup Complete")
    else:
        print("⚠️ No Supported KSU Root Engine Selected")
        sys.exit(1)

    # Export Root Engine Version Output
    write_github_output("ksuversion", KSUVERSION)

    print("")
    print("------------------------------")
    print("🎉 Root Engine Configuration Complete")
    print("------------------------------")
    print(f"📦 Engine     : {ROOTENGINE}")
    print(f"📂 Repository : {KSUREPO}")
    print(f"🌿 Branch     : {MANAGERBRANCH}")
    print(f"📁 Setup Repo : {BRANCHPATH}")

if __name__ == "__main__":
    main()
