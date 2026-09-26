/* build-cnmt / build-meta-nca - ports the cnmt-writing and Meta-NCA-
 * assembly half of lib/nca_build.sh (nca_build_cnmt,
 * nca_build_patch_cnmt_digest, nca_build_meta). Program NCA building
 * (nca_build_program - PFS0/IVFC hash-tree construction for a full
 * exefs+romfs) is Phase 8, not this file.
 *
 * WHY THIS EXISTS: every field/cryptographic step here was derived
 * directly from this project's own vendored bin/hacpack 1.36_r2's C
 * source (cnmt.c/cnmt.h/nca.c/nca.h/pfs0.c/pfs0.h) - see
 * lib/nca_build.sh's own header comment for the full derivation and
 * hacpack-default values this deliberately matches (NCA_SIG_TYPE_ZERO -
 * fixed_key_sig/npdm_key_sig left all-zero; keygeneration 1, so
 * crypto_type/crypto_type2 stay 0; --keyareakey default 0x04 repeated 16
 * times as the plaintext content key later wrapped via
 * key_area_key_application_00).
 */
#include "common.h"
#include "crypto.h"
#include "nca_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include <openssl/evp.h>

static void le_put_u16(unsigned char *out, uint16_t v) {
    out[0] = (unsigned char)(v & 0xFF);
    out[1] = (unsigned char)((v >> 8) & 0xFF);
}
static void le_put_u32(unsigned char *out, uint32_t v) {
    for (int i = 0; i < 4; i++) out[i] = (unsigned char)((v >> (i * 8)) & 0xFF);
}
static void le_put_u64(unsigned char *out, uint64_t v) {
    for (int i = 0; i < 8; i++) out[i] = (unsigned char)((v >> (i * 8)) & 0xFF);
}
/* le_put_u40 - the cnmt PackagedContentInfo Size field is 5 raw
 * little-endian bytes (u40), not a power-of-2 width - matches
 * lib/binfmt.sh's own hex_field_le(..., 5) read exactly. */
static void le_put_u40(unsigned char *out, uint64_t v) {
    for (int i = 0; i < 5; i++) out[i] = (unsigned char)((v >> (i * 8)) & 0xFF);
}

static int sha256_file(const char *path, unsigned char out[32]) {
    FILE *f = fopen(path, "rb");
    if (!f) return 1;
    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
    unsigned char buf[1 << 20];
    size_t got;
    while ((got = fread(buf, 1, sizeof(buf), f)) > 0) {
        EVP_DigestUpdate(ctx, buf, got);
    }
    fclose(f);
    unsigned int outlen;
    EVP_DigestFinal_ex(ctx, out, &outlen);
    EVP_MD_CTX_free(ctx);
    return (outlen == 32) ? 0 : 1;
}

static long file_size(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return -1;
    fseeko(f, 0, SEEK_END);
    long size = ftello(f);
    fclose(f);
    return size;
}

/* build_cnmt <out_path> <title_type: "application"|"addon"> <title_id_hex>
 *   <title_version> <program_nca_or_empty> <control_nca_or_empty>
 *   <legal_nca_or_empty> <data_nca_or_empty>
 * Writes a PackagedContentMeta (.cnmt) file - exact port of
 * nca_build_cnmt. Trailing 32-byte digest left as all-zero placeholder;
 * caller patches in the real one after (same two-pass approach the bash
 * version and hacpack's own --digest flag both use). */
static int build_cnmt(const char *out_path, const char *title_type, const char *title_id_hex,
                       uint32_t title_version, const char *program_nca, const char *control_nca,
                       const char *legal_nca, const char *data_nca) {
    uint64_t title_id = strtoull(title_id_hex, NULL, 16);
    int is_application = (strcmp(title_type, "application") == 0);

    unsigned char ext_header[16] = {0};
    if (is_application) {
        /* ApplicationMetaExtendedHeader: PatchId = base_id | 0x800, then
         * 8 more zeroed bytes (RequiredSystemVersion/padding - hacpack's
         * own cnmt_create_application doesn't populate them either). */
        le_put_u64(ext_header, title_id + 0x800);
    } else {
        /* PatchMetaExtendedHeader (AddOnContent shape): ApplicationId,
         * same 8 zeroed bytes after. */
        le_put_u64(ext_header, title_id);
    }

    struct { const char *path; unsigned char type; } content_specs[4] = {
        { program_nca, 0x01 }, /* Program */
        { data_nca, 0x02 },    /* Data */
        { control_nca, 0x03 }, /* Control */
        { legal_nca, 0x05 },   /* LegalInformation */
    };

    unsigned char content_records[4][0x38] = {{0}};
    int content_count = 0;
    for (int i = 0; i < 4; i++) {
        if (!content_specs[i].path || content_specs[i].path[0] == '\0') continue;
        unsigned char hash[32];
        if (sha256_file(content_specs[i].path, hash) != 0) {
            fprintf(stderr, "build-cnmt: could not hash %s\n", content_specs[i].path);
            return 1;
        }
        long size = file_size(content_specs[i].path);
        if (size < 0) {
            fprintf(stderr, "build-cnmt: could not stat %s\n", content_specs[i].path);
            return 1;
        }
        unsigned char *rec = content_records[content_count];
        memcpy(rec, hash, 32);          /* Hash: full SHA256 */
        memcpy(rec + 0x20, hash, 16);   /* ContentId: first 16 bytes of the same SHA256 */
        le_put_u40(rec + 0x30, (uint64_t)size);
        rec[0x36] = content_specs[i].type;
        rec[0x37] = 0;
        content_count++;
    }

    unsigned char header[0x20] = {0};
    le_put_u64(header, title_id);
    le_put_u32(header + 8, title_version);
    header[0xC] = is_application ? 0x80 : 0x82;
    header[0xD] = 0;
    le_put_u16(header + 0xE, 16); /* ExtendedHeaderSize, always 16 for these two shapes */
    le_put_u16(header + 0x10, (uint16_t)content_count);
    /* 0x12-0x1F: reserved/unused, left zero */

    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fprintf(stderr, "build-cnmt: could not open %s for writing\n", out_path);
        return 1;
    }
    fwrite(header, 1, sizeof(header), out);
    fwrite(ext_header, 1, sizeof(ext_header), out);
    for (int i = 0; i < content_count; i++) fwrite(content_records[i], 1, 0x38, out);
    unsigned char digest_placeholder[32] = {0};
    fwrite(digest_placeholder, 1, sizeof(digest_placeholder), out);
    fclose(out);
    return 0;
}

/* patch_cnmt_digest <cnmt_path>
 * Recomputes and rewrites the trailing 32-byte digest (SHA256 of
 * everything except the digest itself) - exact port of
 * nca_build_patch_cnmt_digest. */
static int patch_cnmt_digest(const char *cnmt_path) {
    long size = file_size(cnmt_path);
    if (size < 32) {
        fprintf(stderr, "patch-cnmt-digest: %s too small\n", cnmt_path);
        return 1;
    }

    FILE *f = fopen(cnmt_path, "rb");
    if (!f) return 1;
    unsigned char *buf = malloc((size_t)size);
    if (fread(buf, 1, (size_t)size, f) != (size_t)size) { fclose(f); free(buf); return 1; }
    fclose(f);

    EVP_MD_CTX *ctx = EVP_MD_CTX_new();
    EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
    EVP_DigestUpdate(ctx, buf, (size_t)size - 32);
    unsigned char digest[32];
    unsigned int outlen;
    EVP_DigestFinal_ex(ctx, digest, &outlen);
    EVP_MD_CTX_free(ctx);
    free(buf);

    f = fopen(cnmt_path, "r+b");
    if (!f) return 1;
    fseeko(f, size - 32, SEEK_SET);
    fwrite(digest, 1, 32, f);
    fclose(f);
    return 0;
}

int cmd_build_cnmt(int argc, char **argv) {
    if (argc < 8) {
        fprintf(stderr, "usage: smtool build-cnmt <out_path> <application|addon> <title_id_hex> <title_version> <program_nca_or_-> <control_nca_or_-> <legal_nca_or_-> <data_nca_or_->\n");
        return 1;
    }
    const char *out_path = argv[0], *title_type = argv[1], *title_id_hex = argv[2];
    char *end;
    uint32_t title_version = (uint32_t)strtoul(argv[3], &end, 10);
    if (*end != '\0') { fprintf(stderr, "build-cnmt: invalid title_version '%s'\n", argv[3]); return 1; }
    const char *program_nca = strcmp(argv[4], "-") == 0 ? "" : argv[4];
    const char *control_nca = strcmp(argv[5], "-") == 0 ? "" : argv[5];
    const char *legal_nca = strcmp(argv[6], "-") == 0 ? "" : argv[6];
    const char *data_nca = strcmp(argv[7], "-") == 0 ? "" : argv[7];

    if (build_cnmt(out_path, title_type, title_id_hex, title_version, program_nca, control_nca, legal_nca, data_nca) != 0) return 1;
    return patch_cnmt_digest(out_path);
}

/* --- Meta NCA assembly (nca_build_meta) --- */

/* _nca_build_hash_blocks equivalent: one SHA256 per block_size-byte
 * block of src, written back-to-back, no padding. */
static int hash_blocks(const char *src_path, uint64_t block_size, unsigned char **out_buf, uint64_t *out_size) {
    FILE *f = fopen(src_path, "rb");
    if (!f) return 1;
    fseeko(f, 0, SEEK_END);
    uint64_t src_size = (uint64_t)ftello(f);
    fseeko(f, 0, SEEK_SET);

    uint64_t num_blocks = (src_size + block_size - 1) / block_size;
    if (num_blocks == 0) num_blocks = 1; /* hacpack's own split still emits one empty-file hash if src is empty - matches lib/nca_build.sh's split behavior for a zero-byte input, though this project's real Meta/Program NCAs never hit that case */
    unsigned char *hashes = malloc((size_t)(num_blocks * 32));
    unsigned char *block_buf = malloc((size_t)block_size);

    for (uint64_t b = 0; b < num_blocks; b++) {
        size_t got = fread(block_buf, 1, (size_t)block_size, f);
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
        EVP_DigestUpdate(ctx, block_buf, got);
        unsigned int outlen;
        EVP_DigestFinal_ex(ctx, hashes + b * 32, &outlen);
        EVP_MD_CTX_free(ctx);
    }
    fclose(f);
    free(block_buf);

    *out_buf = hashes;
    *out_size = num_blocks * 32;
    return 0;
}

static int cmd_build_meta_nca_impl(const char *out_nca, const char *keys_path, const char *title_id_hex,
                                    uint32_t title_version, const char *program_nca, const char *control_nca,
                                    const char *legal_nca, const char *data_nca, const char *digest_hex) {
    char work_cnmt[] = "/tmp/smtool_meta_cnmt_XXXXXX";
    int fd = mkstemp(work_cnmt);
    if (fd < 0) { fprintf(stderr, "build-meta-nca: mkstemp failed\n"); return 1; }
    close(fd);

    if (build_cnmt(work_cnmt, "application", title_id_hex, title_version, program_nca, control_nca, legal_nca, data_nca) != 0) {
        remove(work_cnmt);
        return 1;
    }
    if (digest_hex && digest_hex[0] != '\0') {
        size_t dig_len;
        unsigned char *digest = hex_decode(digest_hex, &dig_len);
        if (!digest || dig_len != 32) {
            fprintf(stderr, "build-meta-nca: --digest must be 64 hex chars\n");
            free(digest);
            remove(work_cnmt);
            return 1;
        }
        long sz = file_size(work_cnmt);
        FILE *f = fopen(work_cnmt, "r+b");
        fseeko(f, sz - 32, SEEK_SET);
        fwrite(digest, 1, 32, f);
        fclose(f);
        free(digest);
    }

    /* The cnmt's own PFS0 entry name is "Application_<title_id>.cnmt" -
     * matches hacpack's own naming and this project's bash equivalent
     * (nca_build_meta's own cnmt_path construction). pfs0-pack uses each
     * file's OWN basename as its PFS0 entry name, so the temp file must
     * be renamed to that name first (a plain mkstemp path's basename
     * would otherwise leak into the packed NSP/NCA). */
    char cnmt_dir[] = "/tmp/smtool_meta_dir_XXXXXX";
    if (!mkdtemp(cnmt_dir)) { fprintf(stderr, "build-meta-nca: mkdtemp failed\n"); remove(work_cnmt); return 1; }
    char cnmt_named[512];
    snprintf(cnmt_named, sizeof(cnmt_named), "%s/Application_%s.cnmt", cnmt_dir, title_id_hex);
    if (rename(work_cnmt, cnmt_named) != 0) {
        FILE *src = fopen(work_cnmt, "rb");
        FILE *dst = fopen(cnmt_named, "wb");
        unsigned char buf[65536];
        size_t got;
        while ((got = fread(buf, 1, sizeof(buf), src)) > 0) fwrite(buf, 1, got, dst);
        fclose(src);
        fclose(dst);
        remove(work_cnmt);
    }

    char pfs0_path[600];
    snprintf(pfs0_path, sizeof(pfs0_path), "%s/pfs0.bin", cnmt_dir);
    {
        char *pack_argv[3] = { pfs0_path, cnmt_named, NULL };
        extern int cmd_pfs0_pack(int argc, char **argv);
        if (cmd_pfs0_pack(2, pack_argv) != 0) { return 1; }
    }

    const uint64_t block_size = 4096;
    unsigned char *hashtable_buf;
    uint64_t hashtable_size;
    if (hash_blocks(pfs0_path, block_size, &hashtable_buf, &hashtable_size) != 0) {
        fprintf(stderr, "build-meta-nca: hashing pfs0 failed\n");
        return 1;
    }
    uint64_t padded_hashtable_size = (hashtable_size + 0x1FF) & ~(uint64_t)0x1FF;
    unsigned char *padded_hashtable = calloc(1, padded_hashtable_size);
    memcpy(padded_hashtable, hashtable_buf, hashtable_size);

    long pfs0_size_l = file_size(pfs0_path);
    uint64_t pfs0_size = (uint64_t)pfs0_size_l;
    uint64_t pfs0_offset = padded_hashtable_size;

    unsigned char master_hash[32];
    {
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
        EVP_DigestUpdate(ctx, padded_hashtable, hashtable_size);
        unsigned int outlen;
        EVP_DigestFinal_ex(ctx, master_hash, &outlen);
        EVP_MD_CTX_free(ctx);
    }

    /* FS header (0x200 bytes) for section 0: version(2)=0x0002 +
     * fs_type(1=PFS0) + hash_type(2=PFS0) + crypt_type(3=CTR) + pad(3),
     * pfs0_superblock: master_hash(0x20) + block_size(4) + always_2(4) +
     * hash_table_offset(8,always 0) + hash_table_size(8) +
     * pfs0_offset(8) + pfs0_size(8) + pad(0xF0), section_ctr(8, zero) +
     * pad(0xB8). */
    unsigned char fs_header[0x200] = {0};
    le_put_u16(fs_header + 0x0, 2);
    fs_header[0x2] = 1;
    fs_header[0x3] = 2;
    fs_header[0x4] = 3;
    memcpy(fs_header + 0x8, master_hash, 32);
    le_put_u32(fs_header + 0x28, (uint32_t)block_size);
    le_put_u32(fs_header + 0x2C, 2);
    le_put_u64(fs_header + 0x30, 0);
    le_put_u64(fs_header + 0x38, hashtable_size);
    le_put_u64(fs_header + 0x40, pfs0_offset);
    le_put_u64(fs_header + 0x48, pfs0_size);
    /* fs_header+0x140: section_ctr, left zero (matches a real
     * hacpack-built Meta NCA's own all-zero SectionCTR). */

    unsigned char section_hash[32];
    {
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
        EVP_DigestUpdate(ctx, fs_header, sizeof(fs_header));
        unsigned int outlen;
        EVP_DigestFinal_ex(ctx, section_hash, &outlen);
        EVP_MD_CTX_free(ctx);
    }

    uint64_t raw_content_size = pfs0_offset + pfs0_size;
    uint64_t section_content_size = (raw_content_size + 0x1FF) & ~(uint64_t)0x1FF;
    uint64_t trailing_pad = section_content_size - raw_content_size;
    uint64_t total_size = 0xC00 + section_content_size;
    uint32_t media_end = (uint32_t)(total_size / 0x200);

    /* Main header (0x400 bytes before the 4 fs_headers) */
    unsigned char main_hdr[NCA_HEADER_SIZE] = {0};
    /* fixed_key_sig/npdm_key_sig: 0x200 bytes, left zero */
    memcpy(main_hdr + 0x200, "NCA3", 4);
    main_hdr[0x204] = 0; /* distribution = download */
    main_hdr[0x205] = 1; /* content_type = Meta */
    main_hdr[0x206] = 0; /* crypto_type */
    main_hdr[0x207] = 0; /* kaek_ind = Application */
    le_put_u64(main_hdr + 0x208, total_size);
    le_put_u64(main_hdr + 0x210, strtoull(title_id_hex, NULL, 16));
    le_put_u32(main_hdr + 0x21C, 0xc1100); /* sdk_version default */
    main_hdr[0x220] = 0; /* crypto_type2 */
    /* rights_id: 0x230, 16 bytes, zero (standard crypto) */

    /* section_entries[0]: media_start_offset=6, media_end_offset, _0x8[0]=1 */
    le_put_u32(main_hdr + 0x240, 6);
    le_put_u32(main_hdr + 0x244, media_end);
    main_hdr[0x248] = 1;
    /* section_entries[1..3]: zero (already) */

    /* section_hashes[0..3] */
    memcpy(main_hdr + 0x280, section_hash, 32);

    /* encrypted_keys[4] - plaintext for now (slot 2 = 0x04 placeholder),
     * encrypted in place below via key_area_key_application_00. */
    unsigned char plaintext_keys[0x40] = {0};
    memset(plaintext_keys + 0x20, 0x04, 16);

    char *kaek_hex = keys_file_lookup(keys_path, "key_area_key_application_00", 32);
    if (!kaek_hex) {
        fprintf(stderr, "build-meta-nca: key_area_key_application_00 not found in %s\n", keys_path);
        return 1;
    }
    size_t kaek_len;
    unsigned char *kaek = hex_decode(kaek_hex, &kaek_len);
    free(kaek_hex);
    if (!kaek || kaek_len != 16) { fprintf(stderr, "build-meta-nca: key_area_key_application_00 wrong length\n"); free(kaek); return 1; }

    unsigned char encrypted_keys[0x40];
    for (int i = 0; i < 4; i++) {
        if (aes128_ecb_block(1, kaek, plaintext_keys + i * 16, encrypted_keys + i * 16) != 0) {
            fprintf(stderr, "build-meta-nca: key-area encryption failed\n");
            free(kaek);
            return 1;
        }
    }
    free(kaek);
    memcpy(main_hdr + 0x300, encrypted_keys, 0x40);

    /* fs_headers[0..3]: real one for section 0, zero for the rest */
    memcpy(main_hdr + 0x400, fs_header, sizeof(fs_header));

    unsigned char encrypted_header[NCA_HEADER_SIZE];
    if (nca_encrypt_header(main_hdr, keys_path, encrypted_header) != 0) {
        fprintf(stderr, "build-meta-nca: header encryption failed\n");
        return 1;
    }

    FILE *out = fopen(out_nca, "wb");
    if (!out) { fprintf(stderr, "build-meta-nca: could not open %s for writing\n", out_nca); return 1; }
    fwrite(encrypted_header, 1, sizeof(encrypted_header), out);
    fwrite(padded_hashtable, 1, padded_hashtable_size, out);
    {
        FILE *pfs0_f = fopen(pfs0_path, "rb");
        unsigned char buf[65536];
        size_t got;
        while ((got = fread(buf, 1, sizeof(buf), pfs0_f)) > 0) fwrite(buf, 1, got, out);
        fclose(pfs0_f);
    }
    if (trailing_pad > 0) {
        unsigned char z = 0;
        for (uint64_t i = 0; i < trailing_pad; i++) fwrite(&z, 1, 1, out);
    }
    fclose(out);

    /* Encrypt section 0's content in place (AES-CTR, key = the fixed
     * 0x04-repeated placeholder, CTR = nca_content_ctr with an
     * all-zero SectionCTR and byte offset 0xC00 - CTR is its own
     * inverse, same primitive Phase 5's decrypt-section already uses). */
    unsigned char section_key[16];
    memset(section_key, 0x04, 16);
    unsigned char ctr[16] = {0};
    uint64_t block_offset = 0xC00 / 0x10;
    for (int i = 0; i < 8; i++) ctr[8 + i] = (unsigned char)((block_offset >> ((7 - i) * 8)) & 0xFF);

    {
        FILE *rw = fopen(out_nca, "r+b");
        if (!rw) { fprintf(stderr, "build-meta-nca: could not reopen %s\n", out_nca); return 1; }
        fseeko(rw, 0xC00, SEEK_SET);

        EVP_CIPHER_CTX *cipher = EVP_CIPHER_CTX_new();
        if (!cipher || EVP_EncryptInit_ex(cipher, EVP_aes_128_ctr(), NULL, section_key, ctr) != 1) {
            fprintf(stderr, "build-meta-nca: CTR init failed\n");
            fclose(rw);
            return 1;
        }
        unsigned char inbuf[1 << 20], outbuf[(1 << 20) + 16];
        uint64_t remaining = section_content_size;
        long read_pos = 0xC00;
        while (remaining > 0) {
            size_t chunk = remaining < sizeof(inbuf) ? (size_t)remaining : sizeof(inbuf);
            fseeko(rw, read_pos, SEEK_SET);
            size_t got = fread(inbuf, 1, chunk, rw);
            if (got == 0) break;
            int outlen = 0;
            EVP_EncryptUpdate(cipher, outbuf, &outlen, inbuf, (int)got);
            fseeko(rw, read_pos, SEEK_SET);
            fwrite(outbuf, 1, (size_t)outlen, rw);
            read_pos += (long)got;
            remaining -= got;
        }
        EVP_CIPHER_CTX_free(cipher);
        fclose(rw);
    }

    free(hashtable_buf);
    free(padded_hashtable);
    remove(cnmt_named);
    remove(pfs0_path);
    { char rmdir_cmd[600]; snprintf(rmdir_cmd, sizeof(rmdir_cmd), "%s", cnmt_dir); rmdir(rmdir_cmd); }
    return 0;
}

/* --- Program NCA assembly (nca_build_program) ---
 *
 * Builds a complete, PLAINTEXT (crypt_type=None, matching hacpack's own
 * --plaintext) Program NCA from an ORDERED list of exefs file paths
 * (the original container order, NOT filesystem/readdir order - see
 * lib/nca_build.sh's own comment on why: relying on readdir() to
 * recover the original PFS0 order is fragile/filesystem-dependent) and
 * a real romfs directory tree (built via Phase 6's own romfs-build
 * logic, called in-process here rather than as a subprocess - the whole
 * point of landing Phase 6 before this one).
 *
 * One of the exefs files MUST be named "main.npdm" - its ACID
 * signature/key get zeroed (mirrors hacpack's own npdm_process, which
 * does this to every exefs it packs unless --nozeroacidsig/
 * --nozeroacidkey are passed - this project never passes either).
 */

extern int cmd_pfs0_pack(int argc, char **argv);

/* zero_npdm_acid <main_npdm_path>
 * Zeroes main.npdm's ACID signature (0x100 bytes at acid_offset) and
 * RSA modulus/"key" (the next 0x100 bytes) in place - exact port of
 * nca_build_zero_npdm_acid. acid_offset itself is a u32 at file offset
 * 0x78, pointing at the START of npdm_acid_t (its signature field, NOT
 * the "ACID" magic, which is the 3rd field at acid_offset+0x200). */
static int zero_npdm_acid(const char *npdm_path) {
    FILE *f = fopen(npdm_path, "r+b");
    if (!f) { fprintf(stderr, "build-program-nca: could not open %s\n", npdm_path); return 1; }
    unsigned char acid_off_bytes[4];
    fseeko(f, 0x78, SEEK_SET);
    if (fread(acid_off_bytes, 1, 4, f) != 4) { fclose(f); return 1; }
    uint32_t acid_offset = (uint32_t)acid_off_bytes[0] | ((uint32_t)acid_off_bytes[1] << 8) |
                            ((uint32_t)acid_off_bytes[2] << 16) | ((uint32_t)acid_off_bytes[3] << 24);
    unsigned char zeros[0x200] = {0};
    fseeko(f, acid_offset, SEEK_SET);
    fwrite(zeros, 1, sizeof(zeros), f);
    fclose(f);
    return 0;
}

/* ivfc_hash_level <src_path> <out_path> -> padded out_size
 * One IVFC recursion step: writes a SHA256 hash per 0x4000-byte block of
 * src_path to out_path, padded to a multiple of 0x4000 at the end -
 * exact port of _nca_build_ivfc_level. */
static int ivfc_hash_level(const char *src_path, const char *out_path, uint64_t *out_size) {
    unsigned char *hashes;
    uint64_t hashes_size;
    if (hash_blocks(src_path, 0x4000, &hashes, &hashes_size) != 0) return 1;
    uint64_t padded = (hashes_size + 0x3FFF) & ~(uint64_t)0x3FFF;

    FILE *out = fopen(out_path, "wb");
    if (!out) { free(hashes); return 1; }
    fwrite(hashes, 1, hashes_size, out);
    if (padded > hashes_size) {
        unsigned char z = 0;
        for (uint64_t i = 0; i < padded - hashes_size; i++) fwrite(&z, 1, 1, out);
    }
    fclose(out);
    free(hashes);
    *out_size = padded;
    return 0;
}

static uint64_t file_size_u64(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) return 0;
    fseeko(f, 0, SEEK_END);
    uint64_t sz = (uint64_t)ftello(f);
    fclose(f);
    return sz;
}

int cmd_build_program_nca(int argc, char **argv) {
    const char *out_nca = NULL, *keys_path = NULL, *title_id_hex = NULL, *romfs_dir = NULL;
    char *exefs_files[64];
    int exefs_count = 0;
    int positional = 0;

    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (strcmp(argv[i], "--romfs-dir") == 0 && i + 1 < argc) { romfs_dir = argv[++i]; }
        else if (strcmp(argv[i], "--exefs") == 0 && i + 1 < argc) {
            if (exefs_count < 64) exefs_files[exefs_count++] = argv[++i];
            else { fprintf(stderr, "build-program-nca: too many --exefs files\n"); return 1; }
        }
        else {
            switch (positional) {
                case 0: out_nca = argv[i]; break;
                case 1: title_id_hex = argv[i]; break;
            }
            positional++;
        }
    }
    if (!out_nca || !title_id_hex || !keys_path || !romfs_dir || exefs_count == 0) {
        fprintf(stderr, "usage: smtool build-program-nca <out_nca> <title_id_hex> --keys <keys_file> --romfs-dir <dir> --exefs <file> [--exefs <file> ...]\n");
        return 1;
    }

    char work_dir[] = "/tmp/smtool_program_XXXXXX";
    if (!mkdtemp(work_dir)) { fprintf(stderr, "build-program-nca: mkdtemp failed\n"); return 1; }

    /* --- Section 0: exefs (PFS0, HierarchicalSha256, 0x10000 hash blocks) --- */
    char npdm_copy[600] = "";
    char *exefs_fixed[64];
    for (int i = 0; i < exefs_count; i++) {
        const char *base = strrchr(exefs_files[i], '/');
        base = base ? base + 1 : exefs_files[i];
        if (strcmp(base, "main.npdm") == 0) {
            snprintf(npdm_copy, sizeof(npdm_copy), "%s/main.npdm", work_dir);
            FILE *src = fopen(exefs_files[i], "rb");
            FILE *dst = fopen(npdm_copy, "wb");
            unsigned char buf[65536];
            size_t got;
            while ((got = fread(buf, 1, sizeof(buf), src)) > 0) fwrite(buf, 1, got, dst);
            fclose(src);
            fclose(dst);
            if (zero_npdm_acid(npdm_copy) != 0) return 1;
            exefs_fixed[i] = npdm_copy;
        } else {
            exefs_fixed[i] = exefs_files[i];
        }
    }
    if (npdm_copy[0] == '\0') {
        fprintf(stderr, "build-program-nca: no main.npdm found in --exefs file list\n");
        return 1;
    }

    char exefs_pfs0[600];
    snprintf(exefs_pfs0, sizeof(exefs_pfs0), "%s/exefs.pfs0", work_dir);
    {
        char *pack_argv[66];
        pack_argv[0] = exefs_pfs0;
        for (int i = 0; i < exefs_count; i++) pack_argv[1 + i] = exefs_fixed[i];
        pack_argv[1 + exefs_count] = NULL;
        if (cmd_pfs0_pack(1 + exefs_count, pack_argv) != 0) return 1;
    }

    const uint64_t exefs_block_size = 65536;
    unsigned char *exefs_hashtable_buf;
    uint64_t exefs_hashtable_size;
    if (hash_blocks(exefs_pfs0, exefs_block_size, &exefs_hashtable_buf, &exefs_hashtable_size) != 0) return 1;
    uint64_t exefs_hashtable_padded = (exefs_hashtable_size + 0x1FF) & ~(uint64_t)0x1FF;
    unsigned char *exefs_hashtable_padded_buf = calloc(1, exefs_hashtable_padded);
    memcpy(exefs_hashtable_padded_buf, exefs_hashtable_buf, exefs_hashtable_size);

    uint64_t exefs_pfs0_offset = exefs_hashtable_padded;
    uint64_t exefs_pfs0_size = file_size_u64(exefs_pfs0);

    unsigned char exefs_master_hash[32];
    {
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
        EVP_DigestUpdate(ctx, exefs_hashtable_padded_buf, exefs_hashtable_size);
        unsigned int outlen;
        EVP_DigestFinal_ex(ctx, exefs_master_hash, &outlen);
        EVP_MD_CTX_free(ctx);
    }

    uint64_t exefs_raw_size = exefs_pfs0_offset + exefs_pfs0_size;
    uint64_t exefs_section_size = (exefs_raw_size + 0x1FF) & ~(uint64_t)0x1FF;
    uint64_t exefs_trailing_pad = exefs_section_size - exefs_raw_size;

    unsigned char exefs_fs_header[0x200] = {0};
    le_put_u16(exefs_fs_header + 0x0, 2);
    exefs_fs_header[0x2] = 1; /* fs_type = PFS0 */
    exefs_fs_header[0x3] = 2; /* hash_type = PFS0 */
    exefs_fs_header[0x4] = 1; /* crypt_type = None (plaintext) */
    memcpy(exefs_fs_header + 0x8, exefs_master_hash, 32);
    le_put_u32(exefs_fs_header + 0x28, (uint32_t)exefs_block_size);
    le_put_u32(exefs_fs_header + 0x2C, 2);
    le_put_u64(exefs_fs_header + 0x30, 0);
    le_put_u64(exefs_fs_header + 0x38, exefs_hashtable_size);
    le_put_u64(exefs_fs_header + 0x40, exefs_pfs0_offset);
    le_put_u64(exefs_fs_header + 0x48, exefs_pfs0_size);

    unsigned char exefs_section_hash[32];
    {
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
        EVP_DigestUpdate(ctx, exefs_fs_header, sizeof(exefs_fs_header));
        unsigned int outlen;
        EVP_DigestFinal_ex(ctx, exefs_section_hash, &outlen);
        EVP_MD_CTX_free(ctx);
    }

    /* --- Section 1: romfs (built via Phase 6's romfs-build, in-process,
     * then IVFC-hashed) --- path[5]=raw romfs, path[0..4]=5 recursive
     * hash levels, level_headers[N].hash_data_size for EVERY N is that
     * level's OWN (already-padded, for N<5; naturally block-aligned
     * already for N=5) file size - confirmed by reading hacpack's exact
     * call site (ivfc_create_level writes TO path[b] FROM path[b+1],
     * size captured is path[b]'s own). */
    char ivfc_path5[600], ivfc_path4[600], ivfc_path3[600], ivfc_path2[600], ivfc_path1[600], ivfc_path0[600];
    snprintf(ivfc_path5, sizeof(ivfc_path5), "%s/romfs.bin", work_dir);
    snprintf(ivfc_path4, sizeof(ivfc_path4), "%s/ivfc4.bin", work_dir);
    snprintf(ivfc_path3, sizeof(ivfc_path3), "%s/ivfc3.bin", work_dir);
    snprintf(ivfc_path2, sizeof(ivfc_path2), "%s/ivfc2.bin", work_dir);
    snprintf(ivfc_path1, sizeof(ivfc_path1), "%s/ivfc1.bin", work_dir);
    snprintf(ivfc_path0, sizeof(ivfc_path0), "%s/ivfc0.bin", work_dir);

    /* romfs_build_impl's own *out_unpadded_size param gives us the
     * UNPADDED size directly, in-process - no subprocess/pipe needed
     * (this is exactly the field this project's own README documents as
     * a real, confirmed bug-source if mixed up with the padded on-disk
     * size: level 5's hash_data_size must be the UNPADDED size). */
    uint64_t ivfc_size5;
    if (romfs_build_impl(romfs_dir, ivfc_path5, &ivfc_size5) != 0) {
        fprintf(stderr, "build-program-nca: romfs-build failed\n");
        return 1;
    }

    uint64_t ivfc_size4, ivfc_size3, ivfc_size2, ivfc_size1, ivfc_size0;
    if (ivfc_hash_level(ivfc_path5, ivfc_path4, &ivfc_size4) != 0) return 1;
    if (ivfc_hash_level(ivfc_path4, ivfc_path3, &ivfc_size3) != 0) return 1;
    if (ivfc_hash_level(ivfc_path3, ivfc_path2, &ivfc_size2) != 0) return 1;
    if (ivfc_hash_level(ivfc_path2, ivfc_path1, &ivfc_size1) != 0) return 1;
    if (ivfc_hash_level(ivfc_path1, ivfc_path0, &ivfc_size0) != 0) return 1;

    uint64_t ivfc_off0 = 0;
    uint64_t ivfc_off1 = ivfc_off0 + ivfc_size0;
    uint64_t ivfc_off2 = ivfc_off1 + ivfc_size1;
    uint64_t ivfc_off3 = ivfc_off2 + ivfc_size2;
    uint64_t ivfc_off4 = ivfc_off3 + ivfc_size3;
    uint64_t ivfc_off5 = ivfc_off4 + ivfc_size4;

    unsigned char ivfc_master_hash[32];
    if (sha256_file(ivfc_path0, ivfc_master_hash) != 0) return 1;

    /* IVFC header: magic("IVFC") + id(0x20000) + master_hash_size(0x20) +
     * num_levels(7) + 6 level headers + pad(0x20) + master_hash(0x20). */
    unsigned char ivfc_hdr[0xE0] = {0};
    memcpy(ivfc_hdr, "IVFC", 4);
    le_put_u32(ivfc_hdr + 4, 0x20000);
    le_put_u32(ivfc_hdr + 8, 0x20);
    le_put_u32(ivfc_hdr + 12, 7);
    uint64_t level_offs[6] = { ivfc_off0, ivfc_off1, ivfc_off2, ivfc_off3, ivfc_off4, ivfc_off5 };
    uint64_t level_sizes[6] = { ivfc_size0, ivfc_size1, ivfc_size2, ivfc_size3, ivfc_size4, ivfc_size5 };
    for (int i = 0; i < 6; i++) {
        unsigned char *lvl = ivfc_hdr + 16 + i * 0x18;
        le_put_u64(lvl, level_offs[i]);
        le_put_u64(lvl + 8, level_sizes[i]);
        le_put_u32(lvl + 16, 0xE);
        le_put_u32(lvl + 20, 0);
    }
    memcpy(ivfc_hdr + 0xC0, ivfc_master_hash, 32);

    uint64_t ivfc_path5_actual_size = file_size_u64(ivfc_path5);
    uint64_t romfs_raw_size = ivfc_off5 + ivfc_path5_actual_size;
    uint64_t romfs_section_size = (romfs_raw_size + 0x1FF) & ~(uint64_t)0x1FF;
    uint64_t romfs_trailing_pad = romfs_section_size - romfs_raw_size;

    unsigned char romfs_fs_header[0x200] = {0};
    le_put_u16(romfs_fs_header + 0x0, 2);
    romfs_fs_header[0x2] = 0; /* fs_type = RomFs */
    romfs_fs_header[0x3] = 3; /* hash_type = RomFs/HierarchicalIntegrity */
    romfs_fs_header[0x4] = 1; /* crypt_type = None (plaintext) */
    memcpy(romfs_fs_header + 0x8, ivfc_hdr, sizeof(ivfc_hdr));
    /* remaining bytes to 0x138 (romfs_superblock total size): zero -
     * relocation_header/subsection_header (no BKTR here) already zero. */

    unsigned char romfs_section_hash[32];
    {
        EVP_MD_CTX *ctx = EVP_MD_CTX_new();
        EVP_DigestInit_ex(ctx, EVP_sha256(), NULL);
        EVP_DigestUpdate(ctx, romfs_fs_header, sizeof(romfs_fs_header));
        unsigned int outlen;
        EVP_DigestFinal_ex(ctx, romfs_section_hash, &outlen);
        EVP_MD_CTX_free(ctx);
    }

    /* --- Assemble the full header --- */
    uint32_t exefs_media_end = (uint32_t)((0xC00 + exefs_section_size) / 0x200);
    uint64_t total_size = 0xC00 + exefs_section_size + romfs_section_size;
    uint32_t romfs_media_start = exefs_media_end;
    uint32_t romfs_media_end = (uint32_t)(total_size / 0x200);

    unsigned char main_hdr[NCA_HEADER_SIZE] = {0};
    memcpy(main_hdr + 0x200, "NCA3", 4);
    main_hdr[0x204] = 0; /* distribution = download */
    main_hdr[0x205] = 0; /* content_type = Program */
    main_hdr[0x206] = 0;
    main_hdr[0x207] = 0;
    le_put_u64(main_hdr + 0x208, total_size);
    le_put_u64(main_hdr + 0x210, strtoull(title_id_hex, NULL, 16));
    le_put_u32(main_hdr + 0x21C, 0xc1100);
    main_hdr[0x220] = 0;

    le_put_u32(main_hdr + 0x240, 6);
    le_put_u32(main_hdr + 0x244, exefs_media_end);
    main_hdr[0x248] = 1;
    le_put_u32(main_hdr + 0x250, romfs_media_start);
    le_put_u32(main_hdr + 0x254, romfs_media_end);
    main_hdr[0x258] = 1;

    memcpy(main_hdr + 0x280, exefs_section_hash, 32);
    memcpy(main_hdr + 0x2A0, romfs_section_hash, 32);

    unsigned char plaintext_keys[0x40] = {0};
    memset(plaintext_keys + 0x20, 0x04, 16);
    char *kaek_hex = keys_file_lookup(keys_path, "key_area_key_application_00", 32);
    if (!kaek_hex) { fprintf(stderr, "build-program-nca: key_area_key_application_00 not found\n"); return 1; }
    size_t kaek_len;
    unsigned char *kaek = hex_decode(kaek_hex, &kaek_len);
    free(kaek_hex);
    if (!kaek || kaek_len != 16) { fprintf(stderr, "build-program-nca: bad kaek\n"); free(kaek); return 1; }
    unsigned char encrypted_keys[0x40];
    for (int i = 0; i < 4; i++) {
        if (aes128_ecb_block(1, kaek, plaintext_keys + i * 16, encrypted_keys + i * 16) != 0) { free(kaek); return 1; }
    }
    free(kaek);
    memcpy(main_hdr + 0x300, encrypted_keys, 0x40);

    memcpy(main_hdr + 0x400, exefs_fs_header, sizeof(exefs_fs_header));
    memcpy(main_hdr + 0x600, romfs_fs_header, sizeof(romfs_fs_header));

    unsigned char encrypted_header[NCA_HEADER_SIZE];
    if (nca_encrypt_header(main_hdr, keys_path, encrypted_header) != 0) {
        fprintf(stderr, "build-program-nca: header encryption failed\n");
        return 1;
    }

    FILE *out = fopen(out_nca, "wb");
    if (!out) { fprintf(stderr, "build-program-nca: could not open %s\n", out_nca); return 1; }
    fwrite(encrypted_header, 1, sizeof(encrypted_header), out);
    fwrite(exefs_hashtable_padded_buf, 1, exefs_hashtable_padded, out);
    {
        FILE *src = fopen(exefs_pfs0, "rb");
        unsigned char buf[65536];
        size_t got;
        while ((got = fread(buf, 1, sizeof(buf), src)) > 0) fwrite(buf, 1, got, out);
        fclose(src);
    }
    if (exefs_trailing_pad > 0) { unsigned char z = 0; for (uint64_t i = 0; i < exefs_trailing_pad; i++) fwrite(&z, 1, 1, out); }
    {
        const char *ivfc_paths[6] = { ivfc_path0, ivfc_path1, ivfc_path2, ivfc_path3, ivfc_path4, ivfc_path5 };
        for (int i = 0; i < 6; i++) {
            FILE *src = fopen(ivfc_paths[i], "rb");
            unsigned char buf[65536];
            size_t got;
            while ((got = fread(buf, 1, sizeof(buf), src)) > 0) fwrite(buf, 1, got, out);
            fclose(src);
        }
    }
    if (romfs_trailing_pad > 0) { unsigned char z = 0; for (uint64_t i = 0; i < romfs_trailing_pad; i++) fwrite(&z, 1, 1, out); }
    fclose(out);

    free(exefs_hashtable_buf);
    free(exefs_hashtable_padded_buf);
    return 0;
}

int cmd_build_meta_nca(int argc, char **argv) {
    const char *out_nca = NULL, *keys_path = NULL, *title_id_hex = NULL, *title_version_str = NULL;
    const char *program_nca = "", *control_nca = "", *legal_nca = "", *data_nca = "", *digest_hex = "";
    int positional = 0;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (strcmp(argv[i], "--digest") == 0 && i + 1 < argc) { digest_hex = argv[++i]; }
        else if (strcmp(argv[i], "--program") == 0 && i + 1 < argc) { program_nca = argv[++i]; }
        else if (strcmp(argv[i], "--control") == 0 && i + 1 < argc) { control_nca = argv[++i]; }
        else if (strcmp(argv[i], "--legal") == 0 && i + 1 < argc) { legal_nca = argv[++i]; }
        else if (strcmp(argv[i], "--data") == 0 && i + 1 < argc) { data_nca = argv[++i]; }
        else {
            switch (positional) {
                case 0: out_nca = argv[i]; break;
                case 1: title_id_hex = argv[i]; break;
                case 2: title_version_str = argv[i]; break;
            }
            positional++;
        }
    }
    if (!out_nca || !keys_path || !title_id_hex || !title_version_str) {
        fprintf(stderr, "usage: smtool build-meta-nca <out_nca> <title_id_hex> <title_version> --keys <keys_file> [--program <nca>] [--control <nca>] [--legal <nca>] [--data <nca>] [--digest <hex64>]\n");
        return 1;
    }
    char *end;
    uint32_t title_version = (uint32_t)strtoul(title_version_str, &end, 10);
    if (*end != '\0') { fprintf(stderr, "build-meta-nca: invalid title_version '%s'\n", title_version_str); return 1; }

    return cmd_build_meta_nca_impl(out_nca, keys_path, title_id_hex, title_version, program_nca, control_nca, legal_nca, data_nca, digest_hex);
}
