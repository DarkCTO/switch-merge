/* nacp-info <control.nacp> - ports lib/binfmt.sh's parse_nacp.
 *
 * Layout reference (switchbrew.org/wiki/NACP):
 *   16 language slots, 0x300 bytes each, starting at file offset 0:
 *     0x000 (0x200 bytes) Name, NUL-padded
 *     0x200 (0x100 bytes) Publisher, NUL-padded
 *   0x3060 (0x10 bytes) DisplayVersion, NUL-padded
 *
 * MUST scan all 16 slots for the first non-empty Name, not just slot 0 -
 * a real title ("Talisman") was found with an empty AmericanEnglish
 * (slot 0) name and the real name only in slot 1 (BritishEnglish). See
 * lib/binfmt.sh's parse_nacp comment for the full story - this is a
 * deliberately preserved behavior, not an oversight to "simplify" away.
 */
#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int cmd_nacp_info(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "usage: smtool nacp-info <control.nacp>\n");
        return 1;
    }
    size_t size;
    unsigned char *buf = read_whole_file(argv[0], &size);
    if (!buf) return 1;

    char name[513] = {0};
    for (int slot = 0; slot < 16; slot++) {
        size_t slot_off = (size_t)slot * 0x300;
        if (slot_off + 0x200 > size) break;
        /* NUL-terminated read: copy up to 0x200 bytes, stop at first NUL -
         * matches lib/binfmt.sh's hex_to_text (xxd -r -p | tr -d '\0'),
         * which truncates at the first NUL byte, not just strips all NULs
         * project-wide (this field is NUL-PADDED, so truncating at the
         * first NUL is equivalent here; tr -d '\0' would also drop any
         * NUL bytes embedded mid-string, but a real NACP name field never
         * has one before its own padding starts). */
        size_t len = 0;
        while (len < 0x200 && buf[slot_off + len] != 0) len++;
        if (len > 0) {
            memcpy(name, buf + slot_off, len);
            name[len] = '\0';
            break;
        }
    }

    char display_version[17] = {0};
    if (size >= 12384 + 16) {
        size_t len = 0;
        while (len < 16 && buf[12384 + len] != 0) len++;
        memcpy(display_version, buf + 12384, len);
        display_version[len] = '\0';
    }

    print_kv_str("NACP_NAME", name);
    print_kv_str("NACP_DISPLAY_VERSION", display_version);

    free(buf);
    return 0;
}
