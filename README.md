# switch-merge

Merges a Nintendo Switch base-game NSP with (optionally) its update NSP
and (optionally) any number of DLC NSPs into a single installable NSP,
natively on Linux via bash + `nstool` + `hacpack` + `hactool`. Built as a
CLI-native replacement for
[NSC_Builder](https://github.com/julesontheroad/NSC_BUILDER), which is
Windows-first and currently archived.

For personal use with your own legally-dumped game/update/DLC files only.

This README is written to also be a **learning resource**. If you've never
looked at how Switch game files are actually structured, read "Switch
content format, from scratch" below before anything else — the rest of the
document assumes it. If you just want to use the tool, skip to "Usage".

## Requirements

- Linux x86-64 (any reasonably modern distro — the vendored binaries below
  only link against glibc/libstdc++/libgcc, no distro-specific dependencies).
- `xxd` (ships with `vim`/`vim-common` on most distros, but isn't always
  preinstalled on a minimal system) — used by `lib/binfmt.sh` for pure-bash
  binary parsing, see below.
- `openssl` (near-universal) — used by `lib/nca_header.sh` as a raw
  AES-128-ECB block-cipher primitive, to build AES-XTS decryption of the
  NCA header from scratch (the `openssl enc` CLI has no XTS mode of its
  own — see "The debugging story" below for why).
- Your console's `prod.keys` at `~/.switch/prod.keys` (standard Lockpick_RCM
  output location).

**No package install needed.** `nstool`, `hacpack`, and `hactool` are
vendored directly in `bin/` — `switch-merge.sh` puts that directory first
on `PATH` automatically, so the project is self-contained and doesn't
depend on whatever version (if any) happens to be installed system-wide.
This matters for `hactool` specifically: `bin/hactool` carries a local fix
for two real bugs in upstream 1.4.0 (the latest release, and still present
at time of writing) that reject some legitimate update NCAs — see "The
debugging story" below and `bin/patches/hactool-1.4.0-bktr-layout-fix.patch`
for the exact change and why it's needed. If you ever want to rebuild these
from source instead of trusting the vendored binaries:
```
git clone --branch 1.4.0 https://github.com/jakcron/nstool.git   # or your distro's package
git clone --branch 1.4.0 https://github.com/DarkMatterCore/hacPack.git
git clone --branch 1.4.0 https://github.com/SciresM/hactool.git
cd hactool && git apply /path/to/bin/patches/hactool-1.4.0-bktr-layout-fix.patch
```
(`hacpack`/`nstool` are used unpatched — only `hactool` needed a fix.)

## Usage

```
./switch-merge.sh [-o <output_dir>] [-k keys.dat] [<nsp-or-dir> ...]
```

- `-o` output directory (defaults to `merged/` next to the script itself)
- `-k` path to keys file (defaults to `~/.switch/prod.keys`)
- every other argument is either an individual `.nsp` file or a directory
  (non-recursively globbed for `*.nsp` files inside it), in any order —
  with **no** positional inputs at all, defaults to scanning the directory
  the script itself lives in (not your current working directory), so
  `./switch-merge.sh` with zero arguments just works: drop your base/
  update/DLC files next to the script and run it.

**No `-b`/`-u`/per-DLC flags at all.** Base, update, and DLC are
auto-detected by reading each input NSP's own cnmt content-meta `Type`
field (`Application`/`Patch`/`AddOnContent`) via `nstool` — not by
filename — so inputs don't need to follow any `[B]`/`[U]`/`[D]` naming
convention.

**Multiple games in one run (1G1R — one game, one ROM).** Every input NSP
is also grouped by its own base title ID (see "Switch content format, from
scratch" below for what that means), so a single directory containing
several different games — each with its own base, optional update, and any
number of DLC, all mixed together — merges each game into its own separate
output NSP in one run. There's no need to separate games into subfolders
first. Each title group is merged independently: if one group fails (a
corrupt file, a missing base, etc.), the others still complete, and a
summary at the end reports which titles succeeded and which failed and why.

Example, no arguments at all — scans the script's own directory and writes
to `merged/` next to it:

```
./switch-merge.sh
```

Example, point it at a folder containing base + update + any number of DLC
for a single game:

```
./switch-merge.sh -o ./merged ./game_folder
```

Example, one folder with **multiple different games** mixed together —
each gets merged into its own output NSP:

```
./switch-merge.sh -o ./merged ./roms_folder
```

Example, mixing individual files and a directory of DLC:

```
./switch-merge.sh -o ./merged \
                   "Dicefolk [01002A801E57C000][B].nsp" \
                   "Dicefolk [01002A801E57C000][U].nsp" \
                   ./dlc_folder
```

Example, base game only (no update, no DLC):

```
./switch-merge.sh -o ./merged "Dicefolk [01002A801E57C000][B].nsp"
```

Output is a single NSP in the output directory, named:

```
<Name> [<TitleId>][<DisplayVersion>][<DLC count>].nsp
```

e.g. `Dicefolk [01002A801E57C000][1.2.12][1].nsp`. `<Name>` and
`<DisplayVersion>` (the human-readable `1.2.12`-style string, not the cnmt's
internal version integer) come from the merged Control NCA's NACP. `<DLC
count>` is always shown, including `[0]` when none were given. Installable
directly (e.g. via Tinfoil/DBI) with no separate update or DLC install step
needed.

## Switch content format, from scratch

Skip this section if you already know what an NCA, cnmt, RightsId, or BKTR
is. Everything after this is a lot easier to follow once these pieces click.

### NCAs: the actual content files

A **NCA** (Nintendo Content Archive) is the base unit of storage for
basically everything on a Switch — game code, assets, icons, manuals,
save data. Every NCA has a `Content Type`, which tells you what's inside:

- **`Program`** — the actual executable code and game assets. Internally
  split into up to two partitions: partition 0 is the **exefs** (the
  executable + loader binaries: `main`, `main.npdm`, `rtld`, `sdk`,
  `subsdk0`, ...), partition 1 is the **romfs** (the game's data files —
  everything from `.assets` files to shader bundles). This is by far the
  biggest NCA in any title and the one most of this project's debugging
  revolves around.
- **`Control`** — icons (per-language) + the **NACP** (`control.nacp`), a
  small binary blob holding the game's display name, publisher, and
  human-readable version string (`DisplayVersion`, e.g. `"1.2.12"`) per
  language. This is genuinely tiny — under 2 MB — compared to Program.
  Fixed-size, 0x4000 (16384) bytes total. Byte layout used by this
  project's `lib/binfmt.sh` (verified against real files):
  ```
  16 language slots, 0x300 (768) bytes each, starting at file offset 0:
    slot 0 = AmericanEnglish (the one this project reads)
    0x000 (0x200 bytes) Name, NUL-padded
    0x200 (0x100 bytes) Publisher, NUL-padded
  0x3060 (0x10 bytes) DisplayVersion, NUL-padded, e.g. "1.2.12"
  ```
- **`LegalInformation`** (a.k.a. `Manual`) — the legal/manual HTML content
  you get to when you long-press the game icon on a real console. Also
  tiny.
- **`Data`** — used by DLC. Just raw game data, no code, no exefs/romfs
  split.
- **`Meta`** — described in its own section below; every title has exactly
  one. This is the "index card" that ties everything else together.

An NSP file (what you download/dump) is just a **PFS0** (a flat, unencrypted
container format — think of it like a tar with no compression) holding a
handful of NCAs plus, sometimes, a ticket/cert pair (see "Tickets and
titlekeys" below). `nstool --fstree some.nsp` lists what's inside without
extracting anything. Byte layout used by this project's `lib/pfs0.sh`
(verified byte-for-byte against real hacpack-produced NSPs — see "The
debugging story"):

```
Header (0x10 bytes):
  0x0  u32  Magic ("PFS0")
  0x4  u32  EntryCount
  0x8  u32  StringTableSize
  0xC  u32  Reserved (0)
PartitionEntry (0x18 bytes each, EntryCount of them, right after header):
  0x0  u64  Offset      <- relative to the start of FILE DATA, not the PFS0 file
  0x8  u64  Size
  0x10 u32  StringTableOffset
  0x14 u32  Reserved (0)
String table: EntryCount NUL-terminated filenames, concatenated, then
  padded with NUL bytes so the raw content rounds up to a multiple of
  0x20 (32) bytes.
File data: every file's raw bytes, in PartitionEntry order, with NO
  gaps/padding between files.
```

The NCA header itself is a different story — it's **encrypted**, not
plaintext. The first 0xC00 bytes of every NCA (an 0x400 main header + one
0x200 header per content section) are AES-XTS encrypted with a *fixed* key
(`header_key` in `prod.keys` — the same on every console, unlike the
per-title keys covered below), using a non-standard tweak: Nintendo
encodes the sector number **big-endian** to derive each sector's initial
tweak, where the XTS standard uses little-endian for this step. Fields
worth knowing about, all inside that encrypted region:

```
0x200 (0x4)  Magic ("NCA3")
0x205 (0x1)  ContentType   <- 0=Program, 1=Meta, 2=Control, 3=Manual,
                              4=Data, 5=PublicData (own enum, NOT the
                              same numbering as the cnmt's ContentType)
0x210 (0x8)  ProgramId
0x230 (0x10) RightsId      <- all-zero if standard crypto, a real value
                              if titlekey crypto (see below)
```

`lib/nca_header.sh` decrypts just enough of this to read `RightsId`,
building AES-XTS from scratch out of raw AES-ECB operations (`openssl enc`
has no XTS mode of its own — see "The debugging story" for why).

### The Meta NCA and cnmt: the manifest

Every installable "thing" (a base game, an update, one DLC) has exactly one
**Meta NCA**. Its payload, once you extract it with `nstool -t nca -x`, is a
single small file called a **cnmt** (content meta). The cnmt is the
manifest: it lists every other NCA in this same title by ID, type, and
hash, plus:

- `TitleId` — which title this is
- `Type` — `Application` (128), `Patch` (129), or `AddOnContent` (130).
  This is the single field that tells Horizon (and any repacking tool)
  what kind of thing it's looking at, and it's authoritative — independent
  of what the file is named on disk.
- `Version` — an internal integer (e.g. `v65536`), *not* the human-readable
  version string players see. That lives in the NACP instead (see above).
- a trailing 32-byte SHA256 **digest** covering all of the cnmt's own
  preceding bytes. This exists so a corrupted/tampered cnmt can be
  detected before its content records are even trusted. (Spoiler: getting
  this digest right, rather than leaving it zeroed, was one of two things
  that broke early merge attempts — see "The debugging story".)

Read one with `nstool -t cnmt -v some.cnmt`, or with `parse_cnmt` from this
project's own `lib/binfmt.sh` — the exact byte layout (verified against
real files from this project, cross-checked against `nstool`'s own output):

```
PackagedContentMetaHeader (0x20 bytes, at file start):
  0x00  u64  Id                    <- this content's own TitleId
  0x08  u32  Version
  0x0C  u8   ContentMetaType       <- 0x80 Application, 0x81 Patch, 0x82 AddOnContent
  0x0E  u16  ExtendedHeaderSize
  0x10  u16  ContentCount

ApplicationMetaExtendedHeader (Application only, right after the header):
  0x00  u64  PatchId               <- points forward to this title's update

PatchMetaExtendedHeader (Patch/AddOnContent, right after the header):
  0x00  u64  ApplicationId         <- the base title ID (see below)

PackagedContentInfo (0x38 bytes each, repeated ContentCount times,
starting right after the extended header):
  0x20  u128 ContentId             <- raw bytes, this is the NCA's filename
  0x30  u40  Size                  <- little-endian, non-power-of-2 width
  0x36  u8   ContentType           <- 1 Program, 3 Control, 5 LegalInformation, 2 Data

Digest: last 32 bytes of the file, SHA256 over everything before it.
```

### Application, Patch, AddOnContent: the three title kinds

A single game as sold digitally is actually up to three separate,
independently-installed **titles**, distinguished by their cnmt `Type`:

| Kind | cnmt Type | Title ID convention | Contains |
|---|---|---|---|
| Base game | `Application` | `X` (some 16-hex-digit ID) | Meta + Program + Control + LegalInformation |
| Update | `Patch` | `X \| 0x800` | Meta + its own new Program + Control + LegalInformation |
| DLC | `AddOnContent` | `X` with the high content-type nibble set (e.g. base `...c000` → DLC `...d001`, `...d002`, ...) | Meta + Data (no Control/Legal of its own) |

On a real console, all three install as **separate titles side by side**.
There is no on-disk merging happening at install time — the OS just does
**version resolution**: at launch, Horizon notices the `Patch` title
(higher version) exists for the same base `TitleId` and runs its Program
NCA instead of the base's. DLC is even more independent: it's not
version-resolved against anything, it's just a second title that happens to
declare (via a field described below) that it belongs alongside a specific
base title, and games query for its presence via API at runtime.

The two non-DLC cnmt shapes name the "which base title does this belong to"
field *differently*, which trips up naive parsing:

```
# base (Application) cnmt - TitleId IS the base id directly:
TitleId:               0x01002a801e57c000
...
ApplicationExtendedHeader:
    PatchId:           0x01002a801e57c800   <- points forward to the update

# update (Patch) cnmt - TitleId is the UPDATE's own id, not the base's:
TitleId:               0x01002a801e57c800
...
PatchMetaExtendedHeader:
    ApplicationId:     0x01002a801e57c000   <- THIS is the base id

# DLC (AddOnContent) cnmt - same pattern as Patch:
TitleId:               0x01002a801e57c0d001
...
    ApplicationId:     0x01002a801e57c000   <- points back at the base
```

### Tickets and titlekeys: the second layer of encryption

Every NCA's content partitions are AES-encrypted. Most of the key material
needed to decrypt an NCA comes from your console's `prod.keys` (fixed,
device-independent key-derivation constants) plus the NCA's own header —
but some titles add an *extra* layer on top called **titlekey crypto**:

- The NCA header has a `RightsId` field (present only for titlekey-crypto
  content; absent entirely for "standard crypto" content).
- The actual per-title decryption key (the **titlekey**) is *not* in the
  NCA at all. It lives in a separate small file, the **ticket** (`.tik`,
  plus a `.cert` certificate chain to validate the ticket's signature),
  which normally travels alongside the NCA in the same NSP.
- The ticket stores the titlekey **encrypted** (with a Nintendo eShop key,
  `eticket_rsa_kek` in `prod.keys`) — reading `nstool -t tik -v some.tik`
  shows this encrypted value under `Title Key: Data:`. Tools that want the
  titlekey either decrypt it themselves internally (`nstool` does this
  silently when you give it `--tik`/`--cert`) or want you to hand them
  that same still-encrypted value directly (`hactool --titlekey=...` — see
  "The debugging story" for how this tripped things up).

Whether a given NCA uses titlekey crypto or standard crypto is a
per-content, per-title decision made by the developer/Nintendo at
publishing time — some titles' Program NCAs have a `RightsId`, some don't.
There's no way to know without checking (`nstool -t nca -v some.nca | grep
RightsId`).

### BKTR: updates are usually deltas, not full copies

This is the least obvious part, and the one that caused the most
debugging. An update's romfs partition is very often **not** a full copy
of the base's romfs plus changes — it's stored as a genuine **binary delta**
against the base's romfs, using a Nintendo-specific relocation/patch format
called **BKTR** (visible as `Enc. Type: AesCtrEx` in `nstool -t nca -v`,
versus plain `AesCtr` for a full, non-delta romfs partition). This exists
to keep update download sizes small — most files in a big Unity/Unreal
romfs don't actually change between patch versions, so Nintendo's tooling
only ships the bytes that did, plus a relocation table describing how to
splice them back into the base's romfs at read time.

The practical consequence: **you cannot treat an update's Program NCA as a
self-contained, standalone thing.** Reading it requires the base's Program
NCA to be present as a reference (`hactool`'s `--basenca` flag exists
specifically for this). This is *not* how the base's own romfs is stored —
that one really is a complete, standalone copy — and there's no way to tell
which kind you're looking at except checking `Enc. Type` directly.

## How it works

### The debugging story

This section is a chronological account of two real bugs found while
building this script, told as symptom → investigation → root cause → fix,
because both symptoms looked similar on the surface and it took real
digging to tell them apart.

**Starting point.** The plan, taken from how NSC_Builder does this: since
an update's content NCAs are (usually) a complete superset of the base's
content types, just build a brand-new Meta NCA that declares the update's
Program/Control/LegalInformation NCAs as type `Application` under the
**base**'s title ID (instead of the update's own `Patch` type/ID), and pack
that together with those NCAs into one NSP. If it works, you get a single
file that installs and looks, to the console, exactly like a base game that
was already fully patched — no separate update install step. DLC needs no
rewriting at all: just carry its own Meta+Data NCAs into the same NSP
unmodified, since DLC installs as a fully independent title anyway (see
"Application, Patch, AddOnContent" above).

**Bug #1 — "The titlekey for this Rights ID could not be found."**
First real install attempt (base + update, no DLC) failed immediately with
this error. Investigation: `nstool -t nca -v` on the update's Program NCA
showed a `RightsId` field — this particular title's Program NCA is
titlekey-crypto (see "Tickets and titlekeys" above). The merge script was
copying the NCA itself into the output, but not the `.tik`/`.cert` pair
that the ticket-holding NSP had carried alongside it. Without the ticket in
the output NSP, the console has the encrypted NCA but no way to derive the
key to decrypt it. **Fix:** copy any `.tik`/`.cert` sitting next to the
source NCAs into the merged NSP's output directory too, so hacpack bundles
them into the final PFS0 alongside everything else.

**Bug #2 — "Game updates cannot be loaded directly. Load the base game
instead."** This is the *installer's* stock message for "I think this
content is a Patch, not an Application" — normally seen when you try to
sideload an update NSP by itself, without its base game installed. But this
error kept appearing on our merged NSP even though its cnmt correctly said
`Type: Application` under the base's title ID. Two separate causes were
found chasing this one message, in this order:

1. **The zero-digest issue.** `hacpack --type nca --ncatype meta` turned out
   to leave the cnmt's trailing 32-byte digest as all-zero unless you pass
   `--digest` explicitly — confirmed by comparing byte-for-byte against the
   original base and update cnmts, which both carry a proper SHA256 there.
   A zero digest looks like corrupted/untrusted metadata, which is
   plausibly why an installer would refuse to treat the content as valid
   and fall back to a generic error message. Since the digest covers the
   cnmt's *own* bytes — which don't exist yet before you build it — the fix
   requires building the Meta NCA **twice**: once without `--digest` to get
   a draft cnmt, hash everything but its last 32 bytes, then rebuild
   passing that hash via `--digest` to bake in the real one. **This fixed
   the digest, but the exact same install error still happened afterward**
   — meaning it was a real bug, but not the (only) cause of this error.
2. **The BKTR issue (the real remaining cause).** With a correct digest and
   a correct cnmt Type still not fixing anything, the next question was
   whether the Program NCA itself carried some other "this is a patch"
   signal independent of the cnmt. `nstool -t nca -v` on the update's
   Program NCA showed its romfs partition using `Enc. Type: AesCtrEx` —
   BKTR delta encoding (see "BKTR" above) — while the base's own romfs used
   plain `AesCtr`. The update's Program NCA, even after relabeling, was
   still *structurally* a delta with nothing on disk to diff against once
   packed standalone under the base's title ID. That's what a real
   installer/CFW actually detects and refuses to run — the cnmt's claimed
   `Type` was a lie the installer saw through by looking at the content
   itself. **Fix:** don't just copy the update's Program NCA — reconstruct
   its **full** romfs and exefs by applying its BKTR delta against the
   base's own romfs (using `hactool --basenca`), then rebuild a genuinely
   standalone, standard-crypto Program NCA from that reconstructed content
   (`hacpack --ncatype program --plaintext`). A truly standalone Program
   NCA built this way has no `RightsId` at all, so bug #1's ticket-carrying
   fix isn't even needed for this path — there's no titlekey to resolve
   anymore. Confirmed on real hardware: installs cleanly, shows the
   update's version number (not the base's), and the reconstructed content
   plays correctly in-game.

Two more implementation snags surfaced while building the fix for bug #2:

- **Deriving the titlekey for `hactool`.** `hactool --titlekey=` wants the
  *raw ticket-encrypted* value — the same bytes `nstool -t tik -v` shows
  under `Title Key: Data:` — **not** the fully-decrypted "AES-CTR Key" that
  `nstool -t nca -v --tik ... --cert ...` prints in its own verbose NCA
  dump when given a ticket. Passing the wrong one produces "Hash layer 0
  failed hash verification" — silent-looking corruption, not an obviously
  wrong-key error, which took a bit to untangle.
- **`nstool`'s `--basenca` doesn't support two different tickets at once.**
  The base and update NCAs here use *different* Rights IDs (different
  tickets), and `nstool`'s single `--tik`/`--cert` flag pair can't express
  "decrypt this NCA with ticket A, but also decrypt the base-NCA reference
  with ticket B." `hactool` was brought in specifically to sidestep this: it
  takes a raw `--titlekey=` value directly (no ticket-chain juggling) and
  its `--basenca` just wants a file it can read without a second key
  context — so the base Program NCA is decrypted to a plaintext copy
  first (`hactool --titlekey=<base_key> --plaintext=<file>`), then used as
  the `--basenca` reference for the update's reconstruction pass.
- **A bash `errexit` gotcha, found while adding batch mode.** Each title
  group's merge runs inside `( set -e; merge_group ... )` so a hard
  failure (a bare `exit 1` deep in a helper) only ends that group, not the
  whole batch. The natural way to check the result — `if ( ... ); then` —
  is actually broken: bash disables `set -e` semantics for *any* command
  whose exit status is directly tested (an `if`/`while` condition, or
  either side of `&&`/`||`), and that exemption reaches through into a
  subshell's own internal `set -e` too. Tested directly: with `if ( set -e;
  false; echo "should not print" )`, the echo **prints anyway** — the
  inner `-e` never took effect, because the whole subshell command was
  being tested by the `if`. The fix is to call the subshell as a bare,
  untested statement and read `$?` immediately after — but the *outer*
  script's own `-e` then aborts on that bare statement if it fails, so the
  outer `-e` has to be toggled off (`set +e` / `... ; set -e`) around just
  that one line. Get this wrong and failures either silently succeed (the
  broken `if` form) or take down the whole batch (forgetting to guard the
  outer `-e`).

**Bug #3 — "Invalid BKTR layout!" (a real, confirmed bug in `hactool` 1.4.0
itself), found once a second real title was available to test 1G1R batch
mode against.** With Dicefolk merging fine, a second game (Well Dweller,
`0100217023F6C000`) was added to test true multi-title batch grouping. Its
group failed during the BKTR reconstruction step — not a merge-script bug,
but `hactool` itself crashing with `Invalid BKTR layout!` while processing
its update's Program NCA, before the script even got a chance to do
anything wrong. Investigation:

1. Confirmed this is a documented, unfixed upstream issue
   (`SciresM/hactool` issue #134, "Many game updates will encounter the
   error," also affecting No Man's Sky) — not something specific to this
   setup. A community PR (#138) attempted a fix but was rejected by the
   maintainer specifically for being AI-generated boilerplate, independent
   of whether the underlying fix was correct.
2. Patched a local build of `hactool` with two `fprintf` debug lines to see
   the actual numbers `nca_process_bktr_section()` was comparing, rather
   than guessing. Two separate exact-equality checks were failing:
   - `subsection_header.offset + subsection_header.size` was `0x13224600`,
     but `ctx->size` (the section's total size) was `0x13228800` — a
     `0x4200`-byte gap. The relocation→subsection relationship itself
     (`relocation.offset + relocation.size == subsection.offset`) checked
     out exactly, meaning the bucket-tree structure was internally
     consistent; only trailing padding after it was tripping the check.
   - `subsection_block->total_size` was `0x13214600` against
     `subsection_header.offset` of `0x1321c600` — a gap of exactly
     `0x8000`, which is `relocation_header.size`. Suspicious enough to
     look for an authoritative spec rather than guess a corrected formula.
3. Checked switchbrew's NCA documentation for the BKTR structure: it
   describes `subsection_header`'s `total_size` field as "Total Size of the
   Physical Patch Image" — a property of the bucket layout itself — while
   `subsection_header.offset` is just a position within the NCA section.
   These are different kinds of quantities; the wiki itself flags the
   exact spatial relationship between the two header blocks as
   undocumented ("usually(?) at the very end of the section data").
4. Checked `DarkMatterCore/nxdumptool` — a separate, actively maintained,
   real-world-tested tool that successfully dumps BKTR update romfs
   (its own changelog notes removing an equivalent overly-strict check
   that broke Luigi's Mansion 3). Its BKTR reader has **no equivalent
   pre-validation at all** — it trusts the relocation/subsection buckets'
   own internal offsets while walking them, rather than pre-checking this
   relationship. That's strong evidence hactool's two checks are
   unnecessary, not just "too strict with the wrong constant" — there's no
   correct equation to substitute, because a maintained tool proves the
   check isn't needed for correctness at all.

**Fix:** built a locally-patched `hactool` (see
`bin/patches/hactool-1.4.0-bktr-layout-fix.patch`) that relaxes the first
check to tolerate trailing padding (`>` instead of `!=` against the
section size) and removes the second check's fatal/invalidating behavior
entirely, rather than inventing an unverified replacement formula for it.
Verified the fix doesn't just avoid crashing but produces genuinely correct
output: reconstructed romfs file listing matched the base's file listing
plus legitimately new files (no missing files), an unchanged config file's
content differed only in build-machine-specific paths (real content, not
garbage), and the main game data file grew in a way consistent with a real
content update rather than truncation. This patched `hactool` (along with
unpatched `nstool`/`hacpack`) is vendored in `bin/` — see "Requirements"
above — so this fix is applied automatically without any system package
changes.

**Bug #4 — `openssl enc` silently rejects AES-XTS, found while trying to
read RightsId without `nstool`.** The NCA header (the first 0xC00 bytes of
every NCA, containing fields like `RightsId`, `ContentType`, `ProgramId`)
is encrypted with AES-XTS using a *fixed* key from `prod.keys`
(`header_key`) — unlike the content partitions, which use per-title keys.
Since this is a fixed, publicly-known key (not something requiring a
ticket), it looked like a good next candidate for reading without
`nstool`. `openssl enc -aes-128-xts` lists as a supported cipher
(`openssl list -cipher-algorithms`) but the `enc` CLI subcommand itself
refuses to use it at runtime ("enc XTS ciphers not supported") — a
permanent, documented limitation of that specific subcommand (also true
for GCM/CCM), not a configuration issue. **Fix:** built AES-XTS from its
actual definition (NIST SP 800-38E / IEEE P1619) using only
`openssl enc -aes-128-ecb` as the raw block-cipher primitive — two AES-ECB
operations per 16-byte block (one for the tweak, one for the data) plus
GF(2^128) multiply-by-2 for advancing the tweak within a sector, all in
bash arithmetic. Nintendo's NCA header additionally uses a **non-standard
tweak**: the sector number is encoded big-endian before being AES-encrypted
to produce the initial per-sector tweak, where standard XTS uses
little-endian for this step (confirmed via a community reverse-engineering
gist, and by testing — decrypting with the standard little-endian tweak
produces garbage, not "NCA3"). Every step of the construction (the GF(2^128)
doubling function specifically) was verified against known-correct test
vectors from Python's `cryptography` library before being trusted against
real data, and the full pipeline was verified end-to-end by decrypting a
real NCA header and confirming the "NCA3" magic and `RightsId` matched
`nstool`'s own decryption byte-for-byte. See `lib/nca_header.sh`.

**Bug #5 — bash silently drops embedded NUL bytes, found while
reimplementing PFS0 packing.** PFS0 (the flat container format NSP files
and NCA exefs sections use) separates filenames in its string table with
NUL bytes. The first implementation built the whole string table as one
bash string (`string_table+="$name"$'\0'`) and wrote it out with
`printf '%s' "$string_table"` at the end. This looked correct — `${#s}`
even reports the right length, including the NULs — but `printf '%s'`
(and any C-string-style output) treats a NUL as a terminator and silently
stops there, dropping everything after the *first* embedded NUL in the
whole accumulated string. The result: every filename after the first one
ran together with no separator, corrupting the table. `nstool` reading
this back happily parsed the first filename, then treated the rest of the
partition as one garbled filename with random NCA content appended,
producing warnings like `SubStream offset is greater than the maximum
possible offset`. **Fix:** never build a multi-NUL string in a bash
variable at all — stream each filename directly to the output with its own
`printf '%s\0'` call instead of accumulating them first. Verified by
packing a real DLC's two NCAs and diffing the result **byte-for-byte**
against the original hacpack-produced NSP (`cmp` reported identical
files), and separately confirming `nstool --fstree` reads the repacked
file back with a clean, correct file tree. See `lib/pfs0.sh`.

### Pipeline (what the script does)

0. Expand any directory inputs to the `.nsp` files directly inside them,
   then classify every resulting NSP: extract just its Meta NCA (via
   `nstool --fstree`'s virtual-path listing, so the whole NSP doesn't need
   extracting) and read the cnmt's content-meta `Type` with this project's
   own `parse_cnmt` (`lib/binfmt.sh`) — no `nstool` call for the cnmt
   itself. `Application` → base, `Patch` → update, `AddOnContent` → DLC.
   Also read the **base title ID** this content belongs to from the same
   parse (`TitleId` directly for an `Application`; `ApplicationId` for
   `Patch`/`AddOnContent` — see "The three title kinds" above), and group
   all classified inputs by that title ID. Steps 1–9 below then run
   **once per title group** — a directory with several different games
   mixed together produces one output NSP per game. A group with no
   `Application` NSP is skipped (with a clear error) rather than aborting
   the whole run; a group with more than one `Application` or `Patch` NSP
   keeps the first and warns about (skips) the rest.
1. Pick the **primary source**: the update NSP if one was found, else the
   base NSP. `nstool -x` — extract its NCAs to a scratch dir.
2. `nstool -t nca -x` — extract the primary source's Meta NCA to get the
   raw `.cnmt`.
3. `parse_cnmt` (`lib/binfmt.sh`, pure bash, no `nstool` call) — parse the
   cnmt for the base title ID (`TitleId` if primary is the base,
   `ApplicationId` if primary is the update), `Version`, and the NCA IDs
   for `Program`/`Control`/`LegalInformation`.
4. `nca_rights_id` (`lib/nca_header.sh`, pure bash AES-XTS decryption of
   just the NCA header, no `nstool` call) on the primary source's Program
   NCA — check for a `RightsId`. If one is present **and** an update was
   found, branch into the BKTR reconstruction path (steps 4a–4d);
   otherwise skip straight to step 5 using the primary source's Program
   NCA unmodified.
   1. Extract the base NSP's own Program NCA + ticket independently (not
      just the primary source), plus both sides' raw ticket-encrypted
      titlekeys (`nstool -t tik -v`, the `Title Key: Data:` field).
   2. `hactool --titlekey=<base_key> --plaintext=<file> <base_program.nca>`
      — decrypt the base Program NCA to a plaintext copy, so it can be used
      as a `--basenca` reference without a second key context.
   3. `hactool --titlekey=<update_key> --basenca=<plaintext_base.nca>
      --exefsdir <dir> --romfsdir <dir> <update_program.nca>` — reconstruct
      the update's **full** exefs/romfs by applying its BKTR delta against
      the base's data.
   4. `hacpack --type nca --ncatype program --plaintext --exefsdir <dir>
      --romfsdir <dir> --titleid <base_id>` — rebuild a genuinely
      standalone Program NCA from the reconstructed content, with standard
      (non-titlekey) crypto — no `RightsId` in the result at all.
5. `hacpack --type nca --ncatype meta --titletype application --titleid
   <base_id> --titleversion <hex>` — build a fresh Meta NCA declaring the
   Program NCA from step 4 (reconstructed or original, per the branch)
   alongside Control/LegalInformation as the base application. Built
   **twice**, to work around the zero-digest issue: first pass builds
   without `--digest`, then the script extracts that draft cnmt, hashes
   everything but its last 32 bytes, and rebuilds passing `--digest <hash>`
   to get the real one baked in.
6. If the reconstruction branch in step 4 wasn't taken (no update, or an
   update whose Program NCA isn't titlekey-crypto), copy any `.tik`/`.cert`
   sitting alongside the primary source's extracted NCAs into the merge
   directory, if present — carries the titlekey ticket through for a
   titlekey-crypto Program NCA that's genuinely standalone (no-op if the
   source used standard crypto). Not needed when step 4 did run, since its
   rebuilt Program NCA has no `RightsId`.
7. For each DLC NSP found: `nstool -x` its NCAs directly into the same
   working directory, unmodified — no cnmt parsing or rewriting needed,
   since the DLC's own Meta NCA already declares the correct type
   (`AddOnContent`) and references the base title ID via `ApplicationId`.
   Also copies the DLC's own `.tik`/`.cert` if present.
8. `pfs0_pack` (`lib/pfs0.sh`, pure bash, no `hacpack` call) — pack
   everything (the new Meta NCA, the Program NCA from step 4,
   Control/LegalInformation NCAs, any tickets/certs, and each DLC's own
   Meta + Data NCAs) into one flat PFS0 (NSP) container.
9. `nstool -x` the merged Control NCA, then `parse_nacp` (`lib/binfmt.sh`,
   pure bash, no `nstool` call) on the resulting `control.nacp` to read the
   game's display `Name` and `DisplayVersion`, then rename the packed NSP
   to `<Name> [<TitleId>][<DisplayVersion>][<DLC count>].nsp`.

Each title group's steps 1–9 run inside a subshell, so a hard failure in
one group doesn't stop the others — the group is recorded as failed and
the batch moves on to the next title. After all groups finish, a summary
prints how many succeeded/failed and lists each by title ID.

Verified via `nstool --fstree` and `nstool -y` on the output, and by
confirming a from-scratch manual run produced a byte-identical NSP to the
scripted one, across all four input combinations: base only, base+update,
base+DLC (no update), and base+update+DLC. The base+update and
base+update+DLC cases (which hit the BKTR reconstruction path for this
title) were also confirmed **on real hardware**: installs without error,
shows the update's version (not the base's), and the reconstructed content
plays correctly in-game.

### Verified NCA layout (Dicefolk, title ID `01002A801E57C000`)

Base NSP (`nstool --fstree`):
```
78cbbb4107c58eb1d1041edc22a800f0.nca        <- Program (RightsId ...c000...0011, titlekey crypto)
de2024b03d291dd48b12f5fbd412168d.nca        <- Control
39f50ffb5936e751f1a876a8c5e5d34f.nca        <- LegalInformation
2aadae6d29bceabac377d3fd219204e0.cnmt.nca   <- Meta (type Application, v0)
01002a801e57c0000000000000000011.tik/.cert <- ticket, matches Program's RightsId
```

Update NSP:
```
5d31bb79c1fc1273647a65750dc18f30.nca        <- Program (RightsId ...c800...0012, titlekey crypto;
                                                romfs partition is BKTR/AesCtrEx - a delta, not full data)
ffa46eded347479d8e4dd59b91b06b87.nca        <- Control
efb13dbca492736755dd3f47823abc06.nca        <- LegalInformation
d707072a86131f41e06a9e6fd9856c4f.cnmt.nca   <- Meta (type Patch, v65536,
                                                ApplicationId = 01002a801e57c000,
                                                own title id = ...c800)
01002a801e57c8000000000000000012.tik/.cert <- ticket, matches Program's RightsId
```

DLC NSP (`Dicefolk Chimera Pack`):
```
b1d512d4ec1e2441ce6ffcd261656094.nca        <- Data (no RightsId, standard crypto)
12c68c271374611ecad0219868c5fb18.cnmt.nca   <- Meta (type AddOnContent, v0,
                                                ApplicationId = 01002a801e57c000,
                                                own title id = ...d001)
```

Note the DLC has no Control or LegalInformation NCA of its own — just one
`Data`-type content NCA plus its Meta. The final merged NSP (base+update+
DLC) contains 6 files: the rebuilt standalone Program NCA (from BKTR
reconstruction), the rebuilt Meta NCA, the update's original
Control/LegalInformation NCAs, and the DLC's own Meta + Data NCAs — no
tickets needed, since the rebuilt Program NCA has no RightsId and the DLC's
Data NCA never had one. Confirmed via `nstool --fstree` / `nstool -y`, and
installed + played correctly on real hardware.

## Known issues encountered

Quick-reference list; each is explained in full in "The debugging story"
above.

- **`prod.keys` formatting bug**: several key entries (`mariko_master_kek_
  source_*`, `master_kek_source_*`, etc.) had a stray trailing `00` byte,
  making them 34 hex chars instead of the valid 32/64. This is a dump-tool
  quirk, not specific to this script. `hacpack`/`hactool` warn loudly
  ("Failed to match key") but only actually fail if a key they *need* is
  malformed. Fixed in place; original backed up to `~/.switch/prod.keys.bak`.
- **`hacpack --type nsp` requires `--titleid`** even though the Meta NCA
  already encodes it — undocumented in `--help`, discovered by trial. The
  script always passes it explicitly.
- **"The titlekey for this Rights ID could not be found"** on install —
  see "Bug #1" above. Fixed by carrying `.tik`/`.cert` through into the
  output NSP.
- **"Game updates cannot be loaded directly. Load the base game instead."**
  on install — see "Bug #2" above. Two stacked causes: a zero cnmt digest
  (fixed by building the Meta NCA twice with `--digest`), and the update's
  Program NCA being BKTR-delta-encoded (fixed by reconstructing the full
  romfs/exefs against the base and rebuilding a standalone Program NCA).
- **`hactool` "Invalid BKTR layout!" / silently empty romfs extraction on
  some titles' updates** — see "Bug #3" above. A real, confirmed, unfixed
  bug in upstream `hactool` 1.4.0 itself (not this project's code):
  overly-strict exact-equality checks in its BKTR (patch-romfs) layout
  validation reject some legitimate update NCAs. Fixed by vendoring a
  locally-patched `hactool` in `bin/` — see "Requirements" above and
  `bin/patches/hactool-1.4.0-bktr-layout-fix.patch`.
- **`openssl enc` refuses AES-XTS mode entirely** — see "Bug #4" above.
  A permanent limitation of that specific CLI subcommand, not a config
  issue. Fixed by building AES-XTS from raw AES-ECB operations
  (`lib/nca_header.sh`), since `openssl enc -aes-128-ecb` works fine.
- **Filenames running together with no separator when repacking a PFS0**
  — see "Bug #5" above. Caused by bash silently dropping everything after
  the first embedded NUL byte when a multi-NUL string was built as one
  bash variable and printed with `printf '%s'`. Fixed by streaming each
  filename directly to the output with its own `printf '%s\0'` call
  instead (`lib/pfs0.sh`).

## Tools considered and ruled out

| Tool | Verdict |
|---|---|
| NSC_Builder | Does the real job, but Windows-first, archived, GUI-oriented. The reason this project exists. |
| `nsz` | Compress/decompress only (NSP↔NSZ, XCI↔XCZ). Not a content merger. |
| `hacBrewPack` / `hacPack` (initial read) | First assumed to be homebrew-source-only (builds NCAs from romfs/exefs dirs). Turned out `hacpack`'s `--ncatype meta`/`--ncatype program` + `--ncadir` modes are exactly what's needed for building NCAs — see above. Its flat `--type nsp` container-packing role has since been replaced by this project's own `lib/pfs0.sh` (no crypto/hashing involved in that format, low risk to reimplement — see "The debugging story"), but `hacpack` is still used for the actual NCA-building steps (Meta, Program), which do involve encryption/hash-tree construction. |
| `nstool` | Read/extract/verify only, no repack — used for the NCA/NSP extraction half of the pipeline (decrypting per-title content, which needs real key derivation this project deliberately hasn't reimplemented). Its own `--basenca` support turned out to need both sides' tickets simultaneously, which its single `--tik`/`--cert` flag pair can't express for base+update with different Rights IDs — `hactool` was used instead for the BKTR reconstruction step, since its `--titlekey=<raw>` + `--basenca=<plaintext nca>` combination doesn't have that limitation. cnmt/NACP field reading and NCA-header `RightsId` reading no longer use `nstool` at all — see `lib/binfmt.sh`/`lib/nca_header.sh`. |
| `hactool` | Chosen for BKTR delta reconstruction (`--basenca` against a plaintext-decrypted base Program NCA) — see "The debugging story". Also used to decrypt a titlekey-crypto NCA to plaintext (`--plaintext=<file>`) as a prerequisite for that. Upstream 1.4.0 has a real, confirmed BKTR layout-validation bug (Bug #3) — this project vendors a locally-patched build in `bin/` rather than the stock release. |
| `DarkMatterCore/nxdumptool` | Not used as a dependency, but its source was consulted directly to confirm hactool's BKTR checks are unnecessary (see Bug #3) — it successfully reads BKTR patch romfs with no equivalent pre-validation at all. |
| `switch-merge-utility` (Rust, LordZeuss) | GUI-only, no documented CLI mode. |
| `nxDumpFuse` | Solves a different problem — rejoining split dump *chunks* (`.nsp.00`, `.xc0`, etc.), not content merging. |

## Roadmap

- [x] DLC merging — implemented: any number of DLC NSPs are appended as
      their own unmodified Meta + Data NCA sets (see above).
- [x] Optional update — implemented: base-only and base+DLC-without-update
      both work, using the base's own cnmt as the merge source when no
      update is present among the inputs.
- [x] Auto-detect base/update/DLC — implemented: no `-b`/`-u`/per-file DLC
      flags at all. Every input NSP (or every `.nsp` inside an input
      directory) is classified by its own cnmt content-meta `Type` field —
      not by filename — and sorted into base/update/DLC automatically. See
      "Pipeline" step 0 above.
- [x] Titlekey-crypto title support — implemented, in two layers:
      (1) for a genuinely standalone titlekey-crypto Program NCA (e.g.
      base-only merges), the script carries its `.tik`/`.cert` into the
      merged NSP's PFS0 so the console can resolve `RightsId` to a titlekey
      at install time; (2) for an update whose Program NCA turns out to be
      BKTR-delta-encoded (the common case for titlekey-crypto updates seen
      so far), tickets alone aren't enough — the script instead reconstructs
      the full romfs/exefs via `hactool --basenca` against the base, then
      rebuilds a standalone standard-crypto Program NCA via
      `hacpack --ncatype program --plaintext`, which needs no ticket at all.
      Confirmed on real hardware for this project's test title.
- [x] Descriptive output filename — implemented: the merged NSP is renamed
      to `<Name> [<TitleId>][<DisplayVersion>][<DLC count>].nsp`, reading
      `Name`/`DisplayVersion` from the merged Control NCA's NACP instead of
      the cnmt's internal version integer.
- [x] Batch mode across multiple titles (1G1R) — implemented: inputs are
      grouped by base title ID (see "Pipeline" step 0 above), and one merge
      runs per group, producing one output NSP per game. A directory mixing
      several different games' base/update/DLC files together no longer
      needs to be split up first. One group failing (missing base, corrupt
      file, ...) doesn't stop the others — each group runs in its own
      subshell, and a summary at the end reports success/failure per title.
      Confirmed end-to-end with two real, different games in one batch run
      (Dicefolk + Well Dweller) — this is also what surfaced Bug #3 above,
      a real `hactool` bug that the single-title test case never hit.
- [x] Self-contained toolchain — implemented: `nstool`/`hacpack`/`hactool`
      are vendored in `bin/`, which `switch-merge.sh` puts first on `PATH`
      automatically. No system package install required; also the only way
      to get the Bug #3 `hactool` fix applied without patching a system
      package.
- [x] Zero-argument default — implemented: with no positional inputs,
      scans the directory the script itself lives in (not the caller's
      cwd) and defaults `-o` to `merged/` next to it, so dropping files
      alongside the script and running `./switch-merge.sh` with no
      arguments just works.
- [x] Reduce dependency on vendored tools, starting with the easiest piece
      — implemented: `lib/binfmt.sh` is a pure-bash (no external binary)
      parser for cnmt (`PackagedContentMeta`) and NACP (`control.nacp`),
      the two small, well-documented binary formats the script needs to
      read fields from (title ID, content-meta type, version,
      Program/Control/LegalInformation content IDs, display name,
      display version). Replaces the four call sites that used to
      text-scrape `nstool -t cnmt -v` / `nstool -t nacp -v`'s human-
      readable dump with `grep -oP`. Verified against every real cnmt
      shape this project has seen (Application/Patch/AddOnContent) and
      real NACP files, byte-for-byte matching `nstool`'s own output — see
      "Switch content format, from scratch" and "The debugging story"
      below for the format details and verification approach.
      **`nstool` is still used** for everything involving NCA container
      extraction/decryption (AES-CTR/titlekey crypto, hash-tree
      verification) — reimplementing *that* from scratch risks silently
      corrupted output on a subtle bug, which isn't worth it for tooling
      that already works and is already open-source
      (jakcron/nstool, MIT-ish license) and locally patchable if needed
      (as already done for `hactool`'s BKTR bug). `hacpack`/`hactool`
      remain fully in use for NCA/NSP packing and BKTR reconstruction, for
      the same reason.
- [x] Reduce dependency on vendored tools, second piece — implemented:
      `lib/nca_header.sh` reads `RightsId` directly from the NCA header by
      building AES-XTS decryption from scratch (raw AES-ECB via `openssl`
      + hand-rolled GF(2^128) tweak math), replacing the
      `nstool -t nca -v | grep RightsId` call site. `lib/pfs0.sh`
      pure-bash packs the final NSP container, replacing
      `hacpack --type nsp`. Both verified against real files (AES-XTS:
      decrypted a real NCA header and matched `nstool`'s own `RightsId`
      and magic; PFS0: repacked NSP is byte-for-byte identical to the
      original `hacpack`-produced file via `cmp`). Two real bugs found and
      fixed along the way — see Bug #4 (`openssl enc` has no XTS mode at
      all) and Bug #5 (bash drops embedded NUL bytes from string
      variables, corrupting the PFS0 string table) in "The debugging
      story". **NCA content-partition decryption (AES-CTR, per-title
      keys, hash-tree verification) and NCA-building (Meta/Program, which
      needs to *write* those hash trees) remain on `nstool`/`hacpack`,
      and BKTR reconstruction remains on `hactool`** — those are a
      materially higher risk tier (a subtly wrong implementation would
      silently produce corrupted game/save data, not a clean error) and
      were deliberately not attempted without discussing that risk first.
- [ ] Handle DLC packs containing multiple `AddOnContent` titles in one NSP
      (only single-title DLC packs have been tested so far).
- [x] ~~XCI output (`-f xci`)~~ — **decided against, not implemented.**
      Investigated: neither `hacpack` nor `hactool` can *write* an XCI —
      `hacpack --type` only accepts `nca`/`nsp`, and `hactool`'s XCI support
      is read/extract only (`-t xci`, `--rootdir`/`--updatedir`/etc. for
      unpacking). NSC_Builder had to write its own from-scratch XCI packer
      to support this (its own code, not `hacbuild`) — meaning building it
      here would mean implementing the XCI header, cert area, and HFS0
      partition layout (root/update/normal/logo/secure) by hand, with no
      existing tool to build on. Also: XCI is the **gamecard image**
      format, meant for cartridge dumps/flashing carts — not what
      Tinfoil/DBI-style sideloading (this project's actual use case) needs.
      Decided the complexity/risk isn't worth it for a format this project
      doesn't actually need. Revisit only if a concrete need for real XCI
      output shows up.
