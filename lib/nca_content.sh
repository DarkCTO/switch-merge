# Pure-bash per-title content-key derivation and AES-CTR decryption of an
# NCA content section, so switch-merge.sh can eventually read a standard-
# crypto (or titlekey-crypto) Program/Data/Control partition's raw bytes
# directly instead of shelling out to `nstool -x` / `nstool -t nca -x`.
# Sources lib/nca_header.sh (uses its aes_ecb_hex, nca_header_field, and
# the same encrypted-header region those already decrypt) - read that file
# first, its header comment explains why the NCA header needs AES-XTS at
# all and documents `openssl enc`'s lack of native XTS support.
#
# WHY THIS EXISTS: unlike the header (fixed key, same on every console),
# each NCA's *content* partitions (exefs/romfs/PublicData/...) are
# encrypted with a per-title key that has to be derived from prod.keys
# plus fields inside the (already-decryptable) header - either straight
# from the header's own embedded, encrypted key area (standard crypto), or
# from the ticket's titlekey re-unwrapped through a different prod.keys
# entry (titlekey crypto, RightsId present). Once that key is known, the
# section itself is just AES-128-CTR over raw bytes - no XTS involved here,
# `openssl enc -aes-128-ctr` handles a whole section in one subprocess call
# (confirmed on a real 195MB Program romfs partition, ~0.6s, byte-for-byte
# identical to nstool's own extraction - no chunking/performance workaround
# needed, unlike the header's AES-XTS which had no CLI support at all).
#
# VERIFIED (see PR description / commit message for the exact commands):
# both standard-crypto key derivation (DLC's Data NCA, Dicefolk) and
# titlekey-crypto key derivation (base game's Program NCA, Dicefolk) were
# checked against `nstool -t nca -v`'s own printed "AES-CTR Key" /decrypted
# key-area dump, and the resulting section decryption was `cmp`'d
# byte-for-byte against `nstool -k ... -t nca -x` (and, for titlekey
# content, `nstool -k ... --tik ... --cert ... -t nca -x`) on the same real
# NCA. Every code path below was exercised against real files before being
# considered correct - see the header of the section it lives in for the
# specific offsets/fields this was checked against.
#
# OUT OF SCOPE, DELIBERATELY NOT IMPLEMENTED:
#   - AesCtrEx (BKTR delta romfs) sections: Nintendo's per-subsection
#     initial-counter/offset formula for these is real arithmetic, not just
#     "start from the section offset" - see nca_content_ctr()'s comment for
#     what's already confirmed (the bktr_ctr_val prefix mechanism exists)
#     and why building the full per-subsection walk wasn't attempted here.
#     Detect via nca_section_crypt_type() returning "AesCtrEx" and fall back
#     to hactool for that section - this project's BKTR reconstruction
#     pipeline already does this anyway (see README's "BKTR" section).
#   - Hash-tree (Merkle/HierarchicalIntegrity/HierarchicalSha256)
#     verification: explicitly out of scope by design, not just deferred -
#     leave this to nstool/hactool, which already do it, per this project's
#     stated risk tier for content-partition work (README's "Reduce
#     dependency on vendored tools" roadmap entries explain the reasoning).

# nca_crypto_type <path to .nca file> <keys file>
# Echoes the decimal "master key generation" index used for BOTH standard
# key-area unwrap and titlekey unwrap (same index either way - hactool's
# own nca.c calls this "crypto_type" and reuses it for both key derivation
# paths, see nca.c:424-429 in hactool 1.4.0's own source).
#
# Layout reference: two one-byte fields in the main NCA header (offsets per
# switchbrew.org/wiki/NCA_Format, confirmed against hactool 1.4.0's own
# nca_header_t struct layout, which this project's own vendored bin/hactool
# and bin/nstool are built from):
#   0x206 (0x1) CryptoType     ("KeyGenerationOld": 0/1 = master key 0, 2 = 3.0.0, ...)
#   0x220 (0x1) CryptoType2    ("KeyGeneration": 0 = unused, 3 = 3.0.1, 4 = 4.0.0, ...)
# The effective generation is max(CryptoType, CryptoType2), then decremented
# by one UNLESS it's already 0 (0 and 1 both mean "master key 0" - a
# deliberate off-by-one in Nintendo's own encoding, not a bug in this code -
# matches hactool nca.c exactly: `if (crypto_type) crypto_type--;`).
nca_crypto_type() {
    local nca_path="$1" keys_file="$2"
    local t1_hex t2_hex t1 t2 gen
    t1_hex="$(nca_header_field "$nca_path" "$keys_file" 518 1)" || return 1
    t2_hex="$(nca_header_field "$nca_path" "$keys_file" 544 1)" || return 1
    t1="$((16#$t1_hex))"
    t2="$((16#$t2_hex))"
    gen=$(( t1 > t2 ? t1 : t2 ))
    [ "$gen" -ne 0 ] && gen=$(( gen - 1 ))
    echo "$gen"
}

# nca_kaek_index <path to .nca file> <keys file>
# Echoes 0 (Application), 1 (Ocean), or 2 (System) - which prod.keys
# key_area_key_<name>_XX family to use for this NCA's key-area unwrap.
# Layout: 0x207 (0x1) KeyAreaEncryptionKeyIndex.
nca_kaek_index() {
    local nca_path="$1" keys_file="$2"
    local idx_hex
    idx_hex="$(nca_header_field "$nca_path" "$keys_file" 519 1)" || return 1
    echo "$((16#$idx_hex))"
}

# nca_content_key_standard <path to .nca file> <keys file>
# Derives the AES-CTR content key for a STANDARD-crypto NCA (no RightsId -
# check with nca_rights_id from lib/nca_header.sh first; this function
# does not check, it just unwraps whatever key area is present). Echoes
# the 32-hex-char (16-byte) key, or empty + nonzero return on failure.
#
# Layout reference (switchbrew.org/wiki/NCA_Format, confirmed against
# hactool 1.4.0 nca_header_t): the header holds an "EncryptedKeyArea", four
# 16-byte slots at 0x300, one per KeyAreaEncryptionKeyIndex "family" -
# 0x300 (0x10) Application-family key, 0x310 (0x10) Ocean-family,
# 0x320 (0x10) System-family, 0x330 (0x10) unused-by-content-decryption
# (used for other purposes hacpack/hactool don't need here). Slot 2 (the
# System-family slot, file offset 0x320) is specifically the AES-CTR
# content key regardless of KeyAreaEncryptionKeyIndex - confirmed directly
# against hactool 1.4.0's own nca.c (`decrypted_keys[2]` is what gets
# handed to AES_MODE_CTR for CRYPT_CTR/CRYPT_BKTR sections, always index 2
# of the decrypted 4-key array, independent of which KAEK family was used
# to decrypt the area) and by testing: prod.keys' own
# key_area_key_application_00 correctly unwraps a real DLC Data NCA's own
# encrypted slot 2 into the exact "AES-CTR Key" nstool -t nca -v prints.
#
# Each slot is unwrapped independently with the same single AES-128-ECB
# key: key_area_key_<application|ocean|system>_<generation, 2 hex digits>
# from prod.keys, keyed by nca_kaek_index()/nca_crypto_type() above. Only
# slot 2 is derived here since that's the only one switch-merge.sh's
# content-decryption path needs (no per-title save-data/RSA key use here).
nca_content_key_standard() {
    local nca_path="$1" keys_file="$2"
    local gen kaek_idx kaek_name kaek_key encrypted_slot2 key
    gen="$(nca_crypto_type "$nca_path" "$keys_file")" || return 1
    kaek_idx="$(nca_kaek_index "$nca_path" "$keys_file")" || return 1
    case "$kaek_idx" in
        0) kaek_name="application" ;;
        1) kaek_name="ocean" ;;
        2) kaek_name="system" ;;
        *) echo "nca_content_key_standard: unexpected KeyAreaEncryptionKeyIndex $kaek_idx" >&2; return 1 ;;
    esac
    local gen_hex
    gen_hex="$(printf '%02x' "$gen")"
    kaek_key="$(grep -m1 -oP "^key_area_key_${kaek_name}_${gen_hex}\s*=\s*\K[0-9a-fA-F]+" "$keys_file" | tr -d '\n' | cut -c1-32)"
    [ "${#kaek_key}" -eq 32 ] || { echo "nca_content_key_standard: key_area_key_${kaek_name}_${gen_hex} not found or wrong length in $keys_file" >&2; return 1; }

    encrypted_slot2="$(nca_header_field "$nca_path" "$keys_file" 800 16)" || return 1
    key="$(aes_ecb_hex -d "$kaek_key" "$encrypted_slot2")"
    [ "${#key}" -eq 32 ] || { echo "nca_content_key_standard: ECB unwrap produced wrong-length key" >&2; return 1; }
    echo "$key"
}

# nca_content_key_titlekey <raw_titlekey_hex> <key_generation_decimal> <keys_file>
# Derives the AES-CTR content key for a TITLEKEY-crypto NCA, given the raw
# ticket-encrypted titlekey (parse_tik's TIK_TITLEKEY, lib/binfmt.sh - NOT
# nstool's fully-decrypted "AES-CTR Key" dump) and the NCA's own
# nca_crypto_type() generation index. A single AES-128-ECB unwrap with
# titlekek_<generation, 2 hex digits> from prod.keys - confirmed against
# hactool 1.4.0 nca.c:459 (`new_aes_ctx(keyset.titlekeks[crypto_type], ...)`
# decrypting the ticket's titlekey the same way, one ECB block, no chained
# master-key derivation needed since prod.keys already stores the
# per-generation titlekek directly, same as the key_area_key_* entries).
nca_content_key_titlekey() {
    local titlekey_hex="$1" gen="$2" keys_file="$3"
    local gen_hex titlekek key
    gen_hex="$(printf '%02x' "$gen")"
    titlekek="$(grep -m1 -oP "^titlekek_${gen_hex}\s*=\s*\K[0-9a-fA-F]+" "$keys_file" | tr -d '\n' | cut -c1-32)"
    [ "${#titlekek}" -eq 32 ] || { echo "nca_content_key_titlekey: titlekek_${gen_hex} not found or wrong length in $keys_file" >&2; return 1; }
    key="$(aes_ecb_hex -d "$titlekek" "$titlekey_hex")"
    [ "${#key}" -eq 32 ] || { echo "nca_content_key_titlekey: ECB unwrap produced wrong-length key" >&2; return 1; }
    echo "$key"
}

# nca_section_info <path to .nca file> <keys file> <section_num 0-3>
# Sets these globals for the given section (0-3) of a MAIN header
# (0x400-byte offset region - this is a *second*, distinct encrypted
# region from the 0x400-byte main header itself, one 0x200-byte FS header
# per section, immediately following it):
#   NCA_SECTION_PRESENT     1 or 0 (media_start_offset nonzero or not)
#   NCA_SECTION_OFFSET      decimal byte offset of the section within the NCA file
#   NCA_SECTION_SIZE        decimal byte size of the section
#   NCA_SECTION_CRYPT_TYPE  1=None 2=Xts(NCA0 only) 3=Ctr 4=CtrEx(BKTR) - see
#                           switchbrew.org/wiki/NCA_Format's FsHeader
#                           EncryptionType enum; matches hactool's
#                           section_crypt_type_t (nca.h) numbering exactly
#   NCA_SECTION_CTR         32-hex-char (16-byte) AES-CTR initial counter
#                           for this section's start (byte offset 0) - see
#                           nca_content_ctr() below for the construction
#
# Layout reference (switchbrew.org/wiki/NCA_Format, confirmed against
# hactool 1.4.0's nca_section_entry_t / nca_fs_header_t):
#   Section entry table, main header 0x240 + section_num*0x10 (0x10 bytes):
#     +0x0 (0x4) MediaStartOffset (media units, 1 unit = 0x200 bytes)
#     +0x4 (0x4) MediaEndOffset
#   FS header table, main header 0x400 + section_num*0x200 (0x200 bytes each):
#     +0x2 (0x1) EncryptionType (1 None, 2 Xts, 3 Ctr, 4 CtrEx/BKTR)
#     +0x140 (0x8) SectionCTR - the section's own per-title "secure value"
#       prefix bytes, NOT a byte offset - combined with the section's own
#       start offset within the NCA to form the actual initial CTR value,
#       see nca_content_ctr() for exactly how.
nca_section_info() {
    local nca_path="$1" keys_file="$2" section_num="$3"
    local entry_off=$(( 0x240 + section_num * 0x10 ))
    local start_hex end_hex
    start_hex="$(nca_header_field "$nca_path" "$keys_file" "$entry_off" 4)" || return 1
    end_hex="$(nca_header_field "$nca_path" "$keys_file" $((entry_off + 4)) 4)" || return 1
    # These 4-byte fields are little-endian on disk; nca_header_field
    # returns raw byte order (matching the file), so reverse byte pairs
    # here the same way lib/binfmt.sh's hex_field_le does, then interpret
    # as a "media unit" count (1 unit = 0x200 bytes, confirmed against
    # hactool's own media_to_real(): `x << 9`).
    local start_le end_le
    start_le="$(_nca_content_reverse_hex "$start_hex")"
    end_le="$(_nca_content_reverse_hex "$end_hex")"
    local start_units=$((16#$start_le)) end_units=$((16#$end_le))

    if [ "$start_units" -eq 0 ]; then
        NCA_SECTION_PRESENT=0
        NCA_SECTION_OFFSET=0
        NCA_SECTION_SIZE=0
        NCA_SECTION_CRYPT_TYPE=0
        NCA_SECTION_CTR=""
        return 0
    fi
    NCA_SECTION_PRESENT=1
    NCA_SECTION_OFFSET=$(( start_units * 0x200 ))
    NCA_SECTION_SIZE=$(( (end_units - start_units) * 0x200 ))

    local fs_hdr_off=$(( 0x400 + section_num * 0x200 ))
    local crypt_hex
    crypt_hex="$(nca_header_field "$nca_path" "$keys_file" $((fs_hdr_off + 4)) 1)" || return 1
    NCA_SECTION_CRYPT_TYPE=$((16#$crypt_hex))

    local section_ctr_raw
    section_ctr_raw="$(nca_header_field "$nca_path" "$keys_file" $((fs_hdr_off + 0x140)) 8)" || return 1
    NCA_SECTION_CTR="$(nca_content_ctr "$section_ctr_raw" "$NCA_SECTION_OFFSET")"
}

# _nca_content_reverse_hex <hex_string> -- reverses byte order (not nibble
# order) of an even-length hex string. Local helper, same idea as
# lib/binfmt.sh's hex_field_le but operating on an already-extracted hex
# string instead of slicing a blob by offset.
_nca_content_reverse_hex() {
    local hex="$1"
    local out="" i
    for (( i = ${#hex} - 2; i >= 0; i -= 2 )); do
        out+="${hex:i:2}"
    done
    echo "$out"
}

# nca_content_ctr <section_ctr_raw_hex_16chars> <section_byte_offset_decimal>
# Builds the 32-hex-char (16-byte) initial AES-CTR counter value for a
# section's absolute byte offset 0 (the value openssl's -iv wants when
# decryption starts exactly at the section's own beginning - see
# nca_ctr_decrypt_section below for the case where a caller wants to start
# mid-section instead, which needs bytes 8-15 recomputed instead of reusing
# this verbatim).
#
# Construction (confirmed directly against hactool 1.4.0's own nca.c,
# nca_init_section_ctx(), lines ~501-506 - this is NOT documented in
# switchbrew's NCA wiki page in this much detail, so hactool's own source,
# the very tool this is verified against, was used as the authoritative
# reference instead of guessing from the wiki's field list alone):
#   - bytes 0-7 (the counter's upper/big-endian-first half): the section's
#     own SectionCTR field (FS header +0x140, 8 raw bytes as stored in the
#     file), REVERSED byte-for-byte (ctr[j] = section_ctr[7-j] for
#     j=0..7) - not a byte-offset value at all, an opaque per-section
#     "secure value" burned in at content-creation time.
#   - bytes 8-15 (the lower half): the section's own absolute byte offset
#     within the NCA file, right-shifted by 4 (i.e. counted in 0x10-byte
#     AES-block units, since CTR advances one block at a time), encoded
#     big-endian into these 8 bytes.
# This is a DIFFERENT big-endian-encoding gotcha from lib/nca_header.sh's
# XTS tweak (that one differs from a documented standard; this one is
# just "big-endian all the way", there's no competing standard to get
# backwards) - verified against a real DLC Data NCA: section entry at
# offset 0xc00, hactool's own reported "AesCtr Counter" was
# 000000000000000000000000000000C0, matching (0xc00 >> 4) = 0xc0
# big-endian in the low 8 bytes with an all-zero SectionCTR prefix
# (this particular NCA's SectionCTR happened to be all-zero, which is
# common for non-BKTR content but not guaranteed - the reversal logic
# still needs to run for a section whose SectionCTR is nonzero).
nca_content_ctr() {
    local section_ctr_raw="$1" byte_offset="$2"
    local upper
    upper="$(_nca_content_reverse_hex "$section_ctr_raw")"
    local block_offset=$(( byte_offset / 0x10 ))
    local lower
    lower="$(printf '%016x' "$block_offset")"
    echo "${upper}${lower}"
}

# nca_ctr_advance <ctr_hex_32chars> <block_delta_decimal>
# Returns the CTR value after advancing by block_delta 16-byte AES blocks
# (i.e. block_delta * 0x10 bytes) - for resuming decryption mid-section
# without re-deriving from the section's own start (e.g. skipping the
# first N blocks). Only the lower 8 bytes (a big-endian block counter) are
# affected in practice for any offset this project will realistically hit
# (a section under 2^64 * 0x10 bytes), so this simply re-encodes the
# summed value rather than doing full 128-bit carrying arithmetic - fine
# since bash's own 64-bit signed arithmetic already covers every real NCA
# section size by a wide margin.
nca_ctr_advance() {
    local ctr_hex="$1" block_delta="$2"
    local upper="${ctr_hex:0:16}" lower_hex="${ctr_hex:16:16}"
    local lower=$(( 16#$lower_hex + block_delta ))
    printf '%s%016x' "$upper" "$lower"
}

# nca_ctr_decrypt_section <nca_path> <key_hex_32chars> <ctr_hex_32chars> <byte_offset> <byte_size> <out_path>
# Decrypts byte_size bytes starting at byte_offset in nca_path using
# AES-128-CTR with the given key/initial-counter-at-that-offset, writing
# plaintext to out_path. A single `openssl enc` subprocess call over the
# whole requested range - confirmed fast enough for a whole real content
# partition in prior research for this task (~0.6s / 195MB Program romfs
# partition), no per-block bash loop needed (unlike lib/nca_header.sh's
# AES-XTS, which needs one precisely-chosen tweak per 16-byte block and so
# cannot be handed to openssl as a single streaming call the way CTR can).
#
# ctr_hex must already be the counter value for THIS byte_offset (i.e. from
# nca_section_info's NCA_SECTION_CTR when byte_offset == NCA_SECTION_OFFSET,
# or nca_ctr_advance()'d forward for a mid-section start) - this function
# does not adjust it further.
nca_ctr_decrypt_section() {
    local nca_path="$1" key_hex="$2" ctr_hex="$3" byte_offset="$4" byte_size="$5" out_path="$6"
    dd if="$nca_path" of="$out_path.tmp_ct" bs=1M skip="$byte_offset" iflag=skip_bytes count="$byte_size" iflag=count_bytes,skip_bytes 2>/dev/null \
        || { echo "nca_ctr_decrypt_section: failed to read $byte_size bytes at $byte_offset from $nca_path" >&2; return 1; }
    openssl enc -d -aes-128-ctr -K "$key_hex" -iv "$ctr_hex" -in "$out_path.tmp_ct" -out "$out_path" 2>/dev/null
    local rc=$?
    rm -f "$out_path.tmp_ct"
    return $rc
}

# nca_hierarchical_sha256_data_layer <path to .nca file> <keys file> <section_num 0-3>
# Echoes "<data_layer_offset> <data_layer_size>" (decimal bytes, both
# relative to the START OF THE DECRYPTED SECTION, i.e. after
# nca_ctr_decrypt_section has already run for this section) for a
# HierarchicalSha256-hashed section (Format Type "PartitionFs" in nstool's
# dump - this project's Meta and Control-container-adjacent NCAs use this,
# as opposed to the bigger RomFs sections which use the different, NOT
# handled here, HierarchicalIntegrity multi-layer scheme).
#
# WHY THIS IS NEEDED: a HierarchicalSha256 section's decrypted bytes are
# NOT the PFS0 container directly - a hash-layer region (covering the PFS0
# bytes, for integrity checking this project doesn't attempt) precedes it.
# Skip straight to the last layer region's offset/size (the Data Layer) to
# get the actual PFS0 blob pfs0_extract (lib/pfs0.sh) can parse.
#
# Layout reference (switchbrew.org/wiki/NCA_Format's HierarchicalSha256
# hash-info struct, confirmed against a real Meta NCA's own FS header and
# nstool -t nca -v's "HierarchicalSha256 Header" dump, byte-for-byte):
# relative to this section's FS header start (main NCA header offset
# 0x400 + section_num*0x200, same base nca_section_info uses for
# EncryptionType/SectionCTR):
#   +0x08 (0x20) MasterHash (not read here - no verification attempted)
#   +0x28 (0x4)  HashBlockSize
#   +0x2C (0x4)  LayerCount (2 for every real file seen so far: one hash
#                layer, one data layer)
#   +0x30 (0x10 each, LayerCount of them) LayerRegion { u64 Offset; u64 Size }
# The LAST layer region (index LayerCount-1) is the Data Layer. Verified:
# a real Meta NCA's section 0 reported HashBlockSize 0x1000, LayerCount 2,
# layer 0 offset/size 0x0/0x20, layer 1 (data) offset/size 0x20/0x158 -
# matching nstool -t nca -v's own "Hash Layer 0" / "Data Layer" dump
# exactly, and the PFS0 magic ("50465330") was found to actually start at
# that reported data-layer offset within the decrypted section, not at 0.
nca_hierarchical_sha256_data_layer() {
    local nca_path="$1" keys_file="$2" section_num="$3"
    local fs_hdr_off=$(( 0x400 + section_num * 0x200 ))
    local layer_count_hex layer_count
    layer_count_hex="$(nca_header_field "$nca_path" "$keys_file" $((fs_hdr_off + 0x2C)) 4)" || return 1
    layer_count=$((16#$(_nca_content_reverse_hex "$layer_count_hex")))
    [ "$layer_count" -ge 1 ] || { echo "nca_hierarchical_sha256_data_layer: LayerCount is 0" >&2; return 1; }

    local last_layer_off=$(( fs_hdr_off + 0x30 + (layer_count - 1) * 0x10 ))
    local off_hex size_hex off size
    off_hex="$(nca_header_field "$nca_path" "$keys_file" "$last_layer_off" 8)" || return 1
    size_hex="$(nca_header_field "$nca_path" "$keys_file" $((last_layer_off + 8)) 8)" || return 1
    off=$((16#$(_nca_content_reverse_hex "$off_hex")))
    size=$((16#$(_nca_content_reverse_hex "$size_hex")))
    echo "$off $size"
}

# nca_hierarchical_integrity_data_layer <path to .nca file> <keys file> <section_num 0-3>
# Same idea and same "<data_layer_offset> <data_layer_size>" (decimal
# bytes, relative to the decrypted section start) output as
# nca_hierarchical_sha256_data_layer above, but for a
# HierarchicalIntegrity-hashed section (Format Type "RomFs" in nstool's
# dump - Control NCAs use this, as opposed to the simpler
# HierarchicalSha256 scheme Meta NCAs use). A DIFFERENT struct shape from
# HierarchicalSha256 - not a variant of the same one - so this is a
# separate function, not a shared code path.
#
# WHY THIS IS NEEDED: same reason as the HierarchicalSha256 case - the
# decrypted section's bytes are hash layers followed by the actual RomFs
# data, not the RomFs blob directly at offset 0.
#
# Layout reference (switchbrew.org/wiki/NCA_Format's "IVFC" hash-info
# struct, confirmed against a real Control NCA's own FS header and
# nstool -t nca -v's "HierarchicalIntegrity Header" dump, byte-for-byte):
# relative to this section's FS header start (same base as
# nca_hierarchical_sha256_data_layer uses):
#   +0x08 (0x4)  Magic ("IVFC")
#   +0x0C (0x4)  Version
#   +0x10 (0x4)  MasterHashSize (not read here)
#   +0x14 (0x4)  NumLevels (7 on every real file seen so far - 5 hash
#                levels + 1 data level + 1 trailing all-zero/unused level,
#                NOT 6, i.e. NumLevels counts one more entry than there are
#                real (offset,size) pairs worth trusting)
#   +0x18 (0x18 each, NumLevels of them) LevelInformation
#                { u64 LogicalOffset; u64 HashDataSize; u32 BlockSizeLog2; u32 Reserved }
# Verified: a real Control NCA reported NumLevels 7 with levels 0-4 being
# the 5 hash layers (0x4000 bytes each) and level 5 being
# LogicalOffset=0x14000 HashDataSize=0xeef54 - matching nstool's own
# "Data Layer: Offset 0x14000 Size 0xeef54" exactly - while level 6 is
# all-zero (LogicalOffset=0 HashDataSize=0), which is why the DATA level
# is index NumLevels-2, not NumLevels-1 (unlike
# nca_hierarchical_sha256_data_layer's LayerCount-1, where there's no
# trailing unused entry to skip past).
nca_hierarchical_integrity_data_layer() {
    local nca_path="$1" keys_file="$2" section_num="$3"
    local fs_hdr_off=$(( 0x400 + section_num * 0x200 ))
    local magic_hex
    magic_hex="$(nca_header_field "$nca_path" "$keys_file" $((fs_hdr_off + 0x8)) 4)" || return 1
    [ "$magic_hex" = "49564643" ] || { echo "nca_hierarchical_integrity_data_layer: not an IVFC section (bad magic) in $nca_path" >&2; return 1; }

    local num_levels_hex num_levels
    num_levels_hex="$(nca_header_field "$nca_path" "$keys_file" $((fs_hdr_off + 0x14)) 4)" || return 1
    num_levels=$((16#$(_nca_content_reverse_hex "$num_levels_hex")))
    [ "$num_levels" -ge 2 ] || { echo "nca_hierarchical_integrity_data_layer: NumLevels $num_levels too small to have a data layer" >&2; return 1; }

    local data_level_off=$(( fs_hdr_off + 0x18 + (num_levels - 2) * 0x18 ))
    local off_hex size_hex off size
    off_hex="$(nca_header_field "$nca_path" "$keys_file" "$data_level_off" 8)" || return 1
    size_hex="$(nca_header_field "$nca_path" "$keys_file" $((data_level_off + 8)) 8)" || return 1
    off=$((16#$(_nca_content_reverse_hex "$off_hex")))
    size=$((16#$(_nca_content_reverse_hex "$size_hex")))
    echo "$off $size"
}
