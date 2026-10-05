#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 <all|hookless|record-version|hook|pathhide|ghost|assert-config>" >&2
    echo "       $0 verify [hookless] [hook] [pathhide] [ghost]   (default: all four)" >&2
    exit 2
}

die() { echo "::error::apply_nomount_stack: $*" >&2; exit 1; }

need() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || die "$v is not set"
    done
}

resolve_ksu() {
    need KERNELPLATFORM

    if [ -d "$KERNELPLATFORM/KernelSU" ]; then
        KSUFOLDER="$KERNELPLATFORM/KernelSU"
    elif [ -d "$KERNELPLATFORM/KernelSU-Next" ]; then
        KSUFOLDER="$KERNELPLATFORM/KernelSU-Next"
    else
        die "neither $KERNELPLATFORM/KernelSU nor $KERNELPLATFORM/KernelSU-Next exists"
    fi

    export KSUFOLDER
    echo "KSU tree: $KSUFOLDER"
}

[ $# -ge 1 ] || usage
CMD="$1"
shift

resolve_kv() {
    local mk="$COMMONKERNELFOLDER/Makefile" v p
    [ -f "$mk" ] || die "no $mk -- COMMONKERNELFOLDER is not a kernel tree"
    v="$(sed -n 's/^VERSION[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$mk" | head -n1)"
    p="$(sed -n 's/^PATCHLEVEL[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$mk" | head -n1)"
    [ -n "$v" ] && [ -n "$p" ] || die "cannot read VERSION/PATCHLEVEL from $mk"
    KV="$v.$p"
    case "$KV" in
    5.10 | 5.15 | 6.1 | 6.6 | 6.12) ;;
    *) die "kernel $KV is not one of 5.10 5.15 6.1 6.6 6.12 -- refusing to guess which variants it wants" ;;
    esac
    if [ -n "${KERNELVERSION:-}" ] && [ "$KERNELVERSION" != "$KV" ]; then
        die "KERNELVERSION='$KERNELVERSION' but $mk says '$KV'. One of them is wrong, and the variant tables below are keyed on it."
    fi
    KERNELVERSION="$KV"
    echo "kernel version: $KV (from $mk)"
}

normalise() {
    if command -v dos2unix >/dev/null 2>&1; then
        dos2unix "$@" >/dev/null 2>&1 || true
    else
        local f
        for f in "$@"; do
            [ -f "$f" ] || continue
            if grep -qU "$(printf '\r')" "$f" 2>/dev/null; then
                die "$f has CRLF line endings and dos2unix is not installed. It will not apply at -F0, and patch will blame the kernel tree rather than the line endings. Install dos2unix, or re-checkout with the repo's .gitattributes in effect."
            fi
        done
    fi
}

apply_or_die() {
    local p="$1" root="${2:-$COMMONKERNELFOLDER}"
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

apply_first_of() {
    local family="$1" want="$2"
    shift 2
    local p base hits="" nhits=0 sel="" root="$COMMONKERNELFOLDER"
    for p in "$@"; do
        [ -f "$p" ] || die "$family: variant file is missing: $p"
        if patch -p1 -F0 --forward --dry-run -d "$root" <"$p" >/dev/null 2>&1 ||
            patch -p1 -F0 --reverse --dry-run -d "$root" <"$p" >/dev/null 2>&1; then
            base="$(basename "$p")"
            hits="$hits $base"
            nhits=$((nhits + 1))
            [ -n "$sel" ] || sel="$p"
            if [ "$base" = "$want" ]; then sel="$p"; fi
        fi
    done
    [ "$nhits" -gt 0 ] || die "$family: no variant applies at fuzz 0 on $KERNELVERSION (tried: $*)"
    if [ "$want" = "-" ]; then
        [ "$nhits" -eq 1 ] || die "$family: $nhits variants apply on $KERNELVERSION ($hits ) and the table pins none. Pin one, or refit them so exactly one claims this tree -- picking the first is how a guard lands in the wrong function."
    else
        case " $hits " in
        *" $want "*) ;;
        *) die "$family: pinned variant '$want' does not apply at fuzz 0 on $KERNELVERSION; these do:$hits. The variants do not carry the same hunks, so falling back would silently drop coverage. Refit '$want' to this tree instead." ;;
        esac
        [ "$nhits" -eq 1 ] || echo "  $family: '$want' pinned (also applicable:$hits )"
    fi
    apply_or_die "$sel" "$root"
}

has() { # has <file> <fixed-string>
    grep -qF -- "$2" "$1" || die "$3"
}

hasnt() { # hasnt <file> <fixed-string>
    if grep -qF -- "$2" "$1" 2>/dev/null; then die "$3"; fi
    return 0
}

objy() { # objy <makefile> <object> <what>
    local esc="${2//./[.]}"
    grep -qE "^obj-y[[:space:]]*\+=[[:space:]]*$esc([[:space:]]|\$)" "$1" ||
        die "$3: no '^obj-y += $2' line in $1 -- the object would never be linked into the kernel"
}

find_config() {
    local c
    for c in "${KERNEL_CONFIG_FILE:-}" "$COMMONKERNELFOLDER/out/.config" \
        "$COMMONKERNELFOLDER/.config" "${OUT_DIR:-}/.config"; do
        if [ -n "$c" ] && [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

CONFIG_STRICT=0
assert_config() {
    local sym="$1" why="$2" cfg
    if cfg="$(find_config)"; then
        grep -qx "$sym=y" "$cfg" ||
            die "$sym is not set in $cfg -- $why"
        echo "  config: $sym=y in $cfg"
    elif [ "$CONFIG_STRICT" = 1 ]; then
        die "no .config found (tried KERNEL_CONFIG_FILE, $COMMONKERNELFOLDER/out/.config, $COMMONKERNELFOLDER/.config) -- cannot assert $sym"
    else
        # post-defconfig check against a generated config
        echo "  $sym: not verifiable yet (no .config at apply time; see assert-config)"
    fi
}

verify_hookless() {
    local d="$COMMONKERNELFOLDER"
    [ -f "$d/fs/nomount.c" ] || die "_hookless: fs/nomount.c missing"
    [ -f "$d/fs/nomount.h" ] || die "_hookless: fs/nomount.h missing"
    has "$d/fs/Kconfig" 'config NOMOUNT' "_hookless: fs/Kconfig edit missing"
    has "$d/fs/Makefile" 'obj-$(CONFIG_NOMOUNT) += nomount.o' "_hookless: fs/Makefile edit missing"
    grep -qE 'vfs_map_meta_override|nomount_spoof_mmap_metadata' "$d/fs/proc/task_mmu.c" ||
        die "_hookless: task_mmu.c hook missing"
    grep -qx 'CONFIG_NOMOUNT=y' "$(defconfig_path)" ||
        die "_hookless: CONFIG_NOMOUNT=y is not in $(defconfig_path)"
    assert_config CONFIG_NOMOUNT "the engine is behind CONFIG_NOMOUNT; without it fs/nomount.o is not built at all and every hookless hook is absent"
    echo "_hookless: verified"
}

# walk security/selinux/hooks.c and fail if a `:ksu:`
awk_placement() {
    awk '
        /^static (int|noinline int) selinux_[a-z_]+\(/ { fn = $0; avc = 0 }
        /avc_has_perm/                                 { avc = 1 }
        /:ksu:/ { if (!avc) { print "EARLY " fn > "/dev/stderr"; bad = 1 } }
        END { exit bad ? 1 : 0 }
    ' "$1"
}

verify_hook() {
    local d="$COMMONKERNELFOLDER"
    has "$d/security/selinux/selinuxfs.c" 'sel_ctx_hidden' "_hook: selinuxfs.c gate missing"
    has "$d/security/selinux/selinuxfs.c" 'sel_hidden_bytes' "_hook: selinuxfs.c reply filter missing"
    has "$d/security/selinux/hooks.c" ':ksu:' "_hook: hooks.c attr guard missing"

    infn "$d/security/selinux/hooks.c" '^static int selinux_inode_setxattr' ':ksu:'         "_hook: selinux_inode_setxattr() has no hidden-type guard -- setxattr(security.selinux) then tells an unprivileged caller apart 'type not in policy' (-EINVAL) from 'type exists, denied' (-EACCES), which is a probe for the hidden types"
   
    # 6.12 renamed the process-attr hook; every older tree still has setprocattr
    case "$KERNELVERSION" in
    6.12)
        infn "$d/security/selinux/hooks.c" '^static int selinux_lsm_setattr' ':ksu:'         "_hook: selinux_lsm_setattr() has no hidden-type guard"
        ;;
    *)
        infn "$d/security/selinux/hooks.c" '^static int selinux_setprocattr' ':ksu:'         "_hook: selinux_setprocattr() has no hidden-type guard"
        ;;
    esac
    has "$d/security/selinux/avc.c" ':ksu:' "_hook: avc.c denial filter missing"

    has "$d/security/selinux/avc.c" 'current_uid()' "_hook: avc.c filter has lost its uid gate"
    has "$d/security/selinux/Makefile" 'selinuxfs.o' "_hook: selinuxfs.o is not in security/selinux/Makefile"

    local w
    for w in sel_write_context sel_write_validatetrans sel_write_access \
             sel_write_create sel_write_relabel sel_write_user sel_write_member; do
        infn "$d/security/selinux/selinuxfs.c" "^static ssize_t $w\(" 'sel_ctx_hidden' \
            "_hook: $w() has no sel_ctx_hidden() gate -- that write node is an open hidden-type probe"
    done

    local nfs nhooks navc
    nfs=$(grep -o '":[a-z_]*:"' "$d/security/selinux/selinuxfs.c" | sort -u | tr '\n' ' ')
    nhooks=$(grep -o '":[a-z_]*:"' "$d/security/selinux/hooks.c" | sort -u | tr '\n' ' ')
    navc=$(grep -o '":[a-z_]*:"' "$d/security/selinux/avc.c" | sort -u | tr '\n' ' ')
    [ -n "$nfs" ] || die "_hook: no hidden-type list found in selinuxfs.c"
    [ "$nfs" = "$nhooks" ] ||
        die "_hook: the hidden-type list differs between selinuxfs.c [$nfs] and hooks.c [$nhooks]. A type covered in one file and not another leaves that probe open, and nothing else would have said so."
    [ "$nfs" = "$navc" ] ||
        die "_hook: the hidden-type list differs between selinuxfs.c [$nfs] and avc.c [$navc]."
    echo "  _hook: type list mirrored in 3 files: $nfs"

    awk_placement "$d/security/selinux/hooks.c" ||
        die "_hook: a hidden-type guard in hooks.c sits BEFORE the avc_has_perm() of its own function. That inversion turns the cloak into a one-syscall root oracle -- see common/_hook/README.md."

    [ -n "${KSUFOLDER:-}" ] ||
        die "_hook: KSUFOLDER is not set, so fix_selinux_seqno cannot be verified. Set it -- otherwise the policyload=0 tell goes unchecked and this function reports success anyway."
    [ -f "$KSUFOLDER/kernel/selinux/rules.c" ] ||
        die "_hook: $KSUFOLDER/kernel/selinux/rules.c does not exist. If this KernelSU fork keeps rules.c elsewhere, fix_selinux_seqno.patch did not land and /sys/fs/selinux/status still reports policyload=0."
    hasnt "$KSUFOLDER/kernel/selinux/rules.c" 'selinux_status_update_policyload' \
        "_hook: fix_selinux_seqno did not land -- ksu still writes policyload=0 to /sys/fs/selinux/status"
    has "$KSUFOLDER/kernel/selinux/rules.c" 'selnl_notify_policyload' \
        "_hook: selnl_notify_policyload was removed -- see README, gating it is a documented bootloop risk"

    assert_config CONFIG_SECURITY_SELINUX "every _hook guard lives in security/selinux/, which is built only under CONFIG_SECURITY_SELINUX -- without it the whole family is dead code"
    echo "_hook: verified"
}

verify_pathhide() {
    local d="$COMMONKERNELFOLDER"
    [ -f "$d/fs/pathhide.c" ] || die "_pathhide: fs/pathhide.c missing"
    [ -f "$d/fs/pathhide.h" ] || die "_pathhide: fs/pathhide.h missing"
    objy "$d/fs/Makefile" 'pathhide.o' "_pathhide"
    has "$d/fs/proc/task_mmu.c" 'pathhide_match_file' "_pathhide: maps/smaps guards missing from task_mmu.c"
    has "$d/fs/proc/base.c" 'pathhide_match_file' "_pathhide: map_files guards missing from base.c"
    infn "$d/fs/proc/task_mmu.c" '^static int pagemap_pmd_range' 'pathhide_match_file'         "_pathhide: the pagemap guard is not inside pagemap_pmd_range() -- resident pages sitting at an address maps does not list is the whole gap, stated outright"
    infn "$d/mm/mincore.c" '^static long do_mincore' 'pathhide_match_file'         "_pathhide: the mincore(2) guard is not inside do_mincore(). It has to sit before can_do_mincore(), which answers resident-for-everything by memset for a file the caller cannot write."
    infn "$d/fs/proc/task_mmu.c" '^void task_mem' 'pathhide_hidden_vm_pages'         "_pathhide: the VmSize/VmPeak deduction is not inside task_mem() -- summing the visible maps ranges against VmSize is exact arithmetic, which is what makes it worth closing while RSS is deliberately left alone"
    infn "$d/fs/proc/task_mmu.c" '^unsigned long task_statm' 'pathhide_hidden_vm_pages'         "_pathhide: the statm size deduction is not inside task_statm()"
    # PAGEMAP_SCAN landed in 6.7, so only 6.12 has a second residency window.
    case "$KERNELVERSION" in
    6.12)
        infn "$d/fs/proc/task_mmu.c" '^static int pagemap_scan_test_walk' 'pathhide_match_file'         "_pathhide: the PAGEMAP_SCAN guard is not inside pagemap_scan_test_walk() -- the ioctl is a second residency window onto the same vma"
        ;;
    esac

    hasnt "$d/fs/proc/fd.c" 'pathhide' \
        "_pathhide: fs/proc/fd.c is patched again. The fd half was removed because a hidden fd stays allocated -- fcntl(N, F_GETFD) succeeds where /proc/self/fd/N answers ENOENT, which is unconditional and never true on stock."

    echo "_pathhide: verified (no CONFIG symbol by design -- see README)"
}

# infn <file> <awk-start-regex> <needle> <what>
infn() {
    local seg
    seg="$(awk "/$2/,/^}/" "$1" 2>/dev/null)" || true
    case "$seg" in
    *"$3"*) return 0 ;;
    esac
    die "$4"
}

verify_ghost() {
    local d="$COMMONKERNELFOLDER" n
    [ -f "$d/fs/proc/ghost.c" ] || die "_ghost: fs/proc/ghost.c missing"
    [ -f "$d/fs/proc/ghost.h" ] || die "_ghost: fs/proc/ghost.h missing"
    objy "$d/fs/proc/Makefile" 'ghost.o' "_ghost"

    infn "$d/fs/namei.c" '^static int do_o_path' 'ghost_hidden_path(&path))'         "_ghost: the O_PATH guard is not inside do_o_path()"
    infn "$d/fs/namei.c" '^static int do_open' 'unlikely(ghost_hidden_path(&nd->path))'         "_ghost: the open(2) guard is not inside do_open(). It is unconditional now: any open of a hidden path that did not just create it answers ENOENT, so plain O_RDONLY and O_CREAT agree with O_PATH instead of handing back an fd -- and, with O_TRUNC, emptying the file."
    infn "$d/fs/namei.c" '^static int path_lookupat' 'unlikely(err == -ENOTDIR)'         "_ghost: the ENOTDIR guard is not inside path_lookupat(). It applies at fuzz 0 inside path_parentat() too -- that is the bug ghost_notdir.patch's header documents, and this is the assertion that catches it."
    # both walkers, not one. path_parentat() is the CREATE family's choke point
    infn "$d/fs/namei.c" '^static int path_parentat' 'unlikely(err == -ENOTDIR)'         "_ghost: the ENOTDIR guard is not inside path_parentat() -- mkdirat/mknodat/symlinkat/unlinkat/renameat reach -ENOTDIR through there and through nothing else this patch set guards"
    infn "$d/fs/namei.c" '^static struct dentry \*filename_create' 'error = err2 ? err2 : -EACCES'         "_ghost: the create guard is not inside filename_create(), or it went back to masking only on a read-only mount. mkdirat/mknodat/symlinkat/linkat all reach -EEXIST through here before may_create() runs, so a hidden name has to answer what an absent one would: err2 when the mount is read-only, -EACCES otherwise."
    infn "$d/fs/namei.c" '^(static )?int do_linkat' 'ghost_hidden_path(&old_path)'         "_ghost: the link(2) guard is not inside do_linkat()"
    infn "$d/fs/open.c" '^int do_fchownat' 'ghost_hidden_path(&path))'         "_ghost: the chown(2) guard is not inside do_fchownat()"
    infn "$d/fs/stat.c" '^static int do_readlinkat' 'ghost_hidden_path(&path))'         "_ghost: the readlink(2) guard is not inside do_readlinkat() -- it returns the hidden symlink's target where an absent path answers ENOENT"
    infn "$d/fs/open.c" '^static long do_faccessat' 'unlikely(ghost_hidden_path(&path))'         "_ghost: the access(2) guard is not inside do_faccessat(), or it is gated on the mode again. It used to fire only for MAY_WRITE, so access(F_OK) and access(R_OK) reported the hidden path as present while access(W_OK) answered ENOENT -- one syscall, two answers, and only one of them what an absent path gives."

    infn "$d/fs/stat.c" '^(static )?int vfs_statx' 'ghost_hidden_path(&path))'         "_ghost: the stat(2) family guard is not inside vfs_statx() -- lstat/statx/newfstatat read the hidden object's real metadata where every other ghost surface answers ENOENT. This is the whole family through one choke point on all five trees; there is no version where it is optional."
    infn "$d/fs/open.c" 'do_fchmodat' 'ghost_hidden_path(&path))'         "_ghost: the chmod(2) guard is not inside do_fchmodat()"
    infn "$d/fs/open.c" '^(long|int) do_sys_truncate' 'ghost_hidden_path(&path))'         "_ghost: the truncate(2) guard is not inside do_sys_truncate()"
    infn "$d/fs/utimes.c" '^(static )?(long|int) do_utimes_path' 'ghost_hidden_path(&path))'         "_ghost: the utimensat(2) guard is not inside do_utimes_path()"
    # all four wrappers or none -- ghost_xattr*.patch's header argues at length
    local w
    for w in path_setxattr path_getxattr path_listxattr path_removexattr; do
        infn "$d/fs/xattr.c" "^static (ssize_t|int) $w\(" 'ghost_hidden_path(&path))'             "_ghost: fs/xattr.c has no guard inside $w() -- the xattr family is all four wrappers or none"
    done
    n=$(grep -c 'ghost_hidden_path' "$d/fs/xattr.c" 2>/dev/null || echo 0)
    [ "$n" -eq 8 ] || die "_ghost: fs/xattr.c has $n ghost_hidden_path references, expected 8 (one extern + one call per wrapper)"

    infn "$d/fs/namei.c" '^int do_renameat2' 'struct path gpath = { .mnt = old_path.mnt, .dentry = old_dentry }'         "_ghost: the rename(2) source guard is not inside do_renameat2() -- a hidden source renames like any other file, which both answers where an absent one says ENOENT and moves the object out of the path that hides it"
    if awk '/^int do_renameat2/,/^}/' "$d/fs/namei.c" | grep -q 'err2'; then
        die "_ghost: the create guard landed in do_renameat2, not filename_create. The rename guard belongs there; the err2/-EACCES one does not."
    fi

    hasnt "$d/fs/proc/ghost.c" 'proc_create' \
        "_ghost: ghost.c owns a /proc node -- a file whose job is concealing files must not own a name no stock kernel has"
    echo "_ghost: verified (no CONFIG symbol by design -- see README)"
}

defconfig_path() {
    echo "$COMMONKERNELFOLDER/arch/arm64/configs/${NOMOUNT_DEFCONFIG:-gki_defconfig}"
}

# ---------------------------------------------------------------------------
# Families
# ---------------------------------------------------------------------------
do_hookless() {
    need GITHUB_WORKSPACE COMMONKERNELFOLDER
    echo "::group::Apply NoMount (hookless VFS) patch"
    local NM_SRC="$GITHUB_WORKSPACE/nomount_hookless" NM_PATCH DEFCONFIG
    DEFCONFIG="$(defconfig_path)"
    [ -f "$DEFCONFIG" ] || die "defconfig $DEFCONFIG does not exist and refusing to create it -- a defconfig invented here is not the one the build reads, set nomount defconfig to the fragment this build actually uses"
    rm -rf "$NM_SRC"
    # engine moved into suite repo
    git clone --depth 1 -b "${NOMOUNT_REF:-main}" https://github.com/Bouteillepleine/NoMount-Suite.git "$NM_SRC" \
        || die "could not clone the NoMount engine at ref '${NOMOUNT_REF:-main}' from Bouteillepleine/NoMount-Suite. It was Bouteillepleine/nomount@suite before, and kbuild@hookless before that; if something still passes nomount_ref=suite or =hookless, neither exists in this repo -- use 'main'."
    # resolve the ref to a commit and record it
    NM_SHA="$(git -C "$NM_SRC" rev-parse HEAD 2>/dev/null || echo unknown)"
    export NM_SHA
    echo "engine: Bouteillepleine/NoMount-Suite@${NOMOUNT_REF:-main} = $NM_SHA"
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "NM_ENGINE_REF=${NOMOUNT_REF:-main}" >>"$GITHUB_ENV"
        echo "NM_ENGINE_SHA=$NM_SHA" >>"$GITHUB_ENV"
    fi
    case "${NOMOUNT_REF:-main}" in
    main | master)
        echo "  note: NOMOUNT_REF is a moving branch, so this build is not reproducible from kernel_patches alone. Pass NOMOUNT_REF=<tag> to pin it."
        ;;
    esac
    # The engine collapsed the ten per-version integration patches into one that
    # applies across 4.9-6.18. Prefer it; fall back to the per-version name so
    # this script keeps working against an engine ref that still ships the ten
    # (nomount_ref and patches_ref are chosen independently, so either pairing
    # is a legitimate build).
    NM_PATCH="$NM_SRC/hookless/patches/nomount_kernel_integration.patch"
    if [ ! -f "$NM_PATCH" ]; then
        NM_PATCH="$NM_SRC/hookless/patches/nomount_${KERNELVERSION}_kernel_integration.patch"
        [ -f "$NM_PATCH" ] || die "no hookless NoMount patch for $KERNELVERSION: neither\
 $NM_SRC/hookless/patches/nomount_kernel_integration.patch nor $NM_PATCH exists"
    fi
    echo "hookless integration patch: ${NM_PATCH##*/}"
    rm -f "$COMMONKERNELFOLDER/fs/nomount.c" "$COMMONKERNELFOLDER/fs/nomount.h"
    cp "$NM_SRC/hookless/src/nomount.c" "$COMMONKERNELFOLDER/fs/nomount.c"
    cp "$NM_SRC/hookless/src/nomount.h" "$COMMONKERNELFOLDER/fs/nomount.h"
    # loud, annotated, and visible in the build log rather than the default
    if patch -p1 -F0 --forward --dry-run -d "$COMMONKERNELFOLDER" <"$NM_PATCH" >/dev/null 2>&1; then
        patch -p1 -F0 --forward -d "$COMMONKERNELFOLDER" <"$NM_PATCH" >/dev/null ||
            die "NoMount hookless patch dry-ran clean at -F0 and then failed to apply for $KERNELVERSION"
        echo "  hookless integration: applied at fuzz 0"
    elif patch -p1 -F0 --reverse --dry-run -d "$COMMONKERNELFOLDER" <"$NM_PATCH" >/dev/null 2>&1; then
        echo "  hookless integration: already applied"
    else
        echo "::warning::hookless integration patch does not apply at fuzz 0 on $KERNELVERSION; retrying at fuzz 1. A fuzzed hunk can land a hook in the wrong function -- check fs/proc/task_mmu.c and fs/Makefile in the build output before trusting this kernel."
        patch -p1 --forward --fuzz=1 -d "$COMMONKERNELFOLDER" <"$NM_PATCH" ||
            die "NoMount hookless patch failed to apply for $KERNELVERSION, at fuzz 0 and at fuzz 1"
    fi
    sed -i '/^CONFIG_NOMOUNT=/d' "$DEFCONFIG"
    echo "CONFIG_NOMOUNT=y" >>"$DEFCONFIG"
    verify_hookless
    echo "::endgroup::"
}

do_record_version() {
    need COMMONKERNELFOLDER GITHUB_ENV
    local NM_HDR="$COMMONKERNELFOLDER/fs/nomount.h" NMVER=""
    if [ -f "$NM_HDR" ]; then
        NMVER="$(sed -n 's/^#define[[:space:]]\+NM_MODULE_VERSION[[:space:]]\+"\([^"]*\)".*/\1/p' "$NM_HDR" | head -n1)"
    fi
    echo "NMVER=${NMVER:-unknown}" >>"$GITHUB_ENV"
    echo "NoMount version: ${NMVER:-unknown}"
}

do_hook() {
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER KSUFOLDER
    echo "::group::Apply SELinux oracle (_hook) patches"
    local HOOK="$NMSUITEKERNELPATCHESFOLDER/common/_hook"
    normalise "$HOOK"/*.patch

    # Variant table. Every family is pinned on every supported version
    local REQ_SFS REQ_ATTR REQ_AUDIT
    case "$KERNELVERSION" in
    6.6 | 6.12)
        REQ_SFS=hide_selinux_selinuxfs_6_12.patch
        REQ_AUDIT=quiet_selinux_audit.patch
        ;;
    5.10 | 5.15 | 6.1)
        REQ_SFS=hide_selinux_selinuxfs_5_10.patch
        REQ_AUDIT=quiet_selinux_audit_legacy.patch
        ;;
    esac
    case "$KERNELVERSION" in
    6.12) REQ_ATTR=hide_selinux_attr_6_12.patch ;;
    # 6.6 carries the mnt_idmap-era selinux_inode_setxattr() that the 6.12 hunk guards
    *) REQ_ATTR=hide_selinux_attr.patch ;;
    esac

    apply_first_of selinuxfs "$REQ_SFS" \
        "$HOOK/hide_selinux_selinuxfs_6_12.patch" "$HOOK/hide_selinux_selinuxfs_5_10.patch"
    apply_first_of attr "$REQ_ATTR" \
        "$HOOK/hide_selinux_attr_6_12.patch" "$HOOK/hide_selinux_attr_6_6.patch"         "$HOOK/hide_selinux_attr_5_10.patch" "$HOOK/hide_selinux_attr.patch"
    apply_first_of avc-audit "$REQ_AUDIT" \
        "$HOOK/quiet_selinux_audit.patch" "$HOOK/quiet_selinux_audit_legacy.patch"
    apply_or_die "$HOOK/fix_selinux_seqno.patch" "$KSUFOLDER"
    verify_hook
    echo "::endgroup::"
}

do_pathhide() {
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER
    echo "::group::Apply pathhide (maps cloak)"
    local PH="$NMSUITEKERNELPATCHESFOLDER/common/_pathhide" d="$COMMONKERNELFOLDER"
    rm -f "$d/fs/pathhide.c" "$d/fs/pathhide.h"
    cp "$PH/pathhide.c" "$d/fs/pathhide.c"
    cp "$PH/pathhide.h" "$d/fs/pathhide.h"
    normalise "$d/fs/pathhide.c" "$d/fs/pathhide.h"
    normalise "$PH"/*.patch
    apply_or_die "$PH/pathhide_${KERNELVERSION}_integration.patch"
    apply_or_die "$PH/pathhide_mapfiles_${KERNELVERSION}_integration.patch"
    # dropping a vma's line from maps leaves the mapping itself in place, so the gap stays readable through pagemap, mincore(2) and the accounting-derived counters (VmSize/VmPeak/statm) -- none of which the maps cloak touches
    if grep -q 'pagemap_scan_test_walk' "$d/fs/proc/task_mmu.c"; then
        REQ_PAGEMAP=pathhide_pagemap_6.12_integration.patch
    elif awk '/^static int pagemap_pmd_range/,/^}/' "$d/fs/proc/task_mmu.c" |
        grep -q 'bool migration'; then
        REQ_PAGEMAP=pathhide_pagemap_5.10_integration.patch
    else
        REQ_PAGEMAP=pathhide_pagemap_6.6_integration.patch
    fi
    # do_mincore() finds the vma with find_vma()+vm_start on the older trees and
    # with vma_lookup() from 6.6 on. The guard has to sit before
    # can_do_mincore(), which memsets "resident" for a file the caller cannot
    # write -- so the unwritable case leaks through the side channel, not the walk
    if grep -q 'vma_lookup(current->mm, addr)' "$d/mm/mincore.c"; then
        REQ_MINCORE=pathhide_mincore_6.12_integration.patch
    else
        REQ_MINCORE=pathhide_mincore_5.10_integration.patch
    fi
    # conversion: pathhidehiddenvmpages() counts real pagesize pages while pagesizecount() divroundups into the emulated size, so converting first and subtracting after rounds twice and can over-deduct a page
    if grep -q '__page_size_count(mm->total_vm)' "$d/fs/proc/task_mmu.c"; then
        REQ_ACCT=pathhide_accounting_pgcompat_integration.patch
    elif grep -q 'get_mm_counter_sum(mm, MM_ANONPAGES)' "$d/fs/proc/task_mmu.c"; then
        REQ_ACCT=pathhide_accounting_6.6_integration.patch
    else
        REQ_ACCT=pathhide_accounting_integration.patch
    fi
    apply_first_of pathhide-pagemap "$REQ_PAGEMAP" \
        "$PH/pathhide_pagemap_6.12_integration.patch" \
        "$PH/pathhide_pagemap_6.6_integration.patch" \
        "$PH/pathhide_pagemap_5.10_integration.patch"
    apply_first_of pathhide-mincore "$REQ_MINCORE" \
        "$PH/pathhide_mincore_6.12_integration.patch" \
        "$PH/pathhide_mincore_5.10_integration.patch"
    apply_first_of pathhide-accounting "$REQ_ACCT" \
        "$PH/pathhide_accounting_6.6_integration.patch" \
        "$PH/pathhide_accounting_pgcompat_integration.patch" \
        "$PH/pathhide_accounting_integration.patch"
    # pathhide.c/.h live in fs/, not fs/proc/, so this appends the obj-y line rather than applying pathhide_build_integration.patch (which is the fs/proc/ layout). verifypathhide() asserts the result, not this write
    grep -qE '^obj-y[[:space:]]*\+=.*pathhide\.o' "$d/fs/Makefile" ||
        echo 'obj-y += pathhide.o' >>"$d/fs/Makefile"
    verify_pathhide
    echo "::endgroup::"
}

do_ghost() {
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER
    echo "::group::Apply _ghost (O_PATH / *xattr / link / ENOTDIR existence cloak)"
    local GH="$NMSUITEKERNELPATCHESFOLDER/common/_ghost" d="$COMMONKERNELFOLDER"
    rm -f "$d/fs/proc/ghost.c" "$d/fs/proc/ghost.h"
    cp "$GH/ghost.c" "$d/fs/proc/ghost.c"
    cp "$GH/ghost.h" "$d/fs/proc/ghost.h"
    normalise "$d/fs/proc/ghost.c" "$d/fs/proc/ghost.h"
    normalise "$GH"/*.patch

    local REQ_XATTR REQ_LINKAT REQ_CHMOD
    case "$KERNELVERSION" in
    6.12 | 6.6)
        REQ_XATTR=ghost_xattr_6_12.patch
        REQ_LINKAT=ghost_linkat_5_15.patch
        REQ_CHMOD=ghost_chmod.patch
        ;;
    6.1 | 5.15)
        REQ_XATTR=ghost_xattr_5_15.patch
        REQ_LINKAT=ghost_linkat_5_15.patch
        REQ_CHMOD=ghost_chmod_5_10.patch
        ;;
    5.10)
        REQ_XATTR=ghost_xattr.patch
        REQ_LINKAT=ghost_linkat.patch
        REQ_CHMOD=ghost_chmod_5_10.patch
        ;;
    esac

    apply_or_die "$GH/ghost_o_path.patch"
    apply_first_of ghost-xattr "$REQ_XATTR" \
        "$GH/ghost_xattr_6_12.patch" "$GH/ghost_xattr_5_15.patch" "$GH/ghost_xattr.patch"
    apply_first_of ghost-linkat "$REQ_LINKAT" \
        "$GH/ghost_linkat_5_15.patch" "$GH/ghost_linkat.patch"
    # one file, 5.10 through 6.12: the guards sit in pathlookupat() and doopen(), neither of which cares whether the tree spells the unlazy step unlazywalk() or trytounlazy() that split is what needed two variants
    apply_or_die "$GH/ghost_notdir.patch"
    apply_or_die "$GH/ghost_truncate.patch"
    apply_or_die "$GH/ghost_utimes.patch"
    apply_first_of ghost-chmod "$REQ_CHMOD" \
        "$GH/ghost_chmod.patch" "$GH/ghost_chmod_5_10.patch"
    # chown is chmod's sibling in the mnt_want_write-answers-first family, and dofchownat() is byte-identical on all five, so it needs no variant table
    apply_or_die "$GH/ghost_chown.patch"
    # access(wok), and the write-intent and ocreat forms of open(2)
    apply_or_die "$GH/ghost_access.patch"
    apply_or_die "$GH/ghost_open.patch"
    apply_or_die "$GH/ghost_create.patch"
    apply_or_die "$GH/ghost_build_integration.patch"
    # stat(2) family -- the plainest existence oracle there is
    local REQ_STATX
    case "$KERNELVERSION" in
    6.12) REQ_STATX=ghost_statx_6_12.patch ;;
    6.6 | 6.1) REQ_STATX=ghost_statx_6_1.patch ;;
    5.15 | 5.10) REQ_STATX=ghost_statx_5_10.patch ;;
    esac
    apply_first_of ghost-statx "$REQ_STATX" \
        "$GH/ghost_statx_6_12.patch" "$GH/ghost_statx_6_1.patch" \
        "$GH/ghost_statx_5_10.patch"
    # readlink(2) Two shapes: 6.12 resolves through filenamelookup() and owns a struct filename the guard has to putname(); everything older goes through userpathatempty() and has only the path to drop
    local REQ_READLINK
    case "$KERNELVERSION" in
    6.12) REQ_READLINK=ghost_readlink_6_12.patch ;;
    *) REQ_READLINK=ghost_readlink_5_10.patch ;;
    esac
    apply_first_of ghost-readlink "$REQ_READLINK" \
        "$GH/ghost_readlink_6_12.patch" "$GH/ghost_readlink_5_10.patch"

    local REQ_RENAME
    case "$KERNELVERSION" in
    5.10) REQ_RENAME=ghost_rename_5_10.patch ;;
    *) REQ_RENAME=ghost_rename_5_15.patch ;;
    esac
    apply_first_of ghost-rename "$REQ_RENAME" \
        "$GH/ghost_rename_5_10.patch" "$GH/ghost_rename_5_15.patch"
    verify_ghost
    echo "::endgroup::"
}

# do_verify [family...] -- defaults to every family `all` always verifies all four; a builder that ships only some of them can name the ones it applied
do_verify() {
    need COMMONKERNELFOLDER
    local f
    [ $# -gt 0 ] || set -- hookless hook pathhide ghost
    echo "::group::Verify the NoMount stack landed"
    for f in "$@"; do
        case "$f" in
        hookless) verify_hookless ;;
        hook) verify_hook ;;
        pathhide) verify_pathhide ;;
        ghost) verify_ghost ;;
        *) die "verify: unknown family '$f'" ;;
        esac
    done
    echo "verified: $*"
    echo "::endgroup::"
}

case "$CMD" in
all)
    need GITHUB_WORKSPACE NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER KSUFOLDER
    resolve_kv
    resolve_ksu
    do_hookless
    if [ -n "${GITHUB_ENV:-}" ]; then do_record_version; fi
    do_hook
    do_pathhide
    do_ghost
    do_verify hookless hook pathhide ghost
    ;;
hookless)
    need GITHUB_WORKSPACE COMMONKERNELFOLDER
    resolve_kv
    do_hookless
    ;;
record-version)
    do_record_version
    ;;
hook)
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER KSUFOLDER
    resolve_kv
    resolve_ksu
    do_hook
    ;;
pathhide)
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER
    resolve_kv
    do_pathhide
    ;;
ghost)
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER
    resolve_kv
    do_ghost
    ;;
verify)
    need COMMONKERNELFOLDER
    resolve_kv
    do_verify "$@"
    ;;
assert-config)
    need COMMONKERNELFOLDER
    CONFIG_STRICT=1
    assert_config CONFIG_NOMOUNT "the engine is behind CONFIG_NOMOUNT; without it fs/nomount.o is not built at all"
    assert_config CONFIG_SECURITY_SELINUX "every _hook guard is compiled only under CONFIG_SECURITY_SELINUX"
    ;;
*)
    usage
    ;;
esac
