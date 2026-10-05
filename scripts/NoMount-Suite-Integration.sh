#!/usr/bin/env bash
set -euo pipefail
usage() {
    echo "usage: $0 <all|hookless|record-version|hook|pathhide|ghost|assert-config>" >&2
    echo "       $0 verify [hookless] [hook] [pathhide] [ghost]   (default: all four)" >&2
    exit 2
}

die() { echo "::error::apply-nomountsuite-kernel-integration: $*" >&2; exit 1; }
need() {
    local v
    for v in "$@"; do
        [ -n "${!v:-}" ] || die "$v is not set"
    done
}
resolveksusource() {
    need KERNELPLATFORM
    if [[ -d "${KERNELPLATFORM}/KernelSU" ]]; then
        KSUFOLDER="${KERNELPLATFORM}/KernelSU"
    elif [[ -d "${KERNELPLATFORM}/KernelSU-Next" ]]; then
        KSUFOLDER="${KERNELPLATFORM}/KernelSU-Next"
    else
        die "neither ${KERNELPLATFORM}/kernelsu nor ${KERNELPLATFORM}/kernelsu-next exists.."
    fi

    export KSUFOLDER
    echo "ksu tree: ${KSUFOLDER}"
}
[ $# -ge 1 ] || usage
CMD="$1"
shift
resolvekernelversion() {
    local mk="$COMMONKERNELFOLDER/Makefile" v p
    [ -f "$mk" ] || die "no $mk -- COMMONKERNELFOLDER is not a kernel tree"
    v="$(sed -n 's/^VERSION[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$mk" | head -n1)"
    p="$(sed -n 's/^PATCHLEVEL[[:space:]]*=[[:space:]]*\([0-9]\+\).*/\1/p' "$mk" | head -n1)"
    [ -n "$v" ] && [ -n "$p" ] || die "cannot read version/patchlevel from $mk.."
    KV="$v.$p"
    case "$KV" in
    5.10 | 5.15 | 6.1 | 6.6 | 6.12) ;;
    *) die "kernel $KV is not one of 5.10 5.15 6.1 6.6 6.12 -- refusing to guess which variants it wants.." ;;
    esac
    if [ -n "${KERNELVERSION:-}" ] && [ "$KERNELVERSION" != "$KV" ]; then
        die "KERNELVERSION='$KERNELVERSION' but $mk says '$KV' one of them is wrong, and the variant tables below are keyed on it.."
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
                die "$f has crlf line endings and dos2unix is not installed, it will not apply at -F0, and patch will blame the kernel tree rather than the line endings.. istall dos2unix, or re-checkout with the repo's gitattributes in effect.."
            fi
        done
    fi
}

applypatch() {
    local p="$1" root="${2:-$COMMONKERNELFOLDER}"
    [ -f "$p" ] || die "missing patch: $p"
    if patch -p1 -F0 --forward --dry-run -d "$root" <"$p" >/dev/null 2>&1; then
        patch -p1 -F0 --forward -d "$root" <"$p" >/dev/null
        echo "  applied: $(basename "$p")"
    elif patch -p1 -F0 --reverse --dry-run -d "$root" <"$p" >/dev/null 2>&1; then
        echo "  already applied: $(basename "$p")"
    else
        die "$(basename "$p") neither applies at fuzz 0 nor is already present in $root.."
    fi
}

applyfirst() {
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
        [ "$nhits" -eq 1 ] || die "$family: $nhits variants apply on $KERNELVERSION ($hits ) and the table pins none. Pin one, or refit them so exactly one claims this tree -- picking the first is how a guard lands in the wrong function"
    else
        case " $hits " in
        *" $want "*) ;;
        *) die "$family: pinned variant '$want' does not apply at fuzz 0 on $KERNELVERSION; these do:$hits.. variants do not carry the same hunks.. so falling back would silently drop coverage.. refit '$want' to this tree instead" ;;
        esac
        [ "$nhits" -eq 1 ] || echo "  $family: '$want' pinned (also applicable:$hits )"
    fi
    applypatch "$sel" "$root"
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
        die "$3: no '^obj-y += $2' line in $1 -- object would never be linked into the kernel.."
}

findconfig() {
    local c
    for c in "${DEFCONFIG:-}" "$COMMONKERNELFOLDER/out/.config" \
        "$COMMONKERNELFOLDER/.config" "${OUTDIR:-}/.config"; do
        if [ -n "$c" ] && [ -f "$c" ]; then
            echo "$c"
            return 0
        fi
    done
    return 1
}

CONFIGSTRICT=0
assertconfig() {
    local sym="$1" why="$2" cfg
    if cfg="$(findconfig)"; then
        grep -qx "$sym=y" "$cfg" ||
            die "$sym is not set in $cfg -- $why"
        echo "  config: $sym=y in $cfg"
    elif [ "$CONFIGSTRICT" = 1 ]; then
        die "no defconfig found (tried kernel-config-file, $COMMONKERNELFOLDER/out/.config, $COMMONKERNELFOLDER/.config) -- cannot assert $sym"
    else
        # post-defconfig check against a generated config..
        echo "  $sym: not verifiable yet (no config at apply time; see assert-config).."
    fi
}

verifyhookless() {
    local d="$COMMONKERNELFOLDER"
    [ -f "$d/fs/nomount.c" ] || die "hookless: fs/nomount src missing.."
    [ -f "$d/fs/nomount.h" ] || die "hookless: fs/nomount hdr missing.."
    has "$d/fs/Kconfig" 'config NOMOUNT' "hookless: fs/kconfig edit missing.."
    has "$d/fs/Makefile" 'obj-$(CONFIG_NOMOUNT) += nomount.o' "hookless: fs/makefile edit missing.."
    grep -qE 'vfs_map_meta_override|nomount_spoof_mmap_metadata' "$d/fs/proc/task_mmu.c" ||
        die "hookless: task-mmu src hook missing.."
    grep -qx 'CONFIG_NOMOUNT=y' "$(gkidefconfigpath)" ||
        die "hookless: config-nomount=y is not in $(gkidefconfigpath).."
    assertconfig CONFIG_NOMOUNT "engine is behind config-nomount; without it fs/nomount obj is not built at all and every hookless hook is absent.."
    echo "hookless: verified"
}

# walk security/selinux/hooks.c and fail if a `:ksu:`..
awkplacement() {
    awk '
        /^static (int|noinline int) selinux_[a-z_]+\(/ { fn = $0; avc = 0 }
        /avc_has_perm/                                 { avc = 1 }
        /:ksu:/ { if (!avc) { print "EARLY " fn > "/dev/stderr"; bad = 1 } }
        END { exit bad ? 1 : 0 }
    ' "$1"
}

verifyhook() {
    local d="$COMMONKERNELFOLDER"
    has "$d/security/selinux/selinuxfs.c" 'sel_ctx_hidden' "hook: selinuxfs src gate missing.."
    has "$d/security/selinux/selinuxfs.c" 'sel_hidden_bytes' "hook: selinuxfs src reply filter missing.."
    has "$d/security/selinux/hooks.c" ':ksu:' "hook: hooks src attr guard missing.."

    infn "$d/security/selinux/hooks.c" '^static int selinux-inode-setxattr' ':ksu:' "hook: selinux-inode-setxattr() has no hidden-type guard -- setxattr(security.selinux) then tells an unprivileged caller apart 'type not in policy' (-einval) from 'type exists, denied' (-eacces), which is a probe for the hidden types.."
   
    # 6.12 renamed the process-attr hook; every older tree still has setprocattr
    case "$KERNELVERSION" in
    6.12)
        infn "$d/security/selinux/hooks.c" '^static int selinux-lsm-setattr' ':ksu:' "hook: selinux-lsm-setattr() has no hidden-type guard.."
        ;;
    *)
        infn "$d/security/selinux/hooks.c" '^static int selinux-setprocattr' ':ksu:' "hook: selinux-setprocattr() has no hidden-type guard.."
        ;;
    esac
    has "$d/security/selinux/avc.c" ':ksu:' "hook: avc src denial filter missing.."

    has "$d/security/selinux/avc.c" 'current_uid()' "hook: avc src filter has lost its uid gate.."
    has "$d/security/selinux/Makefile" 'selinuxfs.o' "hook: selinuxfs obj is not in security/selinux/makefile.."

    local w
    for w in sel_write_context sel_write_validatetrans sel_write_access \
             sel_write_create sel_write_relabel sel_write_user sel_write_member; do
        infn "$d/security/selinux/selinuxfs.c" "^static ssize_t $w\(" 'sel_ctx_hidden' \
            "hook: $w() has no sel-ctx-hidden() gate -- that write node is an open hidden-type probe.."
    done

    local nfs nhooks navc
    nfs=$(grep -o '":[a-z_]*:"' "$d/security/selinux/selinuxfs.c" | sort -u | tr '\n' ' ')
    nhooks=$(grep -o '":[a-z_]*:"' "$d/security/selinux/hooks.c" | sort -u | tr '\n' ' ')
    navc=$(grep -o '":[a-z_]*:"' "$d/security/selinux/avc.c" | sort -u | tr '\n' ' ')
    [ -n "$nfs" ] || die "hook: no hidden-type list found in selinuxfs src"
    [ "$nfs" = "$nhooks" ] ||
        die "hook: the hidden-type list differs between selinuxfs.c [$nfs] and hooks src [$nhooks].. a type covered in one file and not another leaves that probe open, and nothing else would have said so.."
    [ "$nfs" = "$navc" ] ||
        die "hook: the hidden-type list differs between selinuxfs src [$nfs] and avc src [$navc].."
    echo "hook: type list mirrored in 3 files: $nfs.."

    awkplacement "$d/security/selinux/hooks.c" ||
        die "_hook: a hidden-type guard in hooks src sits BEFORE the avc-has-perm() of its own function. That inversion turns the cloak into a one-syscall root oracle -- see common/hook/readme.md.."

    [ -n "${KSUFOLDER:-}" ] ||
        die "_hook: KSUFOLDER is not set, so fix_selinux_seqno cannot be verified. Set it -- otherwise the policyload=0 tell goes unchecked and this function reports success anyway."
    [ -f "$KSUFOLDER/kernel/selinux/rules.c" ] ||
        die "hook: $KSUFOLDER/kernel/selinux/rules src does not exist.. if this KernelSU fork keeps rules.c elsewhere, fix-selinux-seqno.patch did not land and /sys/fs/selinux/status still reports policyload=0.."
    hasnt "$KSUFOLDER/kernel/selinux/rules.c" 'selinux_status_update_policyload' \
        "hook: fix-selinux-seqno did not land -- ksu still writes policyload=0 to /sys/fs/selinux/status.."
    has "$KSUFOLDER/kernel/selinux/rules.c" 'selnl_notify_policyload' \
        "hook: selnl-notify-policyload was removed -- see readme, gating it is a documented bootloop risk.."

    assertconfig CONFIG_SECURITY_SELINUX "every hook guard lives in security/selinux/, which is built only under CONFIG_SECURITY_SELINUX -- without it the whole family is dead code"
    echo "hook: verified.."
}

verifypathhide() {
    local d="$COMMONKERNELFOLDER"
    [ -f "$d/fs/pathhide.c" ] || die "_pathhide: fs/pathhide.c missing"
    [ -f "$d/fs/pathhide.h" ] || die "_pathhide: fs/pathhide.h missing"
    objy "$d/fs/Makefile" 'pathhide.o' "_pathhide"
    has "$d/fs/proc/task_mmu.c" 'pathhide_match_file' "pathhide: maps/smaps guards missing from task-mmu src"
    has "$d/fs/proc/base.c" 'pathhide_match_file' "pathhide: map-files guards missing from base src"
    infn "$d/fs/proc/task_mmu.c" '^static int pagemap_pmd_range' 'pathhide_match_file' "pathhide: the pagemap guard is not inside pagemap-pmd-range() -- resident pages sitting at an address maps does not list is the whole gap, stated outright.."
    infn "$d/mm/mincore.c" '^static long do_mincore' 'pathhide_match_file' "pathhide: the mincore(2) guard is not inside do_mincore().. it has to sit before can_do_mincore(), which answers resident-for-everything by memset for a file the caller cannot write."
    infn "$d/fs/proc/task_mmu.c" '^void task_mem' 'pathhide_hidden_vm_pages' "pathhide: the VmSize/VmPeak deduction is not inside task_mem() -- summing the visible maps ranges against VmSize is exact arithmetic, which is what makes it worth closing while RSS is deliberately left alone"
    infn "$d/fs/proc/task_mmu.c" '^unsigned long task_statm' 'pathhide_hidden_vm_pages' "pathhide: the statm size deduction is not inside task-statm()"
  
    # pagemap-scan landed in 6.7, so only 6.12 has a second residency window..
    case "$KERNELVERSION" in
    6.12)
        infn "$d/fs/proc/task_mmu.c" '^static int pagemap_scan_test_walk' 'pathhide_match_file' "pathhide: the page-map-scan guard is not inside pagemap_scan_test_walk() -- the ioctl is a second residency window onto the same vma.."
        ;;
    esac

    hasnt "$d/fs/proc/fd.c" 'pathhide' \
        "_pathhide: fs/proc/fd.c is patched again. The fd half was removed because a hidden fd stays allocated -- fcntl(n, f-getfd) succeeds where /proc/self/fd/N answers ENOENT, which is unconditional and never true on stock.."

    echo "pathhide: verified (no config symbol by design -- see readme).."
}

# infn <file> <awk-start-regex> <needle> <what>..
infn() {
    local seg
    seg="$(awk "/$2/,/^}/" "$1" 2>/dev/null)" || true
    case "$seg" in
    *"$3"*) return 0 ;;
    esac
    die "$4"
}

verifyghost() {
    local d="$COMMONKERNELFOLDER" n
    [ -f "$d/fs/proc/ghost.c" ] || die "ghost: fs/proc/ghost src missing.."
    [ -f "$d/fs/proc/ghost.h" ] || die "ghost: fs/proc/ghost hdr missing.."
    objy "$d/fs/proc/Makefile" 'ghost.o' "ghost"

    infn "$d/fs/namei.c" '^static int do_o_path' 'ghost_hidden_path(&path))' "ghost: the o-path guard is not inside do-o-path()"
    infn "$d/fs/namei.c" '^static int do_open' 'unlikely(ghost_hidden_path(&nd->path))' "ghost: the open(2) guard is not inside do-open().. it is unconditional now: any open of a hidden path that did not just create it answers ENOENT, so plain O_RDONLY and O_CREAT agree with O_PATH instead of handing back an fd -- and, with O_TRUNC, emptying the file."
    infn "$d/fs/namei.c" '^static int path_lookupat' 'unlikely(err == -ENOTDIR)' "ghost: the ENOTDIR guard is not inside path_lookupat(). It applies at fuzz 0 inside path-parentat() too -- that is the bug ghost_notdir.patch's header documents, and this is the assertion that catches it."
    # both walkers, not one. path_parentat() is the CREATE family's choke point
    infn "$d/fs/namei.c" '^static int path_parentat' 'unlikely(err == -ENOTDIR)' "ghost: the ENOTDIR guard is not inside path-parentat() -- mkdirat/mknodat/symlinkat/unlinkat/renameat reach -enotdir through there and through nothing else this patch set guards"
    infn "$d/fs/namei.c" '^static struct dentry \*filename_create' 'error = err2 ? err2 : -EACCES' "ghost: the create guard is not inside filename-create(), or it went back to masking only on a read-only mount. mkdirat/mknodat/symlinkat/linkat all reach -EEXIST through here before may_create() runs, so a hidden name has to answer what an absent one would: err2 when the mount is read-only, -EACCES otherwise."
    infn "$d/fs/namei.c" '^(static )?int do_linkat' 'ghost_hidden_path(&old_path)' "ghost: the link(2) guard is not inside do-linkat()"
    infn "$d/fs/open.c" '^int do_fchownat' 'ghost_hidden_path(&path))' "ghost: the chown(2) guard is not inside do_fchownat()"
    infn "$d/fs/stat.c" '^static int do_readlinkat' 'ghost_hidden_path(&path))' "ghost: the readlink(2) guard is not inside do-readlinkat() -- it returns the hidden symlink's target where an absent path answers enoent.."
    infn "$d/fs/open.c" '^static long do_faccessat' 'unlikely(ghost_hidden_path(&path))' "ghost: the access(2) guard is not inside do-faccessat(), or it is gated on the mode again, it used to fire only for may-write, so access(F_OK) and access(R_OK) reported the hidden path as present while access(w-ok) answered enoent -- one syscall, two answers, and only one of them what an absent path gives."

    infn "$d/fs/stat.c" '^(static )?int vfs_statx' 'ghost_hidden_path(&path))' "ghost: the stat(2) family guard is not inside vfs-statx() -- lstat/statx/newfstatat read the hidden object's real metadata where every other ghost surface answers enoent.. this is the whole family through one choke point on all five trees; there is no version where it is optional.."
    infn "$d/fs/open.c" 'do_fchmodat' 'ghost_hidden_path(&path))' "ghost: the chmod(2) guard is not inside do-fchmodat().."
    infn "$d/fs/open.c" '^(long|int) do_sys_truncate' 'ghost_hidden_path(&path))' "ghost: the truncate(2) guard is not inside do-sys-truncate().."
    infn "$d/fs/utimes.c" '^(static )?(long|int) do_utimes_path' 'ghost_hidden_path(&path))' "ghost: the utimensat(2) guard is not inside do-utimes-path().."
    # all four wrappers or none -- ghost_xattr*.patch's header argues at length..
    local w
    for w in path_setxattr path_getxattr path_listxattr path_removexattr; do
        infn "$d/fs/xattr.c" "^static (ssize_t|int) $w\(" 'ghost_hidden_path(&path))' "ghost: fs/xattr src has no guard inside $w() -- the xattr family is all four wrappers or none.."
    done
    n=$(grep -c 'ghost_hidden_path' "$d/fs/xattr.c" 2>/dev/null || echo 0)
    [ "$n" -eq 8 ] || die "ghost: fs/xattr src has $n ghost-hidden-path references, expected 8 (one extern + one call per wrapper).."

    infn "$d/fs/namei.c" '^int do_renameat2' 'struct path gpath = { .mnt = old_path.mnt, .dentry = old_dentry }'         "_ghost: the rename(2) source guard is not inside do_renameat2() -- a hidden source renames like any other file, which both answers where an absent one says ENOENT and moves the object out of the path that hides it"
    if awk '/^int do_renameat2/,/^}/' "$d/fs/namei.c" | grep -q 'err2'; then
        die "ghost: the create guard landed in do-renameat2, not filename-create.. rename guard belongs there; the err2/-eacces one does not.."
    fi

    hasnt "$d/fs/proc/ghost.c" 'proc_create' \
        "ghost: ghost src owns a /proc node -- a file whose job is concealing files must not own a name no stock kernel has.."
    echo "ghost: verified (no config symbol by design -- see readme).."
}

gkidefconfigpath() {
    echo "$COMMONKERNELFOLDER/arch/arm64/configs/${NOMOUNTSUITEDEFCONFIG:-gki_defconfig}"
}

# families
executehookless() {
    need WORKSPACEDIR COMMONKERNELFOLDER
    echo "::group::apply nomount-suite (hookless vfs) patch"
    local NMSOURCE="$WORKSPACEDIR/nomount_hookless" NMSUITEPATCH DEFCONFIG
    DEFCONFIG="$(gkidefconfigpath)"
    [ -f "$DEFCONFIG" ] || die "defconfig $DEFCONFIG does not exist and refusing to create it -- a defconfig invented here is not the one the build reads.. set nomount defconfig to the fragment this build actually uses.."
    rm -rf "$NMSOURCE"
  
    # engine moved into nomount suite repository..
    git clone --depth 1 -b "${NOMOUNTREF:-main}" https://github.com/Bouteillepleine/NoMount-Suite.git "$NMSOURCE" \
        || die "could not clone the NoMount engine at ref '${NOMOUNTREF:-main}' from Bouteillepleine/NoMount-Suite. It was Bouteillepleine/nomount@suite before, and kbuild@hookless before that; if something still passes nomount_ref=suite or =hookless, neither exists in this repo -- use 'main'."
  
    # resolve the ref to a commit and record it..
    NMSUITESHA="$(git -C "$NMSOURCE" rev-parse HEAD 2>/dev/null || echo unknown)"
    export NMSUITESHA
    echo "engine: bouteillepleine/nomountsuite@${NOMOUNTREF:-main} = $NMSUITESHA"
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "NMSENGINERREF=${NOMOUNTREF:-main}" >>"$GITHUB_ENV"
        echo "NMSENGINESHA=$NMSUITESHA" >>"$GITHUB_ENV"
    fi
    case "${NOMOUNTREF:-main}" in
    main | master)
        echo "  note: nomount ref/branch is a moving branch, so this build is not reproducible from kernel patches alone.. pass nomountref=<tag> to pin it.."
        ;;
    esac
    
    # engine collapsed the ten per-version integration patches into one..
    NMSUITEPATCH="$NMSOURCE/hookless/patches/nomount_kernel_integration.patch"
    if [ ! -f "$NMSUITEPATCH" ]; then
        NMSUITEPATCH="$NMSOURCE/hookless/patches/nomount_${KERNELVERSION}_kernel_integration.patch"
        [ -f "$NMSUITEPATCH" ] || die "no hookless NoMount patch for $KERNELVERSION: neither\
 $NMSOURCE/hookless/patches/nomount_kernel_integration.patch nor $NMSUITEPATCH exists"
    fi
    echo "hookless integration patch: ${NMSUITEPATCH##*/}.."
    rm -f "$COMMONKERNELFOLDER/fs/nomount.c" "$COMMONKERNELFOLDER/fs/nomount.h"
    cp "$NMSOURCE/hookless/src/nomount.c" "$COMMONKERNELFOLDER/fs/nomount.c"
    cp "$NMSOURCE/hookless/src/nomount.h" "$COMMONKERNELFOLDER/fs/nomount.h"
    
    # loud, annotated, and visible in the build log rather than the default..
    if patch -p1 -F0 --forward --dry-run -d "$COMMONKERNELFOLDER" <"$NMSUITEPATCH" >/dev/null 2>&1; then
        patch -p1 -F0 --forward -d "$COMMONKERNELFOLDER" <"$NMSUITEPATCH" >/dev/null ||
            die "nomount-suite hookless patch dry-ran clean at -F0 and then failed to apply for $KERNELVERSION.."
        echo "hookless integration: applied at fuzz 0.."
    elif patch -p1 -F0 --reverse --dry-run -d "$COMMONKERNELFOLDER" <"$NMSUITEPATCH" >/dev/null 2>&1; then
        echo "hookless integration: already applied.."
    else
        echo "::warning::hookless integration patch does not apply at fuzz 0 on $KERNELVERSION; retrying at fuzz 1.. fuzzed hunk can land a hook in the wrong function -- check fs/proc/task_mmu.c and fs/Makefile in the build output before trusting this kernel."
        patch -p1 --forward --fuzz=1 -d "$COMMONKERNELFOLDER" <"$NMSUITEPATCH" ||
            die "nomount-suite hookless patch failed to apply for $KERNELVERSION, at fuzz 0 and at fuzz 1.."
    fi
    sed -i '/^CONFIG_NOMOUNT=/d' "$DEFCONFIG"
    echo "CONFIG_NOMOUNT=y" >>"$DEFCONFIG"
    verifyhookless
    echo "::endgroup::"
}

executerecordversion() {
    need COMMONKERNELFOLDER GITHUB_ENV
    local NMHDR="$COMMONKERNELFOLDER/fs/nomount.h" NMVER=""
    if [ -f "$NMHDR" ]; then
        NMVER="$(sed -n 's/^#define[[:space:]]\+NM_MODULE_VERSION[[:space:]]\+"\([^"]*\)".*/\1/p' "$NMHDR" | head -n1)"
    fi
    echo "NMVER=${NMVER:-unknown}" >>"$GITHUB_ENV"
    echo "NoMount version: ${NMVER:-unknown}"
}

executehook() {
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER KSUFOLDER
    echo "::group::Apply SELinux oracle (_hook) patches"
    local HOOK="$NMSUITEKERNELPATCHESFOLDER/common/_hook"
    normalise "$HOOK"/*.patch

    # variant table.. every family is pinned on every supported version..
    local REQSFS REQATTR REQAUD
    case "$KERNELVERSION" in
    6.6 | 6.12)
        REQSFS=hide_selinux_selinuxfs_6_12.patch
        REQAUD=quiet_selinux_audit.patch
        ;;
    5.10 | 5.15 | 6.1)
        REQSFS=hide_selinux_selinuxfs_5_10.patch
        REQAUD=quiet_selinux_audit_legacy.patch
        ;;
    esac
    case "$KERNELVERSION" in
    6.12) REQATTR=hide_selinux_attr_6_12.patch ;;
   
    # 6.6 carries the mnt-idmap-era selinux-inode-setxattr() that the 6.12 hunk guards..
    *) REQATTR=hide_selinux_attr.patch ;;
    esac
    applyfirst selinuxfs "$REQSFS" \
        "$HOOK/hide_selinux_selinuxfs_6_12.patch" "$HOOK/hide_selinux_selinuxfs_5_10.patch"
    applyfirst attr "$REQATTR" \
        "$HOOK/hide_selinux_attr_6_12.patch" "$HOOK/hide_selinux_attr_6_6.patch" "$HOOK/hide_selinux_attr_5_10.patch" "$HOOK/hide_selinux_attr.patch"
    applyfirst avc-audit "$REQAUD" \
        "$HOOK/quiet_selinux_audit.patch" "$HOOK/quiet_selinux_audit_legacy.patch"
    applypatch "$HOOK/fix_selinux_seqno.patch" "$KSUFOLDER"
    verifyhook
    echo "::endgroup::"
}

executepathhide() {
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER
    echo "::group::Apply pathhide (maps cloak)"
    local PH="$NMSUITEKERNELPATCHESFOLDER/common/_pathhide" d="$COMMONKERNELFOLDER"
    rm -f "$d/fs/pathhide.c" "$d/fs/pathhide.h"
    cp "$PH/pathhide.c" "$d/fs/pathhide.c"
    cp "$PH/pathhide.h" "$d/fs/pathhide.h"
    normalise "$d/fs/pathhide.c" "$d/fs/pathhide.h"
    normalise "$PH"/*.patch
    applypatch "$PH/pathhide_${KERNELVERSION}_integration.patch"
    applypatch "$PH/pathhide_mapfiles_${KERNELVERSION}_integration.patch"
  
    # dropping a vma's line from maps leaves the mapping itself in place, so the gap stays readable through pagemap, mincore(2) and the accounting-derived counters (VmSize/VmPeak/statm) -- none of which the maps cloak touches..
    if grep -q 'pagemap_scan_test_walk' "$d/fs/proc/task_mmu.c"; then
        REQPAGEMAP=pathhide_pagemap_6.12_integration.patch
    elif awk '/^static int pagemap_pmd_range/,/^}/' "$d/fs/proc/task_mmu.c" |
        grep -q 'bool migration'; then
        REQPAGEMAP=pathhide_pagemap_5.10_integration.patch
    else
        REQPAGEMAP=pathhide_pagemap_6.6_integration.patch
    fi
    
    # do-mincore() finds the vma with find-vma()+vm-start on the older trees and..
    # with vma-lookup() from 6.6 on. The guard has to sit before..
    # can_do_mincore(), which memsets "resident" for a file the caller cannot..
    # write -- so the unwritable case leaks through the side channel, not the walk..
    if grep -q 'vma_lookup(current->mm, addr)' "$d/mm/mincore.c"; then
        REQMINCORE=pathhide_mincore_6.12_integration.patch
    else
        REQMINCORE=pathhide_mincore_5.10_integration.patch
    fi
    # conversion: pathhidehiddenvmpages() counts real pagesize pages while pagesizecount() divroundups into the emulated size, so converting first and subtracting after rounds twice and can over-deduct a page..
    if grep -q '__page_size_count(mm->total_vm)' "$d/fs/proc/task_mmu.c"; then
        REQACCT=pathhide_accounting_pgcompat_integration.patch
    elif grep -q 'get_mm_counter_sum(mm, MM_ANONPAGES)' "$d/fs/proc/task_mmu.c"; then
        REQACCT=pathhide_accounting_6.6_integration.patch
    else
        REQACCT=pathhide_accounting_integration.patch
    fi
    applyfirst pathhide-pagemap "$REQPAGEMAP" \
        "$PH/pathhide_pagemap_6.12_integration.patch" \
        "$PH/pathhide_pagemap_6.6_integration.patch" \
        "$PH/pathhide_pagemap_5.10_integration.patch"
    applyfirst pathhide-mincore "$REQMINCORE" \
        "$PH/pathhide_mincore_6.12_integration.patch" \
        "$PH/pathhide_mincore_5.10_integration.patch"
    applyfirst pathhide-accounting "$REQACCT" \
        "$PH/pathhide_accounting_6.6_integration.patch" \
        "$PH/pathhide_accounting_pgcompat_integration.patch" \
        "$PH/pathhide_accounting_integration.patch"
    # pathhide.c/.h live in fs/, not fs/proc/, so this appends the obj-y line rather than applying pathhide_build_integration.patch (which is the fs/proc/ layout). verifypathhide() asserts the result, not this write
    grep -qE '^obj-y[[:space:]]*\+=.*pathhide\.o' "$d/fs/Makefile" ||
        echo 'obj-y += pathhide.o' >>"$d/fs/Makefile"
    verifypathhide
    echo "::endgroup::"
}

executeghost() {
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER
    echo "::group::Apply _ghost (O_PATH / *xattr / link / ENOTDIR existence cloak)"
    local GH="$NMSUITEKERNELPATCHESFOLDER/common/_ghost" d="$COMMONKERNELFOLDER"
    rm -f "$d/fs/proc/ghost.c" "$d/fs/proc/ghost.h"
    cp "$GH/ghost.c" "$d/fs/proc/ghost.c"
    cp "$GH/ghost.h" "$d/fs/proc/ghost.h"
    normalise "$d/fs/proc/ghost.c" "$d/fs/proc/ghost.h"
    normalise "$GH"/*.patch

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

    applypatch "$GH/ghost_o_path.patch"
    applyfirst ghost-xattr "$REQXATTR" \
        "$GH/ghost_xattr_6_12.patch" "$GH/ghost_xattr_5_15.patch" "$GH/ghost_xattr.patch"
    applyfirst ghost-linkat "$REQLINKAT" \
        "$GH/ghost_linkat_5_15.patch" "$GH/ghost_linkat.patch"
  
    # one file, 5.10 through 6.12: the guards sit in pathlookupat() and doopen(), neither of which cares whether the tree spells the unlazy step unlazywalk() or trytounlazy() that split is what needed two variants..
    applypatch "$GH/ghost_notdir.patch"
    applypatch "$GH/ghost_truncate.patch"
    applypatch "$GH/ghost_utimes.patch"
    applyfirst ghost-chmod "$REQCHMOD" \
        "$GH/ghost_chmod.patch" "$GH/ghost_chmod_5_10.patch"
  
    # chown is chmod's sibling in the mnt_want_write-answers-first family, and dofchownat() is byte-identical on all five, so it needs no variant table..
    applypatch "$GH/ghost_chown.patch"

    # access(wok), and the write-intent and ocreat forms of open(2)..
    applypatch "$GH/ghost_access.patch"
    applypatch "$GH/ghost_open.patch"
    applypatch "$GH/ghost_create.patch"
    applypatch "$GH/ghost_build_integration.patch"

    # stat(2) family -- the plainest existence oracle there is..
    local REQSTATX
    case "$KERNELVERSION" in
    6.12) REQSTATX=ghost_statx_6_12.patch ;;
    6.6 | 6.1) REQSTATX=ghost_statx_6_1.patch ;;
    5.15 | 5.10) REQSTATX=ghost_statx_5_10.patch ;;
    esac
    applyfirst ghost-statx "$REQSTATX" \
        "$GH/ghost_statx_6_12.patch" "$GH/ghost_statx_6_1.patch" \
        "$GH/ghost_statx_5_10.patch"

    # readlink(2) Two shapes: 6.12 resolves through filenamelookup() and owns a struct filename the guard has to putname(); everything older goes through userpathatempty() and has only the path to drop..
    local REQREADLINK
    case "$KERNELVERSION" in
    6.12) REQREADLINK=ghost_readlink_6_12.patch ;;
    *) REQREADLINK=ghost_readlink_5_10.patch ;;
    esac
    applyfirst ghost-readlink "$REQREADLINK" \
        "$GH/ghost_readlink_6_12.patch" "$GH/ghost_readlink_5_10.patch"

    local REQRENAME
    case "$KERNELVERSION" in
    5.10) REQRENAME=ghost_rename_5_10.patch ;;
    *) REQRENAME=ghost_rename_5_15.patch ;;
    esac
    applyfirst ghost-rename "$REQRENAME" \
        "$GH/ghost_rename_5_10.patch" "$GH/ghost_rename_5_15.patch"
    verifyghost
    echo "::endgroup::"
}

# do-verify [family...] -- defaults to every family `all` always verifies all four; a builder that ships only some of them can name the ones it applied..
executeverify() {
    need COMMONKERNELFOLDER
    local f
    [ $# -gt 0 ] || set -- hookless hook pathhide ghost
    echo "::group::verify the nomount-suite stack landed.."
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

case "$CMD" in
all)
    need WORKSPACEDIR NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER KSUFOLDER
    resolvekernelversion
    resolveksusource
    executehookless
    if [ -n "${GITHUB_ENV:-}" ]; then executerecordversion; fi
    executehook
    executepathhide
    executeghost
    executeverify hookless hook pathhide ghost
    ;;
hookless)
    need WORKSPACEDIR COMMONKERNELFOLDER
    resolvekernelversion
    executehookless
    ;;
record-version)
    executerecordversion
    ;;
hook)
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER KSUFOLDER
    resolvekernelversion
    resolveksusource
    executehook
    ;;
pathhide)
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER
    resolvekernelversion
    executepathhide
    ;;
ghost)
    need NMSUITEKERNELPATCHESFOLDER COMMONKERNELFOLDER
    resolvekernelversion
    executeghost
    ;;
verify)
    need COMMONKERNELFOLDER
    resolvekernelversion
    executeverify "$@"
    ;;
assert-config)
    need COMMONKERNELFOLDER
    CONFIGSTRICT=1
    assertconfig CONFIG_NOMOUNT "the engine is behind config-nomount; without it fs/nomount obj is not built at all"
    assertconfig CONFIG_SECURITY_SELINUX "every hook guard is compiled only under config-security-selinux"
    ;;
*)
    usage
    ;;
esac
