#!/bin/bash

# ================================================================
# LZ4-Upgrade.sh
# ================================================================

set -euo pipefail

# Script And Repository Paths
SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPODIR="$(cd "${SCRIPTDIR}/.." && pwd)"
LZ4DIR="${REPODIR}/lib/lz4"

PATCHED=0
SKIPPED=0
FAILED=0

info()  { echo "ℹ️ [Info] $*"; }
pass()  { echo "✔️ [Pass] $*"; ((PATCHED++)) || true; }
skip()  { echo "⏭️ [Skip] $*"; ((SKIPPED++)) || true; }
fail()  { echo "⚠️ [Fail] $*"; ((FAILED++)) || true; }

contains() {
  grep -q "$1" "$2" 2>/dev/null
}

filedescription() {
  case "$1" in
    lib/lz4/lz4.c)
      echo "Lib/LZ4/LZ4 Source"
      ;;
    lib/lz4/lz4.h)
      echo "Lib/LZ4/LZ4 Header"
      ;;
    lib/lz4/lz4hc.c)
      echo "Lib/LZ4/LZ4HC Source"
      ;;
    lib/lz4/lz4hc.h)
      echo "Lib/LZ4/LZ4HC Header"
      ;;
    lib/lz4/Makefile)
      echo "Lib/LZ4/Makefile"
      ;;
    lib/lz4/lz4armv8/lz4accel.c)
      echo "Lib/LZ4/LZ4ARMv8/LZ4Accel Source"
      ;;
    lib/lz4/lz4armv8/lz4accel.h)
      echo "Lib/LZ4/LZ4ARMv8/LZ4Accel Header"
      ;;
    lib/lz4/lz4armv8/lz4armv8.S)
      echo "Lib/LZ4/LZ4ARMv8/LZ4ARMv8 Assembly Source"
      ;;
    lib/lz4/lz4_compress.c)
      echo "Lib/LZ4/LZ4 Compress Source"
      ;;
    lib/lz4/lz4_decompress.c)
      echo "Lib/LZ4/LZ4 Decompress Source"
      ;;
    lib/lz4/lz4defs.h)
      echo "Lib/LZ4/LZ4 Definitions Header"
      ;;
    lib/lz4/lz4hc_compress.c)
      echo "Lib/LZ4/LZ4HC Compress Source"
      ;;
    crypto/lz4.c)
      echo "Crypto/LZ4 Source"
      ;;
    crypto/lz4hc.c)
      echo "Crypto/LZ4HC Source"
      ;;
    fs/f2fs/Makefile)
      echo "FS/F2FS/Makefile"
      ;;
    fs/f2fs/compress.c)
      echo "FS/F2FS/Compress Source"
      ;;
    fs/incfs/data_mgmt.c)
      echo "FS/INCFS/DataMgmt Source"
      ;;
    include/linux/lz4.h)
      echo "Include/Linux/LZ4 Header"
      ;;
    *)
      echo "$1"
      ;;
  esac
}

echo "=== LZ4-Upgrade.sh: Starting LZ4 Script ==="

# Validate LZ4 Source Directory
if [[ ! -d "$LZ4DIR" ]]; then
  fail "LZ4 Source Directory Not Found: $LZ4DIR"
  exit 1
fi

# Replace the Lib/LZ4/ Directory with the Unified Upstream LZ4 Implementation
echo ""
echo "[1/5] Replacing Lib/LZ4/"
# Remove Old Files
for OLD in \
  lib/lz4/lz4_compress.c \
  lib/lz4/lz4_decompress.c \
  lib/lz4/lz4defs.h \
  lib/lz4/lz4hc_compress.c; do
  if [[ -f "$OLD" ]]; then
    rm -f "$OLD"
    info "Removed: $(filedescription "$OLD")"
  fi
done

# Remove the Old F2FS LZ4 ARMv8 Implementation
if [[ -d "fs/f2fs/lz4armv8" ]]; then
  rm -rf "fs/f2fs/lz4armv8"
  info "Removed: FS/F2FS/LZ4ARMv8 Directory"
fi

# Create the New LZ4 ARMv8 Directory
mkdir -p lib/lz4/lz4armv8

# Copy the New LZ4 Files
for F in \
  lz4.c \
  lz4.h \
  lz4hc.c \
  lz4hc.h \
  Makefile \
  lz4armv8/lz4accel.c \
  lz4armv8/lz4accel.h \
  lz4armv8/lz4armv8.S; do

  SRC="${LZ4DIR}/${F}"
  DST="lib/lz4/${F}"
  DESC="lib/lz4/${F}"

  if [[ ! -f "$SRC" ]]; then
    fail "LZ4 Source File Not Found: $SRC"
    continue
  fi

  cp -f "$SRC" "$DST"
  info "Written: $(filedescription "$DESC")"
done
if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi

pass "Lib/LZ4 Replacement Completed"

# Generate Include/Linux/LZ4 H Compatibility Wrapper
echo ""
echo "[2/5] Generating Include/Linux/LZ4 H"

mkdir -p include/linux

cat > include/linux/lz4.h <<'EOF'
/* SPDX-License-Identifier: BSD-2-Clause */
// LZ4 Compatibility Wrapper for Linux Kernel

#ifndef __LINUX_LZ4_H__
#define __LINUX_LZ4_H__

#include "../../lib/lz4/lz4.h"
#include "../../lib/lz4/lz4hc.h"

#define LZ4_MEM_COMPRESS       LZ4_STREAM_MINSIZE
#define LZ4HC_MEM_COMPRESS     LZ4_STREAMHC_MINSIZE

#define LZ4HC_MIN_CLEVEL       LZ4HC_CLEVEL_MIN
#define LZ4HC_DEFAULT_CLEVEL   LZ4HC_CLEVEL_DEFAULT
#define LZ4HC_MAX_CLEVEL       LZ4HC_CLEVEL_MAX

#endif
EOF

if contains 'lib/lz4/lz4.h' include/linux/lz4.h &&
   contains 'lib/lz4/lz4hc.h' include/linux/lz4.h; then
  pass "$(filedescription "include/linux/lz4.h") Generated Successfully"
else
  fail "$(filedescription "include/linux/lz4.h") Generation Failed"
fi

# Modify Crypto/LZ4/LZ4HC to Add the ARM64 Neon Branch
echo ""
echo "[3/5] Modifying Crypto/LZ4/LZ4HC C"
for FILE in crypto/lz4.c crypto/lz4hc.c; do
  if [[ ! -f "$FILE" ]]; then
    skip "$(filedescription "$FILE") Does Not Exist"
    continue
  fi

  if contains 'LZ4_arm64_decompress_safe' "$FILE"; then
    skip "$(filedescription "$FILE") Is Already Patched"
    continue
  fi

  perl -i -pe '
    if (/\tint out_len = LZ4_decompress_safe\(src, dst, slen, \*dlen\);/) {
      $_ = "\tint out_len;\n\n"
         . "#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n"
         . "\tout_len = LZ4_arm64_decompress_safe(src, dst, slen, *dlen, false);\n"
         . "#else\n"
         . "\tout_len = LZ4_decompress_safe(src, dst, slen, *dlen);\n"
         . "#endif\n";
    }
  ' "$FILE"
 
  if contains 'LZ4_arm64_decompress_safe' "$FILE"; then
    pass "$(filedescription "$FILE") Neon Branch Added Successfully"
  else
    fail "$(filedescription "$FILE") Failed To Add Neon Branch"
  fi
done

# Modify FS/F2FS/Makefile and FS/F2FS/CompressC
# Remove the Old LZ4Armv8 Build Entry and Include
echo ""
echo "[4/5] Modifying FS/F2FS/"

# 4a. Remove the LZ4Armv8 Build Entry from FS/F2FS/Makefile
F2FSMK="fs/f2fs/Makefile"
if [[ -f "$F2FSMK" ]]; then
  if grep -q 'lz4armv8' "$F2FSMK"; then
    # Support Both Block And Single-Line Formats
    perl -i -0777 -pe '
      # Remove The Ifeq...Endif Block Containing LZ4ARMv8
      s/\nifeq \(\$\(CONFIG_F2FS_FS_COMPRESSION_FIXED_OUTPUT\),y\)\nf2fs-\$\(CONFIG_ARM64\) \+= \$\(addprefix lz4armv8\/,.*?\)\nendif//gs;
      # Remove The Single-Line Format If Present
      s/\nf2fs-\$\(CONFIG_ARM64\) \+= \$\(addprefix lz4armv8\/,.*\)//g;
    ' "$F2FSMK"
    if grep -q 'lz4armv8' "$F2FSMK"; then
      fail "$(filedescription "$F2FSMK") Failed To Remove LZ4ARMv8"
    else
      pass "$(filedescription "$F2FSMK") LZ4ARMv8 Removal Completed"
    fi
  else
    skip "$(filedescription "$F2FSMK") Has No LZ4ARMv8 Entry (Already Removed Or Not Present)"
  fi
fi

# 4b. Remove the LZ4Armv8 Include from FS/F2FS/CompressC
COMPRESSC="fs/f2fs/compress.c"
if [[ -f "$COMPRESSC" ]]; then
  if grep -q 'lz4armv8/lz4accel.h' "$COMPRESSC"; then
    sed -i '/#include "lz4armv8\/lz4accel\.h"/d' "$COMPRESSC"
    if grep -q 'lz4armv8/lz4accel.h' "$COMPRESSC"; then
      fail "$(filedescription "$COMPRESSC") Failed To Remove The Include"
    else
      pass "$(filedescription "$COMPRESSC") LZ4ARMv8 Include Removal Completed"
    fi
  else
    skip "$(filedescription "$COMPRESSC") Has No LZ4ARMv8/LZ4Accel Header Include (Already Removed Or Not Present)"
  fi
fi

# Add the ARM64 Neon Branch to the LZ4 Decompression Call
# Replace Schedule Delayed Work with Queue Delayed Work Using the Power-Efficient Work Queue
echo ""
echo "[5/5] Modifying FS/INCFS/DataMgmt Source"
INCFS="fs/incfs/data_mgmt.c"
if [[ ! -f "$INCFS" ]]; then
  skip "$(filedescription "$INCFS") Does Not Exist (Kernel Version Has No DataMgmt Source)"
else
  # 5a. Add the LZ4 ARM64 Neon Branch
  if contains 'LZ4_arm64_decompress_safe' "$INCFS"; then
    skip "$(filedescription "$INCFS") LZ4 Neon Branch Is Already Patched"
  else
    perl -i -0777 -pe '
      s{(\t+)result = LZ4_decompress_safe\(src\.data, dst\.data, src\.len,\s*\n\s*dst\.len\);}
       {#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}result = LZ4_arm64_decompress_safe(src.data, dst.data, src.len, dst.len, false);\n#else\n${1}result = LZ4_decompress_safe(src.data, dst.data, src.len, dst.len);\n#endif}
    ' "$INCFS"
    if contains 'LZ4_arm64_decompress_safe' "$INCFS"; then
      pass "$(filedescription "$INCFS") LZ4 Neon Branch Added Successfully"
    else
      fail "$(filedescription "$INCFS") Failed To Add LZ4 Neon Branch"
    fi
  fi

  # 5b. Replace Schedule Delayed Work With Queue Delayed Work
  if contains 'system_power_efficient_wq' "$INCFS"; then
    skip "$(filedescription "$INCFS") Queue Delayed Work Is Already Patched"
  else
    sed -i \
      's/schedule_delayed_work(\&log->ml_wakeup_work,/queue_delayed_work(system_power_efficient_wq, \&log->ml_wakeup_work,/' \
      "$INCFS"
    if contains 'system_power_efficient_wq' "$INCFS"; then
      pass "$(filedescription "$INCFS") Queue Delayed Work Replacement Completed"
    else
      fail "$(filedescription "$INCFS") Failed To Replace Queue Delayed Work"
    fi
  fi
fi

echo ""
echo "=== LZ4-Neon Completed: ${PATCHED} Successful, ${SKIPPED} Skipped, ${FAILED} Failed ==="
if [[ "$FAILED" -gt 0 ]]; then
  exit 1
fi
