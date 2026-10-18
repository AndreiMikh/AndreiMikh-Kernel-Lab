#!/bin/bash  
SCRIPTSOURCE="${BASH_SOURCE[0]}"
SELF="$(cd "$(dirname "$SCRIPTSOURCE")" >/dev/null 2>&1 && pwd)/$(basename "$SCRIPTSOURCE")" 
checkrejects() { 
  local searchdirectories="${1:-.}" 
  local rejectsfiles 
  rejectsfiles=$(find "$searchdirectories" -name "*.rej" 2>/dev/null) 
  [ -z "$rejectsfiles" ] && return 0  
  while IFS= read -r REJFILE; do 
    local mark="/tmp/.rej_printed_$(echo "$REJFILE" | md5sum | cut -d' ' -f1)" 
    [ -f "$mark" ] && continue 
    touch "$mark" 2>/dev/null  
    local originalfile="${REJFILE%.rej}" 
    originalfile="${originalfile#./}" 
    local failcount 
    failcount=$(grep -c '^@@ ' "$REJFILE" 2>/dev/null) 
    echo "::group::⚠️ Patch Failed to Apply to ${originalfile} (Hunk Failed: ${failcount:-?} Hunks Could Not be Applied) Click to View Details" 
    cat "$REJFILE" 
    echo "::endgroup::" 
  done <<< "$rejectsfiles" 
  return 0 
}  
errorrejecttrap() { 
  local ec=$? 
  trap - ERR 
  local rejfiles 
  rejfiles=$(find . -name "*.rej" 2>/dev/null) 
  if [ -n "$rejfiles" ]; then 
    checkrejects . 
    exit "$ec" 
  fi 
  trap 'errorrejecttrap' ERR 
}  
if [[ -n "${GITHUB_ENV:-}" && "${BASH_ENV:-}" != "$SELF" ]]; then 
  echo "BASH_ENV=$SELF" >> "$GITHUB_ENV" 
fi 
 
set -E 
trap 'errorrejecttrap' ERR
