#!/usr/bin/env bash
# Merge one or more Switch base-game NSPs, each with (optionally) its own
# update NSP and (optionally) any number of DLC NSPs, into one installable
# NSP per title (1G1R: one game, one ROM).
# Usage: switch-merge.sh [-o <output_dir>] [-k keys.dat] [<nsp-or-dir> ...]
#
# With no positional inputs, defaults to scanning the directory this script
# itself lives in, and to "<script dir>/merged" as the output directory -
# so plain `./switch-merge.sh` with no args just works.
#
# Base/update/DLC are auto-detected from each NSP's own cnmt content-meta
# Type field (Application/Patch/AddOnContent) - not from filenames - and
# grouped by base title ID, so a single directory containing multiple
# different games (each with their own base/update/DLC) can be merged in
# one run. Each group is merged independently; one group failing does not
# stop the others.
set -euo pipefail

# Prefer the vendored copy of hacpack in ./bin (relative to this script's
# own location, not the caller's cwd) over any system-wide install, so the
# project is self-contained and doesn't depend on whatever version happens
# to be on PATH. Falls back to PATH if ./bin doesn't have it (e.g. a fresh
# checkout without the binary vendored in yet). nstool and hactool are no
# longer required at all by the pipeline (see below) but both are left
# vendored/on PATH here too, harmlessly, in case they're ever useful for
# manual debugging (their human-readable dumps and hactool's own
# --basenca reconstruction were used throughout this project's own
# development to verify the pure-bash code against - see lib/bktr.sh's
# header comment for the BKTR-reconstruction verification specifically).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/bin" ]; then
    PATH="$SCRIPT_DIR/bin:$PATH"
fi

# Every mktemp/mktemp -d call in this script and every sourced lib/*.sh
# file (there's no single shared "scratch dir" variable threaded through
# all of them - each function makes its own as needed) honors $TMPDIR
# before falling back to /tmp, so setting it once here, before anything
# else runs, redirects the whole project's scratch usage into its own
# directory instead of system /tmp - a real, hardware-relevant reason:
# temp NCA/romfs/exefs intermediates for a single title can run into the
# hundreds of MB to low GB (a full Program NCA rebuild decrypts/rebuilds
# an entire romfs+exefs in scratch), so a project-local tmp dir on a
# partition sized for game dumps is both easier to keep an eye on and
# easier to bulk-clear than hunting through system /tmp.
export TMPDIR="$SCRIPT_DIR/tmp"
mkdir -p "$TMPDIR"

# Pure-bash cnmt/NACP/ticket binary parsers (lib/binfmt.sh), NCA header
# AES-XTS decryption (lib/nca_header.sh), per-title NCA content-key
# derivation and AES-CTR content decryption (lib/nca_content.sh), PFS0/NSP
# container packing+unpacking (lib/pfs0.sh), RomFs file-table reading
# (lib/romfs.sh), and BKTR (patch-romfs) reconstruction (lib/bktr.sh) -
# together these eliminate the dependency on nstool AND hactool entirely
# (see extract_nsp/extract_cnmt_from_meta_nca/extract_nacp_from_control_nca
# below for the nstool replacements, and the BKTR-reconstruction branch of
# merge_group further down for the hactool replacement - every
# nstool/hactool call site this project ever had is now pure bash). See
# README's "The debugging story" and "Reduce dependency on vendored tools"
# roadmap entries for how these were derived and verified against nstool's/
# hacpack's/hactool's own output on real files (including several real
# bugs found and fixed along the way: bash silently drops embedded NUL
# bytes from string variables, which broke the PFS0 string table's null-
# terminated filenames until file writes were changed to stream NULs
# directly via printf instead of building a combined string first; a
# `while read ... done < <(...)` process substitution runs in a subshell,
# so a variable the piped function sets as a side effect is invisible back
# in the loop body - lib/pfs0.sh's data-offset lookup hit this and now
# returns its result via a dedicated function call instead of a global;
# GNU dd's count=/skip= flags do NOT accept a bash-style 0x... hex literal
# - lib/romfs.sh's header read silently got a `count=0` this way until the
# literal was wrapped in `$(( ))` first; and the BKTR relocation/
# subsection bucket-tree layout is NOT documented anywhere online, in this
# much detail, in switchbrew's wiki or elsewhere - lib/bktr.sh's struct
# offsets were derived directly from vendored bin/hactool's own C source
# instead of guessed, then verified against real files). NCA content-
# partition hash-tree verification and NCA *building* (Meta/Program -
# which needs to write hash trees, not just read them) still go through
# the vendored hacpack, since that involves hash-tree verification/
# construction where a subtly wrong from-scratch implementation would
# silently produce corrupted output rather than a clean error - not worth
# that risk for what's already working, tested tooling.
source "$SCRIPT_DIR/lib/binfmt.sh"
source "$SCRIPT_DIR/lib/nca_header.sh"
source "$SCRIPT_DIR/lib/nca_content.sh"
source "$SCRIPT_DIR/lib/pfs0.sh"
source "$SCRIPT_DIR/lib/romfs.sh"
source "$SCRIPT_DIR/lib/bktr.sh"
source "$SCRIPT_DIR/lib/romfs_build.sh"
source "$SCRIPT_DIR/lib/nca_build.sh"

# extract_nsp <nsp_path> <out_dir>
# Splits an NSP (a plain, unencrypted PFS0 container) into its component
# NCA/tik/cert files - the pure-bash replacement for `nstool -x <out_dir>
# <nsp_path>`. No decryption needed at this level.
extract_nsp() {
    pfs0_extract_all "$1" "$2"
}

# extract_cnmt_from_meta_nca <meta_nca_path> <out_path>
# Decrypts a Meta NCA's PartitionFs section (standard crypto - every real
# Meta NCA seen so far has no RightsId, confirmed across every base/
# update/DLC Meta NCA in this project's test titles) and extracts its
# single .cnmt file to out_path - the pure-bash replacement for `nstool -t
# nca -x <dir> <meta_nca_path>` at this project's cnmt-reading call sites.
# Does NOT handle a titlekey-crypto Meta NCA (would need parse_tik +
# nca_content_key_titlekey instead of nca_content_key_standard) since none
# has ever been seen in practice - fails loudly via nca_rights_id's
# nonempty result rather than silently guessing.
extract_cnmt_from_meta_nca() {
    local meta_nca="$1" out_path="$2"
    local rights_id
    rights_id="$(nca_rights_id "$meta_nca" "$KEYS")"
    [ -z "$rights_id" ] || { echo "extract_cnmt_from_meta_nca: $meta_nca is titlekey-crypto (RightsId $rights_id) - unsupported, no Meta NCA like this has been seen before" >&2; return 1; }

    nca_section_info "$meta_nca" "$KEYS" 0
    local key section_bin data_off data_size
    key="$(nca_content_key_standard "$meta_nca" "$KEYS")" || return 1
    section_bin="$(mktemp)"
    nca_ctr_decrypt_section "$meta_nca" "$key" "$NCA_SECTION_CTR" "$NCA_SECTION_OFFSET" "$NCA_SECTION_SIZE" "$section_bin" || { rm -f "$section_bin"; return 1; }
    read -r data_off data_size <<< "$(nca_hierarchical_sha256_data_layer "$meta_nca" "$KEYS" 0)"

    local pfs0_bin="$section_bin.pfs0"
    tail -c +$((data_off + 1)) "$section_bin" | head -c "$data_size" > "$pfs0_bin"
    rm -f "$section_bin"

    local name off size
    while read -r name off size; do
        if [[ "$name" == *.cnmt ]]; then
            pfs0_extract "$pfs0_bin" "$name" "$out_path"
            rm -f "$pfs0_bin"
            return 0
        fi
    done < <(_pfs0_read_entries "$pfs0_bin")
    rm -f "$pfs0_bin"
    echo "extract_cnmt_from_meta_nca: no .cnmt entry found in $meta_nca" >&2
    return 1
}

# extract_nacp_from_control_nca <control_nca_path> <out_path>
# Decrypts a Control NCA's RomFs section (standard crypto - same as every
# other content NCA this project reads without a ticket) and extracts its
# control.nacp file to out_path - the pure-bash replacement for `nstool -x
# <dir> <control_nca_path>` at this project's one remaining nstool call
# site. Uses lib/romfs.sh's flat-lookup RomFs reader, which only searches
# the root directory - fine here, since every real Control NCA's RomFs
# seen so far has every file (icons + control.nacp) directly in the root,
# no subdirectories.
extract_nacp_from_control_nca() {
    local control_nca="$1" out_path="$2"
    local rights_id
    rights_id="$(nca_rights_id "$control_nca" "$KEYS")"
    [ -z "$rights_id" ] || { echo "extract_nacp_from_control_nca: $control_nca is titlekey-crypto (RightsId $rights_id) - unsupported, no Control NCA like this has been seen before" >&2; return 1; }

    nca_section_info "$control_nca" "$KEYS" 0
    local key section_bin data_off data_size
    key="$(nca_content_key_standard "$control_nca" "$KEYS")" || return 1
    section_bin="$(mktemp)"
    nca_ctr_decrypt_section "$control_nca" "$key" "$NCA_SECTION_CTR" "$NCA_SECTION_OFFSET" "$NCA_SECTION_SIZE" "$section_bin" || { rm -f "$section_bin"; return 1; }
    read -r data_off data_size <<< "$(nca_hierarchical_integrity_data_layer "$control_nca" "$KEYS" 0)"

    local romfs_bin="$section_bin.romfs"
    tail -c +$((data_off + 1)) "$section_bin" | head -c "$data_size" > "$romfs_bin"
    rm -f "$section_bin"

    romfs_extract "$romfs_bin" "control.nacp" "$out_path"
    local rc=$?
    rm -f "$romfs_bin"
    return $rc
}

KEYS="$HOME/.switch/prod.keys"
OUT_DIR="$SCRIPT_DIR/merged"
INPUTS=()

usage() {
    echo "Usage: $0 [-o <output_dir>] [-k keys.dat] [<nsp-or-dir> ...]" >&2
    exit 1
}

while [ $# -gt 0 ]; do
    case "$1" in
        -o) OUT_DIR="$2"; shift 2 ;;
        -k) KEYS="$2"; shift 2 ;;
        -*) usage ;;
        *) INPUTS+=("$1"); shift ;;
    esac
done

# With no positional inputs at all, default to scanning the directory this
# script itself lives in - so `./switch-merge.sh` with no args just works
# regardless of the caller's cwd, matching how ./bin is resolved above.
[ "${#INPUTS[@]}" -gt 0 ] || INPUTS=("$SCRIPT_DIR")
[ -f "$KEYS" ] || { echo "Keys file not found: $KEYS" >&2; exit 1; }
command -v xxd >/dev/null || { echo "xxd not found in PATH (needed by lib/binfmt.sh; ships with vim/vim-common)" >&2; exit 1; }
command -v openssl >/dev/null || { echo "openssl not found in PATH (needed by lib/nca_header.sh)" >&2; exit 1; }

# Expand any directory inputs to the *.nsp files directly inside them
# (non-recursive), and pass individual file inputs through unchanged.
CANDIDATE_NSPS=()
for input in "${INPUTS[@]}"; do
    if [ -d "$input" ]; then
        while IFS= read -r -d '' f; do
            CANDIDATE_NSPS+=("$f")
        done < <(find "$input" -maxdepth 1 -iname '*.nsp' -print0)
    elif [ -f "$input" ]; then
        CANDIDATE_NSPS+=("$input")
    else
        echo "Input not found: $input" >&2
        exit 1
    fi
done
[ "${#CANDIDATE_NSPS[@]}" -gt 0 ] || { echo "No .nsp files found in given inputs" >&2; exit 1; }

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$OUT_DIR"

# Classifies an NSP by its cnmt content-meta Type (Application/Patch/
# AddOnContent) and its base title ID, without extracting the whole file -
# just the Meta NCA (found by listing the NSP's own PFS0 entries via
# lib/pfs0.sh's _pfs0_read_entries) and its cnmt payload (extract_cnmt_from_
# meta_nca, pure bash - see its own comment above), parsed via
# lib/binfmt.sh's parse_cnmt. No nstool call anywhere in this function.
# Echoes "<Type> <base_title_id>" on success.
#
# The two non-Application cnmt shapes name the "base title ID" field
# differently from Application's own TitleId - see README's "Switch
# content format, from scratch" section for the full explanation:
#   - Application cnmt: `TitleId` field IS the base title ID.
#   - Patch/AddOnContent cnmt: `TitleId` is this content's own id; the base
#                              title ID is in the `ApplicationId` field.
classify_nsp() {
    local nsp="$1"
    local tag="$2"
    local meta_name meta_nca cnmt_file base_id
    local name off size
    while read -r name off size; do
        [[ "$name" == *.cnmt.nca ]] && { meta_name="$name"; break; }
    done < <(_pfs0_read_entries "$nsp")
    [ -n "$meta_name" ] || { echo "Could not find Meta NCA in $nsp" >&2; return 1; }

    meta_nca="$WORK/classify_${tag}_meta.nca"
    pfs0_extract "$nsp" "$meta_name" "$meta_nca"

    cnmt_file="$WORK/classify_${tag}.cnmt"
    extract_cnmt_from_meta_nca "$meta_nca" "$cnmt_file" || return 1
    [ -s "$cnmt_file" ] || { echo "Could not find .cnmt inside Meta NCA of $nsp" >&2; return 1; }

    parse_cnmt "$cnmt_file"
    [ -n "$CNMT_TYPE_NAME" ] || { echo "Could not determine content-meta type of $nsp" >&2; return 1; }

    if [ "$CNMT_TYPE_NAME" = "Application" ]; then
        base_id="$CNMT_TITLE_ID"
    else
        base_id="$CNMT_APPLICATION_ID"
    fi
    [ -n "$base_id" ] || { echo "Could not determine base title id of $nsp" >&2; return 1; }

    echo "$CNMT_TYPE_NAME $base_id $CNMT_VERSION"
}

echo "==> Classifying ${#CANDIDATE_NSPS[@]} input NSP(s)"
declare -A GROUP_BASE=()
declare -A GROUP_BASE_VERSION=()
declare -A GROUP_UPDATE=()
declare -A GROUP_UPDATE_VERSION=()
declare -A GROUP_DLCS=()   # newline-separated list per group, since bash has no nested arrays
GROUP_ORDER=()             # preserves first-seen order of title ids

idx=0
for nsp in "${CANDIDATE_NSPS[@]}"; do
    idx=$((idx + 1))
    classify_out="$(classify_nsp "$nsp" "$idx")" || { echo "  Skipping $nsp (classification failed)" >&2; continue; }
    read -r nsp_type base_id nsp_version <<< "$classify_out"
    base_id="${base_id,,}"

    if [ -z "${GROUP_DLCS[$base_id]+x}" ]; then
        GROUP_ORDER+=("$base_id")
        GROUP_DLCS[$base_id]=""
    fi

    case "$nsp_type" in
        Application)
            # Keep the HIGHEST-version Application if more than one is
            # given for the same title - same reasoning as Patch below
            # (a real title dump can legitimately include more than one
            # base dump at different versions; picking whichever happened
            # to be classified first, rather than the newest, would be a
            # silent correctness bug, not just a cosmetic one).
            if [ -z "${GROUP_BASE[$base_id]+x}" ] || [ "$nsp_version" -gt "${GROUP_BASE_VERSION[$base_id]}" ]; then
                [ -n "${GROUP_BASE[$base_id]+x}" ] && echo "  Multiple base (Application) NSPs found for title $base_id: keeping '$nsp' (v$nsp_version) over '${GROUP_BASE[$base_id]}' (v${GROUP_BASE_VERSION[$base_id]})" >&2
                GROUP_BASE[$base_id]="$nsp"
                GROUP_BASE_VERSION[$base_id]="$nsp_version"
            else
                echo "  Multiple base (Application) NSPs found for title $base_id: keeping '${GROUP_BASE[$base_id]}' (v${GROUP_BASE_VERSION[$base_id]}) over '$nsp' (v$nsp_version)" >&2
            fi
            ;;
        Patch)
            # Keep the HIGHEST-version Patch, not just the first one seen -
            # `find`'s own directory-listing order (what CANDIDATE_NSPS is
            # built from) is filesystem-dependent, not sorted by anything
            # meaningful, so "first seen" could easily be the OLDER update
            # if a newer one happens to sort first. A real title with two
            # real update dumps at different versions is exactly the case
            # this matters for - silently merging an old update instead of
            # the latest would look like a successful merge with no error
            # at all, just wrong/outdated content.
            if [ -z "${GROUP_UPDATE[$base_id]+x}" ] || [ "$nsp_version" -gt "${GROUP_UPDATE_VERSION[$base_id]}" ]; then
                [ -n "${GROUP_UPDATE[$base_id]+x}" ] && echo "  Multiple update (Patch) NSPs found for title $base_id: keeping '$nsp' (v$nsp_version) over '${GROUP_UPDATE[$base_id]}' (v${GROUP_UPDATE_VERSION[$base_id]})" >&2
                GROUP_UPDATE[$base_id]="$nsp"
                GROUP_UPDATE_VERSION[$base_id]="$nsp_version"
            else
                echo "  Multiple update (Patch) NSPs found for title $base_id: keeping '${GROUP_UPDATE[$base_id]}' (v${GROUP_UPDATE_VERSION[$base_id]}) over '$nsp' (v$nsp_version)" >&2
            fi
            ;;
        AddOnContent)
            GROUP_DLCS[$base_id]="${GROUP_DLCS[$base_id]}"$'\n'"$nsp"
            ;;
        *)
            echo "  Unrecognized content-meta type '$nsp_type' for $nsp - skipping" >&2
            ;;
    esac
done

echo "==> Found ${#GROUP_ORDER[@]} title group(s)"

# Merges one title's base/update/DLC into a single installable NSP. Runs in
# its own subshell (called with `( merge_group ... )`) so a hard failure in
# one group - this function still relies on `exit` deep inside helpers below
# for simplicity - only ends that subshell, not the whole batch.
merge_group() {
    local BASE_NSP="$1" UPDATE_NSP="$2" title_id="$3"
    shift 3
    local DLC_NSPS=("$@")
    local GROUP_WORK="$WORK/group_${title_id}"
    mkdir -p "$GROUP_WORK"

    echo "==> [$title_id] Base: $(basename "$BASE_NSP")"
    [ -n "$UPDATE_NSP" ] && echo "==> [$title_id] Update: $(basename "$UPDATE_NSP")"
    for dlc in "${DLC_NSPS[@]+"${DLC_NSPS[@]}"}"; do
        echo "==> [$title_id] DLC: $(basename "$dlc")"
    done

    local PRIMARY_DIR="$GROUP_WORK/primary"
    local CNMT_DIR="$GROUP_WORK/primary_cnmt"
    local MERGE_DIR="$GROUP_WORK/merge_ncas"
    mkdir -p "$PRIMARY_DIR" "$CNMT_DIR" "$MERGE_DIR"

    local copy_nca_from
    copy_nca_from() {
        local dir="$1" id="$2"
        local src
        src="$(find "$dir" -maxdepth 1 -iname "${id}.nca" | head -n1)"
        [ -n "$src" ] || { echo "[$title_id] Could not locate NCA file for id $id in $dir" >&2; exit 1; }
        cp "$src" "$MERGE_DIR/"
    }

    # The "primary" source is whichever of update/base carries the
    # highest-versioned Program/Control/LegalInformation NCAs to build the
    # merged Meta NCA from. See README's "Switch content format, from
    # scratch" and "The debugging story" sections for the full explanation
    # of why this needs BKTR-delta reconstruction for some titles' updates.
    local PRIMARY_LABEL
    if [ -n "$UPDATE_NSP" ]; then
        echo "==> [$title_id] Extracting update NSP contents"
        extract_nsp "$UPDATE_NSP" "$PRIMARY_DIR"
        PRIMARY_LABEL="update"
    else
        echo "==> [$title_id] No update given; using base NSP as primary source"
        extract_nsp "$BASE_NSP" "$PRIMARY_DIR"
        PRIMARY_LABEL="base"
    fi

    local META_NCA
    META_NCA="$(find "$PRIMARY_DIR" -maxdepth 1 -name '*.cnmt.nca' | head -n1)"
    [ -n "$META_NCA" ] || { echo "[$title_id] Could not find Meta NCA in $PRIMARY_LABEL NSP" >&2; exit 1; }

    echo "==> [$title_id] Extracting $PRIMARY_LABEL cnmt"
    local CNMT_FILE="$CNMT_DIR/primary.cnmt"
    extract_cnmt_from_meta_nca "$META_NCA" "$CNMT_FILE" || exit 1
    [ -s "$CNMT_FILE" ] || { echo "[$title_id] Could not find .cnmt inside $PRIMARY_LABEL Meta NCA" >&2; exit 1; }

    parse_cnmt "$CNMT_FILE"

    local BASE_TITLE_ID
    if [ -n "$UPDATE_NSP" ]; then
        BASE_TITLE_ID="$CNMT_APPLICATION_ID"
    else
        BASE_TITLE_ID="$CNMT_TITLE_ID"
    fi
    local VERSION_DEC="$CNMT_VERSION"
    [ -n "$BASE_TITLE_ID" ] || { echo "[$title_id] Could not determine base title id from $PRIMARY_LABEL cnmt" >&2; exit 1; }
    [ -n "$VERSION_DEC" ] || { echo "[$title_id] Could not determine title version from $PRIMARY_LABEL cnmt" >&2; exit 1; }
    local VERSION_HEX
    VERSION_HEX="$(printf '%08x' "$VERSION_DEC")"

    local PROGRAM_NCA="$CNMT_PROGRAM_ID" CONTROL_NCA="$CNMT_CONTROL_ID" LEGAL_NCA="$CNMT_LEGALINFORMATION_ID"

    [ -n "$PROGRAM_NCA" ] || { echo "[$title_id] $PRIMARY_LABEL cnmt has no Program content" >&2; exit 1; }

    echo "==> [$title_id] Base title id: $BASE_TITLE_ID  version: 0x$VERSION_HEX  (source: $PRIMARY_LABEL)"

    # Does the primary source's Program NCA carry a RightsId (titlekey
    # crypto)? If so, and it's an update, its romfs partition is almost
    # always a BKTR delta against the base's romfs (Enc. Type "AesCtrEx"),
    # not a self-contained full replacement. Packing that delta NCA
    # standalone under the base title ID produces a Program NCA the
    # console/CFW recognizes as patch-formatted and refuses to run as an
    # application - see README for the full story.
    local PRIMARY_PROGRAM_SRC PROGRAM_RIGHTS_ID PROGRAM_PATH
    PRIMARY_PROGRAM_SRC="$(find "$PRIMARY_DIR" -maxdepth 1 -iname "${PROGRAM_NCA}.nca" | head -n1)"
    PROGRAM_RIGHTS_ID="$(nca_rights_id "$PRIMARY_PROGRAM_SRC" "$KEYS")"

    if [ -n "$PROGRAM_RIGHTS_ID" ] && [ -n "$UPDATE_NSP" ]; then
        echo "==> [$title_id] Update Program NCA is titlekey-crypto (RightsId $PROGRAM_RIGHTS_ID) - reconstructing full romfs/exefs against base"

        local BASE_DIR="$GROUP_WORK/base_for_reconstruct"
        mkdir -p "$BASE_DIR"
        extract_nsp "$BASE_NSP" "$BASE_DIR"

        local BASE_CNMT_NCA BASE_CNMT_FILE BASE_PROGRAM_NCA_ID BASE_PROGRAM_SRC
        BASE_CNMT_NCA="$(find "$BASE_DIR" -maxdepth 1 -name '*.cnmt.nca' | head -n1)"
        BASE_CNMT_FILE="$GROUP_WORK/base.cnmt"
        extract_cnmt_from_meta_nca "$BASE_CNMT_NCA" "$BASE_CNMT_FILE" || exit 1
        parse_cnmt "$BASE_CNMT_FILE"
        BASE_PROGRAM_NCA_ID="$CNMT_PROGRAM_ID"
        BASE_PROGRAM_SRC="$(find "$BASE_DIR" -maxdepth 1 -iname "${BASE_PROGRAM_NCA_ID}.nca" | head -n1)"

        # Pull each side's raw (still ticket-encrypted) titlekey via
        # parse_tik (lib/binfmt.sh, pure bash, no nstool call). This feeds
        # nca_content_key_titlekey (lib/nca_content.sh) below to derive the
        # actual AES-CTR content key - not the same as the raw
        # ticket-encrypted value itself, and not the same as nstool's own
        # verbose-dump "AES-CTR Key" either (that one needs the ticket
        # already resolved, which is exactly what this step is for).
        local extract_ticket_titlekey
        extract_ticket_titlekey() {
            local dir="$1"
            local tik
            tik="$(find "$dir" -maxdepth 1 -iname '*.tik' | head -n1)"
            [ -n "$tik" ] || { echo "[$title_id] No ticket found in $dir" >&2; exit 1; }
            parse_tik "$tik"
            echo "$TIK_TITLEKEY"
        }
        local BASE_TITLEKEY UPDATE_TITLEKEY
        BASE_TITLEKEY="$(extract_ticket_titlekey "$BASE_DIR")"
        UPDATE_TITLEKEY="$(extract_ticket_titlekey "$PRIMARY_DIR")"
        [ -n "$BASE_TITLEKEY" ] || { echo "[$title_id] Could not extract base titlekey" >&2; exit 1; }
        [ -n "$UPDATE_TITLEKEY" ] || { echo "[$title_id] Could not extract update titlekey" >&2; exit 1; }

        # Find each side's romfs section number (BKTR/CtrEx on the update,
        # plain AesCtr on the base - see lib/bktr.sh's header comment for
        # why the base doesn't need any BKTR-aware handling, just an
        # ordinary section decrypt) and the update's own exefs section
        # number (also plain AesCtr - only the romfs half is ever a BKTR
        # delta, confirmed on both this project's test titles).
        local sec base_romfs_section=-1 update_romfs_section=-1 update_exefs_section=-1
        for sec in 0 1 2 3; do
            nca_section_info "$BASE_PROGRAM_SRC" "$KEYS" "$sec"
            [ "$NCA_SECTION_PRESENT" = "1" ] && [ "$NCA_SECTION_CRYPT_TYPE" = "3" ] && base_romfs_section="$sec"
        done
        for sec in 0 1 2 3; do
            nca_section_info "$PRIMARY_PROGRAM_SRC" "$KEYS" "$sec"
            if [ "$NCA_SECTION_PRESENT" = "1" ]; then
                [ "$NCA_SECTION_CRYPT_TYPE" = "4" ] && update_romfs_section="$sec"
                [ "$NCA_SECTION_CRYPT_TYPE" = "3" ] && update_exefs_section="$sec"
            fi
        done
        [ "$base_romfs_section" -ge 0 ] || { echo "[$title_id] Could not find base Program NCA's romfs section" >&2; exit 1; }
        [ "$update_romfs_section" -ge 0 ] || { echo "[$title_id] Could not find update Program NCA's BKTR romfs section" >&2; exit 1; }
        [ "$update_exefs_section" -ge 0 ] || { echo "[$title_id] Could not find update Program NCA's exefs section" >&2; exit 1; }

        # Decrypt the base's own romfs section directly - no need for
        # hactool --plaintext's non-standard intermediate NCA container at
        # all, lib/bktr.sh's bktr_reconstruct only needs the base's raw
        # decrypted romfs section bytes (see that file's own header
        # comment on why hactool's --basenca input is just indexed by
        # plain byte offset once decrypted, nothing NCA-container-specific
        # about it).
        local BASE_ROMFS_DECRYPTED="$GROUP_WORK/base_romfs_decrypted.bin"
        nca_section_info "$BASE_PROGRAM_SRC" "$KEYS" "$base_romfs_section"
        local base_key
        base_key="$(nca_content_key_titlekey "$BASE_TITLEKEY" "$(nca_crypto_type "$BASE_PROGRAM_SRC" "$KEYS")" "$KEYS")"
        nca_ctr_decrypt_section "$BASE_PROGRAM_SRC" "$base_key" "$NCA_SECTION_CTR" "$NCA_SECTION_OFFSET" "$NCA_SECTION_SIZE" "$BASE_ROMFS_DECRYPTED" || exit 1

        # Reconstruct the update's full virtual romfs (lib/bktr.sh, pure
        # bash - see that file's header comment for the relocation/
        # subsection bucket-tree walk this replaces hactool --basenca
        # with), then extract both it and the update's own (non-BKTR)
        # exefs section into real directory trees, since hacpack's
        # --exefsdir/--romfsdir below want directories, not raw blobs.
        local update_key
        update_key="$(nca_content_key_titlekey "$UPDATE_TITLEKEY" "$(nca_crypto_type "$PRIMARY_PROGRAM_SRC" "$KEYS")" "$KEYS")"
        local RECON_ROMFS_BLOB="$GROUP_WORK/recon_romfs_blob.bin"
        bktr_reconstruct "$PRIMARY_PROGRAM_SRC" "$KEYS" "$update_key" "$update_romfs_section" "$BASE_ROMFS_DECRYPTED" "$RECON_ROMFS_BLOB" || exit 1
        rm -f "$BASE_ROMFS_DECRYPTED"

        local RECON_EXEFS="$GROUP_WORK/recon_exefs"
        local RECON_ROMFS="$GROUP_WORK/recon_romfs"
        read -r romfs_data_off romfs_data_size <<< "$(nca_hierarchical_integrity_data_layer "$PRIMARY_PROGRAM_SRC" "$KEYS" "$update_romfs_section")"
        local RECON_ROMFS_DATA="$GROUP_WORK/recon_romfs_data.bin"
        tail -c +$((romfs_data_off + 1)) "$RECON_ROMFS_BLOB" | head -c "$romfs_data_size" > "$RECON_ROMFS_DATA"
        rm -f "$RECON_ROMFS_BLOB"
        romfs_extract_all "$RECON_ROMFS_DATA" "$RECON_ROMFS"
        rm -f "$RECON_ROMFS_DATA"

        nca_section_info "$PRIMARY_PROGRAM_SRC" "$KEYS" "$update_exefs_section"
        local EXEFS_SECTION_BIN="$GROUP_WORK/exefs_section.bin"
        nca_ctr_decrypt_section "$PRIMARY_PROGRAM_SRC" "$update_key" "$NCA_SECTION_CTR" "$NCA_SECTION_OFFSET" "$NCA_SECTION_SIZE" "$EXEFS_SECTION_BIN" || exit 1
        read -r exefs_data_off exefs_data_size <<< "$(nca_hierarchical_sha256_data_layer "$PRIMARY_PROGRAM_SRC" "$KEYS" "$update_exefs_section")"
        local EXEFS_PFS0="$GROUP_WORK/exefs_pfs0.bin"
        tail -c +$((exefs_data_off + 1)) "$EXEFS_SECTION_BIN" | head -c "$exefs_data_size" > "$EXEFS_PFS0"
        rm -f "$EXEFS_SECTION_BIN"

        # Keep the exefs' own original container order (lib/pfs0.sh's
        # _pfs0_read_entries) rather than extracting to a directory and
        # re-scanning it - filesystem readdir() order isn't guaranteed to
        # reproduce the original PFS0 order, and lib/nca_build.sh's
        # nca_build_program needs the real order explicitly (see that
        # function's own comment for why). Specifically the REVERSE of
        # the PFS0 entry table's own order - confirmed by directly
        # comparing against nstool -x's own on-disk write order for the
        # same real file (nstool -x writes files in the reverse of their
        # PFS0 table order, an nstool-internal quirk, not anything
        # meaningful about the format itself - but this project's own
        # prior verified reference outputs were all built via nstool -x
        # extraction, so matching that exact order is what byte-for-byte
        # continuity with those references actually requires).
        pfs0_extract_all "$EXEFS_PFS0" "$RECON_EXEFS"
        local EXEFS_FILES=()
        local exefs_name exefs_off exefs_size
        while read -r exefs_name exefs_off exefs_size; do
            EXEFS_FILES=("$RECON_EXEFS/$exefs_name" "${EXEFS_FILES[@]}")
        done < <(_pfs0_read_entries "$EXEFS_PFS0")
        rm -f "$EXEFS_PFS0"

        echo "==> [$title_id] Rebuilding standalone (non-titlekey) Program NCA from reconstructed content"
        local REBUILT_PROGRAM_NCA="$GROUP_WORK/rebuilt_program.nca"
        nca_build_program "$REBUILT_PROGRAM_NCA" "$KEYS" "$BASE_TITLE_ID" EXEFS_FILES "$RECON_ROMFS" || exit 1

        local REBUILT_PROGRAM_ID
        REBUILT_PROGRAM_ID="$(_nca_build_content_id_from_nca "$REBUILT_PROGRAM_NCA")"
        cp "$REBUILT_PROGRAM_NCA" "$MERGE_DIR/${REBUILT_PROGRAM_ID}.nca"
        PROGRAM_PATH="$MERGE_DIR/${REBUILT_PROGRAM_ID}.nca"
    else
        copy_nca_from "$PRIMARY_DIR" "$PROGRAM_NCA"
        PROGRAM_PATH="$MERGE_DIR/${PROGRAM_NCA}.nca"

        # If the primary source's NCAs are titlekey-crypto but there's no
        # BKTR delta concern (e.g. base-only, no update given), the console
        # still needs the matching ticket/cert to derive the titlekey at
        # install time. Carry them into the output PFS0 alongside the NCAs;
        # harmless if the NCAs are standard-crypto.
        for f in "$PRIMARY_DIR"/*.tik "$PRIMARY_DIR"/*.cert; do
            [ -e "$f" ] || continue
            cp "$f" "$MERGE_DIR/"
        done
    fi

    local CONTROL_NCA_PATH="" LEGAL_NCA_PATH=""
    if [ -n "$CONTROL_NCA" ]; then
        copy_nca_from "$PRIMARY_DIR" "$CONTROL_NCA"
        CONTROL_NCA_PATH="$MERGE_DIR/${CONTROL_NCA}.nca"
    fi
    if [ -n "$LEGAL_NCA" ]; then
        copy_nca_from "$PRIMARY_DIR" "$LEGAL_NCA"
        LEGAL_NCA_PATH="$MERGE_DIR/${LEGAL_NCA}.nca"
    fi

    echo "==> [$title_id] Building merged Meta NCA (application, base title id)"
    # The cnmt's trailing 32-byte digest covers the cnmt's own bytes,
    # which aren't known ahead of a build, so build once with a
    # placeholder digest, hash the resulting cnmt body, then rebuild
    # passing the real digest. See README's "The debugging story".
    local DRAFT_META_NCA="$GROUP_WORK/draft_meta.nca"
    nca_build_meta "$DRAFT_META_NCA" "$KEYS" "$BASE_TITLE_ID" "$VERSION_DEC" "$PROGRAM_PATH" "$CONTROL_NCA_PATH" "$LEGAL_NCA_PATH" "" "" || exit 1

    local DRAFT_CNMT_FILE="$GROUP_WORK/draft.cnmt"
    extract_cnmt_from_meta_nca "$DRAFT_META_NCA" "$DRAFT_CNMT_FILE" || exit 1
    [ -s "$DRAFT_CNMT_FILE" ] || { echo "[$title_id] Could not find .cnmt inside rebuilt Meta NCA" >&2; exit 1; }

    local CNMT_SIZE DIGEST
    CNMT_SIZE="$(stat -c%s "$DRAFT_CNMT_FILE")"
    DIGEST="$(head -c "$((CNMT_SIZE - 32))" "$DRAFT_CNMT_FILE" | sha256sum | cut -d' ' -f1)"

    local FINAL_META_NCA="$GROUP_WORK/final_meta.nca"
    nca_build_meta "$FINAL_META_NCA" "$KEYS" "$BASE_TITLE_ID" "$VERSION_DEC" "$PROGRAM_PATH" "$CONTROL_NCA_PATH" "$LEGAL_NCA_PATH" "" "$DIGEST" || exit 1
    local FINAL_META_ID
    FINAL_META_ID="$(_nca_build_content_id_from_nca "$FINAL_META_NCA")"
    cp "$FINAL_META_NCA" "$MERGE_DIR/${FINAL_META_ID}.cnmt.nca"

    # DLC titles install as separate sibling titles (type AddOnContent)
    # that merely reference the base ApplicationId - unlike the update,
    # their NCAs are NOT rewritten or merged into the base's Meta NCA. We
    # just copy each DLC's own Meta NCA and content NCA(s) into the output
    # directory as-is.
    local DLC_COUNT=0
    local dlc_nsp DLC_DIR DLC_META
    for dlc_nsp in "${DLC_NSPS[@]+"${DLC_NSPS[@]}"}"; do
        DLC_COUNT=$((DLC_COUNT + 1))
        DLC_DIR="$GROUP_WORK/dlc_$DLC_COUNT"
        mkdir -p "$DLC_DIR"

        echo "==> [$title_id] Extracting DLC NSP: $(basename "$dlc_nsp")"
        extract_nsp "$dlc_nsp" "$DLC_DIR"

        DLC_META="$(find "$DLC_DIR" -maxdepth 1 -name '*.cnmt.nca' | head -n1)"
        [ -n "$DLC_META" ] || { echo "[$title_id] Could not find Meta NCA in DLC NSP: $dlc_nsp" >&2; exit 1; }

        echo "==> [$title_id] Copying DLC NCAs into merged output"
        for f in "$DLC_DIR"/*.nca; do
            cp "$f" "$MERGE_DIR/"
        done
        for f in "$DLC_DIR"/*.tik "$DLC_DIR"/*.cert; do
            [ -e "$f" ] || continue
            cp "$f" "$MERGE_DIR/"
        done
    done

    echo "==> [$title_id] Packing merged NSP"
    local PACKED_NSP="$OUT_DIR/${BASE_TITLE_ID,,}.nsp"
    local merge_files=()
    while IFS= read -r -d '' f; do
        merge_files+=("$f")
    done < <(find "$MERGE_DIR" -maxdepth 1 -type f -print0 | sort -z)
    pfs0_pack "$PACKED_NSP" "${merge_files[@]}"
    local RESULT

    # Rename to "<Name> [<TitleId>][<DisplayVersion>][<DLC count>].nsp"
    # using the game name and human-readable version from the Control
    # NCA's NACP - the cnmt's own Version field is an internal integer
    # (e.g. v65536), not the "1.2.12"-style string players actually see.
    if [ -n "$CONTROL_NCA" ] && [ -f "$PACKED_NSP" ]; then
        local NACP_FILE="$GROUP_WORK/control.nacp"
        extract_nacp_from_control_nca "$MERGE_DIR/${CONTROL_NCA}.nca" "$NACP_FILE" || NACP_FILE=""

        local GAME_NAME="" DISPLAY_VERSION=""
        if [ -n "$NACP_FILE" ] && [ -s "$NACP_FILE" ]; then
            parse_nacp "$NACP_FILE"
            GAME_NAME="$NACP_NAME"
            DISPLAY_VERSION="$NACP_DISPLAY_VERSION"
        fi

        if [ -n "$GAME_NAME" ] && [ -n "$DISPLAY_VERSION" ]; then
            local SAFE_NAME
            SAFE_NAME="$(echo "$GAME_NAME" | tr -d '/\\:*?"<>|')"
            RESULT="$OUT_DIR/${SAFE_NAME} [${BASE_TITLE_ID^^}][${DISPLAY_VERSION}][${DLC_COUNT}].nsp"
            mv "$PACKED_NSP" "$RESULT"
        else
            echo "[$title_id] Could not read game name/version from NACP; leaving output as-is" >&2
            RESULT="$PACKED_NSP"
        fi
    else
        RESULT="$PACKED_NSP"
    fi

    if [ -f "$RESULT" ]; then
        echo "==> [$title_id] Done: $RESULT"
    else
        echo "==> [$title_id] Done: check $OUT_DIR for output NSP"
    fi
}

SUCCESS_TITLES=()
FAILED_TITLES=()

for title_id in "${GROUP_ORDER[@]}"; do
    base_nsp="${GROUP_BASE[$title_id]:-}"
    if [ -z "$base_nsp" ]; then
        echo "==> [$title_id] Skipping: no base (Application) NSP found for this title" >&2
        FAILED_TITLES+=("$title_id (no base NSP)")
        continue
    fi
    update_nsp="${GROUP_UPDATE[$title_id]:-}"

    dlc_list=()
    if [ -n "${GROUP_DLCS[$title_id]}" ]; then
        while IFS= read -r line; do
            [ -n "$line" ] && dlc_list+=("$line")
        done <<< "${GROUP_DLCS[$title_id]}"
    fi

    # Run in a subshell so a hard failure deep inside merge_group (which
    # relies on plain `exit 1` in several helpers) only ends this group,
    # not the whole batch. Bash disables `set -e` semantics for any command
    # whose exit status is directly tested (if/while/&&/||/!) - and that
    # exemption reaches through into a subshell's own `set -e` too - so the
    # subshell must be called as a bare, untested statement (with the
    # script's own -e toggled off around it) for its internal -e to work,
    # and its exit code captured via $? immediately after.
    set +e
    ( set -e; merge_group "$base_nsp" "$update_nsp" "$title_id" "${dlc_list[@]+"${dlc_list[@]}"}" )
    group_rc=$?
    set -e
    if [ "$group_rc" -eq 0 ]; then
        SUCCESS_TITLES+=("$title_id")
    else
        echo "==> [$title_id] Merge failed - see errors above" >&2
        FAILED_TITLES+=("$title_id (merge failed)")
    fi
done

echo
echo "==> Batch summary: ${#SUCCESS_TITLES[@]} succeeded, ${#FAILED_TITLES[@]} failed"
for t in "${SUCCESS_TITLES[@]+"${SUCCESS_TITLES[@]}"}"; do
    echo "  OK   $t"
done
for t in "${FAILED_TITLES[@]+"${FAILED_TITLES[@]}"}"; do
    echo "  FAIL $t"
done

[ "${#FAILED_TITLES[@]}" -eq 0 ]
