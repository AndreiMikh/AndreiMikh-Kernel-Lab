```bash
#!/bin/bash

# GET THE ABSOLUTE PATH OF THIS SCRIPT
SELF="$(cd "$(dirname "${SOURCE[0]}")" >/dev/null 2>&1 && pwd)/$(basename "${SOURCE[0]}")"

# CHECK FOR PATCH REJECT FILES
checkrejects() {
    local SEARCHD="${1:-.}"
    local REJECTFILES

    REJECTFILES=$(find "$SEARCHD" -name "*.rej" 2>/dev/null)
    [ -z "$REJECTFILES" ] && return 0

    while IFS= read -r REJECTS; do
        local MARK="/tmp/.rej_printed_$(echo "$REJECTS" | md5sum | cut -d' ' -f1)"

        # SKIP REJECT FILES THAT HAVE ALREADY BEEN REPORTED
        [ -f "$MARK" ] && continue
        touch "$MARK" 2>/dev/null

        local SOURCEFILE="${REJECTS%.rej}"
        SOURCEFILE="${SOURCEFILE#./}"

        local FAILCOUNT
        FAILCOUNT=$(grep -c '^@@ ' "$REJECTS" 2>/dev/null)

        echo "❌ PATCH FAILED IN ${SOURCEFILE} — ${FAILCOUNT:-?} HUNK(S) FAILED TO APPLY"
        cat "$REJECTS"

    done <<< "$REJECTFILES"

    return 0
}

# HANDLE COMMAND FAILURES AND CHECK FOR PATCH REJECTS
rejecterrortrap() {
    local ec=$?

    trap - ERR

    local REJECTFILES
    REJECTFILES=$(find . -name "*.rej" 2>/dev/null)

    if [ -n "$REJECTFILES" ]; then
        checkrejects .
        exit "$ec"
    fi

    trap 'rejecterrortrap' ERR
}

# AUTOMATICALLY LOAD THIS SCRIPT INTO EVERY BASH SHELL IN GITHUB ACTIONS
if [[ -n "${GITHUB_ENV:-}" && "${BASH_ENV:-}" != "$SELF" ]]; then
    echo "BASH_ENV=$SELF" >> "$GITHUB_ENV"
fi

# ENABLE ERR TRAPS INSIDE FUNCTIONS, COMMAND SUBSTITUTIONS, AND SUBSHELLS
set -E

# ENABLE THE GLOBAL ERROR TRAP
trap 'rejecterrortrap' ERR
```
