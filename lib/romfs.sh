# Pure-bash RomFs file-table parser, so switch-merge.sh can read a named
# file (control.nacp) out of a decrypted NCA RomFs data layer instead of
# shelling out to `nstool -x`. Read-only, flat lookup by name - this does
# NOT walk directories (every real Control NCA's RomFs seen so far - the
# only content type this project needs RomFs for - has every file directly
# in the root directory, no subdirectories) and does NOT verify the
# HierarchicalIntegrity hash tree that precedes the RomFs data in a real
# NCA section (see lib/nca_content.sh's nca_hierarchical_sha256_data_layer
# for the analogous "skip past the hash layers" step for the OTHER
# container format, PartitionFs - RomFs's own hash-layer skip is handled
# the same way by nca_content.sh's nca_section_info/nca_ctr_decrypt_section
# callers, not by this file).
#
# WHY THIS EXISTS: RomFs is the last container format this project's
# pipeline still needed nstool for (Control NCA -> control.nacp, for the
# output filename's display name/version). Unlike PFS0/PartitionFs (a flat
# offset+size+name table, already handled by lib/pfs0.sh), RomFs has a
# directory tree - overkill to reimplement in full for what this project
# actually needs (one always-flat, always-known-shape lookup), so only the
# FileTable walk is implemented, not the DirTable at all.
#
# VERIFIED: parsed a real Control NCA's decrypted RomFs data layer (11
# files, all flat in the root directory - icons per language + control.nacp)
# and found control.nacp's recorded data offset/size to produce bytes
# byte-for-byte identical (via cmp) to nstool -t nca -x's own extraction of
# the same NCA.
#
# Layout reference (switchbrew.org/wiki/RomFS):
#   RomFsHeader (0x50 bytes, HeaderSize field at +0x0 confirms exactly
#   0x50 on every real file seen, though this code trusts the field, not
#   a hardcoded 0x50, for the header size itself):
#     0x00 (0x8) HeaderSize
#     0x08 (0x8) DirHashTableOffset   (not read - directories not walked)
#     0x10 (0x8) DirHashTableSize
#     0x18 (0x8) DirTableOffset      (not read - directories not walked)
#     0x20 (0x8) DirTableSize
#     0x28 (0x8) FileHashTableOffset (not read - names looked up by linear
#                                     scan of FileTable instead of via the
#                                     hash table, fine for ~11 real entries)
#     0x30 (0x8) FileHashTableSize
#     0x38 (0x8) FileTableOffset
#     0x40 (0x8) FileTableSize
#     0x48 (0x8) DataOffset          (add a FileEntry's own DataOffset to
#                                     this to get the byte offset, relative
#                                     to the start of the RomFs blob, of
#                                     that file's actual content)
#   RomFsFileEntry (variable size, back-to-back in FileTableOffset..+Size,
#   NOT necessarily in filesystem/alphabetical order - walk via
#   NextSiblingOffset if you need traversal order, this code just walks
#   the raw table start-to-end since every entry needs visiting anyway for
#   a linear name search):
#     +0x00 (0x4) ParentDirOffset      (not read - directories not walked)
#     +0x04 (0x4) NextSiblingOffset    (not read - see above)
#     +0x08 (0x8) DataOffset           (relative to RomFsHeader's own DataOffset)
#     +0x10 (0x8) DataSize
#     +0x18 (0x4) NameHash             (not read - see FileHashTableOffset above)
#     +0x1C (0x4) NameLength           (bytes, NOT NUL-terminated on disk)
#     +0x20 (NameLength bytes, then padded to a multiple of 4) Name
#   0xFFFFFFFF in a u32 field (ParentDirOffset/NextSiblingOffset) is a
#   sentinel ("no entry"/"end of list"), not a real offset - irrelevant
#   here since neither field is read, but worth knowing if this file is
#   ever extended to walk NextSiblingOffset.

# _romfs_reverse_hex <hex_string> -- byte-order reversal (little-endian ->
# big-endian text), same idea as every other lib/*.sh file's local copy of
# this (lib/binfmt.sh's hex_field_le, lib/nca_content.sh's
# _nca_content_reverse_hex, lib/pfs0.sh's _pfs0_reverse_hex) - duplicated
# again here so this file has no cross-file sourcing-order dependency.
_romfs_reverse_hex() {
    local hex="$1"
    local out="" i
    for (( i = ${#hex} - 2; i >= 0; i -= 2 )); do
        out+="${hex:i:2}"
    done
    echo "$out"
}

# romfs_extract <romfs_file> <entry_name> <out_path>
# Extracts one named file's raw bytes from an already-decrypted-to-disk
# RomFs data-layer blob (see lib/nca_content.sh's
# nca_hierarchical_sha256_data_layer for how to slice this out of a
# decrypted NCA RomFs section - the offset/size fields work the same way
# for HierarchicalIntegrity as they do for HierarchicalSha256, just with
# more hash layers before the data layer) to out_path. Only searches the
# root directory's files (see file header comment) - returns nonzero if
# entry_name isn't found among them.
romfs_extract() {
    local romfs_file="$1" entry_name="$2" out_path="$3"

    local hdr_hex
    hdr_hex="$(dd if="$romfs_file" bs=1 count=$((0x50)) 2>/dev/null | xxd -p | tr -d '\n')"
    local file_table_off file_table_size data_base_off
    file_table_off="$((16#$(_romfs_reverse_hex "${hdr_hex:112:16}")))"
    file_table_size="$((16#$(_romfs_reverse_hex "${hdr_hex:128:16}")))"
    data_base_off="$((16#$(_romfs_reverse_hex "${hdr_hex:144:16}")))"

    local table_hex
    table_hex="$(dd if="$romfs_file" bs=1 skip="$file_table_off" count="$file_table_size" 2>/dev/null | xxd -p | tr -d '\n')"

    local pos=0 entry_off data_off data_size name_len name_hex name entry_size
    while [ "$pos" -lt "$file_table_size" ]; do
        entry_off=$(( pos * 2 ))
        data_off="$((16#$(_romfs_reverse_hex "${table_hex:$((entry_off + 16)):16}")))"
        data_size="$((16#$(_romfs_reverse_hex "${table_hex:$((entry_off + 32)):16}")))"
        name_len="$((16#$(_romfs_reverse_hex "${table_hex:$((entry_off + 56)):8}")))"
        name_hex="${table_hex:$((entry_off + 64)):$((name_len * 2))}"
        name="$(hex_to_text "$name_hex")"

        if [ "$name" = "$entry_name" ]; then
            dd if="$romfs_file" of="$out_path" bs=1M skip=$(( data_base_off + data_off )) count="$data_size" iflag=skip_bytes,count_bytes 2>/dev/null
            return 0
        fi

        entry_size=$(( 0x20 + ((name_len + 3) & ~3) ))
        pos=$(( pos + entry_size ))
    done
    echo "romfs_extract: entry '$entry_name' not found in $romfs_file" >&2
    return 1
}

# romfs_extract_all <romfs_file> <out_dir>
# Extracts the FULL directory tree (unlike romfs_extract, which only does
# a flat root-directory lookup by name - see that function's own comment
# for why the flat version was enough for this project's other use case,
# Control NCA -> control.nacp). Needed for BKTR-reconstructed romfs
# content (see lib/bktr.sh), which hacpack's --romfsdir wants as a real
# directory tree on disk, not a raw blob.
#
# Layout reference (switchbrew.org/wiki/RomFS's RomFsDirectoryEntry,
# confirmed against a real BKTR-reconstructed romfs blob's own directory
# table, byte-for-byte matching the directory tree nstool independently
# extracted the same content into - Data/Managed/{Metadata,Resources},
# Data/Resources, Data/StreamingAssets/aa/{AddressablesLink,Switch}):
#   RomFsDirectoryEntry (variable size, same padding-to-4-bytes rule as
#   RomFsFileEntry):
#     +0x00 (0x4) ParentDirOffset
#     +0x04 (0x4) NextSiblingOffset  (0xFFFFFFFF = no more siblings)
#     +0x08 (0x4) FirstChildOffset   (0xFFFFFFFF = no subdirectories)
#     +0x0C (0x4) FirstFileOffset    (0xFFFFFFFF = no files)
#     +0x10 (0x4) NextDirHashOffset  (not read - hash table not used)
#     +0x14 (0x4) NameLength
#     +0x18 (NameLength bytes, padded to a multiple of 4) Name
# RomFsFileEntry's own NextSiblingOffset (already read by romfs_extract's
# per-entry walk, just not used there since that function doesn't need
# more than one file per lookup) is what lets multiple files hang off one
# directory's FirstFileOffset here.
romfs_extract_all() {
    local romfs_file="$1" out_dir="$2"

    local hdr_hex
    hdr_hex="$(dd if="$romfs_file" bs=1 count=$((0x50)) 2>/dev/null | xxd -p | tr -d '\n')"
    local dir_table_off dir_table_size file_table_off file_table_size data_base_off
    dir_table_off="$((16#$(_romfs_reverse_hex "${hdr_hex:48:16}")))"
    dir_table_size="$((16#$(_romfs_reverse_hex "${hdr_hex:64:16}")))"
    file_table_off="$((16#$(_romfs_reverse_hex "${hdr_hex:112:16}")))"
    file_table_size="$((16#$(_romfs_reverse_hex "${hdr_hex:128:16}")))"
    data_base_off="$((16#$(_romfs_reverse_hex "${hdr_hex:144:16}")))"

    local dir_hex file_hex
    dir_hex="$(dd if="$romfs_file" bs=1M skip="$dir_table_off" count="$dir_table_size" iflag=skip_bytes,count_bytes 2>/dev/null | xxd -p | tr -d '\n')"
    file_hex="$(dd if="$romfs_file" bs=1M skip="$file_table_off" count="$file_table_size" iflag=skip_bytes,count_bytes 2>/dev/null | xxd -p | tr -d '\n')"

    _romfs_extract_dir "$romfs_file" "$dir_hex" "$file_hex" 0 "$out_dir" "$data_base_off"
}

# _romfs_extract_dir <romfs_file> <dir_table_hex> <file_table_hex> <dir_entry_offset> <out_dir> <data_base_off>
# Recursive helper for romfs_extract_all: writes every file directly under
# the directory entry at dir_entry_offset to out_dir, then recurses into
# every subdirectory (each becoming its own out_dir/<name>/).
_romfs_extract_dir() {
    local romfs_file="$1" dir_hex="$2" file_hex="$3" dir_off="$4" out_dir="$5" data_base_off="$6"
    mkdir -p "$out_dir"

    local entry_off=$(( dir_off * 2 ))
    local first_child first_file
    first_child="$((16#$(_romfs_reverse_hex "${dir_hex:$((entry_off + 16)):8}")))"
    first_file="$((16#$(_romfs_reverse_hex "${dir_hex:$((entry_off + 24)):8}")))"

    local file_off name_len name_hex name data_off data_size next_sib
    while [ "$first_file" != "4294967295" ]; do
        file_off=$(( first_file * 2 ))
        data_off="$((16#$(_romfs_reverse_hex "${file_hex:$((file_off + 16)):16}")))"
        data_size="$((16#$(_romfs_reverse_hex "${file_hex:$((file_off + 32)):16}")))"
        name_len="$((16#$(_romfs_reverse_hex "${file_hex:$((file_off + 56)):8}")))"
        name_hex="${file_hex:$((file_off + 64)):$((name_len * 2))}"
        name="$(hex_to_text "$name_hex")"
        dd if="$romfs_file" of="$out_dir/$name" bs=1M skip=$(( data_base_off + data_off )) count="$data_size" iflag=skip_bytes,count_bytes 2>/dev/null

        next_sib="$((16#$(_romfs_reverse_hex "${file_hex:$((file_off + 8)):8}")))"
        first_file="$next_sib"
    done

    local child_off name_len2 name_hex2 name2 next_sib_dir
    child_off="$first_child"
    while [ "$child_off" != "4294967295" ]; do
        entry_off=$(( child_off * 2 ))
        name_len2="$((16#$(_romfs_reverse_hex "${dir_hex:$((entry_off + 40)):8}")))"
        name_hex2="${dir_hex:$((entry_off + 48)):$((name_len2 * 2))}"
        name2="$(hex_to_text "$name_hex2")"
        _romfs_extract_dir "$romfs_file" "$dir_hex" "$file_hex" "$child_off" "$out_dir/$name2" "$data_base_off"

        next_sib_dir="$((16#$(_romfs_reverse_hex "${dir_hex:$((entry_off + 8)):8}")))"
        child_off="$next_sib_dir"
    done
}
