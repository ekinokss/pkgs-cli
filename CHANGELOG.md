# Changelog

All notable changes to `pkgs`. The project follows a small, explicit
`MAJOR.MINOR.PATCH` version in `pkgs-core.ps1`.

## [1.2.3] — Backend-version verification maintenance

> Scope: mpm backend version detection and minimum-version gate hardening.
> The JSON schema remains pkgs/v1. The deployed production installation
> remained at v1.2.2 during release preparation; source publication and
> production deployment are separate approval decisions.

### Fixed

- Recognize mpm's real --version banner even when ANSI color and preceding
  artwork appear before the mpm, version X.Y.Z label.
- Reject unrecognized, missing, failed or ambiguous backend-version probes
  with exit 5 before using mpm for inventory or package operations.
- Preserve the minimum supported mpm version, 8.3.0. A lower numeric version
  is refused; supported higher versions remain accepted.
- Add eleven deterministic regression cases for colored output, newer versions,
  too-old versions, unknown output, a nonzero probe exit, conflicting labels,
  prerelease/build-suffix versions, mixed malformed/valid labels, and missing
  mpm identity.

### Verification

- Final deterministic test suite: 147 PASS / 0 FAIL, with 2 expected
  profile-dependent integration skips, on the approved private branch and
  sanitized public candidate.
- A separate isolated installer and profile-less launcher test passed; the
  existing production installation was unchanged.
- Private PR CI and post-merge `main` CI: PASS. Publication and production
  deployment require separate authorization.
- No new physical package-management lifecycle was tested for v1.2.3.

## [1.2.2]

> Release scope: WinGet postcondition version-equivalence correction for
> explicit-version installs and upgrades. Deterministic qualification only. The
> previous physical WinMerge upgrade failed verification under v1.2.1, and the
> corrected implementation has not yet passed a physical upgrade retest. Phase
> 6B remains FAIL / NOT QUALIFIED. MSI/MSIX are not qualified by this release.

### Fixed

- WinGet postcondition verification for explicit-version installs and upgrades
  now accepts the narrow three-versus-four-component trailing-zero form:
  `2.16.60` and `2.16.60.0` may be treated as equivalent in those specified
  postconditions. The comparison is component-wise and culture-independent; it
  does not strip zeros generally, accept suffixes, or normalize arbitrary
  versions.
- The raw versions reported by WinGet and mpm must still agree exactly. A raw
  provider disagreement remains a fail-closed refusal.
- Package identity, source verification, duplicate-registration checks and
  native/local protection remain strict. Default-version installs retain their
  existing comparison behavior.
- Source version is `1.2.2`; the JSON schema remains `pkgs/v1`.

### Verification

- Full deterministic suite: **PASS 138 / FAIL 0**.
- CI-compatible suite: **PASS 136 / FAIL 0**, 2 expected skips.
- Parser: 0 errors. PSScriptAnalyzer: 0 errors and 116 warnings, matching the
  accepted main baseline. Duplicate-function scan clean.
- The WinMerge equivalence matrix, genuine version mismatch refusals,
  WinGet/mpm disagreement refusals, and protection/identity regressions remain
  in the suite.
- Physical WinMerge upgrade retest: **NOT PERFORMED** for v1.2.2. This release
  is not evidence that the EXE upgrade lifecycle is qualified.

## [1.2.1]

> Release scope: Scoop canonical identity safety correction. Qualified
> deterministically and by read-only physical checks; no live Scoop mutation was
> performed in Phase 5B. The upstream mpm truncation defect remains unresolved.

### Fixed

- Scoop `upgrade` and `remove` plans now require the final canonical ID to match
  an exact direct child directory under a recognized Scoop apps root (user or
  global). The check runs after fresh backend identity resolution and again
  immediately before backend execution. Missing, unreadable, ambiguous,
  prefix-only or punctuation-lookalike evidence blocks the plan with exit 5 and
  no backend invocation. The guard is an identity-safety refusal, not a native
  pin/hold claim.
- The profile integration test now derives the expected version from the actual
  deployed pkgs installation rather than hardcoding the 1.1.0 release. It also
  verifies `pkgs/v1` and `LASTEXITCODE=0`, so it remains meaningful across
  deployments and development branches.
- Added deterministic fake-backend coverage for cached/fresh ID corruption,
  native-hold and local-ignore bypass attempts, missing/prefix/ambiguous roots,
  unreadable roots, case-insensitive matches, truncated display names,
  correct/truncated and duplicate cache records, cached-state planning, and a
  directory disappearing before execution.
- Scoop root discovery now follows Scoop's effective precedence: `SCOOP`
  environment, config `root_path`, portable installation root, then the user
  default; and `SCOOP_GLOBAL`, config `global_path`, then the ProgramData
  default. Configuration read failures and inaccessible, malformed or
  unclassifiable roots fail closed. Unrelated default roots are never used when
  Scoop is configured elsewhere.
- Added deterministic root-state tests for genuinely absent, readable, regular
  file, ACL-denied, unclassifiable, later-inaccessible and multi-root cases.
- Added a mixed corrupt-Scoop/valid-unrelated batch test: planning blocks before
  any backend invocation. Pre-plan refusal is all-or-nothing; per-entry
  pre-execution refusal is not a transaction and earlier completed entries are
  not rolled back.
- Added malformed/unreadable Scoop configuration coverage; configuration
  failures fail closed rather than falling back to unrelated default roots.
- Scoop ordinary and portable configuration candidates now pass through a shared
  file-state classifier. Only a provably absent file is optional; unreadable,
  unknown, directory and non-object/malformed JSON states fail closed. A
  portable config whose state is untrustworthy never silently falls back to the
  ordinary config, and valid environment root overrides do not suppress a
  configuration error.
- Source version is `1.2.1`; the JSON schema remains `pkgs/v1`.

### Verification

- Full deterministic suite: **PASS 131 / FAIL 0** (includes the profile
  integration tests).
- CI-compatible suite: **PASS 129 / FAIL 0**, 2 expected skips.
- Read-only physical validation on 2026-11-17 at HEAD
  `4da792ec88affd7d278bec0077ade77e1cf3f778`: effective user root readable,
  global default absent, exact `meta-package-manager` directory match, correct
  installed/show/pin JSON, and a ready remove dry-run with no backend mutation.
- Read-only configuration revalidation at
  `1ccfc5e10ce760fd1b0818db33c047ff9b8b6811`: ordinary config state `file`,
  no root/config errors, correct identity and installed/show/pin JSON, and a
  ready remove dry-run with no backend mutation.
- PSScriptAnalyzer warnings match the accepted main baseline (116); parser and
  duplicate-function scans clean.
- Phase 5B qualification performed no real package mutation. The controlled
  v1.2.1 release deploys application files only; it does not change package
  manager state.

## [1.2.0]

> Release scope: WinGet live qualification covers only the Glow portable x64
> `winget`-source package in the medium-integrity Mode B PATH-fallback
> environment (Parts 1 and 2). Mode A symlink integration, MSI, EXE, MSIX and
> other WinGet packages are **NOT TESTED** live.

### Fixed

- WinGet mutation plans now verify the installed identity directly with
  `winget list --id <id> --exact`: exactly one exact-ID record, source `winget`,
  and a readable version. Wrong-source, unreported-source, duplicate and
  WinGet-only registrations are refused before the backend runs.
- An mpm/WinGet installed-version disagreement is refused as stale evidence.
- Post-operation WinGet verification now checks the direct installed identity for
  install, upgrade and remove, in addition to mpm's inventory.
- Malformed or empty `winget pin list` output is `protection unknown` and is a
  hard block; `--override-protection` cannot bypass it. Snapshot pin reads record
  the error instead of crashing.
- The `Pin type` header used by real WinGet is parsed, and a blank `Available`
  value no longer shifts `Source` into the wrong column.
- WinGet package IDs and explicit version specifiers are token-validated before
  pin or mutation commands.
- Blocking WinGet pin creation now requires readback with exactly one pin whose
  type is `Blocking` and whose source is `winget`. Ordinary `Pinning`, `Gating`,
  wrong-source, missing-type and duplicate records are failures; existing pins
  are never replaced or removed automatically.
- WinGet pin creation requires exactly one installed exact-ID record with source
  `winget` and a readable version. Pin removal verifies ownership of the exact
  `winget`-source pin and leaves same-ID pins from other sources untouched;
  orphaned `winget` pins can still be removed.
- Default WinGet installs now require the installed version to equal the planned
  available version, recheck that version immediately before execution, and
  require direct WinGet evidence to agree with mpm's refreshed inventory.
- `pkgs pin --list` and `pkgs show --json` expose the native pin type and source.
- `pkgs pin --json` now captures native pin output and routes it to stderr, so
  stdout remains a single valid JSON envelope. This was found during the live
  Part 1 attempt.
- Upgrade protection is now evaluated before the live backend outdated check.
  WinGet omits a blocking-pinned package from its upgrade list; such a target is
  now reported as a native-pin protection block (exit 6) instead of
  "not reported as outdated" (exit 5). This was found during the Part 2 attempt.
- Blocked non-dry-run mutations now emit exactly one `pkgs/v1` JSON envelope
  with `ok=false`, matching `exit_code`, `dry_run=false`, and the blocked/
  protected plan instead of returning with no JSON document. The shared helper
  also covers manager mismatch, missing confirmation and execution/verification
  results.
- `--json` mutations are now deterministic and non-interactive. JSON mode never
  calls `Read-Host`, never prints a confirmation prompt, and requires `--yes`
  even when stdin is a terminal; without `--yes` it returns exit 3 and one JSON
  failure envelope before any backend call. Previously an interactive terminal
  could enter the prompt and cancel with exit 0 without emitting JSON.
- JSON mode does not honor `--override-protection` when it would bypass local
  protection, because the typed `OVERRIDE`/`CONFIRM` authorization cannot be
  obtained without a prompt. The plan entry and `message` say so, the command
  returns exit 6, and no backend runs.
- `--json`/`-j` is detected before argument parsing (stopping at `--` and
  skipping value-option arguments), so usage and parse errors requested with
  `--json` return one error-only `pkgs/v1` envelope with `schema`, `command`,
  `ok=false`, `exit_code` and `error{code,message}`. Top-level exception
  envelopes now include `exit_code`.
- `pin --json`, `ignore --json` and `unprotect --json` also never prompt;
  `--yes` is required and their success envelopes now include `exit_code`.
- Source version is `1.2.0`; the JSON schema remains `pkgs/v1`.
- `winget list` provenance queries do not pass `--source` (which hides the
  `Source` column) and do not use `--scope` as proof of installation scope.

### Added

- 29 deterministic WinGet tests (Phase 4A-4B baseline): source/identity,
  duplicate and WinGet-only refusal, stale version, unreadable inventory,
  malformed/empty/typed pins, pin failure/readback mismatch, blocking
  type/source readback, pre-pin identity, pin removal ownership, orphaned pin
  removal, no-op and nonzero backends, post-install and post-remove identity
  mismatch, default/explicit install version verification, stale
  available-version refusal, direct/mpm post-state disagreement, pin-target
  token validation, pin JSON output isolation, and
  protection-before-outdated-filter ordering.
- 9 Phase 4C mutation-JSON tests (98 baseline): native pin, local ignore, Scoop
  hold, unreadable protection, guard, protected mixed batch, missing `--yes`,
  stale target, and backend native-output isolation.
- 11 Phase 4D JSON edge-case tests (109 total): interactive JSON with and
  without `--yes`, native pin under a simulated TTY, preserved non-JSON
  interactive cancellation, JSON protection-override refusal, parse errors
  before and after `--json`, a target-resolution error envelope, literal
  `--json` after `--`, and JSON pin/ignore without `--yes`.
- Phase 4 audit, candidate comparison and exact proposed Part 1/Part 2 live
  sequences in `docs/mutation-audit.md`.

### Verification

- Automated: **PASS 109 / FAIL 0**; CI-compatible **PASS 107 / FAIL 0** with 2
  expected skips.
- Live Phase 4B Part 1 rerun (2026-11-15, reviewed HEAD `4d257d2`, verified
  medium-integrity process): **PASS** - Glow 3.0.0 installed using WinGet's
  supported PATH fallback (symlink creation unavailable), executable and
  fresh-shell command reported 3.0.0, native pin JSON/stdout contract passed,
  blocking pin and local ignore refused removal without backend uninstall,
  unpin/ignore removal succeeded, uninstall verified absence, and user/machine
  PATH, config and inventories were restored. No code change was required in
  this rerun.
- Live Phase 4B Part 2 rerun (2026-11-16, HEAD `2c336fd`, verified
  medium-integrity process): **PASS** - Glow 2.1.2 installed via Mode B PATH
  fallback; native-pin and local-ignore upgrade refusals returned exit 6 with no
  backend call; the actual upgrade reached 3.0.0; the 2.1.2 PATH entry was
  replaced by the 3.0.0 entry; executable and fresh shell reported 3.0.0;
  uninstall and baseline PATH/config/inventory restoration passed. No code
  change was required in this rerun.
- Phase 4C JSON correction: accepted; blocked non-dry mutations emit one JSON
  envelope, deterministic-only until live retest (none was performed).
- Phase 4D JSON edge cases: deterministic-only; JSON mode never prompts,
  requires `--yes`, refuses JSON protection overrides and returns
  machine-readable parse errors. No live package mutation was performed.
- Live WinGet upgrade beyond the Glow 2.1.2 -> 3.0.0 fixture / other installer
  types: **NOT TESTED**.

## [1.1.0] - 2026-11-14

### Phase 3 - mutation hardening (Scoop live-qualified; other managers live NOT TESTED)

#### Fixed

- Native pin/unpin was broken in the real CLI: `Set-PkgsPin` called a function
  name that `pkgs.ps1` shadowed with the CLI command, so live pinning failed
  with "Cannot index into a null array". The executor is now
  `Invoke-PkgsNativePinCommand`.
- Scoop 0.6.0 hold metadata is read from `scoop-install.json` with legacy
  `install.json` fallback. Missing or malformed metadata is `protection unknown`
  and hard-blocks mutation instead of being treated as unheld.
- Native pin/unpin failures now propagate; a zero exit is verified by re-reading
  the pin/hold. Non-zero, no-op and unreadable readbacks are exit 5.
- Native backend output is routed to the host instead of the result pipeline;
  successful non-JSON install/remove/pin commands now return 0 instead of 5.
- WinGet mutations no longer use mpm's `winget install --id` rendering. mpm
  8.3.0 omits `--exact`, `--source` and `--version`, and WinGet uses substring
  matching for `--id` without `--exact`. pkgs now executes WinGet writes
  directly with `--id ... --exact --source winget`.
- WinGet pins are created with `--blocking --exact --source winget`, so they
  cannot be overridden by an external explicit `winget upgrade`.
- Version-specific Scoop installs (`app@version`) are pinned and skipped by
  normal outdated/upgrade. The live proposal is split into a non-upgrade
  install/hold/refusal/uninstall sequence and a separately approved temporary
  bucket upgrade fixture.
- Plans are re-checked immediately before execution: native pins, pkgs
  protection, installed/available versions and installed identity must still
  match. A stale plan is refused.
- Backend success is now verified against live inventory. A zero exit code
  without the expected version or removal is a failure (exit 5), not a pass.
- Installing an already-installed target is refused; use upgrade or remove.
- `--dry-run` now live-verifies targets instead of trusting a cached snapshot.
  Dry-run exit codes now match JSON: 0 ready, 6 protection block, 5 invalid/unsupported.
- Local pin/unpin and `pkgs ignore`/`pkgs unprotect` now require explicit
  confirmation (`[y/N]` on a TTY, `--yes` off a TTY). The Phase 2 UI Protect
  regression is covered by a test.

#### Added

- 60 deterministic tests (up from 41): direct WinGet exact execution, blocking
  pins, post-verification success/failure, stale-plan protection refusal,
  install refusal, dry-run live verification, manager-filter enforcement,
  protection confirmations and the UI Protect cancellation regression.
- `-SkipIntegration` for portable/CI runs and a read-only GitHub Actions
  workflow.
- `docs/protection.md` WinGet execution section and mutation audit notes.

#### Verification

- Automated: **PASS 60 / FAIL 0** (58 pass + 2 skip with `-SkipIntegration`).
- Live Part 1 (Scoop `less` install, hold, removal refusal, unhold, ignore,
  removal refusal, uninstall): **PASS**, 2026-11-15.
- Live upgrade: **PASS** (Part 2 temporary local bucket, 1.0.0 -> 1.1.0, 2026-11-15).
- Native pin/remove non-JSON success exits verified 0 after output-routing fix.
- Phase 2 baseline remains at `phase2-accepted` (`c896c76`).

## [1.0.0] - 2026-11-14

### Phase 2 - UI redesign, inventory correctness and physical acceptance

Accepted baseline. Tag: `phase2-accepted`.

#### Fixed

- Preview pane failed with `[bat error] ... preview{4}.txt` because fzf
  consumed `\{4}` as an escaped placeholder. Preview now uses a stable
  target-hash file plus the raw `{r4}` placeholder and a fault-tolerant
  `preview.cmd`.
- Preview files are generated once per session in a `preview-<pid>-<guid>`
  directory, cleaned on exit, and stale sessions are removed by owner PID or
  age.
- Managers without outdated support were presented as current. Update state is
  now explicit: `outdated`, `current`, `unsupported`, `unchecked`, `unknown`,
  `broken`, `available`.
- VS Code extensions were indistinguishable from the VS Code application.
  Added verified types (`VS Code Ext`), verified manifest display names and
  `name_source`; canonical IDs remain the execution identity.
- Status symbols (`!`, `*`, `~`, `?`) were unexplained. Status is now words,
  with protection reasons such as `Protected (guard) - Update available`.
- Inventory counts were ambiguous. `inventory` now reconciles total, visible,
  hidden pip, outdated, manual updates, protected, unknown, unsupported,
  broken, duplicate source rows and manager counts, and drives both CLI and UI.
- Old screen content leaked between UI screens; screens now clear on entry.
- Narrow terminals lost version information; layouts are selected by width.

#### Added

- Task-oriented home screen: Available Updates, Installed Packages, Search &
  Install, Protected / Ignored Packages, Package Managers & Health, Refresh
  Data, Help, Quit.
- Installed browsing by manager and by package type.
- Details screen with canonical ID, type, manager, scope, versions, evidence,
  protection, operations and exact dry-run commands.
- Typed `OVERRIDE` and `CONFIRM` gates for protected UI mutations.
- `[y/N]` confirmation before the UI adds local ignore entries.
- `pkgs howto inventory`, `pkgs help ui`, and revised `pkgs howto keys`.
- 41 deterministic tests (up from 34), including preview safety, rapid
  selection changes, classification, inventory reconciliation and layout.
- `preview.cmd` helper and `install.ps1` deployment tooling.

#### Verification at acceptance

- Automated: **PASS 41 / FAIL 0**.
- Physical Windows Terminal acceptance: **PASS** for the Phase 2 checklist.
- Preview defect: **PASS** (real fzf selection, no placeholder path).
- Mutation acceptance: **NOT TESTED** (no live install, upgrade, remove or
  native pin was performed).
- `mpm` backend: 8.3.0, unchanged.
- Performance (live cache): cold snapshot ~20.4 s, warm outdated ~1.5 s,
  managers ~0.75 s, installed scoop ~1.3 s, profile startup ~0.97 s, peak mpm
  working set ~107 MiB, residual mpm processes 0.

#### Known limitations

- Live mutation paths remain unqualified.
- Microsoft Store inventory depends on a `winget` adapter; mpm omits Store
  packages.
- Several managers have no per-package outdated/upgrade support and are
  reported as `No update check` or `Manual update`.
- Search is network-bound; cold snapshots are slow.
- UI is terminal/fzf based, with a compact narrow-terminal layout.

### Verification

