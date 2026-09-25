#!/usr/bin/env python3

import os
import re
import shutil
import subprocess
import sys
from pathlib import Path
from urllib.request import Request, urlopen
from urllib.error import HTTPError, URLError


def runcommand(
    command,
    cwd=None,
    check=True,
    stdout=None,
    stderr=None,
    stdin=None,
):
    return subprocess.run(
        command,
        cwd=cwd,
        check=check,
        stdout=stdout,
        stderr=stderr,
        stdin=stdin,
        text=True,
    )


def getenv(name, default=""):
    return os.environ.get(name, default)


def isfile(path):
    return Path(path).is_file()


def isdir(path):
    return Path(path).is_dir()


def readtxt(path, encoding="utf-8", errors="replace"):
    return Path(path).read_text(
        encoding=encoding,
        errors=errors,
    )


def writetxt(path, text, encoding="utf-8"):
    Path(path).write_text(
        text,
        encoding=encoding,
    )


def setupenv(name, value):
    gitenv = getenv("GITHUB_ENV")

    if not gitenv:
        raise RuntimeError(
            "Environment is Not Set"
        )

    with open(
        gitenv,
        "a",
        encoding="utf-8",
    ) as envfile:
        envfile.write(
            f"{name}={value}\n"
        )


def setupoutput(name, value):
    gitoutput = getenv("GITHUB_OUTPUT")

    if not gitoutput:
        raise RuntimeError(
            "Output is Not Set"
        )

    with open(
        gitoutput,
        "a",
        encoding="utf-8",
    ) as output:
        output.write(
            f"{name}={value}\n"
        )


def resolvekerneldirectory(workspace):
    kernelworkspace = (
        workspace / "kernel_workspace"
    )

    kernelplatform = (
        kernelworkspace
        / "kernel_platform"
    )

    if isdir(
        kernelplatform / "common"
    ):
        kerneldir = (
            kernelplatform / "common"
        )

    elif isdir(
        kernelworkspace / "common"
    ):
        kerneldir = (
            kernelworkspace / "common"
        )

    else:
        print(
            "⚠️ ERROR: Kernel Common "
            "Directory Not Found!"
        )
        sys.exit(1)

    return kerneldir.resolve()


def resolvesusfsrepository(
    susfsvariant,
):
    if susfsvariant == "OGKI":
        return (
            "https://github.com/"
            "cctv18/susfs4oki.git"
        )

    return (
        "https://gitlab.com/"
        "simonpunk/susfs4ksu.git"
    )


def resolvesusfsbranch(
    androidversion,
    kernelversion,
    susfsvariant,
    susfsbranchdev,
):
    if susfsvariant == "OGKI":
        branch = (
            f"oki-{androidversion}-"
            f"{kernelversion}"
        )
    else:
        branch = (
            f"gki-{androidversion}-"
            f"{kernelversion}"
        )

    if susfsbranchdev == "true":
        branch = f"{branch}-dev"

    return branch


def clonesusfs(
    repository,
    branch,
    destination,
):
    print(
        "📥 Cloning SUSFS..."
    )

    command = [
        "git",
        "clone",
        "--depth=1",
        repository,
        str(destination),
        "-b",
        branch,
    ]

    runcommand(
        command,
        check=True,
    )


def checkoutsusfsrevised(
    susfsdir,
    susfsrepository,
    branch,
):
    if (
        not susfsrepository
        or susfsrepository == "-1"
    ):
        return

    print(
        f"🔎 SUSFS Revision: "
        f"{susfsrepository}"
    )

    os.chdir(susfsdir)

    # Numeric Rollback Mode
    if re.fullmatch(
        r"[0-9]+",
        susfsrepository,
    ):
        print(
            "📦 Fetching Additional "
            "Git History..."
        )

        runcommand(
            [
                "git",
                "fetch",
                "--unshallow",
            ],
            check=False,
        )

        runcommand(
            [
                "git",
                "fetch",
                "--depth=1000",
                "origin",
                branch,
            ],
            check=False,
        )

        result = runcommand(
            [
                "git",
                "checkout",
                f"HEAD~{susfsrepository}",
            ],
            check=False,
        )

        if result.returncode != 0:
            print(
                "⚠️ Failed Checkout "
                f"HEAD~{susfsrepository}"
            )
            sys.exit(1)

    else:
        # SUSFS Commit Hash / Tag / Branch Mode
        if re.fullmatch(
            r"[0-9a-fA-F]{7,40}",
            susfsrepository,
        ):
            print(
                "📦 Expanding Shallow "
                "Clone History..."
            )

            result = runcommand(
                [
                    "git",
                    "fetch",
                    "--unshallow",
                    "origin",
                ],
                check=False,
            )

            if result.returncode != 0:
                runcommand(
                    [
                        "git",
                        "fetch",
                        "--deepen=200",
                        "origin",
                        branch,
                    ],
                    check=False,
                )

        result = runcommand(
            [
                "git",
                "checkout",
                susfsrepository,
            ],
            check=False,
        )

        if result.returncode != 0:
            print(
                "⚠️ Invalid SUSFS Revision"
            )
            sys.exit(1)


def detectsusfsversion(susfsdir):
    susfsheader = (
        susfsdir
        / "kernel_patches"
        / "include"
        / "linux"
        / "susfs.h"
    )

    if not isfile(susfsheader):
        return "Unknown"

    susfstxt = readtxt(
        susfsheader,
        encoding="utf-8",
        errors="replace",
    )

    match = re.search(
        r'SUSFS_VERSION\s*[^"]*"([^"]+)"',
        susfstxt,
    )

    if match:
        return match.group(1)

    return "Unknown"


def findsusfspatch(
    susfsdir,
    androidversion,
    kernelversion,
):
    patchdir = (
        susfsdir
        / "kernel_patches"
    )

    pattern = (
        f"50_add_susfs_in_gki-"
        f"{androidversion}-"
        f"{kernelversion}*.patch"
    )

    patchlist = sorted(
        patchdir.glob(pattern)
    )

    if not patchlist:
        print(
            "⚠️ No SUSFS Patch Found"
        )

        if isdir(patchdir):
            for item in sorted(
                patchdir.iterdir()
            ):
                print(
                    f"   {item.name}"
                )

        sys.exit(1)

    return patchlist[-1]


def copysusfspatches(
    susfsdir,
    kerneldir,
    susfsrepository,
    susfspatch,
):
    if susfsrepository == "-1":
        return

    print(
        "📥 Copying SUSFS Patches..."
    )

    if not isfile(
        kerneldir / susfspatch.name
    ):
        try:
            shutil.copy2(
                susfspatch,
                kerneldir,
            )
        except Exception:
            print(
                "⚠️ Failed to Copy "
                "SUSFS Patch"
            )

    fsdir = (
        susfsdir
        / "kernel_patches"
        / "fs"
    )

    includedir = (
        susfsdir
        / "kernel_patches"
        / "include"
        / "linux"
    )

    targetfs = (
        kerneldir / "fs"
    )

    targetinclude = (
        kerneldir
        / "include"
        / "linux"
    )

    if isdir(fsdir):
        try:
            shutil.copytree(
                fsdir,
                targetfs,
                dirs_exist_ok=True,
            )
        except Exception:
            print(
                "⚠️ Failed to Copy "
                "SUSFS FS Patches"
            )

    if isdir(includedir):
        try:
            shutil.copytree(
                includedir,
                targetinclude,
                dirs_exist_ok=True,
            )
        except Exception:
            print(
                "⚠️ Failed to Copy "
                "SUSFS Include Patches"
            )


def applypatch(
    patchfile,
    cwd,
):
    result = runcommand(
        [
            "patch",
            "-p1",
        ],
        cwd=cwd,
        stdin=open(
            patchfile,
            "r",
            encoding="utf-8",
        ),
        check=False,
    )

    return result.returncode == 0


def applykernelsususfspatch(
    rootengine,
    susfsvariant,
    androidversion,
    kernelversion,
    susfsbranchdev,
    kerneldir,
):
    if rootengine != "KernelSU":
        print(
            "⚠️ Skipping KernelSU "
            "SUSFS Enable Patch "
            f"(Root = {rootengine})"
        )
        return

    print(
        "⚙️ Applying KernelSU "
        "SUSFS enable patch"
    )

    if susfsvariant == "OGKI":
        patchbranch = (
            f"oki-{androidversion}-"
            f"{kernelversion}"
        )
    else:
        patchbranch = (
            f"gki-{androidversion}-"
            f"{kernelversion}"
        )

    if susfsbranchdev == "true":
        patchbranch = (
            f"{patchbranch}-dev"
        )

    if susfsvariant == "GKI":
        susfs10url = (
            "https://gitlab.com/"
            "simonpunk/susfs4ksu/-/raw/"
            f"{patchbranch}/kernel_patches/"
            f"{rootengine}/"
            "10_enable_susfs_for_ksu.patch"
        )

    elif susfsvariant == "OGKI":
        susfs10url = (
            "https://raw.githubusercontent.com/"
            "cctv18/susfs4oki/"
            f"{patchbranch}/kernel_patches/"
            f"{rootengine}/"
            "10_enable_susfs_for_ksu.patch"
        )

    else:
        print(
            "⚠️ Invalid SUSFS Variant"
        )
        sys.exit(1)

    print(
        "🔍 Checking Patch URL..."
    )

    try:
        request = Request(
            susfs10url,
            method="HEAD",
        )

        with urlopen(
            request,
            timeout=30,
        ):
            pass

    except (
        HTTPError,
        URLError,
        TimeoutError,
    ):
        print(
            "⚠️ ERROR: Patch Does "
            "Not Exist:"
        )
        print(susfs10url)
        sys.exit(1)

    print(
        f"🌐 Downloading Patch: "
        f"{susfs10url}"
    )

    patchpath = (
        kerneldir
        / "enable.patch"
    )

    try:
        request = Request(
            susfs10url
        )

        with urlopen(
            request,
            timeout=60,
        ) as response:
            patchpath.write_bytes(
                response.read()
            )

    except (
        HTTPError,
        URLError,
        TimeoutError,
    ):
        print(
            "⚠️ ERROR: Failed to "
            "Download SUSFS Enable Patch"
        )
        sys.exit(1)

    origdir = kerneldir

    ksudir = (
        kerneldir.parent
        / "KernelSU"
    )

    print(
        f"📂 Current Directory: "
        f"{origdir}"
    )

    print(
        f"🔧 Applying SUSFS Enable Patch..."
    )

    if not isdir(ksudir):
        print(
            "⚠️ ERROR: KernelSU "
            "Directory Not Found:"
        )
        print(
            f"   {ksudir}"
        )

        patchpath.unlink(
            missing_ok=True
        )

        sys.exit(1)

    print(
        "📂 Entering KernelSU "
        "Directory..."
    )

    print(
        f"📂 Current Directory: "
        f"{ksudir}"
    )

    print(
        "🔧 Applying SUSFS Enable Patch..."
    )

    applied = applypatch(
        patchpath,
        ksudir,
    )

    if applied:
        print(
            "✔️ SUSFS Enable Patch "
            "Applied Successfully"
        )
    else:
        print(
            "⚠️ SUSFS Enable Patch "
            "Is Not Compatible With "
            "This KernelSU Source Tree"
        )

        print(
            "ℹ️ Skipping SUSFS "
            "Enable Patch"
        )

    print(
        "📂 Returning to Original "
        "Directory..."
    )

    patchpath.unlink(
        missing_ok=True
    )

    if applied:
        print(
            "✔️ KernelSU SUSFS Enable "
            "Patch Completed"
        )
    else:
        print(
            "⚠️ KernelSU SUSFS Enable "
            "Patch Skipped"
        )


def applylegacyfixpatch(
    gkiversion,
    sublevelvalue,
    workspace,
):
    if not (
        gkiversion == "android13-5.15"
        and sublevelvalue < 123
    ):
        return

    legacypatch = (
        workspace
        / "AndreiMikh-Kernel-Lab"
        / "patches"
        / "Legacy-5.15-Fix.patch"
    )

    if not isfile(legacypatch):
        print(
            "⚠️ Patch Not Found:"
        )
        print(legacypatch)
        sys.exit(1)

    print(
        "🚀 Applying Legacy Fix "
        "(Kernel 5.15.0–5.15.123)"
    )

    # Check Whether the Patch is
    # Already Applied
    dryrun = runcommand(
        [
            "patch",
            "-R",
            "-p1",
            "--dry-run",
        ],
        cwd=workspace,
        stdin=open(
            legacypatch,
            "r",
            encoding="utf-8",
        ),
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
        check=False,
    )

    if dryrun.returncode == 0:
        print(
            "⚠️ Patch Already Applied "
            "— Skipping"
        )
        return

    applied = applypatch(
        legacypatch,
        workspace,
    )

    if applied:
        print(
            "✔️ Legacy 5.15 Fix Applied"
        )
    else:
        print(
            "⚠️ Patch Failed"
        )
        sys.exit(1)


def applyxusfixpatch(
    xus,
    workspace,
):
    if xus != "Enabled":
        return

    print(
        "🛠️ Applying XUS Fix Patch"
    )

    source = (
        workspace
        / "AndreiMikh-Kernel-Lab"
        / "patches"
        / "XUS-Fix.patch"
    )

    destination = (
        workspace
        / "XUS-Fix.patch"
    )

    if not isfile(source):
        print(
            "⚠️ XUS Fix Patch Not Found:"
        )
        print(source)
        return

    shutil.copy2(
        source,
        destination,
    )

    applypatch(
        destination,
        workspace,
    )

    print(
        "✔️ XUS Fix Patch Applied"
    )


def checkrejects(
    rejectchecker,
    kerneldir,
):
    if not isfile(
        rejectchecker
    ):
        print(
            "⚠️ Reject Checker "
            "Not Found:"
        )
        print(rejectchecker)
        return

    print(
        "🔎 Running Reject Checker..."
    )

    # Preserve the Original Shell
    # Behavior:
    #
    # source "$REJECTCHECKER"
    # checkrejects .
    #
    # Checker is Therefore
    # Executed Inside Bash so That
    # Functions Defined By The
    # Sourced Script Remain Available
    command = [
        "bash",
        "-c",
        (
            "source \"$1\" && "
            "checkrejects \"$2\""
        ),
        "rootengine",
        str(rejectchecker),
        str(kerneldir),
    ]

    result = subprocess.run(
        command,
        text=True,
        check=False,
    )

    if result.returncode != 0:
        print(
            "⚠️ Reject Checker "
            "Reported an Error"
        )


def main():
    # ===== Read Environment =====

    androidversion = getenv(
        "ANDROIDVERSION"
    )

    kernelversion = getenv(
        "KERNELVERSION"
    )

    rootengine = getenv(
        "ROOTENGINE"
    )

    susfsrepository = getenv(
        "SUSFSREPOSITORY"
    )

    susfsvariant = getenv(
        "SUSFSVARIANT"
    )

    susfsbranchdev = getenv(
        "SUSFSBRANCHDEV"
    )

    workspace = Path(
        getenv(
            "GITHUB_WORKSPACE",
            os.getcwd(),
        )
    ).resolve()

    xus = getenv("XUS")

    rejectchecker = Path(
        getenv("REJECTCHECKER")
    )

    sublevelvalue = int(
        getenv(
            "SUBLEVEL",
            "0",
        ) or "0"
    )

    # ===== Build Kernel Base =====

    gkiversion = (
        f"{androidversion}-"
        f"{kernelversion}"
    )

    print(
        f"🧾 Android Version       : "
        f"{androidversion}"
    )

    print(
        f"🧾 Kernel Version        : "
        f"{kernelversion}"
    )

    print(
        f"🔎 Detected Kernel Base  : "
        f"{gkiversion}"
    )

    print("")

    # ===== Resolve Kernel Directory =====

    kerneldir = resolvekerneldirectory(
        workspace
    )

    print(
        f"📁 Kernel Directory: "
        f"{kerneldir}"
    )

    print("")

    # ===== Resolve SUSFS Repository =====

    susfsurl = (
        resolvesusfsrepository(
            susfsvariant
        )
    )

    susfsbranch = (
        resolvesusfsbranch(
            androidversion,
            kernelversion,
            susfsvariant,
            susfsbranchdev,
        )
    )

    print(
        f"🌐 SUSFS Repository: "
        f"{susfsurl}"
    )

    print(
        f"🌿 SUSFS Branch: "
        f"{susfsbranch}"
    )

    # ===== Prepare SUSFS Directory =====

    kernelworkspace = (
        workspace
        / "kernel_workspace"
    )

    susfsdir = (
        kernelworkspace
        / "susfs4ksu"
    )

    if isdir(susfsdir):
        print(
            "🧹 Removing Existing "
            "SUSFS Directory..."
        )

        shutil.rmtree(
            susfsdir
        )

    # ===== Clone SUSFS =====

    clonesusfs(
        susfsurl,
        susfsbranch,
        susfsdir,
    )

    # ===== Checkout SUSFS Revision =====

    checkoutsusfsrevised(
        susfsdir,
        susfsrepository,
        susfsbranch,
    )

    # ===== Display Active SUSFS Commit =====

    os.chdir(susfsdir)

    result = runcommand(
        [
            "git",
            "rev-parse",
            "--short",
            "HEAD",
        ],
        stdout=subprocess.PIPE,
        check=True,
    )

    activecommit = (
        result.stdout.strip()
    )

    print(
        f"✔️ Active SUSFS Commit: "
        f"{activecommit}"
    )

    # ===== Detect SUSFS Version =====

    susfsver = detectsusfsversion(
        susfsdir
    )

    print("")

    print(
        f"📦 SUSFS Version: "
        f"{susfsver}"
    )

    setupenv(
        "SUSFSVER",
        susfsver,
    )

    # ===== Find SUSFS Patch =====

    susfspatch = findsusfspatch(
        susfsdir,
        androidversion,
        kernelversion,
    )

    # ===== Copy SUSFS Patches =====

    print(
        f"🧾 SUSFS Patch Directory: "
        f"{susfspatch}"
    )

    copysusfspatches(
        susfsdir,
        kerneldir,
        susfsrepository,
        susfspatch,
    )

    # ===== Enter Kernel Common Directory =====

    os.chdir(kerneldir)

    # ===== Apply SUSFS Core Patch =====

    print(
        "⚙️ Applying SUSFS Core Patch "
        "(50 Add SUSFS Patch)"
    )

    corepatchapplied = applypatch(
        kerneldir
        / susfspatch.name,
        kerneldir,
    )

    if corepatchapplied:
        print(
            "✔️ SUSFS 50 Enable Core "
            "Patch Applied"
        )
    else:
        print(
            "⚠️ SUSFS Core Patch "
            "Already Applied or Failed"
        )

    # ===== Apply KernelSU SUSFS Patch =====

    applykernelsususfspatch(
        rootengine,
        susfsvariant,
        androidversion,
        kernelversion,
        susfsbranchdev,
        kerneldir,
    )

    print("")

    print(
        "🎉 SUSFS Patches Complete"
    )

    # ===== Apply Legacy 5.15 Fix =====

    applylegacyfixpatch(
        gkiversion,
        sublevelvalue,
        workspace,
    )

    # ===== Apply XUS Fix =====

    applyxusfixpatch(
        xus,
        workspace,
    )

    # ===== Run Reject Checker =====

    checkrejects(
        rejectchecker,
        kerneldir,
    )

    print("")

    print(
        "🎉 Kernel Compatibility "
        "Fix Stage Completed"
    )


if __name__ == "__main__":
    main()
