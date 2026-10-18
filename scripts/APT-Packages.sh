#!/bin/bash
set -euo pipefail
if [ -z "${APTPACKAGES:-}" ]; then
  echo "⚠️ APT Packages Environment Variable is Not Set" >&2
  exit 1
fi

read -ra PACKAGES <<< "$APTPACKAGES"
CACHEDIR="${1:-$HOME/.apt-pkg-cache}"
REQMANIFEST="$CACHEDIR/request-manifest.txt"
FULLMANIFEST="$CACHEDIR/full-manifest.txt"
EXPECTEDREQ="$(printf '%s\n' "${PACKAGES[@]}" | sort)"
mkdir -p "$CACHEDIR"
cachehit=false
if [ -f "$REQMANIFEST" ] && [ "$(cat "$REQMANIFEST")" = "$EXPECTEDREQ" ] && [ -f "$FULLMANIFEST" ]; then
  missing=0
  while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    [ -f "$CACHEDIR/${pkg}.tar" ] || { missing=1; break; }
  done < "$FULLMANIFEST"
  [ "$missing" -eq 0 ] && cachehit=true
fi

if [ "$cachehit" = true ]; then
  n=0
  while IFS= read -r pkg; do
    [ -z "$pkg" ] && continue
    sudo tar -xf "$CACHEDIR/${pkg}.tar" -C /
    n=$((n+1))
  done < "$FULLMANIFEST"
  sudo ldconfig || true
  echo "✔️ APT File Cache Hit, Restored $n Packages (Including Dependencies)"
  exit 0
fi

echo "🔧 APT File Cache Miss (or Package List Changed), Performing Normal Installation and Calculating Dependency Closure"
echo "Requested: ${PACKAGES[*]}"
BEFORE="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)"
sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "${PACKAGES[@]}"
AFTER="$(dpkg-query -W -f='${Package}\n' 2>/dev/null | sort)"
NEWPACKAGES="$(comm -13 <(echo "$BEFORE") <(echo "$AFTER"))"
FULLSET="$(printf '%s\n%s\n' "$NEWPACKAGES" "$(printf '%s\n' "${PACKAGES[@]}")" | sort -u)"
n=0
while IFS= read -r pkg; do
  [ -z "$pkg" ] && continue
  dpkg -s "$pkg" >/dev/null 2>&1 || continue
  tarpath="$CACHEDIR/${pkg}.tar"
  tar -cf "$tarpath" -C / -T <(
    dpkg -L "$pkg" | while IFS= read -r f; do
      [ -f "$f" ] && echo "${f#/}"
    done
  )
  n=$((n+1))
done <<< "$FULLSET"
printf '%s\n' "${PACKAGES[@]}" | sort > "$REQMANIFEST"
echo "$FULLSET" | sed '/^$/d' | sort -u > "$FULLMANIFEST"
echo "✔️ Cache Write Completed, $n Packages in Total"
