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
REAL_KEYS="$HOME/.switch/prod.keys"
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
