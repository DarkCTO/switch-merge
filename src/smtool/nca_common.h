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

#endif
