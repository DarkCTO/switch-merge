/* Shared NCA header decrypt, used by nca_header.c's own subcommands and
 * by every later phase (nca_content.c, bktr.c, nca_build.c) that needs
 * to read fields out of a decrypted header without re-implementing
 * AES-XTS or re-deriving header_key itself.
 */
#ifndef SMTOOL_NCA_COMMON_H
#define SMTOOL_NCA_COMMON_H

#define NCA_HEADER_SIZE 0xC00

/* nca_decrypt_header <nca_path> <keys_path> <out[NCA_HEADER_SIZE]>
 * Decrypts the full 0xC00-byte header (6 XTS sectors) into out. Returns
 * 0 on success, nonzero (with a message on stderr) on failure. */
int nca_decrypt_header(const char *nca_path, const char *keys_path, unsigned char *out);

/* nca_encrypt_header <header[NCA_HEADER_SIZE]> <keys_path> <out[NCA_HEADER_SIZE]>
 * Encrypts a complete, freshly-assembled 0xC00-byte NCA header (6 XTS
 * sectors) with the same fixed header_key every real NCA uses - the
 * exact mirror of nca_decrypt_header, used by Phase 7/8's NCA builders.
 * Returns 0 on success, nonzero on failure. */
int nca_encrypt_header(const unsigned char *header, const char *keys_path, unsigned char *out);

#include <stdint.h>

/* romfs_build_impl <in_dir> <out_path> <*out_unpadded_size>
 * The in-process (no subprocess) RomFs writer from Phase 6 - see
 * romfs_build.c's own header comment for the full algorithm. Used
 * directly by Phase 8's Program NCA assembly. */
int romfs_build_impl(const char *in_dir, const char *out_path, uint64_t *out_unpadded_size);

/* nca_section_info_t / nca_section_info / nca_content_ctr - shared with
 * bktr.c's in-process BKTR reconstruction (see nca_content.c for the
 * full derivation of both). */
typedef struct {
    int present;
    uint64_t offset;
    uint64_t size;
    int crypt_type;
    unsigned char ctr[16];
} nca_section_info_t;

void nca_section_info(const unsigned char *header, int section_num, nca_section_info_t *out);
void nca_content_ctr(const unsigned char section_ctr_raw[8], uint64_t byte_offset, unsigned char out_ctr[16]);

/* nca_ctr_decrypt_range <nca_path> <key[16]> <ctr[16]> <byte_offset> <byte_size> <out_path>
 * Streaming AES-128-CTR decrypt of byte_size bytes at byte_offset in
 * nca_path, writing plaintext to out_path - the in-process (no
 * subprocess) version of Phase 5's own decrypt-section subcommand, for
 * bktr.c's reconstruction loop to call directly. Returns 0 on success. */
int nca_ctr_decrypt_range(const char *nca_path, const unsigned char key[16], const unsigned char ctr[16],
                           uint64_t byte_offset, uint64_t byte_size, const char *out_path);

/* nca_ctr_decrypt_range_append - same as nca_ctr_decrypt_range but
 * APPENDS to out_path instead of creating/truncating it - used by
 * bktr.c's reconstruction loop, which builds its output incrementally
 * chunk by chunk (a mix of base-romfs copies and update-NCA decrypts). */
int nca_ctr_decrypt_range_append(const char *nca_path, const unsigned char key[16], const unsigned char ctr[16],
                                  uint64_t byte_offset, uint64_t byte_size, const char *out_path);

#endif
