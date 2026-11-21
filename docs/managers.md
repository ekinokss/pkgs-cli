# Manager capability matrix

Capabilities come from `Get-PkgsCapability` in `pkgs-model.ps1`. The matrix is
deliberately conservative: a manager not in the verified list is read-only, even
if a backend happens to accept a command.

Legend: `yes` = supported; `-` = not supported; `native` = the manager has its
own pin/hold mechanism.

| Manager | Installed | Outdated | Search | Install | Upgrade | Remove | Pin | Elevation |
|---|---|---|---|---|---|---|---|---|
| `winget` | yes | yes | yes | yes | yes | yes | native | UAC |
| `msstore` | yes | yes | yes | yes | yes | yes | - | - |
| `scoop` | yes | yes | yes | yes | yes | yes | native | - |
| `choco` | yes | yes | yes | yes | yes | yes | native | `gsudo` |
| `npm` | yes | yes | yes | yes | yes | yes | - | - |
| `pnpm` | yes | yes | yes | yes | yes | yes | - | - |
| `yarn` | yes | yes | yes | yes | yes | yes | - | - |
| `yarn-berry` | yes | yes | yes | yes | yes | yes | - | - |
| `bun` | yes | yes | yes | yes | yes | yes | - | - |
| `uvx` | yes | yes | - | yes | yes | yes | - | - |
| `pipx` | yes | yes | - | yes | yes | yes | - | - |
| `cargo` | yes | - | yes | yes | - | yes | - | - |
| `rustup` | yes | yes | - | yes | yes | yes | - | - |
| `dotnet` | yes | - | yes | yes | - | yes | - | - |
| `pwsh-gallery` | yes | yes | yes | yes | yes | yes | - | - |
| `vscode` | yes | - | - | yes | - | yes | - | - |
| `gh-ext` | yes | - | yes | yes | - | yes | - | - |
| `gcloud` | yes | yes | - | yes | - | yes | - | - |
| `micro` | yes | - | yes | yes | - | yes | - | - |
| `claude-code-plugins` | yes | - | - | yes | - | yes | - | - |
| `antigravity-cli-plugins` | yes | fallback* | fallback* | - | - | - | - | - |
| `pip*` | yes | on demand | - | - | - | - | - | - |
| `uv` | excluded | - | - | - | - | - | - | - |
| pip adapter | excluded | - | - | - | - | - | - | - |

\* Also under the fallback: the manager gets a read-only capability with
`unverified = true`. `Outdated` is taken from the backend listing, but no write
operation is offered.


## Semantics by manager

### WinGet
`mpm` drives WinGet inventory, but `pkgs` executes WinGet mutations directly.
`mpm` 8.3.0 renders an upgrade as `winget install --id <id>` without
`--exact`/`--source`/`--version`; WinGet's ID filter uses substring matching
unless `--exact` is present. `pkgs` therefore uses:

```text
winget upgrade   --id <id> --exact --source winget ...
winget install   --id <id> --exact --source winget [--version <v>] ...
winget uninstall --id <id> --exact --source winget ...
```

Native `winget pin` is a hard block. `pkgs pin` creates a blocking pin
(`--blocking`) with `--exact --source winget`. The `msstore` adapter exists
because `mpm` 8.3.0 does not expose Store packages; it uses
`winget --source msstore` and qualifies IDs with `msstore:`.

Before and after a WinGet mutation, `pkgs` reads `winget list --id <id> --exact`
without `--source` and requires exactly one exact-ID record with source
`winget` and a readable version. WinGet does not report the installed scope, and
its `--scope` filter was observed to match packages from both scopes, so scope is
neither forwarded nor claimed. Portable packages install per-user by design.

A blocking WinGet pin is only accepted after readback shows exactly one pin with
type `Blocking` and source `winget`; ordinary/gating/wrong-source pins are never
replaced automatically. Pin creation requires the installed exact identity, and
pin removal requires ownership of the exact `winget`-source pin. Default installs
must match the planned available version, and direct WinGet evidence must agree
with mpm's refreshed inventory after execution.

### Scoop
User-scope installs are the normal case. `scoop hold` is stored in
`apps\<app>\current\scoop-install.json` for Scoop 0.6.0 installs, with
`install.json` supported for legacy installs. Both files are read; the new file
is preferred when both exist. Missing or malformed metadata is reported as an
unreadable protection state and blocks mutation, not as unheld. Global apps may
require `-g`; `pkgs` does not add it silently.

`app@version` installs are pinned by Scoop/mpm and are skipped by ordinary
`outdated`/`upgrade`. They are not a valid upgrade fixture.

### Chocolatey
`mpm` escalates with `gsudo`. A UAC prompt is expected. `choco pin` is a hard
block. Do not run Chocolatey qualification while another install is pending.

### npm / pnpm / yarn / bun
Global packages only. Project-local `node_modules` and lockfiles are never
scanned or modified. `Outdated` refers to the global prefix.

### uv / uvx / pipx
`uvx` and `pipx` list isolated tools. `uv` itself is excluded because `mpm`'s
uv manager resolves the current environment, which could be a project directory.
pip environments are explicit global interpreters from configuration and are
read-only by policy.

### Cargo / .NET tools
Both have install and remove, but no per-binary outdated listing or upgrade
command in `mpm`. They are reported as `No update check`, not `Current`.

### rustup
Toolchains are covered by the default guard pattern `.*`. Upgrades are possible
only after an explicit protection override.

### PowerShell Gallery
Outdated and upgrade use `Update-PSResource`/PSResourceGet. Module provenance and
repository configuration can affect the result; treat failures as failures.

### VS Code
`vscode` is an extension manager, not the VS Code application. The extension
manager is identified as `vscode`; WinGet may separately report
`Microsoft.VisualStudioCode` as an application. Display names are read from
`~/.vscode/extensions/<id>-<version>/package.json`, and a localized
`%displayName%` placeholder falls back to the canonical ID. There is no backend
outdated listing; extensions are shown as `No update check`.

### micro / gh-ext / gcloud
No per-package outdated/upgrade through the backend. `gcloud` can update all
components at once, which `pkgs` deliberately does not do; those rows are
`Manual update` and are excluded from upgrade plans.

### Microsoft Store
The adapter uses `winget list --source msstore` and `winget search --source
msstore`. Store IDs are opaque (for example `9NFD76MCDRJZ`). Live Store
install/upgrade/remove is **NOT TESTED**.

## Inventory adapters

- Canonical identity is always `manager:id`; display names never select a target.
- Duplicate raw rows for the same manager and ID collapse into one record with
  `instances > 1`; `duplicate_source_rows` counts the extras.
- malformed versions and failed-install markers are normalized; scoop's
  `Updated` date or `Install`/`failed` text is not treated as a version.
- pip rows are hidden by default and their outdated check is opt-in.
- `uv` is present in manager inventory but excluded from packages.

## Adding a manager

1. Verify the backend's real CLI syntax for installed/outdated/search/install/
   upgrade/remove and pin semantics.
2. Add a capability entry only for operations verified against the backend.
3. Add an inventory adapter in `pkgs-snapshot.ps1` if `mpm` does not expose it.
4. Add a package type in `Get-PkgsPackageType`.
5. Add fixtures and deterministic tests, including identity and unsupported
   operation cases.
6. Update this matrix and `docs/protection.md` if pin behavior changes.
