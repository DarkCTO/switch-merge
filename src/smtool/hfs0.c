/* hfs0-list / hfs0-extract-all - ports lib/hfs0.sh's reader
 * (_hfs0_read_entries, hfs0_extract_all). HFS0 is PFS0's hashed sibling
 * (XCI partitions use it) - same flat shape, bigger 0x40-byte entry.
 *
 * Layout (switchbrew.org/wiki/XCI "HFS0" partition format), exactly as
 * documented in lib/hfs0.sh's own header comment:
 *   Header (0x10 bytes): Magic("HFS0") EntryCount(u32) StringTableSize(u32) Reserved(u32)
 *   HfsEntry (0x40 bytes each): Offset(u64) Size(u64) StringTableOffset(u32)
 *     HashedDataSize(u32) Reserved(u32) Reserved(u32) Hash[0x20]
 *   String table: EntryCount NUL-terminated filenames, padded to StringTableSize.
 *   File data: every file's raw bytes, in entry order, no gaps.
 *
 * The header does not have to sit at the start of the file - an XCI's
 * root/secure/etc. HFS0 headers each start at some offset read from an
 * outer header - so every subcommand here takes an explicit header
 * offset argument, unlike PFS0 (which is always the whole file).
 *
 * Streams the header/entry-table/string-table (always small - at most a
 * few hundred entries) via a bounded read, but never loads a whole XCI
 * into memory to extract its file data - a real XCI's "secure" partition
 * alone can be multi-GB, and this project's own base-game NSPs run
 * 1-15GB+, so every data-copying function here seeks and streams with a
 * fixed-size buffer instead of malloc'ing the whole container.
 */
#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>

typedef struct {
    char *name;
    uint64_t offset;
    uint64_t size;
} hfs0_entry_t;

static uint64_t le_u64_at(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}
static uint32_t le_u32_at(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

/* Reads just the HFS0 header + entry table + string table starting at
 * base_off within an already-open file (bounded size - EntryCount and
 * StringTableSize are both u32 fields read from the file itself, so a
 * malformed/truncated file is caught by the fread() length checks below,
 * not assumed safe). Returns a malloc'd array of entries (caller frees
 * each .name and the array), sets *out_count, and *out_data_off to the
 * ABSOLUTE offset (within the file) where file data begins. Returns
 * NULL on bad magic, a truncated table, or an I/O error. */
static hfs0_entry_t *read_hfs0_entries(FILE *f, size_t base_off, size_t *out_count, size_t *out_data_off) {
    unsigned char hdr[16];
    if (fseeko(f, (off_t)base_off, SEEK_SET) != 0 || fread(hdr, 1, 16, f) != 16) {
        fprintf(stderr, "could not read HFS0 header at offset %zu\n", base_off);
        return NULL;
    }
    if (memcmp(hdr, "HFS0", 4) != 0) {
        fprintf(stderr, "not an HFS0 container (bad magic) at offset %zu\n", base_off);
        return NULL;
    }
    uint32_t entry_count = le_u32_at(hdr + 4);
    uint32_t string_table_size = le_u32_at(hdr + 8);

    size_t entry_table_size = (size_t)entry_count * 0x40;
    unsigned char *entry_table = malloc(entry_table_size > 0 ? entry_table_size : 1);
    unsigned char *string_table = malloc(string_table_size > 0 ? string_table_size : 1);
    if (!entry_table || !string_table) {
        free(entry_table);
        free(string_table);
        return NULL;
    }
    if (entry_table_size > 0 && fread(entry_table, 1, entry_table_size, f) != entry_table_size) {
        fprintf(stderr, "HFS0 entry table runs past end of file\n");
        free(entry_table);
        free(string_table);
        return NULL;
    }
    if (string_table_size > 0 && fread(string_table, 1, string_table_size, f) != string_table_size) {
        fprintf(stderr, "HFS0 string table runs past end of file\n");
        free(entry_table);
        free(string_table);
        return NULL;
    }

    hfs0_entry_t *entries = calloc(entry_count, sizeof(hfs0_entry_t));
    if (!entries) {
        free(entry_table);
        free(string_table);
        return NULL;
    }

    for (uint32_t i = 0; i < entry_count; i++) {
        const unsigned char *e = entry_table + (size_t)i * 0x40;
        uint64_t off = le_u64_at(e);
        uint64_t sz = le_u64_at(e + 8);
        uint32_t str_off = le_u32_at(e + 16);

        size_t max_len = str_off < string_table_size ? string_table_size - str_off : 0;
        size_t name_len = strnlen((const char *)string_table + str_off, max_len);

        entries[i].name = malloc(name_len + 1);
        memcpy(entries[i].name, string_table + str_off, name_len);
        entries[i].name[name_len] = '\0';
        entries[i].offset = off;
        entries[i].size = sz;
    }

    free(entry_table);
    free(string_table);

    *out_count = entry_count;
    *out_data_off = base_off + 16 + entry_table_size + string_table_size;
    return entries;
}

static void free_entries(hfs0_entry_t *entries, size_t count) {
    for (size_t i = 0; i < count; i++) free(entries[i].name);
    free(entries);
}

/* Streams len bytes from src (already open), starting at src_off, to a
 * newly-created out_path - fixed-size buffer, never the whole range in
 * memory at once. */
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
        if (got == 0) {
            fprintf(stderr, "short read while copying to %s\n", out_path);
            rc = 1;
            break;
        }
        if (fwrite(buf, 1, got, out) != got) {
            fprintf(stderr, "short write to %s\n", out_path);
            rc = 1;
            break;
        }
        remaining -= got;
    }
    fclose(out);
    return rc;
}

static int parse_offset_arg(const char *s, size_t *out) {
    char *end;
    unsigned long long v = strtoull(s, &end, 0);
    if (*end != '\0') return 1;
    *out = (size_t)v;
    return 0;
}

int cmd_hfs0_data_off(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: smtool hfs0-data-off <path> <header_offset>\n");
        return 1;
    }
    size_t header_offset;
    if (parse_offset_arg(argv[1], &header_offset) != 0) {
        fprintf(stderr, "hfs0-data-off: invalid header_offset '%s'\n", argv[1]);
        return 1;
    }

    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    size_t count, data_off;
    hfs0_entry_t *entries = read_hfs0_entries(f, header_offset, &count, &data_off);
    if (!entries) { fclose(f); return 1; }

    printf("%llu\n", (unsigned long long)data_off);

    free_entries(entries, count);
    fclose(f);
    return 0;
}

int cmd_hfs0_list(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: smtool hfs0-list <path> <header_offset>\n");
        return 1;
    }
    size_t header_offset;
    if (parse_offset_arg(argv[1], &header_offset) != 0) {
        fprintf(stderr, "hfs0-list: invalid header_offset '%s'\n", argv[1]);
        return 1;
    }

    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    size_t count, data_off;
    hfs0_entry_t *entries = read_hfs0_entries(f, header_offset, &count, &data_off);
    if (!entries) { fclose(f); return 1; }

    for (size_t i = 0; i < count; i++) {
        printf("%s %llu %llu\n", entries[i].name, (unsigned long long)entries[i].offset, (unsigned long long)entries[i].size);
    }

    free_entries(entries, count);
    fclose(f);
    return 0;
}

int cmd_hfs0_extract_all(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: smtool hfs0-extract-all <path> <header_offset> <out_dir>\n");
        return 1;
    }
    size_t header_offset;
    if (parse_offset_arg(argv[1], &header_offset) != 0) {
        fprintf(stderr, "hfs0-extract-all: invalid header_offset '%s'\n", argv[1]);
        return 1;
    }

    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    size_t count, data_off;
    hfs0_entry_t *entries = read_hfs0_entries(f, header_offset, &count, &data_off);
    if (!entries) { fclose(f); return 1; }

    if (mkdir(argv[2], 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "could not create output directory %s\n", argv[2]);
        free_entries(entries, count);
        fclose(f);
        return 1;
    }

    int rc = 0;
    for (size_t i = 0; i < count; i++) {
        char out_path[4096];
        snprintf(out_path, sizeof(out_path), "%s/%s", argv[2], entries[i].name);
        if (stream_range_to_file(f, data_off + entries[i].offset, entries[i].size, out_path) != 0) rc = 1;
    }

    free_entries(entries, count);
    fclose(f);
    return rc;
}
