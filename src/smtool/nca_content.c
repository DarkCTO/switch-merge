/* nca-content-key-standard / nca-content-key-titlekey / nca-section-info
 * - ports the key-derivation half of lib/nca_content.sh (nca_crypto_type,
 * nca_kaek_index, nca_content_key_standard, nca_content_key_titlekey,
 * nca_section_info, nca_content_ctr). Streaming AES-CTR content
 * decryption itself (nca_ctr_decrypt_section) is Phase 5, not this file -
 * key derivation is small, fixed-size, and independently useful to
 * several later phases (BKTR reconstruction needs the key but streams
 * decryption differently), so it's split out on its own here.
 *
 * All layout/derivation details below are exact ports of
 * lib/nca_content.sh's own header comments - see that file for the full
 * verification history (byte-for-byte matches against nstool's own
 * "AES-CTR Key"/decrypted-key-area dumps on real Dicefolk/DLC NCAs).
 */
#include "common.h"
#include "crypto.h"
#include "nca_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* nca_crypto_type - the effective "master key generation" index, used
 * for both standard key-area unwrap and titlekey unwrap. Two one-byte
 * fields in the main header:
 *   0x206 (0x1) CryptoType  ("KeyGenerationOld")
 *   0x220 (0x1) CryptoType2 ("KeyGeneration")
 * Effective generation = max(CryptoType, CryptoType2), decremented by
 * one UNLESS already 0 (0 and 1 both mean "master key 0" - Nintendo's
 * own off-by-one encoding, matches hactool nca.c exactly). */
static int nca_crypto_type(const unsigned char *header) {
    int t1 = header[0x206];
    int t2 = header[0x220];
    int gen = t1 > t2 ? t1 : t2;
    if (gen != 0) gen--;
    return gen;
}

/* nca_kaek_index - 0 (Application), 1 (Ocean), or 2 (System). One-byte
 * field at 0x207 (KeyAreaEncryptionKeyIndex). */
static int nca_kaek_index(const unsigned char *header) {
    return header[0x207];
}

static const char *kaek_name(int idx) {
    switch (idx) {
        case 0: return "application";
        case 1: return "ocean";
        case 2: return "system";
        default: return NULL;
    }
}

/* nca_content_key_standard - derives the AES-CTR content key for a
 * STANDARD-crypto NCA. The header's EncryptedKeyArea holds four 16-byte
 * slots at 0x300 (one per KeyAreaEncryptionKeyIndex family); slot 2 (the
 * System-family slot, file offset 0x320) is ALWAYS the AES-CTR content
 * key regardless of which KAEK family was used to decrypt the area
 * (confirmed against hactool 1.4.0 nca.c: decrypted_keys[2] is what gets
 * handed to AES_MODE_CTR). Unwrapped with a single AES-128-ECB decrypt
 * keyed by key_area_key_<family>_<generation> from prod.keys. */
static int nca_content_key_standard(const unsigned char *header, const char *keys_path, unsigned char out_key[16]) {
    int gen = nca_crypto_type(header);
    int kaek_idx = nca_kaek_index(header);
    const char *name = kaek_name(kaek_idx);
    if (!name) {
        fprintf(stderr, "nca-content-key-standard: unexpected KeyAreaEncryptionKeyIndex %d\n", kaek_idx);
        return 1;
    }

    char key_name[64];
    snprintf(key_name, sizeof(key_name), "key_area_key_%s_%02x", name, gen);
    char *kaek_hex = keys_file_lookup(keys_path, key_name, 32);
    if (!kaek_hex) {
        fprintf(stderr, "nca-content-key-standard: %s not found or wrong length in %s\n", key_name, keys_path);
        return 1;
    }
    size_t kaek_len;
    unsigned char *kaek = hex_decode(kaek_hex, &kaek_len);
    free(kaek_hex);
    if (!kaek || kaek_len != 16) {
        fprintf(stderr, "nca-content-key-standard: %s did not decode to 16 bytes\n", key_name);
        free(kaek);
        return 1;
    }

    const unsigned char *encrypted_slot2 = header + 0x300 + 0x20; /* slot 2 = +0x20 into the 4x16-byte key area */
    int rc = aes128_ecb_block(0, kaek, encrypted_slot2, out_key);
    free(kaek);
    if (rc != 0) {
        fprintf(stderr, "nca-content-key-standard: ECB unwrap failed\n");
        return 1;
    }
    return 0;
}

/* nca_content_key_titlekey - derives the AES-CTR content key for a
 * TITLEKEY-crypto NCA, given the raw ticket-encrypted titlekey (parse_tik's
 * TIK_TITLEKEY / tik-info's TIK_TITLEKEY - NOT nstool's fully-decrypted
 * dump) and the NCA's own crypto-type generation. Single AES-128-ECB
 * unwrap with titlekek_<generation> from prod.keys (confirmed against
 * hactool 1.4.0 nca.c:459). */
static int nca_content_key_titlekey(const unsigned char titlekey[16], int gen, const char *keys_path, unsigned char out_key[16]) {
    char key_name[64];
    snprintf(key_name, sizeof(key_name), "titlekek_%02x", gen);
    char *titlekek_hex = keys_file_lookup(keys_path, key_name, 32);
    if (!titlekek_hex) {
        fprintf(stderr, "nca-content-key-titlekey: %s not found or wrong length in %s\n", key_name, keys_path);
        return 1;
    }
    size_t titlekek_len;
    unsigned char *titlekek = hex_decode(titlekek_hex, &titlekek_len);
    free(titlekek_hex);
    if (!titlekek || titlekek_len != 16) {
        fprintf(stderr, "nca-content-key-titlekey: %s did not decode to 16 bytes\n", key_name);
        free(titlekek);
        return 1;
    }

    int rc = aes128_ecb_block(0, titlekek, titlekey, out_key);
    free(titlekek);
    if (rc != 0) {
        fprintf(stderr, "nca-content-key-titlekey: ECB unwrap failed\n");
        return 1;
    }
    return 0;
}

/* nca_content_ctr - builds the 16-byte initial AES-CTR counter for a
 * section's absolute byte offset 0. Construction (confirmed directly
 * against hactool 1.4.0 nca.c's nca_init_section_ctx(), not documented
 * on switchbrew's wiki in this detail):
 *   bytes 0-7:  the section's own SectionCTR field (FS header +0x140, 8
 *               raw bytes as stored), REVERSED byte-for-byte - an opaque
 *               per-section "secure value", not a byte-offset.
 *   bytes 8-15: the section's absolute byte offset within the NCA,
 *               right-shifted by 4 (counted in 16-byte AES-block units),
 *               encoded BIG-ENDIAN. */
static void nca_content_ctr(const unsigned char section_ctr_raw[8], uint64_t byte_offset, unsigned char out_ctr[16]) {
    for (int i = 0; i < 8; i++) out_ctr[i] = section_ctr_raw[7 - i];
    uint64_t block_offset = byte_offset / 0x10;
    for (int i = 0; i < 8; i++) out_ctr[8 + i] = (unsigned char)((block_offset >> ((7 - i) * 8)) & 0xFF);
}

/* nca_section_info - reads a section's presence/offset/size/crypt-type/
 * initial-CTR from the main header's section entry table (0x240 +
 * section_num*0x10, MediaStartOffset/MediaEndOffset in 0x200-byte media
 * units) and the corresponding FS header (0x400 + section_num*0x200,
 * EncryptionType at +0x2, SectionCTR at +0x140). */
typedef struct {
    int present;
    uint64_t offset;
    uint64_t size;
    int crypt_type;
    unsigned char ctr[16];
} nca_section_info_t;

static void nca_section_info(const unsigned char *header, int section_num, nca_section_info_t *out) {
    const unsigned char *entry = header + 0x240 + section_num * 0x10;
    uint32_t start_units = (uint32_t)entry[0] | ((uint32_t)entry[1] << 8) | ((uint32_t)entry[2] << 16) | ((uint32_t)entry[3] << 24);
    uint32_t end_units = (uint32_t)entry[4] | ((uint32_t)entry[5] << 8) | ((uint32_t)entry[6] << 16) | ((uint32_t)entry[7] << 24);

    if (start_units == 0) {
        memset(out, 0, sizeof(*out));
        return;
    }
    out->present = 1;
    out->offset = (uint64_t)start_units * 0x200;
    out->size = (uint64_t)(end_units - start_units) * 0x200;

    const unsigned char *fs_header = header + 0x400 + section_num * 0x200;
    out->crypt_type = fs_header[0x4];
    nca_content_ctr(fs_header + 0x140, out->offset, out->ctr);
}

/* parse_hex_key_arg <hex_string> <out[16]> - decodes a 32-hex-char
 * command-line argument into 16 raw bytes, failing loudly on a malformed
 * value rather than silently truncating/garbling it. */
static int parse_hex16_arg(const char *hex, unsigned char out[16]) {
    size_t len;
    unsigned char *decoded = hex_decode(hex, &len);
    if (!decoded || len != 16) {
        free(decoded);
        return 1;
    }
    memcpy(out, decoded, 16);
    free(decoded);
    return 0;
}

int cmd_nca_crypto_type(int argc, char **argv) {
    const char *nca_path = NULL, *keys_path = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (!nca_path) { nca_path = argv[i]; }
    }
    if (!nca_path || !keys_path) {
        fprintf(stderr, "usage: smtool nca-crypto-type <nca_path> --keys <keys_file>\n");
        return 1;
    }

    unsigned char header[NCA_HEADER_SIZE];
    if (nca_decrypt_header(nca_path, keys_path, header) != 0) return 1;

    printf("%d\n", nca_crypto_type(header));
    return 0;
}

int cmd_nca_content_key_standard(int argc, char **argv) {
    const char *nca_path = NULL, *keys_path = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (!nca_path) { nca_path = argv[i]; }
    }
    if (!nca_path || !keys_path) {
        fprintf(stderr, "usage: smtool nca-content-key-standard <nca_path> --keys <keys_file>\n");
        return 1;
    }

    unsigned char header[NCA_HEADER_SIZE];
    if (nca_decrypt_header(nca_path, keys_path, header) != 0) return 1;

    unsigned char key[16];
    if (nca_content_key_standard(header, keys_path, key) != 0) return 1;

    char *hex = hex_encode(key, 16);
    printf("%s\n", hex);
    free(hex);
    return 0;
}

int cmd_nca_content_key_titlekey(int argc, char **argv) {
    const char *titlekey_hex = NULL, *gen_str = NULL, *keys_path = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (!titlekey_hex) { titlekey_hex = argv[i]; }
        else if (!gen_str) { gen_str = argv[i]; }
    }
    if (!titlekey_hex || !gen_str || !keys_path) {
        fprintf(stderr, "usage: smtool nca-content-key-titlekey <titlekey_hex> <key_generation> --keys <keys_file>\n");
        return 1;
    }

    unsigned char titlekey[16];
    if (parse_hex16_arg(titlekey_hex, titlekey) != 0) {
        fprintf(stderr, "nca-content-key-titlekey: titlekey_hex must be 32 hex chars\n");
        return 1;
    }
    char *end;
    long gen = strtol(gen_str, &end, 10);
    if (*end != '\0' || gen < 0) {
        fprintf(stderr, "nca-content-key-titlekey: invalid key_generation '%s'\n", gen_str);
        return 1;
    }

    unsigned char key[16];
    if (nca_content_key_titlekey(titlekey, (int)gen, keys_path, key) != 0) return 1;

    char *hex = hex_encode(key, 16);
    printf("%s\n", hex);
    free(hex);
    return 0;
}

int cmd_nca_section_info(int argc, char **argv) {
    const char *nca_path = NULL, *keys_path = NULL, *section_str = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (strcmp(argv[i], "--section") == 0 && i + 1 < argc) { section_str = argv[++i]; }
        else if (!nca_path) { nca_path = argv[i]; }
    }
    if (!nca_path || !keys_path || !section_str) {
        fprintf(stderr, "usage: smtool nca-section-info <nca_path> --keys <keys_file> --section <0-3>\n");
        return 1;
    }
    char *end;
    long section_num = strtol(section_str, &end, 10);
    if (*end != '\0' || section_num < 0 || section_num > 3) {
        fprintf(stderr, "nca-section-info: invalid --section '%s' (must be 0-3)\n", section_str);
        return 1;
    }

    unsigned char header[NCA_HEADER_SIZE];
    if (nca_decrypt_header(nca_path, keys_path, header) != 0) return 1;

    nca_section_info_t info;
    nca_section_info(header, (int)section_num, &info);

    print_kv_u64("NCA_SECTION_PRESENT", info.present);
    print_kv_u64("NCA_SECTION_OFFSET", info.offset);
    print_kv_u64("NCA_SECTION_SIZE", info.size);
    print_kv_u64("NCA_SECTION_CRYPT_TYPE", info.crypt_type);
    if (info.present) {
        print_kv_hex("NCA_SECTION_CTR", info.ctr, 16);
    } else {
        print_kv_empty("NCA_SECTION_CTR");
    }
    return 0;
}
