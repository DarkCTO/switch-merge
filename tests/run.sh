#!/usr/bin/env bash
# tests/run.sh - Phase 1 fixture harness: runs both the existing lib/*.sh
# bash function and the equivalent bin/smtool subcommand over every
# fixture in tests/fixtures/, and diffs the output. No real prod.keys or
# large real title files needed - every fixture here is a small, real or
# hand-constructed (with a documented derivation) file that exercises
# pure struct/container parsing only, no crypto.
#
# Run from anywhere: cd "$(dirname "$0")/.." && bash tests/run.sh
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
FIXTURES="$SCRIPT_DIR/tests/fixtures"
SMTOOL="$SCRIPT_DIR/bin/smtool"

source "$SCRIPT_DIR/lib/binfmt.sh"
source "$SCRIPT_DIR/lib/pfs0.sh"
source "$SCRIPT_DIR/lib/hfs0.sh"
source "$SCRIPT_DIR/lib/nca_header.sh"
source "$SCRIPT_DIR/lib/nca_content.sh"
source "$SCRIPT_DIR/lib/romfs.sh"
source "$SCRIPT_DIR/lib/bktr.sh"
source "$SCRIPT_DIR/lib/romfs_build.sh"
source "$SCRIPT_DIR/lib/nca_build.sh"

[ -x "$SMTOOL" ] || { echo "FAIL: $SMTOOL not found or not executable - build it first with 'make -C src/smtool'" >&2; exit 1; }

PASS=0
FAIL=0

# assert_kv_match <test_name> <bash_output> <smtool_output>
# Compares two "KEY=value" multi-line blobs line-for-line (order-
# independent - each is sorted before comparing, since ordering isn't
# part of the contract, only the KEY=value pairs are).
assert_kv_match() {
    local name="$1" bash_out="$2" smtool_out="$3"
    local sorted_bash sorted_smtool
    sorted_bash="$(sort <<< "$bash_out")"
    sorted_smtool="$(sort <<< "$smtool_out")"
    if [ "$sorted_bash" = "$sorted_smtool" ]; then
        echo "PASS: $name"
        PASS=$((PASS + 1))
    else
        echo "FAIL: $name"
        echo "  bash:   $bash_out"
        echo "  smtool: $smtool_out"
        FAIL=$((FAIL + 1))
    fi
}

# --- cnmt-info: all three real cnmt shapes ---
for shape in application patch addoncontent; do
    f="$FIXTURES/$shape.cnmt"
    [ -f "$f" ] || { echo "SKIP: $shape.cnmt fixture missing"; continue; }
    parse_cnmt "$f"
    bash_out="CNMT_TITLE_ID=$CNMT_TITLE_ID
CNMT_VERSION=$CNMT_VERSION
CNMT_TYPE_NAME=$CNMT_TYPE_NAME
CNMT_APPLICATION_ID=$CNMT_APPLICATION_ID
CNMT_PROGRAM_ID=$CNMT_PROGRAM_ID
CNMT_CONTROL_ID=$CNMT_CONTROL_ID
CNMT_LEGALINFORMATION_ID=$CNMT_LEGALINFORMATION_ID
CNMT_DATA_ID=$CNMT_DATA_ID"
    smtool_out="$("$SMTOOL" cnmt-info "$f" | grep -v '^CNMT_TYPE_NUM=')"
    assert_kv_match "cnmt-info ($shape)" "$bash_out" "$smtool_out"
done

# --- nacp-info: default (slot 0) and the slot-1 fallback edge case ---
for f in "$FIXTURES/control.nacp" "$FIXTURES/control_slot1.nacp"; do
    [ -f "$f" ] || { echo "SKIP: $(basename "$f") fixture missing"; continue; }
    parse_nacp "$f"
    bash_out="NACP_NAME=$NACP_NAME
NACP_DISPLAY_VERSION=$NACP_DISPLAY_VERSION"
    smtool_out="$("$SMTOOL" nacp-info "$f")"
    assert_kv_match "nacp-info ($(basename "$f"))" "$bash_out" "$smtool_out"
done

# --- tik-info ---
f="$FIXTURES/ticket.tik"
if [ -f "$f" ]; then
    parse_tik "$f"
    bash_out="TIK_TITLEKEY=$TIK_TITLEKEY
TIK_RIGHTS_ID=$TIK_RIGHTS_ID"
    smtool_out="$("$SMTOOL" tik-info "$f")"
    assert_kv_match "tik-info" "$bash_out" "$smtool_out"
else
    echo "SKIP: ticket.tik fixture missing"
fi

# --- pfs0-list ---
f="$FIXTURES/meta.pfs0"
if [ -f "$f" ]; then
    bash_out="$(_pfs0_read_entries "$f")"
    smtool_out="$("$SMTOOL" pfs0-list "$f")"
    assert_kv_match "pfs0-list" "$bash_out" "$smtool_out"
else
    echo "SKIP: meta.pfs0 fixture missing"
fi

# --- hfs0-list ---
f="$FIXTURES/xci_root.hfs0"
if [ -f "$f" ]; then
    bash_out="$(_hfs0_read_entries "$f" 0)"
    smtool_out="$("$SMTOOL" hfs0-list "$f" 0)"
    assert_kv_match "hfs0-list" "$bash_out" "$smtool_out"
else
    echo "SKIP: xci_root.hfs0 fixture missing"
fi

# --- romfs-extract / romfs-extract-all: real Control NCA RomFs blob ---
f="$FIXTURES/control.romfs"
if [ -f "$f" ]; then
    bash_extract="$(mktemp -d)"
    smtool_extract="$(mktemp -d)"
    romfs_extract "$f" control.nacp "$bash_extract/control.nacp"
    "$SMTOOL" romfs-extract "$f" control.nacp "$smtool_extract/control.nacp"
    if cmp -s "$bash_extract/control.nacp" "$smtool_extract/control.nacp"; then
        echo "PASS: romfs-extract"
        PASS=$((PASS + 1))
    else
        echo "FAIL: romfs-extract"
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$bash_extract" "$smtool_extract"

    bash_extract_all="$(mktemp -d)"
    smtool_extract_all="$(mktemp -d)"
    romfs_extract_all "$f" "$bash_extract_all/out"
    "$SMTOOL" romfs-extract-all "$f" "$smtool_extract_all/out"
    if diff -rq "$bash_extract_all/out" "$smtool_extract_all/out" >/dev/null 2>&1; then
        echo "PASS: romfs-extract-all"
        PASS=$((PASS + 1))
    else
        echo "FAIL: romfs-extract-all"
        FAIL=$((FAIL + 1))
    fi
    rm -rf "$bash_extract_all" "$smtool_extract_all"
else
    echo "SKIP: control.romfs fixture missing"
fi

# --- bktr-relocations / bktr-subsections: synthetic multi-bucket
# fixtures - specifically exercise the fixed-0x4000-stride bug this
# project already found and fixed once (an earlier wrong 0x4014/0x4010
# "stride + overflow entry" guess read past the end of a real 29-bucket
# table) - a single-bucket-only test could not catch a stride regression
# at all, since bucket 1's start offset only matters when there IS one. ---
for shape in reloc subsec; do
    f="$FIXTURES/bktr_${shape}_2bucket.bin"
    [ -f "$f" ] || { echo "SKIP: bktr_${shape}_2bucket.bin fixture missing"; continue; }
    if [ "$shape" = "reloc" ]; then
        bash_out="$(_bktr_parse_bucket0_relocations "$f")"
        smtool_out="$("$SMTOOL" bktr-relocations "$f")"
    else
        bash_out="$(_bktr_parse_bucket0_subsections "$f")"
        smtool_out="$("$SMTOOL" bktr-subsections "$f")"
    fi
    if [ "$bash_out" = "$smtool_out" ]; then
        echo "PASS: bktr-${shape} (2-bucket)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: bktr-${shape} (2-bucket)"
        echo "  bash:   $bash_out"
        echo "  smtool: $smtool_out"
        FAIL=$((FAIL + 1))
    fi
done

# --- bktr-headers: synthetic decrypted-header fixture with a real BKTR
# superblock at section 1 (and deliberately none at section 0, to also
# confirm the bad-magic failure path fires) ---
f="$FIXTURES/bktr_header_section1.bin"
if [ -f "$f" ]; then
    smtool_out="$("$SMTOOL" bktr-headers "$f" --section 1)"
    expected="BKTR_RELOC_OFF=20480
BKTR_RELOC_SIZE=32768
BKTR_SUBSEC_OFF=53248
BKTR_SUBSEC_SIZE=4096"
    assert_kv_match "bktr-headers (section 1)" "$expected" "$smtool_out"

    if "$SMTOOL" bktr-headers "$f" --section 0 >/dev/null 2>&1; then
        echo "FAIL: bktr-headers (section 0, should fail on missing magic)"
        FAIL=$((FAIL + 1))
    else
        echo "PASS: bktr-headers (section 0, correctly fails on missing magic)"
        PASS=$((PASS + 1))
    fi
else
    echo "SKIP: bktr_header_section1.bin fixture missing"
fi

# REAL_KEYS: a real prod.keys, which can't be committed (console-
# specific, gitignored). Every test needing real crypto below checks for
# it and skips automatically if absent - this is the "manual-only
# verification" case tests/run.sh's own design accepted: CI/a clean
# checkout with no keys still gets full coverage of every fixture that
# doesn't need one.
REAL_KEYS="$HOME/.switch/prod.keys"

# --- romfs-build: real flat directory tree (a real Control NCA's
# extracted icons + control.nacp - no subdirectories, but every real
# name/size this format needs to handle). Two checks: (1) byte-for-byte
# identical build output against lib/romfs_build.sh's own bash
# implementation, (2) round-trip through the already-verified
# romfs-extract-all and diff against the original directory - this
# catches structural bugs (e.g. a wrong header field offset) that a
# byte-diff against a POSSIBLY-ALSO-WRONG bash build might not, since it
# validates against the independently-verified reader instead. ---
f="$FIXTURES/control_romfs_dir"
if [ -d "$f" ]; then
    bash_build="$(mktemp -u).bin"
    smtool_build="$(mktemp -u).bin"
    romfs_build "$f" "$bash_build" >/dev/null
    "$SMTOOL" romfs-build "$f" "$smtool_build" >/dev/null
    if cmp -s "$bash_build" "$smtool_build"; then
        echo "PASS: romfs-build (byte-identical vs bash)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: romfs-build (byte-identical vs bash)"
        FAIL=$((FAIL + 1))
    fi

    roundtrip_dir="$(mktemp -d)/out"
    "$SMTOOL" romfs-extract-all "$smtool_build" "$roundtrip_dir"
    if diff -rq "$f" "$roundtrip_dir" >/dev/null 2>&1; then
        echo "PASS: romfs-build (round-trip content matches original directory)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: romfs-build (round-trip content matches original directory)"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$bash_build" "$smtool_build"
    rm -rf "$(dirname "$roundtrip_dir")"
else
    echo "SKIP: control_romfs_dir fixture missing"
fi

# --- build-cnmt / build-meta-nca: needs real prod.keys + real NCA
# files (control.nca fixture covers Control; Program/LegalInformation
# NCAs aren't committed as fixtures - too large even by this project's
# already-generous fixture standards - so this test only exercises the
# Control-only case, still enough to catch a structural regression in
# the header/PFS0/hash-table assembly since it's the same code path
# regardless of how many content NCAs are given). ---
if [ -f "$REAL_KEYS" ] && [ -f "$FIXTURES/control.nca" ]; then
    bash_cnmt="$(mktemp)"
    smtool_cnmt="$(mktemp)"
    nca_build_cnmt "$bash_cnmt" application 01009c6020d1a000 0 "" "$FIXTURES/control.nca" "" ""
    nca_build_patch_cnmt_digest "$bash_cnmt"
    "$SMTOOL" build-cnmt "$smtool_cnmt" application 01009c6020d1a000 0 - "$FIXTURES/control.nca" - -
    if cmp -s "$bash_cnmt" "$smtool_cnmt"; then
        echo "PASS: build-cnmt"
        PASS=$((PASS + 1))
    else
        echo "FAIL: build-cnmt"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$bash_cnmt" "$smtool_cnmt"

    bash_meta="$(mktemp)"
    smtool_meta="$(mktemp)"
    nca_build_meta "$bash_meta" "$REAL_KEYS" 01009c6020d1a000 0 "" "$FIXTURES/control.nca" "" "" ""
    "$SMTOOL" build-meta-nca "$smtool_meta" 01009c6020d1a000 0 --keys "$REAL_KEYS" --control "$FIXTURES/control.nca"
    if cmp -s "$bash_meta" "$smtool_meta"; then
        echo "PASS: build-meta-nca (first pass, zero digest)"
        PASS=$((PASS + 1))
    else
        echo "FAIL: build-meta-nca (first pass, zero digest)"
        FAIL=$((FAIL + 1))
    fi
    rm -f "$bash_meta" "$smtool_meta"
else
    echo "SKIP: build-cnmt/build-meta-nca tests (no $REAL_KEYS or control.nca fixture on this machine)"
fi

# --- decrypt-section / nca-hierarchical-*-layer ---
if [ -f "$REAL_KEYS" ]; then
    control_nca_full="$FIXTURES/control.nca"
    if [ -f "$control_nca_full" ]; then
        bash_key="$(nca_content_key_standard "$control_nca_full" "$REAL_KEYS")"
        smtool_key="$("$SMTOOL" nca-content-key-standard "$control_nca_full" --keys "$REAL_KEYS")"
        assert_kv_match "nca-content-key-standard" "KEY=$bash_key" "KEY=$smtool_key"

        nca_section_info "$control_nca_full" "$REAL_KEYS" 0
        bash_section_kv="NCA_SECTION_PRESENT=$NCA_SECTION_PRESENT
NCA_SECTION_OFFSET=$NCA_SECTION_OFFSET
NCA_SECTION_SIZE=$NCA_SECTION_SIZE
NCA_SECTION_CRYPT_TYPE=$NCA_SECTION_CRYPT_TYPE
NCA_SECTION_CTR=$NCA_SECTION_CTR"
        smtool_section_kv="$("$SMTOOL" nca-section-info "$control_nca_full" --keys "$REAL_KEYS" --section 0)"
        assert_kv_match "nca-section-info" "$bash_section_kv" "$smtool_section_kv"

        bash_decrypt="$(mktemp)"
        smtool_decrypt="$(mktemp)"
        nca_ctr_decrypt_section "$control_nca_full" "$bash_key" "$NCA_SECTION_CTR" "$NCA_SECTION_OFFSET" "$NCA_SECTION_SIZE" "$bash_decrypt"
        "$SMTOOL" decrypt-section "$control_nca_full" --key-hex "$smtool_key" --ctr "$NCA_SECTION_CTR" --offset "$NCA_SECTION_OFFSET" --size "$NCA_SECTION_SIZE" -o "$smtool_decrypt"
        if cmp -s "$bash_decrypt" "$smtool_decrypt"; then
            echo "PASS: decrypt-section"
            PASS=$((PASS + 1))
        else
            echo "FAIL: decrypt-section"
            FAIL=$((FAIL + 1))
        fi
        rm -f "$bash_decrypt" "$smtool_decrypt"

        bash_layer="$(nca_hierarchical_integrity_data_layer "$control_nca_full" "$REAL_KEYS" 0)"
        hdr_tmp="$(mktemp)"
        "$SMTOOL" nca-header-decrypt "$control_nca_full" --keys "$REAL_KEYS" -o "$hdr_tmp"
        smtool_layer="$("$SMTOOL" nca-hierarchical-integrity-layer "$hdr_tmp" --section 0)"
        rm -f "$hdr_tmp"
        assert_kv_match "nca-hierarchical-integrity-layer" "LAYER=$bash_layer" "LAYER=$smtool_layer"
    else
        echo "SKIP: decrypt-section/nca-section-info tests (control.nca fixture missing)"
    fi
else
    echo "SKIP: decrypt-section/nca-section-info tests (no $REAL_KEYS on this machine)"
fi

# --- nca-rights-id / nca-header-decrypt: both fixtures below already
# exercise the big-endian-vs-little-endian sector-tweak distinction that
# matters most here - RightsId lives at header offset 0x230, inside
# SECTOR 1 (0x200-0x3FF), and sector 1's tweak-seed encodes differently
# as big-endian (00...01) vs little-endian (01...00), unlike sector 0
# (all-zero either way, so testing only sector 0 couldn't catch a
# wrong-endianness regression at all). No separate synthetic-tweak
# fixture needed - a wrong endianness here would already produce a
# wrong (garbage, not just differently-formatted) RightsId in the tests
# below.
#
# Needs a real prod.keys, which
# can't be committed (console-specific, gitignored) - skip automatically
# if one isn't present rather than fail the whole suite. This is the
# "manual-only verification" case tests/run.sh's own design accepted:
# CI/a clean checkout with no keys still gets full coverage of every
# fixture that doesn't need one.
if [ -f "$REAL_KEYS" ]; then
    for shape in program_titlekey control_standard; do
        f="$FIXTURES/$shape.nca_header"
        [ -f "$f" ] || { echo "SKIP: $shape.nca_header fixture missing"; continue; }
        bash_out="$(nca_rights_id "$f" "$REAL_KEYS")"
        smtool_out="$("$SMTOOL" nca-rights-id "$f" --keys "$REAL_KEYS")"
        assert_kv_match "nca-rights-id ($shape)" "RIGHTS_ID=$bash_out" "RIGHTS_ID=$smtool_out"
    done
else
    echo "SKIP: nca-rights-id tests (no $REAL_KEYS on this machine)"
fi

echo
echo "$PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
