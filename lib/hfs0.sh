# Pure-bash HFS0 (HashedFs) container reader, for reading XCI (gamecard
# dump) input. HFS0 is PFS0's hashed sibling - same flat "header + entry
# table + string table + concatenated file data" shape lib/pfs0.sh already
# reads/writes, but with a bigger per-entry struct that adds a partial-file
# SHA256 (for on-cart integrity checking, not needed for extraction - never
# verified here, same as how this project leaves other correctness-only
# hash checks to nstool/hactool by design). Read-only: this project never
# builds an XCI, only reads one as an alternative input format to NSP, so
# there's no hfs0_pack.
#
# Layout (switchbrew.org/wiki/XCI, "HFS0" partition format; verified
# byte-for-byte against real dumped .xci files' root/secure partitions by
# cross-checking every offset/size against `hactool -t xci -i`'s own dump):
#   Header (0x10 bytes):
#     0x0  u32  Magic ("HFS0")
#     0x4  u32  EntryCount
#     0x8  u32  StringTableSize
#     0xC  u32  Reserved (0)
#   HfsEntry (0x40 bytes each, EntryCount of them, right after header):
#     0x0  u64  Offset            <- relative to the START OF FILE DATA,
#                                     same convention as PFS0
#     0x8  u64  Size
#     0x10 u32  StringTableOffset
#     0x14 u32  HashedDataSize    <- how many leading bytes of this file
#                                     the trailing Hash field covers -
#                                     not read/checked here
#     0x18 u32  Reserved (0)
#     0x1C u32  Reserved (0)
#     0x20 u8[0x20] Hash          <- SHA256 of the first HashedDataSize
#                                     bytes - not read/checked here
#   String table: EntryCount null-terminated filenames, concatenated,
#     padded to StringTableSize with zero bytes if needed.
#   File data: every file's raw bytes, in entry order, with NO gaps/
#     padding between them (same as PFS0).
#
# Depends on lib/binfmt.sh's hex_to_text and lib/pfs0.sh's
# _pfs0_reverse_hex/_pfs0_index_of_00 - source both first.

# _hfs0_data_off <hfs0_file> <byte_offset_of_header_within_file>
# Same idea as lib/pfs0.sh's _pfs0_data_off, but HFS0's entry size is 0x40,
# not 0x18, and the header doesn't have to sit at the start of the file (an
# XCI's root/secure/etc. HFS0 headers each start at some offset read from
# an outer header) - echoes the ABSOLUTE byte offset (within hfs0_file)
# where this partition's file-data region starts.
_hfs0_data_off() {
    local hfs0_file="$1" base_off="$2"
    local hdr_hex
    hdr_hex="$(dd if="$hfs0_file" bs=1 skip="$base_off" count=16 2>/dev/null | xxd -p | tr -d '\n')"
    [ "${hdr_hex:0:8}" = "48465330" ] || { echo "_hfs0_data_off: not an HFS0 container (bad magic) at offset $base_off in $hfs0_file" >&2; return 1; }
    local entry_count string_table_size
    entry_count="$((16#$(_pfs0_reverse_hex "${hdr_hex:8:8}")))"
    string_table_size="$((16#$(_pfs0_reverse_hex "${hdr_hex:16:8}")))"
    echo $(( base_off + 16 + entry_count * 0x40 + string_table_size ))
}

# _hfs0_read_entries <hfs0_file> <byte_offset_of_header_within_file>
# Same shape as lib/pfs0.sh's _pfs0_read_entries: prints one
# "<name> <off> <size>" line per entry, off relative to the start of the
# file-data region (add _hfs0_data_off's result to get an absolute offset
# within hfs0_file).
_hfs0_read_entries() {
    local hfs0_file="$1" base_off="$2"
    local hdr_hex
    hdr_hex="$(dd if="$hfs0_file" bs=1 skip="$base_off" count=16 2>/dev/null | xxd -p | tr -d '\n')"
    [ "${hdr_hex:0:8}" = "48465330" ] || { echo "_hfs0_read_entries: not an HFS0 container (bad magic) at offset $base_off in $hfs0_file" >&2; return 1; }

    local entry_count string_table_size
    entry_count="$((16#$(_pfs0_reverse_hex "${hdr_hex:8:8}")))"
    string_table_size="$((16#$(_pfs0_reverse_hex "${hdr_hex:16:8}")))"

    local entry_table_off=$(( base_off + 16 ))
    local entry_table_size=$(( entry_count * 0x40 ))
    local string_table_off=$(( entry_table_off + entry_table_size ))

    # Same rationale as _pfs0_read_entries: read the whole entry table +
    # string table as one hex blob rather than piping raw bytes through
    # anything NUL-sensitive.
    local tables_hex
    tables_hex="$(dd if="$hfs0_file" bs=1 skip="$entry_table_off" count="$entry_table_size" 2>/dev/null | xxd -p | tr -d '\n')$(dd if="$hfs0_file" bs=1 skip="$string_table_off" count="$string_table_size" 2>/dev/null | xxd -p | tr -d '\n')"
    local entry_table_hex_len=$(( entry_table_size * 2 ))

    local i entry_off off size str_off name_hex nul_pos name
    for (( i = 0; i < entry_count; i++ )); do
        entry_off=$(( i * 0x40 * 2 ))
        off="$((16#$(_pfs0_reverse_hex "${tables_hex:entry_off:16}")))"
        size="$((16#$(_pfs0_reverse_hex "${tables_hex:$((entry_off + 16)):16}")))"
        str_off="$((16#$(_pfs0_reverse_hex "${tables_hex:$((entry_off + 32)):8}")))"

        name_hex="${tables_hex:$((entry_table_hex_len + str_off * 2))}"
        nul_pos=$(( $(_pfs0_index_of_00 "$name_hex") ))
        name="$(hex_to_text "${name_hex:0:nul_pos}")"
        echo "$name $off $size"
    done
}

# hfs0_extract_all <hfs0_file> <byte_offset_of_header_within_file> <out_dir>
# Extracts every entry in one HFS0 partition to out_dir (created if
# needed) - the HFS0 counterpart of lib/pfs0.sh's pfs0_extract_all.
hfs0_extract_all() {
    local hfs0_file="$1" base_off="$2" out_dir="$3"
    mkdir -p "$out_dir"
    local data_off
    data_off="$(_hfs0_data_off "$hfs0_file" "$base_off")" || return 1
    local name off size
    while read -r name off size; do
        dd if="$hfs0_file" of="$out_dir/$name" bs=1M skip=$(( data_off + off )) count="$size" iflag=skip_bytes,count_bytes 2>/dev/null
    done < <(_hfs0_read_entries "$hfs0_file" "$base_off")
}
