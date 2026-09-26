/* cnmt-info <path.cnmt> - ports lib/binfmt.sh's parse_cnmt.
 *
 * Layout reference (switchbrew.org/wiki/CNMT), exactly as documented in
 * lib/binfmt.sh's own header comment:
 *   PackagedContentMetaHeader (0x20 bytes):
 *     0x00 u64  Id (this content's own TitleId)
 *     0x08 u32  Version
 *     0x0C u8   ContentMetaType
 *     0x0E u16  ExtendedHeaderSize
 *     0x10 u16  ContentCount
 *   ApplicationMetaExtendedHeader (Application only, at 0x20):
 *     0x00 u64  PatchId
 *   PatchMetaExtendedHeader (Patch/AddOnContent, at 0x20):
 *     0x00 u64  ApplicationId
 *   PackagedContentInfo (0x38 bytes each, starting at 0x20+ExtendedHeaderSize):
 *     0x20 u128 ContentId (16 bytes, raw/opaque)
 *     0x30 u40  Size (5 bytes, raw little-endian)
 *     0x36 u8   ContentType
 */
#include "common.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint64_t le_u64(const unsigned char *p) {
    uint64_t v = 0;
    for (int i = 7; i >= 0; i--) v = (v << 8) | p[i];
    return v;
}
static uint32_t le_u32(const unsigned char *p) {
    return (uint32_t)p[0] | ((uint32_t)p[1] << 8) | ((uint32_t)p[2] << 16) | ((uint32_t)p[3] << 24);
}
static uint16_t le_u16(const unsigned char *p) {
    return (uint16_t)(p[0] | (p[1] << 8));
}

static const char *content_meta_type_name(int t) {
    switch (t) {
        case 0: return "Invalid";
        case 1: return "SystemProgram";
        case 2: return "SystemData";
        case 3: return "SystemUpdate";
        case 4: return "BootImagePackage";
        case 5: return "BootImagePackageSafe";
        case 128: return "Application";
        case 129: return "Patch";
        case 130: return "AddOnContent";
        case 131: return "Delta";
        case 132: return "DataPatch";
        default: {
            static char buf[32];
            snprintf(buf, sizeof(buf), "Unknown(%d)", t);
            return buf;
        }
    }
}

typedef enum { CT_META = 0, CT_PROGRAM = 1, CT_DATA = 2, CT_CONTROL = 3,
               CT_HTMLDOC = 4, CT_LEGAL = 5, CT_DELTAFRAG = 6 } content_type_t;

int cmd_cnmt_info(int argc, char **argv) {
    if (argc < 1) {
        fprintf(stderr, "usage: smtool cnmt-info <path.cnmt>\n");
        return 1;
    }
    size_t size;
    unsigned char *buf = read_whole_file(argv[0], &size);
    if (!buf) return 1;
    if (size < 0x20) {
        fprintf(stderr, "cnmt-info: %s too small to be a valid cnmt\n", argv[0]);
        free(buf);
        return 1;
    }

    uint64_t title_id = le_u64(buf + 0x00);
    uint32_t version = le_u32(buf + 0x08);
    uint8_t type_num = buf[0x0C];
    uint16_t ext_hdr_size = le_u16(buf + 0x0E);
    uint16_t content_count = le_u16(buf + 0x10);

    print_kv_hex("CNMT_TITLE_ID", (unsigned char[]){
        (title_id >> 56) & 0xFF, (title_id >> 48) & 0xFF, (title_id >> 40) & 0xFF, (title_id >> 32) & 0xFF,
        (title_id >> 24) & 0xFF, (title_id >> 16) & 0xFF, (title_id >> 8) & 0xFF, title_id & 0xFF
    }, 8);
    print_kv_u64("CNMT_VERSION", version);
    print_kv_u64("CNMT_TYPE_NUM", type_num);
    print_kv_str("CNMT_TYPE_NAME", content_meta_type_name(type_num));

    if (type_num == 129 || type_num == 130) {
        if (size < 0x28) {
            fprintf(stderr, "cnmt-info: %s too small for extended header\n", argv[0]);
            free(buf);
            return 1;
        }
        uint64_t app_id = le_u64(buf + 0x20);
        print_kv_hex("CNMT_APPLICATION_ID", (unsigned char[]){
            (app_id >> 56) & 0xFF, (app_id >> 48) & 0xFF, (app_id >> 40) & 0xFF, (app_id >> 32) & 0xFF,
            (app_id >> 24) & 0xFF, (app_id >> 16) & 0xFF, (app_id >> 8) & 0xFF, app_id & 0xFF
        }, 8);
    } else {
        print_kv_empty("CNMT_APPLICATION_ID");
    }

    unsigned char program_id[16] = {0}, control_id[16] = {0}, legal_id[16] = {0}, data_id[16] = {0};
    int has_program = 0, has_control = 0, has_legal = 0, has_data = 0;

    size_t content_off = 0x20 + ext_hdr_size;
    for (int i = 0; i < content_count; i++) {
        size_t entry_off = content_off + (size_t)i * 0x38;
        if (entry_off + 0x38 > size) {
            fprintf(stderr, "cnmt-info: %s content entry %d runs past end of file\n", argv[0], i);
            free(buf);
            return 1;
        }
        const unsigned char *content_id = buf + entry_off + 0x20;
        uint8_t ctype = buf[entry_off + 0x36];
        switch (ctype) {
            case CT_PROGRAM: if (!has_program) { memcpy(program_id, content_id, 16); has_program = 1; } break;
            case CT_CONTROL: if (!has_control) { memcpy(control_id, content_id, 16); has_control = 1; } break;
            case CT_LEGAL: if (!has_legal) { memcpy(legal_id, content_id, 16); has_legal = 1; } break;
            case CT_DATA: if (!has_data) { memcpy(data_id, content_id, 16); has_data = 1; } break;
            default: break;
        }
    }

    if (has_program) print_kv_hex("CNMT_PROGRAM_ID", program_id, 16); else print_kv_empty("CNMT_PROGRAM_ID");
    if (has_control) print_kv_hex("CNMT_CONTROL_ID", control_id, 16); else print_kv_empty("CNMT_CONTROL_ID");
    if (has_legal) print_kv_hex("CNMT_LEGALINFORMATION_ID", legal_id, 16); else print_kv_empty("CNMT_LEGALINFORMATION_ID");
    if (has_data) print_kv_hex("CNMT_DATA_ID", data_id, 16); else print_kv_empty("CNMT_DATA_ID");

    free(buf);
    return 0;
}
