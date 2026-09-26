# Pure-bash binary parsers for the two Switch file formats switch-merge.sh
# needs to read directly: cnmt (PackagedContentMeta) and NACP (control.nacp).
# No external tool dependency for this - just xxd (coreutils) for the
# hex dump and bash's own string/arithmetic builtins for everything else.
#
# Byte layouts per switchbrew.org (CNMT, NCM_services, NACP pages), verified
# by parsing this project's own real extracted .cnmt/.nacp files and
# cross-checking every field against nstool's verbose dump - see README's
# "The debugging story" for that verification. Source this file, don't run
# it directly.

# hex_of_file <path> -- whole file as one lowercase hex string, no dependency
# on struct/binary parsing beyond xxd itself. Cheap: cnmt files are a few
# hundred bytes, NACP is a fixed 0x4000 (16384) bytes.
hex_of_file() {
    xxd -p "$1" | tr -d '\n'
}

# hex_field_le <hex_blob> <byte_offset> <byte_size>
# Reads byte_size bytes at byte_offset from a hex_of_file blob and returns
# them as a big-endian-ordered hex string (i.e. the natural way to read a
# little-endian integer field as hex - reverses byte order, not nibble
# order within each byte).
hex_field_le() {
    local hex="$1" off="$2" size="$3"
    local chunk="${hex:$((off * 2)):$((size * 2))}"
    local result="" i
    for (( i = size * 2 - 2; i >= 0; i -= 2 )); do
        result+="${chunk:i:2}"
    done
    echo "$result"
}

# hex_field_raw <hex_blob> <byte_offset> <byte_size>
# Reads byte_size bytes at byte_offset and returns them as-is (no byte
# reversal) - for fields that are opaque byte strings, not integers:
# content IDs, hashes, ASCII/UTF-8 text fields.
hex_field_raw() {
    local hex="$1" off="$2" size="$3"
    echo "${hex:$((off * 2)):$((size * 2))}"
}

# hex_to_text <hex_string> -- decodes hex bytes to text, truncating at the
# first NUL byte (fixed-size null-padded string fields, as NACP uses).
hex_to_text() {
    echo "$1" | xxd -r -p | tr -d '\0'
}

# int_of_hex <hex_string> -- decimal value of a hex string via bash's own
# arithmetic (no external tool). Empty input -> empty output, not an error,
# since some fields are legitimately absent depending on cnmt type.
int_of_hex() {
    [ -n "$1" ] && echo "$((16#$1))"
}

# cnmt_content_meta_type_name <numeric_value_decimal>
# Maps the ContentMetaType byte (PackagedContentMetaHeader offset 0xC) to
# its name. Full enum per switchbrew's NCM_services page.
cnmt_content_meta_type_name() {
    case "$1" in
        0) echo "Invalid" ;;
        1) echo "SystemProgram" ;;
        2) echo "SystemData" ;;
        3) echo "SystemUpdate" ;;
        4) echo "BootImagePackage" ;;
        5) echo "BootImagePackageSafe" ;;
        128) echo "Application" ;;
        129) echo "Patch" ;;
        130) echo "AddOnContent" ;;
        131) echo "Delta" ;;
        132) echo "DataPatch" ;;
        *) echo "Unknown($1)" ;;
    esac
}

# cnmt_content_type_name <numeric_value_decimal>
# Maps a PackagedContentInfo entry's ContentType byte to its name. Full
# enum per switchbrew's NCM_services page.
cnmt_content_type_name() {
    case "$1" in
        0) echo "Meta" ;;
        1) echo "Program" ;;
        2) echo "Data" ;;
        3) echo "Control" ;;
        4) echo "HtmlDocument" ;;
        5) echo "LegalInformation" ;;
        6) echo "DeltaFragment" ;;
        *) echo "Unknown($1)" ;;
    esac
}

# parse_cnmt <path to .cnmt file>
# Sets these globals (bash has no return-struct, so this is the simplest
# interface that avoids a subshell - callers must `local` these names if
# they need to nest calls):
#   CNMT_TITLE_ID           hex string, this content's own TitleId
#   CNMT_TYPE_NUM            decimal ContentMetaType byte
#   CNMT_TYPE_NAME           e.g. "Application" / "Patch" / "AddOnContent"
#   CNMT_VERSION             decimal
#   CNMT_APPLICATION_ID       hex string, only set for Patch/AddOnContent
#                            (base title ID; absent/empty for Application,
#                            where CNMT_TITLE_ID IS the base title ID)
#   CNMT_PROGRAM_ID / CNMT_CONTROL_ID / CNMT_LEGALINFORMATION_ID / CNMT_DATA_ID
#                            hex string content ID of the first ContentInfo
#                            entry of that type, or empty if none present
#
# Layout reference (switchbrew.org/wiki/CNMT):
#   PackagedContentMetaHeader (0x20 bytes):
#     0x00 u64  Id (this content's own TitleId)
#     0x08 u32  Version
#     0x0C u8   ContentMetaType
#     0x0E u16  ExtendedHeaderSize
#     0x10 u16  ContentCount
#   ApplicationMetaExtendedHeader (Application only, at 0x20):
#     0x00 u64  PatchId
#   PatchMetaExtendedHeader (Patch/AddOnContent, at 0x20):
#     0x00 u64  ApplicationId
#   PackagedContentInfo (0x38 bytes each, starting at 0x20+ExtendedHeaderSize):
#     0x20 u128 ContentId (16 bytes, raw/opaque)
#     0x30 u40  Size (5 bytes, raw little-endian)
#     0x36 u8   ContentType
parse_cnmt() {
    local path="$1"
    local hex
    hex="$(hex_of_file "$path")"

    CNMT_TITLE_ID="$(hex_field_le "$hex" 0 8)"
    CNMT_VERSION="$(int_of_hex "$(hex_field_le "$hex" 8 4)")"
    CNMT_TYPE_NUM="$(int_of_hex "$(hex_field_le "$hex" 12 1)")"
    CNMT_TYPE_NAME="$(cnmt_content_meta_type_name "$CNMT_TYPE_NUM")"
    local ext_hdr_size content_count
    ext_hdr_size="$(int_of_hex "$(hex_field_le "$hex" 14 2)")"
    content_count="$(int_of_hex "$(hex_field_le "$hex" 16 2)")"

    CNMT_APPLICATION_ID=""
    if [ "$CNMT_TYPE_NUM" -eq 129 ] || [ "$CNMT_TYPE_NUM" -eq 130 ]; then
        CNMT_APPLICATION_ID="$(hex_field_le "$hex" 32 8)"
    fi

    CNMT_PROGRAM_ID=""
    CNMT_CONTROL_ID=""
    CNMT_LEGALINFORMATION_ID=""
    CNMT_DATA_ID=""

    local content_off=$((0x20 + ext_hdr_size))
    local i entry_off content_id ctype_num ctype_name
    for (( i = 0; i < content_count; i++ )); do
        entry_off=$((content_off + i * 0x38))
        content_id="$(hex_field_raw "$hex" $((entry_off + 0x20)) 16)"
        ctype_num="$(int_of_hex "$(hex_field_le "$hex" $((entry_off + 0x36)) 1)")"
        ctype_name="$(cnmt_content_type_name "$ctype_num")"
        case "$ctype_name" in
            Program) [ -n "$CNMT_PROGRAM_ID" ] || CNMT_PROGRAM_ID="$content_id" ;;
            Control) [ -n "$CNMT_CONTROL_ID" ] || CNMT_CONTROL_ID="$content_id" ;;
            LegalInformation) [ -n "$CNMT_LEGALINFORMATION_ID" ] || CNMT_LEGALINFORMATION_ID="$content_id" ;;
            Data) [ -n "$CNMT_DATA_ID" ] || CNMT_DATA_ID="$content_id" ;;
        esac
    done
}

# parse_nacp <path to control.nacp file>
# Sets NACP_NAME and NACP_DISPLAY_VERSION from the AmericanEnglish (index 0)
# language entry and the DisplayVersion field.
#
# Layout reference (switchbrew.org/wiki/NACP):
#   Per-language title entry: 0x300 bytes, 16(+) entries starting at 0x0.
#     Index 0 = AmericanEnglish.
#     0x000 (0x200 bytes) Name, NUL-padded
#     0x200 (0x100 bytes) Publisher, NUL-padded
#   0x3060 (0x10 bytes) DisplayVersion, NUL-padded
parse_nacp() {
    local path="$1"
    local hex
    hex="$(hex_of_file "$path")"

    NACP_NAME="$(hex_to_text "$(hex_field_raw "$hex" 0 512)")"
    NACP_DISPLAY_VERSION="$(hex_to_text "$(hex_field_raw "$hex" 12384 16)")"
}
