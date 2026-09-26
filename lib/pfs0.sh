# Pure-bash PFS0 (PartitionFs) container packer, so switch-merge.sh can
# build the final NSP itself instead of shelling out to
# `hacpack --type nsp --ncadir <dir>`.
#
# PFS0 is the flat container format NSP files use: a small header, a
# fixed-size entry table (offset/size/name per file), a null-terminated
# string table, then every file's raw bytes concatenated with NO padding
# or alignment between them. No encryption, no hashing at this level (the
# per-section hash trees live inside the NCAs themselves, which this
# project still builds via hacpack/hactool - this only packs the flat
# outer container). Verified byte-for-byte against a real NSP's own PFS0
# header before use - see README's "The debugging story".
#
# Layout (switchbrew.org/wiki/NCA#PartitionFS, PFS0 variant):
#   Header (0x10 bytes):
#     0x0  u32  Magic ("PFS0")
#     0x4  u32  EntryCount
#     0x8  u32  StringTableSize
#     0xC  u32  Reserved (always 0)
#   PartitionEntry (0x18 bytes each, EntryCount of them, right after header):
#     0x0  u64  Offset      <- relative to the START OF FILE DATA, not
#                              the start of the PFS0 file itself
#     0x8  u64  Size
#     0x10 u32  StringTableOffset
#     0x14 u32  Reserved (always 0)
#   String table: EntryCount null-terminated filenames, concatenated,
#     padded to StringTableSize with zero bytes if needed.
#   File data: every file's raw bytes, in PartitionEntry order, with NO
#     gaps/padding between them.

# le_hex <decimal_value> <byte_width>
# Encodes a decimal integer as little-endian hex text (byte_width*2 hex
# chars). All multi-byte PFS0 fields are little-endian on-disk; printf's
# %x produces big-endian text, so this reverses byte order after formatting.
le_hex() {
    local value="$1" width="$2"
    local be_hex
    be_hex="$(printf "%0$((width * 2))x" "$value")"
    local out="" i
    for (( i = ${#be_hex} - 2; i >= 0; i -= 2 )); do
        out+="${be_hex:i:2}"
    done
    echo "$out"
}

# pfs0_pack <output_nsp_path> <file1> [file2] ...
# Packs the given files (each contributes its basename as its PFS0 entry
# name) into a PFS0 container at output_nsp_path.
pfs0_pack() {
    local out_path="$1"
    shift
    local files=("$@")
    local entry_count="${#files[@]}"

    # Compute each file's offset within the string table. The actual NUL
    # bytes are written directly to the output stream later (via printf
    # '%s\0'), not accumulated in a bash string variable first - bash
    # strings are C-strings under the hood and silently drop embedded NUL
    # bytes on expansion/printf, which corrupted the table (filenames ran
    # together with no separator) when this was tried the naive way.
    local str_offsets=() cur_str_off=0 f name
    for f in "${files[@]}"; do
        name="$(basename "$f")"
        str_offsets+=("$cur_str_off")
        cur_str_off=$(( cur_str_off + ${#name} + 1 ))
    done
    # Pad the string table so file data starts on a 0x20 (32-byte) aligned
    # offset from the start of the string table - confirmed necessary
    # (not just cosmetic) by testing: an unpadded string table produced a
    # file nstool misparsed, running filenames together past the buffer
    # nstool actually reads for the last entry. Matches hacPack's own
    # rounding rule (round the raw string table length up to the next
    # multiple of 0x20).
    local string_table_size=$(( (cur_str_off + 0x1f) & ~0x1f ))

    # Build the entry table, tracking each file's offset within the
    # concatenated file-data region (which starts right after the string
    # table - no padding/alignment, confirmed against a real NSP).
    local entry_table_hex="" data_off=0 i size
    for (( i = 0; i < entry_count; i++ )); do
        size="$(stat -c%s "${files[i]}")"
        entry_table_hex+="$(le_hex "$data_off" 8)"
        entry_table_hex+="$(le_hex "$size" 8)"
        entry_table_hex+="$(le_hex "${str_offsets[i]}" 4)"
        entry_table_hex+="00000000"
        data_off=$(( data_off + size ))
    done

    local header_hex="50465330"  # "PFS0" magic
    header_hex+="$(le_hex "$entry_count" 4)"
    header_hex+="$(le_hex "$string_table_size" 4)"
    header_hex+="00000000"

    local pad_bytes=$(( string_table_size - cur_str_off ))
    {
        printf '%s%s' "$header_hex" "$entry_table_hex" | xxd -r -p
        for f in "${files[@]}"; do
            printf '%s\0' "$(basename "$f")"
        done
        [ "$pad_bytes" -gt 0 ] && head -c "$pad_bytes" /dev/zero
        for f in "${files[@]}"; do
            cat "$f"
        done
    } > "$out_path"
}
