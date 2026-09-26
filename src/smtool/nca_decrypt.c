/* decrypt-section / nca-hierarchical-sha256-layer /
 * nca-hierarchical-integrity-layer - ports the rest of
 * lib/nca_content.sh: streaming AES-128-CTR content-section decryption
 * (nca_ctr_decrypt_section, nca_ctr_advance) and the two data-layer
 * offset resolvers (nca_hierarchical_sha256_data_layer,
 * nca_hierarchical_integrity_data_layer).
 *
 * THIS is the phase expected to deliver the real, large speedup this
 * whole C port exists for: every earlier phase's bash equivalent (dd
 * for the header/table reads) was already reasonably fast for small
 * fixed-size fields, but nca_ctr_decrypt_section streams a WHOLE content
 * section (hundreds of MB to low GB for a real Program NCA's romfs/
 * exefs) through a single `openssl enc -aes-128-ctr` subprocess call per
 * section - fine in isolation, but this project's merge pipeline calls
 * it repeatedly (once per NCA section actually read), and the process-
 * spawn + pipe overhead is what Phase 1's own profiling found dominates
 * a real merge's wall-clock time, not the small header/table parses
 * earlier phases sped up. This file does the same AES-CTR work
 * in-process via libcrypto's EVP streaming API instead.
 */
#include "common.h"
#include "nca_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include <openssl/evp.h>

static uint32_t le_u32_at(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t le_u64_at(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

static int parse_offset_arg(const char *s, uint64_t *out) {
    char *end;
    unsigned long long v = strtoull(s, &end, 0);
    if (*end != '\0') return 1;
    *out = v;
    return 0;
}

/* cmd_nca_ctr_decrypt_section <nca_path> --keys <keys> --key-hex <hex32>
 *   --ctr <hex32> --offset <N> --size <N> -o <out_path>
 * Decrypts size bytes starting at offset in nca_path using AES-128-CTR
 * with the given key and initial-counter-at-that-offset, writing
 * plaintext to out_path - streamed with a fixed-size buffer via
 * libcrypto's EVP streaming API (EVP_DecryptUpdate can be called
 * repeatedly on successive chunks of the same logical CTR stream,
 * exactly the property this needs), never loading the whole section
 * into memory at once. --keys is unused here (accepted for interface
 * symmetry with other nca-* subcommands) since the caller (switch-
 * merge.sh's op_ wrapper) already derived key_hex/ctr_hex via
 * nca-content-key-standard/-titlekey and nca-section-info - this
 * subcommand does no key derivation of its own, matching
 * nca_ctr_decrypt_section's own bash signature exactly (it also just
 * takes an already-derived key_hex/ctr_hex, not raw prod.keys). */
int cmd_nca_ctr_decrypt_section(int argc, char **argv) {
    const char *nca_path = NULL, *key_hex = NULL, *ctr_hex = NULL, *out_path = NULL;
    uint64_t byte_offset = 0, byte_size = 0;
    int have_offset = 0, have_size = 0;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--key-hex") == 0 && i + 1 < argc) { key_hex = argv[++i]; }
        else if (strcmp(argv[i], "--ctr") == 0 && i + 1 < argc) { ctr_hex = argv[++i]; }
        else if (strcmp(argv[i], "--offset") == 0 && i + 1 < argc) { have_offset = (parse_offset_arg(argv[++i], &byte_offset) == 0); }
        else if (strcmp(argv[i], "--size") == 0 && i + 1 < argc) { have_size = (parse_offset_arg(argv[++i], &byte_size) == 0); }
        else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) { out_path = argv[++i]; }
        else if (!nca_path) { nca_path = argv[i]; }
    }
    if (!nca_path || !key_hex || !ctr_hex || !have_offset || !have_size || !out_path) {
        fprintf(stderr, "usage: smtool decrypt-section <nca_path> --key-hex <hex32> --ctr <hex32> --offset <N> --size <N> -o <out_path>\n");
        return 1;
    }

    size_t key_len, ctr_len;
    unsigned char *key = hex_decode(key_hex, &key_len);
    unsigned char *ctr = hex_decode(ctr_hex, &ctr_len);
    if (!key || key_len != 16 || !ctr || ctr_len != 16) {
        fprintf(stderr, "decrypt-section: --key-hex/--ctr must each be 32 hex chars\n");
        free(key);
        free(ctr);
        return 1;
    }

    FILE *in = fopen(nca_path, "rb");
    if (!in) {
        fprintf(stderr, "could not open %s\n", nca_path);
        free(key);
        free(ctr);
        return 1;
    }
    if (fseeko(in, (off_t)byte_offset, SEEK_SET) != 0) {
        fprintf(stderr, "could not seek to offset %llu in %s\n", (unsigned long long)byte_offset, nca_path);
        fclose(in);
        free(key);
        free(ctr);
        return 1;
    }

    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fprintf(stderr, "could not open %s for writing\n", out_path);
        fclose(in);
        free(key);
        free(ctr);
        return 1;
    }

    EVP_CIPHER_CTX *cipher = EVP_CIPHER_CTX_new();
    int rc = 1;
    if (cipher && EVP_DecryptInit_ex(cipher, EVP_aes_128_ctr(), NULL, key, ctr) == 1) {
        unsigned char inbuf[1 << 20];
        unsigned char outbuf[(1 << 20) + 16];
        uint64_t remaining = byte_size;
        rc = 0;
        while (remaining > 0) {
            size_t chunk = remaining < sizeof(inbuf) ? (size_t)remaining : sizeof(inbuf);
            size_t got = fread(inbuf, 1, chunk, in);
            if (got == 0) {
                fprintf(stderr, "decrypt-section: short read from %s\n", nca_path);
                rc = 1;
                break;
            }
            int outlen = 0;
            if (EVP_DecryptUpdate(cipher, outbuf, &outlen, inbuf, (int)got) != 1) {
                fprintf(stderr, "decrypt-section: AES-CTR decrypt failed\n");
                rc = 1;
                break;
            }
            if (outlen > 0 && fwrite(outbuf, 1, (size_t)outlen, out) != (size_t)outlen) {
                fprintf(stderr, "decrypt-section: short write to %s\n", out_path);
                rc = 1;
                break;
            }
            remaining -= got;
        }
        if (rc == 0) {
            int outlen = 0;
            if (EVP_DecryptFinal_ex(cipher, outbuf, &outlen) != 1) {
                fprintf(stderr, "decrypt-section: AES-CTR finalize failed\n");
                rc = 1;
            } else if (outlen > 0 && fwrite(outbuf, 1, (size_t)outlen, out) != (size_t)outlen) {
                fprintf(stderr, "decrypt-section: short write to %s\n", out_path);
                rc = 1;
            }
        }
    } else {
        fprintf(stderr, "decrypt-section: could not initialize AES-CTR cipher\n");
    }
    if (cipher) EVP_CIPHER_CTX_free(cipher);

    fclose(in);
    fclose(out);
    free(key);
    free(ctr);
    return rc;
}

/* cmd_nca_hierarchical_sha256_layer <decrypted_header_file> --section <0-3>
 * Echoes "<data_layer_offset> <data_layer_size>" (decimal bytes,
 * relative to the start of the DECRYPTED section) for a
 * HierarchicalSha256-hashed section (Meta/PartitionFs-shaped NCAs).
 *
 * Layout (switchbrew.org/wiki/NCA_Format's HierarchicalSha256 hash-info
 * struct), relative to fs_hdr_off = 0x400 + section_num*0x200:
 *   +0x08 (0x20) MasterHash (not read)
 *   +0x28 (0x4)  HashBlockSize
 *   +0x2C (0x4)  LayerCount (2 on every real file seen so far)
 *   +0x30 (0x10 each, LayerCount of them) LayerRegion { u64 Offset; u64 Size }
 * The LAST layer region (index LayerCount-1) is the Data Layer. */
int cmd_nca_hierarchical_sha256_layer(int argc, char **argv) {
    const char *header_path = NULL, *section_str = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--section") == 0 && i + 1 < argc) { section_str = argv[++i]; }
        else if (!header_path) { header_path = argv[i]; }
    }
    if (!header_path || !section_str) {
        fprintf(stderr, "usage: smtool nca-hierarchical-sha256-layer <decrypted_header_file> --section <0-3>\n");
        return 1;
    }
    char *end;
    long section_num = strtol(section_str, &end, 10);
    if (*end != '\0' || section_num < 0 || section_num > 3) {
        fprintf(stderr, "nca-hierarchical-sha256-layer: invalid --section '%s'\n", section_str);
        return 1;
    }

    unsigned char header[NCA_HEADER_SIZE];
    FILE *f = fopen(header_path, "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", header_path); return 1; }
    if (fread(header, 1, sizeof(header), f) != sizeof(header)) {
        fprintf(stderr, "could not read %zu-byte header from %s\n", sizeof(header), header_path);
        fclose(f);
        return 1;
    }
    fclose(f);

    size_t fs_hdr_off = 0x400 + (size_t)section_num * 0x200;
    uint32_t layer_count = le_u32_at(header + fs_hdr_off + 0x2C);
    if (layer_count < 1) {
        fprintf(stderr, "nca-hierarchical-sha256-layer: LayerCount is 0\n");
        return 1;
    }
    size_t last_layer_off = fs_hdr_off + 0x30 + (size_t)(layer_count - 1) * 0x10;
    uint64_t off = le_u64_at(header + last_layer_off);
    uint64_t size = le_u64_at(header + last_layer_off + 8);
    printf("%llu %llu\n", (unsigned long long)off, (unsigned long long)size);
    return 0;
}

/* cmd_nca_hierarchical_integrity_layer <decrypted_header_file> --section <0-3>
 * Same "<data_layer_offset> <data_layer_size>" output, for a
 * HierarchicalIntegrity (IVFC)-hashed section (Control/RomFs-shaped
 * NCAs) - a DIFFERENT struct shape, not a variant of the SHA256 one.
 *
 * Layout (switchbrew.org/wiki/NCA_Format's "IVFC" hash-info struct),
 * relative to the same fs_hdr_off base:
 *   +0x08 (0x4) Magic ("IVFC")   +0x0C (0x4) Version
 *   +0x10 (0x4) MasterHashSize (not read)
 *   +0x14 (0x4) NumLevels (7 on every real file seen so far - 5 hash
 *               levels + 1 data level + 1 trailing all-zero/unused level)
 *   +0x18 (0x18 each, NumLevels of them) LevelInformation
 *     { u64 LogicalOffset; u64 HashDataSize; u32 BlockSizeLog2; u32 Reserved }
 * The DATA level is index NumLevels-2 (NOT NumLevels-1 - there IS a
 * trailing unused, all-zero entry here, unlike the SHA256 case above). */
int cmd_nca_hierarchical_integrity_layer(int argc, char **argv) {
    const char *header_path = NULL, *section_str = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--section") == 0 && i + 1 < argc) { section_str = argv[++i]; }
        else if (!header_path) { header_path = argv[i]; }
    }
    if (!header_path || !section_str) {
        fprintf(stderr, "usage: smtool nca-hierarchical-integrity-layer <decrypted_header_file> --section <0-3>\n");
        return 1;
    }
    char *end;
    long section_num = strtol(section_str, &end, 10);
    if (*end != '\0' || section_num < 0 || section_num > 3) {
        fprintf(stderr, "nca-hierarchical-integrity-layer: invalid --section '%s'\n", section_str);
        return 1;
    }

    unsigned char header[NCA_HEADER_SIZE];
    FILE *f = fopen(header_path, "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", header_path); return 1; }
    if (fread(header, 1, sizeof(header), f) != sizeof(header)) {
        fprintf(stderr, "could not read %zu-byte header from %s\n", sizeof(header), header_path);
        fclose(f);
        return 1;
    }
    fclose(f);

    size_t fs_hdr_off = 0x400 + (size_t)section_num * 0x200;
    if (memcmp(header + fs_hdr_off + 0x8, "IVFC", 4) != 0) {
        fprintf(stderr, "nca-hierarchical-integrity-layer: not an IVFC section (bad magic)\n");
        return 1;
    }
    uint32_t num_levels = le_u32_at(header + fs_hdr_off + 0x14);
    if (num_levels < 2) {
        fprintf(stderr, "nca-hierarchical-integrity-layer: NumLevels %u too small to have a data layer\n", num_levels);
        return 1;
    }
    size_t data_level_off = fs_hdr_off + 0x18 + (size_t)(num_levels - 2) * 0x18;
    uint64_t off = le_u64_at(header + data_level_off);
    uint64_t size = le_u64_at(header + data_level_off + 8);
    printf("%llu %llu\n", (unsigned long long)off, (unsigned long long)size);
    return 0;
}
