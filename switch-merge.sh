#!/usr/bin/env bash
# Merge one or more Switch base-game NSPs, each with (optionally) its own
# update NSP and (optionally) any number of DLC NSPs, into one installable
# NSP per title (1G1R: one game, one ROM).
# Usage: switch-merge.sh -o <output_dir> [-k keys.dat] <nsp-or-dir> ...
#
# Base/update/DLC are auto-detected from each NSP's own cnmt content-meta
# Type field (Application/Patch/AddOnContent) - not from filenames - and
# grouped by base title ID, so a single directory containing multiple
# different games (each with their own base/update/DLC) can be merged in
# one run. Each group is merged independently; one group failing does not
# stop the others.
set -euo pipefail

# Prefer the vendored copies of nstool/hacpack/hactool in ./bin (relative to
# this script's own location, not the caller's cwd) over any system-wide
# install, so the project is self-contained and doesn't depend on whatever
# version happens to be on PATH. Falls back to PATH if ./bin doesn't have
# them (e.g. a fresh checkout without the binaries vendored in yet).
# ./bin/hactool specifically carries a local fix for two real, confirmed
# bugs in upstream hactool 1.4.0's BKTR (patch-romfs) layout validation that
# reject some legitimate update NCAs ("Invalid BKTR layout!" / silently
# empty romfs extraction) - see README's "The debugging story" for the
# investigation and exact patch. Do not casually swap this back to a
# system/AUR hactool without re-checking that fix is still needed/applied.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ -d "$SCRIPT_DIR/bin" ]; then
    PATH="$SCRIPT_DIR/bin:$PATH"
fi

KEYS="$HOME/.switch/prod.keys"
OUT_DIR="."
INPUTS=()

usage() {
    echo "Usage: $0 -o <output_dir> [-k keys.dat] <nsp-or-dir> ..." >&2
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

[ "${#INPUTS[@]}" -gt 0 ] || usage
[ -f "$KEYS" ] || { echo "Keys file not found: $KEYS" >&2; exit 1; }
command -v nstool >/dev/null || { echo "nstool not found in PATH" >&2; exit 1; }
command -v hacpack >/dev/null || { echo "hacpack not found in PATH" >&2; exit 1; }
command -v hactool >/dev/null || { echo "hactool not found in PATH" >&2; exit 1; }

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

# Parses a cnmt (given verbose `nstool -t cnmt -v` output) and echoes the NCA
# id for the first ContentInfo entry of the given type (Program, Control,
# LegalInformation, Data, ...), or nothing if absent.
find_content_id() {
    local cnmt_info="$1" type="$2"
    echo "$cnmt_info" | grep -A2 "Type:.*${type}" | grep -oP 'Id:\s*\K[0-9a-fA-F]+' | head -n1
}

# Classifies an NSP by its cnmt content-meta Type (Application/Patch/
# AddOnContent) and its base title ID, without extracting the whole file -
# just the Meta NCA (found via --fstree's virtual path listing) and its
# cnmt payload. Echoes "<Type> <base_title_id>" on success.
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
    local meta_name meta_nca cnmt_dir cnmt_file cnmt_info nsp_type base_id
    meta_name="$(nstool -k "$KEYS" --fstree "$nsp" 2>/dev/null | grep -oP '[0-9a-fA-F]+\.cnmt\.nca' | head -n1)"
    [ -n "$meta_name" ] || { echo "Could not find Meta NCA in $nsp" >&2; return 1; }

    meta_nca="$WORK/classify_${tag}_meta.nca"
    nstool -k "$KEYS" -x "/${meta_name}" "$meta_nca" "$nsp" >/dev/null

    cnmt_dir="$WORK/classify_${tag}_cnmt"
    mkdir -p "$cnmt_dir"
    nstool -k "$KEYS" -t nca -x "$cnmt_dir" "$meta_nca" >/dev/null
    cnmt_file="$(find "$cnmt_dir" -name '*.cnmt' | head -n1)"
    [ -n "$cnmt_file" ] || { echo "Could not find .cnmt inside Meta NCA of $nsp" >&2; return 1; }

    cnmt_info="$(nstool -k "$KEYS" -t cnmt -v "$cnmt_file" 2>/dev/null)"
    nsp_type="$(echo "$cnmt_info" | grep -m1 -oP 'Type:\s*\K\S+')"
    [ -n "$nsp_type" ] || { echo "Could not determine content-meta type of $nsp" >&2; return 1; }

    if [ "$nsp_type" = "Application" ]; then
        base_id="$(echo "$cnmt_info" | grep -oP 'TitleId:\s*0x\K[0-9a-fA-F]+' | head -n1)"
    else
        base_id="$(echo "$cnmt_info" | grep -oP 'ApplicationId:\s*0x\K[0-9a-fA-F]+' | head -n1)"
    fi
    [ -n "$base_id" ] || { echo "Could not determine base title id of $nsp" >&2; return 1; }

    echo "$nsp_type $base_id"
}

echo "==> Classifying ${#CANDIDATE_NSPS[@]} input NSP(s)"
declare -A GROUP_BASE=()
declare -A GROUP_UPDATE=()
declare -A GROUP_DLCS=()   # newline-separated list per group, since bash has no nested arrays
GROUP_ORDER=()             # preserves first-seen order of title ids

idx=0
for nsp in "${CANDIDATE_NSPS[@]}"; do
    idx=$((idx + 1))
    classify_out="$(classify_nsp "$nsp" "$idx")" || { echo "  Skipping $nsp (classification failed)" >&2; continue; }
    nsp_type="${classify_out% *}"
    base_id="${classify_out#* }"
    base_id="${base_id,,}"

    if [ -z "${GROUP_DLCS[$base_id]+x}" ]; then
        GROUP_ORDER+=("$base_id")
        GROUP_DLCS[$base_id]=""
    fi

    case "$nsp_type" in
        Application)
            if [ -n "${GROUP_BASE[$base_id]+x}" ]; then
                echo "  Multiple base (Application) NSPs found for title $base_id: '${GROUP_BASE[$base_id]}' and '$nsp' - skipping the latter" >&2
            else
                GROUP_BASE[$base_id]="$nsp"
            fi
            ;;
        Patch)
            if [ -n "${GROUP_UPDATE[$base_id]+x}" ]; then
                echo "  Multiple update (Patch) NSPs found for title $base_id: '${GROUP_UPDATE[$base_id]}' and '$nsp' - skipping the latter" >&2
            else
                GROUP_UPDATE[$base_id]="$nsp"
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
        nstool -k "$KEYS" -x "$PRIMARY_DIR" "$UPDATE_NSP" >/dev/null
        PRIMARY_LABEL="update"
    else
        echo "==> [$title_id] No update given; using base NSP as primary source"
        nstool -k "$KEYS" -x "$PRIMARY_DIR" "$BASE_NSP" >/dev/null
        PRIMARY_LABEL="base"
    fi

    local META_NCA
    META_NCA="$(find "$PRIMARY_DIR" -maxdepth 1 -name '*.cnmt.nca' | head -n1)"
    [ -n "$META_NCA" ] || { echo "[$title_id] Could not find Meta NCA in $PRIMARY_LABEL NSP" >&2; exit 1; }

    echo "==> [$title_id] Extracting $PRIMARY_LABEL cnmt"
    nstool -k "$KEYS" -t nca -x "$CNMT_DIR" "$META_NCA" >/dev/null
    local CNMT_FILE
    CNMT_FILE="$(find "$CNMT_DIR" -name '*.cnmt' | head -n1)"
    [ -n "$CNMT_FILE" ] || { echo "[$title_id] Could not find .cnmt inside $PRIMARY_LABEL Meta NCA" >&2; exit 1; }

    local CNMT_INFO
    CNMT_INFO="$(nstool -k "$KEYS" -t cnmt -v "$CNMT_FILE")"

    local BASE_TITLE_ID
    if [ -n "$UPDATE_NSP" ]; then
        BASE_TITLE_ID="$(echo "$CNMT_INFO" | grep -oP 'ApplicationId:\s*0x\K[0-9a-fA-F]+')"
    else
        BASE_TITLE_ID="$(echo "$CNMT_INFO" | grep -oP 'TitleId:\s*0x\K[0-9a-fA-F]+' | head -n1)"
    fi
    local VERSION_DEC
    VERSION_DEC="$(echo "$CNMT_INFO" | grep -oP 'Version:.*\(v\K[0-9]+(?=\))' | head -n1)"
    [ -n "$BASE_TITLE_ID" ] || { echo "[$title_id] Could not determine base title id from $PRIMARY_LABEL cnmt" >&2; exit 1; }
    [ -n "$VERSION_DEC" ] || { echo "[$title_id] Could not determine title version from $PRIMARY_LABEL cnmt" >&2; exit 1; }
    local VERSION_HEX
    VERSION_HEX="$(printf '%08x' "$VERSION_DEC")"

    local PROGRAM_NCA CONTROL_NCA LEGAL_NCA
    PROGRAM_NCA="$(find_content_id "$CNMT_INFO" Program)"
    CONTROL_NCA="$(find_content_id "$CNMT_INFO" Control)"
    LEGAL_NCA="$(find_content_id "$CNMT_INFO" LegalInformation)"

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
    PROGRAM_RIGHTS_ID="$(nstool -k "$KEYS" -t nca -v "$PRIMARY_PROGRAM_SRC" 2>/dev/null | grep -oP 'RightsId:\s*\K[0-9A-Fa-f]+' | head -n1)"

    if [ -n "$PROGRAM_RIGHTS_ID" ] && [ -n "$UPDATE_NSP" ]; then
        echo "==> [$title_id] Update Program NCA is titlekey-crypto (RightsId $PROGRAM_RIGHTS_ID) - reconstructing full romfs/exefs against base"

        local BASE_DIR="$GROUP_WORK/base_for_reconstruct"
        mkdir -p "$BASE_DIR"
        nstool -k "$KEYS" -x "$BASE_DIR" "$BASE_NSP" >/dev/null

        local BASE_CNMT_NCA BASE_CNMT_EXTRACT_DIR BASE_CNMT_FILE BASE_CNMT_INFO BASE_PROGRAM_NCA_ID BASE_PROGRAM_SRC
        BASE_CNMT_NCA="$(find "$BASE_DIR" -maxdepth 1 -name '*.cnmt.nca' | head -n1)"
        BASE_CNMT_EXTRACT_DIR="$GROUP_WORK/base_cnmt_extract"
        mkdir -p "$BASE_CNMT_EXTRACT_DIR"
        nstool -k "$KEYS" -t nca -x "$BASE_CNMT_EXTRACT_DIR" "$BASE_CNMT_NCA" >/dev/null
        BASE_CNMT_FILE="$(find "$BASE_CNMT_EXTRACT_DIR" -name '*.cnmt' | head -n1)"
        BASE_CNMT_INFO="$(nstool -k "$KEYS" -t cnmt -v "$BASE_CNMT_FILE")"
        BASE_PROGRAM_NCA_ID="$(find_content_id "$BASE_CNMT_INFO" Program)"
        BASE_PROGRAM_SRC="$(find "$BASE_DIR" -maxdepth 1 -iname "${BASE_PROGRAM_NCA_ID}.nca" | head -n1)"

        # Pull each side's raw (still ticket-encrypted) titlekey. This is
        # the value hactool's --titlekey wants - not the same as the
        # fully-decrypted AES-CTR content key nstool prints in its own
        # verbose NCA dump.
        local extract_ticket_titlekey
        extract_ticket_titlekey() {
            local dir="$1"
            local tik
            tik="$(find "$dir" -maxdepth 1 -iname '*.tik' | head -n1)"
            [ -n "$tik" ] || { echo "[$title_id] No ticket found in $dir" >&2; exit 1; }
            nstool -t tik -v "$tik" 2>/dev/null | grep -A4 "Title Key" | grep -oP '^\s+\K[0-9A-Fa-f]{32}$'
        }
        local BASE_TITLEKEY UPDATE_TITLEKEY
        BASE_TITLEKEY="$(extract_ticket_titlekey "$BASE_DIR")"
        UPDATE_TITLEKEY="$(extract_ticket_titlekey "$PRIMARY_DIR")"
        [ -n "$BASE_TITLEKEY" ] || { echo "[$title_id] Could not extract base titlekey" >&2; exit 1; }
        [ -n "$UPDATE_TITLEKEY" ] || { echo "[$title_id] Could not extract update titlekey" >&2; exit 1; }

        # hactool's --basenca needs a base NCA it can read without a second
        # key context, so decrypt the base Program NCA to plaintext first.
        local BASE_PLAINTEXT_NCA="$GROUP_WORK/base_program_plaintext.nca"
        hactool -k "$KEYS" --titlekey="$BASE_TITLEKEY" \
            --plaintext="$BASE_PLAINTEXT_NCA" \
            "$BASE_PROGRAM_SRC" >/dev/null 2>&1

        local RECON_EXEFS="$GROUP_WORK/recon_exefs"
        local RECON_ROMFS="$GROUP_WORK/recon_romfs"
        mkdir -p "$RECON_EXEFS" "$RECON_ROMFS"
        hactool -k "$KEYS" --titlekey="$UPDATE_TITLEKEY" \
            --basenca="$BASE_PLAINTEXT_NCA" \
            --exefsdir="$RECON_EXEFS" \
            --romfsdir="$RECON_ROMFS" \
            "$PRIMARY_PROGRAM_SRC" >/dev/null

        echo "==> [$title_id] Rebuilding standalone (non-titlekey) Program NCA from reconstructed content"
        local PROGRAM_BUILD_DIR="$GROUP_WORK/program_build"
        mkdir -p "$PROGRAM_BUILD_DIR"
        hacpack -k "$KEYS" \
            --type nca --ncatype program --plaintext \
            --exefsdir "$RECON_EXEFS" \
            --romfsdir "$RECON_ROMFS" \
            --titleid "$BASE_TITLE_ID" \
            -o "$PROGRAM_BUILD_DIR" >/dev/null

        local REBUILT_PROGRAM_NCA
        REBUILT_PROGRAM_NCA="$(find "$PROGRAM_BUILD_DIR" -maxdepth 1 -name '*.nca' | head -n1)"
        [ -n "$REBUILT_PROGRAM_NCA" ] || { echo "[$title_id] Program NCA rebuild did not produce output" >&2; exit 1; }
        cp "$REBUILT_PROGRAM_NCA" "$MERGE_DIR/"
        PROGRAM_PATH="$MERGE_DIR/$(basename "$REBUILT_PROGRAM_NCA")"
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

    local HACPACK_META_ARGS=(--programnca "$PROGRAM_PATH")

    if [ -n "$CONTROL_NCA" ]; then
        copy_nca_from "$PRIMARY_DIR" "$CONTROL_NCA"
        HACPACK_META_ARGS+=(--controlnca "$MERGE_DIR/${CONTROL_NCA}.nca")
    fi
    if [ -n "$LEGAL_NCA" ]; then
        copy_nca_from "$PRIMARY_DIR" "$LEGAL_NCA"
        HACPACK_META_ARGS+=(--legalnca "$MERGE_DIR/${LEGAL_NCA}.nca")
    fi

    echo "==> [$title_id] Building merged Meta NCA (application, base title id)"
    # hacpack leaves the cnmt's trailing 32-byte digest as all-zero unless
    # --digest is passed explicitly. The digest covers the cnmt's own
    # bytes, which aren't known ahead of a build, so build once with a
    # placeholder digest, hash the resulting cnmt body, then rebuild
    # passing the real digest. See README's "The debugging story".
    local META_BUILD_DIR="$GROUP_WORK/meta_build"
    mkdir -p "$META_BUILD_DIR"
    hacpack -k "$KEYS" \
        --type nca --ncatype meta \
        --titletype application \
        --titleid "$BASE_TITLE_ID" \
        --titleversion "$VERSION_HEX" \
        "${HACPACK_META_ARGS[@]}" \
        -o "$META_BUILD_DIR" >/dev/null

    local DRAFT_META_NCA
    DRAFT_META_NCA="$(find "$META_BUILD_DIR" -maxdepth 1 -name '*.cnmt.nca' | head -n1)"
    [ -n "$DRAFT_META_NCA" ] || { echo "[$title_id] Meta NCA build did not produce output" >&2; exit 1; }

    local DRAFT_CNMT_DIR="$GROUP_WORK/meta_build_cnmt"
    mkdir -p "$DRAFT_CNMT_DIR"
    nstool -k "$KEYS" -t nca -x "$DRAFT_CNMT_DIR" "$DRAFT_META_NCA" >/dev/null
    local DRAFT_CNMT_FILE
    DRAFT_CNMT_FILE="$(find "$DRAFT_CNMT_DIR" -name '*.cnmt' | head -n1)"
    [ -n "$DRAFT_CNMT_FILE" ] || { echo "[$title_id] Could not find .cnmt inside rebuilt Meta NCA" >&2; exit 1; }

    local CNMT_SIZE DIGEST
    CNMT_SIZE="$(stat -c%s "$DRAFT_CNMT_FILE")"
    DIGEST="$(head -c "$((CNMT_SIZE - 32))" "$DRAFT_CNMT_FILE" | sha256sum | cut -d' ' -f1)"

    hacpack -k "$KEYS" \
        --type nca --ncatype meta \
        --titletype application \
        --titleid "$BASE_TITLE_ID" \
        --titleversion "$VERSION_HEX" \
        "${HACPACK_META_ARGS[@]}" \
        --digest "$DIGEST" \
        -o "$MERGE_DIR" >/dev/null

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
        nstool -k "$KEYS" -x "$DLC_DIR" "$dlc_nsp" >/dev/null

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
    hacpack -k "$KEYS" \
        --type nsp \
        --ncadir "$MERGE_DIR" \
        --titleid "$BASE_TITLE_ID" \
        -o "$OUT_DIR" >/dev/null

    local PACKED_NSP="$OUT_DIR/${BASE_TITLE_ID,,}.nsp"
    local RESULT

    # Rename to "<Name> [<TitleId>][<DisplayVersion>][<DLC count>].nsp"
    # using the game name and human-readable version from the Control
    # NCA's NACP - the cnmt's own Version field is an internal integer
    # (e.g. v65536), not the "1.2.12"-style string players actually see.
    if [ -n "$CONTROL_NCA" ] && [ -f "$PACKED_NSP" ]; then
        local NACP_EXTRACT_DIR="$GROUP_WORK/nacp_extract"
        mkdir -p "$NACP_EXTRACT_DIR"
        nstool -k "$KEYS" -x "$NACP_EXTRACT_DIR" "$MERGE_DIR/${CONTROL_NCA}.nca" >/dev/null 2>&1
        local NACP_FILE
        NACP_FILE="$(find "$NACP_EXTRACT_DIR" -name '*.nacp' | head -n1)"

        local GAME_NAME="" DISPLAY_VERSION=""
        if [ -n "$NACP_FILE" ]; then
            local NACP_INFO
            NACP_INFO="$(nstool -t nacp -v "$NACP_FILE" 2>/dev/null)"
            GAME_NAME="$(echo "$NACP_INFO" | grep -m1 -oP 'Name:\s*\K.+' | sed 's/[[:space:]]*$//')"
            DISPLAY_VERSION="$(echo "$NACP_INFO" | grep -oP 'DisplayVersion:\s*\K\S+' | head -n1)"
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
