/* pfs0-list / pfs0-extract / pfs0-extract-all - ports the reader half of
 * lib/pfs0.sh (_pfs0_read_entries, pfs0_extract, pfs0_extract_all). The
 * writer half (pfs0_pack) is not ported in this phase - still bash-only,
 * used only by the NCA-building phases (7/8), which aren't in scope yet.
 *
 * Layout (switchbrew.org/wiki/NCA#PartitionFS, PFS0 variant), exactly as
 * documented in lib/pfs0.sh's own header comment:
 *   Header (0x10 bytes): Magic("PFS0") EntryCount(u32) StringTableSize(u32) Reserved(u32)
 *   PartitionEntry (0x18 bytes each): Offset(u64) Size(u64) StringTableOffset(u32) Reserved(u32)
 *   String table: EntryCount NUL-terminated filenames, padded to StringTableSize.
 *   File data: every file's raw bytes, in PartitionEntry order, no gaps.
 *
 * Streams the header/entry-table/string-table (always small) via a
 * bounded read, but never loads a whole NSP into memory to extract its
 * file data - real base-game NSPs run 1-15GB+, so every data-copying
 * function here seeks and streams with a fixed-size buffer instead of
 * malloc'ing the whole container (see lib/hfs0.sh's own header comment
 * for the same reasoning, shared verbatim - this file and hfs0.c were
 * ported together and hit the same "don't slurp a multi-GB file" design
 * point at the same time).
 */
#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <errno.h>
#include <libgen.h>

typedef struct {
    char *name;
    uint64_t offset;
    uint64_t size;
} pfs0_entry_t;

static uint64_t le_u64_at(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}
static uint32_t le_u32_at(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static void le_put_u32(unsigned char *out, uint32_t v) {
    out[0] = (unsigned char)(v & 0xFF);
    out[1] = (unsigned char)((v >> 8) & 0xFF);
    out[2] = (unsigned char)((v >> 16) & 0xFF);
    out[3] = (unsigned char)((v >> 24) & 0xFF);
}
static void le_put_u64(unsigned char *out, uint64_t v) {
    for (int i = 0; i < 8; i++) out[i] = (unsigned char)((v >> (i * 8)) & 0xFF);
}

/* Reads a PFS0 container's header+entry-table+string-table from an
 * already-open file at base_off. Returns a malloc'd array of entries
 * (caller frees each .name and the array), sets *out_count, and
 * *out_data_off to the ABSOLUTE offset (within the file) where file data
 * begins. Returns NULL on bad magic or a truncated table. */
static pfs0_entry_t *read_pfs0_entries(FILE *f, size_t base_off, size_t *out_count, size_t *out_data_off) {
    unsigned char hdr[16];
    if (fseeko(f, (off_t)base_off, SEEK_SET) != 0 || fread(hdr, 1, 16, f) != 16) {
        fprintf(stderr, "could not read PFS0 header at offset %zu\n", base_off);
        return NULL;
    }
    if (memcmp(hdr, "PFS0", 4) != 0) {
        fprintf(stderr, "not a PFS0 container (bad magic) at offset %zu\n", base_off);
        return NULL;
    }
    uint32_t entry_count = le_u32_at(hdr + 4);
    uint32_t string_table_size = le_u32_at(hdr + 8);

    size_t entry_table_size = (size_t)entry_count * 0x18;
    unsigned char *entry_table = malloc(entry_table_size > 0 ? entry_table_size : 1);
    unsigned char *string_table = malloc(string_table_size > 0 ? string_table_size : 1);
    if (!entry_table || !string_table) {
        free(entry_table);
        free(string_table);
        return NULL;
    }
    if (entry_table_size > 0 && fread(entry_table, 1, entry_table_size, f) != entry_table_size) {
        fprintf(stderr, "PFS0 entry table runs past end of file\n");
        free(entry_table);
        free(string_table);
        return NULL;
    }
    if (string_table_size > 0 && fread(string_table, 1, string_table_size, f) != string_table_size) {
        fprintf(stderr, "PFS0 string table runs past end of file\n");
        free(entry_table);
        free(string_table);
        return NULL;
    }

    pfs0_entry_t *entries = calloc(entry_count, sizeof(pfs0_entry_t));
    if (!entries) {
        free(entry_table);
        free(string_table);
        return NULL;
    }

    for (uint32_t i = 0; i < entry_count; i++) {
        const unsigned char *e = entry_table + (size_t)i * 0x18;
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

static void free_entries(pfs0_entry_t *entries, size_t count) {
    for (size_t i = 0; i < count; i++) free(entries[i].name);
    free(entries);
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

int cmd_pfs0_list(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "usage: smtool pfs0-list <path>\n");
        return 1;
    }
    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    size_t count, data_off;
    pfs0_entry_t *entries = read_pfs0_entries(f, 0, &count, &data_off);
    if (!entries) { fclose(f); return 1; }

    for (size_t i = 0; i < count; i++) {
        printf("%s %llu %llu\n", entries[i].name, (unsigned long long)entries[i].offset, (unsigned long long)entries[i].size);
    }

    free_entries(entries, count);
    fclose(f);
    return 0;
}

int cmd_pfs0_extract(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "usage: smtool pfs0-extract <path> <entry_name> <out_file>\n");
        return 1;
    }
    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    size_t count, data_off;
    pfs0_entry_t *entries = read_pfs0_entries(f, 0, &count, &data_off);
    if (!entries) { fclose(f); return 1; }

    int rc = 1;
    int found = 0;
    for (size_t i = 0; i < count; i++) {
        if (strcmp(entries[i].name, argv[1]) == 0) {
            found = 1;
            rc = stream_range_to_file(f, data_off + entries[i].offset, entries[i].size, argv[2]);
            break;
        }
    }
    if (!found) fprintf(stderr, "pfs0-extract: entry '%s' not found in %s\n", argv[1], argv[0]);

    free_entries(entries, count);
    fclose(f);
    return rc;
}

/* cmd_pfs0_pack <out_path> <file1> [file2] ...
 * Packs the given files (each contributes its own basename as its PFS0
 * entry name) into a PFS0 container at out_path - the write-side mirror
 * of read_pfs0_entries above, exact port of lib/pfs0.sh's pfs0_pack.
 * String table entries are 0x20-byte aligned in total (matches
 * hacPack's own rounding rule, confirmed necessary against real NSPs -
 * an unpadded string table produced a file nstool misparsed). File data
 * starts immediately after the (padded) string table, no further
 * alignment, back-to-back in argument order - confirmed against a real
 * NSP. */
int cmd_pfs0_pack(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: smtool pfs0-pack <out_path> <file1> [file2] ...\n");
        return 1;
    }
    const char *out_path = argv[0];
    int file_count = argc - 1;
    const char **files = (const char **)&argv[1];

    /* basename() may modify its argument on some platforms - copy first. */
    char **names = malloc(file_count * sizeof(char *));
    uint64_t *sizes = malloc(file_count * sizeof(uint64_t));
    uint32_t *str_offsets = malloc(file_count * sizeof(uint32_t));
    uint32_t cur_str_off = 0;

    for (int i = 0; i < file_count; i++) {
        char *copy = strdup(files[i]);
        char *base = basename(copy);
        names[i] = strdup(base);
        free(copy);

        struct stat st;
        if (stat(files[i], &st) != 0) {
            fprintf(stderr, "pfs0-pack: could not stat %s\n", files[i]);
            return 1;
        }
        sizes[i] = (uint64_t)st.st_size;

        str_offsets[i] = cur_str_off;
        cur_str_off += (uint32_t)strlen(names[i]) + 1;
    }
    uint32_t string_table_size = (cur_str_off + 0x1F) & ~0x1Fu;
    uint32_t pad_bytes = string_table_size - cur_str_off;

    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fprintf(stderr, "pfs0-pack: could not open %s for writing\n", out_path);
        return 1;
    }

    unsigned char header[16];
    memcpy(header, "PFS0", 4);
    le_put_u32(header + 4, (uint32_t)file_count);
    le_put_u32(header + 8, string_table_size);
    le_put_u32(header + 12, 0);
    fwrite(header, 1, 16, out);

    uint64_t data_off = 0;
    for (int i = 0; i < file_count; i++) {
        unsigned char entry[0x18];
        le_put_u64(entry, data_off);
        le_put_u64(entry + 8, sizes[i]);
        le_put_u32(entry + 16, str_offsets[i]);
        le_put_u32(entry + 20, 0);
        fwrite(entry, 1, sizeof(entry), out);
        data_off += sizes[i];
    }

    for (int i = 0; i < file_count; i++) {
        fwrite(names[i], 1, strlen(names[i]) + 1, out); /* include NUL terminator */
    }
    if (pad_bytes > 0) {
        unsigned char z = 0;
        for (uint32_t i = 0; i < pad_bytes; i++) fwrite(&z, 1, 1, out);
    }

    for (int i = 0; i < file_count; i++) {
        FILE *src = fopen(files[i], "rb");
        if (!src) {
            fprintf(stderr, "pfs0-pack: could not open %s\n", files[i]);
            fclose(out);
            return 1;
        }
        unsigned char buf[1 << 20];
        size_t got;
        while ((got = fread(buf, 1, sizeof(buf), src)) > 0) fwrite(buf, 1, got, out);
        fclose(src);
    }

    fclose(out);
    for (int i = 0; i < file_count; i++) free(names[i]);
    free(names);
    free(sizes);
    free(str_offsets);
    return 0;
}

int cmd_pfs0_extract_all(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: smtool pfs0-extract-all <path> <out_dir>\n");
        return 1;
    }
    FILE *f = fopen(argv[0], "rb");
    if (!f) { fprintf(stderr, "could not open %s\n", argv[0]); return 1; }

    size_t count, data_off;
    pfs0_entry_t *entries = read_pfs0_entries(f, 0, &count, &data_off);
    if (!entries) { fclose(f); return 1; }

    if (mkdir(argv[1], 0755) != 0 && errno != EEXIST) {
        fprintf(stderr, "could not create output directory %s\n", argv[1]);
        free_entries(entries, count);
        fclose(f);
        return 1;
    }

    int rc = 0;
    for (size_t i = 0; i < count; i++) {
        char out_path[4096];
        snprintf(out_path, sizeof(out_path), "%s/%s", argv[1], entries[i].name);
        if (stream_range_to_file(f, data_off + entries[i].offset, entries[i].size, out_path) != 0) rc = 1;
    }

    free_entries(entries, count);
    fclose(f);
    return rc;
}
