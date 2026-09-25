#!/usr/bin/env python3

import json
import os
import re
import shutil
import subprocess
import urllib.error
import urllib.parse
import urllib.request
import zipfile
from pathlib import Path

# Path Alias
if not hasattr(Path, "isfile"):
    Path.isfile = Path.is_file

# Environment
WORKSPACE = Path(
    os.environ.get(
        "GITHUB_WORKSPACE",
        Path.cwd(),
    )
)

IMAGEPATH = WORKSPACE / "AnyKernel3" / "Image"
FLATDIR = WORKSPACE / "FlatAPK"

GITHUB_TOKEN = os.environ.get(
    "GITHUB_TOKEN",
    "",
)
KSUREPOSITORY = os.environ.get(
    "KSUREPOSITORY",
    "",
)
MANAGERBRANCH = os.environ.get(
    "MANAGERBRANCH",
    "",
)
ROOTENGINE = os.environ.get(
    "ROOTENGINE",
    "",
)
KSUVERSION = os.environ.get(
    "KSUVERSION",
    "",
)

# Helpers
def getenv(name, default=""):
    """Read Environment Variable"""
    return os.environ.get(
        name,
        default,
    )
def writetxt(path, value):
    """Write text file."""
    Path(path).write_text(
        value,
        encoding="utf-8",
    )
def appendgithubenv(name, value):
    """Export GitHub Environment"""
    target = getenv("GITHUB_ENV")
    if not target:
        return
    with open(
        target,
        "a",
        encoding="utf-8",
    ) as file:
        file.write(
            f"{name}={value}\n"
        )
def appendgithuboutput(name, value):
    """Export GitHub Output"""
    target = getenv("GITHUB_OUTPUT")
    if not target:
        return
    with open(
        target,
        "a",
        encoding="utf-8",
    ) as file:
        file.write(
            f"{name}={value}\n"
        )
def contains(pattern, text):
    """Case-insensitive regex."""
    return re.search(
        pattern,
        text,
        re.IGNORECASE,
    ) is not None
def runcommand(command):
    """Run Command Safely"""
    try:
        return subprocess.run(
            command,
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            check=False,
        )
    except FileNotFoundError:
        return None

# Regional Detection
def readkernelstrings(imagepath):
    """Read Kernel Strings"""
    result = runcommand(
        [
            "strings",
            str(imagepath),
        ]
    )
    if result is None:
        print(
            "⚠️ 'strings' command not found"
        )
        return ""
    return result.stdout or ""
def detectregionalvariant():
    """Detect ROM Variant"""
    scorecolor = 0
    scoreoxygen = 0
    infomanifest = (
        f"{getenv('MANIFESTBRANCH')} "
        f"{getenv('MANIFESTREPO')} "
        f"{getenv('MANIFESTFILECONFIG')}"
    ).lower()
    print(
        "🔎 Manifest Information:"
    )
    print(infomanifest)
    print()

    # ColorOS Signals
    if contains(
        r"coloros|cn|china",
        infomanifest,
    ):
        scorecolor += 6

    # OxygenOS Signals
    if contains(
        r"oxygen|oneplus|global|eu|india",
        infomanifest,
    ):
        scoreoxygen += 6

    # Shared OPlus Signal
    if contains(
        r"oplus",
        infomanifest,
    ):
        scorecolor += 1
        scoreoxygen += 1

    # Kernel image
    if IMAGEPATH.isfile():
        print(
            f"✔ Found Kernel Image: {IMAGEPATH}"
        )
        outputstrings = readkernelstrings(
            IMAGEPATH
        )
        lowerstrings = (
            outputstrings.lower()
        )
        print(
            "🔎 Debug Matches "
            "(Top 15 Relevant Lines):"
        )
        relevantpattern = re.compile(
            r"androidboot|fingerprint|"
            r"oplus|oneplus|coloros|"
            r"oxygen|hwc|region|"
            r"country|build",
            re.IGNORECASE,
        )
        matches = [
            line
            for line in outputstrings.splitlines()
            if relevantpattern.search(line)
        ]
        for line in matches[:15]:
            print(line)
        print(
            "🧠 Analyzing Kernel Strings..."
        )

        # ColorOS
        if contains(
            r"coloros",
            lowerstrings,
        ):
            scorecolor += 4
        if contains(
            r"hwc=cn|region=cn|"
            r"country=cn|china",
            lowerstrings,
        ):
            scorecolor += 6

        # OxygenOS
        if contains(
            r"oxygen",
            lowerstrings,
        ):
            scoreoxygen += 4
        if contains(
            r"hwc=global|hwc=eu|hwc=india",
            lowerstrings,
        ):
            scoreoxygen += 6
        if contains(
            r"global|europe|india",
            lowerstrings,
        ):
            scoreoxygen += 2
        if contains(
            r"oneplus",
            lowerstrings,
        ):
            scoreoxygen += 1

        # Shared OPlus
        if contains(
            r"oplus",
            lowerstrings,
        ):
            scorecolor += 1
            scoreoxygen += 1
    else:
        print(
            "⚠️ Kernel Image Not Found"
        )
        print(
            "⚠️ Using Manifest-Only Detection"
        )
        print()

    # Final decision
    if scorecolor > scoreoxygen:
        roombase = "ColorOS"
        maxscore = scorecolor
    elif scoreoxygen > scorecolor:
        roombase = "OxygenOS"
        maxscore = scoreoxygen
    elif (
        scorecolor >= 4
        and scoreoxygen >= 4
    ):
        roombase = (
            "ColorOS / OxygenOS"
        )
        maxscore = scorecolor
    else:
        roombase = "Unknown"
        maxscore = 0

    # Confidence
    if maxscore >= 10:
        confidence = "High"
    elif maxscore >= 5:
        confidence = "Medium"
    else:
        confidence = "Low"
    print(
        "------------------------------"
    )
    print(
        "📊 Score Breakdown"
    )
    print(
        "------------------------------"
    )
    print(
        f"🇨🇳 ColorOS  : {scorecolor}"
    )
    print(
        f"🇺🇸 OxygenOS : {scoreoxygen}"
    )
    print(
        "------------------------------"
    )
    print(
        f"📌 Final ROM Base : {roombase}"
    )
    print(
        f"🎯 Confidence     : {confidence}"
    )
    print(
        "------------------------------"
    )
    appendgithubenv(
        "ROMBASE",
        roombase,
    )
    appendgithubenv(
        "ROMCONFIDENCE",
        confidence,
    )
    print()
    print(
        "🎉 Regional ROM Base "
        "Detection Complete!"
    )

# GitHub API
def githubrequest(url):
    """Request GitHub API"""
    headers = {
        "Accept":
            "application/vnd.github+json",
        "User-Agent":
            "APK-Variant-Resolver",
    }
    if GITHUB_TOKEN:
        headers[
            "Authorization"
        ] = f"Bearer {GITHUB_TOKEN}"
    request = urllib.request.Request(
        url,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(
            request,
            timeout=30,
        ) as response:
            return json.loads(
                response.read().decode(
                    "utf-8"
                )
            )
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
    ):
        return None
def getworkflowruns():
    """Get Successful Workflow Runs"""
    if (
        not KSUREPOSITORY
        or not MANAGERBRANCH
    ):
        return []
    branch = urllib.parse.quote(
        MANAGERBRANCH,
        safe="",
    )
    url = (
        "https://api.github.com/repos/"
        f"{KSUREPOSITORY}"
        "/actions/runs"
        f"?branch={branch}"
        "&status=success"
        "&per_page=50"
    )
    data = githubrequest(url)
    if not data:
        return []
    runs = data.get(
        "workflow_runs",
        [],
    )
    runs.sort(
        key=lambda item:
            item.get(
                "created_at",
                "",
            ),
        reverse=True,
    )
    return [
        item["id"]
        for item in runs
        if item.get("id") is not None
    ]
def getartifacts(runid):
    """Get Workflow Artifacts"""
    url = (
        "https://api.github.com/repos/"
        f"{KSUREPOSITORY}"
        f"/actions/runs/{runid}"
        "/artifacts"
    )
    data = githubrequest(url)
    if not data:
        return []
    return data.get(
        "artifacts",
        [],
    )
def scoreartifacts(artifacts):
    """Score Workflow Artifacts"""
    artifactnames = "\n".join(
        str(
            item.get(
                "name",
                "",
            )
        )
        for item in artifacts
    )
    if not artifactnames:
        return 0

    # Relevant Artifacts
    if not contains(
        r"apk|manager|release|build",
        artifactnames,
    ):
        return 0
    score = 0

    # APK
    if contains(
        r"\.apk($|[^a-zA-Z])",
        artifactnames,
    ):
        score += 50

    # Manager
    if contains(
        r"manager",
        artifactnames,
    ):
        score += 20

    # Release/Build
    if contains(
        r"release|build",
        artifactnames,
    ):
        score += 10
    return score
def downloadartifact(
    url,
    destination,
):
    """Download Artifact ZIP"""
    headers = {
        "Accept":
            "application/vnd.github+json",
        "User-Agent":
            "APK-Variant-Resolver",
    }
    if GITHUB_TOKEN:
        headers[
            "Authorization"
        ] = f"Bearer {GITHUB_TOKEN}"
    request = urllib.request.Request(
        url,
        headers=headers,
    )
    try:
        with urllib.request.urlopen(
            request,
            timeout=120,
        ) as response:
            destination.write_bytes(
                response.read()
            )
        return True
    except (
        urllib.error.HTTPError,
        urllib.error.URLError,
        TimeoutError,
    ) as error:
        print(
            "⚠️ Download Failed, "
            f"Skipping... ({error})"
        )
        destination.unlink(
            missing_ok=True
        )
        return False

# APK Resolver
def resolveapk():
    """Resolve Manager APK"""
    print(
        "🚀 AI APK Resolver Started..."
    )
    managerapkdir = (
        WORKSPACE
        / (
            f"ManagerAPK-"
            f"{ROOTENGINE}-"
            f"{KSUVERSION}"
        )
    )
    managerapkdir.mkdir(
        parents=True,
        exist_ok=True,
    )
    print()
    print(
        "------------------------------"
    )
    print(
        f"ℹ️ [Info] Repository       : "
        f"{KSUREPOSITORY}"
    )
    print(
        f"ℹ️ [Info] Branch           : "
        f"{MANAGERBRANCH}"
    )
    print(
        f"ℹ️ [Info] Output Directory : "
        f"{managerapkdir}"
    )
    print(
        "------------------------------"
    )
    print()
    print(
        "🔎 [Check] Fetching Latest "
        "Successful Workflow Runs..."
    )
    runs = getworkflowruns()
    if not runs:
        print(
            "⚠️ [Error] "
            "No Successful Runs Found"
        )
        return managerapkdir
    print(
        f"ℹ️ [Info] Found "
        f"{len(runs)} Workflow Runs..."
    )
    print(
        "🔍 [Check] Scanning Runs "
        "for APK Artifacts..."
    )
    selectedrun = ""
    bestscore = 0

    # Select Highest Score
    for runid in runs:
        print(
            "------------------------------"
        )
        print(
            f"🔍 [Check] Run ID: {runid}"
        )
        artifacts = getartifacts(
            runid
        )
        score = scoreartifacts(
            artifacts
        )
        if score == 0:
            print(
                "⚠️ [Skip] "
                "No Relevant Artifacts"
            )
            continue
        print(
            f"📊 [Info] Score for Run "
            f"{runid} = {score}"
        )
        if score > bestscore:
            bestscore = score
            selectedrun = str(
                runid
            )
            print(
                "🏆 [New Best] "
                "Selected Run Updated "
                f"→ {selectedrun}"
            )
    if not selectedrun:
        print(
            "⚠️ [Error] "
            "No Valid APK Workflow Found"
        )
        return managerapkdir
    print()
    print(
        "------------------------------"
    )
    print(
        f"🏁 [Result] Selected Run: "
        f"{selectedrun}"
    )
    print(
        f"🏁 [Result] Best Score  : "
        f"{bestscore}"
    )
    print(
        "------------------------------"
    )
    print()
    print(
        "🔍 [Verify] Checking Artifacts "
        "Inside Selected Run..."
    )
    selectedartifacts = getartifacts(
        selectedrun
    )
    for artifact in selectedartifacts:
        print(
            artifact.get(
                "name",
                "",
            )
        )
    print(
        "------------------------------"
    )

    # Manager Artifacts
    managerartifacts = [
        artifact
        for artifact in selectedartifacts
        if contains(
            r"manager",
            str(
                artifact.get(
                    "name",
                    "",
                )
            ),
        )
    ]
    print(
        "📩 [Step 3] Fetching Only "
        "Manager APK Artifacts..."
    )
    print(
        "------------------------------"
    )
    print(
        "🔍 Manager Artifact URLs:"
    )
    for artifact in managerartifacts:
        print(
            artifact.get(
                "archive_download_url",
                "",
            )
        )
    print(
        "------------------------------"
    )
    print(
        f"📦 Manager Artifact Count: "
        f"{len(managerartifacts)}"
    )
    if not managerartifacts:
        print(
            "⚠️ No Manager APK "
            "Artifacts Found"
        )
        return managerapkdir
    index = 0

    # Download Artifacts
    for artifact in managerartifacts:
        url = artifact.get(
            "archive_download_url"
        )
        if not url:
            continue
        index += 1
        print(
            f"⬇️ Downloading Artifact "
            f"#{index}"
        )
        zipfilepath = (
            managerapkdir
            / f"artifact_{index}.zip"
        )
        if not downloadartifact(
            url,
            zipfilepath,
        ):
            continue

        # Verify ZIP
        try:
            with zipfile.ZipFile(
                zipfilepath,
                "r",
            ) as archive:
                if archive.testzip():
                    raise zipfile.BadZipFile(
                        "ZIP integrity failed"
                    )
                archive.extractall(
                    managerapkdir
                )
        except (
            zipfile.BadZipFile,
            OSError,
        ) as error:
            print(
                "⚠️ Corrupted Artifact, "
                f"Skipping... ({error})"
            )
            zipfilepath.unlink(
                missing_ok=True
            )
            continue
        zipfilepath.unlink(
            missing_ok=True
        )

    # Keep APK Files Only
    print(
        "🧹 [Step 4] "
        "Cleaning Non-APK Files..."
    )
    for item in managerapkdir.rglob(
        "*"
    ):
        if (
            item.is_file()
            and item.suffix.lower()
            != ".apk"
        ):
            item.unlink(
                missing_ok=True
            )

    # ReSukiSU Filtering
    if (
        KSUREPOSITORY
        == "ReSukiSU/ReSukiSU"
    ):
        print(
            "ℹ️ [Info] ReSukiSU Repository "
            "Detected."
        )
        for apk in managerapkdir.rglob(
            "*.apk"
        ):
            if not apk.name.endswith(
                "arm64-v8a-release.apk"
            ):
                apk.unlink(
                    missing_ok=True
                )
        for apk in managerapkdir.rglob(
            "*.apk"
        ):
            if (
                "spoofed"
                in apk.name.lower()
            ):
                apk.unlink(
                    missing_ok=True
                )

    # Validate APKs
    print(
        "🔍 [Step 5] Verifying Output..."
    )
    apkfiles = [
        item
        for item in managerapkdir.rglob(
            "*.apk"
        )
        if item.isfile()
    ]
    apkcount = len(
        apkfiles
    )
    print(
        f"📦 APK Count: {apkcount}"
    )
    if apkcount:
        print(
            "------------------------------"
        )
        print(
            f"📦 [Success] APKs Found: "
            f"{apkcount}"
        )
        for apk in apkfiles:
            print(apk)
        print(
            "------------------------------"
        )
    else:
        print(
            "⚠️ [Warning] No APK Files Found "
            "(Manager Build Likely Missing)"
        )
    print()
    print(
        "🎉 AI APK Resolver "
        "Completed Successfully"
    )
    return managerapkdir

# APK Validation
def validateandcollect(
    managerapkdir,
):
    """Validate and Flatten APKs."""
    print(
        "🔍 Checking Manager APK Directory..."
    )
    apkfiles = [
        item
        for item in managerapkdir.rglob(
            "*.apk"
        )
        if item.isfile()
    ]
    apkcount = len(
        apkfiles
    )
    print(
        "------------------------------"
    )
    print(
        f"📦 APK Count: {apkcount}"
    )
    print(
        "------------------------------"
    )
    if apkcount > 0:
        apkmanager = "true"
        print(
            "📦 Manager APK Found"
        )
        print(
            f"📌 APK Manager : "
            f"{apkmanager}"
        )
        print(
            f"📌 APK Count   : "
            f"{apkcount}"
        )

        # Export Environment
        appendgithubenv(
            "APKMANAGER",
            apkmanager,
        )
        appendgithubenv(
            "APKCOUNT",
            apkcount,
        )
        # Export Outputs
        appendgithuboutput(
            "apkmanager",
            apkmanager,
        )
        appendgithuboutput(
            "apkcount",
            apkcount,
        )
        # Flatten APKs
        print(
            "📦 Flattening APKs..."
        )
        FLATDIR.mkdir(
            parents=True,
            exist_ok=True,
        )
        for apk in apkfiles:
            shutil.copy2(
                apk,
                FLATDIR / apk.name,
            )
        flatfiles = [
            item
            for item in FLATDIR.glob(
                "*.apk"
            )
            if item.isfile()
        ]
        flatcount = len(
            flatfiles
        )
        print(
            "------------------------------"
        )
        print(
            f"📦 Flat APK Count: "
            f"{flatcount}"
        )
        print(
            "------------------------------"
        )
        if flatcount != apkcount:
            print(
                "⚠️ APK Flattening "
                "Verification Failed"
            )
            print(
                f"📌 Expected: {apkcount}"
            )
            print(
                f"📌 Found   : {flatcount}"
            )
            raise SystemExit(1)
        print(
            "✔️ APK Ready for Upload"
        )
    else:

        # No APK
        apkmanager = "false"
        apkcount = 0
        appendgithubenv(
            "APKMANAGER",
            apkmanager,
        )
        appendgithubenv(
            "APKCOUNT",
            apkcount,
        )
        appendgithuboutput(
            "apkmanager",
            apkmanager,
        )
        appendgithuboutput(
            "apkcount",
            apkcount,
        )
        print(
            "⚠️ No APK Found"
        )

# Main
def main():
    """Run All Resolver Stages"""
    # Regional Detection
    detectregionalvariant()
    # APK Resolution
    managerapkdir = resolveapk()
    # APK Collection
    validateandcollect(
        managerapkdir
    )

if __name__ == "__main__":
    main()
