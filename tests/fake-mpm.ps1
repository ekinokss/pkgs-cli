# Deterministic test double for the mpm CLI.
# Used only when PKGS_TEST_MODE=1. Never participates in real package operations.

$fixture = Join-Path $PSScriptRoot 'fixtures'
$cliArgs = @($args)
if ($env:PKGS_FAKE_DEBUG) { [IO.File]::AppendAllText($env:PKGS_FAKE_DEBUG, ("ARGS=" + ($cliArgs -join "|") + [Environment]::NewLine)) }
function Get-Fixture([string]$EnvName, [string]$Default) {
    $name = [Environment]::GetEnvironmentVariable($EnvName)
    if (-not $name) { $name = $Default }
    return (Get-Content -LiteralPath (Join-Path $fixture $name) -Raw)
}

function Get-State {
    if (-not $env:PKGS_FAKE_STATE) { return $null }
    if (-not (Test-Path -LiteralPath $env:PKGS_FAKE_STATE)) { return $null }
    return (Get-Content -LiteralPath $env:PKGS_FAKE_STATE -Raw | ConvertFrom-Json -AsHashtable)
}

function Save-State($State) {
    if (-not $env:PKGS_FAKE_STATE) { return }
    $State | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:PKGS_FAKE_STATE -Encoding utf8
}

function Get-ManagerFromArgs {
    return (@($cliArgs | Where-Object { $_ -match '^--[a-z0-9-]+$' -and $_ -notin '--plan', '--table-format', '--no-pip', '--no-uv' } |
             ForEach-Object { $_ -replace '^--', '' } | Select-Object -First 1))
}

function Update-FakeState {
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Spec
    )

    if ($env:PKGS_FAKE_SKIP_STATE_UPDATE) { return }
    $state = Get-State
    if (-not $state) { return }

    $id = $Spec
    $version = ''
    if ($Spec -match '^(?<id>.+)@(?<version>[^@]+)$') {
        $id = $Matches.id
        $version = $Matches.version
    }

    if (-not $state.ContainsKey($Manager)) {
        $state[$Manager] = @{ id = $Manager; name = $Manager; packages = @(); errors = @() }
    }
    $managerObj = $state[$Manager]
    $packages = @($managerObj['packages'])
    $index = -1
    for ($i = 0; $i -lt $packages.Count; $i++) {
        if ([string]$packages[$i]['id'] -ieq $id) { $index = $i; break }
    }

    switch ($Operation) {
        'upgrade' {
            if ($index -ge 0) {
                $latest = ''
                $outdated = Get-Fixture 'PKGS_FAKE_OUTDATED' 'outdated-normal.json' | ConvertFrom-Json -AsHashtable
                if ($outdated.ContainsKey($Manager)) {
                    foreach ($pkg in @($outdated[$Manager]['packages'])) {
                        if ([string]$pkg['id'] -ieq $id) { $latest = [string]$pkg['latest_version']; break }
                    }
                }
                if ($env:PKGS_FAKE_MUTATION_VERSION) { $packages[$index]['installed_version'] = $env:PKGS_FAKE_MUTATION_VERSION }
                elseif ($latest) { $packages[$index]['installed_version'] = $latest }
            }
        }
        'install' {
            if ($index -lt 0) {
                $newVersion = if ($version) { $version }
                              elseif ($env:PKGS_FAKE_INSTALL_VERSION) { $env:PKGS_FAKE_INSTALL_VERSION }
                              else { '1.0.0' }
                $packages += @{ id = $id; name = $id; installed_version = $newVersion }
            }
        }
        'remove' {
            if ($index -ge 0) {
                $packages = @($packages | Where-Object { [string]$_['id'] -ine $id })
            }
        }
    }

    $managerObj['packages'] = @($packages)
    Save-State $state
}

if ($cliArgs -contains '--version') {
    if ($null -ne [Environment]::GetEnvironmentVariable('PKGS_FAKE_MPM_VERSION_OUTPUT')) {
        $env:PKGS_FAKE_MPM_VERSION_OUTPUT
    }
    else {
        'mpm, version 8.3.0'
        'Python 3.14.9, Windows x86-64 (AMD64)'
    }
    if ($env:PKGS_FAKE_MPM_VERSION_EXIT) { exit [int]$env:PKGS_FAKE_MPM_VERSION_EXIT }
    exit 0
}

if ($cliArgs -contains 'managers') {
    $text = Get-Fixture 'PKGS_FAKE_MANAGERS' 'managers-normal.txt'
    if ($env:PKGS_FAKE_DEBUG) { Add-Content -LiteralPath $env:PKGS_FAKE_DEBUG -Value ("MANAGERS len=" + $text.Length) }
    $text
    exit 0
}

if ($cliArgs -contains 'search') {
    Get-Fixture 'PKGS_FAKE_SEARCH' 'search-normal.json'
    exit 0
}

if ($cliArgs -contains '--plan') {
    $operation = @('upgrade', 'install', 'remove') | Where-Object { $cliArgs -contains $_ } | Select-Object -First 1
    $manager = @($cliArgs | Where-Object { $_ -match '^--[a-z0-9-]+$' -and $_ -notin '--plan', '--table-format', '--no-pip', '--no-uv' } |
                ForEach-Object { $_ -replace '^--', '' } | Select-Object -First 1)
    if (-not $manager) { $manager = 'winget' }
    $opIndex = [Array]::IndexOf($cliArgs, $operation)
    if ($opIndex -ge 0 -and $opIndex + 1 -lt $cliArgs.Count) {
        foreach ($spec in $cliArgs[($opIndex + 1)..($cliArgs.Count - 1)]) {
            if ($spec -like '--*') { continue }
            switch ($manager) {
                'winget' {
                    if ($operation -eq 'remove') { "winget uninstall --id $spec --source winget" }
                    else { "winget install --id $spec --accept-package-agreements" }
                }
                'scoop' {
                    if ($operation -eq 'upgrade') { "scoop update $spec" }
                    elseif ($operation -eq 'remove') { "scoop uninstall $spec --purge" }
                    else { "scoop install $spec" }
                }
                'npm' { "npm --global upgrade $spec" }
                default { "$manager $operation $spec" }
            }
        }
    }
    exit 0
}

if ($cliArgs -contains 'outdated') {
    $text = Get-Fixture 'PKGS_FAKE_OUTDATED' 'outdated-normal.json'
    if ($env:PKGS_FAKE_DEBUG) {
        [IO.File]::AppendAllText($env:PKGS_FAKE_DEBUG, ("OUTDATED len=" + $text.Length + [Environment]::NewLine))
        if (-not $text) { [IO.File]::AppendAllText($env:PKGS_FAKE_DEBUG, ("EMPTY-OUTDATED args=" + ($cliArgs -join "|") + [Environment]::NewLine)) }
    }
    $text
    exit 0
}

if ($cliArgs -contains 'installed') {
    $file = [Environment]::GetEnvironmentVariable('PKGS_FAKE_INSTALLED')
    if ($file -eq 'malformed') {
        Get-Content -LiteralPath (Join-Path $fixture 'installed-malformed.txt') -Raw
        exit 0
    }
    if (-not $file -and $env:PKGS_FAKE_STATE) {
        $state = Get-State
        if ($state) {
            if ($env:PKGS_FAKE_MPM_VERSION_OVERRIDE -match '^(?<id>[^=]+)=(?<version>.+)$') {
                $overrideId = $Matches.id
                $overrideVersion = $Matches.version
                if ($state.ContainsKey('winget')) {
                    foreach ($pkg in @($state['winget']['packages'])) {
                        if ([string]$pkg['id'] -ieq $overrideId) { $pkg['installed_version'] = $overrideVersion }
                    }
                }
            }
            $state | ConvertTo-Json -Depth 12
            exit 0
        }
    }
    if ($file) { Get-Content -LiteralPath (Join-Path $fixture $file) -Raw }
    else { Get-Fixture 'PKGS_FAKE_INSTALLED' 'installed-normal.json' }
    exit 0
}

if ($cliArgs -contains 'upgrade' -or $cliArgs -contains 'install' -or $cliArgs -contains 'remove') {
    $operation = @('upgrade', 'install', 'remove') | Where-Object { $cliArgs -contains $_ } | Select-Object -First 1
    $manager = Get-ManagerFromArgs
    if (-not $manager) { $manager = 'winget' }
    $opIndex = [Array]::IndexOf($cliArgs, $operation)
    $spec = ''
    if ($opIndex -ge 0 -and $opIndex + 1 -lt $cliArgs.Count) {
        $spec = @($cliArgs[($opIndex + 1)..($cliArgs.Count - 1)] | Where-Object { $_ -notlike '--*' } | Select-Object -First 1)
    }
    if ($spec) { Update-FakeState -Manager ([string]$manager) -Operation ([string]$operation) -Spec ([string]$spec) }
    if ($env:PKGS_FAKE_LOG) { Add-Content -LiteralPath $env:PKGS_FAKE_LOG -Value ($cliArgs -join ' ') }
    if ($env:PKGS_FAKE_MUTATION_OUTPUT) { $env:PKGS_FAKE_MUTATION_OUTPUT }
    $code = 0
    if ($env:PKGS_FAKE_MUTATION_EXIT) { $code = [int]$env:PKGS_FAKE_MUTATION_EXIT }
    exit $code
}

exit 0
