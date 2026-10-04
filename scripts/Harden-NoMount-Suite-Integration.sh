#!/usr/bin/env bash

usage() {
    cat <<'USAGE'
usage:
  applynomountstack <command>

commands:
  all            clone repositories and apply the complete NoMount Suite stack
  clone          clone or update NoMount Suite repositories
  hookless       apply the NoMount Suite Prism hookless integration
  hook           apply NoMount Suite SELinux hook patches
  record-version record NoMount Suite version
  pathhide       apply the matching pathhide patches
  ghost          apply the matching ghost patches
  verify         verify the complete NoMount Suite integration
  assert-config  verify required kernel configuration

environment:
  WORKDIR               kernel workspace
  KERNELPLATFORM        kernel platform directory
  COMMONKERNELFOLDER    common kernel source directory
  DEFCONFIG             kernel defconfig
  ROOTENGINE            selected KernelSU engine
  NOMOUNT_REF           NoMount Suite branch or tag, default: main
  NOMOUNTPATCHES_REF    kernel patches branch or tag, default: main
  PATCH_FUZZ            patch fuzz allowance, default: 3
USAGE
}

error() {
    echo "::error::nm-suite-integration: $*" >&2
    exit 1
}

need() {
    local var
    for var in "$@"; do
        [ -n "${!var:-}" ] || error "$var is not set"
    done
}

has() {
    local needle="$1"
    local file="$2"
    local message="$3"
    grep -Fq -- "$needle" "$file" || error "$message"
}

hasnt() {
    local needle="$1"
    local file="$2"
    local message="$3"
    if grep -Fq -- "$needle" "$file" 2>/dev/null; then
        error "$message"
    fi
}

objy() {
    local makefile="$1"
    local object="$2"
    local message="$3"
    local escaped
    escaped="${object//./[.]}"
    grep -qE \
        "^obj-y[[:space:]]*\\+=[[:space:]]*$escaped([[:space:]]|\$)" \
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
            "$directory" ||
            error "failed to clone ${url}@${branch}"
        return 0
    fi

    echo "updating $(basename "$directory")@${branch}"

    git -C "$directory" fetch \
        --depth=1 \
        origin \
        "$branch" ||
        error "failed to fetch ${url}@${branch}"

    git -C "$directory" checkout \
        --force \
        "$branch" ||
        error "failed to checkout ${branch} in ${directory}"

    git -C "$directory" reset \
        --hard \
        "origin/${branch}" ||
        error "failed to reset ${directory} to origin/${branch}"

    git -C "$directory" clean \
        -fd ||
        error "failed to clean ${directory}"
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
        error "NoMount Suite hookless directory not found: $HOOKLESSDIR"
    [ -d "$HOOKDIR" ] ||
        error "kernel patches hook directory not found: $HOOKDIR"
    [ -d "$PATHHIDEDIR" ] ||
        error "kernel patches pathhide directory not found: $PATHHIDEDIR"
    [ -d "$GHOSTDIR" ] ||
        error "kernel patches ghost directory not found: $GHOSTDIR"
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
    local tmp

    config="$(configpath)"
    tmp="${config}.nomount.tmp"

    awk -v symbol="$symbol" '$0 !~ "^" symbol "=" && $0 !~ "^# " symbol " is not set$"' \
        "$config" > "$tmp" || {
        rm -f "$tmp"
        error "failed to update ${symbol} in ${config}"
    }

    printf '%s=%s\n' "$symbol" "$value" >> "$tmp"
    mv -f "$tmp" "$config" || {
        rm -f "$tmp"
        error "failed to replace ${config}"
    }
}

normalise() {
    local file

    if command -v dos2unix >/dev/null 2>&1; then
        for file in "$@"; do
            [ -f "$file" ] || continue
            dos2unix "$file" >/dev/null 2>&1 ||
                error "failed to normalize line endings: $file"
        done
        return 0
    fi

    for file in "$@"; do
        [ -f "$file" ] || continue
        if grep -qU "$(printf '\r')" "$file" 2>/dev/null; then
            error "$file has CRLF line endings and dos2unix is not installed"
        fi
    done
}

normalisepatches() {
    local directory="$1"
    local found=false
    local patch

    while IFS= read -r -d '' patch; do
        found=true
        normalise "$patch"
    done < <(find "$directory" -maxdepth 1 -type f -name '*.patch' -print0)

    [ "$found" = true ] ||
        error "no patch files found in ${directory}"
}

PATCH_FUZZ="${PATCH_FUZZ:-3}"

case "$PATCH_FUZZ" in
    ''|*[!0-9]*)
        error "PATCH_FUZZ must be a non-negative integer: $PATCH_FUZZ"
        ;;
esac

patchforward() {
    local patchfile="$1"
    local target="$2"

    patch \
        --batch \
        --fuzz="$PATCH_FUZZ" \
        -p1 \
        --forward \
        --dry-run \
        -d "$target" \
        < "$patchfile" \
        >/dev/null 2>&1
}

patchreverse() {
    local patchfile="$1"
    local target="$2"

    patch \
        --batch \
        --fuzz="$PATCH_FUZZ" \
        -p1 \
        --reverse \
        --dry-run \
        -d "$target" \
        < "$patchfile" \
        >/dev/null 2>&1
}

patchdiagnose() {
    local patchfile="$1"
    local target="$2"

    echo "patch diagnostic: $(basename "$patchfile")"
    patch \
        --batch \
        --fuzz="$PATCH_FUZZ" \
        -p1 \
        --forward \
        --dry-run \
        -d "$target" \
        < "$patchfile" || true
}

applypatch() {
    local patchfile="$1"
    local target="${2:-$COMMONKERNELFOLDER}"

    [ -f "$patchfile" ] ||
        error "patch not found: $patchfile"

    echo "applying $(basename "$patchfile")"
    echo "  target: $target"
    echo "  fuzz: $PATCH_FUZZ"

    if patchforward "$patchfile" "$target"; then
        patch \
            --batch \
            --fuzz="$PATCH_FUZZ" \
            -p1 \
            --forward \
            -d "$target" \
            < "$patchfile" || {
            patchdiagnose "$patchfile" "$target"
            error "failed to apply $(basename "$patchfile")"
        }

        echo "  applied: $(basename "$patchfile")"
        return 0
    fi

    if patchreverse "$patchfile" "$target"; then
        echo "  already applied: $(basename "$patchfile")"
        return 0
    fi

    patchdiagnose "$patchfile" "$target"
    error \
        "$(basename "$patchfile") does not apply at fuzz ${PATCH_FUZZ} and is not already applied in $target"
}

applyfirst() {
    local family="$1"
    local wanted="$2"
    shift 2

    local patchfile
    local basename
    local selected=""
    local forward_hits=()
    local reverse_hits=()

    for patchfile in "$@"; do
        [ -f "$patchfile" ] ||
            error "${family}: patch file missing: $patchfile"

        basename="$(basename "$patchfile")"

        if patchforward "$patchfile" "$COMMONKERNELFOLDER"; then
            forward_hits+=("$basename")
            if [ -z "$selected" ] && {
                [ "$wanted" = "-" ] ||
                [ "$basename" = "$wanted" ]
            }; then
                selected="$patchfile"
            fi
        elif patchreverse "$patchfile" "$COMMONKERNELFOLDER"; then
            reverse_hits+=("$basename")
        fi
    done

    if [ -n "$selected" ]; then
        if [ "${#forward_hits[@]}" -gt 1 ]; then
            echo "  $(basename "$selected"): selected; other forward-applicable variants: ${forward_hits[*]}"
        else
            echo "  $(basename "$selected"): selected"
        fi
        applypatch "$selected" "$COMMONKERNELFOLDER"
        return 0
    fi

    if [ "$wanted" != "-" ] && [ "${#forward_hits[@]}" -gt 0 ]; then
        error \
            "${family}: pinned variant '${wanted}' does not apply at fuzz ${PATCH_FUZZ}; forward-applicable variants: ${forward_hits[*]}"
    fi

    if [ "${#forward_hits[@]}" -gt 1 ]; then
        error \
            "${family}: multiple variants apply at fuzz ${PATCH_FUZZ} and no variant is pinned: ${forward_hits[*]}"
    fi

    if [ "${#forward_hits[@]}" -eq 1 ]; then
        for patchfile in "$@"; do
            basename="$(basename "$patchfile")"
            if [ "$basename" = "${forward_hits[0]}" ]; then
                selected="$patchfile"
                break
            fi
        done
        [ -n "$selected" ] ||
            error "${family}: failed to resolve the applicable patch"
        applypatch "$selected" "$COMMONKERNELFOLDER"
        return 0
    fi

    if [ "${#reverse_hits[@]}" -eq 1 ]; then
        if [ "$wanted" != "-" ] && [ "${reverse_hits[0]}" != "$wanted" ]; then
            error \
                "${family}: pinned variant '${wanted}' is not the already-applied variant; found: ${reverse_hits[*]}"
        fi

        echo "${family}: already applied: ${reverse_hits[0]}"
        return 0
    fi

    if [ "${#reverse_hits[@]}" -gt 1 ]; then
        error \
            "${family}: multiple variants appear already applied: ${reverse_hits[*]}"
    fi

    error "${family}: no variant applies at fuzz ${PATCH_FUZZ} on ${KERNELVERSION}"
}

infn() {
    local file="$1"
    local function="$2"
    local needle="$3"
    local message="$4"
    local segment

    segment="$(
        awk -v start="$function" '
            BEGIN {
                candidate = 0
                started = 0
                depth = 0
                segment = ""
            }

            {
                line = $0

                if (!candidate && line ~ start) {
                    candidate = 1
                    started = 0
                    depth = 0
                    segment = ""
                }

                if (!candidate)
                    next

                segment = segment line "\n"

                opens = gsub(/\{/, "{", line)
                closes = gsub(/\}/, "}", line)

                if (!started) {
                    if (opens > 0) {
                        started = 1
                        depth = opens - closes
                    } else if (line ~ /;/) {
                        candidate = 0
                        segment = ""
                    }
                    next
                }

                depth += opens - closes

                if (depth == 0) {
                    print segment
                    exit
                }
            }
        ' "$file" 2>/dev/null
    )"

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
        "hookless: fs/Kconfig edit missing"

    has \
        'obj-$(CONFIG_NOMOUNT) += nomount.o' \
        "$d/fs/Makefile" \
        "hookless: fs/Makefile edit missing"

    grep -qE \
        'vfs_map_meta_override|nomount_spoof_mmap_metadata' \
        "$d/fs/proc/task_mmu.c" ||
        error "hookless: task_mmu.c hook missing"

    assertconfig CONFIG_NOMOUNT y
    echo "hookless: verified"
}

verifyfunctiongate() {
    local file="$1"
    local function="$2"
    local needle="$3"
    local message="$4"

    infn "$file" "$function" "$needle" "$message"
}

verifyhook() {
    local d="$COMMONKERNELFOLDER"
    local writefunction
    local nfs
    local nhooks
    local navc

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
        "hook: selinux_inode_setxattr() has no hidden-type guard"

    case "$KERNELVERSION" in
        6.12)
            infn \
                "$d/security/selinux/hooks.c" \
                '^static int selinux_lsm_setattr' \
                ':ksu:' \
                "hook: selinux_lsm_setattr() has no hidden-type guard"
            ;;
        *)
            infn \
                "$d/security/selinux/hooks.c" \
                '^static int selinux_setprocattr' \
                ':ksu:' \
                "hook: selinux_setprocattr() has no hidden-type guard"
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
        "hook: selinuxfs.o is not in security/selinux/Makefile"

    for writefunction in \
        sel_write_context \
        sel_write_validatetrans \
        sel_write_access \
        sel_write_create \
        sel_write_relabel \
        sel_write_user \
        sel_write_member
    do
        verifyfunctiongate \
          "$d/security/selinux/selinuxfs.c" \
          "^static ssize_t ${writefunction}\\(" \
          'sel_ctx_hidden' \
          "hook: ${writefunction}() has no sel_ctx_hidden() gate"
    done

    nfs="$(
        grep -o ':[a-z_]*:' "$d/security/selinux/selinuxfs.c" |
        sort -u |
        tr '\n' ' '
    )"

    nhooks="$(
        grep -o ':[a-z_]*:' "$d/security/selinux/hooks.c" |
        sort -u |
        tr '\n' ' '
    )"

    navc="$(
        grep -o ':[a-z_]*:' "$d/security/selinux/avc.c" |
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
            "hook: hidden-type guard appears before the avc_has_perm() of its own function"

    need KSUDIR

    [ -f "$KSUDIR/kernel/selinux/rules.c" ] ||
        error \
            "hook: $KSUDIR/kernel/selinux/rules.c does not exist"

    hasnt \
        'selinux_status_update_policyload' \
        "$KSUDIR/kernel/selinux/rules.c" \
        "hook: fix_selinux_seqno did not land"

    has \
        'selnl_notify_policyload' \
        "$KSUDIR/kernel/selinux/rules.c" \
        "hook: selnl_notify_policyload was removed"

    assertconfig CONFIG_SECURITY_SELINUX y
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
        "pathhide: maps/smaps guards missing from task_mmu.c"

    has \
        'pathhide_match_file' \
        "$d/fs/proc/base.c" \
        "pathhide: mapfiles guards missing from base.c"

    infn \
        "$d/fs/proc/task_mmu.c" \
        '^static int pagemap_pmd_range' \
        'pathhide_match_file' \
        "pathhide: pagemap guard is not inside pagemap_pmd_range()"

    infn \
        "$d/mm/mincore.c" \
        '^static long do_mincore' \
        'pathhide_match_file' \
        "pathhide: mincore guard is not inside do_mincore()"

    infn \
        "$d/fs/proc/task_mmu.c" \
        '^void task_mem' \
        'pathhide_hidden_vm_pages' \
        "pathhide: vmsize/vmpeak deduction is not inside task_mem()"

    infn \
        "$d/fs/proc/task_mmu.c" \
        '^unsigned long task_statm' \
        'pathhide_hidden_vm_pages' \
        "pathhide: statm size deduction is not inside task_statm()"

    case "$KERNELVERSION" in
        6.12)
            infn \
                "$d/fs/proc/task_mmu.c" \
                '^static int pagemap_scan_test_walk' \
                'pathhide_match_file' \
                "pathhide: pagemap scan guard is not inside pagemap_scan_test_walk()"
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
    local writefunction

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
        "ghost: o_path guard is not inside do_o_path()"

    infn \
        "$d/fs/namei.c" \
        '^static int do_open' \
        'unlikely(ghost_hidden_path(&nd->path))' \
        "ghost: open guard is not inside do_open()"

    infn \
        "$d/fs/namei.c" \
        '^static int path_lookupat' \
        'unlikely(err == -ENOTDIR)' \
        "ghost: ENOTDIR guard is not inside path_lookupat()"

    infn \
        "$d/fs/namei.c" \
        '^static int path_parentat' \
        'unlikely(err == -ENOTDIR)' \
        "ghost: ENOTDIR guard is not inside path_parentat()"

    infn \
        "$d/fs/namei.c" \
        '^static struct dentry \\*filename_create' \
        'error = err2 ? err2 : -EACCES' \
        "ghost: create guard is not inside filename_create()"

    infn \
        "$d/fs/namei.c" \
        '^(static )?int do_linkat' \
        'ghost_hidden_path(&old_path)' \
        "ghost: link guard is not inside do_linkat()"

    infn \
        "$d/fs/open.c" \
        '^int do_fchownat' \
        'ghost_hidden_path(&path))' \
        "ghost: chown guard is not inside do_fchownat()"

    infn \
        "$d/fs/stat.c" \
        '^static int do_readlinkat' \
        'ghost_hidden_path(&path))' \
        "ghost: readlink guard is not inside do_readlinkat()"

    infn \
        "$d/fs/open.c" \
        '^static long do_faccessat' \
        'unlikely(ghost_hidden_path(&path))' \
        "ghost: access guard is not inside do_faccessat()"

    infn \
        "$d/fs/stat.c" \
        '^(static )?int vfs_statx' \
        'ghost_hidden_path(&path))' \
        "ghost: stat guard is not inside vfs_statx()"

    infn \
        "$d/fs/open.c" \
        'do_fchmodat' \
        'ghost_hidden_path(&path))' \
        "ghost: chmod guard is not inside do_fchmodat()"

    infn \
        "$d/fs/open.c" \
        '^(long|int) do_sys_truncate' \
        'ghost_hidden_path(&path))' \
        "ghost: truncate guard is not inside do_sys_truncate()"

    infn \
        "$d/fs/utimes.c" \
        '^(static )?(long|int) do_utimes_path' \
        'ghost_hidden_path(&path))' \
        "ghost: utimensat guard is not inside do_utimes_path()"

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
            "ghost: ${writefunction}() has no ghost_hidden_path() guard"
    done

    count="$(
        grep -c \
            'ghost_hidden_path' \
            "$d/fs/xattr.c" \
            2>/dev/null || true
    )"

    [ "$count" -eq 8 ] ||
        error \
            "ghost: fs/xattr.c has ${count} ghost_hidden_path references, expected 8"

    infn \
        "$d/fs/namei.c" \
        '^int do_renameat2' \
        'struct path gpath = { .mnt = old_path.mnt, .dentry = old_dentry }' \
        "ghost: rename source guard is not inside do_renameat2()"

    if awk \
        '/^int do_renameat2/,/^}/' \
        "$d/fs/namei.c" |
        grep -q 'err2'
    then
        error \
            "ghost: create guard landed in do_renameat2 instead of filename_create"
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

    echo "::group::apply NoMount Suite hookless integration"

    [ -f "$HOOKLESSDIR/src/nomount.c" ] ||
        error "NoMount Suite source missing: $HOOKLESSDIR/src/nomount.c"
    [ -f "$HOOKLESSDIR/src/nomount.h" ] ||
        error "NoMount Suite source missing: $HOOKLESSDIR/src/nomount.h"

    nmpatch="$HOOKLESSDIR/patches/nomount_kernel_integration.patch"
    if [ ! -f "$nmpatch" ]; then
        nmpatch="$HOOKLESSDIR/patches/nomount_${KERNELVERSION}_kernel_integration.patch"
    fi

    [ -f "$nmpatch" ] ||
        error \
            "NoMount Suite hookless integration patch not found for ${KERNELVERSION}"

    normalise \
        "$HOOKLESSDIR/src/nomount.c" \
        "$HOOKLESSDIR/src/nomount.h" \
        "$nmpatch"

    echo "NoMount Suite ref: ${nm_ref}"
    echo "hookless integration patch: $(basename "$nmpatch")"

    install -m 0644 \
        "$HOOKLESSDIR/src/nomount.c" \
        "$COMMONKERNELFOLDER/fs/nomount.c" ||
        error "failed to install fs/nomount.c"

    install -m 0644 \
        "$HOOKLESSDIR/src/nomount.h" \
        "$COMMONKERNELFOLDER/fs/nomount.h" ||
        error "failed to install fs/nomount.h"

    applypatch "$nmpatch" "$COMMONKERNELFOLDER"

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
                's/^#define[[:space:]]\+NM_MODULE_VERSION[[:space:]]\+"\([^\"]*\)".*/\1/p' \
                "$header" |
            head -n1
        )"
    fi

    echo "NoMount Suite version: ${version:-unknown}"

    if [ -n "${GITHUB_ENV:-}" ]; then
        printf 'NMVER=%s\n' "${version:-unknown}" >> "$GITHUB_ENV"
    fi
}

dohook() {
    resolvepaths
    resolveksudir

    echo "::group::apply NoMount Suite SELinux hook patches"

    normalisepatches "$HOOKDIR"

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
    local reqpagemap
    local reqmincore
    local reqacct

    echo "::group::apply NoMount Suite pathhide patches"

    [ -f "$PATHHIDEDIR/pathhide.c" ] ||
        error "pathhide source missing: $PATHHIDEDIR/pathhide.c"
    [ -f "$PATHHIDEDIR/pathhide.h" ] ||
        error "pathhide source missing: $PATHHIDEDIR/pathhide.h"

    normalise \
        "$PATHHIDEDIR/pathhide.c" \
        "$PATHHIDEDIR/pathhide.h"
    normalisepatches "$PATHHIDEDIR"

    install -m 0644 \
        "$PATHHIDEDIR/pathhide.c" \
        "$d/fs/pathhide.c" ||
        error "failed to install fs/pathhide.c"

    install -m 0644 \
        "$PATHHIDEDIR/pathhide.h" \
        "$d/fs/pathhide.h" ||
        error "failed to install fs/pathhide.h"

    applypatch \
        "$PATHHIDEDIR/pathhide_${KERNELVERSION}_integration.patch"

    applypatch \
        "$PATHHIDEDIR/pathhide_mapfiles_${KERNELVERSION}_integration.patch"

    case "$KERNELVERSION" in
        6.12)
            reqpagemap=pathhide_pagemap_6.12_integration.patch
            reqmincore=pathhide_mincore_6.12_integration.patch
            ;;
        6.6)
            reqpagemap=pathhide_pagemap_6.6_integration.patch
            reqmincore=pathhide_mincore_5.10_integration.patch
            ;;
        6.1|5.15|5.10)
            reqpagemap=pathhide_pagemap_5.10_integration.patch
            reqmincore=pathhide_mincore_5.10_integration.patch
            ;;
    esac

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
        '^obj-y[[:space:]]*\\+=.*pathhide\\.o' \
        "$d/fs/Makefile"
    then
        printf '%s\n' 'obj-y += pathhide.o' >> "$d/fs/Makefile"
    fi

    verifypathhide
    echo "::endgroup::"
}

doghost() {
    resolvepaths

    local d="$COMMONKERNELFOLDER"
    local reqxattr
    local reqlinkat
    local reqchmod
    local reqstatx
    local reqreadlink
    local reqrename

    echo "::group::apply NoMount Suite ghost patches"

    [ -f "$GHOSTDIR/ghost.c" ] ||
        error "ghost source missing: $GHOSTDIR/ghost.c"
    [ -f "$GHOSTDIR/ghost.h" ] ||
        error "ghost source missing: $GHOSTDIR/ghost.h"

    normalise \
        "$GHOSTDIR/ghost.c" \
        "$GHOSTDIR/ghost.h"
    normalisepatches "$GHOSTDIR"

    install -m 0644 \
        "$GHOSTDIR/ghost.c" \
        "$d/fs/proc/ghost.c" ||
        error "failed to install fs/proc/ghost.c"

    install -m 0644 \
        "$GHOSTDIR/ghost.h" \
        "$d/fs/proc/ghost.h" ||
        error "failed to install fs/proc/ghost.h"

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

    applypatch "$GHOSTDIR/ghost_o_path.patch"

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

    applypatch "$GHOSTDIR/ghost_notdir.patch"
    applypatch "$GHOSTDIR/ghost_truncate.patch"
    applypatch "$GHOSTDIR/ghost_utimes.patch"

    applyfirst \
        ghost-chmod \
        "$reqchmod" \
        "$GHOSTDIR/ghost_chmod.patch" \
        "$GHOSTDIR/ghost_chmod_5_10.patch"

    applypatch "$GHOSTDIR/ghost_chown.patch"
    applypatch "$GHOSTDIR/ghost_access.patch"
    applypatch "$GHOSTDIR/ghost_open.patch"
    applypatch "$GHOSTDIR/ghost_create.patch"
    applypatch "$GHOSTDIR/ghost_build_integration.patch"

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
        "config NOMOUNT is missing from fs/Kconfig"

    echo "NoMount Suite kernel integration detected"
}

doverify() {
    resolvepaths
    resolvekernelversion
    resolveksudir

    echo "::group::verify NoMount Suite integration"
    echo "kernel version: $KERNELVERSION"
    echo "kernel platform: $KERNELPLATFORM"
    echo "common kernel: $COMMONKERNELFOLDER"
    echo "defconfig: $DEFCONFIG"
    echo "NoMount Suite: $NOMOUNTSUITE"
    echo "kernel patches: $NOMOUNTPATCHES"
    echo "root engine: $ROOTENGINE"
    echo "root engine directory: $KSUDIR"
    echo "patch fuzz: $PATCH_FUZZ"

    verifyhookless
    verifyhook
    verifypathhide
    verifyghost
    verifykernelchange

    assertconfig CONFIG_NOMOUNT y
    assertconfig CONFIG_SECURITY_SELINUX y

    echo "NoMount Suite integration verification passed"
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
    echo "patch fuzz: $PATCH_FUZZ"

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
    record-version)
        need \
            WORKDIR \
            KERNELPLATFORM \
            COMMONKERNELFOLDER \
            DEFCONFIG
        resolvepaths
        dorecordversion
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
        assertconfig CONFIG_NOMOUNT y
        assertconfig CONFIG_SECURITY_SELINUX y
        ;;
    -h|--help|help)
        usage
        ;;
    *)
        usage
        error "unknown command: $CMD"
        ;;
esac
