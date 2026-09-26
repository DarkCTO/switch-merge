# Pure-bash PFS0 (PartitionFs) container packer AND unpacker, so
# switch-merge.sh can build the final NSP itself instead of shelling out to
# `hacpack --type nsp --ncadir <dir>`, and split an NSP/decrypted NCA
# section into its component files instead of shelling out to `nstool -x` /
# `nstool -t nca -x`. The unpack half (pfs0_extract / pfs0_extract_all /
# _pfs0_read_entries) sources lib/binfmt.sh's hex_to_text - source that
# file first.
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

# _pfs0_data_off <pfs0_file>
# Echoes the absolute byte offset (within pfs0_file) where the file-data
# region starts - i.e. header size (fixed 0x10) + entry table + string
# table. A separate, tiny function (not a side-effect global set by
# _pfs0_read_entries) specifically so callers can get this value in their
# OWN shell: `while read ... done < <(_pfs0_read_entries ...)` runs the
# process substitution in a subshell, and any variable _pfs0_read_entries
# sets is invisible back in the loop body once the pipe is involved - a
# real bug hit and fixed here, confirmed by testing (PFS0_DATA_OFF read as
# a stale/unset 0 in the loop body, silently extracting every entry from
# the wrong offset - same *shape* of bug as README's Bug #5, though the
# root mechanism this time is subshell variable scoping, not NUL handling).
_pfs0_data_off() {
    local pfs0_file="$1"
    local hdr_hex
    hdr_hex="$(dd if="$pfs0_file" bs=1 count=16 2>/dev/null | xxd -p | tr -d '\n')"
    [ "${hdr_hex:0:8}" = "50465330" ] || { echo "_pfs0_data_off: not a PFS0 container (bad magic) in $pfs0_file" >&2; return 1; }
    local entry_count string_table_size
    entry_count="$((16#$(_pfs0_reverse_hex "${hdr_hex:8:8}")))"
    string_table_size="$((16#$(_pfs0_reverse_hex "${hdr_hex:16:8}")))"
    echo $(( 16 + entry_count * 0x18 + string_table_size ))
}

# _pfs0_read_entries <pfs0_file>
# Shared header/entry-table/string-table parser for pfs0_extract and
# pfs0_extract_all below - reads the same layout pfs0_pack writes, in
# reverse. Prints one "<name> <data_off> <size>" line per entry (data_off
# relative to the start of the file-data region - add _pfs0_data_off's
# result, computed separately by the caller, to get an absolute offset).
_pfs0_read_entries() {
    local pfs0_file="$1"
    local hdr_hex
    hdr_hex="$(dd if="$pfs0_file" bs=1 count=16 2>/dev/null | xxd -p | tr -d '\n')"
    [ "${hdr_hex:0:8}" = "50465330" ] || { echo "_pfs0_read_entries: not a PFS0 container (bad magic) in $pfs0_file" >&2; return 1; }

    local entry_count string_table_size
    entry_count="$((16#$(_pfs0_reverse_hex "${hdr_hex:8:8}")))"
    string_table_size="$((16#$(_pfs0_reverse_hex "${hdr_hex:16:8}")))"

    local entry_table_off=16
    local entry_table_size=$(( entry_count * 0x18 ))
    local string_table_off=$(( entry_table_off + entry_table_size ))

    # Read the whole entry table + string table as one hex blob and slice
    # names out of the hex text (NUL byte = "00" in hex) instead of piping
    # raw bytes through `cut -d $'\0'` - that looked correct in isolated
    # tests but produced corrupted names read straight off a real NSP (each
    # name after the first ran together with the next entry's raw file
    # bytes, the same *symptom* as README's Bug #5, though the root cause
    # here is a `cut`/pipe interaction with embedded NULs from `dd`, not
    # bash string handling - confirmed by reproducing it against a
    # materialized file, ruling out a live-pipe-buffering explanation).
    # Small (a few hundred bytes for every real file this project handles),
    # so reading it all upfront is cheap.
    local tables_hex
    tables_hex="$(dd if="$pfs0_file" bs=1 skip="$entry_table_off" count="$entry_table_size" 2>/dev/null | xxd -p | tr -d '\n')$(dd if="$pfs0_file" bs=1 skip="$string_table_off" count="$string_table_size" 2>/dev/null | xxd -p | tr -d '\n')"
    local entry_table_hex_len=$(( entry_table_size * 2 ))

    local i entry_off off size str_off name_hex nul_pos name
    for (( i = 0; i < entry_count; i++ )); do
        entry_off=$(( i * 0x18 * 2 ))
        off="$((16#$(_pfs0_reverse_hex "${tables_hex:entry_off:16}")))"
        size="$((16#$(_pfs0_reverse_hex "${tables_hex:$((entry_off + 16)):16}")))"
        str_off="$((16#$(_pfs0_reverse_hex "${tables_hex:$((entry_off + 32)):8}")))"

        name_hex="${tables_hex:$((entry_table_hex_len + str_off * 2))}"
        nul_pos=$(( $(_pfs0_index_of_00 "$name_hex") ))
        name="$(hex_to_text "${name_hex:0:nul_pos}")"
        echo "$name $off $size"
    done
}

# _pfs0_index_of_00 <hex_string> -- index (in hex CHARS, always even) of the
# first "00" byte pair that starts at an even hex-character position, i.e.
# the first NUL byte boundary-aligned to whole bytes. Echoes the full
# remaining length if no NUL is found (shouldn't happen for a well-formed
# PFS0 string table, since every name is NUL-terminated by construction -
# pfs0_pack itself writes it that way).
_pfs0_index_of_00() {
    local hex="$1"
    local i
    for (( i = 0; i < ${#hex}; i += 2 )); do
        [ "${hex:i:2}" = "00" ] && { echo "$i"; return 0; }
    done
    echo "${#hex}"
}

# pfs0_extract <pfs0_file> <entry_name> <out_path>
# Extracts one named entry's raw bytes from an already-unpacked-to-disk PFS0
# blob (e.g. a decrypted NCA content section - see lib/nca_content.sh, or a
# whole NSP file directly, which IS a PFS0 blob with no encryption at this
# outer layer) to out_path. Returns nonzero (no output written) if
# entry_name isn't present.
pfs0_extract() {
    local pfs0_file="$1" entry_name="$2" out_path="$3"
    local data_off
    data_off="$(_pfs0_data_off "$pfs0_file")" || return 1
    local name off size
    while read -r name off size; do
        if [ "$name" = "$entry_name" ]; then
            # bs=1M with the *_bytes iflags (not bs=1/skip/count in raw
            # byte units) - real file entries here run into the hundreds
            # of MB, and dd's per-byte-block-size read loop is unusably
            # slow at that size (confirmed: a 370MB extraction that should
            # take a couple seconds ran for minutes with bs=1 before being
            # killed). Only the tiny fixed-size header/table reads
            # elsewhere in this file keep bs=1, where the size difference
            # doesn't matter.
            dd if="$pfs0_file" of="$out_path" bs=1M skip=$(( data_off + off )) count="$size" iflag=skip_bytes,count_bytes 2>/dev/null
            return 0
        fi
    done < <(_pfs0_read_entries "$pfs0_file")
    echo "pfs0_extract: entry '$entry_name' not found in $pfs0_file" >&2
    return 1
}

# pfs0_extract_all <pfs0_file> <out_dir>
# Extracts every entry in a PFS0 blob to out_dir (created if needed), each
# under its own PFS0-recorded filename - the direct pure-bash replacement
# for `nstool -x <out_dir> <nsp>` (NSP splitting; no decryption needed at
# this level, PFS0 itself carries no encryption) or, given an already
# section-decrypted PartitionFs blob, for `nstool -t nca -x` (see
# lib/nca_content.sh's nca_hierarchical_sha256_data_layer for how to get
# from a decrypted NCA section to the PFS0 blob this function wants).
pfs0_extract_all() {
    local pfs0_file="$1" out_dir="$2"
    mkdir -p "$out_dir"
    local data_off
    data_off="$(_pfs0_data_off "$pfs0_file")" || return 1
    local name off size
    while read -r name off size; do
        # bs=1M + *_bytes iflags, not bs=1 - see pfs0_extract's comment on
        # why (real entries here run into the hundreds of MB).
        dd if="$pfs0_file" of="$out_dir/$name" bs=1M skip=$(( data_off + off )) count="$size" iflag=skip_bytes,count_bytes 2>/dev/null
    done < <(_pfs0_read_entries "$pfs0_file")
}

# _pfs0_reverse_hex <hex_string> -- reverses byte order (little-endian ->
# big-endian text) of an even-length hex string. Same idea as
# lib/binfmt.sh's hex_field_le / lib/nca_content.sh's
# _nca_content_reverse_hex, duplicated locally so this file has no
# cross-file sourcing-order dependency.
_pfs0_reverse_hex() {
    local hex="$1"
    local out="" i
    for (( i = ${#hex} - 2; i >= 0; i -= 2 )); do
        out+="${hex:i:2}"
    done
    echo "$out"
}
