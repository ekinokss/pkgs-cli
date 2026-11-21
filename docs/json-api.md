# JSON API (`pkgs/v1`)

Read-only commands accept `--json`. stdout contains exactly one JSON document;
progress, warnings and errors go to stderr. The schema name is `pkgs/v1`.

Changes are additive. Existing field names and meanings are preserved; new
fields may appear in any `1.x` release. Consumers should ignore unknown fields.

## Envelope

```json
{
  "schema": "pkgs/v1",
  "command": "installed",
  "generated": "2026-11-14T15:00:00.0000000Z",
  "cached": true,
  "cache_age_seconds": 42,
  "mpm": { "version": "8.3.0", "path": "C:\\...\\mpm.exe" },
  "pip_outdated_checked": false,
  "managers": [],
  "packages": [],
  "errors": [],
  "warnings": [],
  "inventory": {}
}
```

`mpm.path` is machine-specific runtime metadata. It is not part of the
repository or fixtures.

## Package object

| Field | Type | Meaning |
|---|---|---|
| `manager` | string | Canonical manager ID (`winget`, `scoop`, `vscode`, `pip312`, ...) |
| `manager_name` | string | Human-readable manager name |
| `id` | string | Canonical backend package ID |
| `name` | string | Backend-reported name (may equal `id`) |
| `display_name` | string | Verified display name or canonical ID |
| `name_source` | string | `extension manifest`, `package manager`, or `canonical id` |
| `type` | string | Verified package category (`WinGet Package`, `VS Code Ext`, ...) |
| `scope` | string | `Global` or `Global Python environment` |
| `installed_version` | string | Raw backend version, possibly empty |
| `version_known` | bool | Whether the version is plausible and reported |
| `installed_display` | string | `0.2.5`, `Unknown`, or `Not installed` |
| `latest_version` | string | Latest known version, possibly empty |
| `available_display` | string | Latest version, `Current`, `Not available`, or `Unknown` |
| `outdated` | bool | Backend reports a newer version |
| `update_known` | bool | Outdated check produced usable evidence |
| `update_state` | string | `outdated`, `current`, `unsupported`, `unchecked`, `unknown`, `broken`, `available` |
| `update_label` | string | Long state label |
| `status_label` | string | Short display status, including protection |
| `update_evidence` | string | How the state was determined |
| `broken` | bool | Incomplete/failed install reported by the backend |
| `source` | string | Inventory source |
| `implicit` | bool | Backend auto-detected record (for example Store entries) |
| `instances` | int | Raw source rows collapsed into this record |
| `notes` | string[] | Normalization notes |
| `target` | string | `manager:id`; the only execution identity |
| `protected` | bool | Any protection layer applies |
| `protection` | object[] | `{ kind, label, detail, hard_block }`; `kind` is `native`, `ignore`, `guard` or `pin-read`; `pin-read` means the native state is unreadable and is a hard block |
| `protection_summary` | string | Joined labels |
| `protected_reason` | string | Same as summary, or empty |
| `native_pin` | object/null | `{ mechanism, detail }` |
| `capability` | object | See below |
| `operations` | object | `{ install, upgrade, remove }` booleans |

### Capability object

```json
{
  "installed": true,
  "outdated": true,
  "search": true,
  "install": true,
  "upgrade": true,
  "remove": true,
  "pin": "native",
  "elevation": "uac",
  "notes": "...",
  "unverified": false
}
```

`outdated` may be `true`, `false`, or the string `on-demand` (pip).

## Manager object

```json
{
  "id": "scoop",
  "name": "Scoop",
  "version": "0.6.0",
  "source": "mpm",
  "detected": true,
  "excluded": false,
  "exclude_reason": "",
  "package_count": 15,
  "outdated_count": 2,
  "outdated_known": true,
  "capabilities": {},
  "errors": [],
  "anomalies": []
}
```

## Inventory object

Present on `installed` and `outdated`. All counts are computed from the full
snapshot before query/manager filters.

| Field | Definition |
|---|---|
| `total_records` | Canonical manager:id records after collapsing duplicate source rows |
| `visible_records` | Records shown by default (non-pip) |
| `hidden_pip_records` | pip records from configured global interpreters |
| `outdated_records` | Records with a verified newer version |
| `outdated_visible` | Outdated records shown by default |
| `manual_update_records` | Outdated non-pip records the backend cannot upgrade |
| `protected_records` | All installed protected records |
| `unknown_update_records` | Unknown state plus on-demand checks not run |
| `unsupported_update_records` | Managers with no outdated listing |
| `broken_records` | Incomplete/failed installs |
| `duplicate_source_rows` | Extra raw rows collapsed into canonical records |
| `managers_detected` | Manager inventory entries, including excluded |
| `managers_active` | Non-excluded managers with at least one package |
| `managers_excluded` | Deliberately excluded managers (`uv`) |

Reconciliation invariants:

```text
visible_records + hidden_pip_records == total_records
duplicate_source_rows == sum(instances - 1)
outdated_visible <= outdated_records
protected_records <= total_records
```

`outdated_visible` equals `outdated_records` minus pip outdated records (pip rows
are hidden from the default view even when a cached check exists).

## Examples

```powershell
pkgs outdated --json | ConvertFrom-Json
pkgs installed --manager scoop --json
pkgs installed 7zip --json
pkgs managers --json
pkgs show scoop:7zip --json
pkgs doctor --json
```

`pkgs show` returns the full package object for one resolved target. `doctor`
returns `checks` plus an `inventory` object.

## Mutation commands

Mutation commands (`upgrade`, `install`, `remove`) print human-readable plans
by default. `--json` is a deterministic, non-interactive contract:

- JSON mode never prompts and never calls `Read-Host`.
- `--yes` is required for execution, even on a TTY. Without it the command
  returns exit 3, one failure envelope, and no backend invocation.
- `--override-protection` is not honored in JSON mode because the typed
  `OVERRIDE`/`CONFIRM` authorization cannot be obtained; locally protected
  targets are refused with exit 6 instead of being bypassed.
- Blocked plans, missing confirmation, manager mismatch and pre-plan usage
  errors emit exactly one envelope with no success result.

The envelope contains `schema`, `command`, `ok`, `exit_code`, `dry_run`,
`plan`, and `results` only when execution/verification reached that stage.
`message` describes missing confirmation, manager mismatch or a refused JSON
override. `plan[]` carries `target`, `from`, `to`, `version`, `invocation`,
`native`, `blocked`, `reason`, `protected` and `protection`. `pin --json`
returns the smaller `schema`/`command`/`ok`/`exit_code`/`results` shape.

A pre-plan usage or resolution error returns an error-only envelope:

```json
{
  "schema": "pkgs/v1",
  "command": "upgrade",
  "ok": false,
  "exit_code": 2,
  "error": { "code": 2, "message": "unknown option '--bogus'" }
}
```

No `plan` is fabricated for a pre-plan error. `--` terminates option parsing;
tokens after it are literal positionals and never enable JSON mode.

### Mutation failure semantics

| Failure | Backend invoked? | Meaning |
|---|---|---|
| Blocked plan (protection, guard, stale or invalid target) | No | The mutation did not start. |
| Missing `--yes` or manager mismatch | No | Authorization or usage failed before execution. |
| Backend nonzero exit | Yes | The backend may have partially acted; `results[].backend_exit` is nonzero and `verified=false`. |
| Post-operation verification failure | Yes | The backend may have mutated the package, but the required postcondition was not established; `results[].verified=false`. |

Do not treat exit 5 as proof that no mutation occurred. Only a blocked plan or
an authorization/usage refusal returned before execution guarantees that no
backend write was attempted.

Execution results include:

```json
{
  "target": "scoop:7zip",
  "manager": "scoop",
  "id": "7zip",
  "operation": "upgrade",
  "ok": true,
  "verified": true,
  "verification": "installed version '26.06'",
  "backend_exit": 0,
  "exit": 0,
  "message": ""
}
```

`verified` is true only when the live inventory shows the expected change.
`backend_exit` is the raw backend exit code; `exit` is the pkgs result code (5
when verification fails). `--dry-run` live-verifies the target and prints the
exact command without executing it. Mutation JSON includes `ok`, `exit_code`
and `dry_run`: 0 when ready/successful, 6 when blocked by protection, 5 when
invalid/unsupported/execution/verification failure, 3 when confirmation is
missing, and 4 when a manager filter does not match. The process exit code
matches `exit_code`.

## Exit codes

JSON mode still uses the documented process exit codes (0, 1, 2, 3, 4, 5, 6,
130). A JSON document on stdout does not imply success; check the exit code.
