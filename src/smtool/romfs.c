/* romfs-extract / romfs-extract-all - ports lib/romfs.sh's RomFs reader.
 * Operates on an already-decrypted-to-disk RomFs data-layer blob (see
 * lib/nca_content.sh's nca_hierarchical_sha256_data_layer/
 * nca_hierarchical_integrity_data_layer, or their C equivalents once
 * Phase 5 lands, for how to slice this out of a decrypted NCA section).
 *
 * Layout (switchbrew.org/wiki/RomFS), exactly as documented in
 * lib/romfs.sh's own header comment:
 *   RomFsHeader (HeaderSize field confirms exactly 0x50 on every real
 *   file seen, though this trusts the field, not a hardcoded 0x50):
 *     0x00 (0x8) HeaderSize
 *     0x18 (0x8) DirTableOffset      0x20 (0x8) DirTableSize
 *     0x38 (0x8) FileTableOffset     0x40 (0x8) FileTableSize
 *     0x48 (0x8) DataOffset
 *   RomFsFileEntry (variable size, padded to a multiple of 4):
 *     +0x00 ParentDirOffset  +0x04 NextSiblingOffset
 *     +0x08 DataOffset(u64, relative to header's own DataOffset)
 *     +0x10 DataSize(u64)    +0x18 NameHash(u32, not read)
 *     +0x1C NameLength(u32)  +0x20 Name (NameLength bytes)
 *   RomFsDirectoryEntry (variable size, same padding rule):
 *     +0x00 ParentDirOffset  +0x04 NextSiblingOffset
 *     +0x08 FirstChildOffset +0x0C FirstFileOffset
 *     +0x10 NextDirHashOffset(not read) +0x14 NameLength +0x18 Name
 *   0xFFFFFFFF in a u32 field = sentinel ("no entry"/"end of list").
 *
 * romfs-extract only searches the root directory's files (flat lookup -
 * every real Control NCA's RomFs seen so far has every file directly in
 * the root, no subdirectories). romfs-extract-all walks the FULL
 * directory tree (needed for BKTR-reconstructed content, which can have
 * real subdirectories).
 */
#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>

#define SENTINEL 0xFFFFFFFFu

static uint32_t le_u32_at(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint64_t le_u64_at(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}

typedef struct {
    uint64_t dir_table_off, dir_table_size;
    uint64_t file_table_off, file_table_size;
    uint64_t data_base_off;
} romfs_header_t;

static int read_romfs_header(FILE *f, romfs_header_t *out) {
    unsigned char hdr[0x50];
    if (fseeko(f, 0, SEEK_SET) != 0 || fread(hdr, 1, 0x50, f) != 0x50) {
        fprintf(stderr, "could not read RomFs header\n");
        return 1;
    }
    out->dir_table_off = le_u64_at(hdr + 0x18);
    out->dir_table_size = le_u64_at(hdr + 0x20);
    out->file_table_off = le_u64_at(hdr + 0x38);
    out->file_table_size = le_u64_at(hdr + 0x40);
    out->data_base_off = le_u64_at(hdr + 0x48);
    return 0;
}

static unsigned char *read_table(FILE *f, uint64_t off, uint64_t size) {
    if (size == 0) return malloc(1);
    unsigned char *buf = malloc(size);
    if (!buf) return NULL;
    if (fseeko(f, (off_t)off, SEEK_SET) != 0 || fread(buf, 1, size, f) != size) {
        fprintf(stderr, "could not read table at offset %llu size %llu\n", (unsigned long long)off, (unsigned long long)size);
        free(buf);
        return NULL;
    }
    return buf;
}

static int stream_range_to_file(FILE *src, uint64_t src_off, uint64_t len, const char *out_path) {
    if (fseeko(src, (off_t)src_off, SEEK_SET) != 0) {
        fprintf(stderr, "could not seek to offset %llu\n", (unsigned long long)src_off);
        return 1;
    }
    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fprintf(stderr, "could not open %s for writing\n", out_path);
        return 1;
    }
    unsigned char buf[1 << 20];
    uint64_t remaining = len;
    int rc = 0;
    while (remaining > 0) {
        size_t chunk = remaining < sizeof(buf) ? (size_t)remaining : sizeof(buf);
        size_t got = fread(buf, 1, chunk, src);
        if (got == 0) { fprintf(stderr, "short read while copying to %s\n", out_path); rc = 1; break; }
        if (fwrite(buf, 1, got, out) != got) { fprintf(stderr, "short write to %s\n", out_path); rc = 1; break; }
        remaining -= got;
    }
    fclose(out);
    return rc;
}

int cmd_romfs_extract(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: smtool romfs-extract <romfs_file> <entry_name> <out_path>\n");
        return 1;
    }
    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    romfs_header_t hdr;
    if (read_romfs_header(f, &hdr) != 0) { fclose(f); return 1; }

    unsigned char *table = read_table(f, hdr.file_table_off, hdr.file_table_size);
    if (!table) { fclose(f); return 1; }

    int found = 0;
    uint64_t pos = 0;
    while (pos < hdr.file_table_size) {
        const unsigned char *entry = table + pos;
        uint64_t data_off = le_u64_at(entry + 0x08);
        uint64_t data_size = le_u64_at(entry + 0x10);
        uint32_t name_len = le_u32_at(entry + 0x1C);
        const char *name = (const char *)(entry + 0x20);

        if (name_len == strlen(argv[1]) && memcmp(name, argv[1], name_len) == 0) {
            found = 1;
            int rc = stream_range_to_file(f, hdr.data_base_off + data_off, data_size, argv[2]);
            free(table);
            fclose(f);
            return rc;
        }

        uint64_t entry_size = 0x20 + ((name_len + 3) & ~3u);
        pos += entry_size;
    }

    free(table);
    fclose(f);
    if (!found) fprintf(stderr, "romfs-extract: entry '%s' not found in %s\n", argv[1], argv[0]);
    return 1;
}

/* _romfs_extract_dir - recursive helper for romfs-extract-all: writes
 * every file directly under the directory entry at dir_off to out_dir,
 * then recurses into every subdirectory. */
static int extract_dir(FILE *f, const unsigned char *dir_table, const unsigned char *file_table,
                        uint32_t dir_off, const char *out_dir, uint64_t data_base_off) {
    if (mkdir(out_dir, 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "could not create directory %s\n", out_dir);
        return 1;
    }

    const unsigned char *dir_entry = dir_table + dir_off;
    uint32_t first_child = le_u32_at(dir_entry + 0x08);
    uint32_t first_file = le_u32_at(dir_entry + 0x0C);

    int rc = 0;

    uint32_t file_off = first_file;
    while (file_off != SENTINEL) {
        const unsigned char *file_entry = file_table + file_off;
        uint64_t data_off = le_u64_at(file_entry + 0x08);
        uint64_t data_size = le_u64_at(file_entry + 0x10);
        uint32_t name_len = le_u32_at(file_entry + 0x1C);
        const char *name = (const char *)(file_entry + 0x20);

        char out_path[4096];
        snprintf(out_path, sizeof(out_path), "%s/%.*s", out_dir, (int)name_len, name);
        if (stream_range_to_file(f, data_base_off + data_off, data_size, out_path) != 0) rc = 1;

        file_off = le_u32_at(file_entry + 0x04); /* NextSiblingOffset */
    }

    uint32_t child_off = first_child;
    while (child_off != SENTINEL) {
        const unsigned char *child_entry = dir_table + child_off;
        uint32_t name_len = le_u32_at(child_entry + 0x14);
        const char *name = (const char *)(child_entry + 0x18);

        char child_out_dir[4096];
        snprintf(child_out_dir, sizeof(child_out_dir), "%s/%.*s", out_dir, (int)name_len, name);
        if (extract_dir(f, dir_table, file_table, child_off, child_out_dir, data_base_off) != 0) rc = 1;

        child_off = le_u32_at(child_entry + 0x04); /* NextSiblingOffset */
    }

    return rc;
}

int cmd_romfs_extract_all(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: smtool romfs-extract-all <romfs_file> <out_dir>\n");
        return 1;
    }
    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    romfs_header_t hdr;
    if (read_romfs_header(f, &hdr) != 0) { fclose(f); return 1; }

    unsigned char *dir_table = read_table(f, hdr.dir_table_off, hdr.dir_table_size);
    unsigned char *file_table = read_table(f, hdr.file_table_off, hdr.file_table_size);
    if (!dir_table || !file_table) {
        free(dir_table);
        free(file_table);
        fclose(f);
        return 1;
    }

    int rc = extract_dir(f, dir_table, file_table, 0, argv[1], hdr.data_base_off);

    free(dir_table);
    free(file_table);
    fclose(f);
    return rc;
}
