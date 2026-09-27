/* Shared helpers for every smtool subcommand: hex encode/decode, KEY=VALUE
 * line output, and prod.keys file lookup. See README's "smtool" section
 * for the project-wide output contract (KEY=VALUE lines for multi-field
 * results, bare scalar for single values, plain positional lines for
 * already-table-shaped results like pfs0-list/hfs0-list) - every
 * subcommand file follows this convention, not just this header.
 */
#ifndef SMTOOL_COMMON_H
#define SMTOOL_COMMON_H

#include <stdint.h>
#include <stddef.h>

/* Reads a whole file into a malloc'd buffer. Returns NULL and prints to
 * stderr on failure. Caller frees. *out_size receives the byte length. */
unsigned char *read_whole_file(const char *path, size_t *out_size);

/* Encodes len bytes as a malloc'd lowercase hex string (2*len chars + NUL). */
char *hex_encode(const unsigned char *data, size_t len);

/* Decodes a hex string into a malloc'd byte buffer. Returns NULL on a
 * malformed (odd-length or non-hex) string. *out_len receives the byte
 * count (strlen(hex)/2). */
unsigned char *hex_decode(const char *hex, size_t *out_len);

/* Prints one "KEY=value" line to stdout, where value is the lowercase hex
 * encoding of data[0..len). Used for hex-shaped fields (title IDs, content
 * IDs, raw byte fields). */
void print_kv_hex(const char *key, const unsigned char *data, size_t len);

/* Prints one "KEY=value" line where value is a decimal (unsigned 64-bit)
 * integer - used for numeric fields (version, sizes, type numbers). */
void print_kv_u64(const char *key, uint64_t value);

/* Prints one "KEY=value" line where value is a plain string, as-is (used
 * for CNMT_TYPE_NAME and similar already-text fields). */
void print_kv_str(const char *key, const char *value);

/* Prints "KEY=" (empty value) - for a field that doesn't apply to this
 * record shape, matching lib/binfmt.sh's convention of leaving a bash
 * variable empty (not unset) when a field isn't present, so callers'
 * `[ -n "$X" ]` checks keep working after switch-merge.sh's KV-reading
 * helper populates every declared variable. */
void print_kv_empty(const char *key);

/* Looks up a prod.keys-style "name = hexvalue" entry (first match, any
 * amount of whitespace around '=', trailing whitespace/newline trimmed -
 * mirrors lib/nca_header.sh's `grep -oP '^name\s*=\s*\K[0-9a-fA-F]+'`
 * behavior). Returns a malloc'd hex string, or NULL if not found.
 * expected_hex_len is the required hex-character length (e.g. 64 for a
 * 32-byte key) - a match shorter than this is treated as not found, same
 * as the bash `[ "${#x}" -eq N ]` checks throughout lib dir scripts; a match
 * LONGER than this is truncated to expected_hex_len (matches bash's
 * `cut -c1-N`, which several real prod.keys entries need due to a known
 * stray-trailing-byte formatting quirk documented in README's "Known
 * issues"). */
char *keys_file_lookup(const char *keys_path, const char *name, size_t expected_hex_len);

/* Reverses byte order (not nibble order) of an even-length hex string
 * in place into a new malloc'd string - the hex-string equivalent of
 * every lib dir script's own duplicated reverse-hex helper (used to
 * read a little-endian on-disk field as a big-endian-ordered hex string,
 * i.e. the natural human/printf reading order). */
char *reverse_hex_bytes(const char *hex);

/* make_scratch_template <name_prefix> <out_buf> <out_buf_size>
 * Builds an mkstemp/mkdtemp template ("<scratch_dir>/<name_prefix>XXXXXX")
 * honoring $TMPDIR (falling back to /tmp if unset), same convention every
 * bash mktemp call in this project's lib dir scripts already follows -
 * switch-merge.sh sets $TMPDIR to a project-local directory specifically
 * so large scratch files (this tool's own multi-GB Program/Meta NCA
 * intermediates included) don't land on a small system /tmp tmpfs.
 * Unlike bash's own `mktemp`, C's mkstemp()/mkdtemp() do NOT consult
 * $TMPDIR automatically - every caller must build this template
 * explicitly, which is exactly what this function centralizes (a real
 * bug this project hit once: several call sites hardcoded a literal
 * "/tmp/smtool_..." template, which silently produced truncated/empty
 * scratch files instead of a loud error when a small system /tmp filled
 * up during a large real merge). */
void make_scratch_template(const char *name_prefix, char *out_buf, size_t out_buf_size);

#endif
