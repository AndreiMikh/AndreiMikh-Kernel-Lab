#!/usr/bin/env bash
set -Eeuo pipefail
# APT Package Cache Configuration
CACHEDIR="${1:-${APT_CACHE_DIR:-$HOME/.apt-pkg-cache}}"
DEBDIR="$CACHEDIR/debs"
REQMANIFEST="$CACHEDIR/request-manifest.txt"
FULLMANIFEST="$CACHEDIR/full-manifest.txt"
CHECKSUMS="$CACHEDIR/checksums.txt"
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
# Prevent Concurrent Cache Modifications
exec 9>"$CACHEDIR/.cache.lock"
flock -x 9
# Generate Requested Package Manifest
EXPECTEDREQ="$(printf '%s\n' "${PACKAGES[@]}")"
# Validate Existing Cache
cachevalidity() {
    [[ -f "$REQMANIFEST" ]] || return 1
    [[ -f "$FULLMANIFEST" ]] || return 1
    [[ -f "$CHECKSUMS" ]] || return 1
    [[ "$(cat "$REQMANIFEST")" == "$EXPECTEDREQ" ]] || return 1
    [[ -s "$FULLMANIFEST" ]] || return 1
    (
        cd "$CACHEDIR"
        while IFS= read -r deb; do
            [[ -n "$deb" && -f "$deb" ]] || return 1
        done < "$FULLMANIFEST"
        sha256sum --quiet -c checksums.txt
    ) || return 1
    return 0
}

# Restore Packages From Cached DEB Archives
if cachevalidity; then
    echo "📦 APT File Cache Hit"
    echo "📌 Requested: ${PACKAGES[*]}"
    # Restore Cached Archives Into APT Archive Directory
    sudo mkdir -p /var/cache/apt/archives
    while IFS= read -r deb; do
        [[ -n "$deb" ]] || continue
        sudo cp -f "$CACHEDIR/$deb" /var/cache/apt/archives/
    done < "$FULLMANIFEST"

    # Install Packages Without Network Downloads
    echo "🔧 Restoring Cached Packages"
    sudo DEBIAN_FRONTEND=noninteractive apt-get install \
        -y \
        --no-download \
        --no-install-recommends \
        "${PACKAGES[@]}"
    sudo ldconfig || true
    echo "✔️ APT Cache Restore Completed"
    exit 0
fi

echo "🔧 APT File Cache Miss (or Invalid Cache)"
echo "📌 Requested: ${PACKAGES[*]}"
# Refresh Package Indexes
sudo apt-get update \
    -o Acquire::Retries=5 \
    -o Acquire::http::Pipeline-Depth=0
# Prepare Temporary Download Directory
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
mkdir -p "$WORKDIR/archives/partial"
# Download The Exact APT-Resolved Installation Transaction
echo "⬇️ Downloading APT Installation Transaction"
sudo DEBIAN_FRONTEND=noninteractive apt-get install \
    --download-only \
    --reinstall \
    -y \
    --no-install-recommends \
    -o "Dir::Cache::archives=$WORKDIR/archives/" \
    "${PACKAGES[@]}"

# Verify Downloaded DEB Archives
shopt -s nullglob
DEBFILES=("$WORKDIR/archives"/*.deb)
shopt -u nullglob
if [[ ${#DEBFILES[@]} -eq 0 ]]; then
    echo "⚠️ No DEB Archives were Downloaded" >&2
    exit 1
fi

# Install Requested Packages
echo "🔧 Installing Requested Packages"
sudo DEBIAN_FRONTEND=noninteractive apt-get install \
    -y \
    --no-install-recommends \
    -o "Dir::Cache::archives=$WORKDIR/archives/" \
    "${PACKAGES[@]}"
# Prepare New Cache
NEWCACHE="$CACHEDIR/.new-cache"
rm -rf "$NEWCACHE"
mkdir -p "$NEWCACHE/debs"
# Copy Downloaded DEB Archives
for deb in "${DEBFILES[@]}"; do
    cp -f "$deb" "$NEWCACHE/debs/"
done

# Generate Package Manifest
(
    cd "$NEWCACHE"
    find debs -maxdepth 1 -type f -name '*.deb' -printf '%p\n' |
        sort > full-manifest.txt
    # Generate SHA-256 Checksums
    sha256sum $(cat full-manifest.txt) > checksums.txt
)

# Generate Requested Package Manifest
printf '%s\n' "${PACKAGES[@]}" > "$NEWCACHE/request-manifest.txt"
# Validate New Cache
if ! (
    cd "$NEWCACHE"
    sha256sum --quiet -c checksums.txt
); then
    echo "⚠️ APT Cache Integrity Validation Failed" >&2
    exit 1
fi

# Publish Cache Files
rm -rf "$CACHEDIR/.old-cache"
mkdir -p "$CACHEDIR/.old-cache"
# Preserve Previous Cache Until New Archives are Ready
[[ -d "$DEBDIR" ]] && mv "$DEBDIR" "$CACHEDIR/.old-cache/debs"
for file in request-manifest.txt full-manifest.txt checksums.txt; do
    [[ -f "$CACHEDIR/$file" ]] &&
        mv "$CACHEDIR/$file" "$CACHEDIR/.old-cache/"
done

# Publish New Cache
mv "$NEWCACHE/debs" "$DEBDIR"
for file in request-manifest.txt full-manifest.txt checksums.txt; do
    mv "$NEWCACHE/$file" "$CACHEDIR/$file"
done

# Remove Previous Cache
rm -rf "$NEWCACHE" "$CACHEDIR/.old-cache"
# Refresh Dynamic Linker Cache
sudo ldconfig || true
# Display Cache Summary
TOTAL="$(find "$DEBDIR" -maxdepth 1 -type f -name '*.deb' | wc -l)"
SIZE="$(du -sh "$DEBDIR" | awk '{print $1}')"
echo "✔️ APT Cache Write Completed"
echo "📦 Cached DEB Archives: $TOTAL"
echo "💾 Cache Size: $SIZE"
echo "📌 Requested: ${PACKAGES[*]}"
echo "📁 Cache Directory: $CACHEDIR"
