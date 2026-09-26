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

#endif
