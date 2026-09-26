/* Shared crypto primitives (libcrypto-backed) used by nca_header.c and
 * later phases. AES-128-ECB (no padding) is the one raw block-cipher
 * primitive AES-XTS/key-unwrap/AES-CTR are all built from - the same
 * layering lib/nca_header.sh's aes_ecb_hex uses (openssl enc -aes-128-ecb
 * -nopad), just calling libcrypto in-process instead of shelling out.
 */
#ifndef SMTOOL_CRYPTO_H
#define SMTOOL_CRYPTO_H

#include <stddef.h>

/* aes128_ecb_block <encrypt: 1|0> <key[16]> <in[16]> <out[16]>
 * Single 16-byte AES-128-ECB block operation, no padding - the exact
 * primitive lib/nca_header.sh's XTS construction and (later) key-area
 * unwrap are built from. Returns 0 on success, nonzero on failure. */
int aes128_ecb_block(int encrypt, const unsigned char key[16], const unsigned char in[16], unsigned char out[16]);

/* aes128_ecb_multi <encrypt: 1|0> <key[16]> <in> <out> <len, multiple of 16>
 * Multi-block AES-128-ECB, no padding, no chaining between blocks (each
 * 16-byte block is independently encrypted/decrypted - true ECB, not
 * CBC) - used to encrypt/decrypt several blocks in one call where XTS's
 * own per-block tweak isn't needed (e.g. key-area unwrap in a later
 * phase). Returns 0 on success, nonzero on failure (including if len
 * isn't a multiple of 16). */
int aes128_ecb_multi(int encrypt, const unsigned char key[16], const unsigned char *in, unsigned char *out, size_t len);

#endif
