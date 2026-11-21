# Draft upstream issue: mpm Scoop adapter uses formatted `scoop list` names

**Status: draft only — not published or submitted.**

## Summary

The mpm Scoop adapter obtains package identities by running:

```text
scoop.CMD list
```

and parsing the human-formatted table's `Name` column as the package `id`. When
PowerShell truncates that cell, mpm emits the truncated text as a JSON package
ID instead of the actual installed Scoop app directory name.

## Observed behavior

`pkgs` copies mpm's JSON `id` verbatim. In a synthetic boundary test, the
following Scoop-style table row:

```text
meta-package-.       8.3.0         main         2026-11-14 14:13:51
```

fed through mpm's real Scoop adapter produced:

```json
{"id":"meta-package-.","name":null,"installed_version":"8.3.0"}
```

mpm debug output confirmed that the adapter invoked the synthetic `scoop.CMD`
and parsed the `Name` cell. No actual Scoop package or mpm installation was
modified.

The exact string `meta-package-.` is also reproducible with PowerShell table
formatting:

```powershell
scoop list | Out-String -Width 14
```

which renders the 20-character name `meta-package-manager` as
`meta-package-.`.

## Why this matters

- JSON ids must not depend on terminal/table width.
- A truncated id is not a canonical package identity and can break inventory,
  target resolution and protection matching.
- The historical live trigger that produced this in the field was not captured;
  this is not a claim of a confirmed historical corruption incident.

## Recommended fix

Use a machine-readable Scoop inventory, such as Scoop's JSON export or a direct
inspection of the installed app metadata, instead of parsing the formatted
`list` table. Alternatively, reject or repair values that cannot be
corroborated against an installed app directory.

A defensive mpm check could verify each parsed `Name` against the direct child
directories under the user/global Scoop apps roots before emitting it as `id`.

## Minimal reproduction

Create a synthetic `scoop.CMD` that emits a valid Scoop list header and a row
whose `Name` cell is `meta-package-.` with a Version cell, place it first on
`PATH`, and run:

```text
mpm --scoop --table-format json installed
```

The resulting JSON package id is the truncated Name. A normal real Scoop
invocation in this environment returned the full `meta-package-manager` name;
the historical trigger remains unknown.
