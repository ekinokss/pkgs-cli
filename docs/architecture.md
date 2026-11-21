# Architecture

`pkgs` is a set of PowerShell scripts loaded lazily by the profile. It has no
build step, no daemon, no scheduled task and no persistent background process.

## Loading model

```text
PowerShell profile
  └─ function pkgs                (lazy wrapper, integration/profile-snippet.ps1)
       └─ pkgs.ps1                (parsed on first call, cached in $script:PkgsScript)
            ├─ pkgs-core.ps1      paths, config, process capture, tool discovery
            ├─ pkgs-snapshot.ps1  mpm adapters, msstore adapter, snapshot cache
            ├─ pkgs-model.ps1     capabilities, protection, presentation, plans
            ├─ pkgs-ui.ps1        fzf UI, preview, layout, confirmations
            └─ pkgs-help.ps1      help and howto text
```

The profile wrapper prepends `$PkgsHome` and `$InShell = $true`, so
`pkgs.ps1` knows both its installation directory and that it must return
`$LASTEXITCODE` rather than terminate the host process. `install.ps1` and the
profile-less `pkgs.cmd` run `pkgs.ps1` directly with `pwsh -NoProfile -File`.

## Files

| File | Responsibility |
|---|---|
| `pkgs.ps1` | Argument parser, dispatch, JSON envelope, doctor, version |
| `pkgs-core.ps1` | Config load/save, cache paths, native process capture, tool lookup, output helpers, exit codes |
| `pkgs-snapshot.ps1` | `mpm` inventory parsing, manager adapters, msstore adapter, native pins, snapshot cache |
| `pkgs-model.ps1` | Capability matrix, target resolution, protection, presentation, plans and execution |
| `pkgs-ui.ps1` | Home/updates/installed/search/protected/managers/help screens, preview files, layout, confirmations |
| `pkgs-help.ps1` | Usage, per-command help and `howto` topics |
| `preview.cmd` | Fault-tolerant preview renderer (`bat`, then `type`) |

## Inventory flow

```text
Get-PkgsSnapshot
  ├─ cache hit (snapshot.json, TTL from config)  -> deserialize
  └─ cache miss / --refresh
       ├─ mpm --table-format json installed
       ├─ mpm --table-format json outdated
       ├─ mpm --table-format txt managers
       ├─ winget list --source msstore           (msstore adapter)
       ├─ native pin/hold reads                  (winget/scoop/choco)
       └─ write snapshot.json atomically
```

The snapshot schema is `pkgs/snapshot/v2`. It stores canonical records keyed by
`manager:id`, manager capability/observation rows, native pins, backend errors
and anomalies, and cache age. Duplicate raw rows collapse into one record with
`instances` counting the source rows.

pip interpreters are explicit global environments from the configuration.
`mpm`'s own pip adapter and environment-relative `uv` manager are excluded.

## Presentation flow

`Get-PkgsDecoratedPackages` turns each raw record into one presentation object:

- `type` from `Get-PkgsPackageType` (manager semantics, never name guessing);
- `display_name` from the backend, a verified VS Code `package.json`, or the
  canonical ID, with `name_source` recording which;
- installed/available display values that distinguish unknown and not available;
- `update_state` from `Get-PkgsPackageState`, using capability plus evidence;
- protection from `Get-PkgsProtection`, evaluated against native pins, local
  ignores, guard exceptions and guard patterns;
- `operations` (`install`, `upgrade`, `remove`) from the capability matrix;
- `target` = canonical `manager:id`, the only execution identity.

The same presentation object feeds the UI, tables and JSON, so the CLI and UI
cannot disagree about state.

## UI flow

```text
pkgs
  └─ Invoke-PkgsUi
       ├─ Available Updates   -> list -> actions -> plan -> confirm -> execute
       ├─ Installed Packages  -> all / by manager / by type
       ├─ Search & Install    -> backend search -> plan -> confirm -> execute
       ├─ Protected / Ignored -> reasons and unprotect instructions
       ├─ Managers & Health   -> compact capability table + backend errors
       ├─ Refresh Data        -> explicit cache rebuild
       └─ Help                -> keys and commands
```

Lists are rendered by `Select-PkgsRows`. Each row is:

```text
<ANSI display columns> TAB <manager> TAB <id> TAB <preview key> TAB <target>
```

fzf displays field 1 only (`--with-nth 1`) and returns the whole line, so the
selection is resolved back to the exact canonical target. Unknown identities are
warned about and ignored; they are never executed.

### Preview

- `New-PkgsPreviewFiles` writes one detail file per visible row, once per
  session.
- The filename is the first 16 hex characters of SHA-1 over the lower-cased
  `manager:id`; it is stable and independent of row order.
- The session directory is `%LOCALAPPDATA%\pkgs\cache\preview-<pid>-<guid>`.
- fzf expands `{r4}` (raw field 4). A backslash before a placeholder escapes it,
  which was the Phase 2 defect; `Get-PkgsPreviewCommand` never emits `\{4}`.
- `preview.cmd` checks for the file, prints a friendly fallback when it is gone,
  and never throws a raw backend error into the pane.
- `Clear-PkgsPreviewCache` removes the session on exit. Stale sessions are
  removed when their owner PID no longer exists or they are older than an hour.

No file is created per keypress; fzf starts one small preview process per
selection change.

## Mutations

`New-PkgsPlan` resolves every target against a live snapshot, re-evaluates
protection, and produces entries with the exact native command. `Invoke-PkgsPlan`
executes entries one at a time and records each exit code. Immediately before
each entry it re-reads native pins, configuration, the live inventory and (for
upgrades) the outdated list; a changed version, missing target or newly added
protection blocks that entry. Unreadable native protection state is a hard
block. After a backend reports success, the live inventory is read again to
verify the expected version or removal. A failed verification is a failure with
exit code 5; partial success is never reported as complete success. `rustup` and
`micro` do not report installed versions; for those managers verification
confirms presence and records that limitation instead of claiming a version
transition.

WinGet writes are executed directly with `--exact --source winget` because
`mpm` 8.3.0 renders an upgrade as an unqualified `winget install --id`. Other
managers use `mpm --<manager> <operation> <exact-id>`.

The UI never mutates while browsing. It shows the plan, then requires:

- `yes` for unprotected operations;
- typed `OVERRIDE` and `CONFIRM` for protected overrides;
- `[y/N]` before adding local ignore entries.

## Failure model

- Errors are routed to stderr in JSON mode; stdout remains a single JSON
  document.
- `Stop-Pkgs` raises `PKGS_EXIT:<code>:<message>`; the entry point converts it
  to the documented exit code (or `$LASTEXITCODE` in shell mode).
- Backend stderr is captured and surfaced with the failing manager and target.
- A malformed inventory document is a hard error, not an empty inventory.
- `--strict` turns backend/manager observations into a non-zero exit.
