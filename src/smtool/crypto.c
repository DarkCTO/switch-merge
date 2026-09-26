#include "crypto.h"

#include <openssl/evp.h>
#include <string.h>

static int aes128_ecb_op(int encrypt, const unsigned char key[16], const unsigned char *in, unsigned char *out, size_t len) {
    if (len % 16 != 0) return 1;

    EVP_CIPHER_CTX *ctx = EVP_CIPHER_CTX_new();
    if (!ctx) return 1;

    int ok = 1;
    if (EVP_CipherInit_ex(ctx, EVP_aes_128_ecb(), NULL, key, NULL, encrypt) == 1 &&
        EVP_CIPHER_CTX_set_padding(ctx, 0) == 1) {
        int outlen1 = 0, outlen2 = 0;
        if (len > 0) {
            if (EVP_CipherUpdate(ctx, out, &outlen1, in, (int)len) == 1 &&
                EVP_CipherFinal_ex(ctx, out + outlen1, &outlen2) == 1) {
                ok = 0;
            }
        } else {
            ok = 0;
        }
    }

    EVP_CIPHER_CTX_free(ctx);
    return ok;
}

int aes128_ecb_block(int encrypt, const unsigned char key[16], const unsigned char in[16], unsigned char out[16]) {
    return aes128_ecb_op(encrypt, key, in, out, 16);
}

int aes128_ecb_multi(int encrypt, const unsigned char key[16], const unsigned char *in, unsigned char *out, size_t len) {
    return aes128_ecb_op(encrypt, key, in, out, len);
}
