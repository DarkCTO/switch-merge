---
name: switch-merge
description: Merge Nintendo Switch base game + update + DLC NSPs into single installable NSP(s), one per title (1G1R). Use when the user asks to merge/combine Switch game files, build an installable NSP from base+update+DLC, or troubleshoot a switch-merge.sh run (BKTR/hactool errors, digest errors, titlekey errors, wrong output name/version).
argument-hint: [extra switch-merge.sh flags, e.g. -o <dir> or specific files/dirs]
allowed-tools: Bash(*/switch-merge.sh *) Bash(find *) Bash(ls *) Bash(nstool *)
---

Run `${CLAUDE_PROJECT_DIR}/switch-merge.sh $ARGUMENTS` — the script at the
project root (not inside `.claude/`).

With no arguments, it auto-scans the project root for `.nsp` files, groups
them by title, and writes merged output to `merged/` next to the script —
so just running the skill with no arguments is the common case.

## What it does

Classifies every input NSP by its own cnmt content-meta type
(`Application`/`Patch`/`AddOnContent`) — not filename — groups them by base
title ID, and merges each group (base + optional update + any DLC) into one
installable NSP: `<Name> [<TitleId>][<DisplayVersion>][<DLC count>].nsp`.
Handles multiple different games in one run (1G1R: one game, one ROM per
title). One group failing doesn't stop the others; a summary at the end
reports per-title success/failure.

## After running

Report the batch summary (succeeded/failed per title) plainly. For any
failed title, read the group's own log lines above the summary (prefixed
`==> [<title_id>] ...`) before speculating about the cause.

## Troubleshooting known failure modes

If a group fails, check the error against these **before** proposing new
theories — full technical detail and the story behind each is in
`README.md`'s "The debugging story" section at the project root:

- **"The titlekey for this Rights ID could not be found"** on later
  install (not from the script itself) — a titlekey-crypto NCA got
  packed without its ticket. Already handled for base-only/standalone
  Program NCAs; if it resurfaces, check whether a new code path is
  copying NCAs without also copying `.tik`/`.cert`.
- **"Game updates cannot be loaded directly. Load the base game
  instead."** on install — either a zero cnmt digest (shouldn't happen,
  the script always builds the Meta NCA twice to set a real one) or an
  update whose Program NCA is BKTR-delta-encoded and wasn't reconstructed
  against the base. Check the group's log for whether the "reconstructing
  full romfs/exefs against base" line appears when the input has an update.
- **"Invalid BKTR layout!" or a group with an update silently produces no
  romfs content** — a real upstream `hactool` bug (not this script). The
  vendored `bin/hactool` already carries a fix
  (`bin/patches/hactool-1.4.0-bktr-layout-fix.patch`). If this error still
  appears, check `command -v hactool` resolves to the project's
  `bin/hactool` and not a system install — the script prepends `bin/` to
  `PATH` automatically, but a caller-supplied `PATH` override could shadow
  it.
- **Wrong/missing output filename, or `[0]` DLC count when DLC was
  given** — the merged Control NCA's NACP couldn't be read for
  `Name`/`DisplayVersion`. The script falls back to the raw
  `<titleid>.nsp` name and prints a warning; check that warning rather
  than assuming the merge itself failed.
- **"No base (Application) NSP found"**, **"Multiple base/update NSPs
  found"** — classification/grouping issue, not a merge bug. Check the
  actual file(s) with `nstool -t cnmt -v` on their Meta NCA if the
  automatic classification looks wrong.

If an error doesn't match any of these, do real investigation (inspect the
actual NCA/cnmt with the vendored `bin/nstool`, don't guess) before editing
`switch-merge.sh` — see `CLAUDE.md` at the project root for the established
investigation approach and prior findings.

## Requirements

`~/.switch/prod.keys` must exist. Nothing else — `nstool`/`hacpack`/
`hactool` are vendored in the project's `bin/` and used automatically.
