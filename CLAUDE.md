# switch-merge

Bash CLI (`switch-merge.sh`) that merges a Nintendo Switch base-game NSP +
update NSP + any number of DLC NSPs into a single installable NSP, for one
or many games at once (1G1R). See `README.md` for full usage, pipeline
details, and known issues — that file is kept up to date and is the
primary reference. It now also has a "Switch content format, from
scratch" primer (NCA/cnmt/RightsId/BKTR/PFS0/AES-XTS concepts) and a "The
debugging story" narrative walking through all five real bugs found so
far — read those if a new title produces an unfamiliar error before
assuming it's something new. This file is for picking the workflow back
up quickly and for context `README.md` doesn't cover.

## Current state

Working and hardware-verified (installs cleanly, correct version shown,
game runs and plays correctly) for the base+update+DLC case using the test
title Dicefolk (`01002A801E57C000`). **Also now hardware-verified** for a
second real title, Super Smash Bros. Ultimate (`01006A800016E000`, base +
2 updates + 99 separate `AddOnContent` DLC NSPs), merged together with
Dicefolk in one real 1G1R batch run — confirmed installing and playing
correctly on real hardware. This is
by far the largest/most demanding title tested so far (14.6GB base NSP,
two ~3.9GB update NSPs) and surfaced two real bugs:
  - `classify_nsp`/the classification loop originally kept whichever
    Patch (update) NSP was seen first, not the highest-versioned one.
    Fixed by comparing each group's `Application`/`Patch` NSP against the
    cnmt's own version integer and keeping the higher one — confirmed
    working directly from a real merge log line: "Multiple update (Patch)
    NSPs found for title 01006a800016e000: keeping '...[v2031616][Up
    v13.0.5].nsp' (v2031616) over '...[v1966080]...nsp' (v1966080)".
  - `lib/bktr.sh`'s relocation/subsection table parsers only ever handled
    `num_buckets == 1` (true for every test title up to this point).
    Smash's update romfs is large enough to need a real bucket tree
    (29 relocation buckets, 9 subsection buckets) — hit a hard failure
    ("only 1 is supported") the first time a merge reached BKTR
    reconstruction for this title. Fixed by rewriting both parsers to walk
    every bucket; see "Non-obvious things worth remembering" below for the
    exact bucket-layout bug that came with that fix (a wrong stride
    guess). Confirmed fixed via a full merge run that produced
    `Super Smash Bros. Ultimate [01006A800016E000][13.0.5][99].nsp`
    (17.7GB output, 400 PFS0 entries: 99 `.tik` + 99 `.cert` + 100
    `.cnmt.nca` + 102 `.nca`) — the `13.0.5`/`99` in the filename itself
    confirms both the version-supersession fix and that all 99 DLCs made
    it into the merge.
  Merging multiple separate `AddOnContent` titles bundled into a single
  DLC NSP is still untested - every DLC NSP seen so far (Dicefolk,
  Talisman, and all 99 of Smash's) has turned out to contain exactly one
  `AddOnContent` title per file, even when a filename implied otherwise
  (see README's roadmap). Test files live in `roms/` (kept out of the
  project root for tidiness):

  **`.xci` (gamecard dump) input is also now supported**, alongside `.nsp`
  - new `lib/hfs0.sh` (HFS0 reader, XCI's PFS0-like partition format) plus
  `xci_split_to_nsps` in `switch-merge.sh`, which repacks an XCI's `secure`
  partition into one synthetic NSP per title found there (a single
  cartridge's secure partition can hold more than one independent title's
  NCAs side by side - confirmed against a real dump). Verified against
  three real XCI files (a real user library at `~/Downloads/switch2/`, not
  checked into this repo) - a single-title cartridge, a two-title
  cartridge (correctly split into two separate output NSPs with no
  cross-contamination, each verified via `nstool -t cnmt -v` to have the
  right TitleId/Type/content list), and a mixed XCI+NSP batch in one run.
  See README's new "XCI: the gamecard container format" section and the
  roadmap's "XCI input" entry for full detail.

- `Dicefolk [01002A801E57C000][B/U].nsp` + `Dicefolk Chimera Pack [...][D].nsp`
- `Super Smash Bros. Ultimate [01006A800016E000][B].nsp` + two `[01006A800016E800]`
  update NSPs (`v1966080` and `v2031616`/`Up v13.0.5`) + 99 separate
  `[01006A800016F0XX]` DLC NSPs

Usage is fully auto-detecting — no `-b`/`-u`/per-DLC flags, and handles
multiple different games in one run. With zero arguments it defaults to
scanning the directory the script itself lives in and writing to
`merged/` next to it:

```
./switch-merge.sh
```

Every `.nsp` found (individual files or globbed one level deep from a
directory arg) gets classified by its own cnmt content-meta `Type`
(`Application`/`Patch`/`AddOnContent`) — parsed by this project's own
`lib/binfmt.sh`, not `nstool` — and grouped by base title ID — **1G1R
batch mode**: a directory mixing several different games' base/update/DLC
files together merges each into its own output NSP in one run, one merge
per group, failures in one group don't stop the others.

**The project is self-contained AND has zero runtime dependency on any
vendored tool.** `nstool`/`hacpack`/`hactool` still live in `bin/` (which
the script puts first on `PATH` automatically) purely for optional manual
debugging/cross-verification — **all three are fully eliminated from the
merge pipeline**, confirmed by temporarily replacing all three vendored
`bin/` binaries at once with wrappers that fail loudly if invoked, then
re-running a full 1G1R batch merge of both test titles end-to-end: none
of them ever fired. Everything, including final NCA/hash-tree building,
is pure bash: `lib/binfmt.sh` reads cnmt/NACP/`.tik` directly,
`lib/nca_header.sh` decrypts (and, as of the final piece, ENCRYPTS —
`xts_encrypt_sector`/`nca_encrypt_header`) the NCA header (AES-XTS, built
from raw `openssl enc -aes-128-ecb` since `openssl enc` has no XTS mode of
its own), `lib/nca_content.sh` derives per-title content keys (AES-128-ECB
unwrap of the header's key area, or of a ticket's titlekey via
`titlekek_<gen>`) and decrypts/encrypts a content section via one
`openssl enc -aes-128-ctr` call (CTR is its own inverse, confirmed by a
round-trip test), `lib/pfs0.sh` both packs AND unpacks PFS0 containers,
`lib/romfs.sh` reads RomFs content (flat lookup for Control NCA →
`control.nacp`, full recursive extraction for BKTR-reconstructed content),
`lib/bktr.sh` reimplements BKTR (patch-romfs) delta reconstruction,
`lib/romfs_build.sh` reimplements hacpack's own `romfs_build` (a full
directory-tree-to-romfs-container builder — sorted traversal, custom path
hash, odd-count hash-table sizing, none of it documented anywhere online),
and `lib/nca_build.sh` builds complete Meta and Program NCAs from scratch
(cnmt generation, PFS0/hash-table assembly, IVFC hash-tree construction,
NCA header assembly, key-area/header encryption) — `switch-merge.sh`'s own
`extract_nsp`/`extract_cnmt_from_meta_nca`/`extract_nacp_from_control_nca`
plus the BKTR-reconstruction and Meta/Program-building parts of
`merge_group` combine all of this to replace every single `nstool`/
`hacpack`/`hactool` call site the pipeline ever had. All verified
byte-for-byte against real tool output at every level (individual field
comparisons against real decrypted headers; whole-file `cmp` against real
`hacpack`-built Meta/Program NCAs and hacpack's own hard-linked-out
pre-hash romfs intermediate; `diff -rq` against `hactool --basenca`'s own
BKTR reconstruction; and the full 1G1R batch merge end-to-end) — see
README roadmap's "fourth" through "eighth piece" entries for full
verification detail and the real bugs found along the way, including in
this final piece: a byte-reversed `"IVFC"` magic literal, mixing up an
IVFC level's unpadded-vs-padded size (hacpack's own `*out_size` param is
captured BEFORE its own final padding step, not after), and `nstool -x`'s
on-disk file-write order for a PartitionFs section being the REVERSE of
that section's own entry-table order (an `nstool`-internal quirk this
project's own reference outputs, all originally built via `nstool -x`,
needed to be matched exactly for continued byte-for-byte continuity).
BKTR's own relocation/subsection bucket-tree format and hacpack's own
romfs-building/NCA-building algorithms are genuinely undocumented anywhere
online — both were derived directly from the exact vendored `bin/hactool`/
`bin/hacpack` source already used as read-side ground truth, not guessed.
**No vendored tool is required to run a merge anymore** — the only
remaining dependencies are bash, `xxd`, `openssl`, and standard coreutils.

## Non-obvious things worth remembering

- **Update Program NCAs are often BKTR-delta encoded, not full
  replacements.** This was the root cause of a real install failure ("Game
  updates cannot be loaded directly. Load the base game instead.") that
  took a long debugging session to trace. Detect via `Enc. Type: AesCtrEx`
  on the romfs partition in `nstool -t nca -v`, or just check for a
  `RightsId` on the update's Program NCA (titlekey-crypto updates are the
  ones seen to use BKTR so far). Fix: reconstruct the full romfs/exefs with
  `hactool --basenca` against a plaintext-decrypted base Program NCA, then
  rebuild a standalone standard-crypto Program NCA via
  `hacpack --ncatype program --plaintext`. Full detail in README's "How it
  works" and "Known issues" sections — read those before touching this
  code path again.
- **`hacpack --ncatype meta` writes an all-zero cnmt digest** unless
  `--digest` is passed explicitly. The script builds the Meta NCA twice
  (once to get the cnmt bytes, hash them, rebuild with the real digest) to
  work around this.
- **`nstool` vs `hactool`**: `nstool` is read/extract/verify only, no
  repack, and its `--basenca` couldn't be made to work for two
  different-RightsId sides at once (base + update tickets) — that's why
  `hactool` was added as a second dependency, specifically for the BKTR
  reconstruction step. `hactool --titlekey` wants the raw ticket-encrypted
  key value — read directly from the ticket's fixed `0x180` offset by this
  project's own `parse_tik` (`lib/binfmt.sh`), not the fully-decrypted
  "AES-CTR Key" nstool prints in its own verbose NCA dump — easy to mix
  these up.
- **DLC does not get folded into the base Meta NCA at all.** It's a
  structurally separate title (`AddOnContent`) that just references the
  base's title ID. "Merging" DLC means carrying its own Meta + Data NCA(s)
  into the output NSP unmodified, alongside the rewritten base+update Meta.
- Output filename convention: `<Name> [<TitleId>][<DisplayVersion>][<DLC
  count>].nsp`, e.g. `Dicefolk [01002A801E57C000][1.2.12][1].nsp`. Name and
  DisplayVersion come from the merged Control NCA's NACP, parsed by
  `lib/binfmt.sh`'s `parse_nacp` — not the cnmt's internal version integer,
  which is a meaningless build number, not the player-facing `1.2.12`-style
  string.
- **`lib/binfmt.sh` byte layouts are hand-verified, not just copied from
  switchbrew.org** — every field offset was cross-checked by parsing this
  project's own real extracted `.cnmt`/`.nacp` files and comparing against
  `nstool -t cnmt -v` / `nstool -t nacp -v`'s output, for all three cnmt
  shapes (Application/Patch/AddOnContent). If a new title's cnmt or NACP
  ever parses wrong (wrong title ID, garbled name, etc.), re-verify against
  `nstool`'s own output on that specific file before assuming the general
  layout is wrong — could just be a field this project hasn't seen a
  variant of yet (e.g. `ContentMetaAttributes` bits). **Confirmed to
  actually happen once**: an earlier test title's own NACP (since swapped
  out for Super Smash Bros. Ultimate) left the AmericanEnglish (slot 0)
  name empty, with the real name only in slot 1 (BritishEnglish) —
  `parse_nacp` now scans all 16 language slots for the
  first non-empty Name instead of assuming slot 0 is always populated.
- **`hactool` 1.4.0 (the latest release) has a real, confirmed, unfixed
  bug**: two overly-strict exact-equality checks in its BKTR (patch-romfs)
  layout validation reject some legitimate update NCAs with "Invalid BKTR
  layout!" or silently produce an empty romfs extraction. Documented
  upstream (hactool issue #134, "many game updates" affected, incl. No
  Man's Sky); a community fix (PR #138) was rejected by the maintainer for
  being AI-generated, not necessarily for being wrong. Verified via
  DarkMatterCore/nxdumptool's source (a separate maintained tool that reads
  BKTR successfully with no equivalent checks at all) that these checks
  aren't actually load-bearing for correctness. Fixed by vendoring a
  locally-patched `hactool` build in `bin/` — patch at
  `bin/patches/hactool-1.4.0-bktr-layout-fix.patch`, full investigation
  (including the actual byte offsets that triggered it) in README's "The
  debugging story", Bug #3. **This no longer affects the merge pipeline
  at all** — `lib/bktr.sh`'s own from-scratch BKTR reconstruction never
  calls `hactool`, so this bug is now purely a concern for anyone using
  the vendored `bin/hactool` directly for manual debugging. **If
  `bin/hactool` is ever rebuilt or replaced for that purpose, re-apply
  this patch** — a stock hactool 1.4.0 will silently regress on any title
  whose update hits this layout (confirmed at the time: the project's
  second test title did, its first didn't — it's title-dependent, not
  universal, so a regression might not show up in casual testing with
  just one game; that second test title has since been swapped out, so
  this specific trigger condition can't be re-confirmed against it, but
  the underlying hactool bug itself is an upstream, not project-specific,
  fact).
- **`openssl enc` has no AES-XTS mode**, hit while reimplementing NCA
  header reading. `aes-128-xts` shows up in `openssl list
  -cipher-algorithms` but the `enc` CLI subcommand refuses it at runtime
  ("enc XTS ciphers not supported") — permanent upstream limitation, same
  for GCM/CCM, not fixable with flags. Worked around by building XTS from
  its actual definition using only `openssl enc -aes-128-ecb` (two AES-ECB
  ops per 16-byte block, one for the tweak one for the data, plus
  GF(2^128) tweak-doubling in bash arithmetic). Full derivation in
  `lib/nca_header.sh` and README's "The debugging story", Bug #4. Also:
  Nintendo's NCA header tweak is non-standard (big-endian sector number,
  not little-endian) - get that backwards and you get silent garbage, not
  an error.
- **Bash silently drops embedded NUL bytes from string variables** — the
  bug behind PFS0 packing corruption (`lib/pfs0.sh`, Bug #5 in README).
  `s="a"$'\0'"b"; printf '%s' "$s"` only prints `a` even though `${#s}`
  correctly reports length 3. Any format that needs multiple NUL-separated
  strings written out (PFS0's filename table is one; there may be others
  if this project ever touches more binary formats) must stream each piece
  directly via its own `printf '%s\0'` call - never accumulate them in one
  bash variable first and print that at the end.
- **Bash `errexit`-in-a-tested-command gotcha**, hit while adding batch
  mode: `if ( set -e; some_func ); then` does NOT give you working `-e`
  inside the subshell — bash disables errexit for any command whose exit
  status is directly tested (if/while/&&/||), and that reaches through into
  the subshell's own `set -e`. The working pattern: call the subshell as a
  bare statement, capture `$?` right after, and toggle the *outer* script's
  own `-e` off/on around that one line so it doesn't abort on the bare
  statement's nonzero exit before you can read `$?`. Full writeup with a
  reproducible test case in README's "The debugging story". If touching
  the per-group failure-isolation logic again, re-read that first — it's
  easy to silently reintroduce (failures start looking like successes) if
  this pattern gets "simplified."
- **BKTR relocation/subsection bucket stride is a fixed 0x4000 bytes per
  bucket, not 0x4000-plus-an-overflow-entry.** Hit while adding
  multi-bucket support to `lib/bktr.sh` (every test title before Smash
  Bros Ultimate only ever had `num_buckets == 1`, so this never mattered
  before). An initial reading of hactool's own comments led to a wrong
  guess of 0x4014 (relocation) / 0x4010 (subsection) stride, i.e. bucket
  body plus room for one extra entry - that guess read past the end of a
  real 29-bucket relocation table and crashed with `16#: invalid integer
  constant` (an empty hex slice past EOF). The actual struct layout
  (`bktr_relocation_bucket_t`/`bktr_subsection_bucket_t` in hactool's
  `bktr.h`) packs header + entries + padding to exactly 0x4000 bytes with
  no overflow room at all - confirmed both by computing it directly from
  the struct's own field sizes and by checking that `0x4000 * (num_buckets
  + 1)` (the +1 for the block header) exactly equals the real captured
  table file's size for both a 29-bucket and a 9-bucket real table. If
  BKTR parsing is ever touched again, re-derive bucket size from the
  actual `bktr.h` struct fields, not from a comment restating an earlier
  guess.

## Environment

- `nstool`/`hacpack`/`hactool` are vendored in `bin/` (see "Current state"
  above) — no system package needed. If `bin/` is ever missing (fresh
  checkout without the binaries), the script falls back to `PATH`, but
  then loses the `hactool` BKTR fix; see the note above about that.
- `xxd` (ships with `vim`/`vim-common`) is needed by `lib/binfmt.sh`.
  `openssl` (near-universal) is needed by `lib/nca_header.sh`. Neither is
  vendored (both are tiny/common enough not to bother), but the script
  checks for both explicitly at startup with a clear error if missing.
- `bin/smtool` (the C port, see "Current state"/"Where to resume" above)
  needs building once via `make -C src/smtool` before the default
  (non-`--pure`) path works - `gcc`/`cc` and OpenSSL dev headers
  (`libcrypto`) are needed at BUILD time only, confirmed present on this
  machine already (OpenSSL 3.6.4, gcc 16.2.1). `switch-merge.sh` checks
  for `bin/smtool`'s existence at startup with a clear error pointing at
  the build command if missing, unless `--pure` is passed.
- `~/.switch/prod.keys` — had a formatting bug on first use (some key
  entries had a stray trailing `00` byte); fixed in place, original backed
  up to `~/.switch/prod.keys.bak`. If `hacpack`/`hactool` throw "Failed to
  match key" warnings, that's usually benign noise from this quirk, not a
  real failure — only worry if a build/pack step actually errors out.
- This sandboxed session can't run interactive `sudo` — if a system package
  install is ever genuinely needed (shouldn't be, now that the toolchain is
  vendored), build with `yay` then ask the user to run the final
  `sudo pacman -U ...` step themselves in their own terminal.

## Where to resume

1. Re-read `README.md` in full — it has the authoritative, kept-current
   pipeline description, known issues, and roadmap.
0. **`smtool` (C port of the perf-critical pipeline) is IN PROGRESS, Phase
   1 of 9 landed.** See README roadmap's `smtool` entry for full detail.
   Short version: the bash pipeline is measured ~100x slower than the
   vendored C tools on equivalent work, so a new `src/smtool/` C project
   (links libcrypto) reimplements it as one-shot subcommands
   (`bin/smtool <subcommand> ...`), called by default from
   `switch-merge.sh`; `--pure` routes back to the original bash. Landed so
   far: pure struct/container parsing only (cnmt/NACP/ticket/PFS0/HFS0
   reading) — no crypto yet. Verified byte-for-byte against bash output on
   every fixture in `tests/` (`bash tests/run.sh`) AND against a full real
   1G1R merge (compiled vs `--pure`, `cmp`-identical output). **Honest
   finding**: this phase's real-world speedup on a full merge is small —
   the dominant real-file cost (copying a multi-GB secure partition to
   scratch) is I/O-bound either way, not sped up by faster parsing. The
   big wins are expected from later phases (NCA header/content crypto,
   replacing hundreds of `openssl` subprocess spawns) — don't assume this
   phase alone made the pipeline fast; it's phase 1 of 9, and the
   remaining 8 are NOT done. Remaining phases, in order: NCA header
   AES-XTS decrypt, NCA content-key derivation, RomFs/BKTR readers,
   streaming AES-CTR content decryption, RomFs writer, NCA builder (Meta
   then Program), final cutover (`smtool` becomes required, `--pure`
   finalized as the explicit slow-path opt-in). If the user asks to
   continue this, don't re-derive the design from scratch — the phase
   ordering, subcommand-naming convention (`<noun>-<verb>`, `KEY=VALUE`
   multi-field output), and `op_*`/`--pure` dispatch pattern are already
   decided; follow the existing shape in `switch-merge.sh` (`op_parse_cnmt`
   etc.) and `src/smtool/` (one `.c` file per module, `main.c` dispatches
   by subcommand name) for the next phase rather than inventing a new one.
2. **Vendored-tool elimination is done.** `nstool`/`hacpack`/`hactool` are
   all confirmed unused by the merge pipeline (see README roadmap's
   "fourth" through "eighth piece" entries for the full history: cnmt/NACP
   parsing, NCA-header AES-XTS, PFS0 packing, ticket parsing, per-title
   AES-CTR content decryption, BKTR reconstruction, and finally NCA
   *building* - hash-tree construction, romfs container building - all
   reimplemented and verified byte-for-byte against real tool output).
   Confirmed via wrapper-substitution testing (replace a vendored binary
   with a script that fails loudly if invoked, then run a full merge and
   confirm it never fires) — done for all three simultaneously as the
   final check. All three remain vendored in `bin/` purely for optional
   manual debugging/cross-verification, not as a runtime dependency.
   Don't assume there's a next vendored-tool piece to chip away at; if the
   user raises it again, treat it as a new ask, not a continuation.
3. Roadmap's open remaining item: multi-title DLC packs (a single DLC NSP
   containing more than one `AddOnContent` title) — still untested, no
   real file with that shape has been available yet. An earlier test
   title's DLC NSP looked promising (filenamed "20 DLCs") but turned out,
   on actually reading its cnmt, to contain exactly one `AddOnContent`
   title — the "20" referred to how many separate DLC purchases/NSPs
   exist for the game in total, not how many are bundled in this one
   file. Smash Bros Ultimate's 99 DLCs are the same shape: 99 separate
   single-title NSPs, not one bundle. XCI **output** was investigated and
   explicitly decided against (see README roadmap) — XCI **input** is a
   separate thing and IS implemented (see "Current state" above and
   README's "XCI input" roadmap entry); don't conflate the two if this
   comes up again.
4. If a new title hits a new error, check first whether it's a variant of
   the known issues in README (BKTR delta, zero digest, hactool BKTR
   layout bug, AES-XTS mistweak, PFS0 NUL-drop, NACP language-slot
   fallback) before assuming something new — several produced
   similar-looking generic errors and took real digging to tell apart.
5. Multi-title batch mode (1G1R) is confirmed end-to-end with two real,
   different games (Dicefolk + Super Smash Bros. Ultimate) merged together
   in one run, including the largest/most demanding title tested so far
   (14.6GB base, two updates, 99 DLCs) and the first real exercise of a
   multi-bucket BKTR table (29 relocation buckets, 9 subsection buckets).
   Smash's merge was verified structurally (PFS0 entry-count/type
   breakdown: 99 `.tik` + 99 `.cert` + 100 `.cnmt.nca` + 102 `.nca`) and via
   the output filename itself confirming both the version-supersession fix
   (`13.0.5`, the newer of its two updates) and full DLC coverage (`99`),
   and **now confirmed on real hardware** too, same as Dicefolk — installs
   and plays correctly.
6. Both test titles are now hardware-verified. The next open item is the
   roadmap's remaining unchecked box: multi-title DLC packs (a single DLC
   NSP containing more than one `AddOnContent` title) — still untested, no
   real file with that shape has turned up yet.
