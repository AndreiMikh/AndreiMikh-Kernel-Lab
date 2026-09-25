#!/usr/bin/env python3

import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.request import Request, urlopen
from xml.etree import ElementTree


# ===== Command Helper =====

def runcommand(
    command,
    cwd=None,
    check=True,
    stdout=None,
    stderr=None,
):
    return subprocess.run(
        command,
        cwd=cwd,
        check=check,
        stdout=stdout,
        stderr=stderr,
        text=True,
    )


# ===== Environment Helper =====

def getenv(
    name,
    default="",
):
    return os.environ.get(
        name,
        default,
    )


# ===== Path Helpers =====

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


def writebytes(
    path,
    data,
):
    path.write_bytes(
        data
    )


# ===== GitHub Actions File Helpers =====

def envfile(name):
    value = getenv(name)

    if not value:
        raise RuntimeError(
            f"{name} is not set"
        )

    return Path(value)


def setupenv(
    name,
    value,
):
    gitenv = envfile(
        "GITHUB_ENV"
    )

    with gitenv.open(
        "a",
        encoding="utf-8",
    ) as output:
        output.write(
            f"{name}={value}\n"
        )


def setupoutput(
    name,
    value,
):
    gitoutput = envfile(
        "GITHUB_OUTPUT"
    )

    with gitoutput.open(
        "a",
        encoding="utf-8",
    ) as output:
        output.write(
            f"{name}={value}\n"
        )


# ===== Manifest Name Normalization =====

def normalizeconfig(filename):
    # Remove a final single-letter suffix.
    #
    # Example:
    #   DEVICE_A -> DEVICE
    #
    # Keep Original Value When
    # File Name Does Not Match Pattern
    if re.fullmatch(
        r"(.+)_([a-zA-Z])",
        filename,
    ):
        return filename.rsplit(
            "_",
            1,
        )[0]

    return filename


def normalizebase(filename):
    # Preserve Original Bash/Sed
    # Normalization Behavior
    value = filename

    # Normalize AOSP Naming
    value = value.replace(
        "_aosp",
        "AOSP",
    )

    # Normalize Custom Build Naming
    value = value.replace(
        "_custom",
        "CustomBuild",
    )

    # Convert:
    #   _x -> X
    # For Alphanumeric Characters
    value = re.sub(
        r"_([a-zA-Z0-9])",
        lambda match: match.group(1).upper(),
        value,
    )

    # Normalize Manufacturer Names
    value = re.sub(
        r"^oneplus",
        "1+",
        value,
    )

    value = re.sub(
        r"^realme",
        "RealMe",
        value,
    )

    value = re.sub(
        r"^oppo",
        "Oppo",
        value,
    )

    return value


# ===== GitHub API Branch Discovery =====

def getbranches(
    owner,
    repository,
    token="",
):
    # Build GitHub Branches API URL
    url = (
        "https://api.github.com/repos/"
        f"{owner}/{repository}/branches"
        "?per_page=100"
    )

    headers = {
        "Accept": (
            "application/vnd.github+json"
        )
    }

    # Use GitHub Token When Available
    if token:
        headers["Authorization"] = (
            f"Bearer {token}"
        )

    try:
        request = Request(
            url,
            headers=headers,
        )

        with urlopen(
            request,
            timeout=20,
        ) as response:
            data = response.read().decode(
                "utf-8",
                errors="replace",
            )

        branches = json.loads(
            data
        )

        return [
            branch["name"]
            for branch in branches
            if isinstance(
                branch,
                dict,
            )
            and branch.get("name")
        ]

    except (
        HTTPError,
        URLError,
        TimeoutError,
        OSError,
        ValueError,
    ):
        return []


# ===== Git Remote Branch Discovery =====

def getgitbranches(
    owner,
    repository,
):
    # Fallback to Git When GitHub API
    # Cannot Provide Branch Lists
    result = runcommand(
        [
            "git",
            "ls-remote",
            "--heads",
            (
                f"https://github.com/"
                f"{owner}/{repository}.git"
            ),
        ],
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=False,
    )

    branches = []

    # Parse Refs/Heads From Git LS-Remote
    for line in result.stdout.splitlines():
        if "refs/heads/" not in line:
            continue

        branch = line.split(
            "refs/heads/",
            1,
        )[1]

        if branch:
            branches.append(
                branch
            )

    return branches


# ===== Repository Branch Resolver =====

def getrepositorybranches(
    owner,
    repository,
    token,
):
    # First Attempt GitHub API
    branches = getbranches(
        owner,
        repository,
        token,
    )

    if branches:
        return branches

    # If API Fails, Use Git Directly
    print(
        "⚠️ GitHub API Failed"
    )

    print(
        "🔄 Falling Back to Git LS-Remote..."
    )

    return getgitbranches(
        owner,
        repository,
    )


# ===== Remote URL Checker =====

def urlexists(url):
    # Use HEAD to Check Whether Manifest
    # Exists Without Downloading it First
    try:
        request = Request(
            url,
            method="HEAD",
        )

        with urlopen(
            request,
            timeout=20,
        ):
            return True

    except (
        HTTPError,
        URLError,
        TimeoutError,
        OSError,
    ):
        return False


# ===== Remote File Downloader =====

def downloadfile(
    url,
    path,
):
    try:
        request = Request(
            url,
            headers={
                "User-Agent": "GitHub-Actions"
            },
        )

        with urlopen(
            request,
            timeout=30,
        ) as response:
            data = response.read()

        # Use Renamed Writebytes Helper
        writebytes(
            path,
            data,
        )

        return True

    except (
        HTTPError,
        URLError,
        TimeoutError,
        OSError,
    ):
        return False


# ===== Repository Input Parser =====

def parseinput(value):
    # Remove GitHub HTTPS Prefix
    value = value.removeprefix(
        "https://github.com/"
    )

    # Remove Trailing Slashes
    value = value.rstrip(
        "/"
    )

    # Parse Owner/Repository Input
    if "/" in value:
        owner, repository = value.split(
            "/",
            1,
        )

    # Preserve Original Fallback:
    # Owner-Only Input Uses Kernel-Manifest
    else:
        owner = value
        repository = "Kernel-Manifest"

    return (
        owner,
        repository,
    )


# ===== Manifest Repository Search =====

def findmanifest(
    file,
    repositories,
    xmlpath,
    readmepath,
    token,
):
    # Search Repositories in Deterministic Order
    for owner, repository in repositories:
        print("")
        print(
            f"🔎 Checking "
            f"{owner}/{repository}"
        )

        # Resolve Available Branches
        branches = getrepositorybranches(
            owner,
            repository,
            token,
        )

        # Skip Repositories Without Branches
        if not branches:
            print(
                "⚠️ No Branches Found"
            )
            continue

        # Search Every Branch for Manifest
        for branch in branches:
            print(
                f"  → 📃 Trying Branch: "
                f"{branch}"
            )

            # Build Raw GitHub URLs
            xmlurl = (
                "https://raw.githubusercontent.com/"
                f"{owner}/{repository}/"
                f"{branch}/{file}.xml"
            )

            readmeurl = (
                "https://raw.githubusercontent.com/"
                f"{owner}/{repository}/"
                f"{branch}/README.md"
            )

            # Check Whether XML Manifest Exists
            if not urlexists(
                xmlurl
            ):
                continue

            print(
                f"✔️ Found {file}.xml"
            )

            print(
                f"📂 Repository: "
                f"{owner}/{repository}"
            )

            print(
                f"🌿 Branch    : "
                f"{branch}"
            )

            # Download Manifest to a Temporary Path
            tmpxml = Path(
                f"{xmlpath}.tmp"
            )

            if not downloadfile(
                xmlurl,
                tmpxml,
            ):
                print(
                    "⚠️ Manifest Download Failed"
                )

                tmpxml.unlink(
                    missing_ok=True
                )

                continue

            # Verify Downloaded Manifest
            if (
                not isfile(tmpxml)
                or tmpxml.stat().st_size == 0
            ):
                print(
                    "⚠️ Downloaded Manifest Is Empty"
                )

                tmpxml.unlink(
                    missing_ok=True
                )

                continue

            # Replace Final Maifest With
            # Verified Temporary File
            tmpxml.replace(
                xmlpath
            )

            # Download README When Available
            tmpreadme = Path(
                f"{readmepath}.tmp"
            )

            if downloadfile(
                readmeurl,
                tmpreadme,
            ):
                if (
                    isfile(tmpreadme)
                    and tmpreadme.stat().st_size > 0
                ):
                    tmpreadme.replace(
                        readmepath
                    )
                else:
                    tmpreadme.unlink(
                        missing_ok=True
                    )
            else:
                tmpreadme.unlink(
                    missing_ok=True
                )

            # Return Forst Successful Match
            return (
                owner,
                repository,
                branch,
            )

        print(
            f"⚠️ {file}.xml Not Found "
            f"in {owner}/{repository}"
        )

    # Nothing Was Found
    return (
        "",
        "",
        "",
    )


# ===== Manifest XML Revision Parser =====

def parserevision(
    xmlpath,
):
    try:
        # Use Python's XML Parser First
        tree = ElementTree.parse(
            xmlpath
        )

        root = tree.getroot()

        # Find First Project Containing
        # a Revision Attribute
        for project in root.iter(
            "project"
        ):
            revision = project.get(
                "revision"
            )

            if revision:
                return revision

    except (
        ElementTree.ParseError,
        OSError,
    ):
        pass

    # Preserve Original Grep Fallback
    text = readtxt(
        xmlpath,
        encoding="utf-8",
        errors="replace",
    )

    match = re.search(
        r"<project[^>]+revision="
        r'"([^"]+)"',
        text,
    )

    if match:
        return match.group(1)

    return ""


# ===== CPU Parser =====

def parsecpu(
    revision,
):
    # Original Logic:
    #
    # Revision -> Part After /
    # Rhen -> Part Before _
    #
    # Example:
    # Android14/FOO_CPU -> FOO
    parts = revision.split(
        "/",
        1,
    )

    if len(parts) < 2:
        return ""

    return parts[1].split(
        "_",
        1,
    )[0]


# ===== Android Version Parser =====

def parseandroidversion(
    revision,
):
    match = re.search(
        r"\d+\.\d+(?:\.\d+)?",
        revision,
    )

    if not match:
        return ""

    return match.group(0)


# ===== Android Major Version Parser =====

def parseandroidmajor(
    version,
):
    if not version:
        return ""

    return version.split(
        ".",
        1,
    )[0]


# ===== README Build Information Parser =====

def parsereadme(
    readmepath,
):
    cpud = ""
    buildmethod = ""

    # README is Optional
    if not isfile(
        readmepath
    ):
        return (
            cpud,
            buildmethod,
        )

    if readmepath.stat().st_size == 0:
        return (
            cpud,
            buildmethod,
        )

    text = readtxt(
        readmepath,
        encoding="utf-8",
        errors="replace",
    )

    # Find First Line Containing
    # OplusBuildKernel.sh
    for line in text.splitlines():
        if "oplus_build_kernel.sh" not in line:
            continue

        parts = line.split()

        # Preserve:
        #   awk '{print $(NF-1)}'
        #   awk '{print $NF}'
        if len(parts) >= 2:
            cpud = parts[-2]
            buildmethod = parts[-1]

        break

    return (
        cpud,
        buildmethod,
    )


# ===== Main Manifest Extraction =====

def main():
    # ===== Read Workflow Environment =====

    FILE = getenv(
        "FILE"
    )

    GITREPOSITORYINPUT = getenv(
        "GITREPOSITORYINPUT"
    )

    GITHUB_TOKEN = getenv(
        "GITHUB_TOKEN"
    )

    # FILE is required by the workflow.
    if not FILE:
        print(
            "⚠️ ERROR: FILE is not set"
        )
        sys.exit(1)

    # Resolve GitHub Actions Workspace
    GITHUB_WORKSPACE = Path(
        getenv(
            "GITHUB_WORKSPACE",
            os.getcwd(),
        )
    )

    # Match the original Bash:
    # cd "$GITHUB_WORKSPACE"
    os.chdir(
        GITHUB_WORKSPACE
    )

    # ===== Normalize Manifest Names =====

    MANIFESTFILECONFIG = normalizeconfig(
        FILE
    )

    MANIFESTBASEFILE = normalizebase(
        MANIFESTFILECONFIG
    )

    # ===== Prepare Fallback Directory =====

    FALLBACKDIRECTORY = (
        GITHUB_WORKSPACE
        / ".repo"
        / "fallbackmanifests"
    )

    FALLBACKDIRECTORY.mkdir(
        parents=True,
        exist_ok=True,
    )

    # ===== Define Manifest Paths =====

    XMLPATH = (
        FALLBACKDIRECTORY
        / f"{FILE}.xml"
    )

    READMEPATH = (
        FALLBACKDIRECTORY
        / "README.md"
    )

    # ===== Display Manifest Information =====

    print(
        f"FILE                  : {FILE}"
    )

    print(
        "MANIFESTFILECONFIG    : "
        f"{MANIFESTFILECONFIG}"
    )

    print(
        "MANIFESTBASEFILE      : "
        f"{MANIFESTBASEFILE}"
    )

    # ===== Export Normalized Manifest Names =====

    setupenv(
        "MANIFESTFILECONFIG",
        MANIFESTFILECONFIG,
    )

    setupenv(
        "MANIFESTBASEFILE",
        MANIFESTBASEFILE,
    )

    # Export Manifest Base Name as Step Output
    setupoutput(
        "manifestbasefile",
        MANIFESTBASEFILE,
    )

    # ===== Define Repository Search Order =====

    REPOSITORIES = [
        (
            "AndreiMikh",
            "Kernel-Manifest",
        ),
        (
            "AndreiMikh",
            "AndreiMikh-Kernel-Lab",
        ),
    ]

    # ===== Add Dynamic Repository =====

    if GITREPOSITORYINPUT:
        OWNER, REPOSITORY = parseinput(
            GITREPOSITORYINPUT
        )

        print(
            "🚀 Dynamic Repository: "
            f"{OWNER}/{REPOSITORY}"
        )

        REPOSITORIES.append(
            (
                OWNER,
                REPOSITORY,
            )
        )

    # ===== Search Manifest =====

    (
        MANIFESTFOUNDREPO,
        MANIFESTFOUNDREPONAME,
        MANIFESTFOUNDBRANCH,
    ) = findmanifest(
        FILE,
        REPOSITORIES,
        XMLPATH,
        READMEPATH,
        GITHUB_TOKEN,
    )

    # ===== Verify Manifest =====

    if (
        not MANIFESTFOUNDREPO
        or not isfile(XMLPATH)
        or XMLPATH.stat().st_size == 0
    ):
        print("")
        print(
            f"⚠️ WARNING: {FILE}.xml "
            "Not Found in Any Repository"
        )
        sys.exit(1)

    # ===== Display Located Manifest =====

    print("")
    print(
        "------ Manifest Located ------"
    )

    print(
        "📂 Repository  : "
        f"{MANIFESTFOUNDREPO}/"
        f"{MANIFESTFOUNDREPONAME}"
    )

    print(
        f"📂 Branch      : "
        f"{MANIFESTFOUNDBRANCH}"
    )

    print(
        "------------------------------"
    )

    print("")

    # ===== Export Repository Information =====

    setupenv(
        "MANIFESTREPO",
        MANIFESTFOUNDREPO,
    )

    setupenv(
        "MANIFESTREPONAME",
        MANIFESTFOUNDREPONAME,
    )

    setupenv(
        "MANIFESTBRANCH",
        MANIFESTFOUNDBRANCH,
    )

    # ===== Parse Manifest Revision =====

    print(
        "📌 Parsing Manifest"
    )

    REVISION = parserevision(
        XMLPATH
    )

    # ===== Extract CPU =====

    CPU = parsecpu(
        REVISION
    )

    # ===== Extract Android Version =====

    VANDROID = parseandroidversion(
        REVISION
    )

    # ===== Extract Android Major Version =====

    ASHORTVERSION = parseandroidmajor(
        VANDROID
    )

    # ===== Export Parsed Manifest Data =====

    setupenv(
        "CPU",
        CPU,
    )

    setupenv(
        "VANDROID",
        VANDROID,
    )

    setupenv(
        "ASHORTVERSION",
        ASHORTVERSION,
    )

    # ===== Export CPU Step Output =====

    setupoutput(
        "cpu",
        CPU,
    )

    # ===== Parse README Build Information =====

    CPUD, BUILDMETHOD = parsereadme(
        READMEPATH
    )

    if CPUD or BUILDMETHOD:
        setupenv(
            "CPUD",
            CPUD,
        )

        setupenv(
            "BUILDMETHOD",
            BUILDMETHOD,
        )

    # ===== Export Combined Manifest Identity =====

    setupoutput(
        "value",
        (
            f"{MANIFESTBASEFILE}-Android"
            f"{VANDROID or 'Unknown'}"
        ),
    )

    # ===== Complete =====

    print("")
    print(
        "🎉 Manifest Parsing Complete"
    )


# ===== Script Entry Point =====

if __name__ == "__main__":
    try:
        main()

    except KeyboardInterrupt:
        print(
            "⚠️ Interrupted"
        )
        sys.exit(130)

    except Exception as error:
        print(
            f"⚠️ ERROR: {error}"
        )
        sys.exit(1)
