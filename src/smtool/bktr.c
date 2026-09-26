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

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

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
