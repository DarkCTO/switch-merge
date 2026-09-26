/* tik-info <path.tik> - ports lib/binfmt.sh's parse_tik.
 *
 * Layout reference (switchbrew.org/wiki/Ticket), RSA-2048-SHA256 SignType
 * (0x10004) only - the only kind seen on real console tickets so far, per
 * lib/binfmt.sh's own comment. A different SignType shifts every offset
 * below (the signature block size varies per type), so this fails loudly
 * rather than guess:
 *   0x000 (0x4)  SignType
 *   0x180 (0x10) TitleKeyBlock (first 16 bytes = the titlekey)
 *   0x2A0 (0x10) RightsId
 */
#include "common.h"

#include <stdio.h>
#include <stdlib.h>

static uint32_t le_u32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}

int cmd_tik_info(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "usage: smtool tik-info <path.tik>\n");
        return 1;
    }
    size_t size;
    unsigned char *buf = read_whole_file(argv[0], &size);
    if (!buf) return 1;
    if (size < 4) {
        fprintf(stderr, "tik-info: %s too small to be a valid ticket\n", argv[0]);
        free(buf);
        return 1;
    }

    /* SignType is a little-endian u32 on disk (confirmed against a real
     * ticket: raw bytes 04 00 01 00 -> 0x00010004, matching nstool's own
     * "SignType: RSA2048-SHA256 (0x10004)"). lib/binfmt.sh's hex_field_le
     * reverses byte order before interpreting as hex, i.e. it also does a
     * plain little-endian read - read directly as LE here to match. */
    uint32_t sign_type = le_u32(buf);
    if (sign_type != 0x10004) {
        fprintf(stderr, "tik-info: unsupported SignType %u (only RSA2048-SHA256/0x10004 handled)\n", sign_type);
        free(buf);
        return 1;
    }

    if (size < 0x2B0) {
        fprintf(stderr, "tik-info: %s too small for RSA2048-SHA256 ticket layout\n", argv[0]);
        free(buf);
        return 1;
    }

    print_kv_hex("TIK_TITLEKEY", buf + 0x180, 16);
    print_kv_hex("TIK_RIGHTS_ID", buf + 0x2A0, 16);

    free(buf);
    return 0;
}
