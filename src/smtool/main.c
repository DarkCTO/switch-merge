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
int cmd_hfs0_data_off(int argc, char **argv);
int cmd_hfs0_list(int argc, char **argv);
int cmd_hfs0_extract_all(int argc, char **argv);
int cmd_nca_header_decrypt(int argc, char **argv);
int cmd_nca_rights_id(int argc, char **argv);

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
            "  hfs0-data-off <path> <header_offset>\n"
            "  hfs0-list <path> <header_offset>\n"
            "  hfs0-extract-all <path> <header_offset> <out_dir>\n"
            "  nca-header-decrypt <nca_path> --keys <keys_file> -o <out_file>\n"
            "  nca-rights-id <nca_path> --keys <keys_file>\n");
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
    if (strcmp(sub, "hfs0-data-off") == 0) return cmd_hfs0_data_off(sargc, sargv);
    if (strcmp(sub, "hfs0-list") == 0) return cmd_hfs0_list(sargc, sargv);
    if (strcmp(sub, "hfs0-extract-all") == 0) return cmd_hfs0_extract_all(sargc, sargv);
    if (strcmp(sub, "nca-header-decrypt") == 0) return cmd_nca_header_decrypt(sargc, sargv);
    if (strcmp(sub, "nca-rights-id") == 0) return cmd_nca_rights_id(sargc, sargv);

    fprintf(stderr, "smtool: unknown subcommand '%s'\n", sub);
    return 1;
}
