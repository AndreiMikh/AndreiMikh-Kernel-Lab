<p align="center">
  <img src="AndreiMikh.png" alt="ANDREIMIKH KERNEL LAB" width="100%">
</p>

<br>

## 🔥 Supported Root Engines

<p align="center">

| 🟣 **SukiSU-Ultra** | 🔵 **ReSukiSU** | 🟢 **KernelSU-Next** |
|:-------------------:|:---------------:|:--------------------:|
| SUSFS Monster Mode | Balanced & Refined | Bleeding Edge |

| 🟡 **WildKSU** | 🔴 **KernelSU (Official)** | ⚙ Future Slot |
|:---------------:|:--------------------------:|:--------------:|
| Experimental Fork | Clean Upstream | Expandable |

</p>

## 🧠 Core Philosophy

<p align="center">

| ⚡ Principle | 💀 What It Means |
|:-------------|:-----------------|
| **Performance > Safety Nets** | Speed & Efficiency Come First — No Artificial Limits |
| **Automation > Manual Mess** | CI-Driven Builds — No Telegram Zip Roulette |
| **Power Users > Casual Flashers** | Built For People Who Read Logs, Not Tutorials |
| **Reproducible > Random** | Clean Commit History, Deterministic Builds |
| **Visibility > Mystery** | No Hidden Binaries, No Secret Patches, Everything Is Auditable |

</p>

> No Mystery Binaries  
> No Hidden Patches  
> Everything Is Automated — Everything Is Visible

## 💀 Built For Operators — Not Spectators

You Want Control — Not Comfort

You Want Source — Not Sketches

You Want Reproducibility — Not Random Telegram Builds

<p align="center">

| 💣 Demand | 🧠 Implementation |
|:----------|:------------------|
| Root Authority | Kernel-Level Integration |
| SUSFS Support | Auto-Detected, Patched Correctly |
| Multi-KSU Eco-System | Selectable Build Time |
| CI Automation | Deterministic GitHub Pipeline |
| Version Integrity | Offset-based, Collision-Proof Logic |
| Clean Architecture | Structured Patch Engine |

</p>

If You're Afraid Of Fastboot —

Turn Back
Why This Version Is Better

✔ Looks Intentional
✔ Feels Engineered
✔ Maintains Aggression Without Looking Childish
✔ Visually Structured
✔ Makes Your Repository Feel Serious


## ⚙️ Build Infrastructure — Engineered, Not Assembled

<p align="center">

| 🧠 Component | ⚡ Implementation |
|:-------------|:------------------|
| **CI Engine** | GitHub Actions Multi-Manifest Automation |
| **Source Handling** | Manifest-Based Upstream Syncing |
| **Version Logic** | Commit Count Injection With Fork Offsets |
| **SUSFS Integration** | Auto Header Detection + Adaptive Patching |
| **Patch System** | Official First Logic With Clean Fallback |
| **Feature Toggles** | SUSFS • ZRAM • LZ4KD • KSU META |

</p>

This Is Not Manual Patch Stacking  
This Is Structured Kernel Engineering


Flashing Custom Kernels Can:

Brick Your Device

Break SafetyNet

Void Warranty

Cause Instability

You Chose This Life


🏴 Maintained By

Andrei Mikh
Kernel Builder • Automation Addict • OnePlus Tweaker

Philippines 🇵🇭

GitHub: https://github.com/AndreiMikh

⭐ Final Note

This Repository Exists For Control!

You Control:

The Root System

The Patch Stack

The Version Logic

The Automation

No Middle Layer
No Pre-Built Dependency Chains
No Non-Sense

<!-- This is a visitor counter used to see how many people have visited my project homepage -->
<div align="center">
  <img width="0" height="0" src="https://count.getloli.com/get/@:AndreiMikh" />
</div>

# Kernel Manifest Appendix

This is an additional build manifest designed to support most OnePlus MediaTek and realme devices. It will be continuously maintained and updated as new devices and changes become available.

If you encounter any issues or discover compatibility problems, please report them so they can be addressed promptly.

## MediaTek Device Adaptation

For MediaTek-based devices, only the following repositories are required:

* `kernel`
* `vendor` (`kernel_modules_and_devicetree`)

### Example

Replace the original kernel project entry:

```xml
<project remote="origin" name="android_kernel_XXXXX_mtXXXX" path="kernel-<kernel-version>" revision="XXXX">
    <linkfile dest="kernel_platform/common" src="."/>
</project>
```

With:

```xml
<project remote="origin" name="android_kernel_XXXXX_mtXXXX" path="kernel-<kernel-version>" revision="XXXX">
    <linkfile dest="kernel/kernel-6.1" src="."/>
</project>

<project remote="origin" name="android_kernel_modules_and_devicetree_oneplus_mtXXXX" path="./" revision="XXXX"/>
```

> Replace the original `kernel_platform/common` link path with the appropriate `kernel/kernel-<version>` path for your target kernel version.

## Build Instructions

```bash
./kernel_platform/oplus/build/oplus_build_kernel.sh <cpu_codename> gki
```

### Parameters

| Parameter      | Description         |
| -------------- | ------------------- |
| CPU Code Name | Device CPU Code Name |

For All MediaTek Devices, Use:

```bash
./kernel_platform/oplus/build/oplus_build_kernel.sh unknown gki
```

In other words, set the CPU codename to `unknown` when building kernels for MediaTek-based devices.

