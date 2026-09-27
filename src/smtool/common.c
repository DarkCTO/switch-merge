#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

unsigned char *read_whole_file(const char *path, size_t *out_size) {
    FILE *f = fopen(path, "rb");
    if (!f) {
        fprintf(stderr, "Could not open %s\n", path);
        return NULL;
    }
    if (fseeko(f, 0, SEEK_END) != 0) {
        fprintf(stderr, "Could not seek %s\n", path);
        fclose(f);
        return NULL;
    }
    off_t size = ftello(f);
    if (size < 0 || fseeko(f, 0, SEEK_SET) != 0) {
        fprintf(stderr, "Could not determine size of %s\n", path);
        fclose(f);
        return NULL;
    }
    unsigned char *buf = malloc((size_t)size > 0 ? (size_t)size : 1);
    if (!buf) {
        fclose(f);
        return NULL;
    }
    if (size > 0 && fread(buf, 1, (size_t)size, f) != (size_t)size) {
        fprintf(stderr, "Short read on %s\n", path);
        free(buf);
        fclose(f);
        return NULL;
    }
    fclose(f);
    *out_size = (size_t)size;
    return buf;
}

char *hex_encode(const unsigned char *data, size_t len) {
    char *out = malloc(len * 2 + 1);
    if (!out) return NULL;
    static const char digits[] = "0123456789abcdef";
    for (size_t i = 0; i < len; i++) {
        out[i * 2] = digits[(data[i] >> 4) & 0xF];
        out[i * 2 + 1] = digits[data[i] & 0xF];
    }
    out[len * 2] = '\0';
    return out;
}

static int hex_nibble(char c) {
    if (c >= '0' && c <= '9') return c - '0';
    if (c >= 'a' && c <= 'f') return c - 'a' + 10;
    if (c >= 'A' && c <= 'F') return c - 'A' + 10;
    return -1;
}

unsigned char *hex_decode(const char *hex, size_t *out_len) {
    size_t hlen = strlen(hex);
    if (hlen % 2 != 0) return NULL;
    size_t blen = hlen / 2;
    unsigned char *out = malloc(blen > 0 ? blen : 1);
    if (!out) return NULL;
    for (size_t i = 0; i < blen; i++) {
        int hi = hex_nibble(hex[i * 2]);
        int lo = hex_nibble(hex[i * 2 + 1]);
        if (hi < 0 || lo < 0) {
            free(out);
            return NULL;
        }
        out[i] = (unsigned char)((hi << 4) | lo);
    }
    *out_len = blen;
    return out;
}

void print_kv_hex(const char *key, const unsigned char *data, size_t len) {
    char *hex = hex_encode(data, len);
    printf("%s=%s\n", key, hex ? hex : "");
    free(hex);
}

void print_kv_u64(const char *key, uint64_t value) {
    printf("%s=%llu\n", key, (unsigned long long)value);
}

void print_kv_str(const char *key, const char *value) {
    printf("%s=%s\n", key, value ? value : "");
}

void print_kv_empty(const char *key) {
    printf("%s=\n", key);
}

char *reverse_hex_bytes(const char *hex) {
    size_t hlen = strlen(hex);
    if (hlen % 2 != 0) return NULL;
    char *out = malloc(hlen + 1);
    if (!out) return NULL;
    size_t nbytes = hlen / 2;
    for (size_t i = 0; i < nbytes; i++) {
        out[i * 2] = hex[(nbytes - 1 - i) * 2];
        out[i * 2 + 1] = hex[(nbytes - 1 - i) * 2 + 1];
    }
    out[hlen] = '\0';
    return out;
}

char *keys_file_lookup(const char *keys_path, const char *name, size_t expected_hex_len) {
    FILE *f = fopen(keys_path, "r");
    if (!f) {
        fprintf(stderr, "Could not open keys file %s\n", keys_path);
        return NULL;
    }

    size_t name_len = strlen(name);
    char *line = NULL;
    size_t line_cap = 0;
    ssize_t n;
    char *result = NULL;

    while ((n = getline(&line, &line_cap, f)) != -1) {
        /* Match "^name\s*=\s*" then capture [0-9a-fA-F]+ after it, mirroring
         * the bash grep -oP pattern every lib-dir keys-file lookup uses. */
        if (strncmp(line, name, name_len) != 0) continue;
        char *p = line + name_len;
        while (*p == ' ' || *p == '\t') p++;
        if (*p != '=') continue;
        p++;
        while (*p == ' ' || *p == '\t') p++;

        char *start = p;
        size_t hexlen = 0;
        while (isxdigit((unsigned char)*p)) {
            p++;
            hexlen++;
        }
        if (hexlen == 0) continue;
        if (hexlen < expected_hex_len) continue;

        result = malloc(expected_hex_len + 1);
        if (result) {
            memcpy(result, start, expected_hex_len);
            result[expected_hex_len] = '\0';
        }
        break;
    }

    free(line);
    fclose(f);
    return result;
}

void make_scratch_template(const char *name_prefix, char *out_buf, size_t out_buf_size) {
    const char *dir = getenv("TMPDIR");
    if (!dir || dir[0] == '\0') dir = "/tmp";
    snprintf(out_buf, out_buf_size, "%s/%sXXXXXX", dir, name_prefix);
}
