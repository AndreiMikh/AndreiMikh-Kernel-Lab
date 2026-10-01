#!/usr/bin/env bash

set -euo pipefail

# Base Paths
WORKSPACE="$GITHUB_WORKSPACE"
KERNELPLATFORM="$WORKSPACE/$CONFIG/kernel_platform"
KDIR="$KERNELPLATFORM/common"
PDIR="$WORKSPACE/kernel_patches/common"

usage() {
    echo "usage: $0 <all|hookless|record-version|hook|pathhide|ghost|assert-config>" >&2
    echo "       $0 verify [hookless] [hook] [pathhide] [ghost]   (default: all four)" >&2
    exit 2
}

die() {
    echo "::error::applynomount: $*" >&2
    exit 1
}

[ $# -ge 1 ] || usage
COMMAND="$1"
shift

# Detect the Kernel Version from the Kernel Makefile
resolvekv() {
    local mk="$KDIR/Makefile" v p

    [ -f "$mk" ] || die "no $mk -- $KDIR is not a kernel tree"

    v="$(sed -n 's/^VERSION[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$mk" | head -n1)"
    p="$(sed -n 's/^PATCHLEVEL[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$mk" | head -n1)"

    [ -n "$v" ] && [ -n "$p" ] || die "cannot read version/patchlevel from $mk"

    KV="$v.$p"

    case "$KV" in
    5.10 | 5.15 | 6.1 | 6.6 | 6.12) ;;
    *) die "kernel $KV is not one of 5.10 5.15 6.1 6.6 6.12 -- refusing to guess which variants it wants" ;;
    esac

    if [ -n "${KERNELVERSION:-}" ] && [ "$KERNELVERSION" != "$KV" ]; then
        die "KERNELVERSION='$KERNELVERSION' but $mk says '$KV' one of them is wrong, and the variant tables below are keyed on it"
    fi

    KERNELVERSION="$KV"
    echo "kernel version: $KV (from $mk)"
}

# Normalize Patch and Source Files
normalise() {
    if command -v dos2unix >/dev/null 2>&1; then
        dos2unix "$@" >/dev/null 2>&1 || true
    else
        local f

        for f in "$@"; do
            [ -f "$f" ] || continue

            if grep -qU "$(printf '\r')" "$f" 2>/dev/null; then
                die "$f has crlf line endings and dos2unix is not installed, it will not apply at -f0, and patch will blame the kernel tree rather than the line endings, install dos2unix, or re-checkout with the repo's gitattributes in effect"
            fi
        done
    fi
}

# Apply a Single Patch at Fuzz 0 or Detect that it is Already Applied
applypatch() {
    local p="$1" root="${2:-$KDIR}"

    [ -f "$p" ] || die "missing patch: $p"

    if patch -p1 -F0 --forward --dry-run -d "$root" <"$p" >/dev/null 2>&1; then
        patch -p1 -F0 --forward -d "$root" <"$p" >/dev/null
        echo "  applied: $(basename "$p")"
    elif patch -p1 -F0 --reverse --dry-run -d "$root" <"$p" >/dev/null 2>&1; then
        echo "  already applied: $(basename "$p")"
    else
        die "$(basename "$p") neither applies at fuzz 0 nor is already present in $root"
    fi
}

# Select and Apply Correct Kernel-Specific Patch Variant
applypatchvariant() {
    local family="$1" want="$2"
    shift 2

    local p base hits="" nhits=0 sel="" root="$KDIR"

    for p in "$@"; do
        [ -f "$p" ] || die "$family: variant file is missing: $p"

        if patch -p1 -F0 --forward --dry-run -d "$root" <"$p" >/dev/null 2>&1 ||
            patch -p1 -F0 --reverse --dry-run -d "$root" <"$p" >/dev/null 2>&1; then

            base="$(basename "$p")"
            hits="$hits $base"
            nhits=$((nhits + 1))

            [ -n "$sel" ] || sel="$p"

            if [ "$base" = "$want" ]; then
                sel="$p"
            fi
        fi
    done

    [ "$nhits" -gt 0 ] ||
        die "$family: no variant applies at fuzz 0 on $KERNELVERSION (tried: $*)"

    if [ "$want" = "-" ]; then
        [ "$nhits" -eq 1 ] ||
            die "$family: $nhits variants apply on $KERNELVERSION ($hits ) and the table pins none... pin one, or refit them so exactly one claims this tree -- picking the first is how a guard lands in the wrong function"
    else
        case " $hits " in
        *" $want "*) ;;
        *) die "$family: pinned variant '$want' does not apply at fuzz 0 on $KERNELVERSION; these do:$hits, the variants do not carry the same hunks, so falling back would silently drop coverage... refit '$want' to this tree instead" ;;
        esac

        [ "$nhits" -eq 1 ] || echo "  $family: '$want' pinned (also applicable:$hits )"
    fi

    applypatch "$sel" "$root"
}

# Require a Fixed String to Exist
has() {
    grep -qF -- "$2" "$1" || die "$3"
}

# Require a Fixed String to be Absent
hasnt() {
    if grep -qF -- "$2" "$1" 2>/dev/null; then
        die "$3"
    fi

    return 0
}

# Verify that an Object is Linked Through Obj-y
objy() {
    local esc="${2//./[.]}"

    grep -qE "^obj-y[[:space:]]*\+=[[:space:]]*$esc([[:space:]]|\$)" "$1" ||
        die "$3: no '^obj-y += $2' line in $1 -- the object would never be linked into the kernel"
}

# Locate the Active Kernel Configuration
findconfig() {
    local c

    for c in "${KERNEL_CONFIG_FILE:-}" \
        "$KDIR/out/.config" \
        "$KDIR/.config" \
        "${OUT_DIR:-}/.config"; do

        if [ -n "$c" ] && [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done

    return 1
}

CONFIGSTRICT=0

# Verify a Required Kernel Configuration
assertconfig() {
    local sym="$1" why="$2" cfg

    if cfg="$(findconfig)"; then
        grep -qx "$sym=y" "$cfg" ||
            die "$sym is not set in $cfg -- $why"

        echo "  config: $sym=y in $cfg"
    elif [ "$CONFIGSTRICT" = 1 ]; then
        die "no config found (tried kernelconfigfile, $KDIR/out/.config, $KDIR/.config) -- cannot assert $sym"
    else
        echo "  $sym: not verifiable yet (no .config at apply time; see assertconfig)"
    fi
}

# Verify Hookless VFS Integration
verifyhookless() {
    [ -f "$KDIR/fs/nomount.c" ] ||
        die "hookless: fs/nomount.c missing"

    [ -f "$KDIR/fs/nomount.h" ] ||
        die "hookless: fs/nomount.h missing"

    has "$KDIR/fs/Kconfig" \
        'config NOMOUNT' \
        "hookless: fs/Kconfig edit missing"

    has "$KDIR/fs/Makefile" \
        'obj-$(CONFIG_NOMOUNT) += nomount.o' \
        "hookless: fs/Makefile edit missing"

    grep -qE 'vfs_map_meta_override|nomount_spoof_mmap_metadata' \
        "$KDIR/fs/proc/task_mmu.c" ||
        die "hookless: taskmmu.c hook missing"

    grep -qx 'CONFIG_NOMOUNT=y' "$(defconfigpath)" ||
        die "hookless: confignomount=y is not in $(defconfigpath)"

    assertconfig CONFIG_NOMOUNT \
        "the engine is behind confignomount; without it fs/nomount.o is not built at all and every hookless hook is absent"

    echo "_hookless: verified"
}

# Check that SELinux Guards are Placed After AVCHasPerm()
awkplacement() {
    awk '
        /^static (int|noinline int) selinux_[a-z_]+\(/ { fn = $0; avc = 0 }
        /avc_has_perm/                                 { avc = 1 }
        /:ksu:/ { if (!avc) { print "EARLY " fn > "/dev/stderr"; bad = 1 } }
        END { exit bad ? 1 : 0 }
    ' "$1"
}

# Verify SELinux Hooks and KernelSU Integration
verifyhook() {
    has "$KDIR/security/selinux/selinuxfs.c" \
        'sel_ctx_hidden' \
        "hook: selinuxfs.c gate missing"

    has "$KDIR/security/selinux/selinuxfs.c" \
        'sel_hidden_bytes' \
        "hook: selinuxfs.c reply filter missing"

    has "$KDIR/security/selinux/hooks.c" \
        ':ksu:' \
        "hook: hooks.c attr guard missing"

    infn "$KDIR/security/selinux/hooks.c" \
        '^static int selinux_inode_setxattr' \
        ':ksu:' \
        "hook: selinuxinodesetxattr() has no hidden-type guard -- setxattr(security.selinux) then tells an unprivileged caller apart 'type not in policy' (-einval) from 'type exists, denied' (-eacces), which is a probe for the hidden types"

    case "$KERNELVERSION" in
    6.12)
        infn "$KDIR/security/selinux/hooks.c" \
            '^static int selinux_lsm_setattr' \
            ':ksu:' \
            "hook: selinuxlsmsetattr() has no hidden-type guard"
        ;;
    *)
        infn "$KDIR/security/selinux/hooks.c" \
            '^static int selinux_setprocattr' \
            ':ksu:' \
            "hook: selinuxsetprocattr() has no hidden-type guard"
        ;;
    esac

    has "$KDIR/security/selinux/avc.c" \
        ':ksu:' \
        "hook: avc.c denial filter missing"

    has "$KDIR/security/selinux/avc.c" \
        'current_uid()' \
        "hook: avc.c filter has lost its uid gate"

    has "$KDIR/security/selinux/Makefile" \
        'selinuxfs.o' \
        "hook: selinuxfs.o is not in security/selinux/makefile"

    # Verify All SELinux Write Nodes
    local w

    for w in sel_write_context sel_write_validatetrans sel_write_access \
             sel_write_create sel_write_relabel sel_write_user sel_write_member; do

        infn "$KDIR/security/selinux/selinuxfs.c" \
            "^static ssize_t $w\(" \
            'sel_ctx_hidden' \
            "hook: $w() has no selctxhidden() gate -- that write node is an open hidden-type probe"
    done

    # Ensure Hidden-Type List Matches Across SELinux Files
    local nfs nhooks navc

    nfs=$(grep -o '":[a-z_]*:"' "$KDIR/security/selinux/selinuxfs.c" |
        sort -u | tr '\n' ' ')

    nhooks=$(grep -o '":[a-z_]*:"' "$KDIR/security/selinux/hooks.c" |
        sort -u | tr '\n' ' ')

    navc=$(grep -o '":[a-z_]*:"' "$KDIR/security/selinux/avc.c" |
        sort -u | tr '\n' ' ')

    [ -n "$nfs" ] ||
        die "hook: no hiddentype list found in selinuxfs.c"

    [ "$nfs" = "$nhooks" ] ||
        die "hook: the hidden-type list differs between selinuxfs.c [$nfs] and hooks.c [$nhooks] a type covered in one file and not another leaves that probe open, and nothing else would have said so"

    [ "$nfs" = "$navc" ] ||
        die "hook: the hidden-type list differs between selinuxfs.c [$nfs] and avc.c [$navc]"

    echo "hook: type list mirrored in 3 files: $nfs"

    awkplacement "$KDIR/security/selinux/hooks.c" ||
        die "hook: a hidden-type guard in hooks.c sits BEFORE the avchasperm() of its own function, that inversion turns the cloak into a one-syscall root oracle -- see common/hook/readme.md"

    [ -d "$KERNELPLATFORM/KernelSU" ] ||
        die "hook: $KERNELPLATFORM/KernelSU does not exist, so fixselinuxseqno cannot be verified"

    [ -f "$KERNELPLATFORM/KernelSU/kernel/selinux/rules.c" ] ||
        die "hook: $KERNELPLATFORM/KernelSU/kernel/selinux/rules.c does not exist, if this ksu fork keeps rules.c elsewhere, fixselinuxseqno.patch did not land and /sys/fs/selinux/status still reports policyload=0"

    hasnt "$KERNELPLATFORM/KernelSU/kernel/selinux/rules.c" \
        'selinux_status_update_policyload' \
        "hook: fixselinuxseqno did not land -- ksu still writes policyload=0 to /sys/fs/selinux/status"

    has "$KERNELPLATFORM/KernelSU/kernel/selinux/rules.c" \
        'selnl_notify_policyload' \
        "hook: selnlnotifypolicyload was removed -- see readme, gating it is a documented bootloop risk"

    assertconfig CONFIG_SECURITY_SELINUX \
        "every hook guard lives in security/selinux, which is built only under config security selinux -- without it the whole family is dead code"

    echo "_hook: verified"
}

# Verify Pathhide Integration
verifypathhide() {
    [ -f "$KDIR/fs/pathhide.c" ] ||
        die "_pathhide: fs/pathhide.c missing"

    [ -f "$KDIR/fs/pathhide.h" ] ||
        die "_pathhide: fs/pathhide.h missing"

    objy "$KDIR/fs/Makefile" \
        'pathhide.o' \
        "_pathhide"

    has "$KDIR/fs/proc/task_mmu.c" \
        'pathhide_match_file' \
        "pathhide: maps/smaps guards missing from taskmmu.c"

    has "$KDIR/fs/proc/base.c" \
        'pathhide_match_file' \
        "pathhide: map_files guards missing from base.c"

    infn "$KDIR/fs/proc/task_mmu.c" \
        '^static int pagemap_pmd_range' \
        'pathhide_match_file' \
        "pathhide: the pagemap guard is not inside pagemappmdrange() -- resident pages sitting at an address maps does not list is the whole gap, stated outright"

    infn "$KDIR/mm/mincore.c" \
        '^static long do_mincore' \
        'pathhide_match_file' \
        "pathhide: the mincore(2) guard is not inside domincore() it has to sit before candomincore(), which answers resident for everything by memset for a file the caller cannot write"

    infn "$KDIR/fs/proc/task_mmu.c" \
        '^void task_mem' \
        'pathhide_hidden_vm_pages' \
        "pathhide: the vmsize/vmpeak deduction is not inside taskmem() -- summing the visible maps ranges against VmSize is exact arithmetic, which is what makes it worth closing while rss is deliberately left alone"

    infn "$KDIR/fs/proc/task_mmu.c" \
        '^unsigned long task_statm' \
        'pathhide_hidden_vm_pages' \
        "pathhide: the statm size deduction is not inside taskstatm()"

    case "$KERNELVERSION" in
    6.12)
        infn "$KDIR/fs/proc/task_mmu.c" \
            '^static int pagemap_scan_test_walk' \
            'pathhide_match_file' \
            "pathhide: the pagemapscan guard is not inside pagemap-scan-test-walk() -- the ioctl is a second residency window onto the same vma"
        ;;
    esac

    hasnt "$KDIR/fs/proc/fd.c" \
        'pathhide' \
        "pathhide: fs/proc/fd.c is patched again, the fd half was removed because a hidden fd stays allocated -- fcntl(n, f-getfd) succeeds where /proc/self/fd/n answers enoent, which is unconditional and never true on stock"

    echo "pathhide: verified (no config symbol by design -- see readme)"
}

# Check that a Pattern Exists Inside a Specific Function
infn() {
    local seg

    seg="$(awk "/$2/,/^}/" "$1" 2>/dev/null)" || true

    case "$seg" in
    *"$3"*) return 0 ;;
    esac

    die "$4"
}

# Verify Ghost Integration
verifyghost() {
    local n

    [ -f "$KDIR/fs/proc/ghost.c" ] ||
        die "ghost: fs/proc/ghost.c missing"

    [ -f "$KDIR/fs/proc/ghost.h" ] ||
        die "ghost: fs/proc/ghost.h missing"

    objy "$KDIR/fs/proc/Makefile" \
        'ghost.o' \
        "ghost"

    infn "$KDIR/fs/namei.c" \
        '^static int do_o_path' \
        'ghost_hidden_path(&path))' \
        "ghost: the o-path guard is not inside do-o-path()"

    infn "$KDIR/fs/namei.c" \
        '^static int do_open' \
        'unlikely(ghost_hidden_path(&nd->path))' \
        "ghost: the open(2) guard is not inside do-open() it is unconditional now: any open of a hidden path that did not just create it answers enoent, so plain o-rdonly and o-creat agree with o-path instead of handing back an fd -- and, with o-trunc, emptying the file"

    infn "$KDIR/fs/namei.c" \
        '^static int path_lookupat' \
        'unlikely(err == -ENOTDIR)' \
        "ghost: the enotdir guard is not inside path-lookupat() it applies at fuzz 0 inside path-parentat() too -- that is the bug ghost_notdir.patch's header documents, and this is the assertion that catches it"

    infn "$KDIR/fs/namei.c" \
        '^static int path_parentat' \
        'unlikely(err == -ENOTDIR)' \
        "ghost: the enotdir guard is not inside path-parentat() -- mkdirat/mknodat/symlinkat/unlinkat/renameat reach -enotdir through there and through nothing else this patch set guards"

    infn "$KDIR/fs/namei.c" \
        '^static struct dentry \*filename_create' \
        'error = err2 ? err2 : -EACCES' \
        "ghost: the create guard is not inside filename-create(), or it went back to masking only on a read-only mount, mkdirat/mknodat/symlinkat/linkat all reach -eexist through here before may-create() runs, so a hidden name has to answer what an absent one would: err2 when the mount is read-only, -eacces otherwise"

    infn "$KDIR/fs/namei.c" \
        '^(static )?int do_linkat' \
        'ghost_hidden_path(&old_path)' \
        "ghost: the link(2) guard is not inside do-linkat()"

    infn "$KDIR/fs/open.c" \
        '^int do_fchownat' \
        'ghost_hidden_path(&path))' \
        "ghost: the chown(2) guard is not inside do-fchownat()"

    infn "$KDIR/fs/stat.c" \
        '^static int do_readlinkat' \
        'ghost_hidden_path(&path))' \
        "ghost: the readlink(2) guard is not inside do-readlinkat() -- it returns the hidden symlink's target where an absent path answers enoent"

    infn "$KDIR/fs/open.c" \
        '^static long do_faccessat' \
        'unlikely(ghost_hidden_path(&path))' \
        "ghost: the access(2) guard is not inside do-faccessat(), or it is gated on the mode again, it used to fire only for may write, so access(f-ok) and access(r-ok) reported the hidden path as present while access(W_OK) answered enoent -- one syscall, two answers, and only one of them what an absent path gives"

    infn "$KDIR/fs/stat.c" \
        '^(static )?int vfs_statx' \
        'ghost_hidden_path(&path))' \
        "ghost: the stat(2) family guard is not inside vfs-statx() -- lstat/statx/newfstatat read the hidden object's real metadata where every other ghost surface answers enoent, this is the whole family through one choke point on all five trees; there is no version where it is optional"

    infn "$KDIR/fs/open.c" \
        'do_fchmodat' \
        'ghost_hidden_path(&path))' \
        "ghost: the chmod(2) guard is not inside do-fchmodat()"

    infn "$KDIR/fs/open.c" \
        '^(long|int) do_sys_truncate' \
        'ghost_hidden_path(&path))' \
        "ghost: the truncate(2) guard is not inside do-sys-truncate()"

    infn "$KDIR/fs/utimes.c" \
        '^(static )?(long|int) do_utimes_path' \
        'ghost_hidden_path(&path))' \
        "ghost: the utimensat(2) guard is not inside do-utimes-path()"

    # Verify All XATTRS Wrappers
    local w

    for w in path_setxattr path_getxattr path_listxattr path_removexattr; do
        infn "$KDIR/fs/xattr.c" \
            "^static (ssize_t|int) $w\(" \
            'ghost_hidden_path(&path))' \
            "ghost: fs/xattr.c has no guard inside $w() -- the xattr family is all four wrappers or none"
    done

    n=$(grep -c 'ghost_hidden_path' "$KDIR/fs/xattr.c" 2>/dev/null || echo 0)

    [ "$n" -eq 8 ] ||
        die "ghost: fs/xattr.c has $n ghost-hidden-path references, expected 8 (one extern + one call per wrapper)"

    infn "$KDIR/fs/namei.c" \
        '^int do_renameat2' \
        'struct path gpath = { .mnt = old_path.mnt, .dentry = old_dentry }' \
        "ghost: the rename(2) source guard is not inside do-renameat2() -- a hidden source renames like any other file, which both answers where an absent one says enoent and moves the object out of the path that hides it"

    if awk '/^int do_renameat2/,/^}/' "$KDIR/fs/namei.c" |
        grep -q 'err2'; then

        die "ghost: the create guard landed in do_renameat2, not filename create, the rename guard belongs there; the err2/-eacces one does not"
    fi

    hasnt "$KDIR/fs/proc/ghost.c" \
        'proc_create' \
        "ghost: ghost.c owns a /proc node -- a file whose job is concealing files must not own a name no stock kernel has"

    echo "ghost: verified (no config symbol by design -- see readme)"
}

# Return Selected DefConfig Path
defconfigpath() {
    echo "$KDIR/arch/arm64/configs/${NOMOUNT_DEFCONFIG:-gki_defconfig}"
}

# Clone NoMount and Apply Hookless VFS Integration
dohookless() {
    echo "::group::apply nomount (hookless vfs) patch"

    local NMSRC="$WORKSPACE/nomount_hookless" NMPATCH DEFCONFIG

    DEFCONFIG="$(defconfigpath)"

    [ -f "$DEFCONFIG" ] ||
        die "defconfig $DEFCONFIG does not exist... refusing to create it -- a defconfig invented here is not the one the build reads, set nomount-defconfig to the fragment this build actually uses"

    rm -rf "$NMSRC"

    git clone --depth 1 -b "${NMREF:-main}" \
        https://github.com/Bouteillepleine/NoMount-Suite.git \
        "$NMSRC" ||
        die "could not clone the NoMount engine at ref '${NMREF:-main}' from bouteillepleine/nomount-suite, it was bouteillepleine/nomount@suite before, and kbuild@hookless before that; if something still passes NMREF=suite or =hookless, neither exists in this repo -- use 'main'"

    NMSHA="$(git -C "$NMSRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    export NMSHA

    echo "engine: bouteillepleine/nomount-suite@${NMREF:-main} = $NMSHA"

    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "NMENGINEREF=${NMREF:-main}" >>"$GITHUB_ENV"
        echo "NMENGINESHA=$NMSHA" >>"$GITHUB_ENV"
    fi

    case "${NMREF:-main}" in
    main | master)
        echo "  note: nomount ref is a moving branch, so this build is not reproducible from kernelpatches alone. pass nomount ref = <tag> to pin it"
        ;;
    esac

    # Locate Generic Integration Patch, then the Version-Specific Fallback
    NMPATCH="$NMSRC/hookless/patches/nomount_kernel_integration.patch"

    if [ ! -f "$NMPATCH" ]; then
        NMPATCH="$NMSRC/hookless/patches/nomount_${KERNELVERSION}_kernel_integration.patch"

        [ -f "$NMPATCH" ] ||
            die "no hookless NoMount patch for $KERNELVERSION: neither\
 $NMSRC/hookless/patches/nomount_kernel_integration.patch nor $NMPATCH exists"
    fi

    echo "hookless integration patch: ${NMPATCH##*/}"

    # Install NoMount Source Files
    rm -f "$KDIR/fs/nomount.c" "$KDIR/fs/nomount.h"

    cp "$NMSRC/hookless/src/nomount.c" "$KDIR/fs/nomount.c"
    cp "$NMSRC/hookless/src/nomount.h" "$KDIR/fs/nomount.h"

    # Apply at Fuzz 0; Allow Fuzz 1 Only as a Fallback
    if patch -p1 -F0 --forward --dry-run \
        -d "$KDIR" <"$NMPATCH" >/dev/null 2>&1; then

        patch -p1 -F0 --forward \
            -d "$KDIR" <"$NMPATCH" >/dev/null ||
            die "nomount hookless patch dry-ran clean at -F0 and then failed to apply for $KERNELVERSION"

        echo "  hookless integration: applied at fuzz 0"

    elif patch -p1 -F0 --reverse --dry-run \
        -d "$KDIR" <"$NMPATCH" >/dev/null 2>&1; then

        echo "  hookless integration: already applied"

    else
        echo "::warning::hookless integration patch does not apply at fuzz 0 on $KERNELVERSION; retrying at fuzz 1... a fuzzed hunk can land a hook in the wrong function -- check fs/proc/task_mmu.c and fs/makefile in the build output before trusting this kernel"

        patch -p1 --forward --fuzz=1 \
            -d "$KDIR" <"$NMPATCH" ||
            die "momount hookless patch failed to apply for $KERNELVERSION, at fuzz 0 and at fuzz 1"
    fi

    sed -i '/^CONFIG_NOMOUNT=/d' "$DEFCONFIG"
    echo "CONFIG_NOMOUNT=y" >>"$DEFCONFIG"

    verifyhookless

    echo "::endgroup::"
}

# Record NoMount Module Version
dorecordversion() {
    local NMHDR="$KDIR/fs/nomount.h" NMVER=""

    if [ -f "$NMHDR" ]; then
        NMVER="$(sed -n 's/^#define[[:space:]]\+NM_MODULE_VERSION[[:space:]]\+"\([^"]*\)".*/\1/p' "$NMHDR" | head -n1)"
    fi

    echo "NMVER=${NMVER:-unknown}" >>"$GITHUB_ENV"
    echo "nomount version: ${NMVER:-unknown}"
}

# Apply SELinux Oracle Patches
dohook() {
    echo "::group::apply selinux oracle (hook) patches"

    normalise "$PDIR/_hook"/*.patch

    local REQSFS REQATTR REQAUDIT

    case "$KERNELVERSION" in
    6.6 | 6.12)
        REQSFS=hide_selinux_selinuxfs_6_12.patch
        REQAUDIT=quiet_selinux_audit.patch
        ;;
    5.10 | 5.15 | 6.1)
        REQSFS=hide_selinux_selinuxfs_5_10.patch
        REQAUDIT=quiet_selinux_audit_legacy.patch
        ;;
    esac

    case "$KERNELVERSION" in
    6.12) REQATTR=hide_selinux_attr_6_12.patch ;;
    6.6)  REQATTR=hide_selinux_attr_6_6.patch ;;
    5.10 | 5.15 | 6.1) REQATTR=hide_selinux_attr_5_10.patch ;;
    *) REQATTR=hide_selinux_attr.patch ;;
    esac

    applypatchvariant selinuxfs "$REQSFS" \
        "$PDIR/_hook/hide_selinux_selinuxfs_6_12.patch" \
        "$PDIR/_hook/hide_selinux_selinuxfs_5_10.patch"

    applypatchvariant attr "$REQATTR" \
        "$PDIR/_hook/hide_selinux_attr_6_12.patch" \
        "$PDIR/_hook/hide_selinux_attr_6_6.patch" \
        "$PDIR/_hook/hide_selinux_attr_5_10.patch" \
        "$PDIR/_hook/hide_selinux_attr.patch"

    applypatchvariant avc-audit "$REQAUDIT" \
        "$PDIR/_hook/quiet_selinux_audit.patch" \
        "$PDIR/_hook/quiet_selinux_audit_legacy.patch"

    applypatch \
        "$PDIR/_hook/fix_selinux_seqno.patch" \
        "$KERNELPLATFORM/KernelSU"

    verifyhook

    echo "::endgroup::"
}

# Install and Integrate Pathhide
dopathhide() {
    echo "::group::apply pathhide (maps cloak)"

    rm -f "$KDIR/fs/pathhide.c" "$KDIR/fs/pathhide.h"

    cp "$PDIR/_pathhide/pathhide.c" "$KDIR/fs/pathhide.c"
    cp "$PDIR/_pathhide/pathhide.h" "$KDIR/fs/pathhide.h"

    normalise "$KDIR/fs/pathhide.c" "$KDIR/fs/pathhide.h"
    normalise "$PDIR/_pathhide"/*.patch

    applypatch "$PDIR/_pathhide/pathhide_${KERNELVERSION}_integration.patch"
    applypatch "$PDIR/_pathhide/pathhide_mapfiles_${KERNELVERSION}_integration.patch"

    # Detect Correct Pathhide Variants from Source Layout
    local REQPAGEMAP REQMINCORE REQACCT

    if grep -q 'pagemap_scan_test_walk' "$KDIR/fs/proc/task_mmu.c"; then
        REQPAGEMAP=pathhide_pagemap_6.12_integration.patch
    elif awk '/^static int pagemap_pmd_range/,/^}/' "$KDIR/fs/proc/task_mmu.c" |
        grep -q 'bool migration'; then
        REQPAGEMAP=pathhide_pagemap_5.10_integration.patch
    else
        REQPAGEMAP=pathhide_pagemap_6.6_integration.patch
    fi

    if grep -q 'vma_lookup(current->mm, addr)' "$KDIR/mm/mincore.c"; then
        REQMINCORE=pathhide_mincore_6.12_integration.patch
    else
        REQMINCORE=pathhide_mincore_5.10_integration.patch
    fi

    if grep -q '__page_size_count(mm->total_vm)' "$KDIR/fs/proc/task_mmu.c"; then
        REQACCT=pathhide_accounting_pgcompat_integration.patch
    elif grep -q 'get_mm_counter_sum(mm, MM_ANONPAGES)' "$KDIR/fs/proc/task_mmu.c"; then
        REQACCT=pathhide_accounting_6.6_integration.patch
    else
        REQACCT=pathhide_accounting_integration.patch
    fi

    applypatchvariant pathhide-pagemap "$REQPAGEMAP" \
        "$PDIR/_pathhide/pathhide_pagemap_6.12_integration.patch" \
        "$PDIR/_pathhide/pathhide_pagemap_6.6_integration.patch" \
        "$PDIR/_pathhide/pathhide_pagemap_5.10_integration.patch"

    applypatchvariant pathhide-mincore "$REQMINCORE" \
        "$PDIR/_pathhide/pathhide_mincore_6.12_integration.patch" \
        "$PDIR/_pathhide/pathhide_mincore_5.10_integration.patch"

    applypatchvariant pathhide-accounting "$REQACCT" \
        "$PDIR/_pathhide/pathhide_accounting_6.6_integration.patch" \
        "$PDIR/_pathhide/pathhide_accounting_pgcompat_integration.patch" \
        "$PDIR/_pathhide/pathhide_accounting_integration.patch"

    grep -qE '^obj-y[[:space:]]*\+=.*pathhide\.o' \
        "$KDIR/fs/Makefile" ||
        echo 'obj-y += pathhide.o' >>"$KDIR/fs/Makefile"

    verifypathhide

    echo "::endgroup::"
}

# Install and Integrate Ghost
doghost() {
    echo "::group::apply ghost (o-path / *xattr / link / enotdir existence cloak)"

    rm -f "$KDIR/fs/proc/ghost.c" "$KDIR/fs/proc/ghost.h"

    cp "$PDIR/_ghost/ghost.c" "$KDIR/fs/proc/ghost.c"
    cp "$PDIR/_ghost/ghost.h" "$KDIR/fs/proc/ghost.h"

    normalise "$KDIR/fs/proc/ghost.c" "$KDIR/fs/proc/ghost.h"
    normalise "$PDIR/_ghost"/*.patch

    local REQXATTR REQLINKAT REQCHMOD

    case "$KERNELVERSION" in
    6.12 | 6.6)
        REQXATTR=ghost_xattr_6_12.patch
        REQLINKAT=ghost_linkat_5_15.patch
        REQCHMOD=ghost_chmod.patch
        ;;
    6.1 | 5.15)
        REQXATTR=ghost_xattr_5_15.patch
        REQLINKAT=ghost_linkat_5_15.patch
        REQCHMOD=ghost_chmod_5_10.patch
        ;;
    5.10)
        REQXATTR=ghost_xattr.patch
        REQLINKAT=ghost_linkat.patch
        REQCHMOD=ghost_chmod_5_10.patch
        ;;
    esac

    applypatch "$PDIR/_ghost/ghost_o_path.patch"

    applypatchvariant ghost-xattr "$REQXATTR" \
        "$PDIR/_ghost/ghost_xattr_6_12.patch" \
        "$PDIR/_ghost/ghost_xattr_5_15.patch" \
        "$PDIR/_ghost/ghost_xattr.patch"

    applypatchvariant ghost-linkat "$REQLINKAT" \
        "$PDIR/_ghost/ghost_linkat_5_15.patch" \
        "$PDIR/_ghost/ghost_linkat.patch"

    applypatch "$PDIR/_ghost/ghost_notdir.patch"
    applypatch "$PDIR/_ghost/ghost_truncate.patch"
    applypatch "$PDIR/_ghost/ghost_utimes.patch"

    applypatchvariant ghost-chmod "$REQCHMOD" \
        "$PDIR/_ghost/ghost_chmod.patch" \
        "$PDIR/_ghost/ghost_chmod_5_10.patch"

    applypatch "$PDIR/_ghost/ghost_chown.patch"
    applypatch "$PDIR/_ghost/ghost_access.patch"
    applypatch "$PDIR/_ghost/ghost_open.patch"
    applypatch "$PDIR/_ghost/ghost_create.patch"
    applypatch "$PDIR/_ghost/ghost_build_integration.patch"

    local REQSTATX

    case "$KERNELVERSION" in
    6.12) REQSTATX=ghost_statx_6_12.patch ;;
    6.6 | 6.1) REQSTATX=ghost_statx_6_1.patch ;;
    5.15 | 5.10) REQSTATX=ghost_statx_5_10.patch ;;
    esac

    applypatchvariant ghost-statx "$REQSTATX" \
        "$PDIR/_ghost/ghost_statx_6_12.patch" \
        "$PDIR/_ghost/ghost_statx_6_1.patch" \
        "$PDIR/_ghost/ghost_statx_5_10.patch"

    local REQREADLINK

    case "$KERNELVERSION" in
    6.12) REQREADLINK=ghost_readlink_6_12.patch ;;
    *) REQREADLINK=ghost_readlink_5_10.patch ;;
    esac

    applypatchvariant ghost-readlink "$REQREADLINK" \
        "$PDIR/_ghost/ghost_readlink_6_12.patch" \
        "$PDIR/_ghost/ghost_readlink_5_10.patch"

    local REQRENAME

    case "$KERNELVERSION" in
    5.10) REQRENAME=ghost_rename_5_10.patch ;;
    *) REQRENAME=ghost_rename_5_15.patch ;;
    esac

    applypatchvariant ghost-rename "$REQRENAME" \
        "$PDIR/_ghost/ghost_rename_5_10.patch" \
        "$PDIR/_ghost/ghost_rename_5_15.patch"

    verifyghost

    echo "::endgroup::"
}

# Verify Selected NoMount Components
doverify() {
    local f

    [ $# -gt 0 ] || set -- hookless hook pathhide ghost

    echo "::group::verify the NoMount stack landed"

    for f in "$@"; do
        case "$f" in
        hookless) verifyhookless ;;
        hook) verifyhook ;;
        pathhide) verifypathhide ;;
        ghost) verifyghost ;;
        *) die "verify: unknown family '$f'" ;;
        esac
    done

    echo "verified: $*"
    echo "::endgroup::"
}

# Command Dispatcher
case "$COMMAND" in
all)
    resolvekv
    dohookless

    if [ -n "${GITHUB_ENV:-}" ]; then
        dorecordversion
    fi

    dohook
    dopathhide
    doghost
    doverify hookless hook pathhide ghost
    ;;
hookless)
    resolvekv
    dohookless
    ;;
record-version)
    dorecordversion
    ;;
hook)
    resolvekv
    dohook
    ;;
pathhide)
    resolvekv
    dopathhide
    ;;
ghost)
    resolvekv
    doghost
    ;;
verify)
    resolvekv
    doverify "$@"
    ;;
assert-config)
    CONFIGSTRICT=1

    assertconfig CONFIG_NOMOUNT \
        "the engine is behind config-nomount; without it fs/nomount.o is not built at all"

    assertconfig CONFIG_SECURITY_SELINUX \
        "every hook guard is compiled only under config-security-selinux"
    ;;

*)
    usage
    ;;
esac
