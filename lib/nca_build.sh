# Pure-bash NCA *building* (writing, not just reading), so switch-merge.sh
# can construct the merged Meta NCA and the BKTR-rebuilt standalone
# Program NCA itself instead of shelling out to `hacpack --ncatype meta`/
# `hacpack --ncatype program --plaintext`. Sources lib/nca_header.sh (for
# aes_ecb_hex, reused here in its ENCRYPT direction), lib/nca_content.sh
# (for nca_ctr_decrypt_section, reused here for content encryption - AES-CTR
# is its own inverse: the same keystream XORed against plaintext produces
# ciphertext or against ciphertext reproduces plaintext, confirmed by an
# encrypt-then-decrypt round-trip test with openssl before trusting this),
# and lib/romfs_build.sh (nca_build_program's own romfs container builder -
# see that file's own header comment for why reusing this project's
# already-reconstructed BKTR romfs bytes directly, skipping a full
# from-scratch container rebuild, turned out NOT to produce byte-identical
# output despite reusing byte-identical file CONTENT).
#
# WHY THIS EXISTS: every field and cryptographic step this file needs was
# derived directly from this project's own vendored bin/hacpack 1.36_r2's
# own C source (nca.c/nca.h/cnmt.c/cnmt.h/pfs0.c/pfs0.h/ivfc.c) - the exact
# version already vendored and already used as read-side ground truth
# throughout this project. No new cryptographic primitive is needed beyond
# what lib/nca_header.sh/lib/nca_content.sh already have: AES-128-ECB
# (encrypt direction, for the key area), AES-128-CTR (content, same
# primitive either direction), AES-128-XTS (encrypt direction, for the
# header), and SHA256 (hash tables / master hashes - openssl already does
# this both directions trivially, it's not a decrypt/encrypt operation at
# all).
#
# WHAT THIS DELIBERATELY DOES NOT CHANGE FROM hacpack'S OWN DEFAULTS,
# confirmed by reading main.c's option parsing (switch-merge.sh never
# passes any of these flags, so hacpack's own unset/default values are
# what every previously-produced merge output was already built with -
# matching these exactly is what makes the output byte-for-byte
# reproducible against prior verified output):
#   - --ncasig (signature type): default NCA_SIG_TYPE_ZERO - fixed_key_sig
#     and npdm_key_sig are both left all-zero (0x100 bytes each) - no RSA
#     signing happens at all, real Nintendo/eShop signing is a separate,
#     out-of-scope concern this project's CFW-target use case doesn't need.
#   - --keygeneration: default 1, meaning nca_header.crypto_type/
#     crypto_type2 are both left 0 (nca_set_keygen's own logic: does
#     nothing unless keygeneration != 1) - so the content key area is
#     always encrypted with key_area_key_application_00 from prod.keys.
#   - --keyareakey (the PLAINTEXT content key later encrypted into the
#     header's key area): default 0x04 repeated 16 times - an arbitrary,
#     fixed placeholder value, not derived from prod.keys at all (only
#     the WRAPPING of this value, via key_area_key_application_00, uses
#     real per-console key material). Confirmed against a real
#     hacpack-built NCA in this project's own merged output: its
#     decrypted key-area slot 2 was exactly 04040404...04.
#
# VERIFIED: see lib/nca_build.sh's own build functions below for the
# specific byte-for-byte comparisons each was checked against (a real Meta
# NCA hacpack itself built, and - for the Program NCA path - byte-for-byte
# identical final merged NSPs compared against previously-verified,
# hardware-tested output).

# _nca_build_reverse_hex <hex_string> -- byte-order reversal, same
# duplicated helper every lib/*.sh file has its own copy of.
_nca_build_reverse_hex() {
    local hex="$1"
    local out="" i
    for (( i = ${#hex} - 2; i >= 0; i -= 2 )); do
        out+="${hex:i:2}"
    done
    echo "$out"
}

# _nca_build_le_hex <decimal_value> <byte_width>
# Encodes a decimal integer as little-endian hex text - same idea as
# lib/pfs0.sh's le_hex, duplicated here to avoid a cross-file dependency
# on that file specifically (this file only truly needs nca_header.sh/
# nca_content.sh, sourced for their crypto primitives).
_nca_build_le_hex() {
    local value="$1" width="$2"
    local be_hex
    be_hex="$(printf "%0$((width * 2))x" "$value")"
    _nca_build_reverse_hex "$be_hex"
}

# _nca_build_sha256_file <path> -- echoes lowercase hex SHA256 of a whole
# file's contents.
_nca_build_sha256_file() {
    sha256sum "$1" | cut -d' ' -f1
}

# _nca_build_content_id_from_nca <nca_path>
# Echoes the lowercase-hex content ID (first 16 bytes / 32 hex chars of
# the whole NCA file's own SHA256) AND renames/copies nothing - callers
# decide what to do with the ID. This is also literally the filename every
# real/hacpack-built NCA uses on disk (confirmed directly in hacpack's own
# nca_create_meta: `hexBinaryString(nca_hash, 16, meta_nca_name, 33)`).
_nca_build_content_id_from_nca() {
    local nca_path="$1"
    _nca_build_sha256_file "$nca_path" | cut -c1-32
}

# nca_build_cnmt <out_path> <title_type: application|addon> <title_id_hex> <title_version_decimal> <program_nca> <control_nca> <legal_nca> <data_nca>
# Writes a PackagedContentMeta (.cnmt) file to out_path, matching hacpack's
# own cnmt_create_application/cnmt_create_addon exactly (field order,
# sizes, and the trailing 32-byte digest left as all-zero placeholder -
# same "build twice, patch in the real digest after" two-pass approach
# switch-merge.sh already uses for hacpack's own --digest flag, unchanged
# by this function - the digest is filled in by the CALLER after building,
# same as before).
#
# Pass empty string for any NCA path that isn't present (e.g. no
# control/legal NCA) - matches hacpack's own settings->foo.valid check.
#
# Layout reference: same PackagedContentMetaHeader/PackagedContentInfo
# struct this project already reads via lib/binfmt.sh's parse_cnmt -
# writing is the exact mirror of that reading, plus the content-record
# HASH field (first 0x20 bytes of each PackagedContentInfo entry) that
# parse_cnmt doesn't need to read but this function does need to write -
# confirmed via hacpack's own cnmt.h cnmt_content_record_t: hash(0x20) +
# ncaid(0x10) + size(0x6) + type(0x1) + reserved(0x1) = 0x38 bytes, same
# entry size parse_cnmt already assumes.
nca_build_cnmt() {
    local out_path="$1" title_type="$2" title_id_hex="$3" title_version="$4"
    local program_nca="$5" control_nca="$6" legal_nca="$7" data_nca="$8"

    local title_id_le title_version_le
    title_id_le="$(_nca_build_le_hex "$((16#$title_id_hex))" 8)"
    title_version_le="$(_nca_build_le_hex "$title_version" 4)"

    local type_byte ext_header_size ext_header_hex
    if [ "$title_type" = "application" ]; then
        type_byte="80"
        ext_header_size=16
        # ApplicationMetaExtendedHeader: PatchId (base_id | 0x800), 4 more
        # reserved/unused fields hacpack also just zeroes (RequiredSystemVersion,
        # RequiredApplicationVersion aren't populated by hacpack's own
        # cnmt_create_application either - confirmed: only patch_title_id
        # is set, required_system_version/padding stay 0-initialized).
        local patch_id_hex patch_id_le
        patch_id_hex="$(printf '%016x' $(( 16#$title_id_hex + 0x800 )))"
        patch_id_le="$(_nca_build_le_hex "$((16#$patch_id_hex))" 8)"
        ext_header_hex="${patch_id_le}0000000000000000"
    else
        type_byte="82"
        ext_header_size=16
        # PatchMetaExtendedHeader (AddOnContent shape): ApplicationId, same
        # 8 bytes of zero padding after.
        ext_header_hex="${title_id_le}0000000000000000"
    fi

    local content_count=0
    local content_records_hex=""
    local nca_path nca_type_byte
    for nca_path_type in "$program_nca:01" "$data_nca:02" "$control_nca:03" "$legal_nca:05"; do
        nca_path="${nca_path_type%:*}"
        nca_type_byte="${nca_path_type#*:}"
        [ -n "$nca_path" ] || continue
        local hash content_id size_bytes
        hash="$(_nca_build_sha256_file "$nca_path")"
        content_id="${hash:0:32}"
        size_bytes="$(stat -c%s "$nca_path")"
        local size_hex_le
        size_hex_le="$(_nca_build_le_hex "$size_bytes" 6)"
        content_records_hex+="${hash}${content_id}${size_hex_le}${nca_type_byte}00"
        content_count=$((content_count + 1))
    done

    local header_hex=""
    header_hex+="$title_id_le"
    header_hex+="$title_version_le"
    header_hex+="$type_byte"
    header_hex+="00"
    header_hex+="$(_nca_build_le_hex "$ext_header_size" 2)"
    header_hex+="$(_nca_build_le_hex "$content_count" 2)"
    header_hex+="0000"
    header_hex+="000000000000000000000000"

    local digest_placeholder_hex
    digest_placeholder_hex="$(printf '00%.0s' $(seq 1 32) | tr -d '\n')"

    printf '%s' "${header_hex}${ext_header_hex}${content_records_hex}${digest_placeholder_hex}" | xxd -r -p > "$out_path"
}

# nca_build_patch_cnmt_digest <cnmt_path>
# Recomputes and rewrites the trailing 32-byte digest of an already-built
# cnmt file (SHA256 of everything except the digest itself) - the same
# two-pass fix switch-merge.sh's hacpack path already does (build once
# with a placeholder, hash the draft, rebuild with the real digest baked
# in), just operating on this project's own nca_build_cnmt output instead
# of hacpack's.
nca_build_patch_cnmt_digest() {
    local cnmt_path="$1"
    local size digest
    size="$(stat -c%s "$cnmt_path")"
    digest="$(head -c "$((size - 32))" "$cnmt_path" | sha256sum | cut -d' ' -f1)"
    printf '%s' "$digest" | xxd -r -p | dd of="$cnmt_path" bs=1 seek=$((size - 32)) conv=notrunc 2>/dev/null
}

# _nca_build_hash_blocks <src_path> <block_size_decimal> <out_path>
# Writes one SHA256 hash per block_size-byte block of src_path to
# out_path, back-to-back, NO padding (padding rules differ between
# callers - PFS0's hash table pads to 0x200, IVFC's own level output pads
# to its own block_size - so padding is the caller's job, see
# _nca_build_pfs0_hashtable/_nca_build_ivfc_level below).
#
# Uses `split` (into real temp files) + a single batched `sha256sum`/
# `xargs sha256sum` call instead of one dd+sha256sum subprocess pair per
# block - a real, measured performance difference: a 320MB romfs needs
# ~19,600 blocks at IVFC's 0x4000 block size, which took an ESTIMATED
# ~20s with the naive per-block-subprocess approach (never actually run
# at that count - the batch approach was adopted before ever hitting
# this scale) versus a MEASURED ~0.4s via split+xargs (confirmed against
# the naive approach's own output, byte-for-byte, on a smaller sample,
# before trusting the batch approach for real builds). `xargs` (not a
# single `sha256sum dir/*` glob) specifically to stay under ARG_MAX for
# very large content - `xargs` auto-batches its own argv size, a plain
# glob expansion does not.
_nca_build_hash_blocks() {
    local src_path="$1" block_size="$2" out_path="$3"
    local src_size
    src_size="$(stat -c%s "$src_path")"

    local split_dir
    split_dir="$(mktemp -d)"
    split -b "$block_size" --numeric-suffixes=0 -a 10 "$src_path" "$split_dir/c_"

    : > "$out_path"
    find "$split_dir" -name 'c_*' | sort | xargs sha256sum | while read -r hash _; do
        printf '%s' "$hash" | xxd -r -p
    done >> "$out_path"

    rm -rf "$split_dir"
}

# _nca_build_pfs0_hashtable <pfs0_path> <block_size_decimal> <out_hashtable_path>
# Writes a PFS0 hash table (one SHA256 hash per block_size-byte block of
# pfs0_path, via _nca_build_hash_blocks above), NUL-padded to a multiple
# of PFS0_PADDING_SIZE (0x200) at the end - the exact mirror of
# pfs0_create_hashtable (hacpack's pfs0.c). Echoes "<hashtable_size>
# <pfs0_offset>" (both decimal, pfs0_offset = the padded hash-table size,
# i.e. where the PFS0 content itself starts within the section).
_nca_build_pfs0_hashtable() {
    local pfs0_path="$1" block_size="$2" out_path="$3"
    _nca_build_hash_blocks "$pfs0_path" "$block_size" "$out_path"

    local hashtable_size padded_size pad_bytes
    hashtable_size="$(stat -c%s "$out_path")"
    padded_size=$(( (hashtable_size + 0x1FF) & ~0x1FF ))
    pad_bytes=$(( padded_size - hashtable_size ))
    [ "$pad_bytes" -gt 0 ] && head -c "$pad_bytes" /dev/zero >> "$out_path"

    echo "$hashtable_size $padded_size"
}

# _nca_build_ivfc_level <src_path> <out_path>
# One IVFC recursion step: writes a SHA256 hash per IVFC_HASH_BLOCK_SIZE
# (0x4000) block of src_path to out_path, padded to a multiple of 0x4000
# at the end - the exact mirror of hacpack's own ivfc_create_level
# (ivfc.c). Echoes out_path's own final (padded) size (decimal) - this
# is exactly what hacpack's own out_size param captures
# (`*out_size = ftello64(dst_file)`, the file just WRITTEN, not the one
# read from) and what gets stored in THAT LEVEL's own
# level_headers[N].hash_data_size field - confirmed by reading the
# call site precisely: `ivfc_create_level(&ivfc_lvls_path[b],
# &ivfc_lvls_path[b + 1], &level_headers[b].hash_data_size)` writes TO
# path[b] FROM path[b+1], and the size captured is path[b]'s own -
# i.e. hash_data_size always describes "how big is this level's own
# file", not "how much of the level above did this one cover" (those
# happen to be related by the hashing but are not the same number once
# padding enters the picture, which is exactly the subtlety this
# comment exists to flag for anyone tempted to assume otherwise from the
# field's name alone).
_nca_build_ivfc_level() {
    local src_path="$1" out_path="$2"
    _nca_build_hash_blocks "$src_path" $((0x4000)) "$out_path"

    local out_size padded_size pad_bytes
    out_size="$(stat -c%s "$out_path")"
    padded_size=$(( (out_size + 0x3FFF) & ~0x3FFF ))
    pad_bytes=$(( padded_size - out_size ))
    [ "$pad_bytes" -gt 0 ] && head -c "$pad_bytes" /dev/zero >> "$out_path"

    echo "$padded_size"
}

# nca_build_zero_npdm_acid <main_npdm_path>
# Zeroes main.npdm's ACID signature (0x100 bytes) and RSA modulus/"key"
# (the next 0x100 bytes) in place - the exact mirror of hacpack's own
# npdm_process (npdm.c), which does this to every exefs it packs UNLESS
# --nozeroacidsig/--nozeroacidkey are passed (switch-merge.sh never
# passes either, so both always get zeroed). This is a real content
# transformation, not just a container-repacking detail: a real update's
# own main.npdm carries a genuine ACID signature/RSA modulus (this
# project's own real update test title has actual non-zero bytes there,
# confirmed directly) - the exefs a rebuilt Program NCA embeds has both
# zeroed, since re-signing over merged/rebuilt content with the ORIGINAL
# signature would be meaningless anyway (the signature covers content
# that's no longer identical), so Nintendo's own installer conventions
# tolerate a zeroed ACID sig/key on non-officially-signed content like
# this project's own merge output already was BEFORE this fix (this
# project's own previously-hardware-verified output already had this
# zeroing applied - by hacpack, not this project's own code, until now).
#
# Layout reference (hacpack's own npdm.h npdm_t/npdm_acid_t structs,
# confirmed against a real main.npdm's own acid_offset field AND the
# real "ACID" magic text location - acid_offset itself points at the
# START of npdm_acid_t, i.e. its signature[0x100] field, NOT at the
# magic - the magic is the 3rd field, at acid_offset+0x200):
#   npdm_t.acid_offset: u32 at file offset 0x78
#   npdm_acid_t.signature: 0x100 bytes at acid_offset+0x0
#   npdm_acid_t.modulus:   0x100 bytes at acid_offset+0x100
nca_build_zero_npdm_acid() {
    local npdm_path="$1"
    local acid_offset_hex acid_offset
    acid_offset_hex="$(dd if="$npdm_path" bs=1 skip=$((0x78)) count=4 2>/dev/null | xxd -p | tr -d '\n')"
    acid_offset=$((16#$(_nca_build_reverse_hex "$acid_offset_hex")))
    dd if=/dev/zero of="$npdm_path" bs=1 seek="$acid_offset" count=$((0x200)) conv=notrunc 2>/dev/null
}

# nca_build_meta <out_nca_path> <keys_file> <title_id_hex> <title_version_decimal> <program_nca> <control_nca> <legal_nca> <data_nca> <digest_hex_or_empty>
# Builds a complete, encrypted Meta NCA at out_nca_path - the pure-bash
# replacement for `hacpack --type nca --ncatype meta --titletype
# application --titleid ... --titleversion ... --programnca ...
# --controlnca ... --legalnca ... [--digest ...] -o <dir>`. Does NOT
# rename the output to its content-ID-based filename (unlike hacpack,
# which renames Meta.nca -> <hash>.cnmt.nca itself) - the caller does that
# with _nca_build_content_id_from_nca, same as it already renamed
# hacpack's own output.
#
# Pass digest_hex as empty string for the FIRST pass (matches hacpack's
# own two-build approach for the same reason: the digest covers the
# cnmt's own bytes, unknowable before the cnmt exists) - the caller then
# reads the resulting cnmt back out (extract_cnmt_from_meta_nca already
# does this) and calls nca_build_patch_cnmt_digest on it, THEN rebuilds
# calling this function again with the real digest hex.
#
# See this file's own header comment for what every hacpack default this
# mirrors (--ncasig zero, --keygeneration 1, --keyareakey 0404...04) and
# why matching them exactly matters for byte-for-byte reproducibility.
#
# VERIFIED: built a Meta NCA for the exact same title/version/constituent-
# NCA inputs a real hacpack build already produced (from this project's
# own previously-verified merged output) and confirmed the result is
# byte-for-byte identical (cmp) to hacpack's own file, including its
# content-ID filename (both derived the same way, from the built file's
# own SHA256).
nca_build_meta() {
    local out_nca="$1" keys_file="$2" title_id_hex="$3" title_version="$4"
    local program_nca="$5" control_nca="$6" legal_nca="$7" data_nca="$8" digest_hex="$9"

    local work_dir
    work_dir="$(mktemp -d)"

    local cnmt_dir="$work_dir/cnmt_dir"
    mkdir -p "$cnmt_dir"
    local cnmt_path="$cnmt_dir/Application_${title_id_hex}.cnmt"
    nca_build_cnmt "$cnmt_path" application "$title_id_hex" "$title_version" "$program_nca" "$control_nca" "$legal_nca" "$data_nca"
    if [ -n "$digest_hex" ]; then
        printf '%s' "$digest_hex" | xxd -r -p | dd of="$cnmt_path" bs=1 seek=$(( $(stat -c%s "$cnmt_path") - 32 )) conv=notrunc 2>/dev/null
    fi

    local pfs0_path="$work_dir/pfs0.bin"
    pfs0_pack "$pfs0_path" "$cnmt_path"

    local hashtable_path="$work_dir/hashtable.bin"
    local block_size=4096
    local hashtable_size pfs0_offset
    read -r hashtable_size pfs0_offset <<< "$(_nca_build_pfs0_hashtable "$pfs0_path" "$block_size" "$hashtable_path")"
    local pfs0_size
    pfs0_size="$(stat -c%s "$pfs0_path")"

    local master_hash
    master_hash="$(head -c "$hashtable_size" "$hashtable_path" | sha256sum | cut -d' ' -f1)"

    # Assemble the FS header (0x200 bytes) for section 0: version(2) +
    # fs_type(1=PFS0) + hash_type(2=PFS0) + crypt_type(3=CTR) + pad(3),
    # then the pfs0_superblock (0x138 bytes): master_hash(0x20) +
    # block_size(4) + always_2(4) + hash_table_offset(8, always 0) +
    # hash_table_size(8) + pfs0_offset(8) + pfs0_size(8) + pad(0xF0), then
    # section_ctr(8, left zero - a fresh build has no per-title "secure
    # value" burned in, confirmed: a real hacpack-built Meta NCA's
    # SectionCTR is all-zero) + pad(0xB8).
    local fs_header_hex=""
    fs_header_hex+="0200"       # version=2
    fs_header_hex+="01"         # fs_type=PFS0
    fs_header_hex+="02"         # hash_type=PFS0
    fs_header_hex+="03"         # crypt_type=CTR
    fs_header_hex+="000000"     # padding
    fs_header_hex+="$master_hash"
    fs_header_hex+="$(_nca_build_le_hex "$block_size" 4)"
    fs_header_hex+="$(_nca_build_le_hex 2 4)"
    fs_header_hex+="$(_nca_build_le_hex 0 8)"
    fs_header_hex+="$(_nca_build_le_hex "$hashtable_size" 8)"
    fs_header_hex+="$(_nca_build_le_hex "$pfs0_offset" 8)"
    fs_header_hex+="$(_nca_build_le_hex "$pfs0_size" 8)"
    fs_header_hex+="$(printf '00%.0s' $(seq 1 240) | tr -d '\n')"  # 0xF0 pad
    fs_header_hex+="0000000000000000"  # section_ctr, zero
    fs_header_hex+="$(printf '00%.0s' $(seq 1 184) | tr -d '\n')"  # 0xB8 pad

    local section_hash
    section_hash="$(printf '%s' "$fs_header_hex" | xxd -r -p | sha256sum | cut -d' ' -f1)"

    # nca_write_padding rounds the WHOLE section's content (hash table +
    # PFS0, not just the hash table) up to the next 0x200 boundary after
    # everything's been written - confirmed against a real hacpack-built
    # Meta NCA, whose actual on-disk section size (total file size minus
    # the 0xC00-byte header) was 0x400 bytes even though pfs0_offset+
    # pfs0_size only added up to 0x360 - the extra 0xA0 is this final
    # whole-section padding, not folded into the hash-table's own
    # already-separately-padded size.
    local raw_content_size=$(( pfs0_offset + pfs0_size ))
    local section_content_size=$(( (raw_content_size + 0x1FF) & ~0x1FF ))
    local trailing_pad=$(( section_content_size - raw_content_size ))
    local total_size=$(( 0xC00 + section_content_size ))
    local media_end=$(( total_size / 0x200 ))

    # Assemble the main header (0x400 bytes before the 4 fs_headers):
    # fixed_key_sig(0x100, zero) + npdm_key_sig(0x100, zero) + magic +
    # distribution(0) + content_type(1=Meta) + crypto_type(0) +
    # kaek_ind(0) + nca_size + title_id + pad(4) + sdk_version +
    # crypto_type2(0) + pad(0xF) + rights_id(0x10, zero) +
    # section_entries[4] (0x10 each) + section_hashes[4] (0x20 each) +
    # encrypted_keys[4] (0x10 each, plaintext for now - encrypted below) +
    # pad(0xC0).
    local main_hex=""
    main_hex+="$(printf '00%.0s' $(seq 1 256) | tr -d '\n')"  # fixed_key_sig, 0x100 zero
    main_hex+="$(printf '00%.0s' $(seq 1 256) | tr -d '\n')"  # npdm_key_sig, 0x100 zero
    main_hex+="4e434133"  # "NCA3"
    main_hex+="00"        # distribution=download
    main_hex+="01"        # content_type=Meta
    main_hex+="00"        # crypto_type=0 (keygeneration 1)
    main_hex+="00"        # kaek_ind=0 (Application)
    main_hex+="$(_nca_build_le_hex "$total_size" 8)"
    main_hex+="$(_nca_build_le_hex "$((16#$title_id_hex))" 8)"
    main_hex+="00000000"  # pad
    main_hex+="$(_nca_build_le_hex $((0xc1100)) 4)"  # sdk_version default
    main_hex+="00"        # crypto_type2=0
    main_hex+="$(printf '00%.0s' $(seq 1 15) | tr -d '\n')"  # pad 0xF

    main_hex+="$(printf '00%.0s' $(seq 1 16) | tr -d '\n')"  # rights_id, zero (standard crypto)

    # section_entries[0]: media_start_offset=6 (0xC00/0x200), media_end_offset, _0x8[0]=1
    main_hex+="$(_nca_build_le_hex 6 4)"
    main_hex+="$(_nca_build_le_hex "$media_end" 4)"
    main_hex+="01000000$(printf '00%.0s' $(seq 1 4) | tr -d '\n')"
    # section_entries[1..3]: all zero
    main_hex+="$(printf '00%.0s' $(seq 1 48) | tr -d '\n')"

    # section_hashes[0..3]: real hash for section 0, zero for the rest
    main_hex+="$section_hash"
    main_hex+="$(printf '00%.0s' $(seq 1 96) | tr -d '\n')"

    # encrypted_keys[4] - plaintext for now (slot 2 = the fixed 0x04
    # placeholder content key, matching hacpack's own --keyareakey
    # default; slots 0/1/3 zero), encrypted in place below.
    local plaintext_keys
    plaintext_keys="$(printf '00%.0s' $(seq 1 16) | tr -d '\n')"
    plaintext_keys+="$(printf '00%.0s' $(seq 1 16) | tr -d '\n')"
    plaintext_keys+="$(printf '04%.0s' $(seq 1 16) | tr -d '\n')"
    plaintext_keys+="$(printf '00%.0s' $(seq 1 16) | tr -d '\n')"
    local gen_hex="00"
    local kaek_key
    kaek_key="$(grep -m1 -oP "^key_area_key_application_${gen_hex}\s*=\s*\K[0-9a-fA-F]+" "$keys_file" | tr -d '\n' | cut -c1-32)"
    [ "${#kaek_key}" -eq 32 ] || { echo "nca_build_meta: key_area_key_application_${gen_hex} not found in $keys_file" >&2; rm -rf "$work_dir"; return 1; }
    local encrypted_keys
    encrypted_keys="$(aes_ecb_hex -e "$kaek_key" "$plaintext_keys")"
    main_hex+="$encrypted_keys"

    main_hex+="$(printf '00%.0s' $(seq 1 192) | tr -d '\n')"  # pad 0xC0

    # fs_headers[0..3]: real one for section 0, zero for the rest
    main_hex+="$fs_header_hex"
    main_hex+="$(printf '00%.0s' $(seq 1 1536) | tr -d '\n')"  # 3 * 0x200 zero

    local header_len_bytes=$(( ${#main_hex} / 2 ))
    [ "$header_len_bytes" -eq $((0xC00)) ] || { echo "nca_build_meta: assembled header is $header_len_bytes bytes, expected 0xC00" >&2; rm -rf "$work_dir"; return 1; }

    local encrypted_header
    encrypted_header="$(nca_encrypt_header "$main_hex" "$keys_file")"

    {
        printf '%s' "$encrypted_header" | xxd -r -p
        head -c "$hashtable_size" "$hashtable_path"
        [ "$((pfs0_offset - hashtable_size))" -gt 0 ] && head -c $((pfs0_offset - hashtable_size)) /dev/zero
        cat "$pfs0_path"
        [ "$trailing_pad" -gt 0 ] && head -c "$trailing_pad" /dev/zero
    } > "$out_nca"

    # Encrypt section 0's content in place (AES-CTR, same construction
    # nca_content_ctr already builds and nca_ctr_decrypt_section already
    # applies - CTR is its own inverse, see this file's header comment).
    local section_key="04040404040404040404040404040404"
    local section_ctr
    section_ctr="$(nca_content_ctr "0000000000000000" $((0xC00)))"
    local encrypted_section="$work_dir/encrypted_section.bin"
    nca_ctr_decrypt_section "$out_nca" "$section_key" "$section_ctr" $((0xC00)) "$section_content_size" "$encrypted_section"
    dd if="$encrypted_section" of="$out_nca" bs=1M seek=$((0xC00)) conv=notrunc oflag=seek_bytes 2>/dev/null

    rm -rf "$work_dir"
}

# nca_build_program <out_nca_path> <keys_file> <title_id_hex> <exefs_files_ordered_list_string> <romfs_dir>
# Builds a complete, PLAINTEXT (crypt_type=None, matching hacpack's own
# --plaintext) Program NCA at out_nca_path from an ordered, space-
# separated (via a nameref array, see below) list of exefs file paths and
# a real romfs directory tree - the pure-bash replacement for
# `hacpack --type nca --ncatype program --plaintext --exefsdir <dir>
# --romfsdir <dir> --titleid ... -o <dir>`.
#
# exefs_files MUST be passed as the NAME of an already-populated bash
# array variable (nameref), in the file's ORIGINAL container order - NOT
# a directory to scan, since relying on filesystem readdir() order to
# recover the original PFS0 order is fragile/filesystem-dependent (this
# project's own lib/pfs0.sh already knows the real order directly from
# the container's own entry table - _pfs0_read_entries - so callers pass
# that instead of a directory switch-merge.sh would otherwise have to
# hope readdir() reproduces). One of the exefs files MUST be named
# "main.npdm" - its ACID signature/key get zeroed via
# nca_build_zero_npdm_acid before packing (see that function's own
# comment for why).
#
# romfs_dir is a real directory tree (e.g. lib/romfs.sh's
# romfs_extract_all output, itself fed by lib/bktr.sh's reconstruction) -
# NOT pre-built romfs bytes. An earlier version of this function tried
# reusing the already-reconstructed raw romfs bytes directly (skip
# rebuilding the container, just IVFC-hash it), on the theory that a
# hacpack --romfsdir round-trip through the same files would reproduce
# the same bytes anyway. That theory was WRONG, confirmed by directly
# testing: hacpack's own romfs_build re-derives the entire directory/file
# table AND the file-data-partition layout from its own from-scratch
# directory walk (alphabetically sorted, not filesystem/readdir order),
# which does not have to - and in the one real title tested, did not -
# produce byte-identical file-partition offsets to a real Nintendo-built
# romfs holding the exact same files. See lib/romfs_build.sh for the full
# reimplementation this function now uses instead.
#
# VERIFIED: built a Program NCA for the exact same title/exefs-files/
# romfs-directory a real hacpack --plaintext build already produced (from
# this project's own previously-verified merged output, re-extracted) and
# confirmed the result is byte-for-byte identical (cmp) to hacpack's own
# file, including content-ID filename. Confirmed on the harder of this
# project's two real BKTR titles too (Well Dweller, ~600MB romfs).
nca_build_program() {
    local out_nca="$1" keys_file="$2" title_id_hex="$3"
    local -n _exefs_files_ref="$4"
    local romfs_dir="$5"

    local work_dir
    work_dir="$(mktemp -d)"

    # --- Section 0: exefs (PFS0, HierarchicalSha256, 0x10000 hash blocks) ---
    local npdm_copy=""
    local f base
    local exefs_files_fixed=()
    for f in "${_exefs_files_ref[@]}"; do
        base="$(basename "$f")"
        if [ "$base" = "main.npdm" ]; then
            npdm_copy="$work_dir/main.npdm"
            cp "$f" "$npdm_copy"
            nca_build_zero_npdm_acid "$npdm_copy"
            exefs_files_fixed+=("$npdm_copy")
        else
            exefs_files_fixed+=("$f")
        fi
    done
    [ -n "$npdm_copy" ] || { echo "nca_build_program: no main.npdm found in exefs file list" >&2; rm -rf "$work_dir"; return 1; }

    local exefs_pfs0="$work_dir/exefs.pfs0"
    pfs0_pack "$exefs_pfs0" "${exefs_files_fixed[@]}"

    local exefs_hashtable="$work_dir/exefs_hashtable.bin"
    local exefs_block_size=65536
    local exefs_hashtable_size exefs_pfs0_offset
    read -r exefs_hashtable_size exefs_pfs0_offset <<< "$(_nca_build_pfs0_hashtable "$exefs_pfs0" "$exefs_block_size" "$exefs_hashtable")"
    local exefs_pfs0_size
    exefs_pfs0_size="$(stat -c%s "$exefs_pfs0")"
    local exefs_master_hash
    exefs_master_hash="$(head -c "$exefs_hashtable_size" "$exefs_hashtable" | sha256sum | cut -d' ' -f1)"

    local exefs_raw_size=$(( exefs_pfs0_offset + exefs_pfs0_size ))
    local exefs_section_size=$(( (exefs_raw_size + 0x1FF) & ~0x1FF ))
    local exefs_trailing_pad=$(( exefs_section_size - exefs_raw_size ))

    local exefs_fs_header_hex=""
    exefs_fs_header_hex+="0200"     # version=2
    exefs_fs_header_hex+="01"       # fs_type=PFS0
    exefs_fs_header_hex+="02"       # hash_type=PFS0
    exefs_fs_header_hex+="01"       # crypt_type=None (plaintext)
    exefs_fs_header_hex+="000000"
    exefs_fs_header_hex+="$exefs_master_hash"
    exefs_fs_header_hex+="$(_nca_build_le_hex "$exefs_block_size" 4)"
    exefs_fs_header_hex+="$(_nca_build_le_hex 2 4)"
    exefs_fs_header_hex+="$(_nca_build_le_hex 0 8)"
    exefs_fs_header_hex+="$(_nca_build_le_hex "$exefs_hashtable_size" 8)"
    exefs_fs_header_hex+="$(_nca_build_le_hex "$exefs_pfs0_offset" 8)"
    exefs_fs_header_hex+="$(_nca_build_le_hex "$exefs_pfs0_size" 8)"
    exefs_fs_header_hex+="$(printf '00%.0s' $(seq 1 240) | tr -d '\n')"
    exefs_fs_header_hex+="0000000000000000"
    exefs_fs_header_hex+="$(printf '00%.0s' $(seq 1 184) | tr -d '\n')"
    local exefs_section_hash
    exefs_section_hash="$(printf '%s' "$exefs_fs_header_hex" | xxd -r -p | sha256sum | cut -d' ' -f1)"

    # --- Section 1: romfs (built from the real directory tree via
    # lib/romfs_build.sh's romfs_build, then IVFC-hashed) ---
    # Array-index naming matches hacpack's own ivfc_lvls_path[0..5] exactly:
    # path[5] = the raw romfs container itself (hacpack's own romfs_build
    # output - this project's own romfs_build, see lib/romfs_build.sh);
    # path[0..4] = the 5 recursive hash levels, each built FROM the level
    # with the next-higher index (path[4] hashes path[5], path[3] hashes
    # path[4], ..., path[0] hashes path[1]). level_headers[N].hash_data_size
    # for EVERY N (0 through 5) is that level's OWN (already-padded, for
    # N<5; naturally block-aligned already for N=5 since romfs_build's own
    # final padding step already rounds up to the IVFC hash block size)
    # file size - confirmed by reading hacpack's exact call site
    # (ivfc_create_level's out_size param captures ftello64 of the file
    # just WRITTEN, i.e. the destination, not the source it hashed).
    local ivfc_path5="$work_dir/romfs.bin"
    local ivfc_size5
    # romfs_build's own echo is the UNPADDED size (before its own final
    # 0x4000-alignment step) - this is what hacpack's own
    # level_headers[5].hash_data_size actually holds, NOT the padded
    # on-disk file size stat would report (a real bug caught here: using
    # stat instead produced a byte-for-byte-verified-wrong IVFC header).
    ivfc_size5="$(romfs_build "$romfs_dir" "$ivfc_path5")"
    local ivfc_path4="$work_dir/ivfc4.bin" ivfc_path3="$work_dir/ivfc3.bin"
    local ivfc_path2="$work_dir/ivfc2.bin" ivfc_path1="$work_dir/ivfc1.bin" ivfc_path0="$work_dir/ivfc0.bin"
    _nca_build_ivfc_level "$ivfc_path5" "$ivfc_path4" > /dev/null
    _nca_build_ivfc_level "$ivfc_path4" "$ivfc_path3" > /dev/null
    _nca_build_ivfc_level "$ivfc_path3" "$ivfc_path2" > /dev/null
    _nca_build_ivfc_level "$ivfc_path2" "$ivfc_path1" > /dev/null
    _nca_build_ivfc_level "$ivfc_path1" "$ivfc_path0" > /dev/null

    local ivfc_size0 ivfc_size1 ivfc_size2 ivfc_size3 ivfc_size4
    ivfc_size0="$(stat -c%s "$ivfc_path0")"
    ivfc_size1="$(stat -c%s "$ivfc_path1")"
    ivfc_size2="$(stat -c%s "$ivfc_path2")"
    ivfc_size3="$(stat -c%s "$ivfc_path3")"
    ivfc_size4="$(stat -c%s "$ivfc_path4")"

    # Logical offsets: level 0 starts at 0, each subsequent level starts
    # right after the previous one's own (padded) size - matches
    # hacpack's own cumulative-offset loop exactly.
    local ivfc_off0=0
    local ivfc_off1=$(( ivfc_off0 + ivfc_size0 ))
    local ivfc_off2=$(( ivfc_off1 + ivfc_size1 ))
    local ivfc_off3=$(( ivfc_off2 + ivfc_size2 ))
    local ivfc_off4=$(( ivfc_off3 + ivfc_size3 ))
    local ivfc_off5=$(( ivfc_off4 + ivfc_size4 ))

    local ivfc_master_hash
    ivfc_master_hash="$(sha256sum "$ivfc_path0" | cut -d' ' -f1)"

    # IVFC header: magic("IVFC") + id(0x20000) + master_hash_size(0x20) +
    # num_levels(7) + 6 level headers (logical_offset u64, hash_data_size
    # u64, block_size u32=0xE for 0x4000, reserved u32) + pad(0x20) +
    # master_hash(0x20).
    local ivfc_hex=""
    ivfc_hex+="49564643"  # "IVFC"
    ivfc_hex+="$(_nca_build_le_hex $((0x20000)) 4)"
    ivfc_hex+="$(_nca_build_le_hex $((0x20)) 4)"
    ivfc_hex+="$(_nca_build_le_hex 7 4)"
    local levels_meta=( "$ivfc_off0:$ivfc_size0" "$ivfc_off1:$ivfc_size1" "$ivfc_off2:$ivfc_size2" "$ivfc_off3:$ivfc_size3" "$ivfc_off4:$ivfc_size4" "$ivfc_off5:$ivfc_size5" )
    local lvl_meta lvl_off lvl_hsize
    for lvl_meta in "${levels_meta[@]}"; do
        lvl_off="${lvl_meta%%:*}"
        lvl_hsize="${lvl_meta#*:}"
        ivfc_hex+="$(_nca_build_le_hex "$lvl_off" 8)"
        ivfc_hex+="$(_nca_build_le_hex "$lvl_hsize" 8)"
        ivfc_hex+="$(_nca_build_le_hex $((0xE)) 4)"
        ivfc_hex+="00000000"
    done
    ivfc_hex+="$(printf '00%.0s' $(seq 1 32) | tr -d '\n')"  # pad 0x20
    ivfc_hex+="$ivfc_master_hash"

    local ivfc_hex_len_bytes=$(( ${#ivfc_hex} / 2 ))
    [ "$ivfc_hex_len_bytes" -eq $((0xE0)) ] || { echo "nca_build_program: IVFC header assembled to $ivfc_hex_len_bytes bytes, expected 0xE0" >&2; rm -rf "$work_dir"; return 1; }

    # NOTE: the section's own total byte size must use ivfc_path5's REAL
    # (padded-to-0x4000) on-disk size, not ivfc_size5 (which is
    # deliberately the unpadded value for the IVFC header field above -
    # see romfs_build's own comment on why those two numbers differ).
    local ivfc_path5_actual_size
    ivfc_path5_actual_size="$(stat -c%s "$ivfc_path5")"
    local romfs_raw_size=$(( ivfc_off5 + ivfc_path5_actual_size ))
    local romfs_section_size=$(( (romfs_raw_size + 0x1FF) & ~0x1FF ))
    local romfs_trailing_pad=$(( romfs_section_size - romfs_raw_size ))

    # FS header 1: version(2) + fs_type(0=RomFs) + hash_type(3=RomFs) +
    # crypt_type(1=None) + pad(3), then romfs_superblock: ivfc_header
    # (0xE0) + pad(0x18) + relocation_header(0x20, zero - no BKTR here) +
    # subsection_header(0x20, zero) + pad to 0x138 total.
    local romfs_fs_header_hex=""
    romfs_fs_header_hex+="0200"
    romfs_fs_header_hex+="00"   # fs_type=RomFs
    romfs_fs_header_hex+="03"   # hash_type=RomFs/HierarchicalIntegrity
    romfs_fs_header_hex+="01"   # crypt_type=None (plaintext)
    romfs_fs_header_hex+="000000"
    romfs_fs_header_hex+="$ivfc_hex"
    local romfs_superblock_remaining=$(( 0x138 - 0xE0 ))
    romfs_fs_header_hex+="$(printf '00%.0s' $(seq 1 "$romfs_superblock_remaining") | tr -d '\n')"
    romfs_fs_header_hex+="0000000000000000"  # section_ctr, zero
    romfs_fs_header_hex+="$(printf '00%.0s' $(seq 1 184) | tr -d '\n')"

    local romfs_fs_header_len_bytes=$(( ${#romfs_fs_header_hex} / 2 ))
    [ "$romfs_fs_header_len_bytes" -eq $((0x200)) ] || { echo "nca_build_program: romfs FS header assembled to $romfs_fs_header_len_bytes bytes, expected 0x200" >&2; rm -rf "$work_dir"; return 1; }

    local romfs_section_hash
    romfs_section_hash="$(printf '%s' "$romfs_fs_header_hex" | xxd -r -p | sha256sum | cut -d' ' -f1)"

    # --- Assemble the full header ---
    local exefs_media_end=$(( (0xC00 + exefs_section_size) / 0x200 ))
    local total_size=$(( 0xC00 + exefs_section_size + romfs_section_size ))
    local romfs_media_start="$exefs_media_end"
    local romfs_media_end=$(( total_size / 0x200 ))

    local main_hex=""
    main_hex+="$(printf '00%.0s' $(seq 1 256) | tr -d '\n')"
    main_hex+="$(printf '00%.0s' $(seq 1 256) | tr -d '\n')"
    main_hex+="4e434133"
    main_hex+="00"
    main_hex+="00"   # content_type=Program
    main_hex+="00"
    main_hex+="00"
    main_hex+="$(_nca_build_le_hex "$total_size" 8)"
    main_hex+="$(_nca_build_le_hex "$((16#$title_id_hex))" 8)"
    main_hex+="00000000"
    main_hex+="$(_nca_build_le_hex $((0xc1100)) 4)"
    main_hex+="00"
    main_hex+="$(printf '00%.0s' $(seq 1 15) | tr -d '\n')"
    main_hex+="$(printf '00%.0s' $(seq 1 16) | tr -d '\n')"  # rights_id, zero

    # section_entries[0] (exefs), [1] (romfs)
    main_hex+="$(_nca_build_le_hex 6 4)"
    main_hex+="$(_nca_build_le_hex "$exefs_media_end" 4)"
    main_hex+="01000000$(printf '00%.0s' $(seq 1 4) | tr -d '\n')"
    main_hex+="$(_nca_build_le_hex "$romfs_media_start" 4)"
    main_hex+="$(_nca_build_le_hex "$romfs_media_end" 4)"
    main_hex+="01000000$(printf '00%.0s' $(seq 1 4) | tr -d '\n')"
    main_hex+="$(printf '00%.0s' $(seq 1 32) | tr -d '\n')"  # sections 2,3 zero

    # section_hashes[0..3]
    main_hex+="$exefs_section_hash"
    main_hex+="$romfs_section_hash"
    main_hex+="$(printf '00%.0s' $(seq 1 64) | tr -d '\n')"

    # encrypted_keys[4] - plaintext for now, slot 2 = 0x04 placeholder
    local plaintext_keys
    plaintext_keys="$(printf '00%.0s' $(seq 1 16) | tr -d '\n')"
    plaintext_keys+="$(printf '00%.0s' $(seq 1 16) | tr -d '\n')"
    plaintext_keys+="$(printf '04%.0s' $(seq 1 16) | tr -d '\n')"
    plaintext_keys+="$(printf '00%.0s' $(seq 1 16) | tr -d '\n')"
    local kaek_key
    kaek_key="$(grep -m1 -oP "^key_area_key_application_00\s*=\s*\K[0-9a-fA-F]+" "$keys_file" | tr -d '\n' | cut -c1-32)"
    [ "${#kaek_key}" -eq 32 ] || { echo "nca_build_program: key_area_key_application_00 not found in $keys_file" >&2; rm -rf "$work_dir"; return 1; }
    main_hex+="$(aes_ecb_hex -e "$kaek_key" "$plaintext_keys")"

    main_hex+="$(printf '00%.0s' $(seq 1 192) | tr -d '\n')"  # pad 0xC0

    # fs_headers[0..3]
    main_hex+="$exefs_fs_header_hex"
    main_hex+="$romfs_fs_header_hex"
    main_hex+="$(printf '00%.0s' $(seq 1 1024) | tr -d '\n')"  # 2 * 0x200 zero

    local header_len_bytes=$(( ${#main_hex} / 2 ))
    [ "$header_len_bytes" -eq $((0xC00)) ] || { echo "nca_build_program: assembled header is $header_len_bytes bytes, expected 0xC00" >&2; rm -rf "$work_dir"; return 1; }

    local encrypted_header
    encrypted_header="$(nca_encrypt_header "$main_hex" "$keys_file")"

    {
        printf '%s' "$encrypted_header" | xxd -r -p
        head -c "$exefs_hashtable_size" "$exefs_hashtable"
        [ "$((exefs_pfs0_offset - exefs_hashtable_size))" -gt 0 ] && head -c $((exefs_pfs0_offset - exefs_hashtable_size)) /dev/zero
        cat "$exefs_pfs0"
        [ "$exefs_trailing_pad" -gt 0 ] && head -c "$exefs_trailing_pad" /dev/zero
        cat "$ivfc_path0" "$ivfc_path1" "$ivfc_path2" "$ivfc_path3" "$ivfc_path4" "$ivfc_path5"
        [ "$romfs_trailing_pad" -gt 0 ] && head -c "$romfs_trailing_pad" /dev/zero
    } > "$out_nca"

    rm -rf "$work_dir"
}
