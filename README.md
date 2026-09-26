# switch-merge

Merges a Nintendo Switch base-game NSP with (optionally) its update NSP
and (optionally) any number of DLC NSPs into a single installable NSP,
natively on Linux, entirely in bash (`nstool`/`hacpack`/`hactool` are
vendored in `bin/` but none of them are a runtime dependency anymore —
see "Reduce dependency on vendored tools" in the roadmap below). Built as
a CLI-native replacement for
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
  own — see "The debugging story" below for why). Only needed for the
  `--pure` (bash-only) path — the default path's own crypto is `smtool`'s
  compiled-in libcrypto, not the `openssl` CLI.
- **`bin/smtool`, this project's own C reimplementation of the
  performance-critical pipeline** (see "smtool" below) — build once with
  `make -C src/smtool` (needs `gcc`/`cc` and OpenSSL dev headers,
  `libssl-dev`/`openssl-devel` depending on distro, at BUILD time only;
  confirmed working with OpenSSL 3.6.4 and gcc 16.2.1). Required unless
  `--pure` is passed, in which case the script falls back to the slower,
  zero-compiled-dependency bash implementation instead and `smtool`
  doesn't need to exist at all.
- Your console's `prod.keys` at `~/.switch/prod.keys` (standard Lockpick_RCM
  output location).

**No package install needed, and no vendored binary is actually required
to run a merge anymore.** `nstool`/`hacpack`/`hactool` are still vendored
in `bin/` (which `switch-merge.sh` puts first on `PATH` automatically,
for whenever they're wanted) purely as optional manual-debugging/
cross-verification tools — every one of them was confirmed unused by the
real merge pipeline via the same test: temporarily replace the vendored
binary with a wrapper that fails loudly if invoked, then run a full
merge and confirm the wrapper never fires. `bin/hactool` specifically
still carries a local fix for two real bugs in upstream 1.4.0 (the latest
release, and still present at time of writing) that reject some
legitimate update NCAs — see "The debugging story" below and
`bin/patches/hactool-1.4.0-bktr-layout-fix.patch` for the exact change and
why it's needed, even though the pipeline itself now has its own,
separate from-scratch BKTR reader (`lib/bktr.sh`) that doesn't share that
bug at all. If you ever want to rebuild these from source instead of
trusting the vendored binaries:
```
git clone --branch 1.4.0 https://github.com/jakcron/nstool.git   # or your distro's package
git clone --branch 1.4.0 https://github.com/DarkMatterCore/hacPack.git
git clone --branch 1.4.0 https://github.com/SciresM/hactool.git
cd hactool && git apply /path/to/bin/patches/hactool-1.4.0-bktr-layout-fix.patch
```
(`hacpack`/`nstool` are used unpatched — only `hactool` needed a fix.)

## Usage

```
./switch-merge.sh [-o <output_dir>] [-k keys.dat] [<nsp-or-xci-or-dir> ...]
```

- `-o` output directory (defaults to `merged/` next to the script itself)
- `-k` path to keys file (defaults to `~/.switch/prod.keys`)
- every other argument is either an individual `.nsp`/`.xci` file or a
  directory (non-recursively globbed for `*.nsp`/`*.xci` files inside it),
  in any order — with **no** positional inputs at all, defaults to scanning
  the directory the script itself lives in (not your current working
  directory), so `./switch-merge.sh` with zero arguments just works: drop
  your base/update/DLC files next to the script and run it. `.xci`
  (gamecard dump) input works the same as `.nsp` — each one's "secure"
  partition is split into one or more classifiable titles internally
  before merging (a single cartridge can carry more than one independent
  title's content); see "Switch content format, from scratch" below for
  what an XCI actually contains.

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

### XCI: the gamecard container format

An **XCI** is a raw dump of a physical game cartridge — a different outer
container from NSP, but holding the same underlying NCAs. Structurally:
a small `HEAD`-magic'd header (0x100 bytes in, at file offset 0x100)
whose `PartitionFsHeaderAddress` field points at a **root** partition,
itself a container format called **HFS0** (HashedFs) — PFS0's hashed
sibling: same flat header/entry-table/string-table/file-data shape, just
with a bigger per-entry struct that adds a partial-file SHA256 (an
on-cartridge integrity check, not needed to just read the file back out,
and not checked by this project's own `lib/hfs0.sh` reader for the same
reason other purely-correctness hash checks are left to `nstool`/
`hactool` elsewhere in this project). The root HFS0's entries don't
contain files directly — each one is itself another HFS0 partition:

- **`update`** — a **system firmware** update bundle (dozens of
  unrelated NCAs), not a per-title game update. Not read by this project.
- **`normal`**/**`logo`** — icon/branding assets (`NintendoLogo.png`,
  a startup movie, etc.), not game content. Not read by this project.
- **`secure`** — every real title's own NCAs (Program/Control/
  LegalInformation/Meta, same as an NSP holds), with no titlekey/ticket
  crypto ever seen in practice (a physical cartridge has no eShop
  purchase to tie a ticket to). **This is the only partition
  `switch-merge.sh` reads.**

The one thing that doesn't map cleanly onto NSP's world: a real cartridge's
**`secure` partition can hold more than one independent title's NCAs
flattened together**, with no further file-level grouping — confirmed
against a real dump holding two separate `Application`-type titles under
two different title IDs side by side (not a base+update pair for one
game). `switch-merge.sh`'s `xci_split_to_nsps` handles this by finding
every `*.cnmt.nca` in the extracted `secure` partition and using each
one's own cnmt (same `parse_cnmt` used everywhere else in this project) to
figure out which sibling NCAs belong to it, rather than assuming one
partition is one title. See "Reduce dependency on vendored tools" roadmap
entry "XCI input" below for the full derivation and verification.

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

0. Expand any directory inputs to the `.nsp`/`.xci` files directly inside
   them. Each `.xci` is first split into one or more synthetic `.nsp`s (one
   per title found in its `secure` partition — see "XCI: the gamecard
   container format" above) via `xci_split_to_nsps`, so every input from
   this point on is a real or synthetic NSP with no further XCI-specific
   handling anywhere downstream. Then classify every resulting NSP: extract
   just its Meta NCA (via
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
      titlekeys via `parse_tik` (`lib/binfmt.sh`, pure bash, no `nstool`
      call).
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

## smtool

The bash pipeline described above is entirely dependency-minimal by
design, but was measured to be roughly two orders of magnitude slower
than the vendored C tools doing equivalent work (extracting a real
2.6GB XCI: 74.6s vs `hactool`'s 0.77s) — dominated by per-byte hex-
string parsing in bash and hundreds of `dd`/`xxd`/`openssl` subprocess
spawns per merge, neither of which is tunable further inside bash
itself.

`src/smtool/` is a from-scratch C reimplementation of every
performance-critical piece of the pipeline above — both the binary/
struct parsing (cnmt/NACP/ticket/PFS0/HFS0/RomFs/BKTR-bucket-tree) and
the crypto (AES-XTS header decrypt/encrypt, AES-CTR content decrypt/
encrypt, per-title key derivation, SHA256 hash trees), all linking
libcrypto (OpenSSL) rather than shelling out to the `openssl` CLI.
Build it once with `make -C src/smtool` (produces `bin/smtool`); it's
required by default, unless `--pure` is passed, in which case
`switch-merge.sh` calls the original `lib/*.sh` bash functions directly
instead (slower, but zero compiled dependency beyond `xxd`/`openssl`
as already documented above).

`bin/smtool <subcommand> <args...>` — one-shot subcommands, spawned
exactly like the vendored `nstool`/`hacpack`/`hactool` always have been
(one process per operation, do one thing, exit; run `bin/smtool` with
no arguments for the full subcommand list). Multi-field results are
printed as `KEY=VALUE` lines, one per line, named identically to the
bash globals they replace (e.g. `nca-section-info` prints
`NCA_SECTION_OFFSET=...` exactly like `lib/nca_content.sh`'s
`nca_section_info` sets `NCA_SECTION_OFFSET` as a real bash global) —
read back into `switch-merge.sh` via a small shared `read_kv_into_vars`
helper. Every call site in `switch-merge.sh` is routed through a
matching `op_*` wrapper function (`op_parse_cnmt`, `op_nca_rights_id`,
`op_nca_build_program`, etc.), each branching on a single `PURE`
variable — never a per-call-site `if $PURE` scattered through the
pipeline, so both the compiled and `--pure` code paths stay in exactly
one place to keep in sync.

This was built incrementally, phase by phase (mirroring how the
original bash port itself was built — see the numbered `smtool`
roadmap entries below for the full phase-by-phase history, what each
one verified, and the real bugs caught along the way): pure struct
parsing first (lowest risk, no crypto), then NCA header crypto, then
content-key derivation, then RomFs/BKTR readers, then the streaming
AES-CTR content decryption that turned out to be the first phase with
a genuinely large measured speedup, then the RomFs and NCA (Meta,
Program) *writers*. Every phase was verified against this project's
own existing bash implementation (byte-for-byte, `cmp`, on real files
wherever a real sample was available) and, at the NCA-building phases
specifically, independently cross-checked against `nstool` — real
external ground truth, not just self-consistency between this
project's own two implementations of itself. `tests/run.sh` (a small
fixture harness under `tests/fixtures/`) automates most of this
verification and can be re-run at any time with `bash tests/run.sh` —
crypto-dependent tests skip automatically if no real
`~/.switch/prod.keys` is present on the machine running them, so the
suite still gives full coverage of every fixture that doesn't need one
even in a clean checkout.

**Total measured speedup, full pipeline compiled**: 3.9s vs 43.0s for
the same real XCI merge (~11x) — see the roadmap entries below for the
step-by-step progression (Phase 1's own honest finding that early
phases barely moved the needle, through Phase 5's first large jump,
to this final number).

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
| `hacBrewPack` / `hacPack` (initial read) | First assumed to be homebrew-source-only (builds NCAs from romfs/exefs dirs). Turned out `hacpack`'s `--ncatype meta`/`--ncatype program` + `--ncadir` modes are exactly what's needed for building NCAs. **No longer used by the merge pipeline at all** — its flat `--type nsp` container-packing role was replaced early on by this project's own `lib/pfs0.sh` (no crypto/hashing involved, low risk — see "The debugging story"), and its NCA-building role (Meta, Program — real hash-tree construction, once assumed to be the one piece not worth reimplementing) turned out to need no cryptographic primitive beyond what this project already had for reading; see `lib/nca_build.sh`/`lib/romfs_build.sh` and the roadmap's final ("eighth piece") entry for the full derivation, defaults reproduced, and byte-for-byte verification. Confirmed truly unused via the same wrapper-substitution test as `nstool`/`hactool`. Still vendored in `bin/` for manual debugging/cross-verification only. |
| `nstool` | **No longer used by the merge pipeline at all.** Every call site it used to have — cnmt/NACP field reading, NCA-header `RightsId` reading, ticket (`.tik`) titlekey reading, per-title content-key derivation + AES-CTR content decryption, NSP/NCA(PartitionFs) container splitting, and Control NCA `control.nacp` extraction (RomFs/`HierarchicalIntegrity`) — is now pure bash; see `lib/binfmt.sh`/`lib/nca_header.sh`/`lib/nca_content.sh`/`lib/pfs0.sh`/`lib/romfs.sh` and `switch-merge.sh`'s `extract_nsp`/`extract_cnmt_from_meta_nca`/`extract_nacp_from_control_nca`. Confirmed truly unused (not just untested) by temporarily replacing the vendored `bin/nstool` with a wrapper that fails loudly if invoked and re-running a full 1G1R batch merge end-to-end — it never fired. Still vendored in `bin/` for manual debugging, just no longer a runtime dependency. |
| `hactool` | **Also no longer used by the merge pipeline.** Was chosen for BKTR delta reconstruction (`--basenca` against a plaintext-decrypted base Program NCA) and decrypting a titlekey-crypto NCA to plaintext (`--plaintext=<file>`) as a prerequisite for that — see "The debugging story" for the original investigation, and "Reduce dependency on vendored tools" roadmap's final entry for how this project's own `lib/bktr.sh` replaced both, derived directly from this exact vendored `hactool` 1.4.0 build's own C source (the BKTR relocation/subsection bucket-tree format isn't documented anywhere else). Confirmed truly unused the same way as `nstool` above (wrapper substitution, full batch merge, no invocation), and confirmed correct by diffing (`diff -rq`) the pure-bash reconstruction's full output directory tree against `hactool --basenca`'s own reconstruction, byte-for-byte, on both this project's real BKTR update titles (including the harder of the two, which needed splitting reads at subsection boundaries mid-reconstruction). Upstream 1.4.0 has a real, confirmed BKTR layout-validation bug (Bug #3) — this project's own from-scratch reader doesn't implement that overly-strict check at all, consistent with Bug #3's own finding that it's unnecessary. Still vendored in `bin/` (a locally-patched build, not the stock release) for manual debugging/cross-verification, just no longer a runtime dependency. |
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
      Confirmed on real hardware for both of this project's test titles
      (Dicefolk and Super Smash Bros. Ultimate).
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
- [x] Reduce dependency on vendored tools, third piece — implemented:
      `lib/binfmt.sh` gained `parse_tik`, a pure-bash parser for the
      ticket (`.tik`) format that reads the raw, still ticket-encrypted
      titlekey (what `hactool --titlekey=` wants) directly from its fixed
      offset (`0x180`, 16 bytes, for the RSA-2048-SHA256 SignType every
      real console ticket seen so far uses), replacing the
      `nstool -t tik -v | grep -A4 "Title Key" | grep -oP ...` text-scrape
      in the BKTR-reconstruction code path. Also reads `RightsId` (`0x2A0`)
      for completeness, though the script still gets `RightsId` from the
      NCA header (`lib/nca_header.sh`) as the authoritative source.
      Verified byte-for-byte against `nstool -t tik -v`'s own `Data:` and
      `RightsId:` output on real extracted tickets (both the base's and
      the update's, different Rights IDs), and by re-running the full
      Dicefolk base+update+DLC merge end-to-end and confirming the output
      NSP is byte-for-byte identical (`cmp`) to the previously-verified,
      hardware-tested output. **`nstool` is still used** for full NSP/NCA
      container extraction (`-x`, `-t nca -x`) and everything involving
      per-title AES-CTR decryption/hash-tree verification — reimplementing
      that remains the same higher-risk tier described above.
- [x] Reduce dependency on vendored tools, fourth piece — **primitive
      implemented and verified, not yet wired into the merge pipeline**:
      `lib/nca_content.sh` adds pure-bash per-title content-key derivation
      and AES-128-CTR decryption of an NCA content section (Program/Data/
      Control partitions), for both standard-crypto (unwrap the header's
      own embedded key area with `key_area_key_<application|ocean|system>_
      <generation>` from `prod.keys`) and titlekey-crypto (unwrap the
      ticket's raw titlekey — `parse_tik`'s `TIK_TITLEKEY` — with
      `titlekek_<generation>` instead) content. `openssl enc -aes-128-ctr`
      handles a whole section in one subprocess call (confirmed on a real
      195 MB Program romfs partition, ~0.6s) — unlike the header's AES-XTS,
      CTR mode is natively supported by the `enc` CLI, so no per-block bash
      loop is needed here. The non-obvious part was the AES-CTR initial
      counter construction: the section's own `SectionCTR` FS-header field
      (an opaque per-title "secure value", not an offset) forms the
      counter's upper 8 bytes **byte-reversed**, and the section's absolute
      byte offset within the NCA (shifted right 4, i.e. counted in 16-byte
      AES-block units) forms the lower 8 bytes big-endian — not documented
      in this much detail on switchbrew's wiki, so this project's own
      vendored `hactool` 1.4.0 source (`nca.c`'s `nca_init_section_ctx()`)
      was read directly as the authoritative reference instead of guessing.
      Verified byte-for-byte against `nstool`'s own output on real files:
      standard-crypto key/CTR derivation confirmed against a DLC Data NCA's
      `nstool -t nca -v` dump, and its decrypted section found to contain
      the exact bytes `nstool -t nca -x` extracted from it; titlekey-crypto
      key/CTR derivation confirmed against Dicefolk's base Program NCA
      (`nstool --tik --cert -t nca -v`, a case with a nonzero `SectionCTR`,
      so the byte-reversal logic was genuinely exercised, not just an
      all-zero coincidence), and its decrypted exefs section found to
      contain all five files (`main`, `main.npdm`, `sdk`, `rtld`, `subsdk0`)
      `nstool --tik --cert -t nca -x` extracted from the same NCA,
      byte-for-byte. **Deliberately left unimplemented**: `AesCtrEx`
      (BKTR-delta romfs) sections — Nintendo's per-subsection initial-
      counter formula is real additional arithmetic beyond a plain section
      offset, and wasn't attempted without verifying it first, so BKTR
      reconstruction stays entirely on `hactool` as before — and hash-tree
      (Merkle/`HierarchicalIntegrity`/`HierarchicalSha256`) verification,
      left to `nstool`/`hactool` by design, not just deferred, since a
      naive bash reimplementation is subprocess-spawn-bound (one SHA256 per
      16 KB block — tens of seconds to minutes on a large partition) for a
      correctness-only check that gains nothing from a bash rewrite.
- [x] Reduce dependency on vendored tools, fifth piece — **wired into the
      merge pipeline**: `lib/pfs0.sh` gained an unpack half (`pfs0_extract`,
      `pfs0_extract_all`) alongside its existing packer, and
      `switch-merge.sh` now has `extract_nsp` (splits an NSP - a plain,
      unencrypted PFS0 - into its NCA/tik/cert files) and
      `extract_cnmt_from_meta_nca` (decrypts a Meta NCA's PartitionFs
      section via `lib/nca_content.sh` and pulls out its `.cnmt` via
      `pfs0_extract`), replacing every `nstool -x` / `nstool -t nca -x`
      call site in the classification and merge-group code paths. Every
      real Meta NCA seen so far (base/update/DLC, both test titles) is
      standard-crypto, so `extract_cnmt_from_meta_nca` only implements
      that path and fails loudly (rather than guessing) if it ever meets a
      titlekey-crypto one. Two real bugs surfaced and were fixed while
      wiring this in:
      - `dd bs=1` (fine for the tiny fixed-size header/entry-table reads
        `_pfs0_read_entries` does) is unusably slow for actual file-sized
        payloads — extracting a 370 MB entry this way was still running
        after a minute before being killed. Fixed by switching the actual
        data-copy `dd` calls to `bs=1M` with `iflag=skip_bytes,count_bytes`
        (byte-precise skip/count even with a large block size) - the same
        pattern `lib/nca_content.sh`'s `nca_ctr_decrypt_section` already
        used correctly; extracting that same 370 MB entry now takes
        well under a second.
      - Reading a name out of the string table via
        `dd ... | cut -d $'\0' -f1` looked correct in an isolated synthetic
        test, but corrupted every name after the first when run against a
        real NSP — each name ran together with the *next* entry's raw file
        bytes, the same visible *symptom* as Bug #5 above, though confirmed
        (by reproducing it against a materialized file, ruling out a
        live-pipe-buffering explanation) to be a `cut`/pipe interaction
        with embedded NULs specifically, not bash's own NUL-in-a-variable
        behavior this time. Fixed by reading the whole entry+string table
        as one hex blob (same approach the rest of this project's parsers
        use) and scanning for the `00` byte pair in hex text instead of
        piping raw bytes through `cut`.
      - A third, subtler bug: `_pfs0_read_entries` originally set a
        `PFS0_DATA_OFF` global as a side effect for callers to read after
        the fact, but every caller consumed it via
        `while read ... done < <(_pfs0_read_entries ...)` — a process
        substitution that runs in its own subshell, so the global was
        invisible back in the loop body (silently read as unset/0,
        extracting every single entry from the wrong file offset). Fixed
        by splitting a separate `_pfs0_data_off` function callers invoke
        directly (via normal `$(...)` command substitution, which *does*
        propagate a return value, just not a side-effect global) before
        entering the loop, rather than relying on a global crossing a
        subshell boundary.
      Verified by re-running the full 1G1R batch merge (both Dicefolk,
      which exercises BKTR reconstruction/titlekey crypto, and Well
      Dweller, base+update with no DLC) end-to-end with the wired-in code
      and confirming both output NSPs are byte-for-byte identical (`cmp`)
      to the previously verified, hardware-tested outputs. At this point
      `nstool` had exactly one remaining call site: extracting a merged
      Control NCA's `control.nacp` for the output filename's display
      name/version — Control NCAs use the RomFs/`HierarchicalIntegrity`
      container format, not the simpler PartitionFs/`HierarchicalSha256`
      format Meta NCAs use, which this project didn't parse yet at the
      time.
- [x] Reduce dependency on vendored tools, sixth piece — **`nstool`
      eliminated entirely.** New `lib/romfs.sh` adds a pure-bash RomFs
      file-table reader (flat, root-directory-only lookup by name — every
      real Control NCA's RomFs seen so far has every file, icons +
      `control.nacp`, directly in the root with no subdirectories, so a
      full directory-tree walk wasn't needed and wasn't built) and
      `switch-merge.sh` gained `extract_nacp_from_control_nca`
      (decrypts a Control NCA's RomFs/`HierarchicalIntegrity` section via
      `lib/nca_content.sh` — same AES-CTR decrypt as the Meta NCA case,
      just a different, IVFC-shaped hash-layer header to skip past first —
      then reads `control.nacp` out of it via `romfs_extract`), replacing
      the pipeline's last `nstool` call site. `lib/nca_content.sh` also
      gained `nca_hierarchical_integrity_data_layer`, the IVFC-format
      counterpart to the existing `nca_hierarchical_sha256_data_layer` —
      genuinely a different struct shape (an `IVFC`-magic'd header with a
      variable `NumLevels` count of `{LogicalOffset, HashDataSize,
      BlockSizeLog2, Reserved}` entries, where the DATA layer is at index
      `NumLevels-2` because the last entry is an always-zero, unused
      trailer — confirmed against a real Control NCA's own FS header and
      `nstool -t nca -v`'s "HierarchicalIntegrity Header" dump, byte-for-
      byte), not a variant of the PartitionFs/`HierarchicalSha256` one.
      Two real bugs found while building this:
      - `dd`'s `count=`/`skip=` flags do not accept a bash-style `0x...`
        hex literal directly — passing one silently produces `count=0`
        (with a warning easy to miss under `2>/dev/null`), not an error,
        which looked at first like an empty/corrupt file rather than a
        unit-conversion mistake. Every other hex constant in this
        project's lib/*.sh files was already safe from this because it
        only ever reached shell arithmetic contexts (`$(( ))`,
        `${var:offset:len}`) — this was the first place a literal hex
        constant was handed to an external command's own argument
        parsing instead. Fixed by wrapping the literal in `$(( ))` first.
      - The DATA layer being at index `NumLevels-2`, not `NumLevels-1`
        like the PartitionFs case's `LayerCount-1`, was not obvious from
        the wiki's field list alone — confirmed only by dumping a real
        Control NCA's FS header bytes directly and finding the last
        (`NumLevels-1`th) entry all-zero while the second-to-last matched
        nstool's own reported Data Layer offset/size exactly.
      Verified end-to-end: decrypted a real Control NCA's RomFs section,
      extracted `control.nacp` via the new code, and confirmed it's
      byte-for-byte identical (`cmp`) to `nstool -t nca -x`'s own
      extraction of the same file. Then, to confirm `nstool` is TRULY
      unused (not just unused by the code paths exercised in this
      session's testing), the vendored `bin/nstool` binary was temporarily
      replaced with a wrapper script that prints a loud message and exits
      nonzero if ever invoked, and the full 1G1R batch merge (both test
      titles, base+update+DLC and base+update) was re-run end-to-end: the
      wrapper never fired, and both output NSPs were still byte-for-byte
      identical to the previously hardware-verified references. `nstool`
      remains vendored in `bin/` anyway (harmless, and still useful for
      manually cross-checking this project's own pure-bash code against
      real files, the same way it was used to build and verify everything
      above), but the merge pipeline itself has zero remaining dependency
      on it.
- [x] Reduce dependency on vendored tools, seventh piece — **`hactool`
      eliminated too.** New `lib/bktr.sh` reimplements BKTR (patch-romfs)
      delta reconstruction in pure bash, replacing both remaining
      `hactool` call sites: decrypting the base Program NCA to plaintext
      (`--titlekey= --plaintext=`) and the actual reconstruction
      (`--basenca=`). The base-plaintext step turned out to be
      unnecessary as a separate step at all — investigating it showed
      `hactool --plaintext`'s output isn't a clean, documented NCA format
      (it's a non-standard intermediate specifically for `hactool`'s own
      `--basenca` consumption; `nstool` itself crashes trying to read it),
      so instead of reproducing that intermediate, this project's own
      `nca_ctr_decrypt_section` (`lib/nca_content.sh`) decrypts the base's
      romfs section directly to a raw blob, which turned out to be exactly
      what BKTR reconstruction actually needs to read from (a plain,
      offset-indexed byte source — nothing NCA-container-specific).
      BKTR's actual format — a two-level "bucket tree" indirection: a
      RELOCATION table mapping virtual (reconstructed) romfs byte ranges
      to either the update's own physical bytes or the base's, and a
      SUBSECTION table giving each physical byte range within the update
      side its own AES-CTR `ctr_val` — is **not documented anywhere
      online** (switchbrew's wiki only covers the high-level "Enc. Type:
      AesCtrEx" concept, none of the internal table layout), so every
      struct offset and lookup rule was derived directly from this
      project's own vendored `hactool` 1.4.0 build's C source
      (`nca.c`/`nca.h`/`bktr.c`/`bktr.h`) instead of guessed — see
      `lib/bktr.sh`'s header comment for the full derivation, including
      one place its own source comment (`_0xE0[0x18]` padding) didn't
      match real files' actual byte layout by 8 bytes, caught by trusting
      real decrypted bytes over the comment. The BKTR superblock's own
      relocation/subsection headers were found to sit at a fixed offset
      right after the section's IVFC integrity header (which
      `nca_hierarchical_integrity_data_layer`, from the "sixth piece"
      above, already parses the start of); reading the relocation/
      subsection TABLES themselves (not just their headers) turned out to
      need only a completely ordinary, non-BKTR-aware AES-CTR section
      read at their own physical offset — `nca_content_ctr`/
      `nca_ctr_decrypt_section` already handled this with no new code,
      confirmed directly from `hactool`'s own source: at the point it
      reads these tables, its BKTR-specific virtual-seek logic hasn't
      been enabled yet.

      Also confirmed empirically (not assumed) that this project's real
      test files exercise the general case, not just the easy one: a
      relocation entry's own physical byte range can itself span multiple
      subsections, each needing its own CTR — happens on 18 of 243
      relocation entries in the harder of this project's two real BKTR
      titles (Well Dweller, 41 total subsections; the other, Dicefolk, has
      only 1 subsection and never exercises this) — so `bktr_reconstruct`
      splits a relocation-entry-sized read at every subsection boundary it
      crosses, exactly mirroring hactool's own recursive "easy path/sad
      path" read-splitting logic.

      `lib/romfs.sh` also gained `romfs_extract_all` (a full, recursive
      directory-tree walker — the existing `romfs_extract` only does a
      flat, root-only lookup by name, which was enough for the Control NCA
      case but not for a BKTR-reconstructed romfs, which `hacpack`'s
      `--romfsdir` needs as a real directory tree on disk, not a raw
      blob), verified against a real reconstructed romfs's own directory
      table (`Data/Managed/{Metadata,Resources}`,
      `Data/StreamingAssets/aa/{AddressablesLink,Switch}`, etc.) matching
      what `nstool` independently extracts from the same content.

      Verified end-to-end, twice: (1) the reconstructed exefs+romfs
      directory trees were diffed (`diff -rq`, full recursive structural +
      content comparison) against `hactool --basenca`'s own reconstruction
      of the *same* real update titles — zero differences, on both
      Dicefolk (86 files) and Well Dweller (24 files, the subsection-
      splitting case); (2) the full 1G1R batch merge was re-run end-to-end
      with the wired-in code, producing output NSPs byte-for-byte
      identical (`cmp`) to the previously hardware-verified references —
      including, unexpectedly, byte-for-byte identical to the
      *`hactool`-reconstructed* merge output too, meaning `hacpack`'s NCA
      building from a directory tree is itself fully deterministic given
      the same input bytes. Then, to confirm `hactool` is TRULY unused
      (not just unused by the paths this session's testing happened to
      exercise), the vendored `bin/hactool` binary was temporarily
      replaced with a wrapper that fails loudly if invoked, and the full
      batch merge was re-run again: the wrapper never fired, and outputs
      were still byte-for-byte identical.

      **Only `hacpack` remains required** — NCA *building* (writing hash
      trees, not just reading them, for the merged Meta NCA and the
      BKTR-rebuilt standalone Program NCA) is still the one deliberately-
      untouched higher-risk tier: a subtly wrong from-scratch hash-tree
      *writer* could produce a file that installs fine but is silently
      corrupted at runtime, which is a fundamentally different risk than
      everything reimplemented so far (every prior piece either fails
      loudly on a wrong read, like a bad magic/wrong key producing garbage
      instead of valid content, or was checked byte-for-byte against a
      known-good reference before ever running unsupervised).
- [x] Reduce dependency on vendored tools, eighth (final) piece —
      **`hacpack` eliminated too — zero vendored-tool runtime dependencies
      remain.** The "higher-risk tier" reasoning above turned out to
      still be worth pursuing once actually attempted: every field and
      cryptographic step `hacpack` 1.36_r2 needs (source read directly,
      the same vendored version this project already used as read-side
      ground truth) turned out to need no primitive beyond what this
      project already had — AES-128-ECB (encrypt direction, for the key
      area), AES-128-CTR (content, the SAME primitive read or write,
      confirmed by an encrypt-then-decrypt round-trip test before relying
      on this), AES-128-XTS (encrypt direction, for the header — added
      `xts_encrypt_sector`/`nca_encrypt_header` to `lib/nca_header.sh`,
      the exact mirror of its own existing decrypt functions), and SHA256
      (not a decrypt/encrypt operation at all). New `lib/nca_build.sh`
      adds `nca_build_cnmt`/`nca_build_meta` (replacing both
      `hacpack --ncatype meta` calls, including the existing two-pass
      digest fix, now operating on this project's own output instead of
      hacpack's) and `nca_build_program` (replacing
      `hacpack --ncatype program --plaintext`), plus
      `_nca_build_content_id_from_nca` (the content-ID-from-SHA256
      filename convention every NCA on disk already uses, confirmed
      directly from hacpack's own `nca_create_meta`/`nca_create_program`:
      `hexBinaryString(nca_hash, 16, ...)`).

      Two deliberate, confirmed-safe defaults this project's own builder
      reproduces rather than reinvents (hacpack's own unset/default
      values, since `switch-merge.sh` never passed the flags that would
      change them): `--ncasig` defaults to all-zero `fixed_key_sig`/
      `npdm_key_sig` (no RSA signing at all — this project's CFW-target
      use case doesn't need real Nintendo/eShop signatures, confirmed
      against a real hacpack-built NCA in this project's own prior merged
      output: both fields were already all-zero before this change too);
      `--keyareakey` defaults to `0x04` repeated 16 times as the
      PLAINTEXT content key later wrapped into the header's key area
      (an arbitrary placeholder, not derived from `prod.keys` at all —
      only the WRAPPING uses real per-console key material, confirmed the
      same way).

      The Program NCA side needed a second, separate reimplementation:
      **`lib/romfs_build.sh`**, a full pure-bash port of hacpack's own
      `romfs_build` (romfs.c) — recursive directory-tree walk (sorted by
      plain byte comparison, `LC_ALL=C`, matching C's `strcmp` exactly,
      NOT filesystem/readdir order), a custom path-hash function
      (`calc_path_hash` — parent XOR a fixed constant, then per-byte
      32-bit rotate+XOR, verified bit-for-bit against a real file's own
      hash-table bucket assignment before trusting it further), and an
      odd-count hash-table sizing rule (`romfs_get_hash_table_count`,
      avoiding small prime factors 2/3/5/7/11/13/17 — NOT simply the
      entry count) — none of this is documented anywhere online in
      operational detail; switchbrew's wiki covers the on-disk entry
      struct layout (already used by this project's own read-side
      `lib/romfs.sh`) but not how a valid instance of that layout gets
      constructed from a directory tree in the first place. This turned
      out to be necessary the hard way: the initial plan was to skip
      rebuilding the romfs container at all and just IVFC-hash this
      project's own already-BKTR-reconstructed romfs bytes directly
      (content-correct, already verified file-for-file against
      `hactool`'s own reconstruction) — that produced a functionally
      correct but NOT byte-identical result, because `hacpack`'s own
      `romfs_build` independently re-derives the entire directory/file
      table AND file-data-partition layout from its own directory walk,
      and a real Nintendo-built romfs's on-disk file order doesn't have
      to match hacpack's own alphabetical rebuild order (confirmed by
      directly extracting hacpack's own intermediate pre-hash romfs file
      — hard-linking it out from under hacpack's own temp-directory
      cleanup before it could delete it — and finding the file-partition
      layout differed by thousands of bytes despite identical file
      content).

      Two more real, confirmed bugs found and fixed while wiring
      everything together, both caught by byte-for-byte comparison
      against real hacpack-built files, not guessed:
      - `romfs_build`'s own outer wrapper (not the inner table-building
        function) pads its ENTIRE final output to a 0x4000
        (`IVFC_HASH_BLOCK_SIZE`) boundary, and separately, the IVFC
        level-5 header field (`hash_data_size`/`logical_offset` for the
        raw romfs data itself) records the UNPADDED size from before that
        final step — captured in hacpack's own source at the exact moment
        `*out_size = ftello64(f_out)` runs, which is BEFORE the padding
        `fwrite` that follows it. Getting this backwards (using the
        padded on-disk file size for the header field, or the unpadded
        size for the actual byte count written) produces a same-size,
        differently-CONTENTED file — caught by comparing IVFC level
        headers field-by-field against a real file's own decrypted
        header, not just comparing total file sizes.
      - The literal ASCII bytes for the `"IVFC"` magic were written
        backwards in one spot (`46435649` instead of `49564643`) - a
        plain typo, caught the same way (a field-by-field header diff
        against a real file), not something a size-only check would ever
        catch.

      Also confirmed, while wiring the Program NCA path into
      `switch-merge.sh`'s real merge pipeline (not just a standalone
      test): `nstool -x`'s own on-disk file-write order for a PartitionFs
      section is the REVERSE of that section's own entry-table order —
      an `nstool`-internal quirk, not anything meaningful about the PFS0
      format itself (this project's own `_pfs0_read_entries` already
      reads the entry table's own true, forward order correctly) — but
      since every one of this project's prior verified reference outputs
      was originally built via `nstool -x` extraction feeding hacpack's
      own `--exefsdir`, matching that exact (reversed) order turned out
      to be necessary for byte-for-byte continuity with those existing
      references, confirmed by directly comparing `nstool -x`'s own raw
      directory-creation order (`ls -f`) against the reference NSP's own
      exefs entry table.

      Verified end-to-end at every level: `nca_build_meta` and
      `nca_build_cnmt` produce byte-for-byte identical output (`cmp`) to
      a real `hacpack --ncatype meta` build for the same inputs, including
      the derived content-ID filename; `romfs_build` produces a
      byte-for-byte identical (`cmp`) raw romfs container to hacpack's own
      intermediate pre-hash file (hard-linked out from its temp directory
      before cleanup); `nca_build_program` produces a byte-for-byte
      identical Program NCA to this project's own previously-verified,
      hardware-tested merge output; and the FULL 1G1R batch merge (both
      real test titles, Dicefolk base+update+DLC and Well Dweller
      base+update) was re-run end-to-end through the actual
      `switch-merge.sh` pipeline with every vendored tool's binary
      simultaneously replaced by a wrapper that fails loudly if invoked
      (`nstool`, `hactool`, AND `hacpack` all at once) — producing output
      NSPs byte-for-byte identical to the original, hardware-tested
      references, with zero invocations of any wrapper. **The project
      now depends on nothing beyond bash, `xxd`, `openssl`, and coreutils
      (`sha256sum`, `split`, `dd`, etc.) already listed in "Requirements"
      above** — `nstool`/`hacpack`/`hactool` remain vendored in `bin/`
      purely for optional manual debugging/cross-verification (their
      human-readable dumps and reference output are how every piece above
      was built and checked), not because the pipeline needs them.
- [ ] Handle DLC packs containing multiple `AddOnContent` titles in one NSP
      (only single-title DLC packs have been tested so far).
- [ ] **`smtool` (C port), Phase 1 of 9 — pure struct/container parsing,
      implemented.** The bash pipeline, while dependency-free, was measured
      to be roughly two orders of magnitude slower than the vendored C
      tools doing equivalent work (extracting a real 2.6GB XCI: 74.6s vs
      hactool's 0.77s) — dominated by per-byte hex-string parsing in bash
      and hundreds of subprocess spawns (`dd`/`xxd`/`openssl`) per merge,
      neither of which is tunable further (this project's `dd` calls
      already seek directly via `skip=`/`iflag=skip_bytes`, no wasted I/O).
      `src/smtool/` is a new C project (links `libcrypto`, same dependency
      tier the vendored tools already carry) building `bin/smtool`, a
      one-shot-subcommand tool in the same invocation style as
      `nstool`/`hacpack`/`hactool` (`bin/smtool <subcommand> <args...>`,
      spawn once, do one thing, exit). `switch-merge.sh` calls it by
      default; a new `--pure` flag routes every call back through the
      existing `lib/*.sh` bash functions instead, for whenever
      zero-compiled-dependency matters more than speed. Every call site is
      routed through a matching `op_*` bash wrapper (`op_parse_cnmt`,
      `op_pfs0_extract_all`, etc.) so both paths stay in exactly one place
      to keep in sync — never a per-call-site `if $PURE` branch scattered
      through the pipeline.

      This phase ports the read-only, no-crypto pieces: `lib/binfmt.sh`
      (cnmt/NACP/ticket parsing — `cnmt-info`, `nacp-info`, `tik-info`),
      the reader half of `lib/pfs0.sh` (`pfs0-list`, `pfs0-extract`,
      `pfs0-extract-all`), and `lib/hfs0.sh` (`hfs0-data-off`, `hfs0-list`,
      `hfs0-extract-all`). Every subcommand's multi-field output uses a
      `KEY=VALUE`-per-line contract, named identically to the bash
      globals it replaces (e.g. `CNMT_TITLE_ID=...`), read back via a new
      shared `read_kv_into_vars` bash helper — deliberately NOT built via
      `while read ... done < <(smtool ...)`, since a process substitution
      isn't a pipeline and `$?`/`PIPESTATUS` after it don't reflect the
      substituted command's real exit status (confirmed directly: a
      subcommand returning 3 left the wrapper itself silently exiting 0)
      — the same *shape* of subshell-exit-status gotcha `lib/bktr.sh`'s
      own `_bktr_parse_bucket0_subsections` comment already documents
      hitting and fixing the same way (capture via a plain command
      substitution first, iterate over the captured text second).

      Every data-copying subcommand (`pfs0-extract-all`, `hfs0-extract-all`)
      streams with a fixed 1MB buffer via `fseeko`/`fread`/`fwrite` —
      NEVER loads a whole container into memory — since this project's own
      base-game NSPs and XCI secure partitions routinely run 1-15GB+; an
      earlier version of this code naively `malloc`'d and read the entire
      input file up front, which worked but wasted memory for no benefit
      (this was caught and fixed before landing, while measuring that this
      phase's actual speedup on real XCI classification was smaller than
      hoped — see below).

      **Honest finding on the speedup this phase actually delivers**:
      profiling a real end-to-end merge (both a plain NSP and an XCI)
      showed classification-step wall-clock time barely changes between
      the compiled and `--pure` paths for a REAL file, because the
      dominant cost there is disk I/O copying a multi-GB secure partition
      to a scratch directory, not the small cnmt/NACP/PFS0/HFS0 field
      parses this phase actually sped up — both the bash `dd`-based copy
      and this phase's own C streaming copy are similarly I/O-bound. The
      original 74.6s-vs-0.77s measurement that motivated this whole
      effort compared this project's FULL pipeline (including crypto and
      NCA-building, none of which this phase touches) against hactool's
      own C implementation of the same full operation — not an
      apples-to-apples measurement of this phase's actual, narrower
      scope. The real, large wins are expected from later phases (NCA
      header/content crypto, replacing hundreds of `openssl` subprocess
      spawns with in-process AES) — this phase's value is establishing
      the subcommand contract, the `op_*`/`--pure` dispatch pattern, and
      the `tests/` fixture-harness pattern those later phases will reuse,
      not raw speed on its own.

      New `tests/` directory: `tests/fixtures/` holds small (bytes to
      16KB) real and hand-constructed files — real cnmt/NACP/ticket/PFS0
      data extracted from a real NSP this session, a real HFS0 header
      region sliced out of a real XCI, and two deliberately-constructed
      edge cases: a synthetic Patch/AddOnContent cnmt pair (no real update
      NSP was available to source one from) built byte-by-byte from the
      documented `PackagedContentMetaHeader`/`PackagedContentInfo` layout
      — catching two real fixture-construction bugs along the way (a
      missing 1-byte reserved field between `ContentMetaType` and
      `ExtendedHeaderSize` that shifted every following field, and a
      missing 0x20-byte hash prefix before each content entry's own
      `ContentId`) by cross-checking against `lib/binfmt.sh`'s own parser
      until both agreed — and a NACP whose AmericanEnglish (slot 0) name
      is deliberately left empty with the real name only in slot 1,
      exercising the exact already-hard-won fallback-scan bug
      `lib/binfmt.sh`'s `parse_nacp` comment documents hitting for a real
      title ("Talisman"). `tests/run.sh` runs both the bash function and
      the matching `smtool` subcommand over every fixture and diffs the
      output — no real `prod.keys` or large title files needed, since this
      phase touches no crypto. Verified end-to-end, not just per-fixture:
      a full real 1G1R merge (both a plain NSP and a two-title XCI) was
      re-run once through the compiled path and once through `--pure`,
      and the resulting output NSPs were confirmed byte-for-byte identical
      (`cmp`) to each other.

      **Not yet ported** at the time this entry was written (see the
      Phase 3-5 entries directly below for what landed next): NCA
      content-key derivation, RomFs/BKTR readers, streaming AES-CTR
      content decryption, RomFs writer, NCA builder (Meta then Program).
- [ ] **`smtool` (C port), Phase 2 of 9 — NCA header AES-XTS decrypt,
      implemented.** New `src/smtool/crypto.c`/`.h` wraps libcrypto's EVP
      API for raw AES-128-ECB (single/multi-block, no padding) — the one
      block-cipher primitive AES-XTS/key-unwrap/AES-CTR are all built
      from, same layering `lib/nca_header.sh`'s `aes_ecb_hex` uses (just
      calling libcrypto in-process instead of shelling out to the
      `openssl` CLI). New `src/smtool/nca_header.c` ports the AES-XTS
      header decryption itself — Nintendo's non-standard big-endian
      per-sector tweak seed and the standard GF(2^128) tweak-doubling
      between blocks within a sector — plus two subcommands:
      `nca-header-decrypt <nca> --keys <keys> -o <out>` (decrypts the
      full 0xC00-byte header to a file — unlike the bash version's
      per-field `nca_header_field`, this decrypts everything ONCE per
      NCA; later phases needing more header fields read the decrypted
      buffer directly in C rather than spawning another subcommand per
      field) and `nca-rights-id <nca> --keys <keys>` (the one field read
      directly by name in `switch-merge.sh` itself this phase, via a new
      `op_nca_rights_id` wrapper covering all three of its call sites).

      Verified against real files at every level: `nca-header-decrypt`'s
      output matches `lib/nca_header.sh`'s own per-field decrypt
      byte-for-byte on a real titlekey-crypto Program NCA (including
      confirming the "NCA3" magic lands at the documented offset 0x200 —
      i.e. sector 1, not sector 0 — inside the decrypted output);
      `nca-rights-id` matches both the bash function AND `nstool -t nca
      -v`'s own "RightsId:" dump exactly on that same file, and correctly
      returns empty on a real standard-crypto Control NCA (confirmed
      `nstool` shows no RightsId line at all for that file, i.e. it's
      genuinely absent, not zero-and-hidden). A full real 1G1R merge
      (titlekey-crypto NSP, standard-crypto XCI) was re-run through both
      the compiled and `--pure` paths and produced byte-for-byte
      identical (`cmp`) output either way. `tests/run.sh` gained
      `nca-rights-id` fixture tests using just the 3072-byte encrypted
      header region of two real NCAs (titlekey-crypto and standard-crypto)
      — these specifically exercise RightsId at header offset 0x230,
      inside SECTOR 1, where the big-endian-vs-little-endian tweak
      distinction actually matters (sector 0's tweak seed is all-zero
      either way, so a sector-0-only test couldn't have caught a wrong-
      endianness regression at all) — skipped automatically if no real
      `~/.switch/prod.keys` is present on the machine running the tests
      (can't be committed, console-specific).
- [ ] **`smtool` (C port), Phase 3 of 9 — NCA content-key derivation,
      implemented.** New subcommands in `src/smtool/nca_content.c`:
      `nca-crypto-type` (the effective master-key generation index),
      `nca-content-key-standard` (unwraps the header's own embedded
      key-area slot 2 via `key_area_key_<family>_<gen>`), 
      `nca-content-key-titlekey` (unwraps a raw ticket-encrypted titlekey
      via `titlekek_<gen>`), and `nca-section-info` (per-section present/
      offset/size/crypt-type/initial-AES-CTR-counter, including Nintendo's
      non-standard `SectionCTR`-byte-reversed-plus-shifted-offset
      construction). All four call the shared `nca_decrypt_header` from
      Phase 2 once per invocation rather than re-deriving `header_key`
      or re-decrypting per field. Verified against real files at every
      level: `nca-content-key-standard` matches `lib/nca_content.sh`'s
      own derivation on a real Control NCA; `nca-content-key-titlekey`
      matches both the bash function AND `nstool`'s own "AES-CTR Key"
      dump exactly on a real titlekey-crypto Program NCA (confirmed with
      a genuinely nonzero `SectionCTR`, exercising the byte-reversal
      logic for real, not as a zero-coincidence); `nca-section-info`'s
      offset/size match `nstool -t nca -v`'s own reported partition
      offset/size exactly. Wired into `switch-merge.sh` via four new
      `op_*` wrappers covering all call sites (including the BKTR-
      reconstruction path's titlekey-crypto key derivation). A full real
      1G1R merge (titlekey-crypto NSP, standard-crypto XCI) still
      produces byte-for-byte identical output via the compiled and
      `--pure` paths.
- [ ] **`smtool` (C port), Phase 4 of 9 — RomFs reader + BKTR bucket-tree
      reader, implemented.** New `src/smtool/romfs.c` ports
      `lib/romfs.sh`'s flat (`romfs-extract`) and full-recursive
      (`romfs-extract-all`) RomFs readers. New `src/smtool/bktr.c` ports
      the bucket-tree PARSING half of `lib/bktr.sh` (`bktr-headers`,
      `bktr-relocations`, `bktr-subsections`) — full BKTR
      reconstruction itself (`bktr_reconstruct`, which needs streaming
      AES-CTR decryption of update content) stays bash-only until a
      future phase, since no real update/BKTR sample file was available
      to verify a C port of the reconstruction LOOP against, only the
      table-parsing pieces (which don't need one — see below).

      Verified: `romfs-extract`/`romfs-extract-all` match
      `lib/romfs.sh`'s own output byte-for-byte on a real Control NCA's
      RomFs data (checked into `tests/fixtures/control.romfs`).
      `bktr-relocations`/`bktr-subsections` are verified against
      HAND-CONSTRUCTED 2-bucket synthetic fixtures
      (`tests/fixtures/bktr_reloc_2bucket.bin`/`bktr_subsec_2bucket.bin`)
      specifically because this project already found and fixed a real
      bug here once (an earlier wrong 0x4014/0x4010 "stride + overflow
      entry" guess that read past the end of a real 29-bucket table —
      the actual stride is a fixed 0x4000 bytes) — a single-bucket-only
      test could not have caught a stride regression at all, since a
      second bucket's start offset only matters once there IS one.
      `bktr-headers` is verified against a hand-constructed decrypted-
      header fixture with a real BKTR superblock at section 1 (and
      deliberately none at section 0, confirming the bad-magic failure
      path fires correctly too). A full real 1G1R merge (neither sample
      exercises BKTR reconstruction itself, only the Control-NCA RomFs
      read path) still produces byte-for-byte identical output via the
      compiled and `--pure` paths.
- [ ] **`smtool` (C port), Phase 5 of 9 — streaming AES-CTR content
      decryption, implemented. This is the phase that delivers the real
      speedup.** New `src/smtool/nca_decrypt.c`: `decrypt-section`
      (streams AES-128-CTR decryption via libcrypto's EVP streaming API
      with a fixed 1MB buffer, never loading a whole section into
      memory — the direct in-process replacement for shelling out to
      `openssl enc -aes-128-ctr` per section) and
      `nca-hierarchical-sha256-layer`/`nca-hierarchical-integrity-layer`
      (the two data-layer offset resolvers, operating on an
      already-decrypted header file per Phase 2's "decrypt once" design).

      Verified against real files: `decrypt-section`'s output is
      byte-for-byte identical (`cmp`) to `lib/nca_content.sh`'s own
      `nca_ctr_decrypt_section` on a real Control NCA's full 909KB romfs
      section; both layer-resolvers match the bash functions' output
      exactly (including a full round-trip: derive key → decrypt section
      → resolve layer offset → extract cnmt → parse, entirely through
      `smtool` subcommands, producing a cnmt byte-for-byte identical to
      one independently verified earlier this session). A full real
      1G1R merge (titlekey-crypto NSP, standard-crypto XCI) produced
      byte-for-byte identical output via the compiled and `--pure`
      paths — and, unlike every earlier phase, **the wall-clock time
      difference is now real and large**: 10.5s (compiled) vs 43.3s
      (`--pure`) for the same XCI merge, roughly a 4x speedup, confirming
      the honest caveat from Phase 1's own entry above (the big win was
      always expected here, not in the small struct-parsing phases).
- [ ] **`smtool` (C port), Phase 6 of 9 — RomFs writer, implemented.**
      New `src/smtool/romfs_build.c` ports `lib/romfs_build.sh` (itself a
      port of hacpack's own `romfs_build`) — full directory-tree walk,
      the same TWO different sort orderings the bash version draws
      (global "next" order for entry-offset/file-partition-offset/hash-
      table assignment, separate per-parent "sibling" order for the
      actual child/file/sibling linked-list structure), the custom
      `calc_path_hash` function, and `romfs_get_hash_table_count`'s
      odd-bucket-count-avoiding-small-primes sizing rule. **Not wired
      into `switch-merge.sh`** this phase — `romfs_build` is only ever
      called from `lib/nca_build.sh`'s `nca_build_program`, which isn't
      itself ported until Phase 8; wiring `op_romfs_build` in now would
      mean `lib/nca_build.sh` calling a wrapper that only exists in
      `switch-merge.sh`'s own scope for one sub-step of a bash function
      that isn't ported yet. `romfs-build` exists and is fully verified
      standalone now so Phase 8 can call it in-process directly (no
      subprocess spawn at all at that point, not even the one this
      phase's own subcommand still needs).

      **Real bug found and fixed during verification, unrelated to the
      C port**: testing bash's own `romfs_build` against a real
      directory tree initially produced `printf: : invalid number`
      errors and a corrupted, non-round-trippable output — traced to
      `romfs_build`'s own `sed "s|^$in_dir||"` prefix-stripping breaking
      when `in_dir` is passed WITH a trailing slash (an undocumented
      input constraint: every real call site in this project, via
      `nca_build_program`, always passes a `mktemp -d` path with no
      trailing slash, so this never surfaces in the actual pipeline —
      only in ad-hoc manual testing during this phase's own
      verification). Confirmed by re-testing without the trailing slash:
      bash's output then matched `smtool romfs-build`'s own output
      byte-for-byte exactly.

      Verified two ways against a real directory tree (a real Control
      NCA's extracted icons + `control.nacp`, checked into
      `tests/fixtures/control_romfs_dir/`): (1) byte-for-byte identical
      build output (`cmp`) against `lib/romfs_build.sh`'s own bash
      implementation; (2) round-tripped the C-built container back
      through Phase 4's already-verified `romfs-extract-all` and
      `diff -r`'d against the original directory — this catches
      structural bugs a byte-diff against a possibly-also-wrong bash
      build might not, since it validates against an independently-
      verified reader instead. This round-trip test is what caught a
      real bug in the C port itself before it ever shipped: an initial
      version wrote `DirHashTableOffset`/`DirHashTableSize` at the
      `DirTableOffset`/`DirTableSize` header field positions (a
      copy-paste offset mixup), which produced a same-size but
      structurally wrong container that failed to round-trip at all
      until corrected against `lib/romfs.sh`'s own documented field list.
- [ ] **`smtool` (C port), Phase 7 of 9 — NCA builder: Meta NCA,
      implemented.** New `src/smtool/nca_build.c` ports `lib/nca_build.sh`'s
      cnmt-writing and Meta-NCA-assembly half: `build-cnmt` (writes a
      `PackagedContentMeta` file — header, `Application`/`AddOnContent`
      extended-header shape, one content record per Program/Data/
      Control/LegalInformation NCA given, trailing digest left as a
      zero placeholder) and `build-meta-nca` (full assembly: cnmt →
      PFS0-pack via Phase 1's now-extended `pfs0-pack` writer →
      per-4096-byte-block SHA256 hash table → FS header → main header →
      AES-XTS header encryption via Phase 2's `nca_encrypt_header` (the
      new encrypt-direction mirror of that phase's decrypt) → AES-CTR
      content encryption of section 0, using the same primitive Phase
      5's `decrypt-section` already uses (CTR is its own inverse)).
      `pfs0.c` also gained the writer half (`pfs0-pack`) this phase,
      previously deferred from Phase 1 since only the NCA-building
      phases need it.

      **Two real bugs found and fixed during verification, both caught
      by byte-diffing against real files, not guessed**: (1) the
      content-record buffer wasn't zero-initialized, leaving one
      reserved byte (between the Size and ContentType fields) as
      uninitialized stack garbage that corrupted every content record
      after the first non-empty one — caught immediately by a `cmp`
      mismatch against `lib/nca_build.sh`'s own output on a real title's
      three real content NCAs (Program/Control/LegalInformation);
      (2) confirmed (not a bug, but initially looked like one) that a
      single-pass build correctly produces an all-zero digest — verified
      by extracting BOTH the bash and C single-pass builds with `nstool`
      and confirming they agree exactly (all-zero), before moving on to
      test the real two-pass flow.

      Verified end-to-end against a real title's real Program/Control/
      LegalInformation NCAs: `build-cnmt`'s output is byte-for-byte
      identical (`cmp`) to `lib/nca_build.sh`'s own `nca_build_cnmt`;
      `build-meta-nca`'s two-pass flow (build once for a draft cnmt,
      compute the real digest, rebuild with `--digest`) produces a Meta
      NCA byte-for-byte identical to bash's own two-pass
      `nca_build_meta` output; and, going one step further than a bash-
      vs-C comparison alone, the built NCA was independently opened with
      `nstool` (real ground truth, not just self-consistency between two
      implementations of the same project) — confirmed correct
      `ContentType: Meta`/`ProgID`/key-area decryption, and its embedded
      cnmt was extracted and confirmed to have a genuinely correct,
      self-verifying SHA256 digest over its own preceding bytes.

- [ ] **`smtool` (C port), Phase 8 of 9 — NCA builder: Program NCA,
      implemented, AND cutover wired.** New `build-program-nca`
      subcommand in `src/smtool/nca_build.c` completes the NCA-building
      half: exefs (PFS0 pack with `main.npdm`'s ACID sig/key zeroed,
      0x10000-byte hash blocks) + romfs (Phase 6's `romfs_build_impl`
      called IN-PROCESS, no subprocess spawn at all — refactored
      `romfs-build`'s own CLI entry point into a thin wrapper around
      this shared implementation specifically so this phase could call
      it directly) + 5 recursive IVFC hash levels + full header
      assembly. This phase, together with Phase 7, is what Phase 6's
      entry deferred wiring for — both builders now exist, so
      `op_nca_build_meta`/`op_nca_build_program` wrappers were added to
      `switch-merge.sh` this same phase, replacing the last two bash
      NCA-building call sites (`nca_build_meta`'s draft+final two-pass
      calls, and the BKTR-reconstruction branch's `nca_build_program`
      call).

      **Verified end-to-end on the very first real test, byte-for-byte,
      no fixup needed**: extracted a real title's actual exefs (6 files,
      ~59MB total, including a real `main.npdm`) and romfs from its real
      Program NCA (using this project's own already-verified
      `decrypt-section`/`nca-section-info`/`pfs0-extract-all`/
      `romfs-extract-all`), built a Program NCA from that real content
      via both `build-program-nca` and `lib/nca_build.sh`'s own
      `nca_build_program`, and `cmp`'d them — identical. Went one level
      further than a bash-vs-C comparison again: extracted the BUILT
      NCA with `nstool` and diffed every one of its 6 exefs files plus
      its romfs directory structure against the ORIGINAL pre-build
      content — 5 of 6 files matched byte-for-byte exactly, and
      `main.npdm` differed in EXACTLY the deliberately-zeroed 512-byte
      ACID signature/key region (bytes 128-639), confirmed to be
      genuinely all-zero there and nowhere else. This is real
      independent confirmation the built NCA is not just self-
      consistent with this project's own two implementations of itself,
      but genuinely correct, readable content by a real external tool.

      **This phase's own bug-avoidance win**: because Phase 6 (RomFs
      writer) had already landed and been fully verified standalone,
      this phase could call its logic in-process via a small refactor
      (`romfs_build_impl`, with `cmd_romfs_build` reduced to a thin CLI
      wrapper around it) rather than needing its own from-scratch romfs-
      building code or a fork/subprocess round-trip to get the
      UNPADDED-size return value this phase's IVFC header needs exactly
      right (a value this project's own README already documents as a
      real, confirmed bug-source if mixed up with the padded on-disk
      size) — the phased approach paid off directly here, not just as a
      general engineering principle.

      Full real 1G1R merges — a plain titlekey-crypto NSP, a single-
      title XCI, AND a two-title XCI (three separate titles, one of
      which required no BKTR reconstruction and one which used the
      default titlekey/ticket-carry path) — all produced byte-for-byte
      identical output via the compiled and `--pure` paths, and matched
      output captured from every earlier phase this session going back
      to Phase 2 (zero drift across the whole port so far). **Total
      measured speedup with the full builder pipeline compiled: 3.9s vs
      43.0s for the same real XCI merge, ~11x** — up from Phase 5's 4x,
      confirming the Meta-NCA-building path (hash-table construction,
      two-pass digest rebuild) was itself a meaningful further cost the
      earlier phases hadn't yet touched.
- [x] XCI input — implemented: `.xci` (gamecard dump) files are now a valid
      input alongside `.nsp`, auto-detected by extension the same
      zero-flag way everything else is. New `lib/hfs0.sh` reads HFS0
      (HashedFs), the hashed sibling of PFS0 that XCI partitions use - same
      flat header/entry-table/string-table/file-data shape `lib/pfs0.sh`
      already reads, just a bigger 0x40-byte entry (adds a
      partial-file-hash field PFS0 doesn't have) - derived from
      switchbrew's own documented XCI/HFS0 struct layout and verified
      field-by-field against `hactool -t xci -i`'s own dump of several real
      XCI files before trusting it. `switch-merge.sh` gained
      `xci_split_to_nsps`, which locates the XCI's **secure** partition
      (the one holding actual title content - the sibling **update**
      partition is a SYSTEM firmware bundle unrelated to any per-title
      update, and **normal**/**logo** are icon/branding assets, so none of
      those three are read) and repacks it into one synthetic in-memory
      `.nsp` per title found there, via the existing `pfs0_pack`. Every
      other function (`classify_nsp`, `extract_nsp`, the whole merge
      pipeline) needed zero changes - a synthetic NSP is byte-for-byte the
      same shape as a real one from that point on.

      The one XCI-specific wrinkle: a single cartridge's secure partition
      can hold **more than one independent title's NCAs side by side**,
      flattened together with no other file-level grouping - confirmed
      against a real dump, which turned out to hold two separate
      `Application`-type titles under two different title IDs (not a
      base+update pair for one game). `xci_split_to_nsps` can't assume
      "one secure partition = one title" the way a real NSP always is, so
      it finds every `*.cnmt.nca` in the extracted secure partition first,
      parses each one's own cnmt (`parse_cnmt`, already used everywhere
      else in this project) to learn exactly which sibling
      Program/Control/LegalInformation/Data NCA(s) belong to THAT title,
      and packs one synthetic NSP per Meta NCA containing just those files
      - so a multi-title cartridge still classifies and groups correctly
      into separate 1G1R output NSPs, rather than one title's content
      silently going unused or a wrong grouping being produced.

      Verified end-to-end against three real XCI dumps: a single-title
      cartridge (4 files, 1 cnmt) produced one correctly-classified,
      correctly-named output NSP; a two-title cartridge (8 files, 2 cnmts
      under different title IDs) produced two separate correctly-split
      output NSPs, each `nstool --fstree`-valid (4 files: Program, Control,
      LegalInformation, rebuilt Meta) with its own cnmt confirmed via
      `nstool -t cnmt -v` to have the right `TitleId`/`Type`/content list
      and no cross-contamination between the two titles' files; and mixing
      one `.xci` input with a real `.nsp` input in the same batch run
      produced both titles correctly in one 1G1R pass. No real XCI with a
      titlekey-crypto (`RightsId`-bearing) NCA has been seen - a physical
      cartridge has no eShop ticket to carry, and every sample checked
      confirms this (no `.tik`/`.cert` anywhere on the card) - so
      `xci_split_to_nsps` doesn't attempt ticket handling; a titlekey-crypto
      NCA on a card would fail downstream the same way a malformed NSP
      would, not be silently mishandled.

      **Note**: this is XCI *input* only. XCI *output* remains explicitly
      not implemented - see the entry directly below for why.
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
