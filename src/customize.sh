#!/bin/sh
# This is customize the module installation process if you need
TARGET_DIR="/system/lib64"
TARGET_LIB="liblog.so"
PATCHED_LIB="liblog_patched.so"

# for local test
# TARGET_DIR="/sdcard/test_lib"
# TMPDIR="/sdcard/test_tmp"
# MODPATH="/sdcard/test_mod"
# ui_print(){
#     echo "$*"
# }

# copy to TMPDIR
if ! cp -f "${TARGET_DIR}/${TARGET_LIB}" "${TMPDIR}/${TARGET_LIB}"; then
    abort "Failed to copy ${TARGET_DIR}/${TARGET_LIB} to ${TMPDIR}/${TARGET_LIB}"
fi
ui_print "Success to copy ${TARGET_DIR}/${TARGET_LIB} to ${TMPDIR}/${TARGET_LIB}"

# parse liblog.so to get the virtual address of __android_log_is_loggable
TARGET_FUNC_VADDR=$(readelf -sW "${TMPDIR}/${TARGET_LIB}" | grep -w __android_log_is_loggable | awk '{print $2}')
if [ -z "$TARGET_FUNC_VADDR" ]; then
    abort "Failed to get virtual address of __android_log_is_loggable from ${TMPDIR}/${TARGET_LIB}"
fi
ui_print "Success to get virtual address of __android_log_is_loggable: ${TARGET_FUNC_VADDR}"
# Example vaddr 00000000000089ac, so add '0x' prefix to it and convert to number
TARGET_FUNC_VADDR=$(printf "%ld" "0x${TARGET_FUNC_VADDR}")

# parse liblog.so to get elf headers
HEADERS=$(readelf -l "${TMPDIR}/${TARGET_LIB}" | sed '/Program Headers/,/Section to Segment mapping/!d;/Program Headers/d;/Section to Segment mapping/d')
if [ -z "$HEADERS" ]; then
    abort "Failed to parse program headers from ${TMPDIR}/${TARGET_LIB}"
fi

ui_print "Success to parse program headers from ${TMPDIR}/${TARGET_LIB}:"
ui_print "${HEADERS}"

# parse headers line by line to identify base virtual address and physical address
# Example headers:
#  Type           Offset   VirtAddr           PhysAddr           FileSiz MemSiz  Flg Align
#  PHDR           0x000040 0x0000000000000040 0x0000000000000040 0x00230 0x00230 R   0x8
#  LOAD           0x000000 0x0000000000000000 0x0000000000000000 0x04214 0x04214 R   0x1000
#  LOAD           0x005000 0x0000000000005000 0x0000000000005000 0x08870 0x08870 R E 0x1000
#  LOAD           0x00e000 0x000000000000e000 0x000000000000e000 0x005a0 0x005a0 RW  0x1000
#  LOAD           0x00e5a0 0x000000000000f5a0 0x000000000000f5a0 0x00090 0x00180 RW  0x1000

FILE_OFFSET=-1
while IFS= read -r line; do
    Offset=$(echo "$line" | awk '{print $2}')
    VirtAddr=$(echo "$line" | awk '{print $3}')
    PhysAddr=$(echo "$line" | awk '{print $4}')
    MemSiz=$(echo "$line" | awk '{print $6}')
    # string startswith tricks for POSIX sh, 'not startswith' use '='
    if test "$Offset" = "${Offset#0x}" || [ -z "$VirtAddr" ] || [ -z "$PhysAddr" ] || [ -z "$MemSiz" ]; then
        ui_print "Skip illegal header line: ${line}"
        continue
    fi

    # convert to number to avoid [ -lt ] statement error
    Offset=$(printf "%ld" "$Offset")
    VirtAddr=$(printf "%ld" "$VirtAddr")
    PhysAddr=$(printf "%ld" "$PhysAddr")
    MemSiz=$(printf "%ld" "$MemSiz")

    MaxVirtAddr=$((VirtAddr+MemSiz))
    if [ "$TARGET_FUNC_VADDR" -lt "$VirtAddr" ] || [ "$TARGET_FUNC_VADDR" -ge "$MaxVirtAddr" ]; then
        ui_print "Skip out-of-range header line: ${line}"
        continue
    fi

    ui_print "Found target header line: ${line}"
    FILE_OFFSET=$((PhysAddr+TARGET_FUNC_VADDR-VirtAddr))
    break
done << EOF
$HEADERS
EOF

if [ "$FILE_OFFSET" -lt 0 ]; then
    abort "Failed to calculate file offset of __android_log_is_loggable"
fi
ui_print "Calculated file offset of __android_log_is_loggable: ${FILE_OFFSET}"

# normal patched instructions
# MOV W0, #0
# RET
PATCHED_INSTS="\x00\x00\x80\x52\xc0\x03\x5f\xd6"
PATCHED_LEN=8

# handle ARMv8.3 pointer auth, see https://www.qualcomm.com/media/documents/files/whitepaper-pointer-authentication-on-armv8-3.pdf
FIRST_INSTR=$(xxd -p -l4 -s "$FILE_OFFSET" "${TMPDIR}/${TARGET_LIB}")
if [ $? -ne 0 ] || [ -z "$FIRST_INSTR" ]; then
    abort "Failed to get first instruction at ${FILE_OFFSET}"
fi

# PACIASP instruction since ARMv8.3
if [ "$FIRST_INSTR" = "3f2303d5" ]; then
    ui_print "Skip the first PACIASP instruction"
    FILE_OFFSET=$((FILE_OFFSET+4))
    ui_print "Insert AUTIASP instruction before RET"
    # MOV W0, #0
    # AUTIASP
    # RET
    PATCHED_INSTS="\x00\x00\x80\x52\xbf\x23\x03\xd5\xc0\x03\x5f\xd6"
    PATCHED_LEN=12
fi

# patch liblog.so
if ! dd "if=${TMPDIR}/${TARGET_LIB}" bs=1 "count=${FILE_OFFSET}" > "${TMPDIR}/${PATCHED_LIB}"; then
    abort "Failed to patch ${TMPDIR}/${TARGET_LIB}, step1"
fi

# patch
if ! printf "%b" "$PATCHED_INSTS" >> "${TMPDIR}/${PATCHED_LIB}"; then
    abort "Failed to patch ${TMPDIR}/${TARGET_LIB}, step2"
fi

# append remaining file content of liblog.so
FILE_OFFSET=$((FILE_OFFSET+PATCHED_LEN))
if ! dd "if=${TMPDIR}/${TARGET_LIB}" bs=1 "skip=${FILE_OFFSET}" >> "${TMPDIR}/${PATCHED_LIB}"; then
    abort "Failed to patch ${TMPDIR}/${TARGET_LIB}, step3"
fi

# check file size
orig_size=$(stat -c "%s" "${TMPDIR}/${TARGET_LIB}")
patched_size=$(stat -c "%s" "${TMPDIR}/${PATCHED_LIB}")
if [ "$orig_size" != "$patched_size" ]; then
    abort "Failed to patch ${TMPDIR}/${TARGET_LIB}: unexpected file size"
fi

# copy to target dir
mkdir -p "${MODPATH}/${TARGET_DIR}" || abort "Failed to create ${MODPATH}/${TARGET_DIR}"
cp -f "${TMPDIR}/${PATCHED_LIB}" "${MODPATH}/${TARGET_DIR}/${TARGET_LIB}" || abort "Failed to copy patched lib to target"

ui_print "Success to patch ${TARGET_DIR}/${TARGET_LIB}, reboot to take effect!"
