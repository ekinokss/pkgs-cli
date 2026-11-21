# Deterministic test double for winget. Test-only.
$fixture = Join-Path $PSScriptRoot 'fixtures'
$cliArgs = @($args)

function Get-Fixture([string]$Name) {
    return (Get-Content -LiteralPath (Join-Path $fixture $Name) -Raw)
}

function Get-FakeState {
    if (-not $env:PKGS_FAKE_STATE) { return $null }
    if (-not (Test-Path -LiteralPath $env:PKGS_FAKE_STATE)) { return $null }
    return (Get-Content -LiteralPath $env:PKGS_FAKE_STATE -Raw | ConvertFrom-Json -AsHashtable)
}

function Write-FakeWingetList {
    param([string]$Id)

    $rows = @()
    $state = Get-FakeState
    if ($state -and $state.ContainsKey('winget')) {
        foreach ($pkg in @($state['winget']['packages'])) {
            if ([string]$pkg['id'] -ine $Id) { continue }
            $source = if ($pkg.ContainsKey('source')) { [string]$pkg['source'] } else { 'winget' }
            if ($env:PKGS_FAKE_WINGET_SOURCE) { $source = $env:PKGS_FAKE_WINGET_SOURCE }
            $version = if ($env:PKGS_FAKE_WINGET_VERSION) { $env:PKGS_FAKE_WINGET_VERSION } else { [string]$pkg['installed_version'] }
            $name = if ($pkg['name']) { [string]$pkg['name'] } else { [string]$pkg['id'] }
            $rows += [pscustomobject]@{ Name = $name; Id = [string]$pkg['id']; Version = $version; Source = $source }
        }
    }
    if ($env:PKGS_FAKE_WINGET_DUPLICATE -and $rows.Count -eq 1) { $rows += $rows[0] }
    if ($env:PKGS_FAKE_WINGET_LIST_MALFORMED) { 'unreadable winget list output'; exit 0 }
    if ($rows.Count -eq 0) {
        'No installed package found matching input criteria.'
        exit -1978335212
    }

    $includeSource = @($rows | Where-Object { $_.Source }).Count -gt 0
    $nameWidth = [Math]::Max(4, (@($rows | ForEach-Object { $_.Name.Length }) + 4 | Measure-Object -Maximum).Maximum)
    $idWidth = [Math]::Max(2, (@($rows | ForEach-Object { $_.Id.Length }) + 2 | Measure-Object -Maximum).Maximum)
    $versionWidth = [Math]::Max(7, (@($rows | ForEach-Object { $_.Version.Length }) + 7 | Measure-Object -Maximum).Maximum)

    $header = 'Name'.PadRight($nameWidth) + '  ' + 'Id'.PadRight($idWidth) + '  ' + 'Version'.PadRight($versionWidth)
    if ($includeSource) { $header += '  Source' }
    $header
    ('-' * $header.Length)
    foreach ($row in $rows) {
        $line = $row.Name.PadRight($nameWidth) + '  ' + $row.Id.PadRight($idWidth) + '  ' + $row.Version.PadRight($versionWidth)
        if ($includeSource) { $line += '  ' + $row.Source }
        $line
    }
    exit 0
}

function Update-FakeState {
    param([string]$Manager, [string]$Operation, [string]$Id, [string]$Version)

    if ($env:PKGS_FAKE_DEBUG) {
        Add-Content -LiteralPath $env:PKGS_FAKE_DEBUG -Value "STATE op=$Operation manager=$Manager id=$Id version=$Version path=$env:PKGS_FAKE_STATE skip=$env:PKGS_FAKE_SKIP_STATE_UPDATE"
    }
    if ($env:PKGS_FAKE_SKIP_STATE_UPDATE) { return }
    if (-not $env:PKGS_FAKE_STATE) { return }
    if (-not (Test-Path -LiteralPath $env:PKGS_FAKE_STATE)) { return }

    $state = Get-Content -LiteralPath $env:PKGS_FAKE_STATE -Raw | ConvertFrom-Json -AsHashtable
    if (-not $state.ContainsKey($Manager)) {
        $state[$Manager] = @{ id = $Manager; name = $Manager; packages = @(); errors = @() }
    }
    $managerObj = $state[$Manager]
    $packages = @($managerObj['packages'])
    $index = -1
    for ($i = 0; $i -lt $packages.Count; $i++) {
        if ([string]$packages[$i]['id'] -ieq $Id) { $index = $i; break }
    }

    switch ($Operation) {
        'upgrade' {
            if ($index -ge 0) {
                $latest = ''
                $outdated = Get-Fixture 'outdated-normal.json' | ConvertFrom-Json -AsHashtable
                if ($outdated.ContainsKey($Manager)) {
                    foreach ($pkg in @($outdated[$Manager]['packages'])) {
                        if ([string]$pkg['id'] -ieq $Id) { $latest = [string]$pkg['latest_version']; break }
                    }
                }
                if ($env:PKGS_FAKE_MUTATION_VERSION) { $packages[$index]['installed_version'] = $env:PKGS_FAKE_MUTATION_VERSION }
                elseif ($latest) { $packages[$index]['installed_version'] = $latest }
            }
        }
        'install' {
            if ($index -lt 0) {
                $newVersion = if ($env:PKGS_FAKE_MUTATION_VERSION) { $env:PKGS_FAKE_MUTATION_VERSION }
                              elseif ($Version) { $Version }
                              elseif ($env:PKGS_FAKE_INSTALL_VERSION) { $env:PKGS_FAKE_INSTALL_VERSION }
                              else {
                                  $latest = ''
                                  $searchName = if ($env:PKGS_FAKE_SEARCH) { $env:PKGS_FAKE_SEARCH } else { 'search-normal.json' }
                                  $searchPath = Join-Path $fixture $searchName
                                  if (Test-Path -LiteralPath $searchPath) {
                                      $search = Get-Content -LiteralPath $searchPath -Raw | ConvertFrom-Json -AsHashtable
                                      if ($search.ContainsKey('winget')) {
                                          foreach ($searchPkg in @($search['winget']['packages'])) {
                                              if ([string]$searchPkg['id'] -ieq $Id) { $latest = [string]$searchPkg['latest_version']; break }
                                          }
                                      }
                                  }
                                  if ($latest) { $latest } else { '1.0.0' }
                              }
                $packages += @{ id = $Id; name = $Id; installed_version = $newVersion; source = 'winget' }
            }
        }
        'uninstall' {
            if ($index -ge 0) {
                $packages = @($packages | Where-Object { [string]$_['id'] -ine $Id })
            }
        }
    }

    $managerObj['packages'] = @($packages)
    $state | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $env:PKGS_FAKE_STATE -Encoding utf8
}

function Get-FakeWingetPins {
    if (-not $env:PKGS_FAKE_WINGET_PIN_STATE) { return $null }
    $data = @()
    if (Test-Path -LiteralPath $env:PKGS_FAKE_WINGET_PIN_STATE) {
        $data = @(Get-Content -LiteralPath $env:PKGS_FAKE_WINGET_PIN_STATE -Raw | ConvertFrom-Json)
    }
    return [pscustomobject]@{ Pins = @($data) }
}

function Save-FakeWingetPins {
    param([object[]]$Pins)
    if (-not $env:PKGS_FAKE_WINGET_PIN_STATE) { return }
    ConvertTo-Json -InputObject @($Pins) -Depth 6 |
        Set-Content -LiteralPath $env:PKGS_FAKE_WINGET_PIN_STATE -Encoding utf8
}

function Write-FakeWingetPinTable {
    param([object[]]$Pins)

    if (@($Pins).Count -eq 0) {
        'There are no pins configured.'
        exit 0
    }
    $rows = @($Pins | ForEach-Object {
        [pscustomobject]@{
            Name = [string]$_.id
            Id = [string]$_.id
            Version = '1.0.0'
            Source = [string]$_.source
            PinType = [string]$_.type
        }
    })
    $nameWidth = [Math]::Max(4, (@($rows | ForEach-Object { $_.Name.Length }) + 4 | Measure-Object -Maximum).Maximum)
    $idWidth = [Math]::Max(2, (@($rows | ForEach-Object { $_.Id.Length }) + 2 | Measure-Object -Maximum).Maximum)
    $versionWidth = [Math]::Max(7, (@($rows | ForEach-Object { $_.Version.Length }) + 7 | Measure-Object -Maximum).Maximum)
    $sourceWidth = [Math]::Max(6, (@($rows | ForEach-Object { $_.Source.Length }) + 6 | Measure-Object -Maximum).Maximum)
    $header = 'Name'.PadRight($nameWidth) + '  ' + 'Id'.PadRight($idWidth) + '  ' + 'Version'.PadRight($versionWidth) + '  ' + 'Source'.PadRight($sourceWidth) + '  Pin type'
    $header
    ('-' * $header.Length)
    foreach ($row in $rows) {
        $row.Name.PadRight($nameWidth) + '  ' + $row.Id.PadRight($idWidth) + '  ' + $row.Version.PadRight($versionWidth) + '  ' + $row.Source.PadRight($sourceWidth) + '  ' + $row.PinType
    }
    exit 0
}

if ($cliArgs -contains 'pin') {
    if ($cliArgs -contains 'list') {
        if ($env:PKGS_FAKE_WINGET_PIN_LIST -eq 'empty') { exit 0 }
        if ($env:PKGS_FAKE_WINGET_PIN_LIST) { Get-Fixture $env:PKGS_FAKE_WINGET_PIN_LIST; exit 0 }
        $statePins = Get-FakeWingetPins
        if ($null -ne $statePins) { Write-FakeWingetPinTable -Pins @($statePins.Pins) }
        Get-Fixture 'winget-pins.txt'
        exit 0
    }

    $pinId = ''
    $pinSource = 'winget'
    for ($i = 0; $i -lt $cliArgs.Count; $i++) {
        if ($cliArgs[$i] -eq '--id' -and $i + 1 -lt $cliArgs.Count) { $pinId = [string]$cliArgs[$i + 1] }
        if ($cliArgs[$i] -eq '--source' -and $i + 1 -lt $cliArgs.Count) { $pinSource = [string]$cliArgs[$i + 1] }
    }
    $state = Get-FakeWingetPins
    if ($null -ne $state -and -not $env:PKGS_FAKE_WINGET_PIN_NO_STATE -and -not $env:PKGS_FAKE_PIN_NO_STATE) {
        $pinState = @($state.Pins)
        if ($cliArgs -contains 'add') {
            $type = if ($env:PKGS_FAKE_WINGET_PIN_ADD_MISSING_TYPE) { '' }
                    elseif ($env:PKGS_FAKE_WINGET_PIN_ADD_TYPE) { $env:PKGS_FAKE_WINGET_PIN_ADD_TYPE }
                    elseif ($cliArgs -contains '--blocking') { 'Blocking' }
                    else { 'Pinning' }
            $source = if ($env:PKGS_FAKE_WINGET_PIN_ADD_SOURCE) { $env:PKGS_FAKE_WINGET_PIN_ADD_SOURCE } else { $pinSource }
            $pinState += [pscustomobject]@{ id = $pinId; source = $source; type = $type }
            if ($env:PKGS_FAKE_WINGET_PIN_DUPLICATE) {
                $pinState += [pscustomobject]@{ id = $pinId; source = $source; type = $type }
            }
            Save-FakeWingetPins -Pins $pinState
        }
        elseif ($cliArgs -contains 'remove') {
            $pinState = @($pinState | Where-Object {
                -not ([string]$_.id -ieq $pinId -and [string]$_.source -ieq $pinSource)
            })
            Save-FakeWingetPins -Pins $pinState
        }
    }

    if ($env:PKGS_FAKE_PIN_OUTPUT) { $env:PKGS_FAKE_PIN_OUTPUT }
    if ($env:PKGS_FAKE_LOG) { Add-Content -LiteralPath $env:PKGS_FAKE_LOG -Value ('winget ' + ($cliArgs -join ' ')) }
    if ($env:PKGS_FAKE_PIN_EXIT) { exit [int]$env:PKGS_FAKE_PIN_EXIT }
    exit 0
}

if ($cliArgs -contains 'list' -and $cliArgs -contains '--id' -and -not ($cliArgs -contains 'msstore')) {
    $queryId = ''
    for ($i = 0; $i -lt $cliArgs.Count; $i++) {
        if ($cliArgs[$i] -eq '--id' -and $i + 1 -lt $cliArgs.Count) { $queryId = [string]$cliArgs[$i + 1] }
    }
    Write-FakeWingetList -Id $queryId
}

if ($cliArgs -contains 'list' -and $cliArgs -contains 'msstore') {
    Get-Fixture 'msstore-list.txt'
    exit 0
}

if ($cliArgs -contains 'upgrade' -and $cliArgs -contains 'msstore' -and -not ($cliArgs -contains '--id')) {
    Get-Fixture 'msstore-upgrade.txt'
    exit 0
}

if ($cliArgs -contains 'search') {
    Get-Fixture 'msstore-search.txt'
    exit 0
}

if ($env:PKGS_FAKE_LOG) { Add-Content -LiteralPath $env:PKGS_FAKE_LOG -Value ('winget ' + ($cliArgs -join ' ')) }

$operation = @('upgrade', 'install', 'uninstall') | Where-Object { $cliArgs -contains $_ } | Select-Object -First 1
if ($env:PKGS_FAKE_DEBUG) {
    Add-Content -LiteralPath $env:PKGS_FAKE_DEBUG -Value "ARGS op=$operation all=$($cliArgs -join '|')"
}
if ($operation) {
    $id = ''
    $version = ''
    for ($i = 0; $i -lt $cliArgs.Count; $i++) {
        if ($cliArgs[$i] -eq '--id' -and $i + 1 -lt $cliArgs.Count) { $id = [string]$cliArgs[$i + 1] }
        if ($cliArgs[$i] -eq '--version' -and $i + 1 -lt $cliArgs.Count) { $version = [string]$cliArgs[$i + 1] }
    }
    if ($id) {
        $manager = if ($cliArgs -contains 'msstore') { 'msstore' } else { 'winget' }
        Update-FakeState -Manager $manager -Operation ([string]$operation) -Id $id -Version $version
    }
}

$code = 0
if ($env:PKGS_FAKE_MUTATION_EXIT) { $code = [int]$env:PKGS_FAKE_MUTATION_EXIT }
exit $code
