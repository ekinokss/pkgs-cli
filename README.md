# pkgs

**A safety-first Windows package manager CLI for people and AI agents.**

**Current source version: 1.2.3 (pkgs/v1).** This maintenance version hardens detection of Meta Package Manager backend versions and rejects unverifiable version probes. No new installer-family qualification is claimed.

`pkgs` combines package inventory, discovery, update planning and explicitly authorized operations across supported managers through [Meta Package Manager (`mpm`)](https://github.com/kdeldycke/meta-package-manager). Use the interactive terminal interface when working yourself, or the `pkgs/v1` JSON API for scripting and coding agents.

- **One inventory:** canonical `manager:id` identities, manager capabilities, searchable installed and outdated packages
- **Read-only by default:** no surprise upgrades and no `upgrade-all` mutation
- **Plan before mutation:** `--dry-run` resolves and checks the exact target without changing it
- **Protection:** native pins/holds, local ignores and a developer-toolchain guard
- **Verified outcomes:** independent backend/inventory checks, structured errors and deterministic exit codes
- **No resident software:** no background service, tray process or scheduled task

`pkgs` does **not** bundle `mpm` or the underlying package managers. The external `mpm` project is licensed under GPL-2.0-or-later; it is installed and executed separately, and is **not** covered by the MIT license for `pkgs`.

## Requirements

| Dependency | Requirement |
|---|---|
| Windows | Windows 10/11 with PowerShell **7.4+** (`pwsh`) |
| Meta Package Manager | `mpm` **8.3.0** (external dependency) |
| Package managers | Install whichever supported managers you intend to use |
| Optional interactive UI | `fzf`; `bat` provides richer previews |
| Optional elevation helper | `gsudo` for particular manager workflows |

Install `mpm` following the [official installation guide](https://mpm.run/install/). For example, if you already use Scoop:

```powershell
scoop install main/meta-package-manager
```

Avoid maintaining multiple independent `mpm` installations on the same machine.

## Install

Clone the public repository:

```powershell
git clone https://github.com/ekinokss/pkgs-cli.git pkgs
cd pkgs

# Preview the deployment without changing files:
pwsh -NoProfile -File .\install.ps1 -WhatIf

# Deploy under your PowerShell profile library:
pwsh -NoProfile -File .\install.ps1
```

The installer copies the application scripts to `%USERPROFILE%\Documents\PowerShell\lib\pkgs` and writes a profile-less `%USERPROFILE%\bin\pkgs.cmd` launcher. It does not install an external package manager, modify PATH, or overwrite unrelated files.

Choose either integration method:

- Use `pwsh -NoProfile -File "$HOME\Documents\PowerShell\lib\pkgs\pkgs.ps1" version` directly; or
- Add `%USERPROFILE%\bin` to your existing PATH (if needed), or run the installer with `-ConfigureProfile` to add the lazy `pkgs` function to your PowerShell profile.

```powershell
pwsh -NoProfile -File .\install.ps1 -ConfigureProfile

# Preview and verify:
pkgs version
pkgs doctor --json
```

To install to a different directory, pass `-Target` and optionally `-LauncherPath`. Inspect `install.ps1 -WhatIf` before changing destinations.

## Use it

```powershell
pkgs                            # Interactive home screen
pkgs outdated                   # Human-readable update list
pkgs managers --json            # Supported manager capabilities
pkgs installed --json           # Structured installed inventory
pkgs search 7zip --json         # Catalog search
pkgs show scoop:7zip --json     # Exact manager-qualified package
pkgs doctor --json              # Diagnostic checks
```

Each mutation must identify a target precisely, such as `scoop:7zip`, `winget:Microsoft.PowerToys`, or `npm:@opencode/cli`. Display names are not used as execution identities. A bare package ID is only accepted when unambiguous.

### Safe install / upgrade / removal

```powershell
# Illustrative example, not a physical qualification claim:
pkgs install winget:Microsoft.PowerToys --dry-run --json

# Only after reviewing the plan and authorizing the operation:
pkgs install winget:Microsoft.PowerToys --yes --json

# Other workflows:
pkgs upgrade winget:Microsoft.PowerToys --dry-run --json
pkgs remove winget:Microsoft.PowerToys --dry-run --json
```

Use `pkgs pin`, `pkgs ignore` and `pkgs unprotect` to manage protections. Protected operations fail closed. A pin or ignore is **not** an invitation for an agent to override it.

## For AI agents and scripts

Use non-interactive `--json` mode, parse the `pkgs/v1` envelope, check the **process exit code** and inspect the planned target. Do not infer success from a backend's exit status alone. For a mutation, obtain explicit user authorization, dry-run the exact package, then execute with `--yes --json`. On a blocked, ambiguous, unsuccessful or unverified result, stop rather than trying another installer automatically.

| Exit code | Meaning |
|---:|---|
| `0` | Success |
| `1` | General error |
| `2` | Usage error |
| `3` | Confirmation required |
| `4` | Target missing or ambiguous |
| `5` | Backend, execution or verification failure |
| `6` | Protected target / native pin or hold |
| `130` | Interrupted |

JSON mutations do not prompt, require `--yes`, and cannot bypass local protection using `--override-protection`. See [JSON contract](docs/json-api.md) and [protection model](docs/protection.md) for detailed semantics.

No dedicated MCP server is included; agents can use `pkgs` through ordinary terminal tools.

## Physical qualification and limits

The previous deployed `pkgs 1.2.2` passed narrowly scoped Windows lifecycle testing for:

- **Scoop:** a separate live installation, protection, upgrade and removal lifecycle
- **WinGet portable:** Glow
- **WinGet Inno Setup EXE:** WinMerge, per-user
- **WinGet WiX MSI:** PuTTY, machine-scope with user-approved UAC
- **WinGet MSIX:** Microsoft.WinAppCli, per-user x64

These results **do not** demonstrate generic compatibility with all packages or installers. Other MSIX packages and bundles, Microsoft Store entitlement flows, provisioned/all-user installations, alternate Windows environments and unattended elevation remain unqualified. A successful test in one installer family is not a universal guarantee.

## Development

```powershell
# Uses fake backends; no real package-manager mutation:
pwsh -NoProfile -File .\tests\run-tests.ps1 -SkipIntegration
# Expected: 147 PASS, 0 FAIL, 2 expected profile-dependent skips
```

Read the [development guide](docs/development.md), [manager behavior](docs/managers.md), [architecture](docs/architecture.md) and [security policy](SECURITY.md).

## Contributing and license

Contributions and bug reports are welcome; please follow [CONTRIBUTING.md](CONTRIBUTING.md). The `pkgs` source is offered under the [MIT License](LICENSE). External tools and packages retain their own licenses, including `mpm` ([GPL-2.0-or-later](https://github.com/kdeldycke/meta-package-manager/blob/main/license)).
