# Deterministic test double for Scoop hold/unhold. Test-only.
$cliArgs = @($args)
if ($env:PKGS_FAKE_LOG) {
    Add-Content -LiteralPath $env:PKGS_FAKE_LOG -Value ('scoop ' + ($cliArgs -join ' '))
}

$action = @('hold', 'unhold') | Where-Object { $cliArgs -contains $_ } | Select-Object -First 1
if (-not $action) { exit 0 }

$id = @($cliArgs | Where-Object { $_ -notlike '-*' -and $_ -ne $action } | Select-Object -Last 1)
if (-not $id) { exit 1 }

if ($env:PKGS_FAKE_PIN_OUTPUT) { $env:PKGS_FAKE_PIN_OUTPUT }
if ($env:PKGS_FAKE_PIN_EXIT) { exit [int]$env:PKGS_FAKE_PIN_EXIT }
if ($env:PKGS_FAKE_PIN_NO_STATE) { exit 0 }

$root = $env:PKGS_TEST_SCOOP_ROOT
if (-not $root) { exit 1 }

$dir = Join-Path $root "$id\current"
$null = New-Item -ItemType Directory -Path $dir -Force
@{
    hold         = ($action -eq 'hold')
    bucket       = 'main'
    architecture = '64bit'
} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $dir 'scoop-install.json') -Encoding utf8
exit 0
