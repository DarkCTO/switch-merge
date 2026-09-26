/* romfs-build - ports lib/romfs_build.sh (a pure port of hacpack's own
 * romfs_build, romfs.c) - builds a complete romfs container from a real
 * directory tree.
 *
 * WHY THIS EXISTS, AND WHY A SIMPLER SHORTCUT DOESN'T WORK: reusing
 * already-reconstructed BKTR romfs bytes directly (skip rebuilding the
 * container, just re-hash it) does NOT reproduce hacpack's own
 * --romfsdir rebuild byte-for-byte - hacpack's own romfs_build
 * independently re-derives the entire directory/file table AND
 * file-data-partition layout from its own directory walk, and a real
 * Nintendo-built romfs's on-disk file order doesn't have to match (and
 * in practice doesn't) hacpack's own alphabetical rebuild order. See
 * lib/romfs_build.sh's own header comment for the full story (confirmed
 * by directly extracting hacpack's own intermediate pre-hash romfs file
 * and finding the file-partition layout differed by thousands of bytes
 * despite identical file content).
 *
 * ALGORITHM (derived directly from hacpack 1.36_r2's own romfs.c/romfs.h -
 * NOT documented anywhere else in this operational detail):
 *   1. Recursively walk the input directory. Build TWO orderings, both
 *      by plain byte comparison (strcmp) on each entry's own FULL path
 *      from the root, NOT filesystem/readdir order:
 *        - "sibling" order: only entries within the SAME parent
 *          directory - becomes each directory's own child/file list.
 *        - "next" order: EVERY directory (resp. file) in the ENTIRE
 *          tree, in one single GLOBAL sorted order - used ONLY for
 *          entry_offset assignment and file-partition offset
 *          assignment. A DIFFERENT ordering from the sibling order
 *          despite using the same comparator.
 *   2. Assign each file its own file_partition offset by walking the
 *      global "next" order, accumulating size + align-to-0x10 gaps.
 *   3. Assign each directory/file its own entry_offset (position within
 *      the flat entry table) by walking the same global "next" order.
 *   4. Build two hash tables (odd bucket count avoiding small prime
 *      factors 2/3/5/7/11/13/17, NOT simply the entry count), populated
 *      by walking the SAME global "next" order and chaining collisions
 *      through each entry's own hash field.
 *   5. Write header + dir hash table + dir table + file hash table +
 *      file table + (0x200-aligned) file data partition, then pad the
 *      WHOLE output to a 0x4000 (IVFC_HASH_BLOCK_SIZE) boundary - a
 *      separate step from every other padding rule here.
 *
 * Root directory has an empty name (name_size=0) and entry_offset 0,
 * matching hacpack's own root_ctx handling exactly (root_ctx->parent =
 * root_ctx itself - its OWN entry_offset, 0, is what "parent" points to
 * for root).
 */
#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <dirent.h>
#include <sys/stat.h>
#include <sys/types.h>

#define SENTINEL 0xFFFFFFFFu

typedef struct entry {
    char *path;          /* full romfs-relative path, e.g. "/Data/foo.bin" */
    char *name;          /* basename only */
    int is_dir;
    uint32_t entry_offset;
    uint64_t file_size;         /* files only */
    uint64_t file_partition_offset; /* files only */
    uint32_t parent_offset;
    uint32_t sibling_offset;    /* next sibling within same parent, SENTINEL if none */
    uint32_t child_offset;      /* dirs only: first child dir, SENTINEL if none */
    uint32_t first_file_offset; /* dirs only: first file, SENTINEL if none */
    uint32_t hash_chain;        /* previous entry with same hash bucket, SENTINEL if none */
    struct entry *parent;       /* pointer to parent entry, for path-hash of parent_offset */
    int last_child_set;
    uint32_t last_child_idx;    /* dirs.entries index of the last-linked child dir */
    int last_file_set;
    uint32_t last_file_idx;     /* files.entries index of the last-linked child file */
} entry_t;

typedef struct {
    entry_t *entries;
    size_t count, cap;
} entry_list_t;

static void list_init(entry_list_t *l) { l->entries = NULL; l->count = 0; l->cap = 0; }
static entry_t *list_push(entry_list_t *l) {
    if (l->count == l->cap) {
        l->cap = l->cap ? l->cap * 2 : 16;
        l->entries = realloc(l->entries, l->cap * sizeof(entry_t));
    }
    memset(&l->entries[l->count], 0, sizeof(entry_t));
    return &l->entries[l->count++];
}

static int cmp_path(const void *a, const void *b) {
    const entry_t *ea = *(const entry_t **)a;
    const entry_t *eb = *(const entry_t **)b;
    return strcmp(ea->path, eb->path);
}

/* Recursively walks in_dir, appending every directory and file entry
 * (full romfs-relative path, e.g. rel_path + "/" + name) to dirs/files.
 * Does NOT sort or link anything yet - just enumeration. */
static int walk_dir(const char *base_dir, const char *rel_path, entry_list_t *dirs, entry_list_t *files) {
    char full_path[4096];
    snprintf(full_path, sizeof(full_path), "%s%s", base_dir, rel_path);

    DIR *d = opendir(full_path);
    if (!d) {
        fprintf(stderr, "romfs-build: could not open directory %s\n", full_path);
        return 1;
    }

    struct dirent *de;
    while ((de = readdir(d)) != NULL) {
        if (strcmp(de->d_name, ".") == 0 || strcmp(de->d_name, "..") == 0) continue;

        char child_full[8192], child_rel[8192];
        snprintf(child_full, sizeof(child_full), "%s/%s", full_path, de->d_name);
        snprintf(child_rel, sizeof(child_rel), "%s/%s", rel_path, de->d_name);

        struct stat st;
        if (stat(child_full, &st) != 0) {
            fprintf(stderr, "romfs-build: could not stat %s\n", child_full);
            closedir(d);
            return 1;
        }

        if (S_ISDIR(st.st_mode)) {
            entry_t *e = list_push(dirs);
            e->path = strdup(child_rel);
            e->name = strdup(de->d_name);
            e->is_dir = 1;
            if (walk_dir(base_dir, child_rel, dirs, files) != 0) {
                closedir(d);
                return 1;
            }
        } else if (S_ISREG(st.st_mode)) {
            entry_t *e = list_push(files);
            e->path = strdup(child_rel);
            e->name = strdup(de->d_name);
            e->is_dir = 0;
            e->file_size = (uint64_t)st.st_size;
        }
    }
    closedir(d);
    return 0;
}

static uint32_t align_u32(uint32_t v, uint32_t alignment) {
    return (v + alignment - 1) & ~(alignment - 1);
}
static uint64_t align_u64(uint64_t v, uint64_t alignment) {
    return (v + alignment - 1) & ~(alignment - 1);
}

/* romfs_get_hash_table_count - mirrors hacpack's own function exactly:
 * an odd bucket count chosen to avoid small prime factors, NOT simply
 * the entry count. */
static uint32_t hash_table_count(uint32_t n) {
    if (n < 3) return 3;
    if (n < 19) return n | 1;
    uint32_t count = n;
    while (count % 2 == 0 || count % 3 == 0 || count % 5 == 0 ||
           count % 7 == 0 || count % 11 == 0 || count % 13 == 0 || count % 17 == 0) {
        count++;
    }
    return count;
}

/* calc_path_hash - mirrors hacpack's own calc_path_hash exactly:
 * parent^123456789, then for each byte of name: rotate-right-5 (32-bit)
 * then XOR in the byte. */
static uint32_t path_hash(uint32_t parent, const char *name) {
    uint32_t hash = parent ^ 123456789u;
    for (const unsigned char *p = (const unsigned char *)name; *p; p++) {
        hash = ((hash >> 5) | (hash << 27));
        hash ^= *p;
    }
    return hash;
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

int cmd_romfs_build(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr, "usage: smtool romfs-build <in_dir> <out_path>\n");
        return 1;
    }
    const char *in_dir = argv[0];
    const char *out_path = argv[1];

    entry_list_t dirs, files;
    list_init(&dirs);
    list_init(&files);

    if (walk_dir(in_dir, "", &dirs, &files) != 0) {
        return 1;
    }

    /* --- Step 1: global "next" sort order, both lists independently --- */
    entry_t **dir_sorted = malloc(dirs.count * sizeof(entry_t *));
    entry_t **file_sorted = malloc(files.count * sizeof(entry_t *));
    for (size_t i = 0; i < dirs.count; i++) dir_sorted[i] = &dirs.entries[i];
    for (size_t i = 0; i < files.count; i++) file_sorted[i] = &files.entries[i];
    qsort(dir_sorted, dirs.count, sizeof(entry_t *), cmp_path);
    qsort(file_sorted, files.count, sizeof(entry_t *), cmp_path);

    /* --- Step 2: assign entry_offset by walking global "next" order,
     * root first (offset 0, size 0x18, no name) --- */
    uint32_t entry_off = 0x18; /* root's own size */
    for (size_t i = 0; i < dirs.count; i++) {
        dir_sorted[i]->entry_offset = entry_off;
        entry_off += 0x18 + align_u32((uint32_t)strlen(dir_sorted[i]->name), 4);
    }
    uint32_t dir_table_size = entry_off;

    entry_off = 0;
    for (size_t i = 0; i < files.count; i++) {
        file_sorted[i]->entry_offset = entry_off;
        entry_off += 0x20 + align_u32((uint32_t)strlen(file_sorted[i]->name), 4);
    }
    uint32_t file_table_size = entry_off;

    /* --- Step 3: file-partition offsets, same global order, 0x10-aligned --- */
    uint64_t partition_size = 0;
    for (size_t i = 0; i < files.count; i++) {
        partition_size = align_u64(partition_size, 16);
        file_sorted[i]->file_partition_offset = partition_size;
        partition_size += file_sorted[i]->file_size;
    }

    /* --- Step 4: per-directory child/file/sibling chains, and parent
     * lookups (needed for path_hash) - map each path to its own entry,
     * find each entry's parent by dirname, in the SAME sorted order (a
     * subset of a sorted list stays sorted, no re-sort needed). --- */
    /* Root's own synthetic entry_offset is 0, name "". */
    uint32_t root_child = SENTINEL, root_file = SENTINEL;
    uint32_t root_last_child = SENTINEL, root_last_file = SENTINEL;

    /* dirname/basename split - find each entry's parent dir by exact
     * path match (linear scan is fine, real romfs trees here are small -
     * icons + control.nacp for Control NCAs, a few hundred files for a
     * game's BKTR-reconstructed content). */
    for (size_t i = 0; i < dirs.count; i++) {
        entry_t *e = dir_sorted[i];
        e->child_offset = SENTINEL;
        e->first_file_offset = SENTINEL;
    }

    /* parent_path helper inline (no separate function needed for this
     * scope) - dirname("/a/b/c") = "/a/b", or "" for a top-level entry
     * (which then means parent is root). */
    for (size_t i = 0; i < dirs.count; i++) {
        entry_t *e = dir_sorted[i];
        char parent_path[4096];
        strncpy(parent_path, e->path, sizeof(parent_path) - 1);
        parent_path[sizeof(parent_path) - 1] = '\0';
        char *slash = strrchr(parent_path, '/');
        *slash = '\0'; /* strip trailing "/name", leaving parent path or "" */

        uint32_t parent_off;
        entry_t *parent_entry = NULL;
        if (parent_path[0] == '\0') {
            parent_off = 0; /* root */
        } else {
            for (size_t j = 0; j < dirs.count; j++) {
                if (strcmp(dirs.entries[j].path, parent_path) == 0) { parent_entry = &dirs.entries[j]; break; }
            }
            if (!parent_entry) {
                fprintf(stderr, "romfs-build: internal error, parent dir not found for %s\n", e->path);
                return 1;
            }
            parent_off = parent_entry->entry_offset;
        }
        e->parent_offset = parent_off;
        e->parent = parent_entry;
        e->sibling_offset = SENTINEL;

        if (parent_entry) {
            if (parent_entry->last_child_set) {
                dirs.entries[parent_entry->last_child_idx].sibling_offset = e->entry_offset;
            } else {
                parent_entry->child_offset = e->entry_offset;
            }
            parent_entry->last_child_idx = (uint32_t)(e - dirs.entries);
            parent_entry->last_child_set = 1;
        } else {
            if (root_last_child != SENTINEL) {
                for (size_t j = 0; j < dirs.count; j++) {
                    if (dirs.entries[j].entry_offset == root_last_child) { dirs.entries[j].sibling_offset = e->entry_offset; break; }
                }
            } else {
                root_child = e->entry_offset;
            }
            root_last_child = e->entry_offset;
        }
    }

    for (size_t i = 0; i < files.count; i++) {
        entry_t *e = file_sorted[i];
        char parent_path[4096];
        strncpy(parent_path, e->path, sizeof(parent_path) - 1);
        parent_path[sizeof(parent_path) - 1] = '\0';
        char *slash = strrchr(parent_path, '/');
        *slash = '\0';

        uint32_t parent_off;
        entry_t *parent_entry = NULL;
        if (parent_path[0] == '\0') {
            parent_off = 0;
        } else {
            for (size_t j = 0; j < dirs.count; j++) {
                if (strcmp(dirs.entries[j].path, parent_path) == 0) { parent_entry = &dirs.entries[j]; break; }
            }
            if (!parent_entry) {
                fprintf(stderr, "romfs-build: internal error, parent dir not found for %s\n", e->path);
                return 1;
            }
            parent_off = parent_entry->entry_offset;
        }
        e->parent_offset = parent_off;
        e->parent = parent_entry;
        e->sibling_offset = SENTINEL;

        if (parent_entry) {
            if (parent_entry->last_file_set) {
                files.entries[parent_entry->last_file_idx].sibling_offset = e->entry_offset;
            } else {
                parent_entry->first_file_offset = e->entry_offset;
            }
            parent_entry->last_file_idx = (uint32_t)(e - files.entries);
            parent_entry->last_file_set = 1;
        } else {
            if (root_last_file != SENTINEL) {
                for (size_t j = 0; j < files.count; j++) {
                    if (files.entries[j].entry_offset == root_last_file) { files.entries[j].sibling_offset = e->entry_offset; break; }
                }
            } else {
                root_file = e->entry_offset;
            }
            root_last_file = e->entry_offset;
        }
    }

    /* --- Step 5: hash tables --- */
    uint32_t dir_hash_count = hash_table_count((uint32_t)dirs.count + 1);
    uint32_t file_hash_count = hash_table_count((uint32_t)files.count);
    uint32_t *dir_hash_table = malloc(dir_hash_count * sizeof(uint32_t));
    uint32_t *file_hash_table = malloc(file_hash_count * sizeof(uint32_t));
    for (uint32_t i = 0; i < dir_hash_count; i++) dir_hash_table[i] = SENTINEL;
    for (uint32_t i = 0; i < file_hash_count; i++) file_hash_table[i] = SENTINEL;

    uint32_t root_hash_chain;
    {
        uint32_t h = path_hash(0, "");
        uint32_t b = h % dir_hash_count;
        root_hash_chain = dir_hash_table[b];
        dir_hash_table[b] = 0;
    }
    for (size_t i = 0; i < dirs.count; i++) {
        entry_t *e = dir_sorted[i];
        uint32_t h = path_hash(e->parent_offset, e->name);
        uint32_t b = h % dir_hash_count;
        e->hash_chain = dir_hash_table[b];
        dir_hash_table[b] = e->entry_offset;
    }
    for (size_t i = 0; i < files.count; i++) {
        entry_t *e = file_sorted[i];
        uint32_t h = path_hash(e->parent_offset, e->name);
        uint32_t b = h % file_hash_count;
        e->hash_chain = file_hash_table[b];
        file_hash_table[b] = e->entry_offset;
    }

    /* --- Step 6: assemble and write --- */
    uint32_t dir_hash_table_size = dir_hash_count * 4;
    uint32_t file_hash_table_size = file_hash_count * 4;
    uint64_t file_partition_ofs = 0x200;
    uint64_t dir_hash_table_ofs = file_partition_ofs + partition_size;
    uint64_t dir_table_ofs = dir_hash_table_ofs + dir_hash_table_size;
    uint64_t file_hash_table_ofs = dir_table_ofs + dir_table_size;
    uint64_t file_table_ofs = file_hash_table_ofs + file_hash_table_size;

    FILE *out = fopen(out_path, "wb");
    if (!out) {
        fprintf(stderr, "romfs-build: could not open %s for writing\n", out_path);
        return 1;
    }

    /* RomFsHeader layout (switchbrew.org/wiki/RomFS, exactly as
     * documented in lib/romfs.sh's own header comment - the READING
     * half's already-verified field offsets, which this WRITING half
     * must match exactly since lib/romfs.sh's own reader is what
     * verifies this file's output):
     *   0x00 HeaderSize   0x08 DirHashTableOffset  0x10 DirHashTableSize
     *   0x18 DirTableOffset  0x20 DirTableSize
     *   0x28 FileHashTableOffset  0x30 FileHashTableSize
     *   0x38 FileTableOffset  0x40 FileTableSize  0x48 DataOffset */
    unsigned char header[0x50] = {0};
    le_put_u64(header + 0x00, 0x50);
    le_put_u64(header + 0x08, dir_hash_table_ofs);
    le_put_u64(header + 0x10, dir_hash_table_size);
    le_put_u64(header + 0x18, dir_table_ofs);
    le_put_u64(header + 0x20, dir_table_size);
    le_put_u64(header + 0x28, file_hash_table_ofs);
    le_put_u64(header + 0x30, file_hash_table_size);
    le_put_u64(header + 0x38, file_table_ofs);
    le_put_u64(header + 0x40, file_table_size);
    le_put_u64(header + 0x48, file_partition_ofs);
    fwrite(header, 1, sizeof(header), out);

    long pos = ftell(out);
    long pad = (long)file_partition_ofs - pos;
    if (pad > 0) { unsigned char z = 0; for (long i = 0; i < pad; i++) fwrite(&z, 1, 1, out); }

    uint64_t cur = 0;
    for (size_t i = 0; i < files.count; i++) {
        entry_t *e = file_sorted[i];
        uint64_t gap = e->file_partition_offset - cur;
        if (gap > 0) { unsigned char z = 0; for (uint64_t g = 0; g < gap; g++) fwrite(&z, 1, 1, out); }
        char full_path[4096];
        snprintf(full_path, sizeof(full_path), "%s%s", in_dir, e->path);
        FILE *src = fopen(full_path, "rb");
        if (!src) { fprintf(stderr, "romfs-build: could not open %s\n", full_path); fclose(out); return 1; }
        unsigned char buf[1 << 20];
        size_t got;
        while ((got = fread(buf, 1, sizeof(buf), src)) > 0) fwrite(buf, 1, got, out);
        fclose(src);
        cur = e->file_partition_offset + e->file_size;
    }
    uint64_t final_gap = (dir_hash_table_ofs - file_partition_ofs) - cur;
    if (final_gap > 0) { unsigned char z = 0; for (uint64_t g = 0; g < final_gap; g++) fwrite(&z, 1, 1, out); }

    unsigned char *dhbuf = malloc(dir_hash_table_size);
    for (uint32_t i = 0; i < dir_hash_count; i++) le_put_u32(dhbuf + i * 4, dir_hash_table[i]);
    fwrite(dhbuf, 1, dir_hash_table_size, out);
    free(dhbuf);

    unsigned char *dtbuf = malloc(dir_table_size);
    memset(dtbuf, 0, dir_table_size);
    le_put_u32(dtbuf + 0x00, 0); /* root parent = self */
    le_put_u32(dtbuf + 0x04, SENTINEL);
    le_put_u32(dtbuf + 0x08, root_child);
    le_put_u32(dtbuf + 0x0C, root_file);
    le_put_u32(dtbuf + 0x10, root_hash_chain);
    le_put_u32(dtbuf + 0x14, 0);
    for (size_t i = 0; i < dirs.count; i++) {
        entry_t *e = dir_sorted[i];
        unsigned char *p = dtbuf + e->entry_offset;
        le_put_u32(p + 0x00, e->parent_offset);
        le_put_u32(p + 0x04, e->sibling_offset);
        le_put_u32(p + 0x08, e->child_offset);
        le_put_u32(p + 0x0C, e->first_file_offset);
        le_put_u32(p + 0x10, e->hash_chain);
        uint32_t name_len = (uint32_t)strlen(e->name);
        le_put_u32(p + 0x14, name_len);
        memcpy(p + 0x18, e->name, name_len);
    }
    fwrite(dtbuf, 1, dir_table_size, out);
    free(dtbuf);

    unsigned char *fhbuf = malloc(file_hash_table_size);
    for (uint32_t i = 0; i < file_hash_count; i++) le_put_u32(fhbuf + i * 4, file_hash_table[i]);
    fwrite(fhbuf, 1, file_hash_table_size, out);
    free(fhbuf);

    unsigned char *ftbuf = malloc(file_table_size);
    memset(ftbuf, 0, file_table_size);
    for (size_t i = 0; i < files.count; i++) {
        entry_t *e = file_sorted[i];
        unsigned char *p = ftbuf + e->entry_offset;
        le_put_u32(p + 0x00, e->parent_offset);
        le_put_u32(p + 0x04, e->sibling_offset);
        le_put_u64(p + 0x08, e->file_partition_offset);
        le_put_u64(p + 0x10, e->file_size);
        le_put_u32(p + 0x18, e->hash_chain);
        uint32_t name_len = (uint32_t)strlen(e->name);
        le_put_u32(p + 0x1C, name_len);
        memcpy(p + 0x20, e->name, name_len);
    }
    fwrite(ftbuf, 1, file_table_size, out);
    free(ftbuf);

    fclose(out);

    /* Final padding to a 0x4000 boundary - a real, separate step from
     * every other padding rule above, applied by romfs_build's own
     * OUTER wrapper after everything else is written. */
    long total_size = 0;
    {
        FILE *check = fopen(out_path, "rb");
        fseeko(check, 0, SEEK_END);
        total_size = ftello(check);
        fclose(check);
    }
    long padded_total = (total_size + 0x3FFF) & ~0x3FFFL;
    long pad_bytes = padded_total - total_size;
    if (pad_bytes > 0) {
        FILE *append = fopen(out_path, "ab");
        unsigned char z = 0;
        for (long i = 0; i < pad_bytes; i++) fwrite(&z, 1, 1, append);
        fclose(append);
    }

    /* Echo the UNPADDED size (before this final alignment step) - this
     * is exactly hacpack's own romfs_build return value AND its
     * *out_size param, which becomes the IVFC level_headers[5].hash_data_size
     * field in the caller - NOT the padded on-disk file size. */
    printf("%ld\n", total_size);

    free(dir_hash_table);
    free(file_hash_table);
    free(dir_sorted);
    free(file_sorted);
    for (size_t i = 0; i < dirs.count; i++) { free(dirs.entries[i].path); free(dirs.entries[i].name); }
    for (size_t i = 0; i < files.count; i++) { free(files.entries[i].path); free(files.entries[i].name); }
    free(dirs.entries);
    free(files.entries);
    return 0;
}
