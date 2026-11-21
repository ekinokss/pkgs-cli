# Protection model

`pkgs` has three protection layers plus a hard native layer. Protection changes
are persistent state changes and always require explicit confirmation.

## Layers

| Layer | Source | Stored in | Hard block? | Normal override |
|---|---|---|---|---|
| Native pin/hold | WinGet pin, Scoop hold, Chocolatey pin | Managed by the package manager | **Yes** | Remove it with `pkgs pin --remove manager:id`, then act |
| Local ignore | User or UI (`pkgs ignore`) | `config.json` → `ignored` | No | `--override-protection` + `--yes`, or typed `OVERRIDE` + `CONFIRM` |
| Developer-toolchain guard | Default patterns (`config.json` → `guard`) | `config.json` | No | Same as local ignore |
| Guard exception | Exemption for one target | `config.json` → `guardExceptions` | Removes guard protection | `pkgs unprotect manager:id` |

`pkgs` protection is evaluated in this order: native pin, local ignore, guard.
The summary joins every reason, for example
`Protected (pin, toolchain guard) - Update available`.

## Native pins

| Manager | Native mechanism | Read | Add | Remove |
|---|---|---|---|---|
| `winget` | `winget pin add/remove --id` | `winget pin list` | yes (blocking) | yes |
| `scoop` | `scoop hold/unhold` (`current\scoop-install.json`, legacy `install.json`) | metadata scan | yes | yes |
| `choco` | `choco pin add/remove -n=` | `choco pin list` | yes (via `gsudo` when available) | yes |
| others | none | - | local pin via `ignored` (`kind = pin`) | local removal |

Native pins are re-read live before a mutation plan is built
(`Get-PkgsLiveNativePins`) and again immediately before execution. They cannot
be bypassed with `--override-protection`; the plan marks the entry blocked and
reports the exact target. This is intentional: bypassing a pin requires removing
the pin itself.

For Scoop `upgrade` and `remove`, pkgs also corroborates the final canonical ID
against an exact direct child directory under the effective user or global Scoop
apps roots. Missing, unreadable, ambiguous, prefix-only or punctuation-lookalike
evidence blocks the plan with exit 5 before any backend call. Effective roots
follow Scoop's precedence (`SCOOP`/config `root_path`/portable/default and
`SCOOP_GLOBAL`/config `global_path`/ProgramData); configuration or root failures
fail closed. Ordinary and portable configuration candidates are classified as
absent/file/directory/unreadable/unknown, and malformed or non-object JSON is
refused without fallback. This is an identity-safety refusal, not a native-pin
claim; normal Scoop `current` layouts are not modified.

A missing or malformed Scoop installation metadata file is a `pin-read` hard block: the protection state is unknown, so pkgs refuses mutation. A native command that exits 0 is accepted only after the pin/hold state is re-read and matches the requested action.

`pkgs pin` creates a **blocking** WinGet pin (`winget pin add --blocking`), so a
pin cannot be overridden by an external `winget upgrade --id` either. The pin
command also uses `--exact --source winget`, so it cannot attach to a
substring-matched package from another source.

### WinGet execution is direct and exact

`mpm` 8.3.0 renders a WinGet upgrade as:

```text
winget install --id <id> --accept-package-agreements --accept-source-agreements --disable-interactivity --no-progress
```

It omits `--exact`, `--source`, and `--version`. WinGet's `--id` filter uses
substring matching unless `--exact` is present, and `install` is not the same
operation as `upgrade`. `pkgs` therefore executes WinGet writes itself:

```text
winget upgrade   --id <id> --exact --source winget --accept-package-agreements ...
winget install   --id <id> --exact --source winget [--version <v>] --accept-package-agreements ...
winget uninstall --id <id> --exact --source winget ...
```

No `--all`, `--force`, `--include-pinned`, `--purge` (except Scoop's documented
`--purge` preview), or unqualified query is ever added. Other managers still use
`mpm` with a single exact ID and the `--<manager>` selector.

Before a WinGet mutation, `pkgs` also reads `winget list --id <id> --exact`
without `--source` (which hides the `Source` column) and without `--scope`.
It requires exactly one exact-ID record whose source is `winget` and whose
version is readable. Duplicate, wrong-source and unreported-source records are
refused. Install scope is not reported by WinGet and is not claimed. A malformed
or empty `winget pin list` is a hard `protection unknown` block.

Adding a WinGet pin requires exactly one installed exact-ID record from source
`winget` with a readable version. After `winget pin add --blocking`, readback
must show exactly one pin with type `Blocking` and source `winget`; a
`Pinning`/`Gating` type, another source, a missing type, or duplicate records is
a failure. An existing ordinary/gating/wrong-source pin is never replaced or
removed automatically. Pin removal verifies that the exact `winget`-source pin
exists before deleting it and leaves same-ID pins from other sources untouched;
an orphaned `winget` pin can still be removed. `pkgs pin --list` and
`pkgs show --json` expose the pin type and source.

A default (unversioned) install must finish at the planned available version.
The plan's available version is rechecked immediately before execution; a
changed repository version refuses the stale plan. After execution, direct
WinGet evidence must agree with mpm's refreshed inventory.

With `--json`, native pin command output is captured and written to stderr so
stdout remains a single valid JSON envelope. User-scope WinGet uninstalls are
refused by WinGet in an administrator context; run live WinGet removal tests
from a medium-integrity, non-interactive shell.

## Default guard

The default configuration guards development toolchains:

- WinGet: Go, LLVM, Rustup, Node.js, Python, Python Launcher, Temurin JDKs,
  .NET SDKs, Visual Studio Build Tools, Miniconda, Miniforge, Platform Tools.
- Scoop: corretto JDKs, flutter, gcc, nodejs, python, rustup.
- rustup: every toolchain (`.*`).

These are conservative defaults. Adjust them deliberately with
`pkgs config`/the JSON file; they are not a security boundary against the user.

## Commands

```powershell
pkgs pin --list                     # native + local
pkgs pin scoop:7zip                 # native hold where supported
pkgs pin --remove scoop:7zip
pkgs ignore scoop:7zip --reason "keep 26.05"
pkgs ignore --remove scoop:7zip
pkgs unprotect scoop:7zip           # removes local ignore + guard exception
```

`pkgs unprotect` is not a general "ignore all protection" switch. It removes the
local ignore entry and any guard exception for that exact target. Native pins
must be removed with `pkgs pin --remove`.

## Mutation rules

`New-PkgsPlan` and `Invoke-PkgsPlan` enforce:

1. **Exact identity.** Each target resolves to one `manager:id`. A bare ID is
   accepted only when exactly one installed record matches. Ambiguity is refused
   with exit 4; a target is never guessed.
2. **No implicit "all".** `pkgs upgrade` with no targets opens interactive
   selection only on a TTY. There is no upgrade-all command and no fallback to
   the whole inventory.
3. **Live recheck.** Protection is recomputed from live native pins and the
   current config before the plan is shown and again immediately before
   execution. Target identity and the planned versions are also re-checked, so a
   stale plan is refused instead of executed.
4. **No bypass flags.** There is no `--force`. `--override-protection` only
   overrides pkgs-local layers, and only with a second confirmation. In `--json`
   mode that typed confirmation cannot be obtained, so a JSON override is
   refused (exit 6) for locally protected targets instead of being bypassed.
5. **Non-interactive intent.** Off a TTY, mutations and protection changes
   require `--yes`. `--json` mutations always require `--yes`, even on a TTY,
   and never prompt; `--yes` does not override native pins or confirm protection
   overrides by itself.
6. **Preview is inert.** Browsing, filtering, previewing and cancelling never
   write package state or config. `--dry-run` live-verifies the target but never
   mutates.
7. **Configuration writes are explicit.** `pkgs ignore`, `pkgs unprotect` and
   local pins list the exact targets and require `[y/N]` (or `--yes` off a TTY).
   The UI requires `[y/N]` before the Protect action.
8. **Accurate results.** Each manager invocation's exit code is recorded. After
   a zero exit code, live inventory and (for WinGet) the direct exact-ID/source
   identity are read to verify the expected version or removal. Any failure or
   missing change makes the command exit non-zero. A partial success is printed
   as incomplete, never as complete success.
9. **No unrelated changes.** The plan contains only the resolved targets; the
   backend is invoked one target at a time with an exact ID. Installing an
   already-installed target is refused.

## Interactive confirmations

| Action | Confirmation |
|---|---|
| Upgrade/uninstall unprotected selection | Plan, then `yes` |
| Upgrade/uninstall protected selection | Plan, typed `OVERRIDE`, typed `CONFIRM` |
| Protect selected (add local ignore) | Target list, then `[y/N]` |
| Native pin/unpin | Plan, then typed `PIN` (or `--yes` non-interactively) |
| Local pin/unpin | Exact target, then typed `PIN` (or `--yes`) |
| `pkgs ignore` add/remove | Exact targets and `[y/N]` on a TTY; `--yes` off a TTY |
| `pkgs unprotect` | Exact targets and `[y/N]` on a TTY; `--yes` off a TTY |
| Search & install | Plan, then `yes` |
| Cancel / Esc / `n` | No change |

The Phase 2 incident (Enter on the action menu's first item silently added
ignores for `gcloud:bq` and `gcloud:core`) is covered by a regression test: the
Protect action must list targets, require `[y/N]`, and leave the config
unchanged when cancelled.

## Live mutation qualification status

Write paths are implemented and covered by deterministic tests only.
**Live install/upgrade/remove/native-pin acceptance is NOT TESTED.** Do not
describe mutation support as qualified until the approved live sequence in the
Phase 3 report has actually run and been recorded.

The deterministic suite covers exact identity, refusal without confirmation,
native-pin blocks, guard/ignore overrides, stale-plan refusal, direct WinGet
execution, install refusal, post-execution verification and the Phase 2 Protect
regression.
