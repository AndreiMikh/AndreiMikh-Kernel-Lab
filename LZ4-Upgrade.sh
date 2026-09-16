#!/bin/bash

# ================================================================
# LZ4-Upgrade.sh
# ================================================================

set -euo pipefail

SCRIPTDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCHED=0
SKIPPED=0
FAILED=0

info()  { echo "[Info] $*"; }
pass()  { echo "[Pass] $*"; ((PATCHED++)) || true; }
skip()  { echo "[Skip] $*"; ((SKIPPED++)) || true; }
fail()  { echo "[Fail] $*"; ((FAILED++)) || true; }

already_has() {
  grep -q "$1" "$2" 2>/dev/null
}

echo "=== LZ4-Upgrade.sh: Starting LZ4 Upgrade ==="

# Replace the Lib/LZ4/ Directory with the Unified Upstream LZ4 Implementation
echo ""
echo "[1/5] Replacing Lib/LZ4/"

# Remove Old Files
for OLD in lib/lz4/lz4_compress.c lib/lz4/lz4_decompress.c \
           lib/lz4/lz4defs.h lib/lz4/lz4hc_compress.c; do
  if [ -f "$OLD" ]; then
    rm -f "$OLD"
    info "Removed Old File: $OLD"
  fi
done

# Remove the Old F2FS LZ4 Armv8 Implementation
if [ -d "fs/f2fs/lz4armv8" ]; then
  rm -rf "fs/f2fs/lz4armv8"
  info "Removed Old Directory: fs/f2fs/lz4armv8/"
fi

# Create the New LZ4 Armv8 Directory
mkdir -p lib/lz4/lz4armv8

# Copy the New LZ4 Files
for F in lib/lz4/lz4.c \
         lib/lz4/lz4.h \
         lib/lz4/lz4hc.c \
         lib/lz4/lz4hc.h \
         lib/lz4/Makefile \
         lib/lz4/lz4armv8/lz4accel.c \
         lib/lz4/lz4armv8/lz4accel.h \
         lib/lz4/lz4armv8/lz4armv8.S; do
  cp -f "${SCRIPTDIR}/${F}" "${F}"
  info "Written: $F"
done

pass "Lib/LZ4 Replacement Completed"

# Replace Include/Linux/LZ4H with the Thin Wrapper Header Pointing to Lib/LZ4/
echo ""
echo "[2/5] Replacing Include/Linux/LZ4H"

if already_has 'lib/lz4/lz4.h' include/linux/lz4.h; then
  skip "Include/Linux/LZ4H Already Uses the New Format"
else
  cp -f "${SCRIPTDIR}/include/linux/lz4.h" include/linux/lz4.h
  pass "Include/Linux/LZ4C Replacement Completed"
fi

# Modify Crypto/Z4C and Crypto/LZ4HCC to Add the Arm64 NEON Branch
echo ""
echo "[3/5] Modifying Crypto/LZ4/LZ4HCC"

for FILE in crypto/lz4.c crypto/lz4hc.c; do
  if [ ! -f "$FILE" ]; then
    skip "LZ4HCC Does Not Exist"
    continue
  fi

  if already_has 'LZ4_arm64_decompress_safe' "$FILE"; then
    skip "LZ4HC is Already Patched"
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

  already_has 'LZ4_arm64_decompress_safe' "$FILE" \
    && pass "LZ4HC NEON Branch Added Successfully" \
    || fail "LZ4HC Failed to add NEON Branch"
done

# Modify FS/F2FS/Makefile and FS/F2FS/CompressC
# Remove the Old LZ4Armv8 Build Entry and Include
echo ""
echo "[4/5] Modifying FS/F2FS/"

# 4a. Remove the LZ4Armv8 Build Entry from FS/F2FS/Makefile
F2FS_MK="fs/f2fs/Makefile"

if [ -f "$F2FS_MK" ]; then
  if grep -q 'lz4armv8' "$F2FS_MK"; then

    # Support Both Block and Single-Line Formats
    perl -i -0777 -pe '
      # Remove the IFeq...Endif Block Containing LZ4Armv8
      s/\nifeq \(\$\(CONFIG_F2FS_FS_COMPRESSION_FIXED_OUTPUT\),y\)\nf2fs-\$\(CONFIG_ARM64\) \+= \$\(addprefix lz4armv8\/,.*?\)\nendif//gs;

      # Remove the Single-Line Format if Present
      s/\nf2fs-\$\(CONFIG_ARM64\) \+= \$\(addprefix lz4armv8\/,.*\)//g;
    ' "$F2FS_MK"

    grep -q 'lz4armv8' "$F2FS_MK" \
      && fail "Makefile Failed to Remove LZ4Armv8" \
      || pass "Makefile LZ4Armv8 Removal Completed"
  else
    skip "Makefile has No LZ4Armv8 Entry (Already Removed or Not Present)"
  fi
fi

# 4b. Remove the LZ4Armv8 Include from FS/F2FS/CompressC
COMPRESS_C="fs/f2fs/compress.c"

if [ -f "$COMPRESS_C" ]; then
  if grep -q 'lz4armv8/lz4accel.h' "$COMPRESS_C"; then
    sed -i '/#include "lz4armv8\/lz4accel\.h"/d' "$COMPRESS_C"

    grep -q 'lz4armv8/lz4accel.h' "$COMPRESS_C" \
      && fail "COMPRESS C Failed to Remove the Include" \
      || pass "COMPRESS C LZ4Armv8 Include Removal Completed"
  else
    skip "CompressC has No LZ4Armv8/LZ4Accel-H Include (Already Removed or Not Present)"
  fi
fi

# Add the ARM64 NEON Branch to the LZ4 Decompression Call
# Replace Schedule Delayed Work with Queue Delayed Work Using the Power-Efficient Work Queue
echo ""
echo "[5/5] Modifying FS/INCFS/DataMgmt C"

INCFS="fs/incfs/data_mgmt.c"

if [ ! -f "$INCFS" ]; then
  skip "$INCFS Does Not Exist (Kernel Version has No INCFS)"
else

  # 5a. Add the LZ4 ARM64 NEON Branch
  if already_has 'LZ4_arm64_decompress_safe' "$INCFS"; then
    skip "DataMgmt C LZ4 NEON Branch is Already Patched"
  else
    perl -i -0777 -pe '
      s{(\t+)result = LZ4_decompress_safe\(src\.data, dst\.data, src\.len,\s*\n\s*dst\.len\);}
       {#if defined(CONFIG_ARM64) && defined(CONFIG_KERNEL_MODE_NEON)\n${1}result = LZ4_arm64_decompress_safe(src.data, dst.data, src.len, dst.len, false);\n#else\n${1}result = LZ4_decompress_safe(src.data, dst.data, src.len, dst.len);\n#endif}
    ' "$INCFS"

    already_has 'LZ4_arm64_decompress_safe' "$INCFS" \
      && pass "DataMgmt C LZ4 NEON Branch Added Successfully" \
      || fail "DataMgmt C Failed to Add LZ4 NEON Branch"
  fi

  # 5b. Replace Schedule Delayed Work with Queue Delayed Work Using the Power-Efficient Work Queue
  if already_has 'system_power_efficient_wq' "$INCFS"; then
    skip "DataMgmt C Queue Delayed Work is Already Patched"
  else
    sed -i 's/schedule_delayed_work(\&log->ml_wakeup_work,/queue_delayed_work(system_power_efficient_wq, \&log->ml_wakeup_work,/' "$INCFS"

    already_has 'system_power_efficient_wq' "$INCFS" \
      && pass "DataMgmt C Queue Delayed Work Replacement Completed" \
      || fail "DataMgmt C Failed to Replace Queue Delayed Work"
  fi
fi

echo ""
echo "=== LZ4-Neon Completed: ${PATCHED} Successful, ${SKIPPED} Skipped, ${FAILED} Failed ==="

if [ "$FAILED" -gt 0 ]; then
  exit 1
fi
