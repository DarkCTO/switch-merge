/* nca-header-decrypt / nca-rights-id - ports lib/nca_header.sh's AES-XTS
 * NCA header decryption.
 *
 * The first 0xC00 bytes of every NCA (a 0x400-byte main header + one
 * 0x200-byte FS header per of 4 content sections) are AES-XTS encrypted
 * with a FIXED key (header_key in prod.keys, same on every console).
 * Nintendo's tweak is NON-STANDARD: the sector number is encoded
 * BIG-ENDIAN before being AES-ECB-encrypted with key2 to produce the
 * initial per-sector tweak (standard XTS uses little-endian here) - see
 * lib/nca_header.sh's own header comment for the full derivation and the
 * gist this was cross-checked against. Within a sector, each subsequent
 * 16-byte block's tweak is the previous tweak doubled in GF(2^128)
 * (multiply by alpha=2, reduction polynomial x^128+x^7+x^2+x+1 i.e. 0x87
 * applied to the LSB on overflow) - this part IS standard XTS.
 *
 * Decrypting a block: XOR with tweak, AES-ECB-decrypt, XOR with tweak
 * again - XTS's actual definition, not a shortcut.
 */
#include "common.h"
#include "crypto.h"
#include "nca_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#define SECTOR_SIZE 0x200

/* gf128_double_be <tweak[16]> - doubles a 16-byte tweak in GF(2^128),
 * treating the bytes as a LITTLE-ENDIAN bit string per the XTS spec
 * (byte 0 holds the least-significant bits) - exact port of
 * lib/nca_header.sh's gf128_double, verified there against known-good
 * test vectors from Python's cryptography library before being trusted. */
static void gf128_double(unsigned char tweak[16]) {
    unsigned char carry = 0;
    for (int i = 0; i < 16; i++) {
        unsigned char new_carry = (tweak[i] >> 7) & 1;
        tweak[i] = (unsigned char)((tweak[i] << 1) | carry);
        carry = new_carry;
    }
    if (carry) {
        tweak[0] ^= 0x87;
    }
}

static void xor16(const unsigned char a[16], const unsigned char b[16], unsigned char out[16]) {
    for (int i = 0; i < 16; i++) out[i] = a[i] ^ b[i];
}

/* xts_crypt_sector <encrypt> <key1[16]> <key2[16]> <sector_index> <in[0x200]> <out[0x200]>
 * Encrypts/decrypts one 0x200-byte AES-XTS sector - exact port of
 * lib/nca_header.sh's xts_decrypt_sector/xts_encrypt_sector (same
 * function either direction here, just swapping which side of the block
 * cipher is -e/-d, same as the bash comment on xts_encrypt_sector notes). */
static int xts_crypt_sector(int encrypt, const unsigned char key1[16], const unsigned char key2[16],
                             uint64_t sector_index, const unsigned char *in, unsigned char *out) {
    /* Sector number as a 16-byte BIG-ENDIAN value (Nintendo's non-
     * standard tweak derivation - see this file's header comment). */
    unsigned char sector_be[16] = {0};
    for (int i = 0; i < 8; i++) sector_be[15 - i] = (unsigned char)((sector_index >> (i * 8)) & 0xFF);

    unsigned char tweak[16];
    if (aes128_ecb_block(1, key2, sector_be, tweak) != 0) return 1;

    for (int block = 0; block < SECTOR_SIZE / 16; block++) {
        const unsigned char *block_in = in + block * 16;
        unsigned char *block_out = out + block * 16;
        unsigned char xored[16], crypted[16];
        xor16(block_in, tweak, xored);
        if (aes128_ecb_block(encrypt, key1, xored, crypted) != 0) return 1;
        xor16(crypted, tweak, block_out);
        gf128_double(tweak);
    }
    return 0;
}

int nca_decrypt_header(const char *nca_path, const char *keys_path, unsigned char *out) {
    char *header_key_hex = keys_file_lookup(keys_path, "header_key", 64);
    if (!header_key_hex) {
        fprintf(stderr, "header_key not found or wrong length in %s\n", keys_path);
        return 1;
    }
    size_t key_len;
    unsigned char *header_key = hex_decode(header_key_hex, &key_len);
    free(header_key_hex);
    if (!header_key || key_len != 32) {
        fprintf(stderr, "header_key did not decode to 32 bytes\n");
        free(header_key);
        return 1;
    }
    unsigned char key1[16], key2[16];
    memcpy(key1, header_key, 16);
    memcpy(key2, header_key + 16, 16);
    free(header_key);

    FILE *f = fopen(nca_path, "rb");
    if (!f) {
        fprintf(stderr, "could not open %s\n", nca_path);
        return 1;
    }
    unsigned char ciphertext[NCA_HEADER_SIZE];
    if (fread(ciphertext, 1, NCA_HEADER_SIZE, f) != NCA_HEADER_SIZE) {
        fprintf(stderr, "could not read %d-byte header from %s\n", NCA_HEADER_SIZE, nca_path);
        fclose(f);
        return 1;
    }
    fclose(f);

    for (int sector = 0; sector < NCA_HEADER_SIZE / SECTOR_SIZE; sector++) {
        if (xts_crypt_sector(0, key1, key2, (uint64_t)sector,
                              ciphertext + sector * SECTOR_SIZE, out + sector * SECTOR_SIZE) != 0) {
            fprintf(stderr, "AES-XTS decryption failed on sector %d of %s\n", sector, nca_path);
            return 1;
        }
    }
    return 0;
}

int cmd_nca_header_decrypt(int argc, char **argv) {
    const char *nca_path = NULL, *keys_path = NULL, *out_path = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) { out_path = argv[++i]; }
        else if (!nca_path) { nca_path = argv[i]; }
    }
    if (!nca_path || !keys_path || !out_path) {
        fprintf(stderr, "usage: smtool nca-header-decrypt <nca_path> --keys <keys_file> -o <out_file>\n");
        return 1;
    }

    unsigned char header[NCA_HEADER_SIZE];
    if (nca_decrypt_header(nca_path, keys_path, header) != 0) return 1;

    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fprintf(stderr, "could not open %s for writing\n", out_path);
        return 1;
    }
    size_t written = fwrite(header, 1, NCA_HEADER_SIZE, out);
    fclose(out);
    if (written != NCA_HEADER_SIZE) {
        fprintf(stderr, "short write to %s\n", out_path);
        return 1;
    }
    return 0;
}

int cmd_nca_rights_id(int argc, char **argv) {
    const char *nca_path = NULL, *keys_path = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (!nca_path) { nca_path = argv[i]; }
    }
    if (!nca_path || !keys_path) {
        fprintf(stderr, "usage: smtool nca-rights-id <nca_path> --keys <keys_file>\n");
        return 1;
    }

    unsigned char header[NCA_HEADER_SIZE];
    if (nca_decrypt_header(nca_path, keys_path, header) != 0) return 1;

    /* RightsId: 0x10 bytes at header offset 0x230 (switchbrew.org/wiki/NCA),
     * same offset lib/nca_header.sh's nca_rights_id reads. All-zero means
     * standard crypto (no titlekey) - echo empty, matching the bash
     * function's own "" output for that case, not the raw zero bytes. */
    static const unsigned char zero16[16] = {0};
    if (memcmp(header + 0x230, zero16, 16) == 0) {
        printf("\n");
    } else {
        char *hex = hex_encode(header + 0x230, 16);
        printf("%s\n", hex);
        free(hex);
    }
    return 0;
}
