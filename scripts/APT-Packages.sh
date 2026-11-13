#!/usr/bin/env bash
set -Eeuo pipefail
# APT Package Cache Configuration
CACHEDIR="${1:-${APT_CACHE_DIR:-$HOME/.apt-pkg-cache}}"
DEBDIR="$CACHEDIR/debs"
REQMANIFEST="$CACHEDIR/request-manifest.txt"
FULLMANIFEST="$CACHEDIR/full-manifest.txt"
CHECKSUMS="$CACHEDIR/checksums.txt"
LOCKFILE="$CACHEDIR/.cache.lock"
# Validate Required Environment Variables
if [[ -z "${APTPACKAGES:-}" ]]; then
    echo "⚠️ APTPACKAGES Environment Variable is Not Set" >&2
    exit 1
fi

# Parse and Normalize Requested Packages
read -r -a PACKAGES <<< "$APTPACKAGES"
if [[ ${#PACKAGES[@]} -eq 0 ]]; then
    echo "⚠️ No APT Packages were Provided" >&2
    exit 1
fi

mapfile -t PACKAGES < <(
    printf '%s\n' "${PACKAGES[@]}" |
        sed '/^[[:space:]]*$/d' |
        sort -u
)

# Prepare Cache Directories
mkdir -p "$DEBDIR"
touch "$LOCKFILE"
# Prevent Concurrent Cache Modifications
exec 9>"$LOCKFILE"
flock -x 9
# Generate Requested Package Manifest
EXPECTEDREQ="$(printf '%s\n' "${PACKAGES[@]}")"
# Check Cache Integrity
cachevalidity() {
    [[ -f "$REQMANIFEST" ]] || return 1
    [[ -f "$FULLMANIFEST" ]] || return 1
    [[ -f "$CHECKSUMS" ]] || return 1
    [[ "$(cat "$REQMANIFEST")" == "$EXPECTEDREQ" ]] || return 1
    [[ -s "$FULLMANIFEST" ]] || return 1
    (
        cd "$CACHEDIR"
        while IFS= read -r deb; do
            [[ -n "$deb" ]] || continue
            [[ -f "$deb" ]] || exit 1
        done < "$FULLMANIFEST"

        sha256sum --quiet -c checksums.txt
    ) || return 1
    return 0
}

# Restore Packages From Cached DEB Archives
if cachevalidity; then
    echo "📦 APT Cache Hit"
    echo "📌 Requested: ${PACKAGES[*]}"
    mapfile -t DEBFILES < <(
        while IFS= read -r deb; do
            [[ -n "$deb" ]] && printf '%s\n' "$DEBDIR/$deb"
        done < "$FULLMANIFEST"
    )

    echo "🔧 Restoring ${#DEBFILES[@]} Cached DEB Packages"
    sudo apt-get install \
        -y \
        --no-download \
        --no-install-recommends \
        "${DEBFILES[@]}"
    sudo ldconfig || true
    echo "✔️ APT Cache Restore Completed"
    exit 0
fi

echo "🔧 APT Cache Miss (or Invalid Cache)"
echo "📌 Requested: ${PACKAGES[*]}"
# Refresh Package Indexes
sudo apt-get update
# Resolve Recursive Package Dependencies
echo "🔍 Calculating Dependency Closure"
DEPENDENCIES="$(
    apt-cache depends \
        --recurse \
        --important \
        --no-recommends \
        --no-suggests \
        --no-conflicts \
        --no-breaks \
        --no-replaces \
        --no-enhances \
        "${PACKAGES[@]}" 2>/dev/null |
    awk '
        /^[[:space:]]+(PreDepends|Depends):/ {
            line = $0
            sub(/^[[:space:]]+(PreDepends|Depends):[[:space:]]*/, "", line)
            gsub(/[<>]/, "", line)
            split(line, fields, /[[:space:]]+/)
            pkg = fields[1]
            sub(/:.*/, "", pkg)

            if (pkg != "" && pkg !~ /^\//)
                print pkg
        }
    ' |
    sort -u
)"

# Include Requested Packages in Dependency Closure
mapfile -t FULLPACKAGES < <(
    {
        printf '%s\n' "${PACKAGES[@]}"
        printf '%s\n' "$DEPENDENCIES"
    } |
    sed '/^[[:space:]]*$/d' |
    sort -u
)

# Keep Only Packages with Available APT Candidates
VALIDPACKAGES=()
for pkg in "${FULLPACKAGES[@]}"; do
    if apt-cache show "$pkg" >/dev/null 2>&1 &&
       apt-cache policy "$pkg" | grep -q 'Candidate: [^ (]'; then
        VALIDPACKAGES+=("$pkg")
    fi
done

if [[ ${#VALIDPACKAGES[@]} -eq 0 ]]; then
    echo "⚠️ Unable to Resolve APT Package Dependencies" >&2
    exit 1
fi

echo "📦 Dependency Closure: ${#VALIDPACKAGES[@]} Packages"

# Download Package Archives
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
echo "⬇️ Downloading DEB Archives"
(
    cd "$WORKDIR"
    apt-get download "${VALIDPACKAGES[@]}"
)

# Verify Downloaded Archives
shopt -s nullglob
DEBFILES=("$WORKDIR"/*.deb)
shopt -u nullglob
if [[ ${#DEBFILES[@]} -eq 0 ]]; then
    echo "⚠️ No DEB Archives were Downloaded" >&2
    exit 1
fi

# Install Requested Packages Using APT
echo "🔧 Installing Requested Packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get install \
    -y \
    --no-install-recommends \
    "${PACKAGES[@]}"

# Prepare New Cache in Temporary Directory
NEWCACHE="$CACHEDIR/.new-cache"
rm -rf "$NEWCACHE"
mkdir -p "$NEWCACHE/debs"
# Copy Downloaded Package Archives
for deb in "${DEBFILES[@]}"; do
    cp -f "$deb" "$NEWCACHE/debs/"
done

# Generate Full Package Manifest
(
    cd "$NEWCACHE"
    find debs -maxdepth 1 -type f -name '*.deb' -printf '%p\n' |
        sort > full-manifest.txt
)

# Generate Requested Package Manifest
printf '%s\n' "${PACKAGES[@]}" > "$NEWCACHE/request-manifest.txt"
# Generate SHA-256 Checksums
(
    cd "$NEWCACHE"
    sha256sum $(cat full-manifest.txt) > checksums.txt
)

# Validate New Cache Before Publishing
if ! (
    cd "$NEWCACHE"
    sha256sum --quiet -c checksums.txt
); then
    echo "⚠️ New APT Cache Integrity Check Failed" >&2
    exit 1
fi

# Replace Previous Cache Atomically at Directory Level
rm -rf "$CACHEDIR/old-cache"
for file in request-manifest.txt full-manifest.txt checksums.txt; do
    [[ -f "$CACHEDIR/$file" ]] &&
        cp -f "$CACHEDIR/$file" "$CACHEDIR/old-cache-$file"
done

rm -rf "$DEBDIR"
mv "$NEWCACHE/debs" "$DEBDIR"
for file in request-manifest.txt full-manifest.txt checksums.txt; do
    mv "$NEWCACHE/$file" "$CACHEDIR/$file"
done

rm -rf "$NEWCACHE"
rm -f "$CACHEDIR"/old-cache-*
sudo ldconfig || true
# Display Cache Summary
TOTAL="$(find "$DEBDIR" -maxdepth 1 -type f -name '*.deb' | wc -l)"
SIZE="$(du -sh "$DEBDIR" | awk '{print $1}')"
echo "✔️ APT Cache Write Completed"
echo "📦 Cached Packages: $TOTAL"
echo "💾 Cache Size: $SIZE"
echo "📌 Requested: ${PACKAGES[*]}"
echo "📌 Cache Directory: $CACHEDIR"
