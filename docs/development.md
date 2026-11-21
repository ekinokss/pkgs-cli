# Development

## Requirements

- PowerShell 7.4+
- Meta Package Manager (mpm) 8.3.0 or newer for live reads; it is not required for deterministic tests
- Optional fzf, bat, gsudo

There is no build step. Run the PowerShell scripts directly or deploy using
install.ps1. The source version is 1.2.3, and the stable JSON schema
remains pkgs/v1.

## Validation scope

The 1.2.3 maintenance correction recognizes mpm --version in formatted
terminal output and rejects versions that cannot be verified. This change was
qualified by deterministic tests and a read-only real-backend version check.
It is not evidence of newly qualified package-management mutation lifecycles.

Earlier 1.2.2 physical lifecycles covered Scoop and the narrow WinGet package
examples Glow (portable), WinMerge (per-user Inno Setup EXE), PuTTY (machine-scope
WiX MSI with user-approved elevation), and Microsoft.WinAppCli (per-user x64
MSIX). Results must not be generalized to all packages or installer families.
Detailed machine-specific qualification records are retained privately and
excluded from this public snapshot.
## Running the suite

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1
```

Expected with local profile integration: `PASS: 149   FAIL: 0`.

The suite:

- creates `%TEMP%\pkgs-tests-<id>` and deletes it afterwards;
- sets `PKGS_CONFIG` and `PKGS_CACHE_DIR` inside that directory;
- replaces `mpm`, `winget`, `scoop`, `choco` and `fzf` with test doubles;
- verifies that repository working directories are untouched;
- uses a fake mutation log and a fake exit code to test failure propagation;
- exercises JSON mutation envelopes, exit-code agreement, TTY/non-TTY
  confirmation behavior and JSON parse-error handling.

No real package manager is invoked and no installed package is modified.

### Two integration tests

`fresh PowerShell session resolves the lazy pkgs function` and
`shortcuts still contains every previous section and the new one` depend on the
local profile. They pass on a machine with the documented profile integration.
For a portable/CI run use:

```powershell
pwsh -NoProfile -File .\tests\run-tests.ps1 -SkipIntegration
```

That reports 147 passes and 2 skips.

## Test doubles and environment variables

| Variable | Purpose |
|---|---|
| `PKGS_TEST_MODE=1` | Enable test overrides |
| `PKGS_CONFIG` | Alternate config path |
| `PKGS_CACHE_DIR` | Alternate cache directory |
| `PKGS_TEST_MPM` | Fake `mpm` script |
| `PKGS_TEST_WINGET` | Fake `winget` |
| `PKGS_TEST_SCOOP` / `PKGS_TEST_SCOOP_ROOT` | Fake scoop + apps root |
| `PKGS_TEST_CHOCO` / `PKGS_TEST_GSUDO` | Fake choco + gsudo |
| `PKGS_TEST_FZF` | Fake fzf |
| `PKGS_TEST_BAT` | Alternate bat (empty string = no bat) |
| `PKGS_FAKE_INSTALLED` / `PKGS_FAKE_OUTDATED` / `PKGS_FAKE_MANAGERS` / `PKGS_FAKE_SEARCH` | Fixtures |
| `PKGS_FAKE_LOG` | Mutation log path |
| `PKGS_FAKE_MUTATION_EXIT` | Forced backend exit code |
| `PKGS_FAKE_FZF_MODE` / `PKGS_FAKE_FZF_INPUT` | Deterministic selection |
| `PKGS_FAKE_STATE` / `PKGS_FAKE_STATE_SEED` | Mutable installed-state JSON for mutation verification |
| `PKGS_FAKE_SKIP_STATE_UPDATE` | Simulate backend success without a state change |
| `PKGS_FAKE_PIN_EXIT` / `PKGS_FAKE_PIN_NO_STATE` | Force a native pin failure / no-op |
| `PKGS_FAKE_MUTATION_VERSION` / `PKGS_FAKE_INSTALL_VERSION` | Version used by the fake backend |
| `PKGS_TEST_TTY=1` | Pretend to be interactive |
| `PKGS_TEST_WIDTH` | Force terminal width |
| `PKGS_TEST_VSCODE_EXT_ROOT` | Fake VS Code extension directory |
| `PKGS_TEST_ROOT` | Test scratch root |
| `PKGS_NO_INPUT=1` | Force non-interactive mode |

`PKGS_TEST_HOME` points the helper at the checkout root when tests dot-source
the modules directly.

## Adding tests

1. Add a fixture under `tests/fixtures/` with deterministic content.
2. Add a `Test-Case` block. Use `Invoke-Cli` for full process runs so exit
   codes and stdout/stderr are real.
3. Assert on canonical identity, not display names.
4. Assert that the mutation log is absent when the action must not mutate.
5. Keep tests hermetic: no live network, no real manager, no writes outside the
   test root.

Useful assertions: `Assert-True`, `Assert-Equal`, `Assert-Match`.

## Benchmarks

```powershell
pwsh -NoProfile -File .\tests\benchmark.ps1
pwsh -NoProfile -File .\tests\benchmark.ps1 -SkipCold
```

Benchmarks are read-only. They measure warm/cold snapshot reads, managers,
search, profile startup, peak `mpm` working set and residual processes. They use
the real cache under `%LOCALAPPDATA%\pkgs\cache` and the real network for search;
run them deliberately.

## Code layout rules

- Keep one responsibility per file; do not add a daemon or background task.
- New backend commands belong in `pkgs-model.ps1` / `pkgs-snapshot.ps1`, never
  inline in the UI.
- Presentation must come from `Get-PkgsPackagePresentation` so CLI and UI agree.
- Never add a force flag, upgrade-all, or implicit target expansion.
- Mutations must carry `manager:id` through planning and execution.
- Keep `pkgs/v1` additive and document new fields in `docs/json-api.md`.
- Update `CHANGELOG.md`, `pkgs-help.ps1`, `integration/shortcuts-snippet.ps1`
  and `AGENTS`-facing documentation for user-visible changes.

## Static checks

```powershell
pwsh -NoProfile -Command {
  Get-ChildItem .\*.ps1 | ForEach-Object {
    $tokens = $null; $errors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($_.FullName, [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors) { $errors | ForEach-Object { "$($_.Extent.StartLineNumber): $($_.Message)" } }
  }
}
```

Optional: `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error`.

## Safety invariants for contributors

- Do not commit `config.json`, caches, inventories, preview directories or logs.
- Do not add tests that call real `winget`, `scoop`, `choco`, npm or pip.
- Do not test failure handling by breaking an installed package.
- Live qualification requires an approved, disposable package and an explicit
  sequence; see the Phase 3 report.
## WinGet postcondition versions

WinGet can report an installed MSI/EXE version with one extra trailing zero
component (for example, `2.16.60.0` for a manifest target of `2.16.60`).
`Test-PkgsWingetVersionEquivalent` permits only that exact three-versus-four
component, trailing-zero shape. It does not strip zeros generally, accept
suffixes, or normalize arbitrary versions. The raw versions reported by WinGet
and mpm must still agree exactly.
