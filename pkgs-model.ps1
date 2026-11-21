# =====================================================================
#  pkgs-model.ps1 - capabilities, protection, target resolution,
#  mutation plans and execution. Native pin mechanisms are honored.
# =====================================================================

# ---------------------------------------------------------------------
#  Capability matrix (verified against mpm 8.3.0 definitions)
# ---------------------------------------------------------------------
function New-PkgsCapability {
    param(
        [bool]$Installed = $true,
        $Outdated = $false,
        [bool]$Search = $false,
        [bool]$Install = $false,
        [bool]$Upgrade = $false,
        [bool]$Remove = $false,
        [string]$Pin = 'none',
        [string]$Elevation = '',
        [string]$Notes = '',
        [bool]$Unverified = $false
    )
    return [pscustomobject]@{
        installed  = $Installed
        outdated   = $Outdated
        search     = $Search
        install    = $Install
        upgrade    = $Upgrade
        remove     = $Remove
        pin        = $Pin
        elevation  = $Elevation
        notes      = $Notes
        unverified = $Unverified
    }
}

function Get-PkgsCapability {
    param([Parameter(Mandatory)][string]$Manager)

    switch ($Manager.ToLowerInvariant()) {
        'winget' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Pin 'native' -Elevation 'uac' -Notes 'msstore IDs are handled by the msstore adapter; installers may raise UAC'
        }
        'msstore' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Notes 'Microsoft Store packages via winget; mpm does not expose them'
        }
        'scoop' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Pin 'native' -Notes 'scoop hold is honored; user scope, global apps may need -g'
        }
        'choco' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Pin 'native' -Elevation 'gsudo' -Notes 'mpm escalates choco with gsudo'
        }
        'npm' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Notes 'global packages only'
        }
        'pnpm' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Notes 'global packages only'
        }
        'yarn' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Notes 'global packages only'
        }
        'yarn-berry' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Notes 'global packages only'
        }
        'bun' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Notes 'global packages only'
        }
        'uvx' {
            return New-PkgsCapability -Outdated $true -Install $true -Upgrade $true -Remove $true -Notes 'uv tools only'
        }
        'pipx' {
            return New-PkgsCapability -Outdated $true -Install $true -Upgrade $true -Remove $true -Notes 'isolated pipx applications'
        }
        'cargo' {
            return New-PkgsCapability -Search $true -Install $true -Remove $true -Notes 'cargo has no outdated listing and no upgrade command for installed binaries'
        }
        'rustup' {
            return New-PkgsCapability -Outdated $true -Install $true -Upgrade $true -Remove $true -Notes 'toolchains are protected by the default guard'
        }
        'dotnet' {
            return New-PkgsCapability -Search $true -Install $true -Remove $true -Notes 'dotnet tool has no outdated listing; install/remove only'
        }
        'pwsh-gallery' {
            return New-PkgsCapability -Outdated $true -Search $true -Install $true -Upgrade $true -Remove $true -Notes 'upgrade uses Update-PSResource (PSResourceGet)'
        }
        'vscode' {
            return New-PkgsCapability -Install $true -Remove $true -Notes 'VS Code has no backend outdated listing'
        }
        'gh-ext' {
            return New-PkgsCapability -Search $true -Install $true -Remove $true -Notes 'gh has no backend outdated listing'
        }
        'gcloud' {
            return New-PkgsCapability -Outdated $true -Install $true -Remove $true -Notes 'gcloud only updates all components at once; individual upgrade unsupported'
        }
        'micro' {
            return New-PkgsCapability -Search $true -Install $true -Remove $true -Notes 'micro has no backend outdated listing'
        }
        'claude-code-plugins' {
            return New-PkgsCapability -Install $true -Remove $true -Notes 'no backend outdated listing'
        }
        'uv' {
            return New-PkgsCapability -Installed $false -Notes 'environment-relative in mpm; excluded'
        }
        'pip' {
            return New-PkgsCapability -Installed $false -Notes 'replaced by explicit pip interpreters'
        }
        default {
            if ($Manager -like 'pip*') {
                return New-PkgsCapability -Outdated 'on-demand' -Notes 'read-only by policy; update the environment deliberately with pip'
            }
            return New-PkgsCapability -Outdated $true -Search $true -Unverified $true -Notes 'manager is not in the verified capability matrix; read-only'
        }
    }
}

# ---------------------------------------------------------------------
#  Presentation: package type, verified names, update state
# ---------------------------------------------------------------------
function Get-PkgsPackageType {
    param([Parameter(Mandatory)][string]$Manager)

    switch ($Manager.ToLowerInvariant()) {
        'winget' { return 'WinGet Package' }
        'msstore' { return 'Store App' }
        'scoop' { return 'Scoop Package' }
        'choco' { return 'Choco Package' }
        'npm' { return 'npm Global' }
        'pnpm' { return 'pnpm Global' }
        'yarn' { return 'Yarn Global' }
        'yarn-berry' { return 'Yarn Global' }
        'bun' { return 'Bun Global' }
        'uvx' { return 'uv Tool' }
        'pipx' { return 'pipx Tool' }
        'cargo' { return 'Cargo Tool' }
        'rustup' { return 'Rust Toolchain' }
        'dotnet' { return '.NET Tool' }
        'pwsh-gallery' { return 'PS Module' }
        'vscode' { return 'VS Code Ext' }
        'micro' { return 'Micro Plugin' }
        'gcloud' { return 'Google Cloud' }
        'gh-ext' { return 'GitHub CLI Ext' }
        'claude-code-plugins' { return 'Claude Plugin' }
        'antigravity-cli-plugins' { return 'Antigravity' }
        'uv' { return 'Python Environment Package' }
        default {
            if ($Manager -like 'pip*') { return 'Python Library' }
            return 'Package'
        }
    }
}

function Get-PkgsManagerLabel {
    param([string]$Manager, $Snapshot)
    $match = @($Snapshot.managers | Where-Object { $_.id -eq $Manager }) | Select-Object -First 1
    if ($match -and $match.name) { return [string]$match.name }
    return $Manager
}

function Get-PkgsVscodeExtensionsRoot {
    $override = Get-PkgsTestOverride -Name 'PKGS_TEST_VSCODE_EXT_ROOT'
    if ($override) { return $override }
    return (Join-Path $HOME '.vscode\extensions')
}

function Get-PkgsVscodeExtensionName {
    param([string]$Id, [string]$Version)

    $key = "$Id|$Version".ToLowerInvariant()
    if (-not $script:PkgsVscodeNameCache) { $script:PkgsVscodeNameCache = @{} }
    if ($script:PkgsVscodeNameCache.ContainsKey($key)) { return $script:PkgsVscodeNameCache[$key] }

    $result = $null
    $root = Get-PkgsVscodeExtensionsRoot
    if (Test-Path -LiteralPath $root) {
        $candidates = @(Get-ChildItem -LiteralPath $root -Directory -ErrorAction Ignore |
            Where-Object { $_.Name -like "$Id-*" })
        $exact = @()
        $other = @()
        foreach ($dir in $candidates) {
            $manifest = Join-Path $dir.FullName 'package.json'
            if (-not (Test-Path -LiteralPath $manifest)) { continue }
            try {
                $json = Get-Content -LiteralPath $manifest -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
                $display = [string](Get-PkgsProperty $json 'displayName' -Default '')
                $manifestVersion = [string](Get-PkgsProperty $json 'version' -Default '')
                if ($display -match '^%.*%$') { $display = '' }
                if ($display) {
                    $entry = [pscustomobject]@{ display = $display; version = $manifestVersion; modified = $dir.LastWriteTimeUtc }
                    if ($Version -and $manifestVersion -eq $Version) { $exact += $entry }
                    else { $other += $entry }
                }
            }
            catch { }
        }
        if ($exact.Count -gt 0) { $result = $exact[0].display }
        elseif ($other.Count -gt 0) {
            $result = ($other | Sort-Object modified -Descending | Select-Object -First 1).display
        }
    }

    $script:PkgsVscodeNameCache[$key] = $result
    return $result
}

function Get-PkgsDisplayName {
    param([Parameter(Mandatory)]$Package)

    $id = [string]$Package.id
    if ($Package.manager -eq 'vscode') {
        $display = Get-PkgsVscodeExtensionName -Id $id -Version ([string]$Package.installed_version)
        if ($display) {
            return [pscustomobject]@{ Name = $display; Source = 'extension manifest' }
        }
    }
    if ($Package.name -and ([string]$Package.name).Trim() -and ([string]$Package.name) -ne $id) {
        return [pscustomobject]@{ Name = [string]$Package.name; Source = 'package manager' }
    }
    return [pscustomobject]@{ Name = $id; Source = 'canonical id' }
}

function Get-PkgsPackageState {
    param($Package, $Capability, [switch]$InstallCandidate)

    $state = 'unknown'
    $stateLabel = 'Update status unknown'
    $availableDisplay = 'Unknown'
    $evidence = 'manager check failed or incomplete'

    if ($InstallCandidate) {
        $state = 'available'
        $stateLabel = 'Available to install'
        $availableDisplay = if ($Package.latest_version) { [string]$Package.latest_version } else { 'Not available' }
        $evidence = 'manager search result'
    }
    elseif ($Package.broken) {
        $state = 'broken'
        $stateLabel = 'Broken install'
        $availableDisplay = 'Unknown'
        $evidence = 'install is incomplete'
    }
    elseif ($Package.outdated -and $Package.latest_version) {
        $state = 'outdated'
        $stateLabel = 'Update available'
        $availableDisplay = [string]$Package.latest_version
        $evidence = if ($Package.update_method) { [string]$Package.update_method } else { 'backend outdated listing' }
    }
    elseif (-not $Package.version_known -and $Package.manager -notin 'micro', 'rustup') {
        $state = 'unknown'
        $stateLabel = 'Installed version unknown'
        $availableDisplay = 'Unknown'
        $evidence = 'backend did not report an installed version'
    }
    elseif ($Capability.outdated -eq $true -and $Package.update_known) {
        $state = 'current'
        $stateLabel = 'Current'
        $availableDisplay = 'Current'
        $evidence = if ($Package.update_method) { [string]$Package.update_method } else { 'backend outdated listing' }
    }
    elseif ($Capability.outdated -is [string] -and $Capability.outdated -eq 'on-demand') {
        if ($Package.update_known) {
            $state = 'current'
            $stateLabel = 'Current'
            $availableDisplay = 'Current'
            $evidence = if ($Package.update_method) { [string]$Package.update_method } else { 'pip outdated check' }
        }
        else {
            $state = 'unchecked'
            $stateLabel = 'Update check not run'
            $availableDisplay = 'Unknown'
            $evidence = 'pip outdated check not run'
        }
    }
    elseif ($Capability.outdated -ne $true) {
        $state = 'unsupported'
        $stateLabel = 'Update check unsupported'
        $availableDisplay = 'Not available'
        $evidence = 'manager has no outdated listing'
    }

    return [pscustomobject]@{
        state = $state
        label = $stateLabel
        available_display = $availableDisplay
        evidence = $evidence
    }
}
function Get-PkgsPackagePresentation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$Config,
        $NativePins,
        [object[]]$PinErrors = @(),
        [Parameter(Mandatory)]$Snapshot,
        [switch]$InstallCandidate
    )

    $cap = Get-PkgsCapability -Manager $Package.manager
    $protection = if ($InstallCandidate) {
        [pscustomobject]@{ protected = $false; native = $false; hardBlock = $false; reasons = @(); summary = '' }
    }
    else {
        Get-PkgsProtection -Package $Package -Config $Config -NativePins $NativePins -PinErrors $PinErrors
    }
    $nativePin = @($NativePins | Where-Object { $_.manager -eq $Package.manager -and $_.id -ieq $Package.id }) | Select-Object -First 1
    $type = Get-PkgsPackageType -Manager $Package.manager
    $nameInfo = Get-PkgsDisplayName -Package $Package
    $managerName = Get-PkgsManagerLabel -Manager $Package.manager -Snapshot $Snapshot

    $installedDisplay = if ($Package.version_known -and $Package.installed_version) { [string]$Package.installed_version }
                        elseif ($Package.manager -eq 'micro' -or $Package.manager -eq 'rustup') { 'Unknown' }
                        else { 'Unknown' }
    if ($InstallCandidate) { $installedDisplay = 'Not installed' }

    $stateInfo = Get-PkgsPackageState -Package $Package -Capability $cap -InstallCandidate:$InstallCandidate
    $state = $stateInfo.state
    $stateLabel = $stateInfo.label
    $availableDisplay = $stateInfo.available_display
    $evidence = $stateInfo.evidence
    $shortState = switch ($state) {
        'available' { 'Available to install' }
        'outdated' { if ($cap.upgrade -eq $true) { 'Update available' } else { 'Manual update' } }
        'current' { 'Current' }
        'unsupported' { 'No update check' }
        'unchecked' { 'Check not run' }
        'broken' { 'Broken install' }
        default { 'Version unknown' }
    }
    $statusLabel = $shortState
    if ($protection.protected) {
        $reason = if ($protection.summary) { $protection.summary } else { 'protected' }
        $reason = switch ($reason) {
            'toolchain guard' { 'guard' }
            'winget pin' { 'pin' }
            'scoop hold' { 'hold' }
            'choco pin' { 'pin' }
            default { $reason }
        }
        $statusLabel = "Protected ($reason) - $shortState"
    }

    $operations = [pscustomobject]@{
        install = ($cap.install -eq $true)
        upgrade = ($cap.upgrade -eq $true)
        remove  = ($cap.remove -eq $true)
    }

    return [pscustomobject]@{
        manager           = $Package.manager
        manager_name      = $managerName
        id                = $Package.id
        name              = $Package.name
        display_name      = $nameInfo.Name
        name_source       = $nameInfo.Source
        type              = $type
        scope             = if ($Package.manager -like 'pip*') { 'Global Python environment' } else { 'Global' }
        installed_version = $Package.installed_version
        version_known     = [bool]$Package.version_known
        installed_display = $installedDisplay
        latest_version    = $Package.latest_version
        available_display = $availableDisplay
        outdated          = [bool]$Package.outdated
        update_known      = [bool]$Package.update_known
        update_state      = $state
        update_label      = $stateLabel
        update_evidence   = $evidence
        broken            = [bool]$Package.broken
        source            = $Package.source
        implicit          = [bool]$Package.implicit
        instances         = [int]$Package.instances
        notes             = @($Package.notes)
        target            = "$($Package.manager):$($Package.id)"
        protected         = [bool]$protection.protected
        protection        = @($protection.reasons)
        protection_summary = $protection.summary
        protected_reason  = if ($protection.summary) { $protection.summary } else { '' }
        native_pin        = if ($nativePin) { [pscustomobject]@{ mechanism = $nativePin.mechanism; detail = $nativePin.detail; type = [string](Get-PkgsProperty -Object $nativePin -Name 'type' -Default ''); source = [string](Get-PkgsProperty -Object $nativePin -Name 'source' -Default '') } } else { $null }
        capability        = $cap
        operations        = $operations
        status_label      = $statusLabel
        install_candidate = [bool]$InstallCandidate
    }
}

function Get-PkgsSnapshotInventoryStats {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Config)

    $pip = 0; $visible = 0; $outdated = 0; $outdatedVisible = 0
    $manual = 0; $protected = 0; $unknown = 0; $unsupported = 0; $broken = 0; $duplicateRows = 0
    foreach ($pkg in @($Snapshot.packages)) {
        $cap = Get-PkgsCapability -Manager $pkg.manager
        $protection = Get-PkgsProtection -Package $pkg -Config $Config -NativePins @($Snapshot.native_pins) -PinErrors @($Snapshot.native_pin_errors)
        $state = Get-PkgsPackageState -Package $pkg -Capability $cap
        $isPip = $pkg.manager -like 'pip*'
        if ($isPip) { $pip++ } else { $visible++ }
        if ($pkg.outdated) {
            $outdated++
            if (-not $isPip) { $outdatedVisible++ }
            if (-not $isPip -and $cap.upgrade -ne $true) { $manual++ }
        }
        if ($protection.protected) { $protected++ }
        if ($state.state -in 'unknown', 'unchecked') { $unknown++ }
        if ($state.state -eq 'unsupported') { $unsupported++ }
        if ($pkg.broken) { $broken++ }
        if ($pkg.instances -gt 1) { $duplicateRows += ($pkg.instances - 1) }
    }

    return [pscustomobject]@{
        total_records          = @($Snapshot.packages).Count
        visible_records        = $visible
        hidden_pip_records     = $pip
        outdated_records       = $outdated
        outdated_visible       = $outdatedVisible
        manual_update_records  = $manual
        protected_records      = $protected
        unknown_update_records = $unknown
        unsupported_update_records = $unsupported
        broken_records         = $broken
        duplicate_source_rows  = $duplicateRows
        managers_detected      = @($Snapshot.managers).Count
        managers_active        = @($Snapshot.managers | Where-Object { -not $_.excluded -and $_.package_count -gt 0 }).Count
        managers_excluded      = @($Snapshot.managers | Where-Object { $_.excluded }).Count
    }
}
function Get-PkgsInventoryStats {
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages, [Parameter(Mandatory)]$Snapshot)

    $pip = @($Packages | Where-Object { $_.manager -like 'pip*' })
    $visible = @($Packages | Where-Object { $_.manager -notlike 'pip*' })
    $outdated = @($Packages | Where-Object { $_.outdated })
    $outdatedVisible = @($outdated | Where-Object { $_.manager -notlike 'pip*' })
    $manualUpdates = @($outdated | Where-Object { $_.operations.upgrade -ne $true })
    $protected = @($Packages | Where-Object { $_.protected })
    $unknown = @($Packages | Where-Object { $_.update_state -in 'unknown', 'unchecked' })
    $unsupported = @($Packages | Where-Object { $_.update_state -eq 'unsupported' })
    $broken = @($Packages | Where-Object { $_.broken })
    $duplicateRows = 0
    foreach ($pkg in $Packages) { if ($pkg.instances -gt 1) { $duplicateRows += ($pkg.instances - 1) } }

    return [pscustomobject]@{
        total_records          = $Packages.Count
        visible_records        = $visible.Count
        hidden_pip_records     = $pip.Count
        outdated_records       = $outdated.Count
        outdated_visible       = $outdatedVisible.Count
        manual_update_records   = $manualUpdates.Count
        protected_records      = $protected.Count
        unknown_update_records = $unknown.Count
        unsupported_update_records = $unsupported.Count
        broken_records         = $broken.Count
        duplicate_source_rows  = $duplicateRows
        managers_detected      = @($Snapshot.managers).Count
        managers_active        = @($Snapshot.managers | Where-Object { -not $_.excluded -and $_.package_count -gt 0 }).Count
        managers_excluded      = @($Snapshot.managers | Where-Object { $_.excluded }).Count
    }
}
# ---------------------------------------------------------------------
#  Protection
# ---------------------------------------------------------------------
function Get-PkgsLiveNativePins {
    param([string[]]$Managers, [switch]$Refresh)

    if (-not $Managers -or $Managers.Count -eq 0) { $Managers = @('winget', 'choco', 'scoop') }
    if (-not $script:PkgsPinCache) { $script:PkgsPinCache = @{} }
    if (-not $script:PkgsPinErrorCache) { $script:PkgsPinErrorCache = @{} }
    $script:PkgsPinReadErrors = @()

    $result = @()
    foreach ($manager in ($Managers | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique)) {
        if (-not $Refresh -and $script:PkgsPinCache.ContainsKey($manager)) {
            $result += @($script:PkgsPinCache[$manager])
            $script:PkgsPinReadErrors += @($script:PkgsPinErrorCache[$manager])
            continue
        }

        $pins = @()
        $pinErrors = @()
        switch ($manager) {
            'winget' {
                $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
                if ($winget) {
                    try {
                        $run = Invoke-PkgsNative -FilePath $winget -TimeoutSeconds 120 -ArgumentList @(
                            'pin', 'list', '--accept-source-agreements', '--disable-interactivity', '--no-progress')
                        if ($run.ExitCode -eq 0) {
                            $pins += @(ConvertFrom-WingetPinList -Text $run.Stdout)
                        }
                        else {
                            $detail = ($run.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
                            if (-not $detail) { $detail = "exit $($run.ExitCode)" }
                            $pinErrors += [pscustomobject]@{ manager = 'winget'; id = ''; scope = 'pins'; message = "winget pin list failed: $detail"; path = '' }
                        }
                    }
                    catch {
                        $pinErrors += [pscustomobject]@{ manager = 'winget'; id = ''; scope = 'pins'; message = "winget pin list failed: $($_.Exception.Message)"; path = '' }
                    }
                }
            }
            'choco' {
                $choco = Get-PkgsTool -Name 'choco' -TestOverride 'PKGS_TEST_CHOCO'
                if ($choco) {
                    try {
                        $run = Invoke-PkgsNative -FilePath $choco -TimeoutSeconds 120 -ArgumentList @('pin', 'list', '--limit-output', '--no-color')
                        if ($run.ExitCode -eq 0) {
                            $pins += @(ConvertFrom-ChocoPinList -Text $run.Stdout)
                        }
                        else {
                            $detail = ($run.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
                            if (-not $detail) { $detail = "exit $($run.ExitCode)" }
                            $pinErrors += [pscustomobject]@{ manager = 'choco'; id = ''; scope = 'pins'; message = "choco pin list failed: $detail"; path = '' }
                        }
                    }
                    catch {
                        $pinErrors += [pscustomobject]@{ manager = 'choco'; id = ''; scope = 'pins'; message = "choco pin list failed: $($_.Exception.Message)"; path = '' }
                    }
                }
            }
            'scoop' {
                $roots = @()
                if (Get-PkgsTool -Name 'scoop' -TestOverride 'PKGS_TEST_SCOOP') { $roots = @(Get-PkgsScoopRoots) }
                $report = Get-PkgsScoopHoldReport -Roots $roots
                $pins += @($report.pins)
                $pinErrors += @($report.errors)
            }
        }
        $script:PkgsPinCache[$manager] = @($pins)
        $script:PkgsPinErrorCache[$manager] = @($pinErrors)
        $script:PkgsPinReadErrors += @($pinErrors)
        $result += @($pins)
    }
    return @($result)
}
function Get-PkgsProtection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Package,
        [Parameter(Mandatory)]$Config,
        $NativePins,
        [object[]]$PinErrors = @()
    )

    $reasons = @()
    $manager = [string]$Package.manager
    $id = [string]$Package.id

    if ($null -eq $NativePins) { $NativePins = @() }
    $pin = @($NativePins | Where-Object { $_.manager -eq $manager -and $_.id -ieq $id }) | Select-Object -First 1
    if ($pin) {
        $reasons += [pscustomobject]@{
            kind      = 'native'
            label     = [string]$pin.mechanism
            detail    = [string]$pin.detail
            type      = [string](Get-PkgsProperty -Object $pin -Name 'type' -Default '')
            source    = [string](Get-PkgsProperty -Object $pin -Name 'source' -Default '')
            hardBlock = $true
        }
    }

    $pinError = @($PinErrors | Where-Object { $_ -and $_.manager -eq $manager -and ([string]$_.id -eq '' -or [string]$_.id -ieq $id) }) | Select-Object -First 1
    if ($pinError) {
        $reasons += [pscustomobject]@{
            kind      = 'pin-read'
            label     = 'protection unknown'
            detail    = [string]$pinError.message
            hardBlock = $true
        }
    }

    $ignored = @($Config.ignored | Where-Object {
        $_ -and $_.manager -eq $manager -and ([string]$_.id) -ieq $id
    }) | Select-Object -First 1
    if ($ignored) {
        $reasons += [pscustomobject]@{
            kind      = 'ignore'
            label     = if ($ignored.kind) { [string]$ignored.kind } else { 'ignore' }
            detail    = [string](Get-PkgsProperty -Object $ignored -Name 'reason' -Default '')
            hardBlock = $false
        }
    }

    $excepted = @($Config.guardExceptions | Where-Object {
        $_ -and $_.manager -eq $manager -and ([string]$_.id) -ieq $id
    }).Count -gt 0
    if (-not $excepted) {
        foreach ($guard in @($Config.guard)) {
            if (-not $guard) { continue }
            if ($guard.manager -ne $manager) { continue }
            try {
                if ($id -match $guard.pattern) {
                    $reasons += [pscustomobject]@{
                        kind      = 'guard'
                        label     = 'toolchain guard'
                        detail    = [string](Get-PkgsProperty -Object $guard -Name 'reason' -Default '')
                        hardBlock = $false
                    }
                    break
                }
            }
            catch { }
        }
    }

    return [pscustomobject]@{
        protected = ($reasons.Count -gt 0)
        native    = [bool]$pin
        hardBlock = (@($reasons | Where-Object { $_.hardBlock }).Count -gt 0)
        reasons   = @($reasons)
        summary   = (@($reasons | ForEach-Object { $_.label }) -join ', ')
    }
}

# ---------------------------------------------------------------------
#  Target resolution
# ---------------------------------------------------------------------
function Find-PkgsManagerById {
    param([string]$Manager, $Snapshot)
    $match = @($Snapshot.managers | Where-Object { $_.id -ieq $Manager }) | Select-Object -First 1
    return $match
}

function Resolve-PkgsTarget {
    <#
        Accepts manager:id, pkg:<manager>/<id>, or a bare id that is
        unique across the installed inventory. Returns the canonical
        backend ID (not the user's spelling).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Spec,
        [Parameter(Mandatory)]$Snapshot,
        [switch]$AllowMissing
    )

    $specText = $Spec.Trim()
    $manager = $null
    $id = $null

    if ($specText -match '^pkg:(?<manager>[^/]+)/(?<id>.+)$') {
        $manager = $Matches.manager
        $id = [uri]::UnescapeDataString($Matches.id)
    }
    elseif ($specText -match '^(?<manager>[A-Za-z0-9][A-Za-z0-9._-]*):(?<id>.+)$') {
        $candidate = $Matches.manager
        if (Find-PkgsManagerById -Manager $candidate -Snapshot $Snapshot) {
            $manager = $candidate
            $id = $Matches.id
        }
    }

    if ($manager -and $id) {
        $record = @($Snapshot.packages | Where-Object { $_.manager -eq $manager -and $_.id -ieq $id }) | Select-Object -First 1
        if (-not $record -and -not $AllowMissing) {
            Stop-Pkgs -Code 4 -Message "'${Manager}:${id}' is not installed or is not in the current inventory (run 'pkgs refresh' if it was just installed)"
        }
        return [pscustomobject]@{
            manager = $manager
            id      = if ($record) { $record.id } else { $id }
            record  = $record
            spec    = if ($record) { "$manager`:$($record.id)" } else { "$manager`:$id" }
        }
    }

    if ($specText -match ':') {
        Stop-Pkgs -Code 2 -Message "unknown manager in target '$specText'"
    }

    $installedMatches = @($Snapshot.packages | Where-Object { $_.id -ieq $specText })
    $managers = @($installedMatches | Select-Object -ExpandProperty manager -Unique)
    if ($managers.Count -gt 1) {
        $candidates = ($installedMatches | ForEach-Object { "  $($_.manager):$($_.id)" }) -join "`n"
        Stop-Pkgs -Code 4 -Message "package '$specText' is installed by multiple managers; use a qualified target:`n$candidates"
    }
    if ($managers.Count -eq 0) {
        if ($AllowMissing) {
            return [pscustomobject]@{ manager = $null; id = $specText; record = $null; spec = $specText }
        }
        Stop-Pkgs -Code 4 -Message "package '$specText' is not installed (qualify it as manager:id for install)"
    }

    $record = $installedMatches[0]
    return [pscustomobject]@{
        manager = $record.manager
        id      = $record.id
        record  = $record
        spec    = "$($record.manager):$($record.id)"
    }
}

# ---------------------------------------------------------------------
#  Fresh reads for mutation verification
# ---------------------------------------------------------------------
function Invoke-PkgsMpmQuery {
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Operation,
        [string]$Query,
        [switch]$Exact
    )
    $mpm = Assert-PkgsMpm
    $cliArgs = @("--$Manager", '--table-format', 'json', $Operation)
    if ($Exact) { $cliArgs += '--exact' }
    if ($Query) { $cliArgs += $Query }
    $run = Invoke-PkgsNative -FilePath $mpm -ArgumentList $cliArgs -TimeoutSeconds 900
    if ($run.ExitCode -ne 0) {
        $detail = ($run.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
        if (-not $detail) { $detail = ($run.Stdout -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1) }
        Stop-Pkgs -Code 5 -Message "mpm $Operation for $Manager failed: $detail"
    }
    return ConvertFrom-MpmInventoryJson -Text $run.Stdout -Kind "$Manager.$Operation"
}

function Get-PkgsFreshOutdated {
    param([Parameter(Mandatory)][string]$Manager, [switch]$Refresh)
    if (-not $script:PkgsFreshOutdated) { $script:PkgsFreshOutdated = @{} }
    if ($Refresh) { $script:PkgsFreshOutdated.Remove($Manager) }
    if ($script:PkgsFreshOutdated.ContainsKey($Manager)) { return $script:PkgsFreshOutdated[$Manager] }

    if ($Manager -eq 'msstore') {
        $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
        if (-not $winget) { Stop-Pkgs -Code 5 -Message 'winget not found for msstore query' }
        $common = @('--accept-source-agreements', '--disable-interactivity', '--no-progress')
        $installed = Invoke-PkgsNative -FilePath $winget -ArgumentList (@('list', '--source', 'msstore') + $common) -TimeoutSeconds 240
        if ($installed.ExitCode -ne 0) {
            $detail = ($installed.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
            Stop-Pkgs -Code 5 -Message "winget Store inventory failed: $detail"
        }
        $upgrade = Invoke-PkgsNative -FilePath $winget -ArgumentList (@('upgrade', '--source', 'msstore') + $common) -TimeoutSeconds 240
        $records = [ordered]@{}
        $null = Add-PkgsWingetStorePackages -Records $records -InstalledText $installed.Stdout -UpgradeText $upgrade.Stdout `
            -UpgradeOk ($upgrade.ExitCode -eq 0) -Anomalies ([ref]$script:PkgsScratchAnomalies) -Errors ([ref]$script:PkgsScratchErrors)
        $script:PkgsFreshOutdated[$Manager] = @($records.Values)
        return $script:PkgsFreshOutdated[$Manager]
    }

    if ($Manager -like 'pip*') { return @() }

    $data = Invoke-PkgsMpmQuery -Manager $Manager -Operation 'outdated'
    $records = @()
    if ($data.managers.ContainsKey($Manager)) {
        foreach ($pkg in $data.managers[$Manager].packages) {
            $id = [string](Get-PkgsProperty -Object $pkg -Name 'id')
            $from = [string](Get-PkgsProperty -Object $pkg -Name 'installed_version')
            $to = [string](Get-PkgsProperty -Object $pkg -Name 'latest_version')
            if (-not $id) { continue }
            if (-not (Test-PkgsPlausibleVersion $from) -or -not (Test-PkgsPlausibleVersion $to)) { continue }
            $records += [pscustomobject]@{ manager = $Manager; id = $id; installed_version = $from; latest_version = $to }
        }
    }
    $script:PkgsFreshOutdated[$Manager] = $records
    return $records
}

function Get-PkgsFreshInstalled {
    param([Parameter(Mandatory)][string]$Manager, [switch]$Refresh)
    if (-not $script:PkgsFreshInstalled) { $script:PkgsFreshInstalled = @{} }
    if ($Refresh) { $script:PkgsFreshInstalled.Remove($Manager) }
    if ($script:PkgsFreshInstalled.ContainsKey($Manager)) { return $script:PkgsFreshInstalled[$Manager] }

    if ($Manager -eq 'msstore') {
        $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
        if (-not $winget) { Stop-Pkgs -Code 5 -Message 'winget not found for msstore query' }
        $common = @('--accept-source-agreements', '--disable-interactivity', '--no-progress')
        $installed = Invoke-PkgsNative -FilePath $winget -ArgumentList (@('list', '--source', 'msstore') + $common) -TimeoutSeconds 240
        if ($installed.ExitCode -ne 0) {
            $detail = ($installed.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
            Stop-Pkgs -Code 5 -Message "winget Store inventory failed: $detail"
        }
        $records = @()
        foreach ($row in (ConvertFrom-WingetTable -Text $installed.Stdout)) {
            $records += [pscustomobject]@{ manager = 'msstore'; id = $row.id; installed_version = $row.version }
        }
        $script:PkgsFreshInstalled[$Manager] = $records
        return $records
    }

    if ($Manager -like 'pip*') {
        $interpreter = @((Get-PkgsConfig).pip.interpreters | Where-Object { $_.id -eq $Manager }) | Select-Object -First 1
        if (-not $interpreter) { return @() }
        $run = Invoke-PkgsNative -FilePath $interpreter.python -ArgumentList @('-m', 'pip', 'list', '--format=json', '--disable-pip-version-check') -TimeoutSeconds 300
        if ($run.ExitCode -ne 0) {
            $detail = ($run.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
            Stop-Pkgs -Code 5 -Message "pip inventory failed for $($Manager): $detail"
        }
        $records = @()
        foreach ($item in @($run.Stdout | ConvertFrom-Json)) {
            $records += [pscustomobject]@{ manager = $Manager; id = $item.name; installed_version = $item.version }
        }
        $script:PkgsFreshInstalled[$Manager] = $records
        return $records
    }

    $data = Invoke-PkgsMpmQuery -Manager $Manager -Operation 'installed'
    $records = @()
    if ($data.managers.ContainsKey($Manager)) {
        foreach ($pkg in $data.managers[$Manager].packages) {
            $records += [pscustomobject]@{
                manager = $Manager
                id = [string](Get-PkgsProperty -Object $pkg -Name 'id')
                installed_version = [string](Get-PkgsProperty -Object $pkg -Name 'installed_version')
            }
        }
    }
    $script:PkgsFreshInstalled[$Manager] = $records
    return $records
}

function Test-PkgsWingetToken {
    <#
        WinGet package IDs and version specifiers are passed as separate argv
        entries, so shell injection is not possible. This still rejects values
        that could be parsed as a WinGet option (leading '-'), contain
        whitespace, or use characters WinGet does not accept in an ID.
    #>
    param([string]$Value, [switch]$AllowVersion, [switch]$AllowBraces)

    if ([string]::IsNullOrWhiteSpace($Value)) { return $false }
    if ($Value -match '^\s' -or $Value -match '\s$') { return $false }
    if ($Value.StartsWith('-')) { return $false }
    if ($Value -match '\s') { return $false }
    if ($AllowBraces) { return ($Value -match '^[A-Za-z0-9{][A-Za-z0-9._+{}\\-]*$') }
    if ($AllowVersion) { return ($Value -match '^[A-Za-z0-9][A-Za-z0-9._+~:-]*$') }
    return ($Value -match '^[A-Za-z0-9][A-Za-z0-9._+-]*$')
}

function Get-PkgsWingetInstalledRecords {
    <#
        Direct WinGet provenance read for one exact package ID.

        mpm's inventory does not expose the installed source. This queries
        WinGet's own installed list without --source (adding --source hides the
        Source column) and without --scope: WinGet's --scope filter has been
        observed to return machine-scoped packages for --scope user and to
        match both scopes for one package, so it cannot prove installation
        scope. Every returned row must carry the exact requested ID; a
        different identity is treated as unreadable evidence.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Id)

    if (-not (Test-PkgsWingetToken -Value $Id)) {
        Stop-Pkgs -Code 5 -Message "refusing a WinGet identity query for an invalid package ID '$Id'"
    }

    $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
    if (-not $winget) { Stop-Pkgs -Code 5 -Message 'winget not found for installed-identity verification' }

    $cliArgs = @(
        'list', '--id', $Id, '--exact',
        '--accept-source-agreements', '--disable-interactivity', '--no-progress'
    )
    $run = Invoke-PkgsNative -FilePath $winget -ArgumentList $cliArgs -TimeoutSeconds 240
    if ($run.ExitCode -ne 0) {
        # 0x8A150014: no installed package found matching the criteria.
        if ($run.ExitCode -eq -1978335212) { return @() }
        if (($run.Stdout + "`n" + $run.Stderr) -match '(?i)no installed package found') { return @() }
        $detail = ($run.Stderr -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1)
        if (-not $detail) { $detail = ($run.Stdout -split "`r?`n" | Where-Object { $_ } | Select-Object -First 1) }
        if (-not $detail) { $detail = "exit $($run.ExitCode)" }
        Stop-Pkgs -Code 5 -Message "winget list failed for '$Id': $detail"
    }

    $rows = @(ConvertFrom-WingetTable -Text $run.Stdout)
    if ($script:LastWingetSkipped -gt 0) {
        Stop-Pkgs -Code 5 -Message "winget list output for '$Id' was not fully readable"
    }

    $records = @()
    $mismatched = @()
    foreach ($row in $rows) {
        if ($row.id -ine $Id) {
            $mismatched += [string]$row.id
            continue
        }
        $records += [pscustomobject]@{
            id      = $row.id
            name    = $row.name
            version = $row.version
            source  = $row.source
        }
    }
    if ($mismatched.Count -gt 0) {
        Stop-Pkgs -Code 5 -Message "winget list returned a different identity for '$Id' ($(@($mismatched) -join ', ')); refusing to mutate"
    }
    return @($records)
}

function Get-PkgsWingetIdentityState {
    <#
        Evaluates the exact WinGet installed identity. A missing package is
        valid for install plans; an installed package must resolve to exactly
        one record, from the expected source, with a readable version.
        Installation scope is not reported by WinGet and is deliberately not
        claimed here.
    #>
    param(
        [Parameter(Mandatory)][string]$Id,
        [string]$ExpectedSource = 'winget'
    )

    if (-not (Test-PkgsWingetToken -Value $Id)) {
        return [pscustomobject]@{
            installed = $null
            ok        = $false
            reason    = "package ID '$Id' is not a valid WinGet identity"
            record    = $null
            records   = @()
        }
    }

    try { $records = @(Get-PkgsWingetInstalledRecords -Id $Id) }
    catch {
        $detail = ($_.Exception.Message -replace '^PKGS_EXIT:\d+:', '').Trim()
        return [pscustomobject]@{
            installed = $null
            ok        = $false
            reason    = "cannot read the installed identity: $detail"
            record    = $null
            records   = @()
        }
    }

    if ($records.Count -eq 0) {
        return [pscustomobject]@{
            installed = $false
            ok        = $true
            reason    = 'not installed'
            record    = $null
            records   = @()
        }
    }
    if ($records.Count -gt 1) {
        $labels = @($records | ForEach-Object { "$($_.id)@$($_.version)[$($_.source)]" }) -join ', '
        return [pscustomobject]@{
            installed = $true
            ok        = $false
            reason    = "multiple installed records matched ($labels); refusing to choose one"
            record    = $null
            records   = @($records)
        }
    }

    $record = $records[0]
    if (-not $record.source) {
        return [pscustomobject]@{
            installed = $true
            ok        = $false
            reason    = 'installed source is not reported by winget; refusing to mutate'
            record    = $record
            records   = @($records)
        }
    }
    if ($ExpectedSource -and $record.source -ne $ExpectedSource) {
        return [pscustomobject]@{
            installed = $true
            ok        = $false
            reason    = "installed source is '$($record.source)', expected '$ExpectedSource'"
            record    = $record
            records   = @($records)
        }
    }
    if (-not (Test-PkgsPlausibleVersion $record.version)) {
        return [pscustomobject]@{
            installed = $true
            ok        = $false
            reason    = "installed version '$($record.version)' is not readable"
            record    = $record
            records   = @($records)
        }
    }

    return [pscustomobject]@{
        installed = $true
        ok        = $true
        reason    = "installed $($record.version) from $($record.source)"
        record    = $record
        records   = @($records)
    }
}

function Get-PkgsFreshSearch {
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Query
    )

    if ($Manager -eq 'msstore') {
        $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
        if (-not $winget) { Stop-Pkgs -Code 5 -Message 'winget not found for msstore query' }
        $run = Invoke-PkgsNative -FilePath $winget -TimeoutSeconds 240 -ArgumentList @(
            'search', '--source', 'msstore', '--id', $Query, '--exact',
            '--accept-source-agreements', '--disable-interactivity', '--no-progress')
        $records = @()
        foreach ($row in (ConvertFrom-WingetTable -Text $run.Stdout)) {
            $records += [pscustomobject]@{ manager = 'msstore'; id = $row.id; latest_version = $row.version; name = $row.name }
        }
        return $records
    }

    $data = Invoke-PkgsMpmQuery -Manager $Manager -Operation 'search' -Query $Query -Exact
    $records = @()
    if ($data.managers.ContainsKey($Manager)) {
        foreach ($pkg in $data.managers[$Manager].packages) {
            $records += [pscustomobject]@{
                manager = $Manager
                id = [string](Get-PkgsProperty -Object $pkg -Name 'id')
                latest_version = [string](Get-PkgsProperty -Object $pkg -Name 'latest_version')
                name = [string](Get-PkgsProperty -Object $pkg -Name 'name')
            }
        }
    }
    return $records
}

# ---------------------------------------------------------------------
#  Plans
# ---------------------------------------------------------------------
function Test-PkgsEntrySafeToExecute {
    <#
        Re-checked immediately before execution. Protection may have changed
        since the plan was shown, and the backend inventory may have moved.
        Returns { ok, reason }.
    #>
    param(
        [Parameter(Mandatory)]$Entry,
        [Parameter(Mandatory)]$Plan
    )

    if ($Entry.manager -eq 'scoop' -and $Entry.operation -in @('upgrade', 'remove')) {
        $scoopIdentity = Get-PkgsScoopIdentityEvidence -Id $Entry.id
        if (-not $scoopIdentity.ok) {
            return [pscustomobject]@{ ok = $false; reason = "Scoop installed identity is not corroborated: $($scoopIdentity.reason)" }
        }
    }

    $config = Get-PkgsConfig -Refresh
    $pins = @(Get-PkgsLiveNativePins -Managers @($Entry.manager) -Refresh)
    $stub = [pscustomobject]@{ manager = $Entry.manager; id = $Entry.id; name = $Entry.name }
    $protection = Get-PkgsProtection -Package $stub -Config $config -NativePins $pins -PinErrors @($script:PkgsPinReadErrors)

    if ($protection.hardBlock) {
        if ($protection.native) {
            return [pscustomobject]@{ ok = $false; reason = "native pin/hold is now present ($($protection.summary))" }
        }
        return [pscustomobject]@{ ok = $false; reason = "native protection state is unreadable ($($protection.summary)); refusing to mutate" }
    }
    $overrideAuthorized = [bool](Get-PkgsProperty -Object $Plan -Name 'override_protection' -Default $false)
    if ($protection.protected -and -not $overrideAuthorized) {
        return [pscustomobject]@{ ok = $false; reason = "pkgs protection is now active ($($protection.summary)); rebuild the plan with an override" }
    }

    $cap = Get-PkgsCapability -Manager $Entry.manager

    if ($Entry.manager -eq 'winget') {
        $identity = Get-PkgsWingetIdentityState -Id $Entry.id
        if (-not $identity.ok) {
            return [pscustomobject]@{ ok = $false; reason = "WinGet identity is now unsafe: $($identity.reason)" }
        }
        if ($Entry.operation -eq 'install') {
            if ($identity.installed) {
                return [pscustomobject]@{ ok = $false; reason = 'target became registered with WinGet after the plan was built' }
            }
        }
        else {
            if (-not $identity.installed) {
                return [pscustomobject]@{ ok = $false; reason = 'target is no longer reported by winget for this exact ID' }
            }
            if ($Entry.from -and ([string]$identity.record.version) -ne [string]$Entry.from) {
                return [pscustomobject]@{ ok = $false; reason = "installed version changed from '$($Entry.from)' to '$($identity.record.version)'" }
            }
            $plannedSource = [string](Get-PkgsProperty -Object $Entry -Name 'winget_source' -Default '')
            if ($plannedSource -and ([string]$identity.record.source) -ne $plannedSource) {
                return [pscustomobject]@{ ok = $false; reason = "installed source changed from '$plannedSource' to '$($identity.record.source)'" }
            }
        }
    }

    switch ($Entry.operation) {
        'upgrade' {
            $fresh = @(Get-PkgsFreshOutdated -Manager $Entry.manager -Refresh | Where-Object { $_.id -ieq $Entry.id } | Sort-Object -Property id -Unique)
            if ($fresh.Count -ne 1) {
                return [pscustomobject]@{ ok = $false; reason = 'target is no longer reported as outdated, or its identity is now ambiguous' }
            }
            if ($Entry.from -and ([string]$fresh[0].installed_version) -ne [string]$Entry.from) {
                return [pscustomobject]@{ ok = $false; reason = "installed version changed from '$($Entry.from)' to '$($fresh[0].installed_version)'" }
            }
            if ($Entry.to -and ([string]$fresh[0].latest_version) -ne [string]$Entry.to) {
                return [pscustomobject]@{ ok = $false; reason = "available version changed from '$($Entry.to)' to '$($fresh[0].latest_version)'; rebuild the plan" }
            }
        }
        'remove' {
            $fresh = @(Get-PkgsFreshInstalled -Manager $Entry.manager -Refresh | Where-Object { $_.id -ieq $Entry.id } | Sort-Object -Property id -Unique)
            if ($fresh.Count -ne 1) {
                return [pscustomobject]@{ ok = $false; reason = 'target is no longer installed exactly once' }
            }
            if ($Entry.from -and ([string]$fresh[0].installed_version) -ne [string]$Entry.from) {
                return [pscustomobject]@{ ok = $false; reason = "installed version changed from '$($Entry.from)' to '$($fresh[0].installed_version)'" }
            }
        }
        'install' {
            $installed = @(Get-PkgsFreshInstalled -Manager $Entry.manager -Refresh | Where-Object { $_.id -ieq $Entry.id } | Sort-Object -Property id -Unique)
            if ($installed.Count -gt 0) {
                return [pscustomobject]@{ ok = $false; reason = 'target became installed after the plan was built' }
            }
            if ($cap.search -eq $true) {
                $found = @(Get-PkgsFreshSearch -Manager $Entry.manager -Query $Entry.id | Where-Object { $_.id -ieq $Entry.id })
                if ($found.Count -ne 1) {
                    return [pscustomobject]@{ ok = $false; reason = 'target is no longer returned exactly once by the manager search' }
                }
                if ($Entry.manager -eq 'winget' -and -not $Entry.version -and $Entry.to -and ([string]$found[0].latest_version) -ne [string]$Entry.to) {
                    return [pscustomobject]@{ ok = $false; reason = "available version changed from '$($Entry.to)' to '$($found[0].latest_version)'; rebuild the plan" }
                }
            }
        }
    }

    return [pscustomobject]@{ ok = $true; reason = '' }
}

function Test-PkgsWingetVersionEquivalent {
    <#
        WinGet may report an installed MSI/EXE version with one extra
        trailing zero component (for example 2.16.60.0) while the manifest
        target is 2.16.60. Accept only that narrow shape for postcondition
        checks. This is not general version normalization: both values must be
        non-empty numeric dot-separated strings, exactly one must have three
        components, the other must have the same three components plus a
        fourth component equal to "0", and all other differences fail.
    #>
    param(
        [string]$Expected,
        [string]$Actual
    )

    if ([string]::IsNullOrWhiteSpace($Expected) -or [string]::IsNullOrWhiteSpace($Actual)) {
        return $false
    }
    if ($Expected -ceq $Actual) {
        return $true
    }

    $expectedParts = @($Expected -split '\.')
    $actualParts = @($Actual -split '\.')
    if ($expectedParts.Count -notin 3, 4 -or $actualParts.Count -notin 3, 4) {
        return $false
    }
    foreach ($part in @($expectedParts + $actualParts)) {
        if ($part -cnotmatch '^[0-9]+$') {
            return $false
        }
    }

    if ($expectedParts.Count -eq 3 -and $actualParts.Count -eq 4) {
        if ($actualParts[3] -cne '0') { return $false }
        $expectedParts = @($expectedParts)
        $actualParts = @($actualParts[0..2])
    }
    elseif ($expectedParts.Count -eq 4 -and $actualParts.Count -eq 3) {
        if ($expectedParts[3] -cne '0') { return $false }
        $expectedParts = @($expectedParts[0..2])
        $actualParts = @($actualParts)
    }
    else {
        return $false
    }

    return (($expectedParts[0] -ceq $actualParts[0]) -and
            ($expectedParts[1] -ceq $actualParts[1]) -and
            ($expectedParts[2] -ceq $actualParts[2]))
}

function Test-PkgsEntryResult {
    <#
        Verifies the live result after a backend reported success. A zero exit
        code alone is not proof that the intended change happened.
    #>
    param([Parameter(Mandatory)]$Entry)

    $expectedInstallVersion = if ($Entry.operation -eq 'install') {
        if ($Entry.version) { [string]$Entry.version }
        elseif ($Entry.manager -eq 'winget' -and $Entry.to) { [string]$Entry.to }
        else { '' }
    }
    else { '' }
    $wingetInstalledVersion = ''

    if ($Entry.manager -eq 'winget') {
        $identity = Get-PkgsWingetIdentityState -Id $Entry.id
        if (-not $identity.ok) {
            return [pscustomobject]@{ ok = $false; reason = "WinGet post-state is unsafe: $($identity.reason)" }
        }
        $plannedSource = [string](Get-PkgsProperty -Object $Entry -Name 'winget_source' -Default '')
        switch ($Entry.operation) {
            'remove' {
                if ($identity.installed) {
                    return [pscustomobject]@{ ok = $false; reason = "winget still reports the package (version '$($identity.record.version)')" }
                }
            }
            'install' {
                if (-not $identity.installed) {
                    return [pscustomobject]@{ ok = $false; reason = 'winget does not report the package after install' }
                }
                $wingetInstalledVersion = [string]$identity.record.version
                if ($expectedInstallVersion) {
                    $versionMatches = if ($Entry.version -and $Entry.manager -eq 'winget') {
                        Test-PkgsWingetVersionEquivalent -Expected $expectedInstallVersion -Actual $wingetInstalledVersion
                    }
                    else {
                        $wingetInstalledVersion -eq $expectedInstallVersion
                    }
                    if (-not $versionMatches) {
                        return [pscustomobject]@{ ok = $false; reason = "winget reports version '$wingetInstalledVersion', expected '$expectedInstallVersion'" }
                    }
                }
            }
            'upgrade' {
                if (-not $identity.installed) {
                    return [pscustomobject]@{ ok = $false; reason = 'winget does not report the package after upgrade' }
                }
                $wingetInstalledVersion = [string]$identity.record.version
                if ($Entry.from -and $wingetInstalledVersion -eq [string]$Entry.from) {
                    return [pscustomobject]@{ ok = $false; reason = "winget version is unchanged at '$wingetInstalledVersion'" }
                }
                if ($Entry.to -and -not (Test-PkgsWingetVersionEquivalent -Expected ([string]$Entry.to) -Actual $wingetInstalledVersion)) {
                    return [pscustomobject]@{ ok = $false; reason = "winget reports version '$wingetInstalledVersion', expected '$($Entry.to)'" }
                }
                if ($plannedSource -and ([string]$identity.record.source) -ne $plannedSource) {
                    return [pscustomobject]@{ ok = $false; reason = "winget reports source '$($identity.record.source)', expected '$plannedSource'" }
                }
            }
        }
    }

    $fresh = @(Get-PkgsFreshInstalled -Manager $Entry.manager -Refresh | Where-Object { $_.id -ieq $Entry.id } | Sort-Object -Property id -Unique)

    switch ($Entry.operation) {
        'remove' {
            if ($fresh.Count -eq 0) { return [pscustomobject]@{ ok = $true; reason = 'target is absent' } }
            return [pscustomobject]@{ ok = $false; reason = "target is still installed (version '$($fresh[0].installed_version)')" }
        }
        'install' {
            if ($fresh.Count -ne 1) {
                return [pscustomobject]@{ ok = $false; reason = "target is not present exactly once after install (found $($fresh.Count))" }
            }
            $now = [string]$fresh[0].installed_version
            if ($expectedInstallVersion) {
                $versionMatches = if ($Entry.version -and $Entry.manager -eq 'winget') {
                    Test-PkgsWingetVersionEquivalent -Expected $expectedInstallVersion -Actual $now
                }
                else {
                    $now -eq $expectedInstallVersion
                }
                if (-not $versionMatches) {
                    return [pscustomobject]@{ ok = $false; reason = "manager reports version '$now', expected '$expectedInstallVersion'" }
                }
            }
            if ($wingetInstalledVersion -and $now -ne $wingetInstalledVersion) {
                return [pscustomobject]@{ ok = $false; reason = "winget reports version '$wingetInstalledVersion' but mpm reports '$now'" }
            }
            if (-not $now -and $Entry.manager -in 'micro', 'rustup') {
                return [pscustomobject]@{ ok = $true; reason = 'target is present; manager does not report installed versions' }
            }
            return [pscustomobject]@{ ok = $true; reason = "installed version '$now'" }
        }
        'upgrade' {
            if ($fresh.Count -ne 1) {
                return [pscustomobject]@{ ok = $false; reason = "target is not present exactly once after upgrade (found $($fresh.Count))" }
            }
            $now = [string]$fresh[0].installed_version
            if (-not $now -and $Entry.manager -in 'micro', 'rustup') {
                return [pscustomobject]@{ ok = $true; reason = 'target is present; manager does not report installed versions' }
            }
            if ($wingetInstalledVersion -and $now -ne $wingetInstalledVersion) {
                return [pscustomobject]@{ ok = $false; reason = "winget reports version '$wingetInstalledVersion' but mpm reports '$now'" }
            }
            if ($Entry.from -and $now -eq [string]$Entry.from) {
                return [pscustomobject]@{ ok = $false; reason = "version is unchanged at '$now'" }
            }
            if ($Entry.to) {
                $versionMatches = if ($Entry.manager -eq 'winget') {
                    Test-PkgsWingetVersionEquivalent -Expected ([string]$Entry.to) -Actual $now
                }
                else {
                    $now -eq [string]$Entry.to
                }
                if (-not $versionMatches) {
                    return [pscustomobject]@{ ok = $false; reason = "version is '$now', expected '$($Entry.to)'" }
                }
            }
            return [pscustomobject]@{ ok = $true; reason = "installed version '$now'" }
        }
    }

    return [pscustomobject]@{ ok = $false; reason = 'unknown operation' }
}

function Get-PkgsWingetMutationArgs {
    <#
        WinGet execution is direct and exact. mpm 8.3.0 renders a WinGet
        upgrade as "winget install --id <id>" without --exact/--source, which
        can match a different package through WinGet's substring search. pkgs
        therefore performs WinGet writes itself with an exact ID and source.
    #>
    param([Parameter(Mandatory)]$Entry)

    $common = @('--accept-source-agreements', '--disable-interactivity', '--no-progress')
    switch ($Entry.operation) {
        'upgrade' {
            return @('upgrade', '--id', [string]$Entry.id, '--exact', '--source', 'winget',
                     '--accept-package-agreements') + $common
        }
        'install' {
            $cliArgs = @('install', '--id', [string]$Entry.id, '--exact', '--source', 'winget',
                         '--accept-package-agreements')
            if ($Entry.version) { $cliArgs += @('--version', [string]$Entry.version) }
            return $cliArgs + $common
        }
        'remove' {
            return @('uninstall', '--id', [string]$Entry.id, '--exact', '--source', 'winget') + $common
        }
    }
}

function Format-PkgsNativeCommand {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$Arguments
    )
    $parts = @("`"$FilePath`"")
    foreach ($arg in $Arguments) {
        if ($arg -match '\s') { $parts += "`"$arg`"" } else { $parts += $arg }
    }
    return ($parts -join ' ')
}

function Get-PkgsNativePreview {
    <#
        Ask mpm to print the exact underlying command with --plan.
        Nothing is executed except mpm's read-only queries.
    #>
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string[]]$Specs
    )
    if ($Manager -eq 'msstore') { return @() }
    $mpm = Assert-PkgsMpm
    $cliArgs = @('--plan', "--$Manager", $Operation) + $Specs
    $run = Invoke-PkgsNative -FilePath $mpm -ArgumentList $cliArgs -TimeoutSeconds 900
    if ($run.ExitCode -ne 0) { return @() }
    $commands = @()
    foreach ($line in ($run.Stdout -split "`r?`n")) {
        $trim = $line.Trim()
        if (-not $trim) { continue }
        # Keep only copy-pasteable commands, not mpm's simulated status lines.
        if ($trim -notmatch "^(?:'|`"|[A-Za-z]:[\\/]|\\\\|(?:scoop|winget|npm|pnpm|yarn|bun|choco|uv|pipx|cargo|rustup|dotnet|gcloud|gh|micro|code)\b)") { continue }
        $commands += $trim
    }
    return @($commands)
}

function Get-PkgsNativeTemplate {
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][string]$Id,
        [string]$Version = ''
    )
    if ($Version -and $Manager -ne 'winget') { return $null }
    $spec = $Id
    $common = '--accept-source-agreements --disable-interactivity --no-progress'

    switch ($Manager) {
        'winget' {
            $common = @('--accept-source-agreements', '--disable-interactivity', '--no-progress')
            if ($Operation -eq 'remove') {
                return (Format-PkgsNativeCommand -FilePath 'winget' -Arguments (@('uninstall', '--id', $spec, '--exact', '--source', 'winget') + $common))
            }
            if ($Operation -eq 'upgrade') {
                return (Format-PkgsNativeCommand -FilePath 'winget' -Arguments (@('upgrade', '--id', $spec, '--exact', '--source', 'winget', '--accept-package-agreements') + $common))
            }
            $installArgs = @('install', '--id', $spec, '--exact', '--source', 'winget', '--accept-package-agreements') + $common
            if ($Version) { $installArgs += @('--version', $Version) }
            return (Format-PkgsNativeCommand -FilePath 'winget' -Arguments $installArgs)
        }
        'scoop' {
            switch ($Operation) {
                'upgrade' { return "scoop update $spec" }
                'install' { return "scoop install $spec" }
                'remove'  { return "scoop uninstall $spec --purge" }
            }
        }
        'choco' {
            $verb = switch ($Operation) { 'upgrade' { 'upgrade' } 'install' { 'install' } 'remove' { 'uninstall' } }
            return "gsudo choco $verb $spec --yes --limit-output --no-progress --no-color"
        }
        'npm' {
            $verb = switch ($Operation) { 'upgrade' { 'upgrade' } 'install' { 'install' } 'remove' { 'uninstall' } }
            return "npm --global --no-progress --no-update-notifier --no-fund --no-audit $verb $spec"
        }
        'uvx' {
            $verb = switch ($Operation) { 'upgrade' { 'upgrade' } 'install' { 'install' } 'remove' { 'uninstall' } }
            return "uv tool $verb $spec"
        }
    }
    return $null
}

function New-PkgsPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('upgrade', 'install', 'remove')][string]$Operation,
        [Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Config,
        [switch]$OverrideProtection,
        [string]$Version = '',
        [switch]$SkipFreshVerification,
        [switch]$UseCachedState
    )

    $script:PkgsFreshOutdated = @{}
    $script:PkgsFreshInstalled = @{}
    $script:PkgsScratchAnomalies = @()
    $script:PkgsScratchErrors = @()

    $entries = @()
    $warnings = @()

    foreach ($spec in $Targets) {
        $resolved = $null
        $record = $null

        if ($Operation -eq 'install') {
            $manager = $null
            $id = $null
            if ($spec -match '^pkg:(?<m>[^/]+)/(?<i>.+)$') {
                $manager = $Matches.m; $id = [uri]::UnescapeDataString($Matches.i)
            }
            elseif ($spec -match '^(?<m>[A-Za-z0-9][A-Za-z0-9._-]*):(?<i>.+)$' -and (Find-PkgsManagerById -Manager $Matches.m -Snapshot $Snapshot)) {
                $manager = $Matches.m; $id = $Matches.i
            }
            else {
                $id = $spec
            }

            if (-not $manager) {
                # Resolve a bare install target against live search results.
                $mpm = Assert-PkgsMpm
                $run = Invoke-PkgsNative -FilePath $mpm -TimeoutSeconds 900 -ArgumentList @('--no-pip', '--no-uv', '--table-format', 'json', 'search', '--exact', $id)
                if ($run.ExitCode -ne 0) { Stop-Pkgs -Code 5 -Message "search for '$id' failed" }
                $data = ConvertFrom-MpmInventoryJson -Text $run.Stdout -Kind 'search'
                $candidates = @()
                foreach ($mgrId in $data.managers.Keys) {
                    $candidateCap = Get-PkgsCapability -Manager $mgrId
                    if ($candidateCap.install -ne $true) { continue }
                    foreach ($pkg in $data.managers[$mgrId].packages) {
                        if ([string]$pkg.id -ieq $id) {
                            $candidates += [pscustomobject]@{ manager = $mgrId; id = [string]$pkg.id; latest = [string](Get-PkgsProperty $pkg 'latest_version') }
                        }
                    }
                }
                if ($candidates.Count -eq 0) { Stop-Pkgs -Code 4 -Message "no package named '$id' found by any manager" }
                if ($candidates.Count -gt 1) {
                    $list = ($candidates | ForEach-Object { "  $($_.manager):$($_.id)" }) -join "`n"
                    Stop-Pkgs -Code 4 -Message "install target '$id' is ambiguous; use a qualified target:`n$list"
                }
                $manager = $candidates[0].manager
                $id = $candidates[0].id
                $record = [pscustomobject]@{ manager = $manager; id = $id; latest_version = $candidates[0].latest }
            }
            else {
                $capForInstall = Get-PkgsCapability -Manager $manager
                if ($capForInstall.search -eq $true) {
                    $found = @(Get-PkgsFreshSearch -Manager $manager -Query $id)
                    $exact = @($found | Where-Object { $_.id -ieq $id })
                    if ($exact.Count -eq 0) {
                        $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason 'not found by the manager search; refusing to install'
                        continue
                    }
                    if ($exact.Count -gt 1) {
                        $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason 'manager search returned multiple exact identities; qualify the target'
                        continue
                    }
                    $record = [pscustomobject]@{
                        manager = $manager
                        id = [string]$exact[0].id
                        name = if ($exact[0].name) { [string]$exact[0].name } else { [string]$exact[0].id }
                        latest_version = [string]$exact[0].latest_version
                    }
                    $id = [string]$exact[0].id
                }
                else {
                    $record = [pscustomobject]@{ manager = $manager; id = $id; latest_version = '' }
                }
            }
        }
        else {
            $resolved = Resolve-PkgsTarget -Spec $spec -Snapshot $Snapshot
            $manager = $resolved.manager
            $id = $resolved.id
            $record = $resolved.record
        }

        $cap = Get-PkgsCapability -Manager $manager
        if ($Operation -eq 'upgrade' -and $cap.upgrade -ne $true) {
            $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "backend does not support per-package upgrade ($($cap.notes))"
            continue
        }
        if ($Operation -eq 'remove' -and $cap.remove -ne $true) {
            $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "backend does not support remove ($($cap.notes))"
            continue
        }
        if ($Operation -eq 'install' -and $cap.install -ne $true) {
            $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "backend does not support install ($($cap.notes))"
            continue
        }

        # Install must never silently replace or upgrade an existing package.
        if ($Operation -eq 'install') {
            $installed = @(Get-PkgsFreshInstalled -Manager $manager | Where-Object { $_.id -ieq $id } | Sort-Object -Property id -Unique)
            if ($installed.Count -gt 0) {
                $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "already installed (version '$($installed[0].installed_version)'); use 'pkgs upgrade $manager`:$id' or 'pkgs remove $manager`:$id' instead"
                continue
            }
        }

        # Exact target check against the manager's own live inventory.
        $from = ''
        $to = ''

        # Protection must be reported before the backend outdated filter. WinGet
        # omits a blocking-pinned package from the upgrade list, which would
        # otherwise turn a protection refusal into "not reported as outdated".
        if ($Operation -eq 'upgrade' -and -not $UseCachedState) {
            $earlyName = if ($record) { [string](Get-PkgsProperty $record 'name' -Default $id) } else { $id }
            $earlyStub = [pscustomobject]@{ manager = $manager; id = $id; name = $earlyName }
            $earlyPins = Get-PkgsLiveNativePins -Managers @($manager)
            $earlyProtection = Get-PkgsProtection -Package $earlyStub -Config $Config -NativePins $earlyPins -PinErrors @($script:PkgsPinReadErrors)
            if ($earlyProtection.hardBlock -or ($earlyProtection.protected -and -not $OverrideProtection)) {
                $earlyReason = if ($earlyProtection.hardBlock) {
                    if ($earlyProtection.native) {
                        "native pin/hold detected ($($earlyProtection.summary)); remove it deliberately with 'pkgs pin --remove $manager`:$id'"
                    }
                    else {
                        "native protection state is unreadable ($($earlyProtection.summary)); refusing to mutate"
                    }
                }
                else {
                    "protected by pkgs ($($earlyProtection.summary)); a deliberate --override-protection is required"
                }
                $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason $earlyReason -Protection $earlyProtection
                continue
            }
        }

        if ($UseCachedState) {
            if ($Operation -eq 'upgrade') {
                if (-not ($record -and $record.outdated)) {
                    $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason 'not outdated in the cached snapshot (run pkgs refresh)'
                    continue
                }
                $from = [string]$record.installed_version
                $to = [string]$record.latest_version
            }
            elseif ($Operation -eq 'remove') {
                if (-not $record) {
                    $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason 'not found in the cached inventory'
                    continue
                }
                $from = [string]$record.installed_version
            }
            else {
                if ($Version) { $to = [string]$Version }
                elseif ($record -and $record.latest_version) { $to = [string]$record.latest_version }
            }
        }
        elseif (-not $SkipFreshVerification) {
            if ($Operation -eq 'upgrade') {
                $fresh = @(Get-PkgsFreshOutdated -Manager $manager | Where-Object { $_.id -ieq $id } | Sort-Object -Property id -Unique)
                if ($fresh.Count -ne 1) {
                    $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason 'not reported as outdated by the backend (or identity is ambiguous); refusing to upgrade'
                    continue
                }
                $from = $fresh[0].installed_version
                $to = $fresh[0].latest_version
                $id = $fresh[0].id
            }
            elseif ($Operation -eq 'remove') {
                $fresh = @(Get-PkgsFreshInstalled -Manager $manager | Where-Object { $_.id -ieq $id } | Sort-Object -Property id -Unique)
                if ($fresh.Count -ne 1) {
                    $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason 'not found in the manager inventory; refusing to remove'
                    continue
                }
                $from = $fresh[0].installed_version
                $id = $fresh[0].id
            }
            else {
                if ($Version) { $to = [string]$Version }
                elseif ($record -and $record.latest_version) { $to = [string]$record.latest_version }
            }
        }
        else {
            if ($record) {
                $from = [string](Get-PkgsProperty -Object $record -Name 'installed_version' -Default '')
                $to = [string](Get-PkgsProperty -Object $record -Name 'latest_version' -Default '')
            }
        }

        $wingetSource = ''
        $wingetVersion = ''
        if ($Operation -in @('upgrade', 'remove') -and $manager -eq 'scoop') {
            $scoopIdentity = Get-PkgsScoopIdentityEvidence -Id $id
            if (-not $scoopIdentity.ok) {
                $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "Scoop installed identity is not corroborated: $($scoopIdentity.reason)"
                continue
            }
        }
        if ($manager -eq 'winget') {
            if (-not (Test-PkgsWingetToken -Value $id)) {
                $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "package ID '$id' is not a valid WinGet identity"
                continue
            }
            if ($Operation -eq 'install' -and $Version -and -not (Test-PkgsWingetToken -Value $Version -AllowVersion)) {
                $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "version '$Version' is not a safe WinGet version specifier"
                continue
            }

            # WinGet's own inventory is the only place that reports the
            # installed source. mpm deduplicates and drops source information,
            # so it cannot prove that a mutation targets the official winget
            # package rather than another registration with the same ID.
            $wingetIdentity = Get-PkgsWingetIdentityState -Id $id
            if (-not $wingetIdentity.ok) {
                $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "WinGet identity is unsafe: $($wingetIdentity.reason)"
                continue
            }
            if ($Operation -eq 'install') {
                if ($wingetIdentity.installed) {
                    $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "already registered with WinGet (version '$($wingetIdentity.record.version)', source '$($wingetIdentity.record.source)'); use 'pkgs upgrade $manager`:$id' or 'pkgs remove $manager`:$id'"
                    continue
                }
            }
            else {
                if (-not $wingetIdentity.installed) {
                    $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason 'not reported by winget for this exact ID; refusing to mutate'
                    continue
                }
                if ($from -and ([string]$wingetIdentity.record.version) -ne [string]$from) {
                    $entries += New-PkgsBlockedPlanEntry -Manager $manager -Id $id -Operation $Operation -Reason "the inventory reports version '$from' but winget reports '$($wingetIdentity.record.version)'; refusing to mutate stale evidence"
                    continue
                }
                $wingetSource = [string]$wingetIdentity.record.source
                $wingetVersion = [string]$wingetIdentity.record.version
            }
        }

        $recordName = if ($record) { [string](Get-PkgsProperty $record 'name' -Default $id) } else { $id }
        $packageStub = [pscustomobject]@{ manager = $manager; id = $id; name = $recordName }
        $pins = Get-PkgsLiveNativePins -Managers @($manager)
        $protection = Get-PkgsProtection -Package $packageStub -Config $Config -NativePins $pins -PinErrors @($script:PkgsPinReadErrors)
        $blocked = $false
        $reason = ''
        if ($protection.hardBlock) {
            $blocked = $true
            if ($protection.native) {
                $reason = "native pin/hold detected ($($protection.summary)); remove it deliberately with 'pkgs pin --remove $manager`:$id'"
            }
            else {
                $reason = "native protection state is unreadable ($($protection.summary)); refusing to mutate"
            }
        }
        elseif ($protection.protected -and -not $OverrideProtection) {
            $blocked = $true
            $reason = "protected by pkgs ($($protection.summary)); a deliberate --override-protection is required"
        }

        $entries += [pscustomobject]@{
            operation  = $Operation
            manager    = $manager
            id         = $id
            name       = $packageStub.name
            from       = $from
            to         = $to
            version    = if ($Operation -eq 'install') { [string]$Version } else { '' }
            target     = "$manager`:$id"
            protection = $protection
            blocked    = $blocked
            reason     = $reason
            native     = ''
            winget_source  = $wingetSource
            winget_version = $wingetVersion
            invocation = "mpm --$manager $Operation $(if ($Operation -eq 'install' -and $Version) { "$id@$Version" } else { $id })"
        }
    }

    # Native command previews, batched per manager (and version for install).
    $groups = $entries | Where-Object { -not $_.blocked } | Group-Object -Property {
        if ($_.operation -eq 'install') { "$($_.manager)|$($_.version)" } else { $_.manager }
    }
    foreach ($group in $groups) {
        $items = @($group.Group)
        $manager = $items[0].manager
        if ($manager -eq 'msstore') {
            foreach ($item in $items) {
                $common = '--accept-source-agreements --disable-interactivity --no-progress'
                switch ($Operation) {
                    'upgrade' { $item.native = "winget upgrade --id $($item.id) --exact --source msstore --accept-package-agreements $common" }
                    'install' { $item.native = "winget install --id $($item.id) --exact --source msstore --accept-package-agreements $common" }
                    'remove'  { $item.native = "winget uninstall --id $($item.id) --exact --source msstore $common" }
                }
                $item.invocation = $item.native
            }
            continue
        }

        if ($manager -eq 'winget') {
            $wingetPath = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
            $displayPath = if ($wingetPath) { $wingetPath } else { 'winget' }
            foreach ($item in $items) {
                $cliArgs = @(Get-PkgsWingetMutationArgs -Entry $item)
                $item.native = Format-PkgsNativeCommand -FilePath $displayPath -Arguments $cliArgs
                $item.invocation = "winget $($cliArgs -join ' ')"
            }
            continue
        }

        $template = Get-PkgsNativeTemplate -Manager $manager -Operation $Operation -Id $items[0].id -Version ([string]$items[0].version)
        if ($template) {
            foreach ($item in $items) {
                $item.native = Get-PkgsNativeTemplate -Manager $manager -Operation $Operation -Id $item.id -Version ([string]$item.version)
            }
            continue
        }

        foreach ($item in $items) {
            $spec = if ($item.version) { "$($item.id)@$($item.version)" } else { $item.id }
            $commands = @(Get-PkgsNativePreview -Manager $manager -Operation $Operation -Specs @($spec))
            if ($commands.Count -eq 1) {
                $item.native = $commands[0]
            }
            else {
                $item.native = "(mpm will resolve the exact command for $manager)"
            }
        }
    }

    return [pscustomobject]@{
        operation = $Operation
        cached    = [bool]$UseCachedState
        override_protection = [bool]$OverrideProtection
        entries   = @($entries)
        warnings  = @($warnings)
        blocked   = @($entries | Where-Object { $_.blocked })
    }
}

function New-PkgsBlockedPlanEntry {
    param($Manager, $Id, $Operation, $Reason, $Protection = $null)
    $effectiveProtection = if ($Protection) {
        $Protection
    }
    else {
        [pscustomobject]@{ protected = $false; native = $false; reasons = @(); summary = '' }
    }
    return [pscustomobject]@{
        operation  = $Operation
        manager    = $Manager
        id         = $Id
        name       = $Id
        from       = ''
        to         = ''
        version    = ''
        target     = "$Manager`:$Id"
        protection = $effectiveProtection
        blocked    = $true
        reason     = $Reason
        native     = ''
        invocation = ''
    }
}

# ---------------------------------------------------------------------
#  Execution
# ---------------------------------------------------------------------
function Invoke-PkgsPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Plan,
        [switch]$CaptureOutput
    )

    $results = @()
    $entries = @($Plan.entries | Where-Object { -not $_.blocked })
    if ($entries.Count -eq 0) { return @() }

    Clear-PkgsSnapshot
    $mpm = Assert-PkgsMpm
    $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'

    $index = 0
    foreach ($entry in $entries) {
        $index++
        $label = "[$index/$($entries.Count)] $($entry.target)"
        Write-PkgsInfo $label

        $pre = Test-PkgsEntrySafeToExecute -Entry $entry -Plan $Plan
        if (-not $pre.ok) {
            Write-PkgsError "  BLOCKED: $($pre.reason)"
            $results += [pscustomobject]@{
                target   = $entry.target
                manager  = $entry.manager
                id       = $entry.id
                operation = $entry.operation
                ok       = $false
                verified = $false
                backend_exit = $null
                exit     = 5
                message  = "pre-execution verification failed: $($pre.reason)"
            }
            continue
        }

        $spec = if ($entry.version) { "$($entry.id)@$($entry.version)" } else { $entry.id }
        $exit = 1
        $backendExit = $null
        $output = ''

        try {
            if ($entry.manager -eq 'winget') {
                if (-not $winget) { throw 'winget not found' }
                $cliArgs = @(Get-PkgsWingetMutationArgs -Entry $entry)
                if ($CaptureOutput) {
                    $run = Invoke-PkgsNative -FilePath $winget -ArgumentList $cliArgs -TimeoutSeconds 3600
                    $exit = $run.ExitCode
                    $output = (($run.Stdout + "`n" + $run.Stderr).Trim())
                }
                else {
                    & $winget @cliArgs | Out-Host
                    $exit = $LASTEXITCODE
                }
            }
            elseif ($entry.manager -eq 'msstore') {
                if (-not $winget) { throw 'winget not found' }
                $common = @('--accept-source-agreements', '--disable-interactivity', '--no-progress')
                $cliArgs = switch ($entry.operation) {
                    'upgrade' { @('upgrade', '--id', $entry.id, '--exact', '--source', 'msstore', '--accept-package-agreements') + $common }
                    'install' { @('install', '--id', $entry.id, '--exact', '--source', 'msstore', '--accept-package-agreements') + $common }
                    'remove'  { @('uninstall', '--id', $entry.id, '--exact', '--source', 'msstore') + $common }
                }
                if ($CaptureOutput) {
                    $run = Invoke-PkgsNative -FilePath $winget -ArgumentList $cliArgs -TimeoutSeconds 3600
                    $exit = $run.ExitCode
                    $output = (($run.Stdout + "`n" + $run.Stderr).Trim())
                }
                else {
                    & $winget @cliArgs | Out-Host
                    $exit = $LASTEXITCODE
                }
            }
            else {
                $opVerb = switch ($entry.operation) { 'upgrade' { 'upgrade' } 'install' { 'install' } 'remove' { 'remove' } }
                $cliArgs = @("--$($entry.manager)", $opVerb, $spec)
                if ($CaptureOutput) {
                    $run = Invoke-PkgsNative -FilePath $mpm -ArgumentList $cliArgs -TimeoutSeconds 3600
                    $exit = $run.ExitCode
                    $output = (($run.Stdout + "`n" + $run.Stderr).Trim())
                }
                else {
                    & $mpm @cliArgs | Out-Host
                    $exit = $LASTEXITCODE
                }
            }
        }
        catch {
            $exit = 1
            $output = $_.Exception.Message
            if (-not $CaptureOutput) { Write-PkgsError $output }
        }

        $backendExit = $exit
        $verified = $false
        $verification = ''
        if ($exit -eq 0) {
            $verify = Test-PkgsEntryResult -Entry $entry
            $verification = [string]$verify.reason
            if ($verify.ok) {
                $verified = $true
                Write-PkgsOk '  OK'
                if ($CaptureOutput -and $output) { Write-PkgsDim $output }
                if ($verify.reason) { Write-PkgsDim "  verified: $($verify.reason)" }
            }
            else {
                $exit = 5
                if ($output) { $output = "verification failed: $($verify.reason)`n$output" }
                else { $output = "verification failed: $($verify.reason)" }
                Write-PkgsError "  VERIFY FAILED: $($verify.reason)"
                if ($CaptureOutput) { Write-PkgsError $output }
            }
        }
        else {
            Write-PkgsError "  FAILED (exit $exit)"
            if ($CaptureOutput -and $output) { Write-PkgsError $output }
        }

        $results += [pscustomobject]@{
            target  = $entry.target
            manager = $entry.manager
            id      = $entry.id
            operation = $entry.operation
            ok      = ($exit -eq 0 -and $verified)
            verified = $verified
            verification = $verification
            backend_exit = $backendExit
            exit    = $exit
            message = $output
        }
    }

    Clear-PkgsSnapshot
    Clear-PkgsPreviewCache
    return @($results)
}

# ---------------------------------------------------------------------
#  Local protection storage
# ---------------------------------------------------------------------
function Add-PkgsIgnoredRecord {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Id,
        [string]$Reason = '',
        [string]$Kind = 'ignore'
    )

    $existing = @($Config.ignored | Where-Object { $_ -and $_.manager -eq $Manager -and ([string]$_.id) -ieq $Id })
    if ($existing.Count -gt 0) {
        foreach ($item in $existing) {
            $item.reason = $Reason
            if ($item.PSObject.Properties['kind']) { $item.kind = $Kind } else { $item | Add-Member -NotePropertyName kind -NotePropertyValue $Kind }
        }
        Save-PkgsConfig -Config $Config
        return 'updated'
    }

    $record = [pscustomobject]@{
        manager = $Manager
        id      = $Id
        reason  = $Reason
        kind    = $Kind
        added   = (Get-Date).ToString('yyyy-MM-dd')
    }
    $Config.ignored = @($Config.ignored) + $record
    Save-PkgsConfig -Config $Config
    return 'added'
}

function Remove-PkgsIgnoredRecord {
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Id
    )
    $before = @($Config.ignored).Count
    $Config.ignored = @($Config.ignored | Where-Object { -not ($_ -and $_.manager -eq $Manager -and ([string]$_.id) -ieq $Id) })
    if (@($Config.ignored).Count -ne $before) {
        Save-PkgsConfig -Config $Config
        return $true
    }
    return $false
}
