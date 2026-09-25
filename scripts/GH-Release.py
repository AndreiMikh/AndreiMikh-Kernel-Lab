#!/usr/bin/env python3

import os
import subprocess
import sys
from pathlib import Path


def runcommand(
    command,
    cwd=None,
    check=True,
):
    # Run a Command While Preserving Requested Working Directory and
    # Subprocess Error Handling Behavior
    return subprocess.run(
        command,
        cwd=cwd,
        check=check,
        text=True,
    )


def isfile(path):
    # Check Whether Supplied Path is a Regular File
    return path.is_file()


def isdir(path):
    # Check Whether Supplied Path is a Directory
    return path.is_dir()


def writetxt(
    path,
    text,
    encoding="utf-8",
):
    # Write Text Content to a File Using Requested Encoding
    path.write_text(
        text,
        encoding=encoding,
    )


def collectassets():
    # Collect All Files That Should be Uploaded to GitHub Release
    assets = []

    # Read AnyKernel3 ZIP Path From GitHub Actions Environment
    anykernel = os.environ.get(
        "ANYKERNEL3ZIP",
        "",
    )

    # Add AnyKernel3 ZIP When File Exists
    if anykernel:
        anykernelpath = Path(anykernel)

        if isfile(anykernelpath):
            assets.append(
                anykernelpath
            )

    # Search FlatAPK Directory for APK Files
    flatapk = Path("FlatAPK")

    if isdir(flatapk):
        for apk in sorted(
            flatapk.rglob("*.apk")
        ):
            if isfile(apk):
                assets.append(apk)

    return assets


def createreleasenotes(path):
    # Generate Release Notes Used by GitHub Release
    releasenotes = """### 📋 **INSTALLATION GUIDE**

### 📩 **DOWNLOAD THE KERNEL ZIP FILE**
---

- Navigate to the Release Page & Download the Correct Kernel Zip File for Your Device & Kernel Version
- Ensure that You Select the File that Matches Your Device's Model & Kernel Version

### 📲 **PREPARE YOUR DEVICE**
---

- Make Sure Your Device has an **Unlocked Bootloader** & a Compatible Custom Recovery
- It's Recommended to **Backup Your Data** Before Proceeding with the Installation

### 📤 **INSTALL THROUGH RECOVERY TOOL**
---

- Reboot Your Device Into **Recovery Mode**
- Select **Install** & Navigate to the Downloaded Kernel Zip File
- Select the Kernel Zip File & Swipe to Confirm Installation
- Reboot Into the System

### 🛠️ **TROUBLESHOOTING**
---

- **Bootloops:** Try Clearing Cache & Dalvik Cache
- **Kernel Panic:** Verify Device and Kernel Compatibility
- **Stuck on Recovery:** Reflash the Recovery & Reattempt Installation

### 📊 **AFTER INSTALLATION**
---

- Verify the Kernel Version & Root Access Using an Appropriate Kernel Checker or Root Checker
- Enjoy the New Kernel Features & Enhancements
"""

    # Write Release Notes to Disk
    writetxt(
        path,
        releasenotes,
    )


def main():
    # Read GitHub Actions Authentication Token
    # GH Token Itself Must Remain Unchanged Because GitHub CLI Uses it
    ghtoken = os.environ.get(
        "GH_TOKEN",
        "",
    )

    # Read Release Tag
    releasetag = os.environ.get(
        "RELEASETAG",
        "",
    )

    # Read Release Display Name
    releasename = os.environ.get(
        "RELEASENAME",
        "",
    )

    # Verify That GitHub Authentication Token is Available
    if not ghtoken:
        print(
            "⚠️ GH_TOKEN is not set"
        )
        sys.exit(1)

    # Verify That Release Tag is Available
    if not releasetag:
        print(
            "⚠️ RELEASE TAG is Not Set"
        )
        sys.exit(1)

    # Verify That Release Name is Available
    if not releasename:
        print(
            "⚠️ RELEASE NAME is Not Set"
        )
        sys.exit(1)

    # Define Release Notes File
    releasenotes = Path(
        "release-notes.md"
    )

    # Generate Release Notes
    createreleasenotes(
        releasenotes
    )

    # Collect ZIP and APK Release Assets
    assets = collectassets()

    # Prevent Creation of a Release Without Any Assets
    if not assets:
        print(
            "⚠️ No Release Assets Found"
        )
        sys.exit(1)

    # Display release information.
    print(
        f"📦 Release Tag : {releasetag}"
    )

    print(
        f"📦 Release Name: {releasename}"
    )

    print(
        "📁 Assets      :"
    )

    # Display Every Asset Selected For Upload
    for asset in assets:
        print(
            f"  - {asset}"
        )

    # Build GitHub CLI Release Command
    command = [
        "gh",
        "release",
        "create",
        releasetag,
    ]

    # Add All Release Assets to Command
    command.extend(
        str(asset)
        for asset in assets
    )

    # Add Release Title and Release Notes
    command.extend(
        [
            "--title",
            releasename,
            "--notes-file",
            str(releasenotes),
        ]
    )

    print("")
    print(
        "🚀 Creating GitHub Release..."
    )

    # Create GitHub Release Through GitHub CLI
    try:
        runcommand(
            command
        )

    except subprocess.CalledProcessError:
        print(
            "⚠️ Failed to Create "
            "GitHub Release"
        )
        sys.exit(1)

    print("")
    print(
        "🎉 GitHub Release Created Successfully"
    )


if __name__ == "__main__":
    main()
