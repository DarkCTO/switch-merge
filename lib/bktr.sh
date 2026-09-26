# Pure-bash BKTR (patch-romfs) reconstruction, so switch-merge.sh can
# rebuild an update's full exefs/romfs from its BKTR delta against the
# base's own romfs, instead of shelling out to `hactool --basenca`.
# Sources lib/nca_header.sh/lib/nca_content.sh - read those first.
#
# WHY THIS EXISTS: an update's Program NCA romfs partition is very often
# NOT a full copy - it's a genuine binary delta (BKTR) against the base's
# romfs (see README's "BKTR" section and "The debugging story" for why
# this exists and how it was first discovered). Reconstructing the full
# content means walking a two-table indirection: a RELOCATION table maps
# virtual (reconstructed) romfs byte ranges to either "read this many
# bytes from the update's own physical romfs bytes" (is_patch) or "read
# this many bytes from the base's own physical romfs bytes at a
# corresponding offset" (not is_patch); and a SUBSECTION table gives each
# physical byte range within the UPDATE side its own AES-CTR "ctr_val"
# (the update's real bytes are encrypted per-subsection, not with one CTR
# for the whole section - this is what earlier bktr work in this project
# used hactool for).
#
# THE FORMAT WAS NOT FOUND DOCUMENTED ANYWHERE ONLINE (switchbrew's wiki
# doesn't cover BKTR's internal relocation/subsection table layout at all,
# only the higher-level "Enc. Type: AesCtrEx" concept) - every struct
# layout and lookup rule below was derived directly from vendored
# bin/hactool's own C source (nca.c/nca.h/bktr.c/bktr.h, hactool 1.4.0,
# the exact version this project already vendors and already found one
# real confirmed bug in - see README's Bug #3), NOT guessed, and every
# field was cross-checked against real decrypted bytes from this
# project's own test titles before being trusted (see each function's own
# comment for the specific verification). Bug #3's own patch
# (bin/patches/hactool-1.4.0-bktr-layout-fix.patch) already established
# that hactool's own subsection_header/relocation_header trailing-gap
# validation is overly strict and unnecessary for correctness (confirmed
# against nxdumptool, a maintained tool with no equivalent check) - this
# file does not implement that check at all, consistent with that finding.
#
# VERIFIED: the full reconstruction (relocation walk + subsection-aware
# patch-side decryption + base-side plain reads) was run against both real
# BKTR update titles in this project (Dicefolk: 1 subsection total, simple
# case; Well Dweller: 41 subsections, exercises mid-relocation-chunk
# subsection splitting) and diffed BYTE-FOR-BYTE (via cmp) against
# hactool's own `--basenca`-reconstructed exefs/romfs output for the same
# files - see switch-merge.sh's use of this file for the exact comparison
# this was checked against before being trusted.

# _bktr_reverse_hex <hex_string> -- byte-order reversal, same idea as every
# other lib/*.sh file's local copy of this. Duplicated here so this file
# has no cross-file sourcing-order dependency beyond nca_header.sh/
# nca_content.sh (both actually needed, unlike this trivial helper).
_bktr_reverse_hex() {
    local hex="$1"
    local out="" i
    for (( i = ${#hex} - 2; i >= 0; i -= 2 )); do
        out+="${hex:i:2}"
    done
    echo "$out"
}

# bktr_headers <nca_path> <keys_file> <section_num>
# Sets BKTR_RELOC_OFF/BKTR_RELOC_SIZE/BKTR_SUBSEC_OFF/BKTR_SUBSEC_SIZE
# (decimal, all relative to the START of the decrypted section, i.e. same
# frame as nca_hierarchical_integrity_data_layer's output) by reading the
# bktr_superblock_t that sits right after the section's IVFC integrity
# header in the FS header.
#
# Layout reference (derived from hactool 1.4.0's nca.h bktr_superblock_t
# and confirmed against two real update Program NCAs' own FS headers,
# byte-for-byte against the relocation_header/subsection_header fields'
# offset+size relationship, which must satisfy
# relocation.offset+relocation.size == subsection.offset exactly - true on
# both real files tested):
#   FS header (same 0x400+section_num*0x200 base as nca_section_info /
#   nca_hierarchical_integrity_data_layer use):
#     +0x100 (0x20) relocation_header: bktr_header_t
#                     { u64 offset; u64 size; u32 magic("BKTR"); u32 version;
#                       u32 num_entries; u32 reserved }
#     +0x120 (0x20) subsection_header: same bktr_header_t shape
#   NOTE: this is a 0x20 (32-byte) gap from the end of the 0xE0-byte IVFC
#   header (0xE0 + padding = 0x100 exactly, confirmed empirically - do NOT
#   trust nca.h's own "_0xE0[0x18]" padding-size comment literally, it
#   does not match real files' actual byte layout by 8 bytes; this file
#   uses the offset that was actually confirmed against real bytes).
bktr_headers() {
    local nca_path="$1" keys_file="$2" section_num="$3"
    local fs_hdr_off=$(( 0x400 + section_num * 0x200 ))
    local reloc_hdr_off=$(( fs_hdr_off + 0x100 ))
    local subsec_hdr_off=$(( fs_hdr_off + 0x120 ))

    local magic1 magic2
    magic1="$(nca_header_field "$nca_path" "$keys_file" $((reloc_hdr_off + 16)) 4)" || return 1
    magic2="$(nca_header_field "$nca_path" "$keys_file" $((subsec_hdr_off + 16)) 4)" || return 1
    [ "$magic1" = "424b5452" ] && [ "$magic2" = "424b5452" ] || { echo "bktr_headers: BKTR magic not found at expected offset in $nca_path" >&2; return 1; }

    local off_hex size_hex
    off_hex="$(nca_header_field "$nca_path" "$keys_file" "$reloc_hdr_off" 8)" || return 1
    size_hex="$(nca_header_field "$nca_path" "$keys_file" $((reloc_hdr_off + 8)) 8)" || return 1
    BKTR_RELOC_OFF=$((16#$(_bktr_reverse_hex "$off_hex")))
    BKTR_RELOC_SIZE=$((16#$(_bktr_reverse_hex "$size_hex")))

    off_hex="$(nca_header_field "$nca_path" "$keys_file" "$subsec_hdr_off" 8)" || return 1
    size_hex="$(nca_header_field "$nca_path" "$keys_file" $((subsec_hdr_off + 8)) 8)" || return 1
    BKTR_SUBSEC_OFF=$((16#$(_bktr_reverse_hex "$off_hex")))
    BKTR_SUBSEC_SIZE=$((16#$(_bktr_reverse_hex "$size_hex")))
}

# bktr_read_relocation_table <nca_path> <key_hex> <section_ctr_raw_hex> <section_offset> <reloc_off> <reloc_size> <out_path>
# Decrypts the relocation table (a ordinary, non-BKTR AES-CTR read at the
# section's own physical offset - the table itself isn't part of the
# virtual/relocated address space, see lib/bktr.sh's header comment and
# nca_content_ctr's own doc for why this is just a plain per-offset CTR,
# not the BKTR-specific one) to out_path.
bktr_read_relocation_table() {
    local nca_path="$1" key_hex="$2" section_ctr_raw="$3" section_offset="$4" reloc_off="$5" reloc_size="$6" out_path="$7"
    local abs_off=$(( section_offset + reloc_off ))
    local ctr
    ctr="$(nca_content_ctr "$section_ctr_raw" "$abs_off")"
    nca_ctr_decrypt_section "$nca_path" "$key_hex" "$ctr" "$abs_off" "$reloc_size" "$out_path"
}

# bktr_read_subsection_table <nca_path> <key_hex> <section_ctr_raw_hex> <section_offset> <subsec_off> <subsec_size> <out_path>
# Same idea as bktr_read_relocation_table, for the subsection table.
bktr_read_subsection_table() {
    local nca_path="$1" key_hex="$2" section_ctr_raw="$3" section_offset="$4" subsec_off="$5" subsec_size="$6" out_path="$7"
    local abs_off=$(( section_offset + subsec_off ))
    local ctr
    ctr="$(nca_content_ctr "$section_ctr_raw" "$abs_off")"
    nca_ctr_decrypt_section "$nca_path" "$key_hex" "$ctr" "$abs_off" "$subsec_size" "$out_path"
}

# _bktr_parse_bucket0_relocations <table_file>
# Prints one "<virt_offset> <phys_offset> <is_patch>" line per relocation
# entry, plus a final synthetic line for total_size (is_patch field empty)
# to mark the end - only reads bucket 0 (num_buckets is 1 on every real
# file seen so far in this project; see file header comment).
#
# Layout reference (hactool 1.4.0's bktr.h bktr_relocation_block_t /
# bktr_relocation_bucket_t, confirmed against two real files' own
# num_entries/total_size fields matching the corresponding
# relocation_header/subsection_header num_entries - see bktr_headers'
# caller for where those get cross-checked):
#   Block header (0x10 bytes): u32 _0x0; u32 num_buckets; u64 total_size
#   bucket_virtual_offsets[0x3FF0/8] (0x3FF0 bytes, i.e. up to 2046 u64
#   entries) - this array is ALWAYS this fixed 0x3FF0-byte size on disk
#   regardless of num_buckets (hactool's own bktr_relocation_block_t
#   struct declares it as a fixed-size array, not sized to num_buckets),
#   so bucket 0 always starts at file offset 0x10+0x3FF0=0x4000 no matter
#   how many buckets exist - only the CONTENTS of this array (how many of
#   the 2046 slots hold a real offset vs padding) depend on num_buckets.
#   Buckets themselves are back-to-back after that, each at a FIXED
#   stride of 0x4000 bytes - confirmed directly from hactool's own
#   bktr_relocation_bucket_t: header (0x10) + entries[0x3FF0/20] (818
#   entries of 20 bytes = 16360 bytes) + padding[0x3FF0 % 20] (8 bytes)
#   = 0x10 + 16360 + 8 = 0x4000 exactly. There is no extra "overflow"
#   entry - an earlier version of this comment claimed a 0x4014 stride
#   (0x4000 + one entry), which was wrong and caused reads to run past
#   the end of a real multi-bucket (num_buckets=29) table's file:
#     Bucket header (0x10 bytes): u32 _0x0; u32 num_entries; u64 virtual_offset_end
#     entries[] (0x14 bytes each): u64 virt_offset; u64 phys_offset; u32 is_patch
#
# Bucket SELECTION for a real, multi-bucket table (num_buckets > 1) walks
# bucket_virtual_offsets the same simple way hactool's own
# bktr_get_relocation does: bucket 0 covers [0, bucket_virtual_offsets[1]),
# bucket 1 covers [bucket_virtual_offsets[1], bucket_virtual_offsets[2]),
# etc. - this function reads and prints EVERY bucket's entries back-to-
# back in ascending virtual-offset order (which is already the correct
# global order, since each bucket's own entries are internally sorted by
# virt_offset and buckets themselves are laid out in ascending
# virtual-offset-range order), so the caller can treat the combined
# output exactly like the old single-bucket case's output - no bucket
# boundary needs to be exposed to callers at all.
_bktr_parse_bucket0_relocations() {
    local table_file="$1"
    local hdr_hex
    hdr_hex="$(dd if="$table_file" bs=1 count=$((0x10)) 2>/dev/null | xxd -p | tr -d '\n')"
    local num_buckets total_size
    num_buckets=$((16#$(_bktr_reverse_hex "${hdr_hex:8:8}")))
    total_size=$((16#$(_bktr_reverse_hex "${hdr_hex:16:16}")))

    local bucket_stride=$((0x4000))
    local all_buckets_off=$(( 0x10 + 0x3FF0 ))
    local all_buckets_size=$(( num_buckets * bucket_stride ))
    local buckets_hex
    buckets_hex="$(dd if="$table_file" bs=1M skip="$all_buckets_off" count="$all_buckets_size" iflag=skip_bytes,count_bytes 2>/dev/null | xxd -p | tr -d '\n')"

    local b bucket_hex_off bucket_hex num_entries entries_hex_off
    local i entry_off virt phys is_patch
    for (( b = 0; b < num_buckets; b++ )); do
        bucket_hex_off=$(( b * bucket_stride * 2 ))
        bucket_hex="${buckets_hex:bucket_hex_off}"
        num_entries=$((16#$(_bktr_reverse_hex "${bucket_hex:8:8}")))
        entries_hex_off=$(( 0x10 * 2 ))
        for (( i = 0; i < num_entries; i++ )); do
            entry_off=$(( entries_hex_off + i * 0x14 * 2 ))
            virt=$((16#$(_bktr_reverse_hex "${bucket_hex:entry_off:16}")))
            phys=$((16#$(_bktr_reverse_hex "${bucket_hex:$((entry_off + 16)):16}")))
            is_patch=$((16#$(_bktr_reverse_hex "${bucket_hex:$((entry_off + 32)):8}")))
            echo "$virt $phys $is_patch"
        done
    done
    echo "$total_size 0 "
}

# _bktr_parse_bucket0_subsections <table_file>
# Prints one "<phys_offset> <ctr_val>" line per subsection entry (walking
# EVERY bucket, in ascending physical-offset order - see
# _bktr_parse_bucket0_relocations' own comment for why concatenating all
# buckets' entries in order is safe and needs no bucket boundary exposed
# to the caller), plus a final synthetic line for the LAST bucket's own
# physical_offset_end (ctr_val field empty) - only the last bucket's
# value is the true final physical end of the whole table; an earlier
# bucket's own physical_offset_end is just where THAT bucket's own range
# ends, not the table's.
#
# Layout reference (hactool 1.4.0's bktr.h bktr_subsection_block_t /
# bktr_subsection_bucket_t) - same fixed-size bucket_physical_offsets
# array (0x3FF0 bytes) and same fixed 0x4000-byte per-bucket stride as
# _bktr_parse_bucket0_relocations (header 0x10 + entries[0x3FF] of 16
# bytes each = 0x10 + 0x3FF0 = 0x4000 exactly - no padding needed here
# since 0x3FF0 % 16 == 0, and no overflow entry either):
#   Block header (0x10 bytes): u32 _0x0; u32 num_buckets; u64 total_size
#   Bucket 0 at 0x10 + 0x3FF0 = 0x4000:
#     Bucket header (0x10 bytes): u32 _0x0; u32 num_entries; u64 physical_offset_end
#     entries[] (0x10 bytes each): u64 offset; u32 _0x8; u32 ctr_val
_bktr_parse_bucket0_subsections() {
    local table_file="$1"
    local hdr_hex
    hdr_hex="$(dd if="$table_file" bs=1 count=$((0x10)) 2>/dev/null | xxd -p | tr -d '\n')"
    local num_buckets
    num_buckets=$((16#$(_bktr_reverse_hex "${hdr_hex:8:8}")))

    local bucket_stride=$((0x4000))
    local all_buckets_off=$(( 0x10 + 0x3FF0 ))
    local all_buckets_size=$(( num_buckets * bucket_stride ))
    local buckets_hex
    buckets_hex="$(dd if="$table_file" bs=1M skip="$all_buckets_off" count="$all_buckets_size" iflag=skip_bytes,count_bytes 2>/dev/null | xxd -p | tr -d '\n')"

    local b bucket_hex_off bucket_hex num_entries physical_offset_end entries_hex_off
    local i entry_off off ctr_val last_physical_offset_end
    for (( b = 0; b < num_buckets; b++ )); do
        bucket_hex_off=$(( b * bucket_stride * 2 ))
        bucket_hex="${buckets_hex:bucket_hex_off}"
        num_entries=$((16#$(_bktr_reverse_hex "${bucket_hex:8:8}")))
        physical_offset_end=$((16#$(_bktr_reverse_hex "${bucket_hex:16:16}")))
        last_physical_offset_end="$physical_offset_end"
        entries_hex_off=$(( 0x10 * 2 ))
        for (( i = 0; i < num_entries; i++ )); do
            entry_off=$(( entries_hex_off + i * 0x10 * 2 ))
            off=$((16#$(_bktr_reverse_hex "${bucket_hex:entry_off:16}")))
            ctr_val=$((16#$(_bktr_reverse_hex "${bucket_hex:$((entry_off + 24)):8}")))
            echo "$off $ctr_val"
        done
    done
    echo "$last_physical_offset_end "
}

# bktr_reconstruct <update_nca_path> <keys_file> <update_key_hex> <update_section_num> <base_decrypted_romfs_path> <out_path>
# Reconstructs the FULL virtual romfs by walking the relocation table:
# each relocation entry's byte range is copied either from the update
# NCA's own physical romfs bytes (decrypted per-subsection, is_patch) or
# straight from base_decrypted_romfs_path at the SAME relocation-relative
# offset (not is_patch) - base_decrypted_romfs_path must be the base
# Program NCA's own romfs SECTION already decrypted to plaintext (e.g. via
# nca_ctr_decrypt_section on the base's own romfs section - NOT the whole
# NCA file, and NOT hactool's --plaintext NCA-container format, which is
# a different, non-standard intermediate this project doesn't need at
# all since it can decrypt the base's romfs section directly).
#
# A patch-type relocation entry's physical byte range can itself span
# multiple subsections (each with its own AES-CTR ctr_val) - confirmed
# happening on a real file (Well Dweller: 18 of 243 relocation entries
# cross a subsection boundary) - so each relocation entry is further split
# at every subsection boundary it crosses before decrypting.
#
# Verified: full output diffed byte-for-byte (cmp) against hactool
# --basenca's own reconstructed exefs+romfs on both Dicefolk (1 total
# subsection - exercises the simple non-splitting path) and Well Dweller
# (41 subsections, 18 relocation entries split - exercises the general
# case) real update titles.
bktr_reconstruct() {
    local update_nca="$1" keys_file="$2" update_key="$3" section_num="$4" base_romfs="$5" out_path="$6"

    bktr_headers "$update_nca" "$keys_file" "$section_num" || return 1
    nca_section_info "$update_nca" "$keys_file" "$section_num" || return 1
    local section_offset="$NCA_SECTION_OFFSET"
    local section_ctr_raw
    section_ctr_raw="$(nca_header_field "$update_nca" "$keys_file" $((0x400 + section_num * 0x200 + 0x140)) 8)" || return 1

    local work_dir
    work_dir="$(mktemp -d)"

    bktr_read_relocation_table "$update_nca" "$update_key" "$section_ctr_raw" "$section_offset" "$BKTR_RELOC_OFF" "$BKTR_RELOC_SIZE" "$work_dir/reloc.bin" || { rm -rf "$work_dir"; return 1; }
    bktr_read_subsection_table "$update_nca" "$update_key" "$section_ctr_raw" "$section_offset" "$BKTR_SUBSEC_OFF" "$BKTR_SUBSEC_SIZE" "$work_dir/subsec.bin" || { rm -rf "$work_dir"; return 1; }

    # Captured via a plain command substitution first, NOT piped straight
    # into `while read ... done < <(...)`, specifically so a failure
    # inside the parser (e.g. an unsupported table layout) surfaces as a
    # clean, checkable exit status here - a process substitution's own
    # exit code is awkward to check inline, and silently continuing past
    # a failed parse with these arrays never populated previously crashed
    # with a bash "unbound variable" error deep inside the reconstruction
    # loop below instead of a clear message at the point of the real
    # failure.
    local subsec_parsed
    subsec_parsed="$(_bktr_parse_bucket0_subsections "$work_dir/subsec.bin")" || { rm -rf "$work_dir"; return 1; }

    local -a subsec_off=() subsec_ctrval=()
    local off ctr_val
    while read -r off ctr_val; do
        subsec_off+=("$off")
        subsec_ctrval+=("$ctr_val")
    done <<< "$subsec_parsed"
    local num_subsec=$(( ${#subsec_off[@]} - 1 ))

    local reloc_parsed
    reloc_parsed="$(_bktr_parse_bucket0_relocations "$work_dir/reloc.bin")" || { rm -rf "$work_dir"; return 1; }

    : > "$out_path"

    local prev_virt="" prev_phys="" prev_is_patch=""
    local virt phys is_patch
    while read -r virt phys is_patch; do
        if [ -n "$prev_virt" ]; then
            local chunk_len=$(( virt - prev_virt ))
            if [ "$prev_is_patch" -eq 1 ]; then
                local chunk_start="$prev_phys" chunk_end=$(( prev_phys + chunk_len ))
                local cur="$chunk_start"
                while [ "$cur" -lt "$chunk_end" ]; do
                    local si=0
                    while [ $(( si + 1 )) -le "$num_subsec" ] && [ "${subsec_off[$((si + 1))]}" -le "$cur" ]; do
                        si=$(( si + 1 ))
                    done
                    local subsec_end="${subsec_off[$((si + 1))]}"
                    local read_end="$chunk_end"
                    [ "$subsec_end" -lt "$read_end" ] && read_end="$subsec_end"
                    local read_len=$(( read_end - cur ))

                    local phys_abs=$(( section_offset + cur ))
                    local ctr
                    ctr="$(nca_content_ctr "$section_ctr_raw" "$phys_abs")"
                    local ctr_val_hex
                    ctr_val_hex="$(printf '%08x' "${subsec_ctrval[$si]}")"
                    ctr="${ctr:0:8}${ctr_val_hex}${ctr:16:16}"

                    local chunk_file="$work_dir/chunk.bin"
                    nca_ctr_decrypt_section "$update_nca" "$update_key" "$ctr" "$phys_abs" "$read_len" "$chunk_file" || { rm -rf "$work_dir"; return 1; }
                    cat "$chunk_file" >> "$out_path"
                    rm -f "$chunk_file"

                    cur="$read_end"
                done
            else
                dd if="$base_romfs" bs=1M skip="$prev_phys" count="$chunk_len" iflag=skip_bytes,count_bytes 2>/dev/null >> "$out_path"
            fi
        fi
        prev_virt="$virt"; prev_phys="$phys"; prev_is_patch="$is_patch"
    done <<< "$reloc_parsed"

    rm -rf "$work_dir"
}
