# Pure-bash RomFs *building* (writing a full romfs container from a real
# directory tree), so lib/nca_build.sh's Program NCA builder can reproduce
# hacpack's own romfs_build (romfs.c) byte-for-byte, instead of reusing
# this project's own BKTR-reconstructed romfs bytes directly.
#
# WHY THIS EXISTS, AND WHY THE SIMPLER SHORTCUT DOESN'T WORK: this
# project's BKTR reconstruction (lib/bktr.sh) already produces CONTENT-
# correct romfs bytes - every individual file's content matches, verified
# file-for-file against hacpack's own --basenca reconstruction. The
# assumption going in was that reusing those raw bytes directly (skip
# rebuilding the container, just re-hash it) would also match hacpack's
# own --romfsdir rebuild byte-for-byte, since hacpack "just" repackages
# the same files. That assumption was WRONG, confirmed by direct testing:
# hacpack's own romfs_build does its own independent directory-tree walk
# and re-derives entry/hash-table sizes and file offsets from scratch,
# and while the METADATA table sizes coincidentally matched in the one
# real title tested (same dir_hash_table_size/dir_table_size/
# file_hash_table_size/file_table_size), the actual FILE DATA PARTITION
# size differed by thousands of bytes - traced to files being written in
# a different order (hacpack's own build sorts alphabetically; a real
# Nintendo-built romfs's on-disk file order doesn't have to match, and in
# practice doesn't), which changes how 0x10-byte alignment gaps between
# consecutively-written files accumulate. There is no way to know a
# priori that reusing existing bytes will match without independently
# reimplementing this and checking - which is what this file does.
#
# ALGORITHM (derived directly from hacpack 1.36_r2's own romfs.c/romfs.h -
# this format is NOT documented anywhere else in this much operational
# detail; switchbrew's wiki covers the on-disk entry struct layout, which
# this project's own lib/romfs.sh (the READING half) already used, but
# not the construction algorithm: traversal order, hash-table sizing,
# offset assignment):
#   1. Recursively walk the input directory. At each directory, list
#      immediate children, split into subdirectories and files.
#   2. Build TWO orderings, both by plain string comparison (strcmp) on
#      each entry's own FULL path from the root (e.g. "/Data/Managed",
#      not just "Managed"), NOT filesystem/readdir order:
#        - "sibling" order: only entries within the SAME parent directory,
#          sorted - this becomes each directory's own child-directory
#          list (via the parent's `child` field) and file list (via the
#          parent's `file` field), chained through each entry's own
#          `sibling` field.
#        - "next" order: EVERY directory (respectively every file) in the
#          ENTIRE tree, in one single GLOBAL sorted order (still by each
#          entry's own full path, but compared globally, not just within
#          a parent) - used ONLY to assign entry_offset (the position
#          within the flat dir_table/file_table byte blob) and to walk
#          for file-data-partition offset assignment. This is a
#          DIFFERENT ordering from the sibling order despite using the
#          same comparator, and getting them confused produces a
#          structurally different (but still "valid-looking") tree.
#   3. Assign each file its own file_partition offset by walking the
#      global file "next" order, accumulating size + align-to-0x10 gaps.
#   4. Assign each directory/file its own entry_offset (position within
#      the flat entry table) by walking the global "next" order,
#      accumulating each entry's own on-disk size
#      (dir: 0x18+align(namelen,4), file: 0x20+align(namelen,4)).
#   5. Build two separate hash tables (directories, files) - size chosen
#      by romfs_get_hash_table_count (an odd count avoiding small prime
#      factors, NOT simply the entry count), each slot initialized to
#      0xFFFFFFFF, populated by walking the SAME global "next" order and
#      chaining collisions through each entry's own `hash` field (i.e.
#      each hash bucket is itself a linked list threaded through the
#      entries' own storage, not a separate probe sequence).
#   6. Write header + dir hash table + dir table + file hash table + file
#      table + (0x200-aligned) file data partition, in that order.
#
# VERIFIED: ran a real, independent `hacpack --type nca --ncatype program
# --plaintext --exefsdir ... --romfsdir ...` build against this project's
# own already-verified-correct extracted romfs directory tree, hard-linked
# its intermediate `program_sec1_ivfc_lvl6` (raw pre-hash romfs bytes) out
# from under hacpack's own temp-directory cleanup before it could delete
# it, and confirmed this file's own output matches that real file
# byte-for-byte (cmp) - see lib/nca_build.sh's own use of this file for
# the full Program-NCA-level verification on top of that.

# _romfs_build_reverse_hex <hex_string> -- byte-order reversal, same
# duplicated helper every lib/*.sh file has.
_romfs_build_reverse_hex() {
    local hex="$1"
    local out="" i
    for (( i = ${#hex} - 2; i >= 0; i -= 2 )); do
        out+="${hex:i:2}"
    done
    echo "$out"
}

# _romfs_build_le_hex <decimal_value> <byte_width>
_romfs_build_le_hex() {
    local value="$1" width="$2"
    local be_hex
    be_hex="$(printf "%0$((width * 2))x" "$value")"
    _romfs_build_reverse_hex "$be_hex"
}

# _romfs_build_align <value> <alignment_pow2>
_romfs_build_align() {
    local value="$1" alignment="$2"
    echo $(( (value + alignment - 1) & ~(alignment - 1) ))
}

# _romfs_build_hash_table_count <num_entries>
# Mirrors hacpack's romfs_get_hash_table_count exactly: an odd bucket
# count chosen to avoid small prime factors (2,3,5,7,11,13,17), NOT
# simply num_entries itself - confirmed this matters (a naive
# num_entries-sized table produces a different, wrong hash table size).
_romfs_build_hash_table_count() {
    local n="$1"
    if [ "$n" -lt 3 ]; then
        echo 3
        return
    fi
    if [ "$n" -lt 19 ]; then
        echo $(( n | 1 ))
        return
    fi
    local count="$n"
    while [ $(( count % 2 )) -eq 0 ] || [ $(( count % 3 )) -eq 0 ] || [ $(( count % 5 )) -eq 0 ] || \
          [ $(( count % 7 )) -eq 0 ] || [ $(( count % 11 )) -eq 0 ] || [ $(( count % 13 )) -eq 0 ] || \
          [ $(( count % 17 )) -eq 0 ]; do
        count=$(( count + 1 ))
    done
    echo "$count"
}

# _romfs_build_path_hash <parent_entry_offset_decimal> <name_ascii>
# Mirrors hacpack's calc_path_hash exactly: parent^123456789, then for
# each byte of name: rotate-right-5 (32-bit) then XOR in the byte. All
# arithmetic forced to stay within 32 bits (bash arithmetic is 64-bit
# signed, so this must mask explicitly - the rotate's left-shift term in
# particular would otherwise leak into bit 32+ and corrupt the result).
_romfs_build_path_hash() {
    local parent="$1" name="$2"
    local hash=$(( (parent ^ 123456789) & 0xFFFFFFFF ))
    local i byte
    for (( i = 0; i < ${#name}; i++ )); do
        byte="$(printf '%d' "'${name:i:1}")"
        hash=$(( ((hash >> 5) | ((hash << 27) & 0xFFFFFFFF)) & 0xFFFFFFFF ))
        hash=$(( hash ^ byte ))
    done
    echo "$hash"
}

# romfs_build <in_dir> <out_path>
# Builds a complete romfs container from a real directory tree at
# in_dir, writing it to out_path - the pure-bash mirror of hacpack's own
# romfs_build (romfs.c). See this file's own header comment for the full
# algorithm derivation and why the simpler "reuse already-reconstructed
# bytes" shortcut doesn't work.
#
# Root directory itself has an empty name (name_size=0) and entry_offset
# 0, matching hacpack's own root_ctx handling exactly (root_ctx->parent =
# root_ctx itself, i.e. self-referential - its OWN entry_offset, 0, is
# what "parent" points to for root, confirmed against a real file's own
# root entry: parent=0, and root's own entry_offset just happens to also
# be 0, so this looks like ordinary "no parent" but is actually
# "parent points to self").
romfs_build() {
    local in_dir="$1" out_path="$2"

    # --- Step 1: enumerate every directory and file, full romfs-relative
    # path (leading /, no trailing /), sorted by plain byte comparison
    # (LC_ALL=C, matching C's strcmp - a locale-aware sort would reorder
    # e.g. punctuation/case differently and silently produce a
    # structurally different, wrong tree). This "next" list order is used
    # for entry_offset assignment, file-partition offset assignment, and
    # hash-table population - NOT for parent/child/sibling structure,
    # which is built separately per-directory below.
    local -a all_dirs=() all_files=()
    local rel
    while IFS= read -r rel; do
        all_dirs+=("$rel")
    done < <(find "$in_dir" -mindepth 1 -type d | sed "s|^$in_dir||" | LC_ALL=C sort)
    while IFS= read -r rel; do
        all_files+=("$rel")
    done < <(find "$in_dir" -mindepth 1 -type f | sed "s|^$in_dir||" | LC_ALL=C sort)

    # --- Step 2: assign each directory/file an entry_offset by walking
    # the SAME sorted "next" list, root first (offset 0, size 0x18, no
    # name). NAME here is just the basename (last path component); each
    # entry's own on-disk size uses ONLY its own name's length, not the
    # full path.
    declare -A dir_offset dir_name dir_parent_path
    declare -A file_offset file_name file_size file_parent_path
    local entry_off=0
    dir_offset["/"]=0
    dir_name["/"]=""
    dir_parent_path["/"]=""
    entry_off=$((0x18))

    local d dname
    for d in "${all_dirs[@]}"; do
        dir_offset["$d"]="$entry_off"
        dname="${d##*/}"
        dir_name["$d"]="$dname"
        dir_parent_path["$d"]="${d%/*}"
        [ -z "${dir_parent_path[$d]}" ] && dir_parent_path["$d"]="/"
        entry_off=$(( entry_off + 0x18 + $(_romfs_build_align ${#dname} 4) ))
    done
    local dir_table_size="$entry_off"

    entry_off=0
    local f fname fsize
    for f in "${all_files[@]}"; do
        file_offset["$f"]="$entry_off"
        fname="${f##*/}"
        file_name["$f"]="$fname"
        file_parent_path["$f"]="${f%/*}"
        [ -z "${file_parent_path[$f]}" ] && file_parent_path["$f"]="/"
        fsize="$(stat -c%s "$in_dir$f")"
        file_size["$f"]="$fsize"
        entry_off=$(( entry_off + 0x20 + $(_romfs_build_align ${#fname} 4) ))
    done
    local file_table_size="$entry_off"

    # --- Step 3: assign each file's own file-partition byte offset by
    # walking the SAME sorted "next" list, 0x10-byte-aligning between
    # each (matches hacpack's own align64(file_partition_size, 0x10)
    # BEFORE placing each file, not after).
    declare -A file_partition_offset
    local partition_size=0
    for f in "${all_files[@]}"; do
        partition_size="$(_romfs_build_align "$partition_size" 16)"
        file_partition_offset["$f"]="$partition_size"
        partition_size=$(( partition_size + file_size[$f] ))
    done

    # --- Step 4: per-directory child/file/sibling chains. Group by
    # parent, in the SAME sorted order as the global list (a sort of a
    # subset of an already-sorted list stays sorted, so no re-sort
    # needed) - this reproduces hacpack's own per-parent "ordered
    # insertion on sibling" without needing a separate comparison pass.
    declare -A dir_child dir_sibling_next dir_last_child
    declare -A dir_file file_sibling_next dir_last_file
    dir_child["/"]="EMPTY"; dir_last_child["/"]=""
    dir_file["/"]="EMPTY"; dir_last_file["/"]=""

    for d in "${all_dirs[@]}"; do
        dir_child["$d"]="EMPTY"; dir_last_child["$d"]=""
        dir_file["$d"]="EMPTY"; dir_last_file["$d"]=""
    done

    for d in "${all_dirs[@]}"; do
        local p="${dir_parent_path[$d]}"
        if [ -z "${dir_last_child[$p]:-}" ]; then
            dir_child["$p"]="$d"
        else
            dir_sibling_next["${dir_last_child[$p]}"]="$d"
        fi
        dir_last_child["$p"]="$d"
    done
    for f in "${all_files[@]}"; do
        local p="${file_parent_path[$f]}"
        if [ -z "${dir_last_file[$p]:-}" ]; then
            dir_file["$p"]="$f"
        else
            file_sibling_next["${dir_last_file[$p]}"]="$f"
        fi
        dir_last_file["$p"]="$f"
    done

    # --- Step 5: hash tables ---
    local dir_hash_count file_hash_count
    dir_hash_count="$(_romfs_build_hash_table_count $(( ${#all_dirs[@]} + 1 )))"
    file_hash_count="$(_romfs_build_hash_table_count "${#all_files[@]}")"
    local -a dir_hash_table file_hash_table
    local i
    for (( i = 0; i < dir_hash_count; i++ )); do dir_hash_table[i]=4294967295; done
    for (( i = 0; i < file_hash_count; i++ )); do file_hash_table[i]=4294967295; done

    declare -A dir_hash_chain file_hash_chain
    # root first
    local rh rb
    rh="$(_romfs_build_path_hash 0 "")"
    rb=$(( rh % dir_hash_count ))
    dir_hash_chain["/"]="${dir_hash_table[$rb]}"
    dir_hash_table[$rb]="0"

    for d in "${all_dirs[@]}"; do
        local p="${dir_parent_path[$d]}"
        local parent_off="${dir_offset[$p]}"
        local h b
        h="$(_romfs_build_path_hash "$parent_off" "${dir_name[$d]}")"
        b=$(( h % dir_hash_count ))
        dir_hash_chain["$d"]="${dir_hash_table[$b]}"
        dir_hash_table[$b]="${dir_offset[$d]}"
    done
    for f in "${all_files[@]}"; do
        local p="${file_parent_path[$f]}"
        local parent_off="${dir_offset[$p]}"
        local h b
        h="$(_romfs_build_path_hash "$parent_off" "${file_name[$f]}")"
        b=$(( h % file_hash_count ))
        file_hash_chain["$f"]="${file_hash_table[$b]}"
        file_hash_table[$b]="${file_offset[$f]}"
    done

    # --- Step 6: write everything ---
    local work_dir
    work_dir="$(mktemp -d)"

    local dir_hash_table_size=$(( dir_hash_count * 4 ))
    local file_hash_table_size=$(( file_hash_count * 4 ))
    local file_partition_ofs=$((0x200))
    local dir_hash_table_ofs=$(( file_partition_ofs + partition_size ))
    local dir_table_ofs=$(( dir_hash_table_ofs + dir_hash_table_size ))
    local file_hash_table_ofs=$(( dir_table_ofs + dir_table_size ))
    local file_table_ofs=$(( file_hash_table_ofs + file_hash_table_size ))

    # Header (0x50 bytes)
    local header_hex=""
    header_hex+="$(_romfs_build_le_hex $((0x50)) 8)"
    header_hex+="$(_romfs_build_le_hex "$dir_hash_table_ofs" 8)"
    header_hex+="$(_romfs_build_le_hex "$dir_hash_table_size" 8)"
    header_hex+="$(_romfs_build_le_hex "$dir_table_ofs" 8)"
    header_hex+="$(_romfs_build_le_hex "$dir_table_size" 8)"
    header_hex+="$(_romfs_build_le_hex "$file_hash_table_ofs" 8)"
    header_hex+="$(_romfs_build_le_hex "$file_hash_table_size" 8)"
    header_hex+="$(_romfs_build_le_hex "$file_table_ofs" 8)"
    header_hex+="$(_romfs_build_le_hex "$file_table_size" 8)"
    header_hex+="$(_romfs_build_le_hex "$file_partition_ofs" 8)"
    printf '%s' "$header_hex" | xxd -r -p > "$work_dir/header.bin"

    # Dir hash table
    local dir_hash_hex=""
    for (( i = 0; i < dir_hash_count; i++ )); do
        dir_hash_hex+="$(_romfs_build_le_hex "${dir_hash_table[$i]}" 4)"
    done
    printf '%s' "$dir_hash_hex" | xxd -r -p > "$work_dir/dir_hash_table.bin"

    # Dir table - written in "next" (global sorted) order, root first.
    # Each entry: parent(4) sibling(4) child(4) file(4) hash(4)
    # name_size(4) name(aligned to 4).
    local dir_table_hex=""
    local child_val sibling_val file_val name_hex name_pad
    child_val="${dir_child[/]}"; [ "$child_val" = "EMPTY" ] && child_val=4294967295 || child_val="${dir_offset[$child_val]}"
    file_val="${dir_file[/]}"; [ "$file_val" = "EMPTY" ] && file_val=4294967295 || file_val="${file_offset[$file_val]}"
    dir_table_hex+="$(_romfs_build_le_hex 0 4)"            # parent (self, root)
    dir_table_hex+="$(_romfs_build_le_hex 4294967295 4)"    # sibling
    dir_table_hex+="$(_romfs_build_le_hex "$child_val" 4)"
    dir_table_hex+="$(_romfs_build_le_hex "$file_val" 4)"
    dir_table_hex+="$(_romfs_build_le_hex "${dir_hash_chain[/]}" 4)"
    dir_table_hex+="$(_romfs_build_le_hex 0 4)"             # name_size=0

    for d in "${all_dirs[@]}"; do
        local p="${dir_parent_path[$d]}"
        sibling_val="${dir_sibling_next[$d]:-}"; [ -z "$sibling_val" ] && sibling_val=4294967295 || sibling_val="${dir_offset[$sibling_val]}"
        child_val="${dir_child[$d]}"; [ "$child_val" = "EMPTY" ] && child_val=4294967295 || child_val="${dir_offset[$child_val]}"
        file_val="${dir_file[$d]}"; [ "$file_val" = "EMPTY" ] && file_val=4294967295 || file_val="${file_offset[$file_val]}"
        name_hex="$(printf '%s' "${dir_name[$d]}" | xxd -p | tr -d '\n')"
        name_pad=$(( $(_romfs_build_align ${#dir_name[$d]} 4) - ${#dir_name[$d]} ))
        dir_table_hex+="$(_romfs_build_le_hex "${dir_offset[$p]}" 4)"
        dir_table_hex+="$(_romfs_build_le_hex "$sibling_val" 4)"
        dir_table_hex+="$(_romfs_build_le_hex "$child_val" 4)"
        dir_table_hex+="$(_romfs_build_le_hex "$file_val" 4)"
        dir_table_hex+="$(_romfs_build_le_hex "${dir_hash_chain[$d]}" 4)"
        dir_table_hex+="$(_romfs_build_le_hex "${#dir_name[$d]}" 4)"
        dir_table_hex+="$name_hex"
        [ "$name_pad" -gt 0 ] && dir_table_hex+="$(printf '00%.0s' $(seq 1 "$name_pad"))"
    done
    printf '%s' "$dir_table_hex" | xxd -r -p > "$work_dir/dir_table.bin"

    # File hash table
    local file_hash_hex=""
    for (( i = 0; i < file_hash_count; i++ )); do
        file_hash_hex+="$(_romfs_build_le_hex "${file_hash_table[$i]}" 4)"
    done
    printf '%s' "$file_hash_hex" | xxd -r -p > "$work_dir/file_hash_table.bin"

    # File table - written in "next" (global sorted) order. Each entry:
    # parent(4) sibling(4) offset(8) size(8) hash(4) name_size(4)
    # name(aligned to 4).
    local file_table_hex=""
    for f in "${all_files[@]}"; do
        local p="${file_parent_path[$f]}"
        sibling_val="${file_sibling_next[$f]:-}"; [ -z "$sibling_val" ] && sibling_val=4294967295 || sibling_val="${file_offset[$sibling_val]}"
        name_hex="$(printf '%s' "${file_name[$f]}" | xxd -p | tr -d '\n')"
        name_pad=$(( $(_romfs_build_align ${#file_name[$f]} 4) - ${#file_name[$f]} ))
        file_table_hex+="$(_romfs_build_le_hex "${dir_offset[$p]}" 4)"
        file_table_hex+="$(_romfs_build_le_hex "$sibling_val" 4)"
        file_table_hex+="$(_romfs_build_le_hex "${file_partition_offset[$f]}" 8)"
        file_table_hex+="$(_romfs_build_le_hex "${file_size[$f]}" 8)"
        file_table_hex+="$(_romfs_build_le_hex "${file_hash_chain[$f]}" 4)"
        file_table_hex+="$(_romfs_build_le_hex "${#file_name[$f]}" 4)"
        file_table_hex+="$name_hex"
        [ "$name_pad" -gt 0 ] && file_table_hex+="$(printf '00%.0s' $(seq 1 "$name_pad"))"
    done
    printf '%s' "$file_table_hex" | xxd -r -p > "$work_dir/file_table.bin"

    # Assemble: header, pad to file_partition_ofs, files (each preceded
    # by whatever 0x10-alignment gap its own offset implies, i.e. laid
    # out exactly per file_partition_offset), pad to dir_hash_table_ofs,
    # then the four tables back-to-back (all already exactly the right
    # size, no further padding between them). Finally, the WHOLE output
    # gets padded to a 0x4000 (IVFC_HASH_BLOCK_SIZE) boundary - a real,
    # separate step from every other padding rule in this file, applied
    # by romfs_build's own OUTER wrapper (not build_romfs_into_file) after
    # everything else is written. Confirmed necessary and confirmed the
    # right constant: without it, output was short by exactly the gap
    # between a real hacpack-built romfs's total size and the next 0x4000
    # boundary above where this file's own four-tables math said it
    # should end.
    {
        cat "$work_dir/header.bin"
        head -c $(( file_partition_ofs - 0x50 )) /dev/zero
        local cur=0
        for f in "${all_files[@]}"; do
            local gap=$(( file_partition_offset[$f] - cur ))
            [ "$gap" -gt 0 ] && head -c "$gap" /dev/zero
            cat "$in_dir$f"
            cur=$(( file_partition_offset[$f] + file_size[$f] ))
        done
        local final_gap=$(( (dir_hash_table_ofs - file_partition_ofs) - cur ))
        [ "$final_gap" -gt 0 ] && head -c "$final_gap" /dev/zero
        cat "$work_dir/dir_hash_table.bin"
        cat "$work_dir/dir_table.bin"
        cat "$work_dir/file_hash_table.bin"
        cat "$work_dir/file_table.bin"
    } > "$out_path"

    local total_size padded_total pad_bytes
    total_size="$(stat -c%s "$out_path")"
    padded_total=$(( (total_size + 0x3FFF) & ~0x3FFF ))
    pad_bytes=$(( padded_total - total_size ))
    [ "$pad_bytes" -gt 0 ] && head -c "$pad_bytes" /dev/zero >> "$out_path"

    # Echo the UNPADDED size (before this final 0x4000-alignment step) -
    # this is exactly hacpack's own romfs_build return value AND its
    # *out_size param (both captured in its own source right after
    # build_romfs_into_file returns, BEFORE the padding fwrite happens),
    # which becomes the IVFC level_headers[5].hash_data_size field in the
    # caller (nca_create_program) - NOT the padded on-disk file size, a
    # real, confirmed distinction (level 5 is the only IVFC level whose
    # hash_data_size differs from its own final padded file size; levels
    # 0-4's hash_data_size correctly IS their own padded size, per
    # _nca_build_ivfc_level's own already-verified convention - mixing
    # these up was a real bug caught by a byte-for-byte mismatch against
    # a real hacpack-built Program NCA's IVFC header).
    echo "$total_size"

    rm -rf "$work_dir"
}
