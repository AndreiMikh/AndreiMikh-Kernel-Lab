#!/usr/bin/env bash
usage() {
    cat <<'EOF'
usage:
  applynomountstack <command>
commands:
  all            clone repositories and apply the complete nomount suite stack
  clone          clone or update nomount suite repositories
  hookless       apply the nomount suite prism hookless integration
  hook           apply nomount suite selinux hook patches
  pathhide       apply the matching pathhide patches
  ghost          apply the matching ghost patches
  verify         verify the complete nomount suite integration
  assert-config
                 verify required kernel configuration
environment:
  WORKDIR               kernel workspace
  KERNELPLATFORM        kernel platform directory
  COMMONKERNELFOLDER    common kernel source directory
  DEFCONFIG             kernel defconfig
  ROOTENGINE            selected kernelsu engine
  NOMOUNT_REF           nomount suite branch or tag, default: main
  NOMOUNTPATCHES_REF    kernel patches branch or tag, default: main
EOF
}
error() {
    echo "::error::nm-suite-integration: $*" >&2
    exit 1
}
need() {
    local var
    for var in "$@"; do
        [ -n "${!var:-}" ] ||
            error "$var is not set"
    done
}
has() {
    grep -Fq -- "$2" "$1" ||
        error "$3"
}
hasnt() {
    if grep -Fq -- "$2" "$1" 2>/dev/null; then
        error "$3"
    fi
    return 0
}
objy() {
    local makefile="$1"
    local object="$2"
    local message="$3"
    local escaped
    escaped="${object//./[.]}"
    grep -qE \
        "^obj-y[[:space:]]*\+=[[:space:]]*$escaped([[:space:]]|\$)" \
        "$makefile" ||
        error "$message: no 'obj-y += $object' line in $makefile"
}
resolvepaths() {
    need \
        WORKDIR \
        KERNELPLATFORM \
        COMMONKERNELFOLDER \
        DEFCONFIG
    NOMOUNTSUITE="${WORKDIR}/NoMount-Suite"
    NOMOUNTPATCHES="${WORKDIR}/kernel_patches"
    HOOKLESSDIR="${NOMOUNTSUITE}/hookless"
    HOOKDIR="${NOMOUNTPATCHES}/common/_hook"
    PATHHIDEDIR="${NOMOUNTPATCHES}/common/_pathhide"
    GHOSTDIR="${NOMOUNTPATCHES}/common/_ghost"
    export \
        NOMOUNTSUITE \
        NOMOUNTPATCHES \
        HOOKLESSDIR \
        HOOKDIR \
        PATHHIDEDIR \
        GHOSTDIR
}
resolvekernelversion() {
    local version
    local patchlevel
    [ -f "${COMMONKERNELFOLDER}/Makefile" ] ||
        error "kernel makefile not found: ${COMMONKERNELFOLDER}/Makefile"
    version="$(
        sed -n \
            's/^VERSION[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
            "${COMMONKERNELFOLDER}/Makefile" |
        head -n1
    )"
    patchlevel="$(
        sed -n \
            's/^PATCHLEVEL[[:space:]]*=[[:space:]]*\([0-9][0-9]*\).*/\1/p' \
            "${COMMONKERNELFOLDER}/Makefile" |
        head -n1
    )"
    [ -n "$version" ] ||
        error "cannot read version from ${COMMONKERNELFOLDER}/Makefile"
    [ -n "$patchlevel" ] ||
        error "cannot read patchlevel from ${COMMONKERNELFOLDER}/Makefile"
    KERNELVERSION="${version}.${patchlevel}"
    case "$KERNELVERSION" in
        5.10|5.15|6.1|6.6|6.12)
            ;;
        *)
            error \
                "kernel ${KERNELVERSION} is not one of 5.10, 5.15, 6.1, 6.6, 6.12 -- refusing to guess patch variants"
            ;;
    esac
    export KERNELVERSION
    echo "kernel version: ${KERNELVERSION}"
}
resolveksudir() {
    need \
        KERNELPLATFORM \
        ROOTENGINE
    case "$ROOTENGINE" in
        SukiSU-Ultra|ReSukiSU|KernelSU)
            KSUDIR="${KERNELPLATFORM}/KernelSU"
            ;;
        KernelSU-Next)
            KSUDIR="${KERNELPLATFORM}/KernelSU-Next"
            ;;
        *)
            error "unsupported root engine: ${ROOTENGINE}"
            ;;
    esac
    [ -d "$KSUDIR" ] ||
        error "root engine directory not found: ${KSUDIR}"
    export KSUDIR
}
clonerepository() {
    local url="$1"
    local branch="$2"
    local directory="$3"
    if [ ! -d "${directory}/.git" ]; then
        echo "cloning ${url}@${branch}"
        rm -rf "$directory"
        git clone \
            --depth=1 \
            --branch "$branch" \
            "$url" \
            "$directory"
        return 0
    fi

    echo "updating $(basename "$directory")@${branch}"
    git -C "$directory" fetch \
        --depth=1 \
        origin \
        "$branch"
    git -C "$directory" checkout \
        --force \
        "$branch"
    git -C "$directory" reset \
        --hard \
        "origin/${branch}"
    git -C "$directory" clean \
        -fd
}
clonerepositories() {
    resolvepaths
    clonerepository \
        "https://github.com/Bouteillepleine/NoMount-Suite.git" \
        "${NOMOUNT_REF:-main}" \
        "$NOMOUNTSUITE"
    clonerepository \
        "https://github.com/Bouteillepleine/kernel_patches.git" \
        "${NOMOUNTPATCHES_REF:-main}" \
        "$NOMOUNTPATCHES"
    [ -d "$HOOKLESSDIR" ] ||
        error "nomount suite hookless directory not found: $HOOKLESSDIR"
    [ -d "$HOOKDIR" ] ||
        error "nomount suite hook directory not found: $HOOKDIR"
    [ -d "$PATHHIDEDIR" ] ||
        error "nomount suite pathhide directory not found: $PATHHIDEDIR"
    [ -d "$GHOSTDIR" ] ||
        error "nomount suite ghost directory not found: $GHOSTDIR"
}
configpath() {
    [ -f "${DEFCONFIG:-}" ] ||
        error "defconfig not found: ${DEFCONFIG:-unset}"
    echo "$DEFCONFIG"
}
assertconfig() {
    local symbol="$1"
    local value="$2"
    local config
    config="$(configpath)"
    grep -qx \
        "${symbol}=${value}" \
        "$config" ||
        error "${symbol}=${value} is missing from ${config}"
}
setconfig() {
    local symbol="$1"
    local value="$2"
    local config
    config="$(configpath)"
    if grep -qE "^${symbol}=" "$config"; then
        sed -i \
            "s/^${symbol}=.*/${symbol}=${value}/" \
            "$config"
    else
        printf '%s\n' "${symbol}=${value}" >> "$config"
    fi
}
normalise() {
    if command -v dos2unix >/dev/null 2>&1; then
        dos2unix "$@" >/dev/null 2>&1 || true
        return 0
    fi

    local file
    for file in "$@"; do
        [ -f "$file" ] || continue
        if grep -qU "$(printf '\r')" "$file" 2>/dev/null; then
            error \
                "$file has crlf line endings and dos2unix is not installed"
        fi
    done
}
applypatch() {
    local patch="$1"
    local target="${2:-$COMMONKERNELFOLDER}"
    [ -f "$patch" ] ||
        error "patch not found: $patch"
    echo "applying $(basename "$patch")"
    if patch \
        -p1 \
        -F0 \
        --forward \
        --dry-run \
        -d "$target" \
        < "$patch" \
        >/dev/null 2>&1; then
        patch \
            -p1 \
            -F0 \
            --forward \
            -d "$target" \
            < "$patch" \
            >/dev/null
        echo "applied: $(basename "$patch")"
        return 0
    fi

    if patch \
        -p1 \
        -F0 \
        --reverse \
        --dry-run \
        -d "$target" \
        < "$patch" \
        >/dev/null 2>&1; then
        echo "already applied: $(basename "$patch")"
        return 0
    fi
 
    error \
        "$(basename "$patch") does not apply at fuzz 0 and is not already applied in $target"
}
applyfirst() {
    local family="$1"
    local wanted="$2"
    shift 2
    local patch
    local selected=""
    local hits=()
    local basename
    for patch in "$@"; do
        [ -f "$patch" ] ||
            error "${family}: patch file missing: $patch"
        if patch \
            -p1 \
            -F0 \
            --forward \
            --dry-run \
            -d "$COMMONKERNELFOLDER" \
            < "$patch" \
            >/dev/null 2>&1 ||
            patch \
                -p1 \
                -F0 \
                --reverse \
                --dry-run \
                -d "$COMMONKERNELFOLDER" \
                < "$patch" \
                >/dev/null 2>&1; then
            basename="$(basename "$patch")"
            hits+=("$basename")
            if [ -z "$selected" ]; then
                selected="$patch"
            fi

            if [ "$basename" = "$wanted" ]; then
                selected="$patch"
            fi
        fi

    done
    [ "${#hits[@]}" -gt 0 ] ||
        error \
            "${family}: no variant applies at fuzz 0 on ${KERNELVERSION}"
    if [ "$wanted" = "-" ]; then
        [ "${#hits[@]}" -eq 1 ] ||
            error \
                "${family}: multiple variants apply and no variant is pinned: ${hits[*]}"
    else
        local found=false
        for basename in "${hits[@]}"; do
            if [ "$basename" = "$wanted" ]; then
                found=true
                break
            fi
 
        done
        [ "$found" = true ] ||
            error \
                "${family}: pinned variant '${wanted}' does not apply at fuzz 0 on ${KERNELVERSION}; applicable variants: ${hits[*]}"
        if [ "${#hits[@]}" -gt 1 ]; then
            echo \
                "${family}: '${wanted}' pinned; other applicable variants: ${hits[*]}"
        fi
    fi
 
    [ -n "$selected" ] ||
        error "${family}: no patch selected"
    applypatch "$selected" "$COMMONKERNELFOLDER"
}
infn() {
    local file="$1"
    local function="$2"
    local needle="$3"
    local message="$4"
    local segment
    segment="$(
        awk \
            "/$function/,/^}/" \
            "$file" \
            2>/dev/null
    )" || true
    case "$segment" in
        *"$needle"*)
            return 0
            ;;
    esac
    error "$message"
}
awkplacement() {
    awk '
        /^static (int|noinline int) selinux_[a-z_]+\(/ {
            fn = $0
            avc = 0
        }
        /avc_has_perm/ {
            avc = 1
        }
        /:ksu:/ {
            if (!avc) {
                print "EARLY " fn > "/dev/stderr"
                bad = 1
            }
        }
        END {
            exit bad ? 1 : 0
        }
    ' "$1"
}
verifyhookless() {
    local d="$COMMONKERNELFOLDER"
    [ -f "$d/fs/nomount.c" ] ||
        error "hookless: fs/nomount.c missing"
    [ -f "$d/fs/nomount.h" ] ||
        error "hookless: fs/nomount.h missing"
    has \
        'config NOMOUNT' \
        "$d/fs/Kconfig" \
        "hookless: fs/kconfig edit missing"
    has \
        'obj-$(CONFIG_NOMOUNT) += nomount.o' \
        "$d/fs/Makefile" \
        "hookless: fs/makefile edit missing"
    grep -qE \
        'vfs_map_meta_override|nomount_spoof_mmap_metadata' \
        "$d/fs/proc/task_mmu.c" ||
        error "hookless: taskmmu.c hook missing"
    assertconfig CONFIG_NOMOUNT y
    echo "hookless: verified"
}
verifyhook() {
    local d="$COMMONKERNELFOLDER"
    [ -f "$d/security/selinux/selinuxfs.c" ] ||
        error "hook: security/selinux/selinuxfs.c missing"
    [ -f "$d/security/selinux/hooks.c" ] ||
        error "hook: security/selinux/hooks.c missing"
    [ -f "$d/security/selinux/avc.c" ] ||
        error "hook: security/selinux/avc.c missing"
    has \
        'sel_ctx_hidden' \
        "$d/security/selinux/selinuxfs.c" \
        "hook: selinuxfs.c gate missing"
    has \
        'sel_hidden_bytes' \
        "$d/security/selinux/selinuxfs.c" \
        "hook: selinuxfs.c reply filter missing"
    has \
        ':ksu:' \
        "$d/security/selinux/hooks.c" \
        "hook: hooks.c attr guard missing"
    infn \
        "$d/security/selinux/hooks.c" \
        '^static int selinux_inode_setxattr' \
        ':ksu:' \
        "hook: selinuxinodesetxattr() has no hidden-type guard"
    case "$KERNELVERSION" in
        6.12)
            infn \
                "$d/security/selinux/hooks.c" \
                '^static int selinux_lsm_setattr' \
                ':ksu:' \
                "hook: selinuxlsmsetattr() has no hidden-type guard"
            ;;
        *)
            infn \
                "$d/security/selinux/hooks.c" \
                '^static int selinux_setprocattr' \
                ':ksu:' \
                "hook: selinuxsetprocattr() has no hidden-type guard"
            ;;
    esac
    has \
        ':ksu:' \
        "$d/security/selinux/avc.c" \
        "hook: avc.c denial filter missing"
    has \
        'current_uid()' \
        "$d/security/selinux/avc.c" \
        "hook: avc.c filter has lost its uid gate"
    has \
        'selinuxfs.o' \
        "$d/security/selinux/Makefile" \
        "hook: selinuxfs.o is not in security/selinux/makefile"
    local writefunction
    for writefunction in \
        sel_write_context \
        sel_write_validatetrans \
        sel_write_access \
        sel_write_create \
        sel_write_relabel \
        sel_write_user \
        sel_write_member
    do
        infn \
            "$d/security/selinux/selinuxfs.c" \
            "^static ssize_t ${write_function}\\(" \
            'sel_ctx_hidden' \
            "hook: ${write_function}() has no sel_ctx_hidden() gate"
    done
    local nfs
    local nhooks
    local navc
    nfs="$(
        grep -o '":[a-z_]*:"' \
            "$d/security/selinux/selinuxfs.c" |
        sort -u |
        tr '\n' ' '
    )"
    nhooks="$(
        grep -o '":[a-z_]*:"' \
            "$d/security/selinux/hooks.c" |
        sort -u |
        tr '\n' ' '
    )"
    navc="$(
        grep -o '":[a-z_]*:"' \
            "$d/security/selinux/avc.c" |
        sort -u |
        tr '\n' ' '
    )"
    [ -n "$nfs" ] ||
        error "hook: no hidden-type list found in selinuxfs.c"
    [ "$nfs" = "$nhooks" ] ||
        error \
            "hook: hidden-type list differs between selinuxfs.c [$nfs] and hooks.c [$nhooks]"
    [ "$nfs" = "$navc" ] ||
        error \
            "hook: hidden-type list differs between selinuxfs.c [$nfs] and avc.c [$navc]"
    echo "hook: hidden-type list mirrored in 3 files: $nfs"
    awkplacement "$d/security/selinux/hooks.c" ||
        error \
            "hook: hidden-type guard appears before the avchasperm() of its own function"
    need KSUDIR
    [ -f "$KSUDIR/kernel/selinux/rules.c" ] ||
        error \
            "hook: $KSUDIR/kernel/selinux/rules.c does not exist"
    hasnt \
        'selinux_status_update_policyload' \
        "$KSUDIR/kernel/selinux/rules.c" \
        "hook: fixselinuxseqno did not land"
    has \
        'selnl_notify_policyload' \
        "$KSUDIR/kernel/selinux/rules.c" \
        "hook: selnlnotifypolicyload was removed"
    assertconfig \
        CONFIG_SECURITY_SELINUX \
        y
    echo "hook: verified"
}
verifypathhide() {
    local d="$COMMONKERNELFOLDER"
    [ -f "$d/fs/pathhide.c" ] ||
        error "pathhide: fs/pathhide.c missing"
    [ -f "$d/fs/pathhide.h" ] ||
        error "pathhide: fs/pathhide.h missing"
    objy \
        "$d/fs/Makefile" \
        'pathhide.o' \
        "pathhide"
    has \
        'pathhide_match_file' \
        "$d/fs/proc/task_mmu.c" \
        "pathhide: maps/smaps guards missing from taskmmu.c"
    has \
        'pathhide_match_file' \
        "$d/fs/proc/base.c" \
        "pathhide: mapfiles guards missing from base.c"
    infn \
        "$d/fs/proc/task_mmu.c" \
        '^static int pagemap_pmd_range' \
        'pathhide_match_file' \
        "pathhide: pagemap guard is not inside pagemappmdrange()"
    infn \
        "$d/mm/mincore.c" \
        '^static long do_mincore' \
        'pathhide_match_file' \
        "pathhide: mincore guard is not inside domincore()"
    infn \
        "$d/fs/proc/task_mmu.c" \
        '^void task_mem' \
        'pathhide_hidden_vm_pages' \
        "pathhide: vmsize/vmpeak deduction is not inside taskmem()"
    infn \
        "$d/fs/proc/task_mmu.c" \
        '^unsigned long task_statm' \
        'pathhide_hidden_vm_pages' \
        "pathhide: statm size deduction is not inside taskstatm()"
    case "$KERNELVERSION" in
        6.12)
            infn \
                "$d/fs/proc/task_mmu.c" \
                '^static int pagemap_scan_test_walk' \
                'pathhide_match_file' \
                "pathhide: pagemapscan guard is not inside pagemapscantestwalk()"
            ;;
    esac
    hasnt \
        'pathhide' \
        "$d/fs/proc/fd.c" \
        "pathhide: fs/proc/fd.c is patched again"
    echo "pathhide: verified"
}
verifyghost() {
    local d="$COMMONKERNELFOLDER"
    local count
    [ -f "$d/fs/proc/ghost.c" ] ||
        error "ghost: fs/proc/ghost.c missing"
    [ -f "$d/fs/proc/ghost.h" ] ||
        error "ghost: fs/proc/ghost.h missing"
    objy \
        "$d/fs/proc/Makefile" \
        'ghost.o' \
        "ghost"
    infn \
        "$d/fs/namei.c" \
        '^static int do_o_path' \
        'ghost_hidden_path(&path))' \
        "ghost: opath guard is not inside doopath()"
    infn \
        "$d/fs/namei.c" \
        '^static int do_open' \
        'unlikely(ghost_hidden_path(&nd->path))' \
        "ghost: open guard is not inside doopen()"
    infn \
        "$d/fs/namei.c" \
        '^static int path_lookupat' \
        'unlikely(err == -ENOTDIR)' \
        "ghost: enotdir guard is not inside pathlookupat()"
    infn \
        "$d/fs/namei.c" \
        '^static int path_parentat' \
        'unlikely(err == -ENOTDIR)' \
        "ghost: enotdir guard is not inside pathparentat()"
    infn \
        "$d/fs/namei.c" \
        '^static struct dentry \*filename_create' \
        'error = err2 ? err2 : -EACCES' \
        "ghost: create guard is not inside filenamecreate()"
    infn \
        "$d/fs/namei.c" \
        '^(static )?int do_linkat' \
        'ghost_hidden_path(&old_path)' \
        "ghost: link guard is not inside dolinkat()"
    infn \
        "$d/fs/open.c" \
        '^int do_fchownat' \
        'ghost_hidden_path(&path))' \
        "ghost: chown guard is not inside dofchownat()"
    infn \
        "$d/fs/stat.c" \
        '^static int do_readlinkat' \
        'ghost_hidden_path(&path))' \
        "ghost: readlink guard is not inside doreadlinkat()"
    infn \
        "$d/fs/open.c" \
        '^static long do_faccessat' \
        'unlikely(ghost_hidden_path(&path))' \
        "ghost: access guard is not inside dofaccessat()"
    infn \
        "$d/fs/stat.c" \
        '^(static )?int vfs_statx' \
        'ghost_hidden_path(&path))' \
        "ghost: stat guard is not inside vfsstatx()"
    infn \
        "$d/fs/open.c" \
        'do_fchmodat' \
        'ghost_hidden_path(&path))' \
        "ghost: chmod guard is not inside dofchmodat()"
    infn \
        "$d/fs/open.c" \
        '^(long|int) do_sys_truncate' \
        'ghost_hidden_path(&path))' \
        "ghost: truncate guard is not inside dosystruncate()"
    infn \
        "$d/fs/utimes.c" \
        '^(static )?(long|int) do_utimes_path' \
        'ghost_hidden_path(&path))' \
        "ghost: utimensat guard is not inside doutimespath()"
    local writefunction
    for writefunction in \
        path_setxattr \
        path_getxattr \
        path_listxattr \
        path_removexattr
    do
        infn \
            "$d/fs/xattr.c" \
            "^static (ssize_t|int) ${writefunction}\\(" \
            'ghost_hidden_path(&path))' \
            "ghost: ${writefunction}() has no ghosthiddenpath() guard"
    done
    count="$(
        grep -c \
            'ghost_hidden_path' \
            "$d/fs/xattr.c" \
            2>/dev/null
    )"
    [ "$count" -eq 8 ] ||
        error \
            "ghost: fs/xattr.c has ${count} ghosthiddenpath references, expected 8"
    infn \
        "$d/fs/namei.c" \
        '^int do_renameat2' \
        'struct path gpath = { .mnt = old_path.mnt, .dentry = old_dentry }' \
        "ghost: rename source guard is not inside dorenameat2()"
    if awk \
        '/^int do_renameat2/,/^}/' \
        "$d/fs/namei.c" |
        grep -q 'err2'
    then
        error \
            "ghost: create guard landed in dorenameat2 instead of filenamecreate"
    fi

    hasnt \
        'proc_create' \
        "$d/fs/proc/ghost.c" \
        "ghost: ghost.c owns a /proc node"
    echo "ghost: verified"
}

dohookless() {
    resolvepaths
    local nmpatch
    local nm_ref="${NOMOUNT_REF:-main}"
    echo "::group::apply nomount suite hookless integration"
    rm -f \
        "$COMMONKERNELFOLDER/fs/nomount.c" \
        "$COMMONKERNELFOLDER/fs/nomount.h"
    [ -f "$HOOKLESSDIR/src/nomount.c" ] ||
        error "nomount suite source missing: $HOOKLESSDIR/src/nomount.c"
    [ -f "$HOOKLESSDIR/src/nomount.h" ] ||
        error "nomount suite source missing: $HOOKLESSDIR/src/nomount.h"
    cp \
        "$HOOKLESSDIR/src/nomount.c" \
        "$COMMONKERNELFOLDER/fs/nomount.c"
    cp \
        "$HOOKLESSDIR/src/nomount.h" \
        "$COMMONKERNELFOLDER/fs/nomount.h"
    normalise \
        "$COMMONKERNELFOLDER/fs/nomount.c" \
        "$COMMONKERNELFOLDER/fs/nomount.h"
    nmpatch="$HOOKLESSDIR/patches/nomount_kernel_integration.patch"
    if [ ! -f "$nmpatch" ]; then
        nmpatch="$HOOKLESSDIR/patches/nomount_${KERNELVERSION}_kernel_integration.patch"
    fi

    [ -f "$nmpatch" ] ||
        error \
            "nomount suite hookless integration patch not found for ${KERNELVERSION}"
    normalise "$nmpatch"
    echo "hookless integration patch: $(basename "$nmpatch")"
    if patch \
        -p1 \
        -F0 \
        --forward \
        --dry-run \
        -d "$COMMONKERNELFOLDER" \
        < "$nmpatch" \
        >/dev/null 2>&1; then
        patch \
            -p1 \
            -F0 \
            --forward \
            -d "$COMMONKERNELFOLDER" \
            < "$nmpatch" \
            >/dev/null
        echo "hookless integration: applied at fuzz 0"
    elif patch \
        -p1 \
        -F0 \
        --reverse \
        --dry-run \
        -d "$COMMONKERNELFOLDER" \
        < "$nmpatch" \
        >/dev/null 2>&1; then
        echo "hookless integration: already applied"
    else
        echo "::warning::hookless integration patch does not apply at fuzz 0 on ${KERNELVERSION}; retrying at fuzz 1"
        patch \
            -p1 \
            --forward \
            --fuzz=1 \
            -d "$COMMONKERNELFOLDER" \
            < "$nmpatch" ||
            error \
                "nomount suite hookless integration failed at fuzz 0 and fuzz 1"
    fi

    setconfig CONFIG_NOMOUNT y
    assertconfig CONFIG_NOMOUNT y
    verifyhookless
    echo "::endgroup::"
}
dorecordversion() {
    resolvepaths
    local header="$HOOKLESSDIR/src/nomount.h"
    local version=""
    if [ -f "$header" ]; then
        version="$(
            sed -n \
                's/^#define[[:space:]]\+NM_MODULE_VERSION[[:space:]]\+"\([^"]*\)".*/\1/p' \
                "$header" |
            head -n1
        )
    fi

    echo "nomount suite version: ${version:-unknown}"
    if [ -n "${GITHUB_ENV:-}" ]; then
        echo "NMVER=${version:-unknown}" >> "$GITHUB_ENV"
    fi
}
dohook() {
    resolvepaths
    resolveksudir
    echo "::group::apply nomount suite selinux hook patches"
    normalise "$HOOKDIR"/*.patch
    local reqsfs
    local reqattr
    local reqaudit
    case "$KERNELVERSION" in
        6.6|6.12)
            reqsfs=hide_selinux_selinuxfs_6_12.patch
            reqaudit=quiet_selinux_audit.patch
            ;;
        5.10|5.15|6.1)
            reqsfs=hide_selinux_selinuxfs_5_10.patch
            reqaudit=quiet_selinux_audit_legacy.patch
            ;;
    esac
    case "$KERNELVERSION" in
        6.12)
            reqattr=hide_selinux_attr_6_12.patch
            ;;
        6.6)
            reqattr=hide_selinux_attr_6_6.patch
            ;;
        5.10|5.15|6.1)
            reqattr=hide_selinux_attr_5_10.patch
            ;;
        *)
            reqattr=hide_selinux_attr.patch
            ;;
    esac
    applyfirst \
        selinuxfs \
        "$reqsfs" \
        "$HOOKDIR/hide_selinux_selinuxfs_6_12.patch" \
        "$HOOKDIR/hide_selinux_selinuxfs_5_10.patch"
    applyfirst \
        attr \
        "$reqattr" \
        "$HOOKDIR/hide_selinux_attr_6_12.patch" \
        "$HOOKDIR/hide_selinux_attr_6_6.patch" \
        "$HOOKDIR/hide_selinux_attr_5_10.patch" \
        "$HOOKDIR/hide_selinux_attr.patch"
    applyfirst \
        avc-audit \
        "$reqaudit" \
        "$HOOKDIR/quiet_selinux_audit.patch" \
        "$HOOKDIR/quiet_selinux_audit_legacy.patch"
    applypatch \
        "$HOOKDIR/fix_selinux_seqno.patch" \
        "$KSUDIR"
    verifyhook
    echo "::endgroup::"
}
dopathhide() {
    resolvepaths
    local d="$COMMONKERNELFOLDER"
    echo "::group::apply nomount suite pathhide patches"
    rm -f \
        "$d/fs/pathhide.c" \
        "$d/fs/pathhide.h"
    [ -f "$PATHHIDEDIR/pathhide.c" ] ||
        error "pathhide source missing: $PATHHIDEDIR/pathhide.c"
    [ -f "$PATHHIDEDIR/pathhide.h" ] ||
        error "pathhide source missing: $PATHHIDEDIR/pathhide.h"
    cp \
        "$PATHHIDEDIR/pathhide.c" \
        "$d/fs/pathhide.c"
    cp \
        "$PATHHIDEDIR/pathhide.h" \
        "$d/fs/pathhide.h"
    normalise \
        "$d/fs/pathhide.c" \
        "$d/fs/pathhide.h"
    normalise "$PATHHIDEDIR"/*.patch
    applypatch \
        "$PATHHIDEDIR/pathhide_${KERNELVERSION}_integration.patch"
    applypatch \
        "$PATHHIDEDIR/pathhide_mapfiles_${KERNELVERSION}_integration.patch"
    local reqpagemap
    local reqmincore
    local reqacct
    if grep -q \
        'pagemap_scan_test_walk' \
        "$d/fs/proc/task_mmu.c"
    then
        reqpagemap=pathhide_pagemap_6.12_integration.patch
    elif awk \
        '/^static int pagemap_pmd_range/,/^}/' \
        "$d/fs/proc/task_mmu.c" |
        grep -q 'bool migration'
    then
        reqpagemap=pathhide_pagemap_5.10_integration.patch
    else
        reqpagemap=pathhide_pagemap_6.6_integration.patch
    fi

    if grep -q \
        'vma_lookup(current->mm, addr)' \
        "$d/mm/mincore.c"
    then
        reqmincore=pathhide_mincore_6.12_integration.patch
    else
        reqmincore=pathhide_mincore_5.10_integration.patch
    fi

    if grep -q \
        '__page_size_count(mm->total_vm)' \
        "$d/fs/proc/task_mmu.c"
    then
        reqacct=pathhide_accounting_pgcompat_integration.patch
    elif grep -q \
        'get_mm_counter_sum(mm, MM_ANONPAGES)' \
        "$d/fs/proc/task_mmu.c"
    then
        reqacct=pathhide_accounting_6.6_integration.patch
    else
        reqacct=pathhide_accounting_integration.patch
    fi
 
    applyfirst \
        pathhide-pagemap \
        "$reqpagemap" \
        "$PATHHIDEDIR/pathhide_pagemap_6.12_integration.patch" \
        "$PATHHIDEDIR/pathhide_pagemap_6.6_integration.patch" \
        "$PATHHIDEDIR/pathhide_pagemap_5.10_integration.patch"
    applyfirst \
        pathhide-mincore \
        "$reqmincore" \
        "$PATHHIDEDIR/pathhide_mincore_6.12_integration.patch" \
        "$PATHHIDEDIR/pathhide_mincore_5.10_integration.patch"
    applyfirst \
        pathhide-accounting \
        "$reqacct" \
        "$PATHHIDEDIR/pathhide_accounting_6.6_integration.patch" \
        "$PATHHIDEDIR/pathhide_accounting_pgcompat_integration.patch" \
        "$PATHHIDEDIR/pathhide_accounting_integration.patch"
    if ! grep -qE \
        '^obj-y[[:space:]]*\+=.*pathhide\.o' \
        "$d/fs/Makefile"
    then
        echo 'obj-y += pathhide.o' >> "$d/fs/Makefile"
    fi

    verifypathhide
    echo "::endgroup::"
}
doghost() {
    resolvepaths
    local d="$COMMONKERNELFOLDER"
    echo "::group::apply nomount suite ghost patches"
    rm -f \
        "$d/fs/proc/ghost.c" \
        "$d/fs/proc/ghost.h"
    [ -f "$GHOSTDIR/ghost.c" ] ||
        error "ghost source missing: $GHOSTDIR/ghost.c"
    [ -f "$GHOSTDIR/ghost.h" ] ||
        error "ghost source missing: $GHOSTDIR/ghost.h"
    cp \
        "$GHOSTDIR/ghost.c" \
        "$d/fs/proc/ghost.c"
    cp \
        "$GHOSTDIR/ghost.h" \
        "$d/fs/proc/ghost.h"
    normalise \
        "$d/fs/proc/ghost.c" \
        "$d/fs/proc/ghost.h"
    normalise "$GHOSTDIR"/*.patch
    local reqxattr
    local reqlinkat
    local reqchmod
    case "$KERNELVERSION" in
        6.12|6.6)
            reqxattr=ghost_xattr_6_12.patch
            reqlinkat=ghost_linkat_5_15.patch
            reqchmod=ghost_chmod.patch
            ;;
        6.1|5.15)
            reqxattr=ghost_xattr_5_15.patch
            reqlinkat=ghost_linkat_5_15.patch
            reqchmod=ghost_chmod_5_10.patch
            ;;
        5.10)
            reqxattr=ghost_xattr.patch
            reqlinkat=ghost_linkat.patch
            reqchmod=ghost_chmod_5_10.patch
            ;;
    esac
    applypatch \
        "$GHOSTDIR/ghost_o_path.patch"
    applyfirst \
        ghost-xattr \
        "$reqxattr" \
        "$GHOSTDIR/ghost_xattr_6_12.patch" \
        "$GHOSTDIR/ghost_xattr_5_15.patch" \
        "$GHOSTDIR/ghost_xattr.patch"
    applyfirst \
        ghost-linkat \
        "$reqlinkat" \
        "$GHOSTDIR/ghost_linkat_5_15.patch" \
        "$GHOSTDIR/ghost_linkat.patch"
    applypatch \
        "$GHOSTDIR/ghost_notdir.patch"
    applypatch \
        "$GHOSTDIR/ghost_truncate.patch"
    applypatch \
        "$GHOSTDIR/ghost_utimes.patch"
    applyfirst \
        ghost-chmod \
        "$reqchmod" \
        "$GHOSTDIR/ghost_chmod.patch" \
        "$GHOSTDIR/ghost_chmod_5_10.patch"
    applypatch \
        "$GHOSTDIR/ghost_chown.patch"
    applypatch \
        "$GHOSTDIR/ghost_access.patch"
    applypatch \
        "$GHOSTDIR/ghost_open.patch"
    applypatch \
        "$GHOSTDIR/ghost_create.patch"
    applypatch \
        "$GHOSTDIR/ghost_build_integration.patch"
    local reqstatx
    case "$KERNELVERSION" in
        6.12)
            reqstatx=ghost_statx_6_12.patch
            ;;
        6.6|6.1)
            reqstatx=ghost_statx_6_1.patch
            ;;
        5.15|5.10)
            reqstatx=ghost_statx_5_10.patch
            ;;
    esac
    applyfirst \
        ghost-statx \
        "$reqstatx" \
        "$GHOSTDIR/ghost_statx_6_12.patch" \
        "$GHOSTDIR/ghost_statx_6_1.patch" \
        "$GHOSTDIR/ghost_statx_5_10.patch"
    local reqreadlink
    case "$KERNELVERSION" in
        6.12)
            reqreadlink=ghost_readlink_6_12.patch
            ;;
        *)
            reqreadlink=ghost_readlink_5_10.patch
            ;;
    esac
    applyfirst \
        ghost-readlink \
        "$reqreadlink" \
        "$GHOSTDIR/ghost_readlink_6_12.patch" \
        "$GHOSTDIR/ghost_readlink_5_10.patch"
    local reqrename
    case "$KERNELVERSION" in
        5.10)
            reqrename=ghost_rename_5_10.patch
            ;;
        *)
            reqrename=ghost_rename_5_15.patch
            ;;
    esac
    applyfirst \
        ghost-rename \
        "$reqrename" \
        "$GHOSTDIR/ghost_rename_5_10.patch" \
        "$GHOSTDIR/ghost_rename_5_15.patch"
    verifyghost
    echo "::endgroup::"
}
verifykernelchange() {
    local source="$COMMONKERNELFOLDER/fs"
    [ -d "$source" ] ||
        error "kernel fs directory not found: $source"
    [ -f "$source/nomount.c" ] ||
        error "fs/nomount.c is missing"
    [ -f "$source/pathhide.c" ] ||
        error "fs/pathhide.c is missing"
    [ -f "$source/proc/ghost.c" ] ||
        error "fs/proc/ghost.c is missing"
    has \
        'CONFIG_NOMOUNT' \
        "$source/Kconfig" \
        "config nomount is missing from fs/kconfig"
    echo "nomount suite kernel integration detected"
}
doverify() {
    resolvepaths
    resolvekernelversion
    resolveksudir
    echo "::group::verify nomount suite integration"
    echo "kernel version: $KERNELVERSION"
    echo "kernel platform: $KERNELPLATFORM"
    echo "common kernel: $COMMONKERNELFOLDER"
    echo "defconfig: $DEFCONFIG"
    echo "nomount suite: $NOMOUNTSUITE"
    echo "kernel patches: $NOMOUNTPATCHES"
    echo "root engine: $ROOTENGINE"
    echo "root engine directory: $KSUDIR"
    verifyhookless
    verifyhook
    verifypathhide
    verifyghost
    verifykernelchange
    assertconfig \
        CONFIG_NOMOUNT \
        y
    assertconfig \
        CONFIG_SECURITY_SELINUX \
        y
    echo "nomount suite integration verification passed"
    echo "::endgroup::"
}
doall() {
    need \
        WORKDIR \
        KERNELPLATFORM \
        COMMONKERNELFOLDER \
        DEFCONFIG \
        ROOTENGINE
    resolvepaths
    resolvekernelversion
    resolveksudir
    clonerepositories
    echo "root engine: $ROOTENGINE"
    echo "root engine directory: $KSUDIR"
    dohookless
    dorecordversion
    dohook
    dopathhide
    doghost
    doverify
}
CMD="${1:-all}"
case "$CMD" in
    all)
        doall
        ;;
    clone)
        need \
            WORKDIR \
            KERNELPLATFORM \
            COMMONKERNELFOLDER \
            DEFCONFIG
        clonerepositories
        ;;
    hookless)
        need \
            WORKDIR \
            KERNELPLATFORM \
            COMMONKERNELFOLDER \
            DEFCONFIG
        resolvekernelversion
        clonerepositories
        dohookless
        ;;
    hook)
        need \
            WORKDIR \
            KERNELPLATFORM \
            COMMONKERNELFOLDER \
            DEFCONFIG \
            ROOTENGINE
        resolvekernelversion
        resolveksudir
        clonerepositories
        dohook
        ;;
    pathhide)
        need \
            WORKDIR \
            KERNELPLATFORM \
            COMMONKERNELFOLDER \
            DEFCONFIG
        resolvekernelversion
        clonerepositories
        dopathhide
        ;;
    ghost)
        need \
            WORKDIR \
            KERNELPLATFORM \
            COMMONKERNELFOLDER \
            DEFCONFIG
        resolvekernelversion
        clonerepositories
        doghost
        ;;
    verify)
        need \
            WORKDIR \
            KERNELPLATFORM \
            COMMONKERNELFOLDER \
            DEFCONFIG \
            ROOTENGINE
        resolvekernelversion
        resolveksudir
        clonerepositories
        doverify
        ;;
    assert-config)
        need \
            COMMONKERNELFOLDER \
            DEFCONFIG
        assertconfig \
            CONFIG_NOMOUNT \
            y
        assertconfig \
            CONFIG_SECURITY_SELINUX \
            y
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        error "unknown command: $CMD"
        ;;
esac
