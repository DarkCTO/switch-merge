/* bktr-headers / bktr-relocations / bktr-subsections - ports lib/bktr.sh's
 * bucket-tree readers (bktr_headers, _bktr_parse_bucket0_relocations,
 * _bktr_parse_bucket0_subsections). Full BKTR reconstruction
 * (bktr_reconstruct itself) is NOT ported here - it needs streaming
 * AES-CTR decryption of update NCA content, which is Phase 5's scope;
 * this phase only ports the bucket-tree PARSING that reconstruction
 * depends on, same split lib/bktr.sh itself doesn't draw but this C port
 * does since the crypto and the parsing are independently testable.
 *
 * BKTR's format is NOT documented anywhere online in this detail
 * (switchbrew's wiki only covers the high-level "Enc. Type: AesCtrEx"
 * concept) - every struct offset and lookup rule below is an exact port
 * of lib/bktr.sh's own header comments, themselves derived directly from
 * vendored bin/hactool 1.4.0's C source (nca.c/nca.h/bktr.c/bktr.h) and
 * verified against real decrypted bytes - see lib/bktr.sh for the full
 * derivation and verification history, including the real bug this
 * project found and fixed (a wrong 0x4014/0x4010 "stride + overflow
 * entry" guess that read past the end of a real 29-bucket table -
 * the ACTUAL stride is a fixed 0x4000 bytes, no overflow room at all).
 */
#include "common.h"
#include "nca_common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static uint32_t le_u32_at(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t le_u64_at(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

/* cmd_bktr_relocations <table_file>
 * Prints one "<virt_offset> <phys_offset> <is_patch>" line per relocation
 * entry across EVERY bucket (in ascending virtual-offset order, which is
 * already the correct global order - see lib/bktr.sh's own comment for
 * why concatenating buckets in table order is safe), plus a final
 * synthetic line for total_size (is_patch field empty).
 *
 * Layout (hactool 1.4.0's bktr.h bktr_relocation_block_t/
 * bktr_relocation_bucket_t):
 *   Block header (0x10 bytes): u32 _0x0; u32 num_buckets; u64 total_size
 *   bucket_virtual_offsets[0x3FF0/8] (0x3FF0 bytes, ALWAYS this fixed
 *   size regardless of num_buckets) - bucket 0 starts at file offset
 *   0x10+0x3FF0=0x4000. Buckets are back-to-back after that, each at a
 *   FIXED stride of 0x4000 bytes (header 0x10 + entries[0x3FF0/20]=818
 *   entries of 20 bytes=16360 bytes + padding[8 bytes] = 0x4000 exactly -
 *   NO overflow entry, despite an earlier version of this project's own
 *   comment claiming otherwise):
 *     Bucket header (0x10 bytes): u32 _0x0; u32 num_entries; u64 virtual_offset_end
 *     entries[] (0x14 bytes each): u64 virt_offset; u64 phys_offset; u32 is_patch
 */
int cmd_bktr_relocations(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "usage: smtool bktr-relocations <table_file>\n");
        return 1;
    }
    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    unsigned char hdr[16];
    if (fread(hdr, 1, 16, f) != 16) {
        fprintf(stderr, "could not read BKTR relocation block header from %s\n", argv[0]);
        fclose(f);
        return 1;
    }
    uint32_t num_buckets = le_u32_at(hdr + 4);
    uint64_t total_size = le_u64_at(hdr + 8);

    const uint64_t bucket_stride = 0x4000;
    const uint64_t all_buckets_off = 0x10 + 0x3FF0;
    uint64_t all_buckets_size = (uint64_t)num_buckets * bucket_stride;

    unsigned char *buckets = malloc(all_buckets_size > 0 ? all_buckets_size : 1);
    if (!buckets) { fclose(f); return 1; }
    if (all_buckets_size > 0) {
        if (fseeko(f, (off_t)all_buckets_off, SEEK_SET) != 0 || fread(buckets, 1, all_buckets_size, f) != all_buckets_size) {
            fprintf(stderr, "could not read %llu bytes of relocation buckets from %s\n", (unsigned long long)all_buckets_size, argv[0]);
            free(buckets);
            fclose(f);
            return 1;
        }
    }
    fclose(f);

    for (uint32_t b = 0; b < num_buckets; b++) {
        const unsigned char *bucket = buckets + (uint64_t)b * bucket_stride;
        uint32_t num_entries = le_u32_at(bucket + 4);
        for (uint32_t i = 0; i < num_entries; i++) {
            const unsigned char *entry = bucket + 0x10 + (uint64_t)i * 0x14;
            uint64_t virt = le_u64_at(entry);
            uint64_t phys = le_u64_at(entry + 8);
            uint32_t is_patch = le_u32_at(entry + 16);
            printf("%llu %llu %u\n", (unsigned long long)virt, (unsigned long long)phys, is_patch);
        }
    }
    printf("%llu 0 \n", (unsigned long long)total_size);

    free(buckets);
    return 0;
}

/* cmd_bktr_subsections <table_file>
 * Prints one "<phys_offset> <ctr_val>" line per subsection entry across
 * EVERY bucket (ascending physical-offset order), plus a final synthetic
 * line for the LAST bucket's own physical_offset_end (ctr_val empty) -
 * only the last bucket's value is the true final physical end of the
 * whole table.
 *
 * Layout (hactool 1.4.0's bktr.h bktr_subsection_block_t/
 * bktr_subsection_bucket_t) - same fixed-size bucket_physical_offsets
 * array (0x3FF0 bytes) and same fixed 0x4000-byte stride as relocations
 * (header 0x10 + entries[0x3FF] of 16 bytes each = 0x10+0x3FF0=0x4000
 * exactly - no padding needed since 0x3FF0%16==0, no overflow entry):
 *   Block header (0x10 bytes): u32 _0x0; u32 num_buckets; u64 total_size
 *   Bucket 0 at 0x4000:
 *     Bucket header (0x10 bytes): u32 _0x0; u32 num_entries; u64 physical_offset_end
 *     entries[] (0x10 bytes each): u64 offset; u32 _0x8; u32 ctr_val
 */
int cmd_bktr_subsections(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "usage: smtool bktr-subsections <table_file>\n");
        return 1;
    }
    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    unsigned char hdr[16];
    if (fread(hdr, 1, 16, f) != 16) {
        fprintf(stderr, "could not read BKTR subsection block header from %s\n", argv[0]);
        fclose(f);
        return 1;
    }
    uint32_t num_buckets = le_u32_at(hdr + 4);

    const uint64_t bucket_stride = 0x4000;
    const uint64_t all_buckets_off = 0x10 + 0x3FF0;
    uint64_t all_buckets_size = (uint64_t)num_buckets * bucket_stride;

    unsigned char *buckets = malloc(all_buckets_size > 0 ? all_buckets_size : 1);
    if (!buckets) { fclose(f); return 1; }
    if (all_buckets_size > 0) {
        if (fseeko(f, (off_t)all_buckets_off, SEEK_SET) != 0 || fread(buckets, 1, all_buckets_size, f) != all_buckets_size) {
            fprintf(stderr, "could not read %llu bytes of subsection buckets from %s\n", (unsigned long long)all_buckets_size, argv[0]);
            free(buckets);
            fclose(f);
            return 1;
        }
    }
    fclose(f);

    uint64_t last_physical_offset_end = 0;
    for (uint32_t b = 0; b < num_buckets; b++) {
        const unsigned char *bucket = buckets + (uint64_t)b * bucket_stride;
        uint32_t num_entries = le_u32_at(bucket + 4);
        uint64_t physical_offset_end = le_u64_at(bucket + 8);
        last_physical_offset_end = physical_offset_end;
        for (uint32_t i = 0; i < num_entries; i++) {
            const unsigned char *entry = bucket + 0x10 + (uint64_t)i * 0x10;
            uint64_t off = le_u64_at(entry);
            uint32_t ctr_val = le_u32_at(entry + 12);
            printf("%llu %u\n", (unsigned long long)off, ctr_val);
        }
    }
    printf("%llu \n", (unsigned long long)last_physical_offset_end);

    free(buckets);
    return 0;
}

/* cmd_bktr_headers <nca_header_decrypted_file> --section <0-3>
 * Reads BKTR_RELOC_OFF/SIZE/BKTR_SUBSEC_OFF/SIZE from the bktr_superblock_t
 * that sits right after the section's IVFC integrity header in the FS
 * header - same fixed offsets (reloc at fs_hdr+0x100, subsec at
 * fs_hdr+0x120) lib/bktr.sh's bktr_headers uses, confirmed against real
 * update Program NCAs' own FS headers (this 0x100 offset is a 0x20-byte
 * gap from the end of the 0xE0-byte IVFC header that does NOT match
 * hactool's own nca.h "_0xE0[0x18]" padding-size comment literally - this
 * project trusts the offset confirmed against real bytes, not the
 * comment).
 *
 * Takes an ALREADY-DECRYPTED 0xC00-byte header file (e.g.
 * nca-header-decrypt's own output) rather than an NCA path + keys, since
 * this is pure struct reading with no crypto of its own - the caller
 * (switch-merge.sh, or a later phase's C code) decrypts the header once
 * via nca-header-decrypt and passes the result here, rather than this
 * subcommand re-deriving header_key and re-decrypting itself. */
int cmd_bktr_headers(int argc, char **argv) {
    const char *header_path = NULL, *section_str = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--section") == 0 && i + 1 < argc) { section_str = argv[++i]; }
        else if (!header_path) { header_path = argv[i]; }
    }
    if (!header_path || !section_str) {
        fprintf(stderr, "usage: smtool bktr-headers <decrypted_header_file> --section <0-3>\n");
        return 1;
    }
    char *end;
    long section_num = strtol(section_str, &end, 10);
    if (*end != '\0' || section_num < 0 || section_num > 3) {
        fprintf(stderr, "bktr-headers: invalid --section '%s' (must be 0-3)\n", section_str);
        return 1;
    }

    unsigned char header[0xC00];
    FILE *f = fopen(header_path, "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", header_path); return 1; }
    if (fread(header, 1, sizeof(header), f) != sizeof(header)) {
        fprintf(stderr, "could not read %zu-byte header from %s\n", sizeof(header), header_path);
        fclose(f);
        return 1;
    }
    fclose(f);

    size_t fs_hdr_off = 0x400 + (size_t)section_num * 0x200;
    size_t reloc_hdr_off = fs_hdr_off + 0x100;
    size_t subsec_hdr_off = fs_hdr_off + 0x120;

    if (memcmp(header + reloc_hdr_off + 16, "BKTR", 4) != 0 || memcmp(header + subsec_hdr_off + 16, "BKTR", 4) != 0) {
        fprintf(stderr, "bktr-headers: BKTR magic not found at expected offset in %s\n", header_path);
        return 1;
    }

    uint64_t reloc_off = le_u64_at(header + reloc_hdr_off);
    uint64_t reloc_size = le_u64_at(header + reloc_hdr_off + 8);
    uint64_t subsec_off = le_u64_at(header + subsec_hdr_off);
    uint64_t subsec_size = le_u64_at(header + subsec_hdr_off + 8);

    print_kv_u64("BKTR_RELOC_OFF", reloc_off);
    print_kv_u64("BKTR_RELOC_SIZE", reloc_size);
    print_kv_u64("BKTR_SUBSEC_OFF", subsec_off);
    print_kv_u64("BKTR_SUBSEC_SIZE", subsec_size);
    return 0;
}

/* --- In-process BKTR reconstruction (bktr_reconstruct) ---
 *
 * Reconstructs the FULL virtual romfs by walking the relocation table:
 * each relocation entry's byte range is copied either from the update
 * NCA's own physical romfs bytes (decrypted per-subsection, is_patch)
 * or straight from the base's already-decrypted romfs at the SAME
 * relocation-relative offset (not is_patch). A patch-type relocation
 * entry's physical byte range can itself span multiple subsections
 * (each with its own AES-CTR ctr_val), so each entry is further split
 * at every subsection boundary it crosses before decrypting - exact
 * port of lib/bktr.sh's own bktr_reconstruct, reusing this file's
 * already-verified table-parsing logic and nca_content.c's key/CTR
 * primitives in-process instead of driving them via subprocess calls. */

typedef struct { uint64_t virt, phys; uint32_t is_patch; } reloc_entry_t;
typedef struct { uint64_t off; uint32_t ctr_val; } subsec_entry_t;

/* read_relocation_table_mem <table_file> <**out_entries> <*out_count> <*out_total_size>
 * Same walk as cmd_bktr_relocations, but into an in-memory array plus a
 * trailing total_size value, instead of printing lines. */
static int read_relocation_table_mem(const char *table_path, reloc_entry_t **out_entries, size_t *out_count, uint64_t *out_total_size) {
    FILE *f = fopen(table_path, "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", table_path); return 1; }
    unsigned char hdr[16];
    if (fread(hdr, 1, 16, f) != 16) { fprintf(stderr, "could not read BKTR relocation block header\n"); fclose(f); return 1; }
    uint32_t num_buckets = le_u32_at(hdr + 4);
    uint64_t total_size = le_u64_at(hdr + 8);

    const uint64_t bucket_stride = 0x4000;
    const uint64_t all_buckets_off = 0x10 + 0x3FF0;
    uint64_t all_buckets_size = (uint64_t)num_buckets * bucket_stride;
    unsigned char *buckets = malloc(all_buckets_size > 0 ? all_buckets_size : 1);
    if (all_buckets_size > 0) {
        if (fseeko(f, (off_t)all_buckets_off, SEEK_SET) != 0 || fread(buckets, 1, all_buckets_size, f) != all_buckets_size) {
            fprintf(stderr, "could not read relocation buckets\n");
            free(buckets);
            fclose(f);
            return 1;
        }
    }
    fclose(f);

    size_t cap = 1024, count = 0;
    reloc_entry_t *entries = malloc(cap * sizeof(reloc_entry_t));
    for (uint32_t b = 0; b < num_buckets; b++) {
        const unsigned char *bucket = buckets + (uint64_t)b * bucket_stride;
        uint32_t num_entries = le_u32_at(bucket + 4);
        for (uint32_t i = 0; i < num_entries; i++) {
            if (count == cap) { cap *= 2; entries = realloc(entries, cap * sizeof(reloc_entry_t)); }
            const unsigned char *entry = bucket + 0x10 + (uint64_t)i * 0x14;
            entries[count].virt = le_u64_at(entry);
            entries[count].phys = le_u64_at(entry + 8);
            entries[count].is_patch = le_u32_at(entry + 16);
            count++;
        }
    }
    free(buckets);
    *out_entries = entries;
    *out_count = count;
    *out_total_size = total_size;
    return 0;
}

/* read_subsection_table_mem - same idea for the subsection table, plus
 * the LAST bucket's own physical_offset_end as a trailing sentinel
 * value (appended as one more entry with ctr_val unused, matching
 * lib/bktr.sh's own "num_subsec = count - 1" convention exactly). */
static int read_subsection_table_mem(const char *table_path, subsec_entry_t **out_entries, size_t *out_count) {
    FILE *f = fopen(table_path, "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", table_path); return 1; }
    unsigned char hdr[16];
    if (fread(hdr, 1, 16, f) != 16) { fprintf(stderr, "could not read BKTR subsection block header\n"); fclose(f); return 1; }
    uint32_t num_buckets = le_u32_at(hdr + 4);

    const uint64_t bucket_stride = 0x4000;
    const uint64_t all_buckets_off = 0x10 + 0x3FF0;
    uint64_t all_buckets_size = (uint64_t)num_buckets * bucket_stride;
    unsigned char *buckets = malloc(all_buckets_size > 0 ? all_buckets_size : 1);
    if (all_buckets_size > 0) {
        if (fseeko(f, (off_t)all_buckets_off, SEEK_SET) != 0 || fread(buckets, 1, all_buckets_size, f) != all_buckets_size) {
            fprintf(stderr, "could not read subsection buckets\n");
            free(buckets);
            fclose(f);
            return 1;
        }
    }
    fclose(f);

    size_t cap = 1024, count = 0;
    subsec_entry_t *entries = malloc(cap * sizeof(subsec_entry_t));
    uint64_t last_physical_offset_end = 0;
    for (uint32_t b = 0; b < num_buckets; b++) {
        const unsigned char *bucket = buckets + (uint64_t)b * bucket_stride;
        uint32_t num_entries = le_u32_at(bucket + 4);
        last_physical_offset_end = le_u64_at(bucket + 8);
        for (uint32_t i = 0; i < num_entries; i++) {
            if (count == cap) { cap *= 2; entries = realloc(entries, cap * sizeof(subsec_entry_t)); }
            const unsigned char *entry = bucket + 0x10 + (uint64_t)i * 0x10;
            entries[count].off = le_u64_at(entry);
            entries[count].ctr_val = le_u32_at(entry + 12);
            count++;
        }
    }
    free(buckets);

    if (count == cap) { cap += 1; entries = realloc(entries, cap * sizeof(subsec_entry_t)); }
    entries[count].off = last_physical_offset_end;
    entries[count].ctr_val = 0;
    count++;

    *out_entries = entries;
    *out_count = count;
    return 0;
}

/* cmd_bktr_reconstruct <update_nca> --keys <keys> --key-hex <hex32>
 *   --section <0-3> --base-romfs <path> -o <out_path>
 * update_nca/--section identify the update's own Program NCA and which
 * of its sections is the BKTR-delta romfs; --key-hex is the update's
 * own already-derived AES-CTR content key (from nca-content-key-
 * titlekey, same as every other content-key consumer in this project);
 * --base-romfs is the base Program NCA's own romfs SECTION already
 * decrypted to plaintext (e.g. via decrypt-section on the base's own
 * romfs section - NOT the whole NCA file). */
int cmd_bktr_reconstruct(int argc, char **argv) {
    const char *update_nca = NULL, *keys_path = NULL, *key_hex = NULL, *section_str = NULL, *base_romfs = NULL, *out_path = NULL;
    for (int i = 0; i < argc; i++) {
        if (strcmp(argv[i], "--keys") == 0 && i + 1 < argc) { keys_path = argv[++i]; }
        else if (strcmp(argv[i], "--key-hex") == 0 && i + 1 < argc) { key_hex = argv[++i]; }
        else if (strcmp(argv[i], "--section") == 0 && i + 1 < argc) { section_str = argv[++i]; }
        else if (strcmp(argv[i], "--base-romfs") == 0 && i + 1 < argc) { base_romfs = argv[++i]; }
        else if (strcmp(argv[i], "-o") == 0 && i + 1 < argc) { out_path = argv[++i]; }
        else if (!update_nca) { update_nca = argv[i]; }
    }
    if (!update_nca || !keys_path || !key_hex || !section_str || !base_romfs || !out_path) {
        fprintf(stderr, "usage: smtool bktr-reconstruct <update_nca> --keys <keys_file> --key-hex <hex32> --section <0-3> --base-romfs <path> -o <out_path>\n");
        return 1;
    }
    char *end;
    long section_num = strtol(section_str, &end, 10);
    if (*end != '\0' || section_num < 0 || section_num > 3) {
        fprintf(stderr, "bktr-reconstruct: invalid --section '%s'\n", section_str);
        return 1;
    }
    size_t key_len;
    unsigned char *key = hex_decode(key_hex, &key_len);
    if (!key || key_len != 16) {
        fprintf(stderr, "bktr-reconstruct: --key-hex must be 32 hex chars\n");
        free(key);
        return 1;
    }

    unsigned char header[NCA_HEADER_SIZE];
    if (nca_decrypt_header(update_nca, keys_path, header) != 0) { free(key); return 1; }

    size_t fs_hdr_off = 0x400 + (size_t)section_num * 0x200;
    size_t reloc_hdr_off = fs_hdr_off + 0x100;
    size_t subsec_hdr_off = fs_hdr_off + 0x120;
    if (memcmp(header + reloc_hdr_off + 16, "BKTR", 4) != 0 || memcmp(header + subsec_hdr_off + 16, "BKTR", 4) != 0) {
        fprintf(stderr, "bktr-reconstruct: BKTR magic not found at expected offset\n");
        free(key);
        return 1;
    }
    uint64_t reloc_off = le_u64_at(header + reloc_hdr_off);
    uint64_t reloc_size = le_u64_at(header + reloc_hdr_off + 8);
    uint64_t subsec_off = le_u64_at(header + subsec_hdr_off);
    uint64_t subsec_size = le_u64_at(header + subsec_hdr_off + 8);

    nca_section_info_t section_info;
    nca_section_info(header, (int)section_num, &section_info);
    if (!section_info.present) {
        fprintf(stderr, "bktr-reconstruct: section %ld not present in %s\n", section_num, update_nca);
        free(key);
        return 1;
    }
    uint64_t section_offset = section_info.offset;

    const unsigned char *section_ctr_raw = header + fs_hdr_off + 0x140;

    char reloc_table_path[600], subsec_table_path[600];
    make_scratch_template("smtool_bktr_reloc_", reloc_table_path, sizeof(reloc_table_path));
    make_scratch_template("smtool_bktr_subsec_", subsec_table_path, sizeof(subsec_table_path));
    int fd1 = mkstemp(reloc_table_path);
    int fd2 = mkstemp(subsec_table_path);
    if (fd1 < 0 || fd2 < 0) { fprintf(stderr, "bktr-reconstruct: mkstemp failed\n"); free(key); return 1; }
    close(fd1);
    close(fd2);

    unsigned char reloc_ctr[16], subsec_ctr[16];
    nca_content_ctr(section_ctr_raw, section_offset + reloc_off, reloc_ctr);
    nca_content_ctr(section_ctr_raw, section_offset + subsec_off, subsec_ctr);

    if (nca_ctr_decrypt_range(update_nca, key, reloc_ctr, section_offset + reloc_off, reloc_size, reloc_table_path) != 0 ||
        nca_ctr_decrypt_range(update_nca, key, subsec_ctr, section_offset + subsec_off, subsec_size, subsec_table_path) != 0) {
        fprintf(stderr, "bktr-reconstruct: failed to read relocation/subsection tables\n");
        remove(reloc_table_path);
        remove(subsec_table_path);
        free(key);
        return 1;
    }

    reloc_entry_t *reloc_entries; size_t reloc_count; uint64_t total_size;
    subsec_entry_t *subsec_entries; size_t subsec_count;
    int rc = read_relocation_table_mem(reloc_table_path, &reloc_entries, &reloc_count, &total_size);
    rc = rc || read_subsection_table_mem(subsec_table_path, &subsec_entries, &subsec_count);
    remove(reloc_table_path);
    remove(subsec_table_path);
    if (rc != 0) { free(key); return 1; }

    /* Add the synthetic trailing total_size entry to the relocation
     * array too, mirroring _bktr_parse_bucket0_relocations' own final
     * line - simplifies the chunk-boundary walk below (every REAL entry
     * has a "next" entry to compute chunk_len against, including the
     * last one). */
    reloc_entry_t *reloc_all = malloc((reloc_count + 1) * sizeof(reloc_entry_t));
    memcpy(reloc_all, reloc_entries, reloc_count * sizeof(reloc_entry_t));
    reloc_all[reloc_count].virt = total_size;
    reloc_all[reloc_count].phys = 0;
    reloc_all[reloc_count].is_patch = 0;
    free(reloc_entries);
    size_t reloc_total = reloc_count + 1;
    size_t num_subsec = subsec_count - 1; /* last entry is the trailing sentinel */

    FILE *out = fopen(out_path, "wb");
    if (!out) { fprintf(stderr, "bktr-reconstruct: could not open %s\n", out_path); free(reloc_all); free(subsec_entries); free(key); return 1; }
    fclose(out); /* truncate/create - subsequent writes append */

    FILE *base_f = fopen(base_romfs, "rb");
    if (!base_f) { fprintf(stderr, "bktr-reconstruct: could not open %s\n", base_romfs); free(reloc_all); free(subsec_entries); free(key); return 1; }

    int had_prev = 0;
    uint64_t prev_virt = 0, prev_phys = 0;
    uint32_t prev_is_patch = 0;
    int final_rc = 0;

    for (size_t idx = 0; idx < reloc_total && final_rc == 0; idx++) {
        uint64_t virt = reloc_all[idx].virt;
        uint64_t phys = reloc_all[idx].phys;
        uint32_t is_patch = reloc_all[idx].is_patch;

        if (had_prev) {
            uint64_t chunk_len = virt - prev_virt;
            if (prev_is_patch) {
                uint64_t chunk_start = prev_phys, chunk_end = prev_phys + chunk_len;
                uint64_t cur = chunk_start;
                while (cur < chunk_end) {
                    size_t si = 0;
                    while (si + 1 <= num_subsec && subsec_entries[si + 1].off <= cur) si++;
                    uint64_t subsec_end = subsec_entries[si + 1].off;
                    uint64_t read_end = chunk_end;
                    if (subsec_end < read_end) read_end = subsec_end;
                    uint64_t read_len = read_end - cur;

                    uint64_t phys_abs = section_offset + cur;
                    unsigned char chunk_ctr[16];
                    nca_content_ctr(section_ctr_raw, phys_abs, chunk_ctr);
                    /* ctr_val overwrites bytes 4-7 of the CTR (matches
                     * lib/bktr.sh's own "${ctr:0:8}${ctr_val_hex}${ctr:16:16}"
                     * text-splice exactly - big-endian 4-byte value at
                     * that position). */
                    uint32_t ctr_val = subsec_entries[si].ctr_val;
                    chunk_ctr[4] = (unsigned char)((ctr_val >> 24) & 0xFF);
                    chunk_ctr[5] = (unsigned char)((ctr_val >> 16) & 0xFF);
                    chunk_ctr[6] = (unsigned char)((ctr_val >> 8) & 0xFF);
                    chunk_ctr[7] = (unsigned char)(ctr_val & 0xFF);

                    if (nca_ctr_decrypt_range_append(update_nca, key, chunk_ctr, phys_abs, read_len, out_path) != 0) {
                        fprintf(stderr, "bktr-reconstruct: chunk decrypt failed\n");
                        final_rc = 1;
                        break;
                    }
                    cur = read_end;
                }
            } else {
                if (fseeko(base_f, (off_t)prev_phys, SEEK_SET) != 0) { final_rc = 1; break; }
                FILE *append = fopen(out_path, "ab");
                if (!append) { final_rc = 1; break; }
                unsigned char buf[1 << 20];
                uint64_t remaining = chunk_len;
                while (remaining > 0) {
                    size_t want = remaining < sizeof(buf) ? (size_t)remaining : sizeof(buf);
                    size_t got = fread(buf, 1, want, base_f);
                    if (got == 0) break;
                    fwrite(buf, 1, got, append);
                    remaining -= got;
                }
                fclose(append);
            }
        }
        prev_virt = virt; prev_phys = phys; prev_is_patch = is_patch;
        had_prev = 1;
    }

    fclose(base_f);
    free(reloc_all);
    free(subsec_entries);
    free(key);
    return final_rc;
}
