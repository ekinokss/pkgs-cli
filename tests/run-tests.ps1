#Requires -Version 7.4
# Deterministic test suite for pkgs. No real package-manager mutation is
# performed: mpm, winget, scoop, choco and fzf are replaced with test doubles
# whenever PKGS_TEST_MODE=1.
param(
    [switch]$SkipIntegration
)

$ErrorActionPreference = 'Stop'
$script:SkipIntegration = [bool]$SkipIntegration
$here       = $PSScriptRoot
$pkgsRoot   = Split-Path -Parent $here
$pkgsScript = Join-Path $pkgsRoot 'pkgs.ps1'
$fixtures   = Join-Path $here 'fixtures'
$fakeMpm    = Join-Path $here 'fake-mpm.ps1'
$fakeWinget = Join-Path $here 'fake-winget.ps1'
$fakeFzf    = Join-Path $here 'fake-fzf.ps1'

$script:Pass = 0
$script:Fail = 0
$script:Failures = @()
$script:TestRoot = Join-Path $env:TEMP ('pkgs-tests-' + [guid]::NewGuid().ToString('N').Substring(0, 8))

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Equal {
    param($Actual, $Expected, [string]$Message)
    if ($Actual -ne $Expected) { throw "$Message (expected '$Expected', got '$Actual')" }
}

function Assert-Match {
    param([string]$Text, [string]$Pattern, [string]$Message)
    if ($Text -notmatch $Pattern) { throw "$Message (no match for '$Pattern')" }
}

function Reset-TestOverrides {
    foreach ($name in 'PKGS_FAKE_INSTALLED', 'PKGS_FAKE_OUTDATED', 'PKGS_FAKE_MANAGERS', 'PKGS_FAKE_SEARCH',
                      'PKGS_FAKE_MUTATION_EXIT', 'PKGS_FAKE_FZF_MODE', 'PKGS_TEST_TTY', 'PKGS_TEST_WIDTH',
                      'PKGS_FAKE_SKIP_STATE_UPDATE', 'PKGS_FAKE_PIN_EXIT', 'PKGS_FAKE_PIN_NO_STATE', 'PKGS_FAKE_PIN_OUTPUT', 'PKGS_FAKE_MUTATION_OUTPUT', 'PKGS_FAKE_MUTATION_VERSION', 'PKGS_FAKE_INSTALL_VERSION',
                      'PKGS_FAKE_WINGET_SOURCE', 'PKGS_FAKE_WINGET_VERSION', 'PKGS_FAKE_WINGET_DUPLICATE', 'PKGS_FAKE_WINGET_LIST_MALFORMED', 'PKGS_FAKE_WINGET_PIN_LIST',
                      'PKGS_FAKE_WINGET_PIN_STATE', 'PKGS_FAKE_WINGET_PIN_ADD_TYPE', 'PKGS_FAKE_WINGET_PIN_ADD_SOURCE', 'PKGS_FAKE_WINGET_PIN_DUPLICATE', 'PKGS_FAKE_WINGET_PIN_NO_STATE',
                      'PKGS_FAKE_WINGET_PIN_ADD_MISSING_TYPE', 'PKGS_FAKE_MPM_VERSION_OVERRIDE', 'PKGS_FAKE_MPM_VERSION_OUTPUT', 'PKGS_FAKE_MPM_VERSION_EXIT') {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction Ignore
    }
    if ($env:PKGS_FAKE_STATE_SEED -and $env:PKGS_FAKE_STATE -and (Test-Path -LiteralPath $env:PKGS_FAKE_STATE_SEED)) {
        Copy-Item -LiteralPath $env:PKGS_FAKE_STATE_SEED -Destination $env:PKGS_FAKE_STATE -Force
    }
    $env:PKGS_TEST_MPM = $fakeMpm
    $env:PKGS_TEST_WINGET = $fakeWinget
    $env:PKGS_TEST_FZF = $fakeFzf
}

function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    Reset-TestOverrides
    $script:LastResult = $null
    try {
        & $Body
        $script:Pass++
        Write-Host "PASS  $Name" -ForegroundColor Green
    }
    catch {
        $script:Fail++
        $detail = $_.Exception.Message
        if ($script:LastResult) {
            $err = ($script:LastResult.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' / '
            $out = ($script:LastResult.Stdout -split "`r?`n" | Where-Object { $_ } | Select-Object -First 2) -join ' / '
            if ($err) { $detail += " | stderr: $err" }
            if ($out) { $detail += " | stdout: $out" }
        }
        $script:Failures += "$Name :: $detail"
        Write-Host "FAIL  $Name :: $detail" -ForegroundColor Red
    }
}

function Test-IntegrationCase {
    param([string]$Name, [scriptblock]$Body)
    if ($script:SkipIntegration) {
        Write-Host "SKIP  $Name" -ForegroundColor DarkGray
        return
    }
    Test-Case -Name $Name -Body $Body
}

function New-TestEnvironment {
    $cache = Join-Path $script:TestRoot 'cache'
    $config = Join-Path $script:TestRoot 'config.json'
    $log = Join-Path $script:TestRoot 'mutations.log'
    $scoopApps = Join-Path $script:TestRoot 'scoop\apps'
    $state = Join-Path $script:TestRoot 'fake-state.json'
    $stateSeed = Join-Path $script:TestRoot 'fake-state.seed.json'

    Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction Ignore
    Remove-Item -LiteralPath $log -Force -ErrorAction Ignore

    $cfg = [ordered]@{
        version = 1
        cacheTtlSeconds = 0
        managers = [ordered]@{ uv = 'excluded'; pip = 'adapter' }
        pip = [ordered]@{ interpreters = @() }
        guard = @(
            [ordered]@{ manager = 'winget'; pattern = '^GoLang\.Go$'; reason = 'dev toolchain' }
            [ordered]@{ manager = 'scoop'; pattern = '^flutter$'; reason = 'dev toolchain' }
        )
        guardExceptions = @()
        ignored = @(
            [ordered]@{ manager = 'npm'; id = 'left-pad'; reason = 'test ignore'; kind = 'ignore'; added = '2026-01-01' }
        )
        ui = [ordered]@{ height = '80%'; preview = $false }
    }
    $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $config -Encoding utf8

    # Deterministic VS Code extension metadata.
    $extRoot = Join-Path $script:TestRoot 'vscode-extensions'
    $commandCode = Join-Path $extRoot 'commandcode.commandcode-vscode-0.2.5'
    $remote = Join-Path $extRoot 'ms-vscode-remote.remote-containers-0.469.0'
    $null = New-Item -ItemType Directory -Path $commandCode, $remote -Force
    '{"name":"commandcode-vscode","displayName":"Command Code for VS Code","publisher":"commandcode","version":"0.2.5"}' |
        Set-Content -LiteralPath (Join-Path $commandCode 'package.json') -Encoding utf8
    '{"name":"remote-containers","displayName":"%displayName%","publisher":"ms-vscode-remote","version":"0.469.0"}' |
        Set-Content -LiteralPath (Join-Path $remote 'package.json') -Encoding utf8

    # Native scoop hold fixture.
    $holdDir = Join-Path $scoopApps '7zip\current'
    $null = New-Item -ItemType Directory -Path $holdDir -Force
    '{"hold":true,"bucket":"main"}' | Set-Content -LiteralPath (Join-Path $holdDir 'scoop-install.json') -Encoding utf8
    $plainDir = Join-Path $scoopApps 'shared.app\current'
    $null = New-Item -ItemType Directory -Path $plainDir -Force
    '{"hold":false,"bucket":"main"}' | Set-Content -LiteralPath (Join-Path $plainDir 'scoop-install.json') -Encoding utf8
    $metaDir = Join-Path $scoopApps 'meta-package-manager\current'
    $null = New-Item -ItemType Directory -Path $metaDir -Force
    '{"hold":false,"bucket":"main"}' | Set-Content -LiteralPath (Join-Path $metaDir 'scoop-install.json') -Encoding utf8

    foreach ($name in 'PKGS_CONFIG', 'PKGS_CACHE_DIR', 'PKGS_TEST_MODE', 'PKGS_TEST_MPM', 'PKGS_TEST_WINGET', 'PKGS_TEST_SCOOP',
                      'PKGS_TEST_SCOOP_ROOT', 'PKGS_TEST_CHOCO', 'PKGS_TEST_FZF', 'PKGS_TEST_BAT', 'PKGS_TEST_GSUDO',
                      'PKGS_FAKE_INSTALLED', 'PKGS_FAKE_OUTDATED', 'PKGS_FAKE_MANAGERS', 'PKGS_FAKE_SEARCH', 'PKGS_FAKE_LOG',
                      'PKGS_FAKE_MUTATION_EXIT', 'PKGS_FAKE_FZF_MODE', 'PKGS_FAKE_FZF_INPUT', 'PKGS_TEST_TTY', 'PKGS_NO_INPUT',
                      'PKGS_FAKE_STATE', 'PKGS_FAKE_STATE_SEED', 'PKGS_FAKE_SKIP_STATE_UPDATE',
                      'PKGS_FAKE_MUTATION_VERSION', 'PKGS_FAKE_INSTALL_VERSION', 'PKGS_FAKE_PIN_EXIT', 'PKGS_FAKE_PIN_NO_STATE', 'PKGS_FAKE_PIN_OUTPUT', 'PKGS_FAKE_MUTATION_OUTPUT',
                      'PKGS_FAKE_WINGET_SOURCE', 'PKGS_FAKE_WINGET_VERSION', 'PKGS_FAKE_WINGET_DUPLICATE', 'PKGS_FAKE_WINGET_LIST_MALFORMED', 'PKGS_FAKE_WINGET_PIN_LIST',
                      'PKGS_FAKE_WINGET_PIN_STATE', 'PKGS_FAKE_WINGET_PIN_ADD_TYPE', 'PKGS_FAKE_WINGET_PIN_ADD_SOURCE', 'PKGS_FAKE_WINGET_PIN_DUPLICATE', 'PKGS_FAKE_WINGET_PIN_NO_STATE',
                      'PKGS_FAKE_WINGET_PIN_ADD_MISSING_TYPE', 'PKGS_FAKE_MPM_VERSION_OVERRIDE', 'PKGS_FAKE_MPM_VERSION_OUTPUT', 'PKGS_FAKE_MPM_VERSION_EXIT') {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction Ignore
    }

    $env:PKGS_CONFIG = $config
    $env:PKGS_CACHE_DIR = $cache
    $env:PKGS_TEST_MODE = '1'
    $env:PKGS_TEST_MPM = $fakeMpm
    $env:PKGS_TEST_WINGET = $fakeWinget
    $env:PKGS_TEST_SCOOP = $fakeScoop
    $env:PKGS_TEST_SCOOP_ROOT = $scoopApps
    $env:PKGS_TEST_CHOCO = $fakeChoco
    $env:PKGS_TEST_FZF = $fakeFzf
    $env:PKGS_TEST_BAT = ''
    $env:PKGS_FAKE_LOG = $log
    $env:PKGS_FAKE_FZF_INPUT = Join-Path $script:TestRoot 'fzf-input.txt'
    Copy-Item -LiteralPath (Join-Path $fixtures 'installed-normal.json') -Destination $stateSeed -Force
    Copy-Item -LiteralPath $stateSeed -Destination $state -Force
    $env:PKGS_FAKE_STATE = $state
    $env:PKGS_FAKE_STATE_SEED = $stateSeed
    $env:PKGS_TEST_VSCODE_EXT_ROOT = $extRoot
    $env:PKGS_TEST_ROOT = $script:TestRoot

    return [pscustomobject]@{ Cache = $cache; Config = $config; Log = $log; ScoopApps = $scoopApps }
}

function Invoke-Cli {
    param(
        [Parameter(Mandatory)][string[]]$Arguments,
        [string]$WorkingDirectory = $script:TestRoot,
        [string]$StdinFile,
        [int]$TimeoutSeconds = 120
    )

    $uniq = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $stdout = Join-Path $script:TestRoot "stdout-$uniq.txt"
    $stderr = Join-Path $script:TestRoot "stderr-$uniq.txt"

    $params = @{
        FilePath               = (Join-Path $PSHOME 'pwsh.exe')
        ArgumentList           = @('-NoProfile', '-File', $pkgsScript) + $Arguments
        RedirectStandardOutput = $stdout
        RedirectStandardError  = $stderr
        WorkingDirectory       = $WorkingDirectory
        NoNewWindow            = $true
        PassThru               = $true
    }
    if ($StdinFile) { $params.RedirectStandardInput = $StdinFile }

    $process = Start-Process @params
    if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
        try { $process.Kill($true) } catch { }
        throw "pkgs timed out: $($Arguments -join ' ')"
    }

    $result = [pscustomobject]@{
        ExitCode = $process.ExitCode
        Stdout   = if (Test-Path -LiteralPath $stdout) { Get-Content -LiteralPath $stdout -Raw } else { '' }
        Stderr   = if (Test-Path -LiteralPath $stderr) { Get-Content -LiteralPath $stderr -Raw } else { '' }
    }
    $process.Dispose()
    Remove-Item -LiteralPath $stdout, $stderr -Force -ErrorAction Ignore
    $script:LastResult = $result
    return $result
}

function Invoke-UiHelper {
    param(
        [Parameter(Mandatory)][string]$Body,
        [hashtable]$ExtraEnv = @{},
        [string]$StdinFile
    )
    $uniq = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $script = Join-Path $script:TestRoot "ui-helper-$uniq.ps1"
    $out = Join-Path $script:TestRoot "ui-helper-$uniq.out"
    $err = Join-Path $script:TestRoot "ui-helper-$uniq.err"
    $Body | Set-Content -LiteralPath $script -Encoding utf8
    $env:PKGS_TEST_HOME = $pkgsRoot
    foreach ($key in $ExtraEnv.Keys) { Set-Item -LiteralPath "Env:$key" -Value $ExtraEnv[$key] }
    $params = @{
        FilePath               = (Join-Path $PSHOME 'pwsh.exe')
        ArgumentList           = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $script)
        RedirectStandardOutput = $out
        RedirectStandardError  = $err
        NoNewWindow            = $true
        PassThru               = $true
        Wait                   = $true
    }
    if ($StdinFile) { $params.RedirectStandardInput = $StdinFile }
    $p = Start-Process @params
    $result = [pscustomobject]@{
        ExitCode = $p.ExitCode
        Stdout   = if (Test-Path -LiteralPath $out) { Get-Content -LiteralPath $out -Raw } else { '' }
        Stderr   = if (Test-Path -LiteralPath $err) { Get-Content -LiteralPath $err -Raw } else { '' }
    }
    $p.Dispose()
    return $result
}
function Get-JsonResult {
    param($Result, [string]$Label = 'output')
    try { return ($Result.Stdout | ConvertFrom-Json -ErrorAction Stop) }
    catch { throw "$Label is not valid JSON: $($_.Exception.Message)`n$($Result.Stdout)" }
}

function Assert-SingleEnvelope {
    param($Result, [string]$Label = 'stdout')
    $count = [regex]::Matches([string]$Result.Stdout, '"schema"\s*:').Count
    if ($count -ne 1) { throw "$Label must contain exactly one JSON document (found $count)" }
}

function Add-WinMergeState {
    param([string]$InstalledVersion = '2.16.58.2')
    $state = Get-Content -LiteralPath $env:PKGS_FAKE_STATE -Raw | ConvertFrom-Json
    $state.winget.packages = @($state.winget.packages) + [pscustomobject]@{
        id                = 'WinMerge.WinMerge'
        name              = 'WinMerge x64 (Current user, 64-bit)'
        installed_version = $InstalledVersion
    }
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:PKGS_FAKE_STATE -Encoding utf8
}

function Initialize-ScoopGuardRoot {
    param([string]$Mode = 'exact', [switch]$Hold)
    $root = Join-Path $script:TestRoot ('scoop-guard-' + [guid]::NewGuid().ToString('N').Substring(0,8))
    if ($Mode -eq 'file') {
        Set-Content -LiteralPath $root -Value 'not a directory' -Encoding utf8
        return $root
    }
    $null = New-Item -ItemType Directory -Path $root -Force
    if ($Mode -eq 'none') { return $root }
    $leaf = switch ($Mode) {
        'exact' { 'meta-package-manager' }
        'upper' { 'META-PACKAGE-MANAGER' }
        'prefix' { 'meta-package-manager-extra' }
        'punctuation' { 'meta-package-.' }
        'other' { 'other-app' }
        default { 'meta-package-manager' }
    }
    $app = Join-Path $root ($leaf + '\current')
    $null = New-Item -ItemType Directory -Path $app -Force
    $holdValue = if ($Hold) { 'true' } else { 'false' }
    "{`"hold`":$holdValue,`"bucket`":`"main`"}" | Set-Content -LiteralPath (Join-Path $app 'scoop-install.json') -Encoding utf8
    return $root
}

function Invoke-ScoopGuardCase {
    param(
        [string]$State = 'correct',
        [string]$Outdated = 'correct',
        [string]$RootMode = 'exact',
        [switch]$Hold,
        [switch]$Ignore,
        [scriptblock]$Body
    )
    $savedState = $env:PKGS_FAKE_STATE
    $savedSeed = $env:PKGS_FAKE_STATE_SEED
    $savedOutdated = $env:PKGS_FAKE_OUTDATED
    $savedRoot = $env:PKGS_TEST_SCOOP_ROOT
    $savedConfig = $env:PKGS_CONFIG
    $statePath = Join-Path $script:TestRoot ('scoop-guard-state-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
    Copy-Item -LiteralPath (Join-Path $fixtures "scoop-meta-$State.json") -Destination $statePath -Force
    $root = Initialize-ScoopGuardRoot -Mode $RootMode -Hold:$Hold
    $env:PKGS_FAKE_STATE = $statePath
    $env:PKGS_FAKE_STATE_SEED = $statePath
    $env:PKGS_FAKE_OUTDATED = "scoop-meta-outdated-$Outdated.json"
    $env:PKGS_TEST_SCOOP_ROOT = $root
    try {
        if ($Ignore) {
            $cfg = Get-Content -LiteralPath $savedConfig -Raw | ConvertFrom-Json
            $cfg.ignored = @([pscustomobject]@{ manager = 'scoop'; id = 'meta-package-manager'; reason = 'identity-test'; kind = 'ignore'; added = '2026-11-16' })
            $cfgPath = Join-Path $script:TestRoot ('scoop-guard-config-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
            $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $cfgPath -Encoding utf8
            $env:PKGS_CONFIG = $cfgPath
        }
        & $Body
    }
    finally {
        $env:PKGS_FAKE_STATE = $savedState
        $env:PKGS_FAKE_STATE_SEED = $savedSeed
        if ($savedOutdated) { $env:PKGS_FAKE_OUTDATED = $savedOutdated } else { Remove-Item Env:PKGS_FAKE_OUTDATED -ErrorAction Ignore }
        $env:PKGS_TEST_SCOOP_ROOT = $savedRoot
        $env:PKGS_CONFIG = $savedConfig
    }
}

function Initialize-ScoopGuardCacheConfig {
    $cfg = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw | ConvertFrom-Json
    $cfg.cacheTtlSeconds = 86400
    $path = Join-Path $script:TestRoot ('scoop-cache-config-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
    $cfg | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

function Invoke-TestDirectoryDeny {
    param([Parameter(Mandatory)][string]$Path)
    & icacls $Path /deny "$($env:USERNAME):(OI)(CI)(RX)" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not apply temporary deny ACL to $Path" }
}

function Invoke-TestDirectoryDenyRemoval {
    param([Parameter(Mandatory)][string]$Path)
    & icacls $Path /remove:d "$env:USERNAME" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not remove temporary deny ACL from $Path" }
}

function Invoke-TestFileDeny {
    param([Parameter(Mandatory)][string]$Path)
    & icacls $Path /deny "$($env:USERNAME):(R)" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not apply temporary deny ACL to file $Path" }
}

function Invoke-TestFileDenyRemoval {
    param([Parameter(Mandatory)][string]$Path)
    & icacls $Path /remove:d "$env:USERNAME" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "could not remove temporary deny ACL from file $Path" }
}

# ---------------------------------------------------------------------
#  Setup
# ---------------------------------------------------------------------
$null = New-Item -ItemType Directory -Path $script:TestRoot -Force
$fakeScoop = Join-Path $here 'fake-scoop.ps1'
$fakeChoco = Join-Path $script:TestRoot 'fake-choco.ps1'
'exit 0' | Set-Content -LiteralPath $fakeChoco -Encoding utf8

try {
    Write-Host "pkgs test root: $script:TestRoot" -ForegroundColor DarkGray
    $envInfo = New-TestEnvironment

    # -----------------------------------------------------------------
    #  Read-only inventory
    # -----------------------------------------------------------------
    Test-Case 'managers --json exposes the capability matrix' {
        $r = Invoke-Cli @('managers', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-Equal $j.schema 'pkgs/v1' 'schema'
        Assert-True (@($j.managers | Where-Object id -eq 'winget').Count -eq 1) 'winget missing'
        Assert-True (@($j.managers | Where-Object id -eq 'scoop').Count -eq 1) 'scoop missing'
        Assert-True (@($j.managers | Where-Object id -eq 'npm').Count -eq 1) 'npm missing'
        $ms = @($j.managers | Where-Object id -eq 'msstore')
        Assert-True ($ms.Count -eq 1) 'msstore adapter missing'
        Assert-Equal $ms[0].package_count 1 'msstore package count'
    }

    Test-Case 'installed inventory, protection and normalized broken scoop rows' {
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-True ($j.packages.Count -ge 8) 'too few packages'
        $go = @($j.packages | Where-Object target -eq 'winget:GoLang.Go')[0]
        Assert-True $go.protected 'Go should be guard-protected'
        $tool = @($j.packages | Where-Object target -eq 'winget:Example.Tool')[0]
        Assert-True $tool.protected 'Example.Tool should be native-pin protected'
        Assert-Equal $tool.native_pin.mechanism 'winget pin' 'winget pin mechanism'
        $seven = @($j.packages | Where-Object target -eq 'scoop:7zip')[0]
        Assert-True $seven.protected '7zip should be scoop-hold protected'
        Assert-Equal $seven.native_pin.mechanism 'scoop hold' 'scoop hold mechanism'
        $left = @($j.packages | Where-Object target -eq 'npm:left-pad')[0]
        Assert-True $left.protected 'left-pad should be locally ignored'
        $flutter = @($j.packages | Where-Object target -eq 'scoop:flutter')[0]
        Assert-True $flutter.broken 'failed scoop install should be marked broken'
        Assert-Equal $flutter.installed_version '' 'failed scoop version should be blank'
        $store = @($j.packages | Where-Object target -eq 'msstore:9ABCDEF12345')
        Assert-Equal $store.Count 1 'Store package missing'
    }

    Test-Case 'scoop hold metadata supports new and legacy formats' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
$root = Join-Path $env:PKGS_TEST_ROOT 'scoop-hold-fixtures'
$null = New-Item -ItemType Directory -Path $root -Force
function New-App([string]$Name, [string]$File, [string]$Text) {
    $dir = Join-Path $root "$Name\current"
    $null = New-Item -ItemType Directory -Path $dir -Force
    if ($File) { $Text | Set-Content -LiteralPath (Join-Path $dir $File) -Encoding utf8 }
}
New-App 'new-held' 'scoop-install.json' '{"hold":true,"bucket":"main"}'
New-App 'legacy-held' 'install.json' '{"hold":true,"bucket":"main"}'
New-App 'new-unheld' 'scoop-install.json' '{"hold":false,"bucket":"main"}'
New-App 'legacy-unheld' 'install.json' '{"hold":false,"bucket":"main"}'
New-App 'both-new-wins' 'scoop-install.json' '{"hold":false}'
'{"hold":true}' | Set-Content -LiteralPath (Join-Path $root 'both-new-wins\current\install.json') -Encoding utf8
New-App 'both-new-held' 'scoop-install.json' '{"hold":true}'
'{"hold":false}' | Set-Content -LiteralPath (Join-Path $root 'both-new-held\current\install.json') -Encoding utf8
New-App 'missing' '' ''
New-App 'malformed' 'scoop-install.json' '{ not json'
New-App 'legacy-malformed' 'install.json' '{ not json'
New-App 'wrongtype' 'scoop-install.json' '[]'
New-App 'hold-string' 'scoop-install.json' '{"hold":"yes"}'
$report = Get-PkgsScoopHoldReport -Roots @($root)
"PINS=$(@($report.pins | ForEach-Object id | Sort-Object) -join ',')"
"ERRORS=$(@($report.errors | ForEach-Object id | Sort-Object) -join ',')"
$both = @($report.states | Where-Object id -eq 'both-new-wins')[0]
"BOTH_NEW_WINS held=$($both.held) readable=$($both.readable) format=$($both.format)"
$missing = @($report.states | Where-Object id -eq 'missing')[0]
"MISSING held=$($missing.held) readable=$($missing.readable)"
$legacy = @($report.states | Where-Object id -eq 'legacy-held')[0]
"LEGACY held=$($legacy.held) readable=$($legacy.readable) format=$($legacy.format)"
$newUnheld = @($report.states | Where-Object id -eq 'new-unheld')[0]
$legacyUnheld = @($report.states | Where-Object id -eq 'legacy-unheld')[0]
"UNHELD new=$($newUnheld.held)/$($newUnheld.readable) legacy=$($legacyUnheld.held)/$($legacyUnheld.readable)"
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'PINS=both-new-held,legacy-held,new-held' 'held pins'
        Assert-Match $r.Stdout 'ERRORS=hold-string,legacy-malformed,malformed,missing,wrongtype' 'unreadable metadata'
        Assert-Match $r.Stdout 'BOTH_NEW_WINS held=False readable=True format=scoop-install\.json' 'new metadata preference'
        Assert-Match $r.Stdout 'MISSING held=False readable=False' 'missing metadata must be unknown'
        Assert-Match $r.Stdout 'LEGACY held=True readable=True format=install\.json' 'legacy metadata'
        Assert-Match $r.Stdout 'UNHELD new=False/True legacy=False/True' 'unheld metadata'
    }

    Test-Case 'unreadable scoop metadata blocks a mutation' {
        $badRoot = Join-Path $script:TestRoot 'scoop-unreadable\apps'
        $badDir = Join-Path $badRoot 'shared.app\current'
        $null = New-Item -ItemType Directory -Path $badDir -Force
        '{ not json' | Set-Content -LiteralPath (Join-Path $badDir 'scoop-install.json') -Encoding utf8
        $oldRoot = $env:PKGS_TEST_SCOOP_ROOT
        try {
            $env:PKGS_TEST_SCOOP_ROOT = $badRoot
            $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 6 'dry-run exit'
            $j = Get-JsonResult $r
            Assert-True $j.plan[0].blocked 'unreadable protection state was treated as unprotected'
            Assert-Match $j.plan[0].reason 'protection state is unreadable' 'reason'
        }
        finally {
            $env:PKGS_TEST_SCOOP_ROOT = $oldRoot
            Remove-Item -LiteralPath (Join-Path $env:PKGS_CACHE_DIR 'snapshot.json') -Force -ErrorAction Ignore
        }
    }

    Test-Case 'classification distinguishes VS Code extensions from applications' {
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        $ext = @($j.packages | Where-Object target -eq 'vscode:commandcode.commandcode-vscode')[0]
        Assert-True ($null -ne $ext) 'extension record missing'
        Assert-Equal $ext.type 'VS Code Ext' 'extension type'
        Assert-Equal $ext.manager 'vscode' 'extension manager id'
        Assert-Equal $ext.manager_name 'Visual Studio Code' 'extension manager name'
        Assert-Equal $ext.display_name 'Command Code for VS Code' 'verified manifest name'
        Assert-Equal $ext.name_source 'extension manifest' 'name source'
        $app = @($j.packages | Where-Object target -eq 'winget:Microsoft.VisualStudioCode')[0]
        Assert-True ($null -ne $app) 'application record missing'
        Assert-Equal $app.type 'WinGet Package' 'application type'
        Assert-Equal $app.manager_name 'WinGet' 'application manager'
        Assert-True ($app.target -ne $ext.target) 'extension and application identity must differ'
        $remote = @($j.packages | Where-Object target -eq 'vscode:ms-vscode-remote.remote-containers')[0]
        Assert-Equal $remote.display_name 'ms-vscode-remote.remote-containers' 'untranslated manifest name must fall back to canonical id'
        Assert-True ($j.inventory.total_records -eq 16) 'inventory total'
        Assert-True ($j.inventory.visible_records -eq 16) 'inventory visible'
        Assert-True ($j.inventory.hidden_pip_records -eq 0) 'inventory pip'
        Assert-True ($j.inventory.outdated_records -eq 7) 'inventory outdated'
        Assert-True ($j.inventory.protected_records -eq 5) 'inventory protected'
        Assert-True ($j.inventory.manual_update_records -eq 0) 'inventory manual updates'
        Assert-True ($j.inventory.unsupported_update_records -eq 4) 'inventory unsupported'
        Assert-True ($j.inventory.unknown_update_records -eq 1) 'inventory unknown'
        Assert-True ($j.inventory.broken_records -eq 1) 'inventory broken'
        Assert-True ($j.inventory.duplicate_source_rows -eq 1) 'inventory duplicate source rows'
        Assert-True ($j.inventory.managers_detected -eq 8) 'inventory detected managers'
        Assert-True ($j.inventory.managers_active -eq 7) 'inventory active managers'
        Assert-True ($j.inventory.managers_excluded -eq 1) 'inventory excluded managers'
        Assert-True ($j.inventory.visible_records + $j.inventory.hidden_pip_records -eq $j.inventory.total_records) 'inventory reconciliation'
    }

    Test-Case 'unsupported and unknown update states are not called current' {
        $r = Invoke-Cli @('installed', '--json')
        $j = Get-JsonResult $r
        $cargo = @($j.packages | Where-Object target -eq 'cargo:cargo-binstall')[0]
        Assert-Equal $cargo.update_state 'unsupported' 'cargo state'
        Assert-Equal $cargo.available_display 'Not available' 'cargo available'
        Assert-Equal $cargo.status_label 'No update check' 'cargo status'
        $micro = @($j.packages | Where-Object target -eq 'micro:linter')[0]
        Assert-Equal $micro.installed_display 'Unknown' 'micro installed'
        Assert-Equal $micro.update_state 'unsupported' 'micro state'
        $cloud = @($j.packages | Where-Object target -eq 'winget:Google.CloudSDK')[0]
        Assert-Equal $cloud.update_state 'unknown' 'cloud state'
        Assert-Equal $cloud.status_label 'Version unknown' 'cloud status'
        Assert-True (-not $cloud.broken) 'unknown version must not be called broken'
        $vscode = @($j.packages | Where-Object target -eq 'vscode:commandcode.commandcode-vscode')[0]
        Assert-Equal $vscode.available_display 'Not available' 'vscode available'
        Assert-True ($vscode.status_label -notmatch '[!*~?]') 'status must not use unexplained symbols'
        $pinned = @($j.packages | Where-Object target -eq 'winget:Example.Tool')[0]
        Assert-True ($pinned.status_label -like 'Protected (pin)*') 'native pin must be visible in status'
        $guarded = @($j.packages | Where-Object target -eq 'winget:GoLang.Go')[0]
        Assert-True ($guarded.status_label -like 'Protected (guard)*') 'guard must be visible in status'
    }

    Test-Case 'outdated inventory drops malformed backend versions' {
        $r = Invoke-Cli @('outdated', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-True (@($j.packages | Where-Object target -eq 'scoop:7zip').Count -eq 1) '7zip outdated entry missing'
        Assert-True (@($j.packages | Where-Object target -eq 'winget:Bad.Version').Count -eq 0) 'malformed entry must be dropped'
        $wingetMgr = @($j.managers | Where-Object id -eq 'winget')[0]
        Assert-Match ((@($wingetMgr.anomalies) -join ' ')) 'malformed outdated entry' 'malformed anomaly not recorded'
    }

    Test-Case 'empty outdated result is valid and empty' {
        $env:PKGS_FAKE_OUTDATED = 'outdated-empty.json'
        $r = Invoke-Cli @('outdated', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-Equal $j.packages.Count 0 'expected no outdated packages'
    }

    Test-Case 'malformed installed output fails clearly' {
        $env:PKGS_FAKE_INSTALLED = 'malformed'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        Assert-Match ($r.Stdout + $r.Stderr) 'malformed JSON' 'error should mention malformed JSON'
    }

    Test-Case 'manager errors are surfaced and --strict exits 5' {
        $env:PKGS_FAKE_INSTALLED = 'installed-errors.json'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 0 'non-strict exit'
        $j = Get-JsonResult $r
        Assert-True (@($j.errors).Count -gt 0) 'errors missing'
        $r2 = Invoke-Cli @('installed', '--json', '--strict')
        Assert-Equal $r2.ExitCode 5 'strict exit'
    }

    Test-Case 'missing mpm fails clearly with exit 5' {
        $env:PKGS_TEST_MPM = Join-Path $script:TestRoot 'does-not-exist.ps1'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified|failed to start|not found' 'missing backend message'
    }

    Test-Case 'mpm parses colored banner and admits supported version' {
        $esc = [string][char]27
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = "    ${esc}[38;5;189mART${esc}[0m    ${esc}[97mmpm, version ${esc}[32m8.3.0${esc}[0m"
        $r = Invoke-Cli @('version')
        Assert-Equal $r.ExitCode 0 'version exit'
        Assert-Match $r.Stdout 'mpm 8\.3\.0 at ' 'mpm should be detected from colored output'
        $installed = Invoke-Cli @('installed', '--json')
        Assert-Equal $installed.ExitCode 0 'supported backend must admit inventory'
    }

    Test-Case 'mpm allows supported newer numeric version' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = 'mpm, version 8.4.1'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 0 'newer backend version'
    }

    Test-Case 'mpm rejects older backend before inventory' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = 'mpm, version 8.2.9'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'old backend must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'too old' 'old-version refusal'
    }

    Test-Case 'mpm rejects unrecognized backend version' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = 'mpm, version unknown'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'unrecognized backend must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified' 'unrecognized-version refusal'
    }

    Test-Case 'mpm rejects version probe with nonzero exit' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = 'mpm, version 8.3.0'
        $env:PKGS_FAKE_MPM_VERSION_EXIT = '17'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'version probe failure must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified' 'probe-failure refusal'
    }

    Test-Case 'mpm rejects conflicting version labels' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = "mpm, version 8.3.0`nmpm, version 9.0.0"
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'ambiguous backend version must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified' 'ambiguous-version refusal'
    }

    Test-Case 'mpm rejects unqualified prerelease version' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = 'mpm, version 8.3.0.dev1'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'prerelease backend must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified' 'prerelease refusal'
    }

    Test-Case 'mpm rejects hyphenated prerelease without accepting numeric prefix' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = 'mpm, version 8.3.0-rc1'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'hyphenated prerelease must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified' 'hyphenated prerelease refusal'
    }

    Test-Case 'mpm rejects local build suffix without accepting numeric prefix' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = 'mpm, version 8.3.0+local'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'local build version must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified' 'local build refusal'
    }

    Test-Case 'mpm rejects mixed malformed and valid version labels' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = "mpm, version unknown`nmpm, version 8.3.0"
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'mixed malformed and valid labels must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified' 'mixed labels refusal'
    }

    Test-Case 'mpm rejects version text without program identity' {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT = 'Version 8.3.0'
        $r = Invoke-Cli @('installed', '--json')
        Assert-Equal $r.ExitCode 5 'unqualified banner must fail closed'
        Assert-Match ($r.Stdout + $r.Stderr) 'version could not be verified' 'unqualified-version refusal'
    }

    Test-Case 'unknown manager filter is a usage error' {
        $env:PKGS_FAKE_MANAGERS = 'managers-npm.txt'
        $env:PKGS_FAKE_INSTALLED = 'installed-npm.json'
        $env:PKGS_FAKE_OUTDATED = 'outdated-empty.json'
        $r = Invoke-Cli @('installed', '--manager', 'winget', '--json')
        Assert-Equal $r.ExitCode 2 'exit code'
        Assert-Match ($r.Stdout + $r.Stderr) "unknown manager 'winget'" 'message'
    }

    # -----------------------------------------------------------------
    #  Identity and protection
    # -----------------------------------------------------------------
    Test-Case 'duplicate identity across managers is refused without qualification' {
        $r = Invoke-Cli @('upgrade', 'shared.app', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 4 'exit code'
        Assert-Match ($r.Stdout + $r.Stderr) 'multiple managers' 'ambiguity message'
    }

    Test-Case 'qualified duplicate identity plans exactly one manager' {
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-Equal @($j.plan).Count 1 'plan size'
        Assert-Equal $j.plan[0].target 'scoop:shared.app' 'target'
        Assert-Match $j.plan[0].native '^scoop update shared\.app$' 'native command'
        Assert-Match $j.plan[0].invocation '^mpm --scoop upgrade shared\.app$' 'invocation'
    }

    Test-Case 'native winget pin is a hard block' {
        $r = Invoke-Cli @('upgrade', 'winget:Example.Tool', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'plan should be blocked'
        Assert-Match $j.plan[0].reason 'native pin' 'reason'
    }

    Test-Case 'native pin protection is reported before outdated filtering' {
        $env:PKGS_FAKE_OUTDATED = 'outdated-empty.json'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'winget:Example.Tool', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'plan should be blocked'
        Assert-True $j.plan[0].protected 'plan should report protection'
        Assert-Equal $j.exit_code 6 'JSON exit code'
        Assert-Match $j.plan[0].reason 'native pin' 'reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'backend was invoked for a protected target'
    }

    Test-Case 'native scoop hold is a hard block' {
        $r = Invoke-Cli @('upgrade', 'scoop:7zip', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        $j = Get-JsonResult $r
        Assert-Match $j.plan[0].reason 'native pin' 'reason'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r2 = Invoke-Cli @('remove', 'scoop:7zip', '--yes')
        Assert-Equal $r2.ExitCode 6 'remove exit'
        Assert-Match ($r2.Stdout + $r2.Stderr) 'native pin' 'remove reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'protected remove invoked the backend'
    }

    Test-Case 'guard protection blocks non-dry mutation and needs an override' {
        $r = Invoke-Cli @('upgrade', 'winget:GoLang.Go')
        Assert-Equal $r.ExitCode 6 'exit code'
        $r2 = Invoke-Cli @('upgrade', 'winget:GoLang.Go', '--override-protection')
        Assert-Equal $r2.ExitCode 3 'override without --yes must still need confirmation'
        $r3 = Invoke-Cli @('upgrade', 'winget:GoLang.Go', '--dry-run', '--json')
        Assert-Equal $r3.ExitCode 6 'guard dry-run exit'
        $j3 = Get-JsonResult $r3
        Assert-True (-not $j3.ok) 'guard dry-run JSON must be false'
        Assert-Equal $j3.exit_code 6 'guard dry-run JSON exit code'
        Assert-Match $j3.plan[0].reason 'protected by pkgs' 'guard dry-run reason'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r4 = Invoke-Cli @('remove', 'winget:GoLang.Go', '--yes')
        Assert-Equal $r4.ExitCode 6 'guard remove exit'
        Assert-Match ($r4.Stdout + $r4.Stderr) 'protected by pkgs' 'guard remove reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'guard remove invoked the backend'
    }

    Test-Case 'local ignore marks the target and blocks normal upgrade' {
        $r = Invoke-Cli @('upgrade', 'npm:left-pad', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 6 'dry-run exit'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'plan should be blocked'
        Assert-True (-not $j.ok) 'ignore dry-run JSON must be false'
        Assert-Equal $j.exit_code 6 'ignore dry-run JSON exit code'
        Assert-Match $j.plan[0].reason 'protected by pkgs' 'reason'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r2 = Invoke-Cli @('remove', 'npm:left-pad', '--yes')
        Assert-Equal $r2.ExitCode 6 'ignore remove exit'
        Assert-Match ($r2.Stdout + $r2.Stderr) 'protected by pkgs' 'ignore remove reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'ignored remove invoked the backend'
    }

    # -----------------------------------------------------------------
    #  Mutations (test doubles only)
    # -----------------------------------------------------------------
    Test-Case 'non-interactive mutation without --yes exits 3 and does nothing' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app')
        Assert-Equal $r.ExitCode 3 'exit code'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'backend was invoked without confirmation'
    }

    Test-Case 'non-dry JSON native pin refusal is one valid envelope' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'winget:Example.Tool', '--yes', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        $j = Get-JsonResult $r
        Assert-Equal $j.schema 'pkgs/v1' 'schema'
        Assert-Equal $j.command 'upgrade' 'command'
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 6 'JSON exit code'
        Assert-Equal $j.dry_run $false 'dry_run must be false'
        Assert-True $j.plan[0].blocked 'plan must be blocked'
        Assert-True $j.plan[0].protected 'plan must be protected'
        Assert-Match $j.plan[0].reason 'native pin' 'reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'backend was invoked for a protected target'
    }

    Test-Case 'non-dry JSON local ignore refusal is one valid envelope' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $null = Invoke-Cli @('ignore', 'winget:shared.app', '--yes')
        try {
            $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--yes', '--json')
            Assert-Equal $r.ExitCode 6 'exit code'
            $j = Get-JsonResult $r
            Assert-Equal $j.command 'upgrade' 'command'
            Assert-True (-not $j.ok) 'ok must be false'
            Assert-Equal $j.exit_code 6 'JSON exit code'
            Assert-True $j.plan[0].blocked 'plan must be blocked'
            Assert-True $j.plan[0].protected 'plan must be protected'
            Assert-Match $j.plan[0].reason 'protected by pkgs' 'reason'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'backend was invoked for an ignored target'
        }
        finally {
            $null = Invoke-Cli @('ignore', '--remove', 'winget:shared.app', '--yes')
        }
    }

    Test-Case 'non-dry JSON scoop hold refusal is one valid envelope' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:7zip', '--yes', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        $j = Get-JsonResult $r
        Assert-Equal $j.command 'upgrade' 'command'
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 6 'JSON exit code'
        Assert-True $j.plan[0].protected 'plan must be protected'
        Assert-Match $j.plan[0].reason 'native pin' 'reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'backend was invoked for a held target'
    }

    Test-Case 'non-dry JSON unreadable protection refusal is one valid envelope' {
        $env:PKGS_FAKE_WINGET_PIN_LIST = 'winget-pins-malformed.txt'
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 6 'JSON exit code'
        Assert-True $j.plan[0].protected 'plan must be protected'
        Assert-Match $j.plan[0].reason 'protection state is unreadable' 'reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'backend was invoked with unreadable protection'
    }

    Test-Case 'non-dry JSON guard refusal is one valid envelope' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'winget:GoLang.Go', '--yes', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 6 'JSON exit code'
        Assert-True $j.plan[0].protected 'plan must be protected'
        Assert-Match $j.plan[0].reason 'protected by pkgs' 'reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'backend was invoked for a guarded target'
    }

    Test-Case 'protected mixed-target JSON batch performs no writes' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'winget:Example.Tool', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        $j = Get-JsonResult $r
        Assert-Equal @($j.plan).Count 2 'plan size'
        Assert-True @($j.plan | Where-Object { $_.blocked }).Count -eq 1 'one blocked target'
        Assert-Match (@($j.plan | Where-Object { $_.blocked })[0].reason) 'native pin' 'blocked reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'a mixed protected batch invoked the backend'
    }

    Test-Case 'missing --yes JSON output is a valid failure envelope' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--json')
        Assert-Equal $r.ExitCode 3 'exit code'
        $j = Get-JsonResult $r
        Assert-Equal $j.schema 'pkgs/v1' 'schema'
        Assert-Equal $j.command 'upgrade' 'command'
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 3 'JSON exit code'
        Assert-Equal $j.dry_run $false 'dry_run must be false'
        Assert-Equal @($j.plan).Count 1 'plan size'
        Assert-Match ([string]$j.message) 'requires --yes' 'message'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'missing confirmation invoked the backend'
    }

    Test-Case 'stale target non-dry JSON is a valid failure envelope' {
        $env:PKGS_FAKE_OUTDATED = 'outdated-empty.json'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 5 'JSON exit code'
        Assert-Equal $j.dry_run $false 'dry_run must be false'
        Assert-True $j.plan[0].blocked 'plan must be blocked'
        Assert-Match $j.plan[0].reason 'not reported as outdated' 'reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'stale target invoked the backend'
    }

    Test-Case 'mutation backend output does not contaminate JSON' {
        $env:PKGS_FAKE_MUTATION_OUTPUT = 'backend-output-line'
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'success JSON'
        Assert-Equal $j.exit_code 0 'JSON exit code'
        Assert-Equal $j.dry_run $false 'dry_run must be false'
        Assert-Match $r.Stderr 'backend-output-line' 'backend output must be on stderr'
        Assert-True ($r.Stdout.TrimStart().StartsWith('{')) 'stdout must begin with a JSON envelope'
    }


    Test-Case 'interactive JSON mutation without --yes refuses without prompting' {
        $env:PKGS_TEST_TTY = '1'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--json')
        Assert-Equal $r.ExitCode 3 'exit code'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 3 'JSON exit code'
        Assert-Equal $j.dry_run $false 'dry_run must be false'
        Assert-Equal @($j.plan).Count 1 'plan size'
        Assert-Match ([string]$j.message) 'requires --yes' 'message'
        Assert-True (($r.Stdout + $r.Stderr) -notmatch 'Proceed\?') 'JSON mode prompted for confirmation'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'missing --yes invoked the backend'
    }

    Test-Case 'interactive JSON mutation with --yes executes without prompting' {
        $env:PKGS_TEST_TTY = '1'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-True $j.ok 'mutation should succeed'
        Assert-Equal $j.exit_code 0 'JSON exit code'
        Assert-Equal $j.dry_run $false 'dry_run must be false'
        Assert-Equal @($j.results).Count 1 'results size'
        Assert-True (($r.Stdout + $r.Stderr) -notmatch 'Proceed\?') 'JSON mode prompted for confirmation'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log '--scoop upgrade shared\.app' 'exact mpm invocation'
        Assert-True ($log -notmatch '--all') 'bulk mutation'
    }

    Test-Case 'interactive JSON native pin refuses without prompting' {
        $env:PKGS_TEST_TTY = '1'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'winget:Example.Tool', '--yes', '--json')
        Assert-Equal $r.ExitCode 6 'exit code'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 6 'JSON exit code'
        Assert-True $j.plan[0].blocked 'plan must be blocked'
        Assert-True $j.plan[0].protected 'plan must report protection'
        Assert-Match $j.plan[0].reason 'native pin' 'reason'
        Assert-True (($r.Stdout + $r.Stderr) -notmatch 'Proceed\?') 'JSON mode prompted for confirmation'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'protected target invoked the backend'
    }

    Test-Case 'interactive non-JSON mutation cancellation is preserved' {
        $env:PKGS_TEST_TTY = '1'
        $stdin = Join-Path $script:TestRoot 'mutation-cancel-answer.txt'
        "n`n" | Set-Content -LiteralPath $stdin -Encoding utf8
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app') -StdinFile $stdin
        Assert-Equal $r.ExitCode 0 'cancelled mutation must exit 0'
        Assert-True ($r.Stdout -notmatch '"schema"') 'cancellation emitted JSON'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'cancelled mutation invoked the backend'
    }

    Test-Case 'JSON protection override cannot authorize local protection' {
        $env:PKGS_TEST_TTY = '1'
        $null = Invoke-Cli @('ignore', 'scoop:shared.app', '--yes')
        try {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes', '--override-protection', '--json')
            Assert-Equal $r.ExitCode 6 'exit code'
            Assert-SingleEnvelope $r
            $j = Get-JsonResult $r
            Assert-True (-not $j.ok) 'ok must be false'
            Assert-Equal $j.exit_code 6 'JSON exit code'
            Assert-True $j.plan[0].blocked 'plan must be blocked'
            Assert-True $j.plan[0].protected 'plan must report protection'
            Assert-Match $j.plan[0].reason 'cannot be authorized in JSON mode' 'reason'
            Assert-Match ([string]$j.message) 'not honored in JSON mode' 'message'
            Assert-True (($r.Stdout + $r.Stderr) -notmatch 'Type .OVERRIDE.') 'typed override prompt was shown'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'override refusal invoked the backend'
        }
        finally {
            $null = Invoke-Cli @('ignore', '--remove', 'scoop:shared.app', '--yes')
        }
    }

    Test-Case 'explicit --json parse error is one machine-readable envelope' {
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--json', '--bogus')
        Assert-Equal $r.ExitCode 2 'exit code'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-Equal $j.schema 'pkgs/v1' 'schema'
        Assert-Equal $j.command 'upgrade' 'command'
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 2 'JSON exit code'
        Assert-Equal $j.error.code 2 'error code'
        Assert-Match ([string]$j.error.message) "unknown option '--bogus'" 'error message'
        Assert-True ($r.Stdout -notmatch '"plan"') 'pre-plan error fabricated a plan'
    }

    Test-Case 'parse error before --json is still machine-readable' {
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--bogus', '--json')
        Assert-Equal $r.ExitCode 2 'exit code'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-Equal $j.command 'upgrade' 'command'
        Assert-Equal $j.exit_code 2 'JSON exit code'
        Assert-Match ([string]$j.error.message) 'unknown option' 'error message'
    }

    Test-Case 'JSON target resolution error is an error-only envelope' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('remove', 'scoop:missing.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 4 'exit code'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-Equal $j.schema 'pkgs/v1' 'schema'
        Assert-Equal $j.command 'remove' 'command'
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 4 'JSON exit code'
        Assert-Equal $j.error.code 4 'error code'
        Assert-Match ([string]$j.error.message) 'not installed' 'error message'
        Assert-True ($r.Stdout -notmatch '"plan"') 'pre-plan error fabricated a plan'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'resolution error invoked the backend'
    }

    Test-Case 'literal --json after -- is not a JSON request' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('remove', 'scoop:shared.app', '--yes', '--', '--json')
        Assert-Equal $r.ExitCode 4 'exit code'
        Assert-True ($r.Stdout -notmatch '"schema"') 'literal argument enabled JSON mode'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'literal argument reached the backend'
    }

    Test-Case 'interactive JSON pin without --yes refuses without prompting' {
        $env:PKGS_TEST_TTY = '1'
        $before = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw
        $r = Invoke-Cli @('pin', 'scoop:shared.app', '--json')
        Assert-Equal $r.ExitCode 3 'exit code'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 3 'JSON exit code'
        Assert-Match ([string]$j.error.message) 'requires --yes' 'error message'
        Assert-True (($r.Stdout + $r.Stderr) -notmatch "Type 'PIN'") 'JSON mode prompted'
        Assert-Equal (Get-Content -LiteralPath $env:PKGS_CONFIG -Raw) $before 'JSON mode changed protection state'
    }

    Test-Case 'interactive JSON ignore without --yes refuses without prompting' {
        $env:PKGS_TEST_TTY = '1'
        $before = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw
        $r = Invoke-Cli @('ignore', 'scoop:shared.app', '--json')
        Assert-Equal $r.ExitCode 3 'exit code'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-Equal $j.command 'ignore' 'command'
        Assert-True (-not $j.ok) 'ok must be false'
        Assert-Equal $j.exit_code 3 'JSON exit code'
        Assert-Match ([string]$j.error.message) 'requires --yes' 'error message'
        Assert-True (($r.Stdout + $r.Stderr) -notmatch 'Apply this protection change') 'JSON mode prompted'
        Assert-Equal (Get-Content -LiteralPath $env:PKGS_CONFIG -Raw) $before 'JSON mode changed protection state'
    }

    Test-Case 'Scoop identity guard allows an exact installed directory' {
        Invoke-ScoopGuardCase -State 'correct' -Outdated 'correct' -RootMode 'exact' -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-manager', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 0 'exit code'
            $j = Get-JsonResult $r
            Assert-True $j.ok 'valid target must be ready'
            Assert-Equal $j.plan[0].target 'scoop:meta-package-manager' 'target'
            Assert-True (-not $j.plan[0].blocked) 'valid target must not be blocked'
            Assert-Match ([string]$j.plan[0].invocation) 'mpm --scoop upgrade meta-package-manager' 'invocation'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'dry-run invoked the backend'
        }
    }

    Test-Case 'Scoop identity guard blocks a truncated cached and fresh ID' {
        Invoke-ScoopGuardCase -State 'truncated' -Outdated 'truncated' -RootMode 'exact' -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            foreach ($operation in @('upgrade', 'remove')) {
                $r = Invoke-Cli @($operation, 'scoop:meta-package-.', '--dry-run', '--json')
                Assert-Equal $r.ExitCode 5 "$operation exit code"
                Assert-SingleEnvelope $r
                $j = Get-JsonResult $r
                Assert-True (-not $j.ok) "$operation must fail"
                Assert-Equal $j.exit_code 5 "$operation JSON exit code"
                Assert-True $j.plan[0].blocked "$operation must be blocked"
                Assert-Match $j.plan[0].reason 'Scoop installed identity is not corroborated' "$operation reason"
                Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) "$operation invoked the backend"
            }
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-.', '--yes', '--json')
            Assert-Equal $r.ExitCode 5 'non-dry upgrade exit code'
            $j = Get-JsonResult $r
            Assert-True (-not $j.ok) 'non-dry upgrade must fail'
            Assert-True ($j.PSObject.Properties.Name -notcontains 'results') 'non-dry upgrade fabricated results'
            $r = Invoke-Cli @('remove', 'scoop:meta-package-.', '--yes', '--json')
            Assert-Equal $r.ExitCode 5 'non-dry remove exit code'
            $j = Get-JsonResult $r
            Assert-True (-not $j.ok) 'non-dry remove must fail'
            Assert-True ($j.PSObject.Properties.Name -notcontains 'results') 'non-dry remove fabricated results'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'non-dry operations invoked the backend'
        }
    }

    Test-Case 'Scoop identity guard blocks truncated IDs before native hold protection' {
        Invoke-ScoopGuardCase -State 'truncated' -Outdated 'truncated' -RootMode 'exact' -Hold -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-.', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 5 'exit code'
            $j = Get-JsonResult $r
            Assert-True $j.plan[0].blocked 'plan must be blocked'
            Assert-Match $j.plan[0].reason 'Scoop installed identity is not corroborated' 'identity reason'
            Assert-True ($j.plan[0].reason -notmatch 'native pin') 'identity refusal must not claim a native pin'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'hold bypass reached the backend'
        }
    }

    Test-Case 'Scoop identity guard blocks truncated IDs before local-ignore protection' {
        Invoke-ScoopGuardCase -State 'truncated' -Outdated 'truncated' -RootMode 'exact' -Ignore -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-.', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 5 'exit code'
            $j = Get-JsonResult $r
            Assert-True $j.plan[0].blocked 'plan must be blocked'
            Assert-Match $j.plan[0].reason 'Scoop installed identity is not corroborated' 'identity reason'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'ignore bypass reached the backend'
        }
    }

    Test-Case 'Scoop identity guard blocks a missing exact app directory' {
        Invoke-ScoopGuardCase -State 'correct' -Outdated 'correct' -RootMode 'none' -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-manager', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 5 'exit code'
            $j = Get-JsonResult $r
            Assert-True $j.plan[0].blocked 'missing directory must block'
            Assert-Match $j.plan[0].reason 'exact Scoop app directory' 'missing-directory reason'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'missing directory reached the backend'
        }
    }

    Test-Case 'Scoop identity guard rejects prefix and punctuation lookalikes' {
        foreach ($mode in @('prefix', 'punctuation', 'other')) {
            Invoke-ScoopGuardCase -State 'correct' -Outdated 'correct' -RootMode $mode -Body {
                Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
                $r = Invoke-Cli @('upgrade', 'scoop:meta-package-manager', '--dry-run', '--json')
                Assert-Equal $r.ExitCode 5 "$mode exit code"
                $j = Get-JsonResult $r
                Assert-True $j.plan[0].blocked "$mode must be blocked"
                Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) "$mode reached the backend"
            }
        }
    }

    Test-Case 'Scoop identity guard uses case-insensitive exact directory matching' {
        Invoke-ScoopGuardCase -State 'correct' -Outdated 'correct' -RootMode 'upper' -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-manager', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 0 'exit code'
            $j = Get-JsonResult $r
            Assert-True $j.ok 'case-insensitive directory must be accepted'
            Assert-True (-not $j.plan[0].blocked) 'case-insensitive directory must not be blocked'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'dry-run invoked the backend'
        }
    }

    Test-Case 'Scoop truncated display name does not change canonical identity' {
        Invoke-ScoopGuardCase -State 'correct-truncated-name' -Outdated 'correct' -RootMode 'exact' -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json')
            Assert-Equal $r.ExitCode 0 'installed exit code'
            $j = Get-JsonResult $r
            $pkg = @($j.packages | Where-Object { $_.target -eq 'scoop:meta-package-manager' })[0]
            Assert-True ($null -ne $pkg) 'canonical record missing'
            Assert-Equal $pkg.display_name 'meta-package-.' 'display name should be truncated'
            Assert-Equal $pkg.id 'meta-package-manager' 'canonical id changed'
            Assert-Equal $pkg.target 'scoop:meta-package-manager' 'canonical target changed'
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-manager', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 0 'upgrade exit code'
            $j = Get-JsonResult $r
            Assert-True $j.ok 'canonical target should be ready'
            Assert-True (-not $j.plan[0].blocked) 'canonical target must not be blocked'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'dry-run invoked the backend'
        }
    }

    Test-Case 'Scoop cached truncation is rejected when fresh identity is correct' {
        Invoke-ScoopGuardCase -State 'correct' -Outdated 'correct' -RootMode 'exact' -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            Copy-Item -LiteralPath (Join-Path $fixtures 'scoop-meta-truncated.json') -Destination $env:PKGS_FAKE_STATE -Force
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json', '--refresh')
            Assert-Equal $r.ExitCode 0 'cache build exit code'
            $j = Get-JsonResult $r
            Assert-Equal (@($j.packages | Where-Object { $_.target -eq 'scoop:meta-package-.' })[0].id) 'meta-package-.' 'cached truncation setup'
            Copy-Item -LiteralPath (Join-Path $fixtures 'scoop-meta-correct.json') -Destination $env:PKGS_FAKE_STATE -Force
            $env:PKGS_CONFIG = Initialize-ScoopGuardCacheConfig
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-.', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 5 'stale identity exit code'
            $j = Get-JsonResult $r
            Assert-True $j.plan[0].blocked 'stale identity must be blocked'
            Assert-Match $j.plan[0].reason 'not reported as outdated' 'stale identity reason'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'stale identity reached the backend'
        }
    }

    Test-Case 'Scoop fresh truncation is rejected when cache is correct' {
        Invoke-ScoopGuardCase -State 'correct' -Outdated 'correct' -RootMode 'exact' -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json', '--refresh')
            Assert-Equal $r.ExitCode 0 'cache build exit code'
            Copy-Item -LiteralPath (Join-Path $fixtures 'scoop-meta-truncated.json') -Destination $env:PKGS_FAKE_STATE -Force
            $env:PKGS_FAKE_OUTDATED = 'scoop-meta-outdated-truncated.json'
            $env:PKGS_CONFIG = Initialize-ScoopGuardCacheConfig
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-manager', '--dry-run', '--json')
            Assert-Equal $r.ExitCode 5 'fresh identity exit code'
            $j = Get-JsonResult $r
            Assert-True $j.plan[0].blocked 'fresh identity must be blocked'
            Assert-Match $j.plan[0].reason 'not reported as outdated' 'fresh identity reason'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'fresh identity reached the backend'
        }
    }

    Test-Case 'Scoop identity helper handles user, global, ambiguous and unreadable roots' {
        $exact1 = Initialize-ScoopGuardRoot -Mode 'exact'
        $exact2 = Initialize-ScoopGuardRoot -Mode 'exact'
        $upper = Initialize-ScoopGuardRoot -Mode 'upper'
        $prefix = Initialize-ScoopGuardRoot -Mode 'prefix'
        $fileRoot = Initialize-ScoopGuardRoot -Mode 'file'
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
$exact1 = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_EXACT1, $env:R_MISSING)
$exact2 = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_MISSING, $env:R_EXACT2)
$ambiguous = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_EXACT1, $env:R_EXACT2)
$upper = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_UPPER)
$prefix = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_PREFIX)
$fileRoot = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_FILE)
$traversal = Get-PkgsScoopIdentityEvidence -Id '..\meta-package-manager' -Roots @($env:R_EXACT1)
$wildcard = Get-PkgsScoopIdentityEvidence -Id 'meta-*' -Roots @($env:R_EXACT1)
"USER_OK=$($exact1.ok) MATCH=$($exact1.matchCount)"
"GLOBAL_OK=$($exact2.ok) MATCH=$($exact2.matchCount)"
"AMBIGUOUS_OK=$($ambiguous.ok) MATCH=$($ambiguous.matchCount)"
"UPPER_OK=$($upper.ok) MATCH=$($upper.matchCount)"
"PREFIX_OK=$($prefix.ok) MATCH=$($prefix.matchCount)"
"FILE_OK=$($fileRoot.ok) MATCH=$($fileRoot.matchCount) REASON=$($fileRoot.reason)"
"TRAVERSAL_OK=$($traversal.ok) MATCH=$($traversal.matchCount)"
"WILDCARD_OK=$($wildcard.ok) MATCH=$($wildcard.matchCount)"
'@
        $r = Invoke-UiHelper -Body $body -ExtraEnv @{
            R_EXACT1 = $exact1; R_EXACT2 = $exact2; R_UPPER = $upper; R_PREFIX = $prefix; R_FILE = $fileRoot
            R_MISSING = (Join-Path $script:TestRoot 'scoop-missing-root')
        }
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'USER_OK=True MATCH=1' 'user root'
        Assert-Match $r.Stdout 'GLOBAL_OK=True MATCH=1' 'global root'
        Assert-Match $r.Stdout 'AMBIGUOUS_OK=False MATCH=2' 'ambiguous roots'
        Assert-Match $r.Stdout 'UPPER_OK=True MATCH=1' 'case-insensitive root'
        Assert-Match $r.Stdout 'PREFIX_OK=False MATCH=0' 'prefix root'
        Assert-Match $r.Stdout 'FILE_OK=False MATCH=0 REASON=.*not a directory' 'unreadable/file root'
        Assert-Match $r.Stdout 'TRAVERSAL_OK=False MATCH=0' 'traversal-like id was treated as a path'
        Assert-Match $r.Stdout 'WILDCARD_OK=False MATCH=0' 'wildcard id was treated as a pattern'
    }

    Test-Case 'Scoop pre-execution identity guard rejects a directory that disappeared' {
        $root = Initialize-ScoopGuardRoot -Mode 'exact'
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
Remove-Item -LiteralPath (Join-Path $env:PKGS_TEST_SCOOP_ROOT 'meta-package-manager') -Recurse -Force
$entry = [pscustomobject]@{ manager='scoop'; id='meta-package-manager'; name='meta-package-manager'; operation='upgrade'; from='8.3.0'; to='9.0.0'; target='scoop:meta-package-manager' }
$plan = [pscustomobject]@{ override_protection = $false }
$r = Test-PkgsEntrySafeToExecute -Entry $entry -Plan $plan
"OK=$($r.ok) REASON=$($r.reason)"
'@
        $r = $null
        $savedRoot = $env:PKGS_TEST_SCOOP_ROOT
        try {
            $r = Invoke-UiHelper -Body $body -ExtraEnv @{ PKGS_TEST_SCOOP_ROOT = $root }
        }
        finally {
            $env:PKGS_TEST_SCOOP_ROOT = $savedRoot
        }
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'OK=False REASON=Scoop installed identity is not corroborated: exact Scoop app directory' 'disappeared directory'
    }

    Test-Case 'Scoop duplicate backend records remain one canonical record' {
        Invoke-ScoopGuardCase -State 'duplicate' -Outdated 'correct' -RootMode 'exact' -Body {
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json')
            Assert-Equal $r.ExitCode 0 'exit code'
            $j = Get-JsonResult $r
            $records = @($j.packages | Where-Object { $_.target -like 'scoop:meta-package*' })
            Assert-Equal $records.Count 1 'duplicate backend rows must collapse to one record'
            Assert-Equal $records[0].id 'meta-package-manager' 'canonical id'
            Assert-Equal $records[0].instances 2 'duplicate instance count'
        }
    }

    Test-Case 'Scoop correct and truncated cached records remain distinct' {
        Invoke-ScoopGuardCase -State 'correct' -Outdated 'correct' -RootMode 'exact' -Body {
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json', '--refresh')
            Assert-Equal $r.ExitCode 0 'cache build exit code'
            $cachePath = Join-Path $env:PKGS_CACHE_DIR 'snapshot.json'
            $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
            $copy = @($cache.packages | Where-Object { $_.manager -eq 'scoop' -and $_.id -eq 'meta-package-manager' })[0] | ConvertTo-Json -Depth 12 | ConvertFrom-Json
            $copy.id = 'meta-package-.'
            $copy.name = 'meta-package-.'
            $cache.packages = @($cache.packages) + $copy
            $cache | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cachePath -Encoding utf8
            $env:PKGS_CONFIG = Initialize-ScoopGuardCacheConfig
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json')
            Assert-Equal $r.ExitCode 0 'cached read exit code'
            $j = Get-JsonResult $r
            $targets = @($j.packages | Where-Object { $_.target -like 'scoop:meta-package*' } | ForEach-Object { $_.target } | Sort-Object)
            Assert-Equal $targets.Count 2 'distinct records must remain distinct'
            Assert-True ($targets -contains 'scoop:meta-package-manager') 'correct record missing'
            Assert-True ($targets -contains 'scoop:meta-package-.') 'truncated record missing'
        }
    }

    Test-Case 'Scoop duplicate cached records are surfaced without merging' {
        Invoke-ScoopGuardCase -State 'correct' -Outdated 'correct' -RootMode 'exact' -Body {
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json', '--refresh')
            Assert-Equal $r.ExitCode 0 'cache build exit code'
            $cachePath = Join-Path $env:PKGS_CACHE_DIR 'snapshot.json'
            $cache = Get-Content -LiteralPath $cachePath -Raw | ConvertFrom-Json
            $record = @($cache.packages | Where-Object { $_.manager -eq 'scoop' -and $_.id -eq 'meta-package-manager' })[0]
            $cache.packages = @($cache.packages) + $record
            $cache | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $cachePath -Encoding utf8
            $env:PKGS_CONFIG = Initialize-ScoopGuardCacheConfig
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json')
            Assert-Equal $r.ExitCode 0 'cached read exit code'
            $j = Get-JsonResult $r
            $targets = @($j.packages | Where-Object { $_.target -like 'scoop:meta-package*' } | ForEach-Object { $_.target })
            Assert-Equal $targets.Count 2 'duplicate cached rows must not be silently merged'
        }
    }

    Test-Case 'Scoop cached-state planning also enforces installed identity' {
        Invoke-ScoopGuardCase -State 'truncated' -Outdated 'truncated' -RootMode 'exact' -Body {
            $r = Invoke-Cli @('installed', '--manager', 'scoop', '--json', '--refresh')
            Assert-Equal $r.ExitCode 0 'cache build exit code'
            $env:PKGS_CONFIG = Initialize-ScoopGuardCacheConfig
            $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot
$c = Get-PkgsConfig
$p = New-PkgsPlan -Operation upgrade -Targets @('scoop:meta-package-.') -Snapshot $s -Config $c -UseCachedState
"BLOCKED=$($p.entries[0].blocked) REASON=$($p.entries[0].reason)"
'@
            $h = Invoke-UiHelper -Body $body
            Assert-Equal $h.ExitCode 0 "helper exit: $($h.Stderr)"
            Assert-Match $h.Stdout 'BLOCKED=True REASON=Scoop installed identity is not corroborated' 'cached-state plan'
        }
    }

    Test-Case 'Scoop root probe classifies absent, file, denied and unknown roots' {
        $missing = Join-Path $script:TestRoot 'scoop-root-missing'
        $readable = Initialize-ScoopGuardRoot -Mode 'exact'
        $file = Initialize-ScoopGuardRoot -Mode 'file'
        $bad = Join-Path $script:TestRoot 'scoop-root-bad|name'
        $aclRoot = Join-Path $script:TestRoot ('scoop-root-acl-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $null = New-Item -ItemType Directory -Path (Join-Path $aclRoot 'child') -Force
        Invoke-TestDirectoryDeny -Path $aclRoot
        try {
            $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
foreach ($pair in @(
    @('missing', $env:R_MISSING),
    @('readable', $env:R_READABLE),
    @('file', $env:R_FILE),
    @('bad', $env:R_BAD),
    @('acl', $env:R_ACL)
)) {
    $state = Get-PkgsScoopRootState -Root $pair[1]
    "STATE_$($pair[0])=$($state.kind)"
}
$denied = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_READABLE, $env:R_ACL)
"DENIED_OK=$($denied.ok) MATCH=$($denied.matchCount) REASON=$($denied.reason)"
$optional = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_MISSING, $env:R_READABLE)
"OPTIONAL_OK=$($optional.ok) MATCH=$($optional.matchCount)"
'@
            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                R_MISSING = $missing; R_READABLE = $readable; R_FILE = $file; R_BAD = $bad; R_ACL = $aclRoot
            }
            Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
            Assert-Match $r.Stdout 'STATE_missing=absent' 'missing root state'
            Assert-Match $r.Stdout 'STATE_readable=directory' 'readable root state'
            Assert-Match $r.Stdout 'STATE_file=file' 'file root state'
            Assert-Match $r.Stdout 'STATE_bad=unknown' 'unclassifiable root state'
            Assert-Match $r.Stdout 'STATE_acl=directory' 'ACL root existence state'
            Assert-Match $r.Stdout 'DENIED_OK=False MATCH=1 REASON=.*cannot enumerate Scoop apps root' 'denied enumeration must block'
            Assert-Match $r.Stdout 'OPTIONAL_OK=True MATCH=1' 'absent optional root must not block'
        }
        finally {
            Invoke-TestDirectoryDenyRemoval -Path $aclRoot
            Remove-Item $aclRoot -Recurse -Force -ErrorAction Ignore
        }
    }

    Test-Case 'Scoop root becoming inaccessible after an earlier successful check blocks' {
        $root = Initialize-ScoopGuardRoot -Mode 'exact'
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
$state = Get-PkgsScoopRootState -Root $env:R_ROOT
$identity = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager' -Roots @($env:R_ROOT)
"STATE=$($state.kind) OK=$($identity.ok) MATCH=$($identity.matchCount)"
'@
        $r = Invoke-UiHelper -Body $body -ExtraEnv @{ R_ROOT = $root }
        Assert-Match $r.Stdout 'STATE=directory OK=True MATCH=1' 'initial readable check'
        Invoke-TestDirectoryDeny -Path $root
        try {
            $r = Invoke-UiHelper -Body $body -ExtraEnv @{ R_ROOT = $root }
            Assert-Match $r.Stdout 'STATE=(directory|unreadable) OK=False' 'later denied check'
        }
        finally {
            Invoke-TestDirectoryDenyRemoval -Path $root
        }
    }

    Test-Case 'Scoop effective roots honor env, config and explicit test override' {
        $saved = @{}
        foreach ($name in 'SCOOP', 'SCOOP_GLOBAL', 'XDG_CONFIG_HOME', 'PKGS_TEST_SCOOP_ROOT', 'PKGS_TEST_SCOOP', 'R_EXPECT_USER', 'R_EXPECT_GLOBAL') {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $customHome = Join-Path $script:TestRoot ('scoop-config-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $emptyHome = Join-Path $script:TestRoot ('scoop-config-empty-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $badHome = Join-Path $script:TestRoot ('scoop-config-bad-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $null = New-Item -ItemType Directory -Path (Join-Path $customHome 'scoop') -Force
        $null = New-Item -ItemType Directory -Path $emptyHome -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $badHome 'scoop') -Force
        '{not valid json' | Set-Content -LiteralPath (Join-Path $badHome 'scoop\config.json') -Encoding utf8
        $customUserRoot = Join-Path $script:TestRoot 'custom-user-root'
        $customGlobalRoot = Join-Path $script:TestRoot 'custom-global-root'
        $portableRoot = Join-Path $script:TestRoot 'portable-root'
        $null = New-Item -ItemType Directory -Path (Join-Path $portableRoot 'shims') -Force
        $portableScript = Join-Path $portableRoot 'shims\scoop.ps1'
        Set-Content -LiteralPath $portableScript -Value '# fake portable scoop shim' -Encoding utf8
        $customConfig = [ordered]@{ root_path = $customUserRoot; global_path = $customGlobalRoot }
        $customConfig | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath (Join-Path $customHome 'scoop\config.json') -Encoding utf8
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
$info = Get-PkgsScoopRootInfo
"ROOTS=$($info.roots -join '|')"
"USER=$($info.userRoot)"
"GLOBAL=$($info.globalRoot)"
"CONFIG=$($info.configFile)"
"ERRORS=$($info.errors -join ';')"
"ERROR_COUNT=$(@($info.errors).Count)"
$identity = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager'
"IDENTITY_OK=$($identity.ok)"
'@
        try {
            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''; XDG_CONFIG_HOME = $emptyHome
            }
            $defaultUser = Join-Path ([Environment]::GetFolderPath('UserProfile')) 'scoop\apps'
            $defaultGlobal = Join-Path ([Environment]::GetFolderPath('CommonApplicationData')) 'scoop\apps'
            Assert-Match $r.Stdout ('USER=' + [regex]::Escape($defaultUser)) 'default user root'
            Assert-Match $r.Stdout ('GLOBAL=' + [regex]::Escape($defaultGlobal)) 'default global root'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''; XDG_CONFIG_HOME = $customHome
            }
            Assert-Match $r.Stdout ('USER=' + [regex]::Escape((Join-Path $customUserRoot 'apps'))) 'custom config user root'
            Assert-Match $r.Stdout ('GLOBAL=' + [regex]::Escape((Join-Path $customGlobalRoot 'apps'))) 'custom config global root'
            Assert-Match $r.Stdout 'IDENTITY_OK=False' 'unrelated default root must not be used for custom config'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''; XDG_CONFIG_HOME = $badHome
            }
            Assert-Match $r.Stdout 'ERRORS=.*cannot read Scoop configuration' 'malformed Scoop config error'
            Assert-Match $r.Stdout 'IDENTITY_OK=False' 'malformed Scoop config must fail closed'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''; XDG_CONFIG_HOME = $emptyHome
                PKGS_TEST_SCOOP = $portableScript
            }
            $portableScriptFull = (Get-Item -LiteralPath $portableScript).FullName
            $portableRootFull = Split-Path (Split-Path $portableScriptFull -Parent) -Parent
            Assert-Match $r.Stdout ('USER=' + [regex]::Escape((Join-Path $portableRootFull 'apps'))) 'portable root precedence'

            $envUserRoot = Join-Path $script:TestRoot 'env-user-root'
            $envGlobalRoot = Join-Path $script:TestRoot 'env-global-root'
            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                SCOOP = $envUserRoot; SCOOP_GLOBAL = $envGlobalRoot; PKGS_TEST_SCOOP_ROOT = ''; XDG_CONFIG_HOME = $customHome
            }
            Assert-Match $r.Stdout ('USER=' + [regex]::Escape((Join-Path $envUserRoot 'apps'))) 'SCOOP env precedence'
            Assert-Match $r.Stdout ('GLOBAL=' + [regex]::Escape((Join-Path $envGlobalRoot 'apps'))) 'SCOOP_GLOBAL env precedence'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                SCOOP = $envUserRoot; SCOOP_GLOBAL = $envGlobalRoot; XDG_CONFIG_HOME = $customHome
                PKGS_TEST_SCOOP_ROOT = $customUserRoot
            }
            Assert-Match $r.Stdout ('ROOTS=' + [regex]::Escape($customUserRoot)) 'explicit test root override'
        }
        finally {
            foreach ($name in $saved.Keys) {
                if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction Ignore }
                else { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] }
            }
            Remove-Item $customHome, $emptyHome, $badHome, $customUserRoot, $customGlobalRoot -Recurse -Force -ErrorAction Ignore
            Remove-Item $portableRoot -Recurse -Force -ErrorAction Ignore
            Remove-Item (Join-Path $script:TestRoot 'env-user-root'), (Join-Path $script:TestRoot 'env-global-root') -Recurse -Force -ErrorAction Ignore
        }
    }

    Test-Case 'Scoop identity guard blocks a mixed batch before any backend call' {
        Invoke-ScoopGuardCase -State 'truncated-mixed' -Outdated 'truncated-mixed' -RootMode 'exact' -Body {
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-.', 'npm:typescript', '--yes', '--json')
            Assert-Equal $r.ExitCode 5 'mixed batch exit code'
            Assert-SingleEnvelope $r
            $j = Get-JsonResult $r
            Assert-Equal @($j.plan).Count 2 'mixed plan size'
            $blocked = @($j.plan | Where-Object { $_.blocked })
            Assert-Equal $blocked.Count 1 'one blocked target'
            Assert-Match $blocked[0].reason 'Scoop installed identity is not corroborated' 'blocked reason'
            Assert-True (@($j.plan | Where-Object { $_.target -eq 'npm:typescript' -and -not $_.blocked }).Count -eq 1) 'valid unrelated target missing'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'mixed batch invoked the backend'
        }
    }

    Test-Case 'Scoop configuration trust handles absent, readable, unreadable and malformed candidates' {
        $saved = @{}
        foreach ($name in 'XDG_CONFIG_HOME', 'SCOOP', 'SCOOP_GLOBAL', 'PKGS_TEST_SCOOP_ROOT', 'PKGS_TEST_SCOOP', 'BAD_CONFIG') {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $emptyHome = Join-Path $script:TestRoot ('scoop-cfg-empty-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $ordinaryHome = Join-Path $script:TestRoot ('scoop-cfg-ordinary-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $unreadableHome = Join-Path $script:TestRoot ('scoop-cfg-unreadable-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $dirHome = Join-Path $script:TestRoot ('scoop-cfg-dir-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $arrayHome = Join-Path $script:TestRoot ('scoop-cfg-array-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $portableRoot = Join-Path $script:TestRoot ('scoop-cfg-portable-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $portableBadRoot = Join-Path $script:TestRoot ('scoop-cfg-portable-bad-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $ordinaryRoot = Join-Path $script:TestRoot 'scoop-cfg-ordinary-root'
        $portableCustomRoot = Join-Path $script:TestRoot 'scoop-cfg-portable-root'
        foreach ($configDir in @($emptyHome, $ordinaryHome, $unreadableHome, $dirHome, $arrayHome, $portableRoot, $portableBadRoot)) {
            $null = New-Item -ItemType Directory -Path (Join-Path $configDir 'scoop') -Force
        }
        foreach ($root in @($portableRoot, $portableBadRoot)) {
            $null = New-Item -ItemType Directory -Path (Join-Path $root 'shims') -Force
            Set-Content -LiteralPath (Join-Path $root 'shims\scoop.ps1') -Value '# fake portable scoop shim' -Encoding utf8
        }
        Set-Content -LiteralPath (Join-Path $portableBadRoot 'config.json') -Value '{"root_path":"ignored"}' -Encoding utf8
        [ordered]@{ root_path = $ordinaryRoot } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $ordinaryHome 'scoop\config.json') -Encoding utf8
        [ordered]@{ root_path = $portableCustomRoot } | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath (Join-Path $portableRoot 'config.json') -Encoding utf8
        Set-Content -LiteralPath (Join-Path (Join-Path $dirHome 'scoop') 'config.json') -Value '' -Encoding utf8
        Remove-Item -LiteralPath (Join-Path $dirHome 'scoop\config.json') -Force
        $null = New-Item -ItemType Directory -Path (Join-Path $dirHome 'scoop\config.json') -Force
        '[]' | Set-Content -LiteralPath (Join-Path $arrayHome 'scoop\config.json') -Encoding utf8
        Set-Content -LiteralPath (Join-Path $unreadableHome 'scoop\config.json') -Value '{"root_path":"ignored"}' -Encoding utf8
        $unreadablePath = Join-Path $unreadableHome 'scoop\config.json'
        Invoke-TestFileDeny -Path $unreadablePath
        Invoke-TestFileDeny -Path (Join-Path $portableBadRoot 'config.json')
        $badConfigPath = Join-Path $script:TestRoot 'scoop-bad|config.json'
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
$info = Get-PkgsScoopRootInfo
"USER=$($info.userRoot)"
"GLOBAL=$($info.globalRoot)"
"CONFIG=$($info.configFile)"
"ERRORS=$($info.errors -join ';')"
"ERROR_COUNT=$(@($info.errors).Count)"
$identity = Get-PkgsScoopIdentityEvidence -Id 'meta-package-manager'
"IDENTITY_OK=$($identity.ok)"
$badState = Get-PkgsScoopFileState -Path $env:BAD_CONFIG
"BAD_STATE=$($badState.kind)"
'@
        try {
            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                XDG_CONFIG_HOME = $emptyHome; SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''
                PKGS_TEST_SCOOP = $fakeScoop; BAD_CONFIG = $badConfigPath
            }
            Assert-Match $r.Stdout 'ERROR_COUNT=0' 'absent ordinary config should not error'
            Assert-Match $r.Stdout 'BAD_STATE=unknown' 'invalid config path state'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                XDG_CONFIG_HOME = $ordinaryHome; SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''
                PKGS_TEST_SCOOP = $fakeScoop; BAD_CONFIG = $badConfigPath
            }
            Assert-Match $r.Stdout ('USER=' + [regex]::Escape((Join-Path $ordinaryRoot 'apps'))) 'readable ordinary config'
            Assert-Match $r.Stdout 'ERROR_COUNT=0' 'readable ordinary config should not error'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                XDG_CONFIG_HOME = $ordinaryHome; SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''
                PKGS_TEST_SCOOP = (Join-Path $portableRoot 'shims\scoop.ps1'); BAD_CONFIG = $badConfigPath
            }
            Assert-Match $r.Stdout ('USER=' + [regex]::Escape((Join-Path $portableCustomRoot 'apps'))) 'portable config precedence'
            Assert-Match $r.Stdout 'ERROR_COUNT=0' 'readable portable config should not error'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                XDG_CONFIG_HOME = $unreadableHome; SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''
                PKGS_TEST_SCOOP = $fakeScoop; BAD_CONFIG = $badConfigPath
            }
            Assert-Match $r.Stdout 'ERRORS=.*cannot (access|read) Scoop configuration' 'unreadable ordinary config'
            Assert-Match $r.Stdout 'IDENTITY_OK=False' 'unreadable ordinary config must fail closed'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                XDG_CONFIG_HOME = $emptyHome; SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''
                PKGS_TEST_SCOOP = (Join-Path $portableBadRoot 'shims\scoop.ps1'); BAD_CONFIG = $badConfigPath
            }
            Assert-Match $r.Stdout 'ERRORS=.*cannot (access|read) Scoop configuration' 'unreadable portable config'
            Assert-Match $r.Stdout 'IDENTITY_OK=False' 'unreadable portable config must fail closed'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                XDG_CONFIG_HOME = $dirHome; SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''
                PKGS_TEST_SCOOP = $fakeScoop; BAD_CONFIG = $badConfigPath
            }
            Assert-Match $r.Stdout 'ERRORS=.*is a directory, not a file' 'directory config path'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                XDG_CONFIG_HOME = $arrayHome; SCOOP = ''; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''
                PKGS_TEST_SCOOP = $fakeScoop; BAD_CONFIG = $badConfigPath
            }
            Assert-Match $r.Stdout 'ERRORS=.*JSON root is not an object' 'non-object JSON config'

            $r = Invoke-UiHelper -Body $body -ExtraEnv @{
                XDG_CONFIG_HOME = $unreadableHome; SCOOP = $ordinaryRoot; SCOOP_GLOBAL = ''; PKGS_TEST_SCOOP_ROOT = ''
                PKGS_TEST_SCOOP = $fakeScoop; BAD_CONFIG = $badConfigPath
            }
            Assert-Match $r.Stdout ('USER=' + [regex]::Escape((Join-Path $ordinaryRoot 'apps'))) 'env override remains visible'
            Assert-Match $r.Stdout 'ERRORS=.*cannot (access|read) Scoop configuration' 'unreadable config alongside env override'
            Assert-Match $r.Stdout 'IDENTITY_OK=False' 'unreadable config must fail closed despite env override'
        }
        finally {
            Invoke-TestFileDenyRemoval -Path $unreadablePath
            Invoke-TestFileDenyRemoval -Path (Join-Path $portableBadRoot 'config.json')
            foreach ($name in $saved.Keys) {
                if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction Ignore }
                else { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] }
            }
            Remove-Item $emptyHome, $ordinaryHome, $unreadableHome, $dirHome, $arrayHome, $portableRoot, $portableBadRoot -Recurse -Force -ErrorAction Ignore
            Remove-Item $ordinaryRoot, $portableCustomRoot -Recurse -Force -ErrorAction Ignore
        }
    }

    Test-Case 'Scoop configuration failure blocks a mutation before the backend' {
        $installRoot = Join-Path $script:TestRoot ('scoop-cfg-install-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $root = Join-Path $installRoot 'apps'
        $app = Join-Path $root 'meta-package-manager\current'
        $null = New-Item -ItemType Directory -Path $app -Force
        '{"hold":false,"bucket":"main"}' | Set-Content -LiteralPath (Join-Path $app 'scoop-install.json') -Encoding utf8
        $configHome = Join-Path $script:TestRoot ('scoop-cfg-block-' + [guid]::NewGuid().ToString('N').Substring(0,6))
        $null = New-Item -ItemType Directory -Path (Join-Path $configHome 'scoop') -Force
        $configFile = Join-Path $configHome 'scoop\config.json'
        Set-Content -LiteralPath $configFile -Value '{"root_path":"ignored"}' -Encoding utf8
        Invoke-TestFileDeny -Path $configFile
        $saved = @{}
        foreach ($name in 'XDG_CONFIG_HOME', 'SCOOP', 'SCOOP_GLOBAL', 'PKGS_TEST_SCOOP_ROOT', 'PKGS_FAKE_STATE', 'PKGS_FAKE_STATE_SEED', 'PKGS_FAKE_OUTDATED') {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
        }
        $statePath = Join-Path $script:TestRoot ('scoop-cfg-state-' + [guid]::NewGuid().ToString('N').Substring(0,6) + '.json')
        Copy-Item -LiteralPath (Join-Path $fixtures 'scoop-meta-correct.json') -Destination $statePath -Force
        try {
            $env:XDG_CONFIG_HOME = $configHome
            $env:SCOOP = $installRoot
            $env:SCOOP_GLOBAL = ''
            $env:PKGS_TEST_SCOOP_ROOT = ''
            $env:PKGS_FAKE_STATE = $statePath
            $env:PKGS_FAKE_STATE_SEED = $statePath
            $env:PKGS_FAKE_OUTDATED = 'scoop-meta-outdated-correct.json'
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('upgrade', 'scoop:meta-package-manager', '--yes', '--json')
            Assert-Equal $r.ExitCode 5 'config failure exit code'
            Assert-SingleEnvelope $r
            $j = Get-JsonResult $r
            Assert-True (-not $j.ok) 'config failure must fail JSON'
            Assert-True $j.plan[0].blocked 'config failure must block the plan'
            Assert-Match $j.plan[0].reason 'Scoop installed identity is not corroborated: cannot (access|read) Scoop configuration' 'config failure reason'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'config failure invoked the backend'
        }
        finally {
            Invoke-TestFileDenyRemoval -Path $configFile
            foreach ($name in $saved.Keys) {
                if ($null -eq $saved[$name]) { Remove-Item -LiteralPath "Env:$name" -ErrorAction Ignore }
                else { Set-Item -LiteralPath "Env:$name" -Value $saved[$name] }
            }
            Remove-Item $configHome -Recurse -Force -ErrorAction Ignore
            Remove-Item $installRoot -Recurse -Force -ErrorAction Ignore
            Remove-Item $statePath -Force -ErrorAction Ignore
        }
    }

    Test-Case 'explicit target + --yes executes exactly the selected manager and ID' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'result should be ok'
        Assert-Equal $j.exit_code 0 'JSON exit code'
        Assert-Equal $j.dry_run $false 'dry_run must be false'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log '--scoop upgrade shared\.app' 'exact mpm invocation'
        Assert-True ($log -notmatch '--all') 'must never pass --all'
    }

    Test-Case 'multiple selected targets are executed individually' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', 'npm:typescript', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $log = @(Get-Content -LiteralPath $env:PKGS_FAKE_LOG)
        Assert-Equal $log.Count 2 'two backend calls expected'
        Assert-Match ($log -join "`n") '--scoop upgrade shared\.app' 'scoop call'
        Assert-Match ($log -join "`n") '--npm upgrade typescript' 'npm call'
    }

    Test-Case 'non-JSON backend output does not corrupt success exit' {
        $env:PKGS_FAKE_MUTATION_OUTPUT = 'backend-output-line'
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes')
        Assert-Equal $r.ExitCode 0 'exit code'
        Assert-Match $r.Stdout 'backend-output-line' 'backend output missing'
        Assert-Match $r.Stdout 'OK' 'success marker missing'
    }

    Test-Case 'native pin output does not corrupt success exit' {
        $env:PKGS_FAKE_PIN_OUTPUT = 'pin-output-line'
        $r = Invoke-Cli @('pin', 'scoop:shared.app', '--yes')
        Assert-Equal $r.ExitCode 0 'hold exit'
        Assert-Match $r.Stdout 'pin-output-line' 'pin output missing'
        $r2 = Invoke-Cli @('pin', 'scoop:shared.app', '--remove', '--yes')
        Assert-Equal $r2.ExitCode 0 'unhold exit'
    }

    Test-Case 'native pin output does not corrupt JSON' {
        $env:PKGS_FAKE_PIN_OUTPUT = 'scoop-pin-output'
        $r = Invoke-Cli @('pin', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'scoop pin JSON exit'
        $j = Get-JsonResult $r 'scoop pin JSON'
        Assert-True $j.ok 'scoop pin JSON must be ok'
        Assert-Match $r.Stderr 'scoop-pin-output' 'scoop pin output must be on stderr'
        Assert-True ($r.Stdout -notmatch 'scoop-pin-output') 'scoop pin output leaked to stdout'
        $r2 = Invoke-Cli @('pin', 'scoop:shared.app', '--remove', '--yes', '--json')
        Assert-Equal $r2.ExitCode 0 'scoop unpin JSON exit'
        $j2 = Get-JsonResult $r2 'scoop unpin JSON'
        Assert-True $j2.ok 'scoop unpin JSON must be ok'

        $pinState = Join-Path $script:TestRoot 'winget-pins-json-state.json'
        ConvertTo-Json -InputObject @() | Set-Content -LiteralPath $pinState -Encoding utf8
        $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
        $env:PKGS_FAKE_PIN_OUTPUT = 'winget-pin-output'
        $r3 = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r3.ExitCode 0 'winget pin JSON exit'
        $j3 = Get-JsonResult $r3 'winget pin JSON'
        Assert-True $j3.ok 'winget pin JSON must be ok'
        Assert-Match $r3.Stderr 'winget-pin-output' 'winget pin output must be on stderr'
        Assert-True ($r3.Stdout -notmatch 'winget-pin-output') 'winget pin output leaked to stdout'
        $r4 = Invoke-Cli @('pin', 'winget:shared.app', '--remove', '--yes', '--json')
        Assert-Equal $r4.ExitCode 0 'winget unpin JSON exit'
        $j4 = Get-JsonResult $r4 'winget unpin JSON'
        Assert-True $j4.ok 'winget unpin JSON must be ok'
    }

    Test-Case 'failed mutation reports failure and exits 5' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $env:PKGS_FAKE_MUTATION_EXIT = '130'
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'result must be failed'
        Assert-Equal $j.results[0].exit 130 'backend exit code'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $env:PKGS_CACHE_DIR 'snapshot.json'))) 'cache should be invalidated'
    }

    Test-Case 'winget upgrade executes a direct exact source-scoped command' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'result should be ok'
        Assert-True $j.results[0].verified 'result must be verified against live state'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log 'winget upgrade --id shared\.app --exact --source winget' 'exact winget upgrade'
        Assert-True ($log -notmatch 'mpm --winget') 'winget mutation must not use the unsafe mpm install path'
        Assert-True ($log -notmatch '--all') 'must never pass --all'
        Assert-True ($log -notmatch '--force') 'must never pass --force'
    }

    Test-Case 'winget install and remove are exact and verified' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('install', 'winget:New.Tool', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'install exit'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'install result should be ok'
        Assert-True $j.results[0].verified 'install must be verified'
        Assert-Match $j.results[0].verification "installed version '2.0.0'" 'planned latest version'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log 'winget install --id New\.Tool --exact --source winget' 'exact winget install'

        $r2 = Invoke-Cli @('remove', 'winget:New.Tool', '--yes', '--json')
        Assert-Equal $r2.ExitCode 0 'remove exit'
        $j2 = Get-JsonResult $r2
        Assert-True $j2.ok 'remove result should be ok'
        Assert-True $j2.results[0].verified 'remove must be verified'
        $log2 = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log2 'winget uninstall --id New\.Tool --exact --source winget' 'exact winget uninstall'
    }

    Test-Case 'winget explicit-version install is exact and token-safe' {
        $r = Invoke-Cli @('install', 'winget:New.Tool', '--pkg-version', '1.5.0', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 0 'version install exit'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'version install JSON'
        Assert-Equal $j.plan[0].version '1.5.0' 'planned version'
        Assert-Match $j.plan[0].native 'install --id New\.Tool --exact --source winget.*--version 1\.5\.0' 'exact version flag'

        $r2 = Invoke-Cli @('install', 'winget:New.Tool', '--pkg-version', '--force', '--dry-run', '--json')
        Assert-Equal $r2.ExitCode 5 'unsafe version exit'
        $j2 = Get-JsonResult $r2
        Assert-True $j2.plan[0].blocked 'unsafe version must be blocked'
        Assert-Match $j2.plan[0].reason 'not a safe WinGet version specifier' 'unsafe version reason'
    }

    Test-Case 'winget uninstall and upgrade verify the installed source' {
        $env:PKGS_FAKE_WINGET_SOURCE = 'msstore'
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 5 'wrong-source upgrade exit'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'wrong-source plan must be blocked'
        Assert-True (-not $j.ok) 'wrong-source JSON must be false'
        Assert-Equal $j.exit_code 5 'wrong-source JSON exit code'
        Assert-Match $j.plan[0].reason "source is 'msstore'" 'wrong-source reason'

        $env:PKGS_FAKE_WINGET_SOURCE = 'unexpectedsource'
        $r2 = Invoke-Cli @('remove', 'winget:shared.app', '--dry-run', '--json')
        Assert-Equal $r2.ExitCode 5 'unreported-source remove exit'
        $j2 = Get-JsonResult $r2
        Assert-True $j2.plan[0].blocked 'unreported-source plan must be blocked'
        Assert-Match $j2.plan[0].reason 'source is not reported' 'unreported-source reason'
    }

    Test-Case 'winget refuses multiple installed registrations' {
        $env:PKGS_FAKE_WINGET_DUPLICATE = '1'
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'duplicate registration must be blocked'
        Assert-Match $j.plan[0].reason 'multiple installed records' 'duplicate reason'
    }

    Test-Case 'winget refuses a stale installed version' {
        $env:PKGS_FAKE_WINGET_VERSION = '1.9.9'
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'stale version must be blocked'
        Assert-Match $j.plan[0].reason "winget reports '1.9.9'" 'stale version reason'
    }

    Test-Case 'winget refuses unreadable inventory output' {
        $env:PKGS_FAKE_WINGET_LIST_MALFORMED = '1'
        $r = Invoke-Cli @('install', 'winget:New.Tool', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'unreadable identity must be blocked'
        Assert-Match $j.plan[0].reason 'not fully readable' 'unreadable reason'
    }

    Test-Case 'winget install refuses a registration that mpm does not report' {
        $state = Get-Content -LiteralPath $env:PKGS_FAKE_STATE -Raw | ConvertFrom-Json
        $state.winget.packages = @($state.winget.packages) + [pscustomobject]@{
            id = 'New.Tool'; name = 'New Tool'; installed_version = '2.0.0'; source = 'winget'
        }
        $state | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $env:PKGS_FAKE_STATE -Encoding utf8
        $env:PKGS_FAKE_INSTALLED = 'installed-normal.json'
        $r = Invoke-Cli @('install', 'winget:New.Tool', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'winget-only registration must be blocked'
        Assert-Match $j.plan[0].reason 'already registered with WinGet' "winget-only reason: $($j.plan[0].reason)"
    }

    Test-Case 'winget refuses malformed or missing pin data' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $env:PKGS_FAKE_WINGET_PIN_LIST = 'winget-pins-malformed.txt'
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 6 'malformed pin exit'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'malformed pin must block'
        Assert-Match $j.plan[0].reason 'protection unknown' 'malformed pin reason'

        $env:PKGS_FAKE_WINGET_PIN_LIST = 'empty'
        $r2 = Invoke-Cli @('upgrade', 'winget:shared.app', '--dry-run', '--json')
        Assert-Equal $r2.ExitCode 6 'empty pin output exit'
        $j2 = Get-JsonResult $r2
        Assert-Match $j2.plan[0].reason 'protection unknown' 'empty pin reason'

        $r3 = Invoke-Cli @('upgrade', 'winget:shared.app', '--override-protection', '--dry-run', '--json')
        Assert-Equal $r3.ExitCode 6 'override must not bypass unknown pin state'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'pin read failure invoked the backend'
    }

    Test-Case 'winget pin types are parsed and all block mutation' {
        $env:PKGS_FAKE_WINGET_PIN_LIST = 'winget-pins-gating.txt'
        $r = Invoke-Cli @('pin', '--list', '--json')
        Assert-Equal $r.ExitCode 0 'pin list exit'
        $j = Get-JsonResult $r
        $gating = @($j.pins | Where-Object target -eq 'winget:Example.Tool')[0]
        Assert-Equal $gating.detail 'Gating' 'gating pin type'
        $pinning = @($j.pins | Where-Object target -eq 'winget:shared.app')[0]
        Assert-Equal $pinning.detail 'Pinning' 'pinning pin type'

        $r2 = Invoke-Cli @('upgrade', 'winget:shared.app', '--dry-run', '--json')
        Assert-Equal $r2.ExitCode 6 'ordinary pin must block'
        $j2 = Get-JsonResult $r2
        Assert-Match $j2.plan[0].reason 'native pin' 'pin block reason'
    }

    Test-Case 'winget table parsing keeps source when Available is blank' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
$fmt = '{0,-24}{1,-20}{2,-10}{3,-10}{4}'
$text = ($fmt -f 'Name','Id','Version','Available','Source') + "`n" + ('-' * 70) + "`n" +
        ($fmt -f 'AnyDesk','AnyDesk.AnyDesk','9.8.3','','winget') + "`n" +
        ($fmt -f 'Rclone','Rclone.Rclone','1.75.1','1.76.0','winget')
$rows = @(ConvertFrom-WingetTable -Text $text)
"COUNT=$($rows.Count)"
foreach ($r in $rows) { "ROW=$($r.id)|$($r.version)|$($r.available)|$($r.source)" }
"SKIPPED=$script:LastWingetSkipped"
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'COUNT=2' 'row count'
        Assert-Match $r.Stdout 'ROW=AnyDesk\.AnyDesk\|9\.8\.3\|\|winget' 'blank Available row'
        Assert-Match $r.Stdout 'ROW=Rclone\.Rclone\|1\.75\.1\|1\.76\.0\|winget' 'populated Available row'
        Assert-Match $r.Stdout 'SKIPPED=0' 'no rows skipped'
    }

    Test-Case 'winget native pin failures and readback mismatches are reported' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $env:PKGS_FAKE_PIN_EXIT = '5'
        $r = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'pin failure exit'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'pin failure reported as success'
        Assert-Match $j.results[0].message 'native pin command failed' 'pin failure message'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log 'winget pin add --id shared\.app --exact --source winget --blocking' 'blocking pin command'

        Remove-Item -LiteralPath "Env:PKGS_FAKE_PIN_EXIT" -ErrorAction Ignore
        $env:PKGS_FAKE_WINGET_PIN_LIST = 'winget-pins-none.txt'
        $r2 = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r2.ExitCode 5 'pin readback exit'
        $j2 = Get-JsonResult $r2
        Assert-Match $j2.results[0].message 'no native pin is present' 'pin readback message'

        Remove-Item -LiteralPath "Env:PKGS_FAKE_WINGET_PIN_LIST" -ErrorAction Ignore
        $r3 = Invoke-Cli @('pin', 'winget:Example.Tool', '--remove', '--yes', '--json')
        Assert-Equal $r3.ExitCode 5 'unpin readback exit'
        $j3 = Get-JsonResult $r3
        Assert-Match $j3.results[0].message 'still present' 'unpin readback message'

        $pinState = Join-Path $script:TestRoot 'winget-pins-state.json'
        ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'Example.Tool'; source = 'winget'; type = 'Blocking' }) |
            Set-Content -LiteralPath $pinState -Encoding utf8
        $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
        $r4 = Invoke-Cli @('pin', 'winget:Example.Tool', '--remove', '--yes', '--json')
        Assert-Equal $r4.ExitCode 0 'unpin success exit'
        $j4 = Get-JsonResult $r4
        Assert-True $j4.ok 'verified unpin must be ok'
        $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
        Assert-Equal $pins.Count 0 'unpin must remove the owned pin'
    }

    Test-Case 'winget pin targets reject option-like identities' {
        $r = Invoke-Cli @('pin', 'winget:--force', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'invalid identity reported as success'
        Assert-Match $j.results[0].message 'not a valid WinGet identity' 'invalid identity message'
    }

    Test-Case 'winget blocking pin creation verifies type and source' {
        $pinState = Join-Path $script:TestRoot 'winget-pins-state.json'
        ConvertTo-Json -InputObject @() | Set-Content -LiteralPath $pinState -Encoding utf8
        $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore

        $r = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'pin creation exit'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'verified blocking pin must be ok'
        $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
        Assert-Equal $pins.Count 1 'pin record count'
        Assert-Equal $pins[0].type 'Blocking' 'pin type'
        Assert-Equal $pins[0].source 'winget' 'pin source'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log 'winget pin add --id shared\.app --exact --source winget --blocking' 'blocking pin command'

        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r2 = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r2.ExitCode 0 'already-blocking exit'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'already-blocking state invoked the backend'

        $r3 = Invoke-Cli @('pin', 'winget:shared.app', '--remove', '--yes', '--json')
        Assert-Equal $r3.ExitCode 0 'unpin exit'
        $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
        Assert-Equal $pins.Count 0 'pin record must be removed'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log 'winget pin remove --id shared\.app --exact --source winget' 'exact unpin command'
    }

    Test-Case 'winget pin creation rejects non-blocking readback' {
        foreach ($type in @('Pinning', 'Gating')) {
            $pinState = Join-Path $script:TestRoot 'winget-pins-state.json'
            ConvertTo-Json -InputObject @() | Set-Content -LiteralPath $pinState -Encoding utf8
            $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
            $env:PKGS_FAKE_WINGET_PIN_ADD_TYPE = $type
            $r = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
            Assert-Equal $r.ExitCode 5 "$type readback exit"
            $j = Get-JsonResult $r
            Assert-True (-not $j.ok) "$type readback reported as success"
            Assert-Match $j.results[0].message "expected 'Blocking'" "$type readback reason"
            $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
            Assert-Equal $pins.Count 1 "$type pin must remain recorded"
            Assert-Equal $pins[0].type $type "$type pin must not be replaced"
        }
    }

    Test-Case 'winget pin creation rejects a wrong-source readback' {
        $pinState = Join-Path $script:TestRoot 'winget-pins-state.json'
        ConvertTo-Json -InputObject @() | Set-Content -LiteralPath $pinState -Encoding utf8
        $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
        $env:PKGS_FAKE_WINGET_PIN_ADD_SOURCE = 'msstore'
        $r = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'wrong-source readback exit'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'wrong-source readback reported as success'
        Assert-Match $j.results[0].message "pin source is 'msstore'" 'wrong-source readback reason'
        $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
        Assert-Equal $pins[0].source 'msstore' 'wrong-source pin must remain recorded'
    }

    Test-Case 'winget pin creation rejects duplicate and missing-type readback' {
        $pinState = Join-Path $script:TestRoot 'winget-pins-state.json'
        ConvertTo-Json -InputObject @() | Set-Content -LiteralPath $pinState -Encoding utf8
        $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
        $env:PKGS_FAKE_WINGET_PIN_DUPLICATE = '1'
        $r = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'duplicate readback exit'
        $j = Get-JsonResult $r
        Assert-Match $j.results[0].message 'multiple native pin records' 'duplicate readback reason'

        Remove-Item -LiteralPath "Env:PKGS_FAKE_WINGET_PIN_DUPLICATE" -ErrorAction Ignore
        ConvertTo-Json -InputObject @() | Set-Content -LiteralPath $pinState -Encoding utf8
        $env:PKGS_FAKE_WINGET_PIN_ADD_MISSING_TYPE = '1'
        $r2 = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r2.ExitCode 5 'missing-type readback exit'
        $j2 = Get-JsonResult $r2
        Assert-True (-not $j2.ok) 'missing-type readback reported as success'
        Assert-Match $j2.results[0].message 'not readable' 'missing-type readback reason'
    }

    Test-Case 'winget pin creation refuses to replace ordinary or gating pins' {
        foreach ($type in @('Pinning', 'Gating')) {
            $pinState = Join-Path $script:TestRoot 'winget-pins-state.json'
            ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'shared.app'; source = 'winget'; type = $type }) |
                Set-Content -LiteralPath $pinState -Encoding utf8
            $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
            Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
            $r = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
            Assert-Equal $r.ExitCode 5 "$type replacement exit"
            $j = Get-JsonResult $r
            Assert-Match $j.results[0].message 'existing native pin' "$type replacement reason"
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) "$type replacement invoked the backend"
            $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
            Assert-Equal $pins.Count 1 "$type pin count"
            Assert-Equal $pins[0].type $type "$type pin type must be preserved"
        }
    }

    Test-Case 'winget pin list exposes exact pin type and source' {
        $pinState = Join-Path $script:TestRoot 'winget-pins-state.json'
        ConvertTo-Json -InputObject @(
            [pscustomobject]@{ id = 'shared.app'; source = 'winget'; type = 'Blocking' }
            [pscustomobject]@{ id = 'Example.Tool'; source = 'msstore'; type = 'Pinning' }
        ) | Set-Content -LiteralPath $pinState -Encoding utf8
        $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
        $r = Invoke-Cli @('pin', '--list', '--json')
        Assert-Equal $r.ExitCode 0 'pin list exit'
        $j = Get-JsonResult $r
        $shared = @($j.pins | Where-Object target -eq 'winget:shared.app')[0]
        Assert-Equal $shared.pin_type 'Blocking' 'shared pin type'
        Assert-Equal $shared.pin_source 'winget' 'shared pin source'
        $example = @($j.pins | Where-Object target -eq 'winget:Example.Tool')[0]
        Assert-Equal $example.pin_type 'Pinning' 'example pin type'
        Assert-Equal $example.pin_source 'msstore' 'example pin source'

        $shown = Invoke-Cli @('show', 'winget:shared.app', '--json')
        Assert-Equal $shown.ExitCode 0 'show exit'
        $sj = Get-JsonResult $shown
        Assert-Equal $sj.packages[0].native_pin.type 'Blocking' 'shown pin type'
        Assert-Equal $sj.packages[0].native_pin.source 'winget' 'shown pin source'
    }

    Test-Case 'winget pin removal verifies exact ownership' {
        $pinState = Join-Path $script:TestRoot 'winget-pins-state.json'
        ConvertTo-Json -InputObject @() | Set-Content -LiteralPath $pinState -Encoding utf8
        $env:PKGS_FAKE_WINGET_PIN_STATE = $pinState
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('pin', 'winget:shared.app', '--remove', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'absent pin removal exit'
        $j = Get-JsonResult $r
        Assert-Match $j.results[0].message 'no native pin' 'absent pin reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'absent pin invoked the backend'

        ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'shared.app'; source = 'msstore'; type = 'Blocking' }) |
            Set-Content -LiteralPath $pinState -Encoding utf8
        $r2 = Invoke-Cli @('pin', 'winget:shared.app', '--remove', '--yes', '--json')
        Assert-Equal $r2.ExitCode 5 'wrong-source removal exit'
        $j2 = Get-JsonResult $r2
        Assert-Match $j2.results[0].message "not from source 'winget'" 'wrong-source removal reason'
        $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
        Assert-Equal $pins.Count 1 'wrong-source pin must remain'

        ConvertTo-Json -InputObject @(
            [pscustomobject]@{ id = 'shared.app'; source = 'winget'; type = 'Blocking' }
            [pscustomobject]@{ id = 'shared.app'; source = 'winget'; type = 'Pinning' }
        ) | Set-Content -LiteralPath $pinState -Encoding utf8
        $r3 = Invoke-Cli @('pin', 'winget:shared.app', '--remove', '--yes', '--json')
        Assert-Equal $r3.ExitCode 5 'duplicate removal exit'
        $j3 = Get-JsonResult $r3
        Assert-Match $j3.results[0].message 'multiple winget-source pins' 'duplicate removal reason'

        ConvertTo-Json -InputObject @([pscustomobject]@{ id = 'Orphan.Tool'; source = 'winget'; type = 'Blocking' }) |
            Set-Content -LiteralPath $pinState -Encoding utf8
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r4 = Invoke-Cli @('pin', 'winget:Orphan.Tool', '--remove', '--yes', '--json')
        Assert-Equal $r4.ExitCode 0 'orphaned pin removal exit'
        $j4 = Get-JsonResult $r4
        Assert-True $j4.ok 'verified orphaned pin removal'
        $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
        Assert-Equal $pins.Count 0 'orphaned pin must be removed'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log 'winget pin remove --id Orphan\.Tool --exact --source winget' 'orphaned pin command'

        ConvertTo-Json -InputObject @([pscustomobject]@{ id = '{6CAD3681-0B2E-4B2D-89D0-2Dff4D35a3de}'; source = 'winget'; type = 'Blocking' }) |
            Set-Content -LiteralPath $pinState -Encoding utf8
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r5 = Invoke-Cli @('pin', 'winget:{6CAD3681-0B2E-4B2D-89D0-2Dff4D35a3de}', '--remove', '--yes', '--json')
        Assert-Equal $r5.ExitCode 0 'GUID pin removal exit'
        $j5 = Get-JsonResult $r5
        Assert-True $j5.ok 'verified GUID pin removal'
        $pins = @(Get-Content -LiteralPath $pinState -Raw | ConvertFrom-Json)
        Assert-Equal $pins.Count 0 'GUID pin must be removed'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log '6CAD3681-0B2E-4B2D-89D0-2Dff4D35a3de' 'GUID pin command'
    }

    Test-Case 'winget pin add requires exact installed identity' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('pin', 'winget:New.Tool', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'not-installed pin exit'
        $j = Get-JsonResult $r
        Assert-Match $j.results[0].message 'not installed' 'not-installed pin reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'not-installed pin invoked the backend'

        $env:PKGS_FAKE_WINGET_SOURCE = 'msstore'
        $r2 = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r2.ExitCode 5 'wrong-source pin exit'
        $j2 = Get-JsonResult $r2
        Assert-Match $j2.results[0].message "source is 'msstore'" 'wrong-source pin reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'wrong-source pin invoked the backend'

        Remove-Item -LiteralPath "Env:PKGS_FAKE_WINGET_SOURCE" -ErrorAction Ignore
        $env:PKGS_FAKE_WINGET_DUPLICATE = '1'
        $r3 = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r3.ExitCode 5 'duplicate pin exit'
        $j3 = Get-JsonResult $r3
        Assert-Match $j3.results[0].message 'multiple installed records' 'duplicate pin reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'duplicate pin invoked the backend'

        Remove-Item -LiteralPath "Env:PKGS_FAKE_WINGET_DUPLICATE" -ErrorAction Ignore
        $env:PKGS_FAKE_WINGET_LIST_MALFORMED = '1'
        $r4 = Invoke-Cli @('pin', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r4.ExitCode 5 'unreadable pin identity exit'
        $j4 = Get-JsonResult $r4
        Assert-Match $j4.results[0].message 'not fully readable' 'unreadable pin identity reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'unreadable identity invoked the backend'
    }

    Test-Case 'install refuses a package that is already installed' {
        $r = Invoke-Cli @('install', 'scoop:shared.app', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 5 'dry-run exit'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'plan should be blocked'
        Assert-True (-not $j.ok) 'invalid install JSON must be false'
        Assert-Equal $j.exit_code 5 'invalid install JSON exit code'
        Assert-Match $j.plan[0].reason 'already installed' 'reason'
    }

    Test-Case 'a manager filter cannot be silently ignored by a mutation' {
        $r = Invoke-Cli @('install', 'winget:New.Tool', '-m', 'scoop', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 4 'install filter exit'
        Assert-Match ($r.Stdout + $r.Stderr) 'does not match -m scoop' 'install filter message'

        $r2 = Invoke-Cli @('upgrade', 'winget:shared.app', '-m', 'scoop', '--dry-run', '--json')
        Assert-Equal $r2.ExitCode 4 'upgrade filter exit'
        Assert-Match ($r2.Stdout + $r2.Stderr) 'does not match -m scoop' 'upgrade filter message'
    }

    Test-Case 'dry-run verifies targets against live backend state' {
        $env:PKGS_FAKE_OUTDATED = 'outdated-empty.json'
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 5 'dry-run exit'
        $j = Get-JsonResult $r
        Assert-True $j.plan[0].blocked 'stale cached target must be blocked'
        Assert-True (-not $j.ok) 'stale target JSON must be false'
        Assert-Equal $j.exit_code 5 'stale target JSON exit code'
        Assert-Match $j.plan[0].reason 'not reported as outdated' 'reason'
    }

    Test-Case 'backend success without the expected change is a failure' {
        $env:PKGS_FAKE_SKIP_STATE_UPDATE = '1'
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'unverified change must not be ok'
        Assert-True (-not $j.results[0].verified) 'result must not be verified'
        Assert-Equal $j.results[0].backend_exit 0 'backend exit'
        Assert-Match $j.results[0].verification 'unchanged' 'verification evidence'
    }

    Test-Case 'winget backend success without the expected change is a failure' {
        $env:PKGS_FAKE_SKIP_STATE_UPDATE = '1'
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'upgrade exit'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'unverified upgrade must not be ok'
        Assert-Equal $j.results[0].backend_exit 0 'backend exit'
        Assert-Match $j.results[0].verification 'unchanged' 'upgrade verification evidence'
    }

    Test-Case 'winget backend nonzero exit propagates' {
        $env:PKGS_FAKE_MUTATION_EXIT = '130'
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'failed backend reported as ok'
        Assert-Equal $j.results[0].backend_exit 130 'backend exit'
        Assert-True (-not $j.results[0].verified) 'failed backend must not be verified'
    }

    Test-Case 'winget post-install identity mismatch fails verification' {
        $env:PKGS_FAKE_WINGET_SOURCE = 'msstore'
        $r = Invoke-Cli @('install', 'winget:New.Tool', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'wrong post-install identity reported as ok'
        Assert-Equal $j.results[0].backend_exit 0 'backend exit'
        Assert-Match $j.results[0].verification 'source' 'identity verification evidence'
    }

    Test-Case 'winget post-remove identity mismatch fails verification' {
        $env:PKGS_FAKE_SKIP_STATE_UPDATE = '1'
        $r = Invoke-Cli @('remove', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'no-op remove reported as ok'
        Assert-Equal $j.results[0].backend_exit 0 'backend exit'
        Assert-Match $j.results[0].verification 'still reports|still installed' 'identity verification evidence'
    }

    Test-Case 'winget default install version mismatch fails verification' {
        $env:PKGS_FAKE_INSTALL_VERSION = '9.9.9'
        $r = Invoke-Cli @('install', 'winget:New.Tool', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'wrong installed version reported as ok'
        Assert-Equal $j.results[0].backend_exit 0 'backend exit'
        Assert-Match $j.results[0].verification "expected '2.0.0'" 'planned latest verification'
    }

    Test-Case 'winget explicit-version install accepts four-part zero form' {
        $env:PKGS_FAKE_MUTATION_VERSION = '2.16.60.0'
        $r = Invoke-Cli @('install', 'winget:New.Tool', '--pkg-version', '2.16.60', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'explicit four-part install exit'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-True $j.ok 'explicit four-part install must be ok'
        Assert-True $j.results[0].verified 'explicit four-part install must be verified'
        Assert-Match $j.results[0].verification "installed version '2\.16\.60\.0'" 'explicit four-part raw version'
        $state = Get-Content -LiteralPath $env:PKGS_FAKE_STATE -Raw | ConvertFrom-Json
        $pkg = @($state.winget.packages | Where-Object id -eq 'New.Tool')[0]
        Assert-Equal $pkg.installed_version '2.16.60.0' 'explicit four-part state'
    }

    Test-Case 'winget explicit version install remains exact' {
        $r = Invoke-Cli @('install', 'winget:New.Tool', '--pkg-version', '1.5.0', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'explicit version install exit'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'explicit version install must be ok'
        Assert-True $j.results[0].verified 'explicit version install must be verified'
        Assert-Match $j.results[0].verification "installed version '1.5.0'" 'explicit version verification'
        $state = Get-Content -LiteralPath $env:PKGS_FAKE_STATE -Raw | ConvertFrom-Json
        $pkg = @($state.winget.packages | Where-Object id -eq 'New.Tool')[0]
        Assert-Equal $pkg.installed_version '1.5.0' 'explicit installed version'
    }

    Test-Case 'winget postcondition version equivalence accepts only the narrow trailing-zero shape' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
$cases = @(
    @('2.16.60', '2.16.60', $true),
    @('2.16.60', '2.16.60.0', $true),
    @('2.16.60.0', '2.16.60', $true),
    @('2.16.60.0', '2.16.60.0', $true),
    @('2.16.60', '2.16.60.1', $false),
    @('2.16.60', '2.16.61.0', $false),
    @('2.16.60', '2.16.6.0', $false),
    @('2.16.60', '2.16.600', $false),
    @('2.16.60', '2.16.60-preview', $false),
    @('2.16.60', '2.16.60.0-preview', $false),
    @('2.16.60', '2.16.60.0.0', $false),
    @('2.16.60', '2.16.60.00', $false),
    @('2.16.60', '2.16.60.', $false),
    @('2.16.60', 'v2.16.60', $false),
    @('2.16.60', '', $false),
    @('', '2.16.60', $false),
    @('2.16.60', 'Unknown', $false),
    @('999999999999999999999.2.3', '999999999999999999999.2.3.0', $true),
    @('999999999999999999999.2.3', '999999999999999999999.2.3.1', $false)
)
$bad = @()
foreach ($case in $cases) {
    $got = Test-PkgsWingetVersionEquivalent -Expected $case[0] -Actual $case[1]
    if ($got -ne $case[2]) { $bad += "$($case[0])|$($case[1])|$got" }
}
if ($bad.Count -gt 0) { "BAD=$($bad -join ';')"; exit 1 }
'MATRIX=PASS'
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "equivalence helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'MATRIX=PASS' 'equivalence matrix'
    }

    Test-Case 'winget postflight accepts the WinMerge 2.16.60 four-part zero form' {
        Add-WinMergeState
        $env:PKGS_FAKE_OUTDATED = 'outdated-winmerge.json'
        $env:PKGS_FAKE_MUTATION_VERSION = '2.16.60.0'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'winget:WinMerge.WinMerge', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'WinMerge equivalent upgrade exit'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-True $j.ok 'equivalent WinMerge upgrade must be ok'
        Assert-True $j.results[0].verified 'equivalent WinMerge upgrade must be verified'
        Assert-Equal $j.results[0].backend_exit 0 'backend exit'
        Assert-Match $j.results[0].verification "installed version '2.16.60.0'" 'raw actual version'
        $state = Get-Content -LiteralPath $env:PKGS_FAKE_STATE -Raw | ConvertFrom-Json
        $pkg = @($state.winget.packages | Where-Object id -eq 'WinMerge.WinMerge')[0]
        Assert-Equal $pkg.installed_version '2.16.60.0' 'raw fake state version'
        $log = @(Get-Content -LiteralPath $env:PKGS_FAKE_LOG -ErrorAction Stop)
        Assert-Equal $log.Count 1 'exactly one WinMerge upgrade invocation'
        Assert-Match $log[0] '^winget upgrade --id WinMerge\.WinMerge --exact --source winget' 'exact WinMerge upgrade invocation'
    }

    Test-Case 'winget postflight rejects a genuine fourth-component difference' {
        Add-WinMergeState
        $env:PKGS_FAKE_OUTDATED = 'outdated-winmerge.json'
        $env:PKGS_FAKE_MUTATION_VERSION = '2.16.60.1'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('upgrade', 'winget:WinMerge.WinMerge', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'fourth-component failure exit'
        Assert-SingleEnvelope $r
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'fourth-component difference must not be ok'
        Assert-True (-not $j.results[0].verified) 'fourth-component difference must not be verified'
        Assert-Equal $j.results[0].backend_exit 0 'backend exit'
        Assert-Match $j.results[0].verification "2\.16\.60\.1.*expected '2\.16\.60'" 'raw fourth-component reason'
        $log = @(Get-Content -LiteralPath $env:PKGS_FAKE_LOG -ErrorAction Stop)
        Assert-Equal $log.Count 1 'one attempted WinMerge upgrade'
    }

    Test-Case 'winget postflight rejects mpm disagreement after an equivalent WinGet match' {
        Add-WinMergeState
        $env:PKGS_FAKE_OUTDATED = 'outdated-winmerge.json'
        $env:PKGS_FAKE_MUTATION_VERSION = '2.16.60.0'
        $env:PKGS_FAKE_MPM_VERSION_OVERRIDE = 'WinMerge.WinMerge=2.16.60'
        $r = Invoke-Cli @('upgrade', 'winget:WinMerge.WinMerge', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'provider disagreement exit'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'provider disagreement must not be ok'
        Assert-True (-not $j.results[0].verified) 'provider disagreement must not be verified'
        Assert-Match $j.results[0].verification "winget reports version '2\.16\.60\.0' but mpm reports '2\.16\.60'" 'provider disagreement reason'
    }

    Test-Case 'winget postflight rejects WinGet disagreement after an equivalent mpm match' {
        Add-WinMergeState -InstalledVersion '2.16.60.0'
        $env:PKGS_FAKE_WINGET_VERSION = '2.16.60'
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
$entry = [pscustomobject]@{
    manager = 'winget'; id = 'WinMerge.WinMerge'; operation = 'upgrade'
    from = '2.16.58.2'; to = '2.16.60'; version = ''; winget_source = 'winget'
}
$result = Test-PkgsEntryResult -Entry $entry
"OK=$($result.ok)"
"REASON=$($result.reason)"
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "reverse disagreement helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'OK=False' 'reverse provider disagreement must fail'
        Assert-Match $r.Stdout "winget reports version '2\.16\.60' but mpm reports '2\.16\.60\.0'" 'reverse provider disagreement reason'
    }

    Test-Case 'non-WinGet managers retain strict version semantics' {
        $env:PKGS_FAKE_MUTATION_VERSION = '1.6.0'
        $r = Invoke-Cli @('upgrade', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'scoop version mismatch exit'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'scoop version mismatch must not be ok'
        Assert-True (-not $j.results[0].verified) 'scoop version mismatch must not be verified'
        Assert-Match $j.results[0].verification "version is '1\.6\.0', expected '1\.6'" 'scoop strict version reason'
    }

    Test-Case 'winget stale available version refuses before execution' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $false
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot
$c = Get-PkgsConfig
$plan = New-PkgsPlan -Operation install -Targets @('winget:New.Tool') -Snapshot $s -Config $c
$env:PKGS_FAKE_SEARCH = 'search-newer.json'
$results = @(Invoke-PkgsPlan -Plan $plan -CaptureOutput)
"OK=$($results[0].ok)"
"EXIT=$($results[0].exit)"
"MSG=$($results[0].message)"
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'OK=False' 'stale install must not execute'
        Assert-Match $r.Stdout 'EXIT=5' 'stale install result exit'
        Assert-Match $r.Stdout 'available version changed' 'stale install reason'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'stale install invoked the backend'
    }

    Test-Case 'winget direct and mpm post-upgrade disagreement fails' {
        $env:PKGS_FAKE_MPM_VERSION_OVERRIDE = 'shared.app=2.0.9'
        $r = Invoke-Cli @('upgrade', 'winget:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'contradictory post-state reported as ok'
        Assert-Equal $j.results[0].backend_exit 0 'backend exit'
        Assert-Match $j.results[0].verification "mpm reports '2.0.9'" 'mpm disagreement evidence'
    }

    Test-Case 'a plan re-checks protection immediately before execution' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $beforeConfig = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot
$c = Get-PkgsConfig
$plan = New-PkgsPlan -Operation upgrade -Targets @('scoop:shared.app') -Snapshot $s -Config $c
$raw = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw | ConvertFrom-Json
$raw.ignored = @($raw.ignored) + [pscustomobject]@{ manager = 'scoop'; id = 'shared.app'; reason = 'added after the plan'; kind = 'ignore'; added = '2026-01-01' }
$raw | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $env:PKGS_CONFIG -Encoding utf8
$results = @(Invoke-PkgsPlan -Plan $plan -CaptureOutput)
"OK=$($results[0].ok)"
"VERIFIED=$($results[0].verified)"
"MSG=$($results[0].message)"
'@
        try {
            $r = Invoke-UiHelper -Body $body
            Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
            Assert-Match $r.Stdout 'OK=False' 'stale plan must not execute'
            Assert-Match $r.Stdout 'VERIFIED=False' 'stale plan must not be verified'
            Assert-Match $r.Stdout 'protection is now active' 'reason'
            Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'backend was invoked for a stale plan'
        }
        finally {
            Set-Content -LiteralPath $env:PKGS_CONFIG -Value $beforeConfig -Encoding utf8
        }
    }

    Test-Case 'local pins are explicit and reversible' {
        $r = Invoke-Cli @('pin', 'npm:typescript', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'local pin exit'
        $cfg = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw | ConvertFrom-Json
        $entry = @($cfg.ignored | Where-Object { $_.manager -eq 'npm' -and $_.id -eq 'typescript' })[0]
        Assert-True ($null -ne $entry) 'local pin entry missing'
        Assert-Equal $entry.kind 'pin' 'local pin kind'

        $r2 = Invoke-Cli @('pin', 'npm:typescript', '--remove', '--yes', '--json')
        Assert-Equal $r2.ExitCode 0 'local unpin exit'
        $cfg = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw | ConvertFrom-Json
        Assert-True (@($cfg.ignored | Where-Object { $_.manager -eq 'npm' -and $_.id -eq 'typescript' }).Count -eq 0) 'local pin entry not removed'
    }

    Test-Case 'winget pin previews are exact and blocking' {
        $r = Invoke-Cli @('pin', 'winget:shared.app', '--dry-run')
        Assert-Equal $r.ExitCode 0 'pin dry-run exit'
        Assert-Match $r.Stdout 'winget pin add --id shared\.app --exact --source winget --blocking' 'blocking exact pin preview'
        $r2 = Invoke-Cli @('pin', 'winget:shared.app', '--remove', '--dry-run')
        Assert-Equal $r2.ExitCode 0 'unpin dry-run exit'
        Assert-Match $r2.Stdout 'winget pin remove --id shared\.app --exact --source winget' 'exact unpin preview'
    }

    Test-Case 'a native pin command that reports success without state change fails' {
        $env:PKGS_FAKE_PIN_NO_STATE = '1'
        $r = Invoke-Cli @('pin', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'false success reported'
        Assert-Match $j.results[0].message 'not present' 'verification evidence'

        # The failed hold must not be treated as protection by a later plan.
        Remove-Item -LiteralPath "Env:PKGS_FAKE_PIN_NO_STATE" -ErrorAction Ignore
        $r2 = Invoke-Cli @('upgrade', 'scoop:shared.app', '--dry-run', '--json')
        Assert-Equal $r2.ExitCode 0 'upgrade dry-run exit'
        $j2 = Get-JsonResult $r2
        Assert-True (-not $j2.plan[0].blocked) 'failed hold became assumed protection'
        Assert-True (-not $j2.plan[0].protected) 'failed hold became protected'
    }

    Test-Case 'a nonzero native pin command propagates failure' {
        $env:PKGS_FAKE_PIN_EXIT = '5'
        $r = Invoke-Cli @('pin', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 5 'exit code'
        $j = Get-JsonResult $r
        Assert-True (-not $j.ok) 'false success reported'
        Assert-Match $j.results[0].message 'native pin command failed' 'failure message'
    }

    Test-Case 'successful scoop hold and unhold are verified by readback' {
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('pin', 'scoop:shared.app', '--yes', '--json')
        Assert-Equal $r.ExitCode 0 'hold exit'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'hold result'
        $log = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log 'scoop hold shared\.app' 'hold command'

        $shown = Invoke-Cli @('show', 'scoop:shared.app', '--json')
        $sj = Get-JsonResult $shown
        Assert-True $sj.packages[0].protected 'hold not visible in inventory'
        Assert-Equal $sj.packages[0].native_pin.mechanism 'scoop hold' 'hold mechanism'

        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r2 = Invoke-Cli @('pin', 'scoop:shared.app', '--remove', '--yes', '--json')
        Assert-Equal $r2.ExitCode 0 'unhold exit'
        $j2 = Get-JsonResult $r2
        Assert-True $j2.ok 'unhold result'
        $log2 = Get-Content -LiteralPath $env:PKGS_FAKE_LOG -Raw
        Assert-Match $log2 'scoop unhold shared\.app' 'unhold command'

        $shown2 = Invoke-Cli @('show', 'scoop:shared.app', '--json')
        $sj2 = Get-JsonResult $shown2
        Assert-True (-not $sj2.packages[0].protected) 'unhold not visible in inventory'
    }

    Test-Case 'excluded/unsupported managers are reported, not silently ignored' {
        $r = Invoke-Cli @('search', 'anything', '--manager', 'uv', '--json')
        Assert-Equal $r.ExitCode 3 'search exit code'
        Assert-Match ($r.Stdout + $r.Stderr) 'do not support search' 'search message'
        $r2 = Invoke-Cli @('install', 'uv:some-tool', '--dry-run', '--json')
        Assert-Equal $r2.ExitCode 5 'dry-run exit code'
        $j = Get-JsonResult $r2
        Assert-True $j.plan[0].blocked 'plan should be blocked'
        Assert-True (-not $j.ok) 'unsupported plan JSON must be false'
        Assert-Equal $j.exit_code 5 'unsupported plan JSON exit code'
        Assert-Match $j.plan[0].reason 'does not support install' 'install reason'
    }

    Test-Case 'install with an explicit version carries the version specifier' {
        $r = Invoke-Cli @('install', 'scoop:newtool', '--pkg-version', '26.05', '--dry-run', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-True $j.ok 'valid dry-run JSON must be true'
        Assert-Equal $j.exit_code 0 'valid dry-run JSON exit code'
        Assert-Equal $j.plan[0].version '26.05' 'version'
        Assert-Match $j.plan[0].native 'scoop install newtool@26\.05' 'native specifier'
        Assert-Match $j.plan[0].invocation 'mpm --scoop install newtool@26\.05' 'invocation'
    }

    # -----------------------------------------------------------------
    #  Interactive plumbing (deterministic fzf double)
    # -----------------------------------------------------------------
    Test-Case 'preview command is safe and renders the real selected item' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot
$c = Get-PkgsConfig
$p = @(Get-PkgsDecoratedPackages -Snapshot $s -Config $c | Where-Object target -eq 'vscode:commandcode.commandcode-vscode')[0]
$rows = @([pscustomobject]@{ Package = $p; Key = Get-PkgsPreviewKey -Target $p.target })
$dir = New-PkgsPreviewFiles -Rows $rows
$cmd = Get-PkgsPreviewCommand -PreviewDir $dir
"CMD=$cmd"
"ESCAPED=" + ($cmd.Contains('\{4}'))
$key = Get-PkgsPreviewKey -Target $p.target
"PRIMARY=" + ((& (Join-Path $PkgsHome 'preview.cmd') (Join-Path $dir "$key.txt") | Out-String) -replace "`r?`n", ' ')
"MISSING=" + ((& (Join-Path $PkgsHome 'preview.cmd') (Join-Path $dir 'missing.txt') | Out-String) -replace "`r?`n", ' ')
$spaced = Join-Path $env:PKGS_TEST_ROOT 'preview with spaces'
$null = New-Item -ItemType Directory -Path $spaced -Force
Copy-Item -LiteralPath (Join-Path $dir "$key.txt") -Destination (Join-Path $spaced 'item.txt') -Force
"SPACED=" + ((& (Join-Path $PkgsHome 'preview.cmd') (Join-Path $spaced 'item.txt') | Out-String) -replace "`r?`n", ' ')
Clear-PkgsPreviewCache
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'CMD=.*\{r4\}' 'raw placeholder missing'
        Assert-Match $r.Stdout 'ESCAPED=False' 'placeholder was escaped'
        Assert-Match $r.Stdout 'PRIMARY=.*Canonical ID vscode:commandcode\.commandcode-vscode' 'real detail missing'
        Assert-Match $r.Stdout 'PRIMARY=.*Command Code for VS Code' 'verified display name missing'
        Assert-Match $r.Stdout 'MISSING=.*no longer available' 'missing-file fallback missing'
        Assert-Match $r.Stdout 'SPACED=.*Canonical ID vscode:commandcode\.commandcode-vscode' 'path with spaces failed'
    }

    Test-Case 'rapid preview changes show the correct package and no stale content' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot
$c = Get-PkgsConfig
$targets = @('cargo:cargo-binstall','vscode:commandcode.commandcode-vscode','winget:Example.Tool')
$pkgs = @($targets | ForEach-Object { $t = $_; @(Get-PkgsDecoratedPackages -Snapshot $s -Config $c | Where-Object target -eq $t)[0] })
$rows = @($pkgs | ForEach-Object { [pscustomobject]@{ Package = $_; Key = Get-PkgsPreviewKey -Target $_.target } })
$dir = New-PkgsPreviewFiles -Rows $rows
foreach ($pkg in $pkgs) {
    $key = Get-PkgsPreviewKey -Target $pkg.target
    $text = (& (Join-Path $PkgsHome 'preview.cmd') (Join-Path $dir "$key.txt") | Out-String)
    "TARGET=$($pkg.target)"
    "HAS_TARGET=" + ($text.Contains("Canonical ID $($pkg.target)"))
    "HAS_OTHER=" + (@($targets | Where-Object { $_ -ne $pkg.target -and $text.Contains($_) }).Count -gt 0)
}
Clear-PkgsPreviewCache
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-True ($r.Stdout -notmatch 'HAS_TARGET=False') 'a preview did not contain its own package'
        Assert-True ($r.Stdout -notmatch 'HAS_OTHER=True') 'a preview contained a different package'
    }

    Test-Case 'narrow and wide layouts stay readable and omit columns predictably' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$wide = Get-PkgsListLayout -Width 140
$narrow = Get-PkgsListLayout -Width 80
"WIDE=$($wide.Mode) MANAGER=$($wide.Manager)"
"NARROW=$($narrow.Mode) MANAGER=$($narrow.Manager)"
$s = Get-PkgsSnapshot; $c = Get-PkgsConfig
$p = @(Get-PkgsDecoratedPackages -Snapshot $s -Config $c | Where-Object target -eq 'cargo:cargo-binstall')[0]
"NARROW_ROW=" + (New-PkgsPackageRow -Package $p -Width 80)
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'WIDE=wide MANAGER=10' 'wide layout'
        Assert-Match $r.Stdout 'NARROW=narrow MANAGER=0' 'narrow layout'
        Assert-Match $r.Stdout 'NARROW_ROW=.*Cargo Tool.*1\.26\.2' 'narrow row lost version/type'
        Assert-True ($r.Stdout -notmatch 'NARROW_ROW=.*Rust cargo') 'narrow row must omit manager column'
    }

    Test-Case 'long canonical IDs remain available in details and are not primary names' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot; $c = Get-PkgsConfig
$longId = ('very-long-package-identifier-' + ('x' * 45))
$stub = [pscustomobject]@{
    manager = 'npm'; id = $longId; name = $null
    installed_version = '1.2.3'; version_known = $true; latest_version = ''
    outdated = $false; update_known = $true; update_method = 'backend outdated listing'
    broken = $false; source = 'npm'; implicit = $false; instances = 1; notes = @()
}
$p = Get-PkgsPackagePresentation -Package $stub -Config $c -NativePins @() -Snapshot $s
$detail = Get-PkgsDetailText -Package $p
$row = New-PkgsPackageRow -Package $p -Width 80
"DETAIL_HAS_TARGET=" + $detail.Contains("npm:$longId")
"ROW_HAS_FULL=" + $row.Contains($longId)
"ROW_ELLIPSIS=" + $row.Contains('...')
"ROW_HAS_SYMBOL=" + ($row -match '[!*~?]')
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'DETAIL_HAS_TARGET=True' 'details must expose the full canonical ID'
        Assert-Match $r.Stdout 'ROW_HAS_FULL=False' 'the full ID must not be the primary row text'
        Assert-Match $r.Stdout 'ROW_ELLIPSIS=True' 'long names must be visibly truncated'
        Assert-Match $r.Stdout 'ROW_HAS_SYMBOL=False' 'row status must not use unexplained symbols'
    }

    Test-Case 'search candidates are presented as installable, not current' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot; $c = Get-PkgsConfig
$candidates = @(Get-PkgsSearchCandidates -Query '7zip' -Snapshot $s -Config $c)
$p = @($candidates | Where-Object target -eq 'choco:7zip')[0]
"TARGET=$($p.target)"
"INSTALLED=$($p.installed_display)"
"STATUS=$($p.status_label)"
"STATE=$($p.update_state)"
"AVAILABLE=$($p.available_display)"
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'TARGET=choco:7zip' 'candidate target'
        Assert-Match $r.Stdout 'INSTALLED=Not installed' 'candidate installed label'
        Assert-Match $r.Stdout 'STATUS=Available to install' 'candidate status'
        Assert-Match $r.Stdout 'STATE=available' 'candidate state'
        Assert-Match $r.Stdout 'AVAILABLE=26\.6\.0' 'candidate available version'
    }

    Test-Case 'native preview keeps commands and drops simulated status lines' {
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$fake = Join-Path $env:PKGS_TEST_ROOT 'fake-plan.ps1'
$lines = @(
    "if (`$args -contains '--version') { 'mpm, version 8.3.0'; exit 0 }"
    "'status scoop.upgrade: demo (0.0s)'"
    "'status Upgraded 1/1 packages'"
    'Write-Output "''C:\fake\scoop.CMD'' update demo"'
    'exit 0'
)
$lines | Set-Content -LiteralPath $fake -Encoding utf8
$env:PKGS_TEST_MPM = $fake
$cmds = @(Get-PkgsNativePreview -Manager 'scoop' -Operation upgrade -Specs @('demo'))
"COUNT=$($cmds.Count)"
"CMD=$($cmds -join '|')"
'@
        $r = Invoke-UiHelper -Body $body
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'COUNT=1' 'status lines were not filtered'
        Assert-Match $r.Stdout 'scoop\.CMD.*update demo' 'command missing'
        Assert-True ($r.Stdout -notmatch 'Upgraded 1/1') 'simulated result leaked into preview'
    }

    Test-Case 'interactive cancellation exits without mutation' {
        $env:PKGS_TEST_TTY = '1'
        $env:PKGS_FAKE_FZF_MODE = 'cancel'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $r = Invoke-Cli @('ui')
        Assert-Equal $r.ExitCode 0 'exit code'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'mutation happened on cancel'
    }

    Test-Case 'UI protect lists exact targets and cancel leaves config untouched' {
        $before = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw
        $stdin = Join-Path $script:TestRoot 'protect-answer.txt'
        "n`n" | Set-Content -LiteralPath $stdin -Encoding utf8
        $body = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsRoot = $PkgsHome
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot
$c = Get-PkgsConfig
$p = @(Get-PkgsDecoratedPackages -Snapshot $s -Config $c | Where-Object { $_.target -in 'scoop:shared.app', 'npm:typescript' })
Invoke-PkgsUiProtect -Packages $p -Config $c
'@
        $r = Invoke-UiHelper -Body $body -StdinFile $stdin
        Assert-Equal $r.ExitCode 0 "helper exit: $($r.Stderr)"
        Assert-Match $r.Stdout 'scoop:shared\.app' 'first target not listed'
        Assert-Match $r.Stdout 'npm:typescript' 'second target not listed'
        $after = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw
        Assert-Equal $after $before 'cancel wrote protection state'
    }

    Test-Case 'interactive multi-select resolves each selection to an exact target' {
        $env:PKGS_TEST_TTY = '1'
        $env:PKGS_FAKE_FZF_MODE = 'all'
        Remove-Item -LiteralPath $env:PKGS_FAKE_LOG -Force -ErrorAction Ignore
        $helper = @'
$PkgsHome = $env:PKGS_TEST_HOME
$script:PkgsJsonRequested = $true
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
$s = Get-PkgsSnapshot
$c = Get-PkgsConfig
$p = @(Get-PkgsDecoratedPackages -Snapshot $s -Config $c | Select-Object -First 3)
$expected = @($p | ForEach-Object target)
$selected = @(Select-PkgsRows -Packages $p -Header 'test')
"COUNT=$($selected.Count)"
"TARGETS=$(@($selected | ForEach-Object target) -join ',')"
"EXPECTED=$($expected -join ',')"
'@
        $env:PKGS_TEST_HOME = $pkgsRoot
        $tmp = Join-Path $script:TestRoot 'ui-test.ps1'
        $helper | Set-Content -LiteralPath $tmp -Encoding utf8
        $out = Join-Path $script:TestRoot 'ui-count.txt'
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -ExecutionPolicy Bypass -File $tmp 1>$out 2>$null
        Assert-Equal $LASTEXITCODE 0 'helper exit'
        $text = Get-Content -LiteralPath $out -Raw
        Assert-Match $text 'COUNT=3' 'selected row count'
        $targetLine = [regex]::Match($text, 'TARGETS=(.*)').Groups[1].Value.Trim()
        $expectedLine = [regex]::Match($text, 'EXPECTED=(.*)').Groups[1].Value.Trim()
        Assert-Equal $targetLine $expectedLine 'selection must map back to exact canonical targets'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_FAKE_LOG)) 'selection invoked a mutation'
        Remove-Item -LiteralPath "Env:PKGS_TEST_HOME" -ErrorAction Ignore
    }

    Test-Case 'action menu returns a deterministic action' {
        $env:PKGS_FAKE_FZF_MODE = 'first'
        $helper = @'
$PkgsHome = $env:PKGS_TEST_HOME
. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
Show-PkgsActionMenu -Items @('Upgrade 2 selected', 'Cancel') -Header 'test'
'@
        $env:PKGS_TEST_HOME = $pkgsRoot
        $tmp = Join-Path $script:TestRoot 'menu-test.ps1'
        $helper | Set-Content -LiteralPath $tmp -Encoding utf8
        $out = Join-Path $script:TestRoot 'menu-out.txt'
        & (Join-Path $PSHOME 'pwsh.exe') -NoProfile -ExecutionPolicy Bypass -File $tmp 1>$out 2>$null
        Assert-Equal $LASTEXITCODE 0 'helper exit'
        Assert-Match (Get-Content -LiteralPath $out -Raw) 'Upgrade 2 selected' 'menu result'
        Remove-Item -LiteralPath "Env:PKGS_TEST_HOME" -ErrorAction Ignore
    }

    # -----------------------------------------------------------------
    #  Supports, help, config
    # -----------------------------------------------------------------
    Test-Case 'show returns package details as JSON' {
        $r = Invoke-Cli @('show', 'scoop:7zip', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-Equal $j.packages[0].target 'scoop:7zip' 'target'
        Assert-True $j.packages[0].protected '7zip should be protected by hold'
    }

    Test-Case 'search returns backend results as JSON' {
        $r = Invoke-Cli @('search', 'tool', '--json')
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        Assert-True ($j.packages.Count -ge 1) 'search results missing'
        Assert-Equal $j.schema 'pkgs/v1' 'schema'
    }

    Test-Case 'pin and ignore dry-runs show native/local commands' {
        $r = Invoke-Cli @('pin', 'scoop:7zip', '--dry-run')
        Assert-Equal $r.ExitCode 0 'pin exit'
        Assert-Match $r.Stdout 'scoop hold 7zip' 'scoop pin command'
        $r2 = Invoke-Cli @('pin', 'npm:typescript', '--dry-run')
        Assert-Equal $r2.ExitCode 0 'local pin exit'
        Assert-Match $r2.Stdout 'local' 'local pin note'
    }

    Test-Case 'ignore add/remove and unprotect update only the test config' {
        $r = Invoke-Cli @('ignore', 'npm:typescript', '--reason', 'unit-test', '--yes')
        Assert-Equal $r.ExitCode 0 'ignore add exit'
        $cfg = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw | ConvertFrom-Json
        Assert-True (@($cfg.ignored | Where-Object { $_.manager -eq 'npm' -and $_.id -eq 'typescript' }).Count -eq 1) 'ignore entry missing'
        $r2 = Invoke-Cli @('ignore', 'npm:typescript', '--remove', '--yes')
        Assert-Equal $r2.ExitCode 0 'ignore remove exit'
        $cfg = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw | ConvertFrom-Json
        Assert-True (@($cfg.ignored | Where-Object { $_.manager -eq 'npm' -and $_.id -eq 'typescript' }).Count -eq 0) 'ignore entry not removed'
        $r3 = Invoke-Cli @('unprotect', 'npm:typescript', '--yes')
        Assert-Equal $r3.ExitCode 0 'unprotect exit'
        $cfg = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw | ConvertFrom-Json
        Assert-True (@($cfg.guardExceptions | Where-Object { $_.manager -eq 'npm' -and $_.id -eq 'typescript' }).Count -eq 1) 'guard exception missing'
    }

    Test-Case 'protection changes without --yes are refused and leave config untouched' {
        $before = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw
        $r = Invoke-Cli @('ignore', 'npm:typescript', '--reason', 'silent')
        Assert-Equal $r.ExitCode 3 'ignore exit'
        Assert-Match ($r.Stdout + $r.Stderr) 'require --yes' 'ignore message'
        $r2 = Invoke-Cli @('unprotect', 'npm:typescript')
        Assert-Equal $r2.ExitCode 3 'unprotect exit'
        Assert-Match ($r2.Stdout + $r2.Stderr) 'require --yes' 'unprotect message'
        $after = Get-Content -LiteralPath $env:PKGS_CONFIG -Raw
        Assert-Equal $after $before 'config changed without confirmation'
    }

    Test-Case 'config validate accepts the test configuration' {
        $r = Invoke-Cli @('config', 'validate')
        Assert-Equal $r.ExitCode 0 'exit code'
        Assert-Match $r.Stdout 'valid' 'validation message'
    }

    Test-Case 'doctor --json reports checks and ok' {
        $r = Invoke-Cli @('doctor', '--json')
        Assert-True ($r.ExitCode -in 0, 1) 'unexpected exit'
        $j = Get-JsonResult $r
        Assert-Equal $j.schema 'pkgs/v1' 'schema'
        Assert-True (@($j.checks).Count -gt 0) 'checks missing'
        Assert-True (@($j.checks | Where-Object name -eq 'mpm').Count -eq 1) 'mpm check missing'
    }

    Test-Case 'help and howto are accessible' {
        $r = Invoke-Cli @('howto', 'protection')
        Assert-Equal $r.ExitCode 0 'howto exit'
        Assert-Match $r.Stdout 'native pin' 'howto content'
        $r2 = Invoke-Cli @('help', 'upgrade')
        Assert-Equal $r2.ExitCode 0 'help exit'
        Assert-Match $r2.Stdout 'Never upgrades everything' 'help content'
    }

    Test-Case 'clean removes the cache' {
        $r = Invoke-Cli @('clean')
        Assert-Equal $r.ExitCode 0 'exit code'
        Assert-True (-not (Test-Path -LiteralPath $env:PKGS_CACHE_DIR)) 'cache still exists'
    }

    # -----------------------------------------------------------------
    #  Current directory inside a development repository
    # -----------------------------------------------------------------
    Test-Case 'a repository working directory never adds uv or touches project files' {
        $repo = Join-Path $script:TestRoot 'repo'
        $null = New-Item -ItemType Directory -Path (Join-Path $repo '.git'), (Join-Path $repo '.venv') -Force -ErrorAction Ignore
        '[project]' | Set-Content -LiteralPath (Join-Path $repo 'pyproject.toml') -Encoding utf8
        'marker' | Set-Content -LiteralPath (Join-Path $repo '.venv\marker.txt') -Encoding utf8
        $before = Get-FileHash -LiteralPath (Join-Path $repo '.venv\marker.txt'), (Join-Path $repo 'pyproject.toml') | ForEach-Object Hash

        Remove-Item -LiteralPath $env:PKGS_CACHE_DIR -Recurse -Force -ErrorAction Ignore
        $r = Invoke-Cli @('outdated', '--json') -WorkingDirectory $repo
        Assert-Equal $r.ExitCode 0 'exit code'
        $j = Get-JsonResult $r
        $uv = @($j.managers | Where-Object id -eq 'uv')
        Assert-True ($uv.Count -eq 1 -and $uv[0].excluded) 'uv must be present but excluded'
        Assert-True (@($j.packages | Where-Object manager -eq 'uv').Count -eq 0) 'uv packages must not appear'
        $after = Get-FileHash -LiteralPath (Join-Path $repo '.venv\marker.txt'), (Join-Path $repo 'pyproject.toml') | ForEach-Object Hash
        Assert-Equal (($after -join ',') ) (($before -join ',')) 'project files changed'
    }

    # -----------------------------------------------------------------
    #  Live session / profile regression
    # -----------------------------------------------------------------
    Test-IntegrationCase 'fresh PowerShell session resolves the lazy pkgs function' {
        $out = Join-Path $script:TestRoot 'profile-out.txt'
        $err = Join-Path $script:TestRoot 'profile-err.txt'
        $probe = Join-Path $script:TestRoot 'profile-probe.ps1'
        "pkgs version`nWrite-Output (`"EXIT=`$LASTEXITCODE`")" | Set-Content -LiteralPath $probe -Encoding utf8

        # The installed deployment may be older than the checkout under test.
        # Derive the expected version from the deployment itself, not a literal.
        $deployedScript = Join-Path $HOME 'Documents\PowerShell\lib\pkgs\pkgs.ps1'
        Assert-True (Test-Path -LiteralPath $deployedScript) "deployed pkgs not found at $deployedScript"
        $deployedOut = Join-Path $script:TestRoot 'deployed-version.txt'
        $deployedErr = Join-Path $script:TestRoot 'deployed-version.err.txt'
        $deployed = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') `
            -ArgumentList @('-NoProfile', '-File', $deployedScript, 'version') `
            -RedirectStandardOutput $deployedOut -RedirectStandardError $deployedErr -NoNewWindow -PassThru -Wait
        $deployedText = (Get-Content -LiteralPath $deployedOut -Raw) + (Get-Content -LiteralPath $deployedErr -Raw)
        Assert-Equal $deployed.ExitCode 0 "deployed version exit: $deployedText"
        if ($deployedText -notmatch 'pkgs (?<version>\d+\.\d+\.\d+) \(schema pkgs/v1\)') {
            throw "deployed version is not recognizable: $deployedText"
        }
        $expectedVersion = $Matches.version

        $p = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-File', $probe) `
            -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru -Wait
        $text = (Get-Content -LiteralPath $out -Raw) + (Get-Content -LiteralPath $err -Raw)
        Assert-Equal $p.ExitCode 0 "shell exit: $text"
        Assert-Match $text ("pkgs " + [regex]::Escape($expectedVersion) + " \(schema pkgs/v1\)") 'version output'
        Assert-Match $text 'EXIT=0' 'LASTEXITCODE'
    }

    Test-IntegrationCase 'shortcuts still contains every previous section and the new one' {
        $out = Join-Path $script:TestRoot 'shortcuts-out.txt'
        $p = Start-Process -FilePath (Join-Path $PSHOME 'pwsh.exe') -ArgumentList @('-Command', 'shortcuts') `
            -RedirectStandardOutput $out -RedirectStandardError (Join-Path $script:TestRoot 'shortcuts-err.txt') -NoNewWindow -PassThru -Wait
        $text = Get-Content -LiteralPath $out -Raw
        foreach ($section in 'Navigation', 'Git', 'Workspace', 'Package Management', 'Anode / Agent Desktop', 'Editor', 'Docs', 'Tools', 'Sync', 'Info', 'Keys') {
            Assert-Match $text ([regex]::Escape($section)) "section '$section' missing"
        }
        foreach ($cmd in 'z <name>', 'lazy <msg>', 'ws launch', 'hx <file>', 'tldr <cmd>', 'czsave <msg>', 'pkgs howto') {
            Assert-Match $text ([regex]::Escape($cmd)) "shortcut '$cmd' missing"
        }
    }
}
finally {
    Remove-Item -LiteralPath $script:TestRoot -Recurse -Force -ErrorAction Ignore
    foreach ($name in 'PKGS_CONFIG', 'PKGS_CACHE_DIR', 'PKGS_TEST_MODE', 'PKGS_TEST_MPM', 'PKGS_TEST_WINGET', 'PKGS_TEST_SCOOP',
                      'PKGS_TEST_SCOOP_ROOT', 'PKGS_TEST_CHOCO', 'PKGS_TEST_FZF', 'PKGS_TEST_BAT', 'PKGS_TEST_GSUDO',
                      'PKGS_FAKE_INSTALLED', 'PKGS_FAKE_OUTDATED', 'PKGS_FAKE_MANAGERS', 'PKGS_FAKE_SEARCH', 'PKGS_FAKE_LOG',
                      'PKGS_FAKE_MUTATION_EXIT', 'PKGS_FAKE_FZF_MODE', 'PKGS_FAKE_FZF_INPUT', 'PKGS_TEST_TTY', 'PKGS_NO_INPUT',
                      'PKGS_TEST_HOME', 'PKGS_TEST_VSCODE_EXT_ROOT', 'PKGS_TEST_WIDTH', 'PKGS_TEST_ROOT',
                      'PKGS_FAKE_STATE', 'PKGS_FAKE_STATE_SEED', 'PKGS_FAKE_SKIP_STATE_UPDATE',
                      'PKGS_FAKE_MUTATION_VERSION', 'PKGS_FAKE_INSTALL_VERSION', 'PKGS_FAKE_PIN_EXIT', 'PKGS_FAKE_PIN_NO_STATE', 'PKGS_FAKE_PIN_OUTPUT', 'PKGS_FAKE_MUTATION_OUTPUT',
                      'PKGS_FAKE_WINGET_SOURCE', 'PKGS_FAKE_WINGET_VERSION', 'PKGS_FAKE_WINGET_DUPLICATE', 'PKGS_FAKE_WINGET_LIST_MALFORMED', 'PKGS_FAKE_WINGET_PIN_LIST',
                      'PKGS_FAKE_WINGET_PIN_STATE', 'PKGS_FAKE_WINGET_PIN_ADD_TYPE', 'PKGS_FAKE_WINGET_PIN_ADD_SOURCE', 'PKGS_FAKE_WINGET_PIN_DUPLICATE', 'PKGS_FAKE_WINGET_PIN_NO_STATE',
                      'PKGS_FAKE_WINGET_PIN_ADD_MISSING_TYPE', 'PKGS_FAKE_MPM_VERSION_OVERRIDE', 'PKGS_FAKE_MPM_VERSION_OUTPUT', 'PKGS_FAKE_MPM_VERSION_EXIT') {
        Remove-Item -LiteralPath "Env:$name" -ErrorAction Ignore
    }
}

Write-Host ''
Write-Host "PASS: $script:Pass   FAIL: $script:Fail"
if ($script:Fail -gt 0) {
    Write-Host 'Failures:' -ForegroundColor Red
    foreach ($failure in $script:Failures) { Write-Host "  - $failure" -ForegroundColor Red }
    exit 1
}
exit 0
