# Pure-bash AES-XTS decryption of the NCA header, so switch-merge.sh can
# read fields like RightsId directly instead of shelling out to
# `nstool -t nca -v`. Unlike lib/binfmt.sh (plain struct parsing, no
# crypto), this file implements real cryptography by hand - read the
# comments below and README's "The debugging story" before touching it.
#
# WHY THIS EXISTS: the first 0xC00 bytes of every NCA (the 0x400-byte
# header + a 0x200-byte header per content section) are encrypted with
# AES-XTS, using a FIXED key (`header_key` in prod.keys - the same for
# every NCA on every console, unlike the per-title keys used for the
# content partitions themselves). `openssl enc` cannot be used directly:
# its CLI subcommand does not support XTS mode at all (a permanent
# upstream limitation, not a config issue - confirmed by testing). So
# this hand-builds XTS from its actual definition (NIST SP 800-38E /
# IEEE P1619) using only `openssl enc -aes-128-ecb` as the raw block
# cipher primitive:
#   - the header_key is two concatenated 16-byte keys: key1 (encrypts the
#     actual data) and key2 (encrypts the per-sector tweak)
#   - Nintendo's tweak is NON-STANDARD: the sector number is encoded as a
#     16-byte BIG-ENDIAN value before being AES-ECB-encrypted with key2 to
#     produce the sector's initial tweak (standard XTS uses little-endian
#     here) - see https://gist.github.com/SciresM/fe8a631d13c069bd66e9c656ab5b3f7f
#   - within a sector, each subsequent 16-byte block's tweak is the
#     previous tweak doubled in GF(2^128) (multiply by the primitive
#     element alpha=2, with reduction polynomial x^128+x^7+x^2+x+1, i.e.
#     0x87, applied to the LSB when the shift overflows - this part IS
#     standard XTS, only the initial per-sector tweak derivation differs)
#   - decrypting a block: XOR with tweak, AES-ECB-decrypt, XOR with tweak
#     again (this "encrypt-then-XOR-twice" pattern is XTS's actual
#     definition, not a shortcut)
#
# VERIFIED: this exact construction was tested against this project's own
# real base-game Program NCA and produces the correct "NCA3" magic and a
# RightsId matching nstool's own decryption byte-for-byte. If a future NCA
# ever fails to decrypt correctly (garbage instead of "NCA3" magic), do NOT
# assume a new bug in Nintendo's format - re-verify header_key wasn't
# corrupted by the same prod.keys formatting bug documented in README's
# "Known issues" (stray trailing 00 byte on some key entries) before
# assuming this code is wrong.

# aes_ecb_hex <mode: -e|-d> <key_hex> <data_hex>
# Raw single/multi-block AES-ECB via openssl (the only primitive this file
# needs from it - XTS itself is built from this, not from openssl's XTS
# support, which doesn't exist in the enc CLI).
aes_ecb_hex() {
    local mode="$1" key_hex="$2" data_hex="$3"
    printf '%s' "$data_hex" | xxd -r -p | openssl enc "$mode" -aes-128-ecb -K "$key_hex" -nopad 2>/dev/null | xxd -p | tr -d '\n'
}

# xor_hex <hex_a> <hex_b> -- both must be equal length, even number of chars
xor_hex() {
    local a="$1" b="$2"
    local out="" i
    for (( i = 0; i < ${#a}; i += 2 )); do
        out+="$(printf '%02x' $(( 16#${a:i:2} ^ 16#${b:i:2} )))"
    done
    echo "$out"
}

# gf128_double <16-byte hex string>
# Multiplies a tweak by alpha=2 in GF(2^128), per the XTS spec: treats the
# 16 bytes as a little-endian bit string, shifts left by 1, and if a 1 bit
# was shifted out of the top, XORs the result's least-significant byte with
# the reduction polynomial 0x87. Verified against known-good test vectors
# generated from Python's `cryptography` library before use.
gf128_double() {
    local hex="$1"
    local -a bytes
    local i
    for (( i = 0; i < 32; i += 2 )); do
        bytes+=("$((16#${hex:i:2}))")
    done
    local carry=0 new_carry
    local -a result
    for (( i = 0; i < 16; i++ )); do
        new_carry=$(( (bytes[i] >> 7) & 1 ))
        result[i]=$(( ((bytes[i] << 1) | carry) & 0xFF ))
        carry=$new_carry
    done
    if [ "$carry" -eq 1 ]; then
        result[0]=$(( result[0] ^ 0x87 ))
    fi
    local out=""
    for (( i = 0; i < 16; i++ )); do
        out+="$(printf '%02x' "${result[i]}")"
    done
    echo "$out"
}

# xts_decrypt_sector <key1_hex_32chars> <key2_hex_32chars> <sector_index> <ciphertext_hex_512bytes>
# Decrypts one 0x200-byte AES-XTS sector. Echoes the plaintext hex.
xts_decrypt_sector() {
    local key1="$1" key2="$2" sector_index="$3" ct="$4"
    local sector_be
    sector_be="$(printf '%032x' "$sector_index")"
    local tweak
    tweak="$(aes_ecb_hex -e "$key2" "$sector_be")"
    local plaintext="" i block xored decrypted
    for (( i = 0; i < ${#ct}; i += 32 )); do
        block="${ct:i:32}"
        xored="$(xor_hex "$block" "$tweak")"
        decrypted="$(aes_ecb_hex -d "$key1" "$xored")"
        plaintext+="$(xor_hex "$decrypted" "$tweak")"
        tweak="$(gf128_double "$tweak")"
    done
    echo "$plaintext"
}

# xts_encrypt_sector <key1_hex_32chars> <key2_hex_32chars> <sector_index> <plaintext_hex_512bytes>
# Encrypts one 0x200-byte AES-XTS sector - the exact mirror of
# xts_decrypt_sector above (XTS's "encrypt-then-XOR-twice" pattern just
# swaps which side of the block cipher is -e vs -d; the tweak derivation
# itself is identical either direction, still built via aes_ecb_hex -e
# since the tweak is always ENCRYPTED with key2 regardless of which
# direction the actual 16-byte data blocks go). Used by nca_build.sh to
# write a Meta/Program NCA's own header - this project's own
# xts_decrypt_sector already reads every NCA header this project has
# ever needed to read, so encrypting one back is exactly this function
# with -e/-d swapped on the data step. Echoes the ciphertext hex.
xts_encrypt_sector() {
    local key1="$1" key2="$2" sector_index="$3" pt="$4"
    local sector_be
    sector_be="$(printf '%032x' "$sector_index")"
    local tweak
    tweak="$(aes_ecb_hex -e "$key2" "$sector_be")"
    local ciphertext="" i block xored encrypted
    for (( i = 0; i < ${#pt}; i += 32 )); do
        block="${pt:i:32}"
        xored="$(xor_hex "$block" "$tweak")"
        encrypted="$(aes_ecb_hex -e "$key1" "$xored")"
        ciphertext+="$(xor_hex "$encrypted" "$tweak")"
        tweak="$(gf128_double "$tweak")"
    done
    echo "$ciphertext"
}

# nca_encrypt_header <header_hex_0xC00bytes> <keys_file>
# Encrypts a complete, freshly-assembled 0xC00-byte NCA header (6 XTS
# sectors of 0x200 bytes each) with the same fixed header_key every real
# NCA uses - the exact mirror of nca_header_field's per-sector decrypt,
# just run over the whole header at once since a fresh build needs every
# sector encrypted, not one field read from one sector. Echoes the full
# 0xC00-byte ciphertext hex.
nca_encrypt_header() {
    local header_hex="$1" keys_file="$2"
    local header_key
    header_key="$(grep -m1 -oP '^header_key\s*=\s*\K[0-9a-fA-F]+' "$keys_file" | tr -d '\n' | cut -c1-64)"
    [ "${#header_key}" -eq 64 ] || { echo "nca_encrypt_header: header_key not found or wrong length in $keys_file" >&2; return 1; }
    local key1="${header_key:0:32}" key2="${header_key:32:32}"

    local out="" sector sector_hex
    for (( sector = 0; sector < 6; sector++ )); do
        sector_hex="${header_hex:$((sector * 1024)):1024}"
        out+="$(xts_encrypt_sector "$key1" "$key2" "$sector" "$sector_hex")"
    done
    echo "$out"
}

# nca_header_field <path to .nca file> <keys file> <byte_offset> <byte_size>
# Reads and decrypts just enough of the NCA header to return one field's
# raw hex bytes. Only decrypts the single 0x200-byte sector containing the
# requested offset, not the whole 0xC00-byte header, since callers so far
# only need one field (RightsId) per NCA.
nca_header_field() {
    local nca_path="$1" keys_file="$2" field_off="$3" field_size="$4"
    local header_key
    header_key="$(grep -m1 -oP '^header_key\s*=\s*\K[0-9a-fA-F]+' "$keys_file" | tr -d '\n' | cut -c1-64)"
    [ "${#header_key}" -eq 64 ] || { echo "header_key not found or wrong length in $keys_file" >&2; return 1; }
    local key1="${header_key:0:32}" key2="${header_key:32:32}"

    local sector_index=$(( field_off / 0x200 ))
    local sector_start=$(( sector_index * 0x200 ))
    local sector_hex
    sector_hex="$(dd if="$nca_path" bs=1 skip="$sector_start" count=512 2>/dev/null | xxd -p | tr -d '\n')"
    [ "${#sector_hex}" -eq 1024 ] || { echo "Could not read NCA header sector at offset $sector_start from $nca_path" >&2; return 1; }

    local plaintext
    plaintext="$(xts_decrypt_sector "$key1" "$key2" "$sector_index" "$sector_hex")"

    local field_off_in_sector=$(( field_off - sector_start ))
    echo "${plaintext:$(( field_off_in_sector * 2 )):$(( field_size * 2 ))}"
}

# nca_rights_id <path to .nca file> <keys file>
# Echoes the NCA's RightsId as a hex string, or empty if it's all-zero
# (standard crypto, no titlekey - RightsId absent). Offset/size per
# switchbrew.org/wiki/NCA: RightsId is 0x10 bytes at header offset 0x230.
nca_rights_id() {
    local nca_path="$1" keys_file="$2"
    local rights_id
    rights_id="$(nca_header_field "$nca_path" "$keys_file" 560 16)" || return 1
    if [ "$rights_id" = "00000000000000000000000000000000" ]; then
        echo ""
    else
        echo "$rights_id"
    fi
}
