# switch-merge

Bash CLI (`switch-merge.sh`) that merges a Nintendo Switch base-game NSP +
update NSP + any number of DLC NSPs into a single installable NSP, for one
or many games at once (1G1R). See `README.md` for full usage, pipeline
details, and known issues — that file is kept up to date and is the
primary reference. It now also has a "Switch content format, from
scratch" primer (NCA/cnmt/RightsId/BKTR concepts) and a "The debugging
story" narrative walking through all three real bugs found so far — read
those if a new title produces an unfamiliar error before assuming it's
something new. This file is for picking the workflow back up quickly and
for context `README.md` doesn't cover.

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
(`Application`/`Patch`/`AddOnContent`) via `nstool`, not by filename, and
grouped by base title ID — **1G1R batch mode**: a directory mixing
several different games' base/update/DLC files together merges each into
its own output NSP in one run, one merge per group, failures in one group
don't stop the others.

**The project is self-contained**: `nstool`/`hacpack`/`hactool` are
vendored in `bin/`, which the script puts first on `PATH` automatically.
No system package install needed, and `bin/hactool` specifically carries a
local fix for a real upstream bug (see below) that the system/AUR version
doesn't have.

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
  key value (`nstool -t tik -v` → `Title Key: Data:` field), not the
  fully-decrypted "AES-CTR Key" nstool prints in its own verbose NCA dump —
  easy to mix these up.
- **DLC does not get folded into the base Meta NCA at all.** It's a
  structurally separate title (`AddOnContent`) that just references the
  base's title ID. "Merging" DLC means carrying its own Meta + Data NCA(s)
  into the output NSP unmodified, alongside the rewritten base+update Meta.
- Output filename convention: `<Name> [<TitleId>][<DisplayVersion>][<DLC
  count>].nsp`, e.g. `Dicefolk [01002A801E57C000][1.2.12][1].nsp`. Name and
  DisplayVersion come from the merged Control NCA's NACP
  (`nstool -t nacp -v`) — not the cnmt's internal version integer, which is
  a meaningless build number, not the player-facing `1.2.12`-style string.
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
2. Roadmap's open remaining item: multi-title DLC packs (only single-
   `AddOnContent`-title DLC has been tested); XCI output was investigated
   and explicitly decided against (see README roadmap).
3. If a new title hits a new error, check first whether it's a variant of
   the known issues in README (BKTR delta, zero digest, hactool BKTR
   layout bug) before assuming something new — several produced
   similar-looking generic errors and took real digging to tell apart.
4. Multi-title batch mode (1G1R) is confirmed end-to-end with two real,
   different games (Dicefolk + Well Dweller) merged together in one run.
   Well Dweller's merge was verified structurally and via reconstructed-
   content sanity checks (file listing diff against base, spot-checked an
   unchanged config file's content, checked the main game data file's size
   grew plausibly) but **not yet confirmed on real hardware** — unlike
   Dicefolk, which was. If you get a chance to test Well Dweller's merged
   NSP on a real Switch, that's the next real confirmation worth doing.
