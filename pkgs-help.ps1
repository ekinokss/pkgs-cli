# =====================================================================
#  pkgs-help.ps1 - help and practical howto text
# =====================================================================

function Get-PkgsUsage {
    return @'
pkgs - unified, read-only-by-default Windows package manager CLI

USAGE
  pkgs                                  Home screen (Available Updates first)
  pkgs ui [--outdated-only] [-m MANAGER]   Direct updates or manager-filtered inventory
  pkgs outdated [QUERY] [-m MANAGER] [--json] [--with-pip] [--protected] [--refresh]
  pkgs installed [QUERY] [-m MANAGER] [--json] [--duplicates] [--refresh]
  pkgs managers [--json] [--refresh]
  pkgs search QUERY [-m MANAGER] [--json] [--exact] [--limit N]
  pkgs upgrade [TARGET...] [--dry-run] [--yes] [--override-protection] [--refresh] [--json]
  pkgs install TARGET... [--pkg-version V] [--dry-run] [--yes] [--json]
  pkgs remove TARGET... [--dry-run] [--yes] [--json]
  pkgs pin [TARGET...] [--list] [--remove] [--dry-run] [--yes] [--reason TEXT] [--json]
  pkgs ignore [TARGET...] [--list] [--remove] [--reason TEXT] [--yes] [--json]
  pkgs unprotect TARGET... [--yes] [--json]
  pkgs show TARGET [--json]
  pkgs doctor [--json]
  pkgs howto [TOPIC]
  pkgs config [show|path|validate]
  pkgs refresh [--with-pip]
  pkgs clean
  pkgs version | help [COMMAND]

TARGETS
  manager:id             scoop:7zip, winget:Google.PlatformTools, npm:@opencode/cli
  pkg:manager/id         purl form, e.g. pkg:winget/Google.PlatformTools
  id                     only when exactly one installed package matches

  Package identity is always manager + backend ID, never a display name.

OPTIONS
  -m, --manager NAME     Restrict to one manager (repeatable with commas)
  --json                 Stable pkgs/v1 JSON on stdout (supported inventory and mutation commands)
  --dry-run              Live-verify targets, then print exactly what would run
                         Exit 0 = ready, 6 = protection block, 5 = invalid/unsupported
  --yes                  Non-interactive confirmation intent (required off a TTY
                         and always required with --json)
  --override-protection  Deliberate second gate for pkgs-protected targets
                         (interactive typed gate; not honored with --json)
  --refresh              Ignore the snapshot cache
  --with-pip             Include pip outdated checks (slow, on demand)
  --pkg-version V        Version specifier for install (single target)
  --strict               Treat backend/manager errors as a non-zero exit

EXIT CODES
  0 ok   1 error   2 usage   3 confirmation required   4 target not found/ambiguous
  5 backend failure   6 protected / native pin   130 interrupted

SAFETY
  Read-only by default. There is no upgrade-all command. Native pins and holds
  are never bypassed. Protected packages are excluded from normal selection and
  need a separately confirmed override. uv is excluded because mpm's uv manager
  is environment-relative; pip is read-only.

Run `pkgs howto` for workflows, `pkgs howto json` for automation, and
`shortcuts` for the cheat sheet.
'@
}

function Show-PkgsHelp {
    Write-Host (Get-PkgsUsage)
}

function Get-PkgsCommandHelp {
    param([string]$Command)
    switch ($Command) {
        'ui' {
            return @'
pkgs                         Open the Package Management home screen
pkgs ui [--outdated-only] [-m MANAGER] [--with-pip]

Home screen: Available Updates (listed first), Installed Packages,
Search & Install, Protected / Ignored Packages, Package Managers & Health,
Refresh Data, Help / Keyboard Shortcuts, Quit.

Keys: Enter opens; Esc goes back/clears; Tab multi-selects; Ctrl-/ toggles the
details preview; Alt-Up/Down scrolls it; typing filters the current list.
`pkgs ui --outdated-only` opens updates directly.
`pkgs ui -m vscode` opens the manager-filtered installed list directly.
'@
        }
        'outdated' {
            return @'
pkgs outdated [QUERY] [-m MANAGER] [--json] [--with-pip] [--protected] [--refresh] [--strict]

Lists packages the backend reports as outdated. Protected packages remain
visible but are marked and excluded from normal upgrade selection.
QUERY matches manager:id, id or name (case-insensitive substring).

pip environments are listed as installed inventory, but their outdated check is
opt-in with --with-pip (or a pip manager filter) because it hits the network and
is slow. pip rows are hidden from the default outdated view even when a cached
check exists; --with-pip shows them.
'@
        }
        'installed' {
            return @'
pkgs installed [QUERY] [-m MANAGER] [--json] [--duplicates] [--refresh]

Lists installed packages with current and (when known) available versions. pip
inventory is included for the explicitly configured interpreters.
--duplicates shows identities installed by more than one manager, or duplicate
rows reported by one backend; pip adapters are excluded unless --with-pip or a
pip manager filter is used.
'@
        }
        'managers' {
            return @'
pkgs managers [--json] [--refresh]

Shows the manager/capability matrix: detection, version, package counts,
read operations (i=installed, o=outdated, s=search), write operations,
pin mechanism and backend notes. Excluded managers explain why.
'@
        }
        'search' {
            return @'
pkgs search QUERY [-m MANAGER] [--json] [--exact] [--limit N]

Live search through every capable backend. Results are not installed state;
use `pkgs install manager:id` to act on one.
'@
        }
        'upgrade' {
            return @'
pkgs upgrade TARGET... [--dry-run] [--yes] [--override-protection] [--refresh] [--json]
pkgs upgrade                      (interactive selection on a terminal)

Never upgrades everything. Every target is re-checked against the manager's own
outdated listing before the plan is shown, and again immediately before
execution. A target that is not outdated, or whose version changed, is refused.
Protected targets need --override-protection and --yes. With --json, --yes is
always required and --override-protection is refused instead of bypassing local
protection.
Native pins/holds cannot be overridden here: `pkgs pin --remove` first.

WinGet mutations are executed directly with an exact ID and source
(`winget upgrade --id <id> --exact --source winget`), not through mpm's
`winget install` rendering. The live version is verified after the backend
reports success; a zero exit code alone is not accepted as success.
'@
        }
        'install' {
            return @'
pkgs install TARGET... [--pkg-version V] [--dry-run] [--yes] [--json]

TARGET must be manager-qualified unless the ID resolves to exactly one manager.
The package is resolved through the backend search, the exact ID and version are
shown, and the native command is previewed before anything runs.

An already-installed target is refused. Use `pkgs upgrade manager:id` to update
it or `pkgs remove manager:id` first; install never silently replaces or
upgrades an existing package.

Scoop `--pkg-version` installs are version-pinned by Scoop; normal `outdated`
and `upgrade` skip them. Do not use them as an upgrade fixture.

With --json, --yes is always required and no prompt is shown.
'@
        }
        'remove' {
            return @'
pkgs remove TARGET... [--dry-run] [--yes] [--json]

Removes only the named manager:id. Native behaviour is preserved (for example
Scoop removals may include --purge, which the plan displays explicitly).
With --json, --yes is always required and no prompt is shown.
'@
        }
        'pin' {
            return @'
pkgs pin TARGET... [--dry-run] [--yes] [--reason TEXT] [--json]
pkgs pin --list [--json]
pkgs pin --remove TARGET... [--yes] [--json]

Uses the native mechanism when one exists:
  winget  winget pin add/remove --exact --source winget
          pkgs creates a blocking pin (--blocking) so other tools cannot
          silently upgrade it either
  scoop   scoop hold/unhold (scoop-install.json, legacy install.json)
  choco   choco pin add/remove (through gsudo)
Other managers store a local pin in the pkgs configuration.

Every pin/unpin lists the exact target and requires typed PIN on a TTY, or
--yes off a TTY. Local pins use the same confirmation. With --json, --yes is
always required and no prompt is shown.
'@
        }
        'ignore' {
            return @'
pkgs ignore TARGET... [--reason TEXT] [--yes] [--json]
pkgs ignore --list [--json]
pkgs ignore --remove TARGET... [--yes] [--json]
pkgs unprotect TARGET... [--yes] [--json]

Local protection list. `unprotect` also records a guard exception so the
built-in toolchain guard stops matching that exact manager:id.

Protection changes are persistent: on a TTY the exact targets are listed and a
[y/N] answer is required; off a TTY, --yes is required. Cancelling writes
nothing. With --json, --yes is always required and no prompt is shown.
'@
        }
        'doctor' {
            return @'
pkgs doctor [--json]

Checks the backend, optional UI tools, configuration, cache, manager errors and
known backend limitations. Exit 1 when a check fails.
'@
        }
        'howto' {
            return 'pkgs howto [overview|protection|automation|managers|keys|json|inventory|troubleshoot]'
        }
        default { return (Get-PkgsUsage) }
    }
}

function Show-PkgsHowTo {
    param([string]$Topic = 'overview')

    switch ($Topic.ToLowerInvariant()) {
        'overview' {
            Write-Host @'
PKGS - PRACTICAL HOWTO

1. Open the home screen
     pkgs

   Package Management
     Available Updates (listed first)
     Installed Packages
     Search & Install
     Protected / Ignored Packages
     Package Managers & Health
     Refresh Data
     Help / Keyboard Shortcuts
     Quit

   Enter opens the selected item. Esc goes back or quits. Type to filter.

2. Read the columns
     Package | Type | Installed | Available | Manager | Status

   Package is a verified name when metadata exists; otherwise the canonical
   package ID is shown. The Manager column is the manager ID (winget, scoop,
   vscode, gcloud, ...). Details always show the full canonical manager:id.

   Status meanings:
     Update available          backend reports a newer version
     Manual update             update exists but this backend cannot upgrade it
     Current                   backend checked and found no newer version
     No update check           manager has no outdated listing
     Check not run             on-demand check (pip) has not run
     Version unknown           backend did not report an installed version
     Broken install            incomplete install reported by the backend
     Protected (guard/pin/hold) - ...   protection plus update state

3. Browse installed packages
     Installed Packages -> All packages
     Installed Packages -> By package manager... -> vscode
     Installed Packages -> By package type... -> VS Code Ext

   A VS Code extension is not the VS Code application: the Type column and
   Manager column are deliberately separate.

4. Inspect before acting
     Enter on a row opens actions; Show details shows:
       canonical ID, manager, type, scope, installed/available versions,
       update evidence, protection reason, supported operations, commands.
     Ctrl-/ toggles the preview. Alt-Up/Alt-Down scrolls it.
     Tab multi-selects; protected rows are never silently upgraded.

5. Change one exact package
     pkgs upgrade scoop:7zip
     pkgs install winget:7zip.7zip --dry-run
     pkgs install winget:7zip.7zip
     pkgs remove scoop:7zip

   Off a terminal, add --yes and keep the explicit manager:id. There is no
   upgrade-all command, by design.

6. Protect a package you want to keep old
     pkgs ignore winget:GoLang.Go --reason "project needs Go 1.22"
     pkgs pin winget:GoLang.Go            blocking native pin where supported
     pkgs ignore --list
     pkgs unprotect winget:GoLang.Go      remove local protection + guard exception

   Protection changes list the exact targets and ask [y/N]; off a terminal,
   add --yes.

7. Automation
     pkgs outdated --json
     pkgs installed --manager scoop --json
     pkgs managers --json
     pkgs upgrade scoop:7zip --dry-run --json

Topics: pkgs howto protection | automation | managers | keys | json | inventory | troubleshoot
'@
        }
        'protection' {
            Write-Host @'
PROTECTION AND PINS

Protection has three layers, evaluated per manager + package ID:

  native pin   winget pin, scoop hold, choco pin
               Hard block. pkgs never bypasses it. Remove it deliberately:
               pkgs pin --remove winget:GoLang.Go

  ignore       pkgs configuration entry (`pkgs ignore`)
               Excluded from normal selection. Requires a separately
               confirmed override for one operation.

  guard        built-in dev-toolchain patterns (Node, Python, Rust, Java,
               Android tools, Go, LLVM, .NET SDK/Build Tools, compilers)
               Same override rule as ignore. `pkgs unprotect` adds an exact
               exception so you can update one package without weakening the
               pattern.

Interactive override: select the package, choose Upgrade, observe the block,
then type OVERRIDE to rebuild and CONFIRM to apply.
Non-interactive override: --override-protection plus --yes plus the exact target.
Dry runs never mutate, always show the block, and live-verify the target.

Native pins are checked live before every mutation, not only from the snapshot.
Scoop 0.6.0 writes scoop-install.json; legacy install.json is also read. A
missing or malformed Scoop hold file is "protection unknown" and blocks the
mutation instead of assuming the package is unprotected.
Protection and the exact installed/available versions are re-checked again
immediately before execution; a plan that has gone stale is refused. After the
backend reports success, pkgs reads the live inventory and verifies the expected
version or removal. A zero exit code without the expected change is a failure.
Native pin/unpin success is verified by re-reading the hold/pin; an unreadable
readback is a failure.
'@
        }
        'automation' {
            Write-Host @'
AGENT AND SCRIPT WORKFLOW

Prefer read-only discovery first:
  pkgs managers --json
  pkgs installed --json
  pkgs outdated --json
  pkgs show winget:Some.Package --json

Then preview a mutation:
  pkgs upgrade scoop:7zip --dry-run --json

The dry run re-reads live state and prints the exact command; it never mutates.
After execution, JSON results carry `verified`, `verification`, `backend_exit`
and `exit`. A zero backend exit without the expected version change is exit 5.

Then, only with explicit authorization and an exact target:
  pkgs upgrade scoop:7zip --yes

Rules:
  - Never omit the target and expect an upgrade-all: it is refused.
  - Use manager:id; bare IDs are accepted only when unique.
  - Non-interactive mutations require --yes. --dry-run never needs it.
  - Exit 3 means confirmation was missing; 4 target identity; 5 backend;
    6 protected/native pin.
  - JSON is stable under schema "pkgs/v1"; warnings stay off stdout.

Useful:
  pkgs outdated --manager winget --json
  pkgs installed --duplicates --json
  pkgs doctor --json
'@
        }
        'managers' {
            Write-Host @'
MANAGER NOTES

mpm (Meta Package Manager) is the backend for inventory and mutations:
  winget, scoop, choco, npm, pnpm, yarn, bun, uvx, pipx, cargo, rustup,
  dotnet, pwsh-gallery, vscode, gh-ext, gcloud, micro, claude-code-plugins,
  antigravity-cli-plugins (when installed).

Two explicit adapters fill gaps in mpm 8.3.0:
  msstore   Microsoft Store packages via winget (mpm omits them)
  pipNNN    read-only pip inventory for explicitly configured global Python
            environments; outdated is opt-in with --with-pip

Deliberately excluded:
  uv        mpm's uv manager acts on whatever environment uv resolves in the
            current directory, which can be a project .venv. Project-local
            environments are never scanned or updated.

Capability notes:
  - cargo, dotnet, vscode, gh-ext, micro: no backend outdated listing, so
    upgrade is intentionally unsupported; install/remove remain available.
  - gcloud updates all components at once; per-package upgrade is unsupported.
  - pwsh-gallery upgrade uses Update-PSResource (PSResourceGet).
  - choco mutations are escalated by mpm through gsudo.
  - winget runs unelevated; installers may raise their own UAC prompt.

Print the live matrix with: pkgs managers
'@
        }
        'keys' {
            Write-Host @'
INTERACTIVE KEYS

  Home screen
    Up / Down       move between workflows
    Enter           open the selected workflow
    Esc             quit
    type            filter the menu

  Package lists
    Enter           open the action menu (never mutates by itself)
    Tab             select / deselect rows (multi-select)
    Ctrl-/          show or hide the details preview
    Alt-Up/Down     scroll the preview
    Esc             clear the filter or go back
    type            fuzzy-filter by package, type, manager or status

  Action menu
    Upgrade         verifies, shows the exact plan and asks for confirmation
    Uninstall       shows the native command, including --purge warnings
    Show details    canonical ID, type, versions, protection, operations
    Protect         lists targets and asks y/N, then adds local ignore entries
    Override        separate typed OVERRIDE and CONFIRM gates for protected rows
    Back            returns without changing anything

  Status is always words, never an unexplained symbol. Protection reasons are
  shown as Protected (pin), Protected (guard), Protected (hold) or Protected
  (ignore). Nothing is selected for upgrade automatically, and nothing runs in
  the background.
'@
        }
        'json' {
            Write-Host @'
JSON INTERFACE (schema pkgs/v1)

Envelope:
  schema, command, generated, cached, cache_age_seconds,
  mpm { version, path }, managers[], packages[], errors[], warnings[]

Package (pkgs/v1; additive fields are stable):
  manager, manager_name, id, name, display_name, name_source, type, scope,
  installed_version, version_known, installed_display,
  latest_version, available_display,
  outdated, update_known, update_state, update_label, status_label,
  update_evidence, broken, source, implicit, instances, notes[],
  target, protected, protection[], protection_summary, protected_reason,
  native_pin { mechanism, detail, type, source }, capability { installed, outdated, search, install, upgrade,
  remove, pin, elevation, notes }, operations { install, upgrade, remove }

  Type is a verified manager/category label (for example VS Code Ext,
  PowerShell Module, Python Library, Rust Toolchain, Cargo Tool).
  update_state is one of: outdated, current, unsupported, unchecked,
  unknown, broken, available (install candidates).
  Display names are never invented; name_source says whether the value came
  from the package manager, a verified extension manifest, or the canonical ID.

Inventory (installed/outdated JSON commands):
  total_records, visible_records, hidden_pip_records, outdated_records,
  outdated_visible, manual_update_records, protected_records, unknown_update_records,
  unsupported_update_records, broken_records, duplicate_source_rows,
  managers_detected, managers_active, managers_excluded

Examples:
  pkgs outdated --json
  pkgs installed --json --manager scoop
  pkgs managers --json
  pkgs show winget:Git.Git --json
  pkgs upgrade winget:Git.Git --dry-run --json

Mutations with --json return:
  schema, command, ok, exit_code, dry_run, plan[], and results[] when executed.
  JSON mode never prompts. --yes is required even on a TTY; without it the
  command exits 3 with a failure envelope. --override-protection is refused when
  it would bypass local protection (exit 6). Parse errors return an error-only
  envelope with schema, command, ok=false, exit_code and error{}.

stdout is JSON only. Warnings and progress go to the host/stderr.
'@
        }
        'inventory' {
            Write-Host @'
INVENTORY DEFINITIONS

  total_records              canonical manager:id records after collapsing
                             duplicate source rows (unique installations)
  visible_records            records shown by default (pip adapters hidden)
  hidden_pip_records         pip records in explicit global interpreters
  outdated_records           records with a verified newer version
  outdated_visible           outdated records shown by default
  manual_update_records      outdated records this backend cannot upgrade
  protected_records          installed records protected by pin/ignore/guard
  unknown_update_records     update check failed, version unknown, or on-demand
                             check not run
  unsupported_update_records manager has no outdated listing
  broken_records             incomplete/failed installs reported by a backend
  duplicate_source_rows      extra raw rows collapsed into one canonical record
  managers_detected          manager inventory entries, including excluded
  managers_active            non-excluded managers with at least one package
  managers_excluded          deliberately excluded managers (currently uv)

  `pkgs installed --json` and `pkgs outdated --json` carry these as `inventory`.
  The same values drive the home screen and Package Managers & Health.

  "Current" is only used when the manager actually reports an outdated check.
  "No update check" and "Version unknown" are not current.
'@
        }
        'troubleshoot' {
            Write-Host @'
TROUBLESHOOTING

  pkgs doctor                  backend, tools, config, cache, manager errors
  pkgs refresh                 rebuild the read-only snapshot
  pkgs clean                   remove cached snapshots and previews
  pkgs managers                see excluded managers and capability notes

Common situations:
  "confirmation required"      add --yes for a non-interactive mutation
  "target is ambiguous"        use manager:id (two managers install the same id)
  "native pin/hold detected"   pkgs pin --remove TARGET, then upgrade
  "not reported as outdated"   the backend's live listing disagrees; refresh
  preview shows no details     press Ctrl-/ to toggle; run pkgs clean if a stale
                               preview session survived a crashed terminal
  preview scroll               Alt-Up / Alt-Down inside a package list
  "No update check"            the manager has no outdated listing; this is not
                               proof the package is current
  "Version unknown"            the backend did not report an installed version
  pip outdated is slow         expected; use --with-pip deliberately
  mpm missing                  scoop install main/meta-package-manager

The snapshot is a read-only cache (default 10 minutes). Mutations always
re-verify the exact target against the manager's live listing.
'@
        }
        default {
            Write-PkgsWarn "unknown howto topic '$Topic'; showing overview"
            Show-PkgsHowTo -Topic 'overview'
        }
    }
}
