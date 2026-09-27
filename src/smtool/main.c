/* smtool - fast C reimplementation of switch-merge's performance-critical
 * pipeline pieces. One-shot subcommands, same invocation style as the
 * project's vendored nstool/hactool/hacpack (spawn once, do one thing,
 * exit). See README's "smtool" section for the project-wide output
 * contract each subcommand follows.
 *
 * Phase 1 scope (this file): pure struct/container parsing only, no
 * crypto - cnmt/NACP/ticket reading, PFS0/HFS0 reading. Later phases add
 * more subcommands here as they're built (NCA header crypto, content
 * decryption, BKTR reconstruction, NCA/romfs building).
 */
#include <stdio.h>
#include <string.h>

int cmd_cnmt_info(int argc, char **argv);
int cmd_nacp_info(int argc, char **argv);
int cmd_tik_info(int argc, char **argv);
int cmd_pfs0_list(int argc, char **argv);
int cmd_pfs0_extract(int argc, char **argv);
int cmd_pfs0_extract_all(int argc, char **argv);
int cmd_pfs0_pack(int argc, char **argv);
int cmd_hfs0_data_off(int argc, char **argv);
int cmd_hfs0_list(int argc, char **argv);
int cmd_hfs0_extract_all(int argc, char **argv);
int cmd_nca_header_decrypt(int argc, char **argv);
int cmd_nca_rights_id(int argc, char **argv);
int cmd_nca_crypto_type(int argc, char **argv);
int cmd_nca_content_key_standard(int argc, char **argv);
int cmd_nca_content_key_titlekey(int argc, char **argv);
int cmd_nca_section_info(int argc, char **argv);
int cmd_romfs_extract(int argc, char **argv);
int cmd_romfs_extract_all(int argc, char **argv);
int cmd_bktr_headers(int argc, char **argv);
int cmd_bktr_relocations(int argc, char **argv);
int cmd_bktr_subsections(int argc, char **argv);
int cmd_bktr_reconstruct(int argc, char **argv);
int cmd_nca_ctr_decrypt_section(int argc, char **argv);
int cmd_nca_hierarchical_sha256_layer(int argc, char **argv);
int cmd_nca_hierarchical_integrity_layer(int argc, char **argv);
int cmd_romfs_build(int argc, char **argv);
int cmd_build_cnmt(int argc, char **argv);
int cmd_build_meta_nca(int argc, char **argv);
int cmd_build_program_nca(int argc, char **argv);

int main(int argc, char **argv) {
    if (argc < 2) {
        fprintf(stderr,
            "usage: smtool <subcommand> [args...]\n"
            "subcommands:\n"
            "  cnmt-info <path.cnmt>\n"
            "  nacp-info <control.nacp>\n"
            "  tik-info <path.tik>\n"
            "  pfs0-list <path>\n"
            "  pfs0-extract <path> <entry_name> <out_file>\n"
            "  pfs0-extract-all <path> <out_dir>\n"
            "  pfs0-pack <out_path> <file1> [file2] ...\n"
            "  hfs0-data-off <path> <header_offset>\n"
            "  hfs0-list <path> <header_offset>\n"
            "  hfs0-extract-all <path> <header_offset> <out_dir>\n"
            "  nca-header-decrypt <nca_path> --keys <keys_file> -o <out_file>\n"
            "  nca-rights-id <nca_path> --keys <keys_file>\n"
            "  nca-crypto-type <nca_path> --keys <keys_file>\n"
            "  nca-content-key-standard <nca_path> --keys <keys_file>\n"
            "  nca-content-key-titlekey <titlekey_hex> <key_generation> --keys <keys_file>\n"
            "  nca-section-info <nca_path> --keys <keys_file> --section <0-3>\n"
            "  romfs-extract <romfs_file> <entry_name> <out_path>\n"
            "  romfs-extract-all <romfs_file> <out_dir>\n"
            "  bktr-headers <decrypted_header_file> --section <0-3>\n"
            "  bktr-relocations <table_file>\n"
            "  bktr-subsections <table_file>\n"
            "  bktr-reconstruct <update_nca> --keys <keys_file> --key-hex <hex32> --section <0-3> --base-romfs <path> -o <out_path>\n"
            "  decrypt-section <nca_path> --key-hex <hex32> --ctr <hex32> --offset <N> --size <N> -o <out_path>\n"
            "  nca-hierarchical-sha256-layer <decrypted_header_file> --section <0-3>\n"
            "  nca-hierarchical-integrity-layer <decrypted_header_file> --section <0-3>\n"
            "  romfs-build <in_dir> <out_path>\n"
            "  build-cnmt <out_path> <application|addon> <title_id_hex> <title_version> <program_or_-> <control_or_-> <legal_or_-> <data_or_->\n"
            "  build-meta-nca <out_nca> <title_id_hex> <title_version> --keys <keys_file> [--program <nca>] [--control <nca>] [--legal <nca>] [--data <nca>] [--digest <hex64>]\n"
            "  build-program-nca <out_nca> <title_id_hex> --keys <keys_file> --romfs-dir <dir> --exefs <file> [--exefs <file> ...]\n");
        return 1;
    }

    const char *sub = argv[1];
    int sargc = argc - 2;
    char **sargv = argv + 2;

    if (strcmp(sub, "cnmt-info") == 0) return cmd_cnmt_info(sargc, sargv);
    if (strcmp(sub, "nacp-info") == 0) return cmd_nacp_info(sargc, sargv);
    if (strcmp(sub, "tik-info") == 0) return cmd_tik_info(sargc, sargv);
    if (strcmp(sub, "pfs0-list") == 0) return cmd_pfs0_list(sargc, sargv);
    if (strcmp(sub, "pfs0-extract") == 0) return cmd_pfs0_extract(sargc, sargv);
    if (strcmp(sub, "pfs0-extract-all") == 0) return cmd_pfs0_extract_all(sargc, sargv);
    if (strcmp(sub, "pfs0-pack") == 0) return cmd_pfs0_pack(sargc, sargv);
    if (strcmp(sub, "hfs0-data-off") == 0) return cmd_hfs0_data_off(sargc, sargv);
    if (strcmp(sub, "hfs0-list") == 0) return cmd_hfs0_list(sargc, sargv);
    if (strcmp(sub, "hfs0-extract-all") == 0) return cmd_hfs0_extract_all(sargc, sargv);
    if (strcmp(sub, "nca-header-decrypt") == 0) return cmd_nca_header_decrypt(sargc, sargv);
    if (strcmp(sub, "nca-rights-id") == 0) return cmd_nca_rights_id(sargc, sargv);
    if (strcmp(sub, "nca-crypto-type") == 0) return cmd_nca_crypto_type(sargc, sargv);
    if (strcmp(sub, "nca-content-key-standard") == 0) return cmd_nca_content_key_standard(sargc, sargv);
    if (strcmp(sub, "nca-content-key-titlekey") == 0) return cmd_nca_content_key_titlekey(sargc, sargv);
    if (strcmp(sub, "nca-section-info") == 0) return cmd_nca_section_info(sargc, sargv);
    if (strcmp(sub, "romfs-extract") == 0) return cmd_romfs_extract(sargc, sargv);
    if (strcmp(sub, "romfs-extract-all") == 0) return cmd_romfs_extract_all(sargc, sargv);
    if (strcmp(sub, "bktr-headers") == 0) return cmd_bktr_headers(sargc, sargv);
    if (strcmp(sub, "bktr-relocations") == 0) return cmd_bktr_relocations(sargc, sargv);
    if (strcmp(sub, "bktr-subsections") == 0) return cmd_bktr_subsections(sargc, sargv);
    if (strcmp(sub, "bktr-reconstruct") == 0) return cmd_bktr_reconstruct(sargc, sargv);
    if (strcmp(sub, "decrypt-section") == 0) return cmd_nca_ctr_decrypt_section(sargc, sargv);
    if (strcmp(sub, "nca-hierarchical-sha256-layer") == 0) return cmd_nca_hierarchical_sha256_layer(sargc, sargv);
    if (strcmp(sub, "nca-hierarchical-integrity-layer") == 0) return cmd_nca_hierarchical_integrity_layer(sargc, sargv);
    if (strcmp(sub, "romfs-build") == 0) return cmd_romfs_build(sargc, sargv);
    if (strcmp(sub, "build-cnmt") == 0) return cmd_build_cnmt(sargc, sargv);
    if (strcmp(sub, "build-meta-nca") == 0) return cmd_build_meta_nca(sargc, sargv);
    if (strcmp(sub, "build-program-nca") == 0) return cmd_build_program_nca(sargc, sargv);

    fprintf(stderr, "smtool: unknown subcommand '%s'\n", sub);
    return 1;
}
