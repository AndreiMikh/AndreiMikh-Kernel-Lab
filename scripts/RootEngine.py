#!/usr/bin/env python3

import os
import re
import subprocess
import sys
from pathlib import Path


# ===== Command Helpers =====

def runcommand(
    command,
    cwd=None,
    check=True,
    stdout=None,
    stdin=None,
):
    return subprocess.run(
        command,
        cwd=cwd,
        check=check,
        stdout=stdout,
        stdin=stdin,
        text=True,
    )


# ===== Git Helpers =====

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
            [
                "git",
                "rev-list",
                "--count",
                "HEAD",
            ],
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


# ===== Root Engine Setup =====

def setupengine(
    repo,
    branch,
    argument,
    cwd,
):
    print(
        f"🔗 Setup Repository : {repo}"
    )

    print(
        f"🌿 Setup Branch     : {branch}"
    )

    print(
        f"📌 Setup Argument   : {argument}"
    )

    url = (
        "https://raw.githubusercontent.com/"
        f"{repo}/{branch}/kernel/setup.sh"
    )

    curl = subprocess.Popen(
        [
            "curl",
            "-fsSL",
            url,
        ],
        stdout=subprocess.PIPE,
    )

    try:
        bash = subprocess.run(
            [
                "bash",
                "-s",
                "--",
                argument,
            ],
            stdin=curl.stdout,
            cwd=cwd,
            check=True,
            text=True,
        )

    finally:
        if curl.stdout is not None:
            curl.stdout.close()

    curlreturncode = curl.wait()

    if curlreturncode != 0:
        raise subprocess.CalledProcessError(
            curlreturncode,
            [
                "curl",
                "-fsSL",
                url,
            ],
        )

    return bash


# ===== GitHub Actions Output Helpers =====

def setupoutput(name, value):
    # GITHUB_OUTPUT is provided by GitHub Actions.
    # The environment variable name must remain unchanged.
    gitoutput = os.environ.get(
        "GITHUB_OUTPUT"
    )

    if not gitoutput:
        raise RuntimeError(
            "GITHUB_OUTPUT is not set"
        )

    with open(
        gitoutput,
        "a",
        encoding="utf-8",
    ) as output:
        output.write(
            f"{name}={value}\n"
        )


def setupenv(name, value):
    # GITHUB_ENV is provided by GitHub Actions.
    # The environment variable name must remain unchanged.
    gitenv = os.environ.get(
        "GITHUB_ENV"
    )

    if not gitenv:
        raise RuntimeError(
            "GITHUB_ENV is not set"
        )

    with open(
        gitenv,
        "a",
        encoding="utf-8",
    ) as envfile:
        envfile.write(
            f"{name}={value}\n"
        )


# ===== File Helpers =====

def isfile(path):
    return path.is_file()


def isdir(path):
    return path.is_dir()


def readtxt(
    path,
    encoding="utf-8",
    errors="replace",
):
    return path.read_text(
        encoding=encoding,
        errors=errors,
    )


def writetxt(
    path,
    text,
    encoding="utf-8",
):
    path.write_text(
        text,
        encoding=encoding,
    )


# ===== Main =====

def main():

    # ===== Read GitHub Actions Inputs =====

    ROOTBRANCHSOURCE = os.environ.get(
        "ROOTBRANCHSOURCE",
        "",
    )

    ROOTENGINE = os.environ.get(
        "ROOTENGINE",
        "",
    )

    # ===== Initialize Root Source Variables =====

    MANAGERBRANCH = ""
    BRANCHPATH = ""
    MANAGERARTIFACT = ""
    KSUREPO = ""

    # ===== Resolve Root Source =====

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

        print(
            f"⚠️ Unsupported Root Source: "
            f"{ROOTBRANCHSOURCE}"
        )

        sys.exit(1)

    # ===== Resolve Root Engine Repository =====

    if ROOTENGINE == "SukiSU-Ultra":

        KSUREPO = (
            "SukiSU-Ultra/"
            "SukiSU-Ultra"
        )

    elif ROOTENGINE == "KernelSU-Next":

        KSUREPO = (
            "KernelSU-Next/"
            "KernelSU-Next"
        )

    elif ROOTENGINE == "ReSukiSU":

        KSUREPO = (
            "ReSukiSU/"
            "ReSukiSU"
        )

    elif ROOTENGINE == "KernelSU":

        KSUREPO = (
            "tiann/"
            "KernelSU"
        )

    else:

        print(
            f"⚠️ Unsupported Root Engine: "
            f"{ROOTENGINE}"
        )

        sys.exit(1)

    # ===== Validate Root Resolution =====

    if not MANAGERBRANCH:

        print(
            "⚠️ Failed to Resolve "
            "Manager Branch"
        )

        sys.exit(1)

    if not KSUREPO:

        print(
            "⚠️ Failed to Resolve "
            "Root Engine Repository"
        )

        sys.exit(1)

    # ===== Export Root Source Outputs =====

    setupoutput(
        "managerbranch",
        MANAGERBRANCH,
    )

    setupoutput(
        "branchpath",
        BRANCHPATH,
    )

    setupoutput(
        "managerartifact",
        MANAGERARTIFACT,
    )

    setupoutput(
        "ksurepo",
        KSUREPO,
    )

    # ===== Display Root Source Resolution =====

    print(
        "------------------------------"
    )

    print(
        "✔️ Root Engine Source Resolved"
    )

    print(
        f"📦 Engine     : {ROOTENGINE}"
    )

    print(
        f"📂 Repository : {KSUREPO}"
    )

    print(
        f"🌿 Branch     : {MANAGERBRANCH}"
    )

    print(
        f"📁 Setup Repo : {BRANCHPATH}"
    )

    print(
        f"📦 Artifact   : {MANAGERARTIFACT}"
    )

    print(
        "------------------------------"
    )

    # ===== Resolve Kernel Platform =====

    KERNELPLATFORM = (
        Path(
            os.environ["GITHUB_WORKSPACE"]
        )
        / "kernel_workspace"
        / "kernel_platform"
    )

    os.chdir(KERNELPLATFORM)

    # ===== Read SUSFS Configuration =====

    SUSFS = os.environ.get(
        "SUSFSREPOSITORY",
        "",
    )

    # ===== Resolve Kernel Configuration Paths =====

    KCDIR = (
        KERNELPLATFORM
        / "common"
    )

    DEFCONFIG = (
        KCDIR
        / "arch"
        / "arm64"
        / "configs"
        / "gki_defconfig"
    )

    # ===== SukiSU-Ultra =====

    if ROOTENGINE == "SukiSU-Ultra":

        print(
            "🚀 Setting Up SukiSU-Ultra..."
        )

        # ===== SukiSU-Ultra Builtin Setup =====

        setupengine(
            KSUREPO,
            MANAGERBRANCH,
            BRANCHPATH,
            KERNELPLATFORM,
        )

        # ===== Resolve KernelSU Directory =====

        ksudir = (
            KERNELPLATFORM
            / "KernelSU"
        )

        if not isdir(ksudir):

            print(
                "⚠️ SukiSU-Ultra "
                "Directory Not Found"
            )

            sys.exit(1)

        os.chdir(ksudir)

        # ===== Get Current Git Commit Hash =====

        result = subprocess.run(
            [
                "git",
                "rev-parse",
                "--short=8",
                "HEAD",
            ],
            stdout=subprocess.PIPE,
            text=True,
            check=True,
        )

        GITCOMMITHASH = (
            result.stdout.strip()
        )

        print(
            f"🔖 Current Commit Hash : "
            f"{GITCOMMITHASH}"
        )

        # ===== Get Main Branch Commit Count =====

        result = subprocess.run(
            [
                "git",
                "rev-list",
                "--count",
                "main",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            check=False,
        )

        COMMITCOUNT = (
            result.stdout.strip()
            or "0"
        )

        # ===== Calculate SukiSU-Ultra Version =====

        if re.fullmatch(
            r"[0-9]+",
            COMMITCOUNT,
        ):

            KSUVERSION = (
                int(COMMITCOUNT)
                + 37185
            )

        else:

            KSUVERSION = 114514

        print(
            f"📦 SukiSU-Ultra Version : "
            f"{KSUVERSION}"
        )

        print(
            f"🔖 SukiSU-Ultra Commit  : "
            f"{GITCOMMITHASH}"
        )

        # ===== Store Version Information =====

        setupenv(
            "KSUVERSION",
            KSUVERSION,
        )

        setupenv(
            "KSUVER",
            KSUVERSION,
        )

        setupenv(
            "GITCOMMITHASH",
            GITCOMMITHASH,
        )

        # ===== Verify Native SukiSU-Ultra Version Logic =====

        print(
            "🔍 Verifying SukiSU-Ultra "
            "Version Definitions..."
        )

        makefile = (
            Path("kernel")
            / "Makefile"
        )

        if isfile(makefile):

            pattern = re.compile(
                r"^VERSION_BASE|"
                r"^VERSION_OFFSET|"
                r"^KSU_VERSION_FULL|"
                r"^VERSION_TAG"
            )

            for (
                linenumber,
                line,
            ) in enumerate(
                readtxt(
                    makefile,
                    encoding="utf-8",
                    errors="replace",
                ).splitlines(),
                start=1,
            ):

                if pattern.search(line):

                    print(
                        f"{linenumber}:{line}"
                    )

        print(
            "🎉 SukiSU-Ultra "
            "Setup Complete"
        )

    # ===== ReSukiSU =====

    elif ROOTENGINE == "ReSukiSU":

        print(
            "🚀 Setting Up ReSukiSU..."
        )

        setupengine(
            KSUREPO,
            MANAGERBRANCH,
            MANAGERBRANCH,
            KERNELPLATFORM,
        )

        # ===== Resolve KernelSU Directory =====

        ksudir = (
            KERNELPLATFORM
            / "KernelSU"
        )

        if not isdir(ksudir):

            print(
                "⚠️ ReSukiSU Directory "
                "was Not Created"
            )

            sys.exit(1)

        os.chdir(ksudir)

        # ===== Resolve Current Branch =====

        CURRENTBRANCH = ""

        try:

            result = subprocess.run(
                [
                    "git",
                    "branch",
                    "--show-current",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL,
                text=True,
                check=False,
            )

            CURRENTBRANCH = (
                result.stdout.strip()
            )

        except Exception:

            CURRENTBRANCH = ""

        CURRENTBRANCH = (
            CURRENTBRANCH
            or "HEAD"
        )

        # ===== Calculate ReSukiSU Version =====

        COMMITCOUNT = getcommitcount(
            Path.cwd()
        )

        if re.fullmatch(
            r"[0-9]+",
            COMMITCOUNT,
        ):

            KSUVERSION = (
                int(COMMITCOUNT)
                + 30700
            )

        else:

            KSUVERSION = 30700

        setupenv(
            "KSUVERSION",
            KSUVERSION,
        )

        # ===== Force Simple Tag-Based Full-Name Format =====

        if isfile(DEFCONFIG):

            lines = readtxt(
                DEFCONFIG,
                encoding="utf-8",
                errors="replace",
            ).splitlines()

            lines = [
                line
                for line in lines
                if not line.startswith(
                    "CONFIG_KSU_FULL_NAME_FORMAT="
                )
            ]

            lines.append(
                'CONFIG_KSU_FULL_NAME_FORMAT="%%TAG_NAME%%"'
            )

            writetxt(
                DEFCONFIG,
                "\n".join(lines)
                + "\n",
                encoding="utf-8",
            )

        print(
            f"🌿 Branch           : "
            f"{CURRENTBRANCH}"
        )

        print(
            f"🔢 KSU Version      : "
            f"{KSUVERSION}"
        )

        print(
            "🎉 ReSukiSU Setup Complete"
        )

    # ===== KernelSU-Next =====

    elif ROOTENGINE == "KernelSU-Next":

        print(
            "🚀 Setting Up KernelSU-Next..."
        )

        setupengine(
            KSUREPO,
            MANAGERBRANCH,
            MANAGERBRANCH,
            KERNELPLATFORM,
        )

        # ===== Resolve KernelSU-Next Directory =====

        ksudir = (
            KERNELPLATFORM
            / "KernelSU-Next"
        )

        if not isdir(ksudir):

            print(
                "⚠️ KernelSU-Next Directory "
                "was Not Created"
            )

            sys.exit(1)

        os.chdir(ksudir)

        # ===== Calculate KernelSU-Next Version =====

        COMMITCOUNT = getcommitcount(
            Path.cwd()
        )

        if re.fullmatch(
            r"[0-9]+",
            COMMITCOUNT,
        ):

            KSUVERSION = (
                int(COMMITCOUNT)
                + 30000
            )

        else:

            KSUVERSION = 30000

        setupenv(
            "KSUVERSION",
            KSUVERSION,
        )

        # ===== Version Fallback =====

        kbuild = (
            Path("kernel")
            / "Kbuild"
        )

        if isfile(kbuild):

            lines = readtxt(
                kbuild,
                encoding="utf-8",
                errors="replace",
            ).splitlines()

            changed = False

            for index, line in enumerate(
                lines
            ):

                if line.startswith(
                    "KSU_VERSION_FALLBACK := "
                ):

                    lines[index] = (
                        "KSU_VERSION_FALLBACK := "
                        f"{KSUVERSION}"
                    )

                    changed = True

            # ===== Tag Fallback =====

            KSUTAG = gitlatesttag(
                KSUREPO
            )

            for index, line in enumerate(
                lines
            ):

                if line.startswith(
                    "KSU_VERSION_TAG_FALLBACK := "
                ):

                    lines[index] = (
                        "KSU_VERSION_TAG_FALLBACK := "
                        f"{KSUTAG}"
                    )

                    changed = True

            if changed:

                writetxt(
                    kbuild,
                    "\n".join(lines)
                    + "\n",
                    encoding="utf-8",
                )

        else:

            KSUTAG = gitlatesttag(
                KSUREPO
            )

        # ===== KernelSU-Next SELinux Fix =====

        STATICSELINUX = (
            Path("kernel")
            / "feature"
            / "selinux_hide.c"
        )

        if isfile(STATICSELINUX):

            selinuxtxt = readtxt(
                STATICSELINUX,
                encoding="utf-8",
                errors="replace",
            )

            if re.search(
                r"^static (int|void) security_"
                r"(context_to_sid|sid_to_context|"
                r"compute_av_user)_with_policy\(",
                selinuxtxt,
                flags=re.MULTILINE,
            ):

                selinuxtxt = re.sub(
                    r"^static int "
                    r"security_context_to_sid_with_policy\(",
                    "int "
                    "security_context_to_sid_with_policy(",
                    selinuxtxt,
                    flags=re.MULTILINE,
                )

                selinuxtxt = re.sub(
                    r"^static int "
                    r"security_sid_to_context_with_policy\(",
                    "int "
                    "security_sid_to_context_with_policy(",
                    selinuxtxt,
                    flags=re.MULTILINE,
                )

                selinuxtxt = re.sub(
                    r"^static void "
                    r"security_compute_av_user_with_policy\(",
                    "void "
                    "security_compute_av_user_with_policy(",
                    selinuxtxt,
                    flags=re.MULTILINE,
                )

                writetxt(
                    STATICSELINUX,
                    selinuxtxt,
                    encoding="utf-8",
                )

                print(
                    "✔️ KernelSU-Next "
                    "SELinux Fix Applied"
                )

        # ===== SUSFS Inline Hook Mode =====

        dispatch = (
            Path("kernel")
            / "supercall"
            / "dispatch.c"
        )

        if (
            SUSFS != "-1"
            and isfile(dispatch)
        ):

            dispatchtxt = readtxt(
                dispatch,
                encoding="utf-8",
                errors="replace",
            )

            dispatchtxt = re.sub(
                r"#ifdef "
                r"CONFIG_HAVE_SYSCALL_TRACEPOINTS"
                r".*?#endif",
                'strscpy(cmd.mode, "Inline", '
                'sizeof(cmd.mode));',
                dispatchtxt,
                flags=re.DOTALL,
            )

            writetxt(
                dispatch,
                dispatchtxt,
                encoding="utf-8",
            )

            print(
                "✔️ SUSFS Hook Mode "
                "Set to Inline"
            )

        # ===== Display KernelSU-Next Information =====

        print(
            f"🌿 Branch           : "
            f"{MANAGERBRANCH}"
        )

        print(
            f"🏷️ Latest Tag       : "
            f"{KSUTAG}"
        )

        print(
            f"🔢 KSU Version      : "
            f"{KSUVERSION}"
        )

        print(
            "🎉 KernelSU-Next "
            "Setup Complete"
        )

    # ===== KernelSU =====

    elif ROOTENGINE == "KernelSU":

        print(
            "🚀 Setting Up KernelSU..."
        )

        setupengine(
            KSUREPO,
            MANAGERBRANCH,
            MANAGERBRANCH,
            KERNELPLATFORM,
        )

        # ===== Resolve KernelSU Directory =====

        ksudir = (
            KERNELPLATFORM
            / "KernelSU"
        )

        if not isdir(ksudir):

            print(
                "⚠️ KernelSU Directory "
                "was Not Created"
            )

            sys.exit(1)

        os.chdir(ksudir)

        # ===== Calculate KernelSU Version =====

        COMMITCOUNT = getcommitcount(
            Path.cwd()
        )

        if re.fullmatch(
            r"[0-9]+",
            COMMITCOUNT,
        ):

            KSUVERSION = (
                int(COMMITCOUNT)
                + 30000
            )

        else:

            KSUVERSION = 30000

        setupenv(
            "KSUVERSION",
            KSUVERSION,
        )

        # ===== KernelSU Version Fallback =====

        kbuild = (
            Path("kernel")
            / "Kbuild"
        )

        if isfile(kbuild):

            lines = readtxt(
                kbuild,
                encoding="utf-8",
                errors="replace",
            ).splitlines()

            changed = False

            for index, line in enumerate(
                lines
            ):

                if line.startswith(
                    "KSU_VERSION_FALLBACK := "
                ):

                    lines[index] = (
                        "KSU_VERSION_FALLBACK := "
                        f"{KSUVERSION}"
                    )

                    changed = True

            # ===== DKSU Version =====

            for index, line in enumerate(
                lines
            ):

                if re.match(
                    r"^DKSU_VERSION\s*=",
                    line,
                ):

                    lines[index] = (
                        f"DKSU_VERSION="
                        f"{KSUVERSION}"
                    )

                    changed = True

            if changed:

                writetxt(
                    kbuild,
                    "\n".join(lines)
                    + "\n",
                    encoding="utf-8",
                )

        # ===== Display KernelSU Information =====

        print(
            f"🌿 Branch           : "
            f"{MANAGERBRANCH}"
        )

        print(
            f"🔢 KSU Version      : "
            f"{KSUVERSION}"
        )

        print(
            "🎉 KernelSU Setup Complete"
        )

    # ===== Unsupported Root Engine =====

    else:

        print(
            "⚠️ No Supported KSU "
            "Root Engine Selected"
        )

        sys.exit(1)

    # ===== Export Root Engine Version Output =====

    setupoutput(
        "ksuversion",
        KSUVERSION,
    )

    # ===== Final Summary =====

    print("")

    print(
        "------------------------------"
    )

    print(
        "🎉 Root Engine "
        "Configuration Complete"
    )

    print(
        "------------------------------"
    )

    print(
        f"📦 Engine     : {ROOTENGINE}"
    )

    print(
        f"📂 Repository : {KSUREPO}"
    )

    print(
        f"🌿 Branch     : {MANAGERBRANCH}"
    )

    print(
        f"📁 Setup Repo : {BRANCHPATH}"
    )


# ===== Python Entry Point =====

if __name__ == "__main__":
    main()
