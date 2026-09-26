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
title Dicefolk (`01002A801E57C000`). Also verified end-to-end (structural
checks + reconstructed-content sanity checks, not yet on real hardware) for
a second real title, Well Dweller (`0100217023F6C000`, base+update, no
DLC), merged together with Dicefolk in one real 1G1R batch run. Test files
live in this directory:

- `Dicefolk [01002A801E57C000][B/U].nsp` + `Dicefolk Chimera Pack [...][D].nsp`
- `Well Dweller [0100217023F6C000][B/U].nsp`

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
  variant of yet (e.g. `ContentMetaAttributes` bits, or a NACP language
  slot beyond AmericanEnglish).
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
  debugging story", Bug #3. **If `bin/hactool` is ever rebuilt or
  replaced, re-apply this patch** — a stock hactool 1.4.0 will silently
  regress on any title whose update hits this layout (confirmed: Well
  Dweller does, Dicefolk doesn't — it's title-dependent, not universal, so
  a regression might not show up in casual testing with just one game).
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

## Environment

- `nstool`/`hacpack`/`hactool` are vendored in `bin/` (see "Current state"
  above) — no system package needed. If `bin/` is ever missing (fresh
  checkout without the binaries), the script falls back to `PATH`, but
  then loses the `hactool` BKTR fix; see the note above about that.
- `xxd` (ships with `vim`/`vim-common`) is needed by `lib/binfmt.sh`.
  `openssl` (near-universal) is needed by `lib/nca_header.sh`. Neither is
  vendored (both are tiny/common enough not to bother), but the script
  checks for both explicitly at startup with a clear error if missing.
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
2. The user asked, at one point, about removing the dependency on
   `nstool`/`hacpack`/`hactool` entirely and reimplementing their
   functionality directly. Tackled in two scoped sessions rather than all
   at once: first cnmt/NACP binary parsing (`lib/binfmt.sh`), then NCA
   header AES-XTS decryption for `RightsId` (`lib/nca_header.sh`) and flat
   PFS0/NSP packing (`lib/pfs0.sh`) - explicitly chosen as the next
   lowest-risk pieces (no per-title crypto, no hash-tree construction) via
   a direct question to the user before starting, since the *initial*
   assumption that NCA-header reading was "trivial, no crypto" turned out
   to be wrong (it's AES-XTS-encrypted) and had to be corrected and
   re-confirmed with the user before proceeding. **Remaining, still on the
   vendored tools, and NOT casually reimplementable**: NCA
   content-partition decrypt/extract (per-title AES-CTR/titlekey crypto,
   hash-tree verification), NCA *building* for Program/Meta (writing hash
   trees, encrypting content), HFS0/RomFS packing, and BKTR bucket-tree
   parsing/rebuilding. These are a materially higher risk tier than
   anything done so far - a wrong implementation produces *silently
   corrupted* game/save data, not a clean error - and were deliberately
   not attempted without the user explicitly choosing that scope each
   time. Don't assume "extract dependencies" as an open standing goal to
   keep chipping away at unprompted - each piece was a separate, scoped
   ask, and the natural next candidates (AES-CTR content decryption, BKTR)
   are meaningfully riskier than what's been done - flag that risk clearly
   and ask before touching them, the same way NCA-header AES-XTS was
   flagged and re-confirmed once its real complexity became clear.
3. Roadmap's open remaining item: multi-title DLC packs (only single-
   `AddOnContent`-title DLC has been tested); XCI output was investigated
   and explicitly decided against (see README roadmap).
4. If a new title hits a new error, check first whether it's a variant of
   the known issues in README (BKTR delta, zero digest, hactool BKTR
   layout bug, AES-XTS mistweak, PFS0 NUL-drop) before assuming something
   new — several produced similar-looking generic errors and took real
   digging to tell apart.
5. Multi-title batch mode (1G1R) is confirmed end-to-end with two real,
   different games (Dicefolk + Well Dweller) merged together in one run.
   Well Dweller's merge was verified structurally and via reconstructed-
   content sanity checks (file listing diff against base, spot-checked an
   unchanged config file's content, checked the main game data file's size
   grew plausibly) but **not yet confirmed on real hardware** — unlike
   Dicefolk, which was. If you get a chance to test Well Dweller's merged
   NSP on a real Switch, that's the next real confirmation worth doing.
