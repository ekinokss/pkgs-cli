# =====================================================================
#  pkgs.ps1 - entry point and command dispatcher
#
#  Invoked either:
#    pwsh -File pkgs.ps1 ...          (standalone; real exit codes)
#    & <scriptblock> ...              (profile function; sets LASTEXITCODE)
#
#  The profile wrapper prepends $PkgsHome and $InShell = $true.
# =====================================================================

if (-not $PkgsHome) { $PkgsHome = $PSScriptRoot }
$script:PkgsRoot = $PkgsHome
$InShell = [bool]$InShell

. (Join-Path $PkgsHome 'pkgs-core.ps1')
. (Join-Path $PkgsHome 'pkgs-snapshot.ps1')
. (Join-Path $PkgsHome 'pkgs-model.ps1')
. (Join-Path $PkgsHome 'pkgs-ui.ps1')
. (Join-Path $PkgsHome 'pkgs-help.ps1')

$script:PkgsJsonRequested = $false
$script:PkgsCommandName = ''

# ---------------------------------------------------------------------
#  Argument parsing
# ---------------------------------------------------------------------
function Get-PkgsCommandSpec {
    param([string]$Command)
    switch ($Command) {
        'ui'        { return @{ flags = @('refresh', 'outdated-only', 'with-pip'); values = @('manager', 'height') } }
        'outdated'  { return @{ flags = @('json', 'refresh', 'with-pip', 'protected', 'strict'); values = @('manager', 'limit') } }
        'installed' { return @{ flags = @('json', 'refresh', 'with-pip', 'duplicates', 'strict'); values = @('manager', 'limit') } }
        'managers'  { return @{ flags = @('json', 'refresh'); values = @() } }
        'search'    { return @{ flags = @('json', 'exact'); values = @('manager', 'limit') } }
        'upgrade'   { return @{ flags = @('json', 'refresh', 'dry-run', 'yes', 'override-protection', 'strict'); values = @('manager') } }
        'install'   { return @{ flags = @('json', 'dry-run', 'yes', 'strict'); values = @('manager', 'pkg-version') } }
        'remove'    { return @{ flags = @('json', 'dry-run', 'yes', 'strict'); values = @('manager') } }
        'pin'       { return @{ flags = @('json', 'list', 'remove', 'dry-run', 'yes', 'refresh'); values = @('reason') } }
        'ignore'    { return @{ flags = @('json', 'list', 'remove', 'yes'); values = @('reason') } }
        'unprotect' { return @{ flags = @('json', 'yes'); values = @() } }
        'show'      { return @{ flags = @('json', 'refresh'); values = @() } }
        'doctor'    { return @{ flags = @('json', 'refresh'); values = @() } }
        'howto'     { return @{ flags = @(); values = @() } }
        'config'    { return @{ flags = @('json'); values = @() } }
        'refresh'   { return @{ flags = @('with-pip'); values = @() } }
        'clean'     { return @{ flags = @(); values = @() } }
        default     { return @{ flags = @(); values = @() } }
    }
}

function Test-PkgsJsonArgument {
    <#
        Detects an explicit JSON request before ConvertFrom-PkgsArguments can
        throw, so usage errors are still machine-readable. Mirrors the parser:
        stops at '--', skips the value of every value option, and never treats
        a positional or post-'--' literal as a flag.
    #>
    param(
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$Command
    )

    $spec = Get-PkgsCommandSpec -Command $Command
    $valueNames = @($spec.values)

    $i = 0
    while ($i -lt $Arguments.Count) {
        $token = [string]$Arguments[$i]
        if ($token -eq '--') { return $false }
        if ($token -in @('--json', '-j')) { return $true }

        if ($token -match '^--(?<name>[A-Za-z][A-Za-z0-9-]*)=(?<value>.*)$') {
            if ($Matches.name.ToLowerInvariant() -eq 'json') { return $true }
            $i++
            continue
        }
        if ($token -match '^--(?<name>[A-Za-z][A-Za-z0-9-]*)$') {
            $name = $Matches.name.ToLowerInvariant()
            if ($valueNames -contains $name -and $i + 1 -lt $Arguments.Count) { $i += 2; continue }
            $i++
            continue
        }
        if ($token -match '^-([A-Za-z])$') {
            if ($Matches[1].ToLowerInvariant() -eq 'm' -and $i + 1 -lt $Arguments.Count) { $i += 2; continue }
            $i++
            continue
        }
        $i++
    }
    return $false
}

function ConvertFrom-PkgsArguments {
    param(
        [AllowEmptyCollection()][string[]]$Arguments = @(),
        [Parameter(Mandatory)][string]$Command
    )

    $spec = Get-PkgsCommandSpec -Command $Command
    $flagNames = @($spec.flags)
    $valueNames = @($spec.values)
    $flags = @{}
    $values = @{}
    foreach ($name in $flagNames) { $flags[$name] = $false }
    foreach ($name in $valueNames) { $values[$name] = @() }
    $positionals = @()

    $shortMap = @{ 'm' = 'manager'; 'y' = 'yes'; 'n' = 'dry-run'; 'j' = 'json'; 'h' = 'help' }

    $i = 0
    while ($i -lt $Arguments.Count) {
        $token = [string]$Arguments[$i]
        if ($token -eq '--') {
            if ($i + 1 -lt $Arguments.Count) { $positionals += $Arguments[($i + 1)..($Arguments.Count - 1)] }
            break
        }

        $name = $null
        $inlineValue = $null
        if ($token -match '^--(?<name>[A-Za-z][A-Za-z0-9-]*)=(?<value>.*)$') {
            $name = $Matches.name.ToLowerInvariant()
            $inlineValue = $Matches.value
        }
        elseif ($token -match '^--(?<name>[A-Za-z][A-Za-z0-9-]*)$') {
            $name = $Matches.name.ToLowerInvariant()
        }
        elseif ($token -match '^-([A-Za-z])$') {
            $short = $Matches[1].ToLowerInvariant()
            if (-not $shortMap.ContainsKey($short)) { Stop-Pkgs -Code 2 -Message "unknown option '-$short'" }
            $name = $shortMap[$short]
        }
        elseif ($token -match '^-') {
            Stop-Pkgs -Code 2 -Message "unknown option '$token'"
        }
        else {
            $positionals += $token
            $i++
            continue
        }

        if ($name -eq 'help') { $flags['help'] = $true; $i++; continue }

        if ($flagNames -contains $name) {
            if ($null -ne $inlineValue) { Stop-Pkgs -Code 2 -Message "option '--$name' does not take a value" }
            $flags[$name] = $true
            $i++
            continue
        }
        if ($valueNames -contains $name) {
            $value = $inlineValue
            if ($null -eq $value) {
                if ($i + 1 -ge $Arguments.Count) { Stop-Pkgs -Code 2 -Message "option '--$name' needs a value" }
                $value = [string]$Arguments[$i + 1]
                $i += 2
            }
            else { $i++ }
            $values[$name] = @($values[$name]) + $value
            continue
        }

        Stop-Pkgs -Code 2 -Message "unknown option '--$name' for '$Command'"
    }

    return [pscustomobject]@{
        positionals = @($positionals)
        flags       = $flags
        values      = $values
    }
}

function Get-PkgsManagerFilter {
    param($Parsed, $Snapshot)
    $list = @()
    foreach ($value in @($Parsed.values['manager'])) {
        foreach ($part in ([string]$value -split ',')) {
            $trim = $part.Trim()
            if ($trim) { $list += $trim }
        }
    }
    if ($list.Count -eq 0) { return @() }
    foreach ($name in $list) {
        if (-not (Find-PkgsManagerById -Manager $name -Snapshot $Snapshot)) {
            Stop-Pkgs -Code 2 -Message "unknown manager '$name' (see 'pkgs managers')"
        }
    }
    return @($list | Select-Object -Unique)
}

function Test-PkgsQueryMatch {
    param($Package, [string]$Query)
    if ([string]::IsNullOrWhiteSpace($Query)) { return $true }
    return ($Package.target -like "*$Query*" -or $Package.id -like "*$Query*" -or $Package.name -like "*$Query*")
}

# ---------------------------------------------------------------------
#  JSON output
# ---------------------------------------------------------------------
function ConvertTo-PkgsManagerJson {
    param($Manager)
    return [ordered]@{
        id            = $Manager.id
        name          = $Manager.name
        version       = $Manager.version
        source        = $Manager.source
        detected      = [bool]$Manager.detected
        excluded      = [bool]$Manager.excluded
        exclude_reason = [string]$Manager.excludeReason
        package_count = [int](Get-PkgsProperty $Manager 'package_count' -Default 0)
        outdated_count = [int](Get-PkgsProperty $Manager 'outdated_count' -Default 0)
        outdated_known = [bool](Get-PkgsProperty $Manager 'outdated_known' -Default $false)
        capabilities  = $Manager.capabilities
        errors        = @($Manager.errors)
        anomalies     = @($Manager.anomalies)
    }
}

function ConvertTo-PkgsPackageJson {
    param($Package)
    return [ordered]@{
        manager           = $Package.manager
        manager_name      = $Package.manager_name
        id                = $Package.id
        name              = $Package.name
        display_name      = $Package.display_name
        name_source       = $Package.name_source
        type              = $Package.type
        scope             = $Package.scope
        installed_version = $Package.installed_version
        version_known     = [bool]$Package.version_known
        installed_display = $Package.installed_display
        latest_version    = $Package.latest_version
        available_display = $Package.available_display
        outdated          = [bool]$Package.outdated
        update_known      = [bool]$Package.update_known
        update_state      = $Package.update_state
        update_label      = $Package.update_label
        status_label      = $Package.status_label
        update_evidence   = $Package.update_evidence
        broken            = [bool]$Package.broken
        source            = $Package.source
        implicit          = [bool]$Package.implicit
        instances         = [int]$Package.instances
        notes             = @($Package.notes)
        target            = $Package.target
        protected         = [bool]$Package.protected
        protection        = @($Package.protection | ForEach-Object {
            [ordered]@{ kind = $_.kind; label = $_.label; detail = $_.detail; hard_block = [bool]$_.hardBlock }
        })
        protection_summary = $Package.protection_summary
        protected_reason  = $Package.protected_reason
        native_pin        = if ($Package.native_pin) { [ordered]@{ mechanism = $Package.native_pin.mechanism; detail = $Package.native_pin.detail; type = $Package.native_pin.type; source = $Package.native_pin.source } } else { $null }
        capability        = $Package.capability
        operations        = $Package.operations
    }
}

function New-PkgsEnvelope {
    param(
        [Parameter(Mandatory)][string]$Command,
        $Snapshot,
        [object[]]$Packages = @(),
        [object[]]$Warnings = @(),
        [object[]]$ExtraErrors = @(),
        [hashtable]$Extra = @{},
        $Inventory = $null
    )

    $envelope = [ordered]@{
        schema            = $script:PkgsSchema
        command           = $Command
        generated         = (Get-Date).ToUniversalTime().ToString('o')
        cached            = if ($Snapshot) { [bool](Get-PkgsProperty $Snapshot 'from_cache' -Default $false) } else { $false }
        cache_age_seconds = if ($Snapshot) { [int](Get-PkgsProperty $Snapshot 'cache_age_seconds' -Default 0) } else { 0 }
        mpm               = [ordered]@{
            version = if ($Snapshot -and $Snapshot.mpm_version) { $Snapshot.mpm_version } else { (Get-PkgsMpmVersion) }
            path    = if ($Snapshot -and $Snapshot.mpm_path) { $Snapshot.mpm_path } else { (Get-PkgsMpmPath) }
        }
        pip_outdated_checked = if ($Snapshot) { [bool](Get-PkgsProperty $Snapshot 'pip_outdated_checked' -Default $false) } else { $false }
        managers          = @()
        packages          = @($Packages)
        errors            = @()
        warnings          = @($Warnings)
    }
    if ($Snapshot) {
        $envelope.managers = @($Snapshot.managers | ForEach-Object { ConvertTo-PkgsManagerJson -Manager $_ })
        $envelope.errors = @($Snapshot.errors) + @($ExtraErrors)
        if ($Inventory) { $envelope.inventory = $Inventory }
    }
    else {
        $envelope.errors = @($ExtraErrors)
    }
    foreach ($key in $Extra.Keys) { $envelope[$key] = $Extra[$key] }
    return $envelope
}

function Write-PkgsJson {
    param($Object)
    $json = $Object | ConvertTo-Json -Depth 14
    [Console]::Out.WriteLine($json)
}

function Set-PkgsJsonMode {
    param([switch]$Enabled)
    if ($Enabled) { $script:PkgsJsonRequested = $true }
}

function ConvertTo-PkgsMutationPlanJson {
    param([Parameter(Mandatory)]$Plan)
    return @($Plan.entries | ForEach-Object {
        [ordered]@{
            target     = $_.target
            from       = $_.from
            to         = $_.to
            version    = $_.version
            invocation = $_.invocation
            native     = $_.native
            blocked    = [bool]$_.blocked
            reason     = $_.reason
            protected  = [bool]$_.protection.protected
            protection = @($_.protection.reasons)
        }
    })
}

function Write-PkgsMutationJson {
    <#
        One mutation response for every JSON path: dry-run, protected refusal,
        missing confirmation, manager mismatch and execution/verification
        results. Callers return the same exit code they pass here.
    #>
    param(
        [Parameter(Mandatory)][string]$Operation,
        $Snapshot,
        [Parameter(Mandatory)]$Plan,
        [Parameter(Mandatory)][int]$ExitCode,
        [Parameter(Mandatory)][bool]$DryRun,
        [object[]]$Results = @(),
        [string]$Message = ''
    )

    $extra = [ordered]@{
        ok        = ($ExitCode -eq 0)
        exit_code = $ExitCode
        dry_run   = $DryRun
        plan      = @(ConvertTo-PkgsMutationPlanJson -Plan $Plan)
    }
    if ($Results.Count -gt 0) { $extra.results = @($Results) }
    if ($Message) { $extra.message = $Message }
    $envelope = New-PkgsEnvelope -Command $Operation -Snapshot $Snapshot -Extra $extra
    Write-PkgsJson $envelope
}

# ---------------------------------------------------------------------
#  Read-only commands
# ---------------------------------------------------------------------
function Invoke-PkgsManagersCommand {
    param($Parsed)
    $snapshot = Get-PkgsSnapshot -Refresh:([bool]$Parsed.flags['refresh'])
    if ($Parsed.flags['json']) {
        Set-PkgsJsonMode -Enabled
        $envelope = New-PkgsEnvelope -Command 'managers' -Snapshot $snapshot
        Write-PkgsJson $envelope
        return 0
    }
    Show-PkgsManagersTable -Snapshot $snapshot
    return 0
}

function Invoke-PkgsInstalledCommand {
    param($Parsed, [switch]$OutdatedOnly)
    $requested = @()
    foreach ($value in @($Parsed.values['manager'])) {
        foreach ($part in ([string]$value -split ',')) {
            if ($part.Trim()) { $requested += $part.Trim() }
        }
    }
    $withPip = [bool]$Parsed.flags['with-pip'] -or (@($requested | Where-Object { $_ -like 'pip*' }).Count -gt 0)
    $snapshot = Get-PkgsSnapshot -Refresh:([bool]$Parsed.flags['refresh']) -IncludePipOutdated:$withPip
    $managers = Get-PkgsManagerFilter -Parsed $Parsed -Snapshot $snapshot
    $config = Get-PkgsConfig
    $inventory = Get-PkgsSnapshotInventoryStats -Snapshot $snapshot -Config $config
    $packages = Get-PkgsDecoratedPackages -Snapshot $snapshot -Config $config -Manager $managers -OutdatedOnly:$OutdatedOnly
    if ($OutdatedOnly -and -not $withPip -and $managers.Count -eq 0) {
        $packages = @($packages | Where-Object { $_.manager -notlike 'pip*' })
    }
    $query = (@($Parsed.positionals) -join ' ').Trim()
    if ($query) { $packages = @($packages | Where-Object { Test-PkgsQueryMatch -Package $_ -Query $query }) }

    if ($Parsed.flags['protected']) { $packages = @($packages | Where-Object { $_.protected }) }
    if ($Parsed.flags['duplicates']) {
        if (-not $withPip -and $managers.Count -eq 0) {
            $packages = @($packages | Where-Object { $_.manager -notlike 'pip*' })
        }
        $idGroups = @($packages | Group-Object -Property id | Where-Object { $_.Count -gt 1 })
        $duplicates = @($idGroups | ForEach-Object { $_.Name })
        $packages = @($packages | Where-Object { $_.instances -gt 1 -or $duplicates -contains $_.id })
    }

    $limit = 0
    if ($Parsed.values['limit']) {
        $limitText = @($Parsed.values['limit'])[-1]
        if ($limitText -match '^\d+$') { $limit = [int]$limitText }
    }
    if ($limit -gt 0 -and $packages.Count -gt $limit) { $packages = @($packages | Select-Object -First $limit) }

    $commandName = if ($OutdatedOnly) { 'outdated' } else { 'installed' }
    if ($Parsed.flags['json']) {
        Set-PkgsJsonMode -Enabled
        $envelope = New-PkgsEnvelope -Command $commandName -Snapshot $snapshot -Packages @($packages | ForEach-Object { ConvertTo-PkgsPackageJson -Package $_ }) -Inventory $inventory
        Write-PkgsJson $envelope
    }
    else {
        Show-PkgsPackageTable -Packages $packages -ShowStatus:(-not $OutdatedOnly)
        Write-PkgsDim ''
        Write-PkgsDim "schema $($script:PkgsSchema) | cache $([int](Get-PkgsProperty $snapshot 'cache_age_seconds' -Default 0))s | pkgs howto json"
    }

    if ($Parsed.flags['strict'] -and @($snapshot.errors).Count -gt 0) { return 5 }
    return 0
}

function Invoke-PkgsSearchCommand {
    param($Parsed)
    $query = (@($Parsed.positionals) -join ' ').Trim()
    if (-not $query) { Stop-Pkgs -Code 2 -Message 'search requires a query' }

    $snapshot = Get-PkgsSnapshot
    $managers = Get-PkgsManagerFilter -Parsed $Parsed -Snapshot $snapshot
    if ($managers.Count -eq 0) {
        $managers = @($snapshot.managers | Where-Object { -not $_.excluded -and $_.capabilities.search -eq $true } | Select-Object -ExpandProperty id)
    }
    else {
        $searchable = @($managers | Where-Object {
            $mgr = Find-PkgsManagerById -Manager $_ -Snapshot $snapshot
            $mgr -and -not $mgr.excluded -and $mgr.capabilities.search -eq $true
        })
        if ($searchable.Count -eq 0) {
            Stop-Pkgs -Code 3 -Message "the selected manager(s) do not support search: $($managers -join ', ')"
        }
        $managers = $searchable
    }

    $results = @()
    $warnings = @()
    $mpmManagers = @($managers | Where-Object { $_ -ne 'msstore' })
    if ($mpmManagers.Count -gt 0) {
        Write-PkgsDim "Searching $($mpmManagers -join ', ')..."
        $mpm = Assert-PkgsMpm
        $cliArgs = @('--table-format', 'json', 'search')
        if ($Parsed.flags['exact']) { $cliArgs += '--exact' }
        $cliArgs += $query
        if ($mpmManagers.Count -eq 1) { $cliArgs = @("--$($mpmManagers[0])") + $cliArgs }
        else { $cliArgs = @('--no-pip', '--no-uv') + $cliArgs }
        $run = Invoke-PkgsNative -FilePath $mpm -ArgumentList $cliArgs -TimeoutSeconds 900
        if ($run.ExitCode -eq 0) {
            $data = ConvertFrom-MpmInventoryJson -Text $run.Stdout -Kind 'search'
            foreach ($managerId in $data.managers.Keys) {
                if ($managers -notcontains $managerId) { continue }
                foreach ($pkg in $data.managers[$managerId].packages) {
                    $display = if ($pkg.name) { [string]$pkg.name } else { [string]$pkg.id }
                    $latest = [string](Get-PkgsProperty $pkg 'latest_version')
                    $results += [pscustomobject]@{
                        manager = $managerId
                        manager_name = Get-PkgsManagerLabel -Manager $managerId -Snapshot $snapshot
                        id = [string]$pkg.id
                        name = $display
                        display_name = $display
                        type = Get-PkgsPackageType -Manager $managerId
                        latest_version = $latest
                        available_display = if ($latest) { $latest } else { 'Unknown' }
                        description = [string](Get-PkgsProperty $pkg 'description')
                    }
                }
            }
        }
        else {
            $warnings += "mpm search failed (exit $($run.ExitCode))"
        }
    }

    if ($managers -contains 'msstore') {
        $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
        if ($winget) {
            $run = Invoke-PkgsNative -FilePath $winget -TimeoutSeconds 240 -ArgumentList @(
                'search', '--source', 'msstore', '--query', $query,
                '--accept-source-agreements', '--disable-interactivity', '--no-progress')
            if ($run.ExitCode -eq 0) {
                foreach ($row in (ConvertFrom-WingetTable -Text $run.Stdout)) {
                    if ($Parsed.flags['exact'] -and $row.id -ine $query) { continue }
                    $results += [pscustomobject]@{
                        manager = 'msstore'; manager_name = 'Microsoft Store (winget)';
                        id = $row.id; name = $row.name; display_name = $row.name;
                        type = Get-PkgsPackageType -Manager 'msstore';
                        latest_version = $row.version; available_display = $row.version; description = ''
                    }
                }
            }
        }
    }

    $limit = 0
    if ($Parsed.values['limit']) {
        $limitText = @($Parsed.values['limit'])[-1]
        if ($limitText -match '^\d+$') { $limit = [int]$limitText }
    }
    if ($limit -gt 0 -and $results.Count -gt $limit) { $results = @($results | Select-Object -First $limit) }

    if ($Parsed.flags['json']) {
        Set-PkgsJsonMode -Enabled
        $envelope = New-PkgsEnvelope -Command 'search' -Snapshot $snapshot -Warnings $warnings -Packages @($results | ForEach-Object {
            [ordered]@{
                manager = $_.manager; manager_name = $_.manager_name;
                id = $_.id; name = $_.name; display_name = $_.display_name;
                type = $_.type; latest_version = $_.latest_version;
                available_display = $_.available_display;
                description = $_.description; target = "$($_.manager):$($_.id)"
            }
        })
        Write-PkgsJson $envelope
    }
    else {
        $columns = @(
            @{ Header = 'PACKAGE'; Expression = { param($r) $r.display_name }; MaxWidth = 34 }
            @{ Header = 'TYPE'; Expression = { param($r) $r.type }; MaxWidth = 18 }
            @{ Header = 'AVAILABLE'; Expression = { param($r) $r.available_display }; MaxWidth = 16 }
            @{ Header = 'MANAGER'; Expression = { param($r) $r.manager }; MaxWidth = 14 }
        )
        Write-PkgsTable -Rows $results -Columns $columns
        foreach ($warning in $warnings) { Write-PkgsWarn $warning }
        Write-PkgsDim ''
        Write-PkgsDim "Install with: pkgs install manager:id --dry-run"
    }
    return 0
}

function Invoke-PkgsShowCommand {
    param($Parsed)
    $target = (@($Parsed.positionals) -join ' ').Trim()
    if (-not $target) { Stop-Pkgs -Code 2 -Message 'show requires a target' }
    $snapshot = Get-PkgsSnapshot -Refresh:([bool]$Parsed.flags['refresh'])
    $resolved = Resolve-PkgsTarget -Spec $target -Snapshot $snapshot
    $decorated = @(Get-PkgsDecoratedPackages -Snapshot $snapshot -Config (Get-PkgsConfig) | Where-Object { $_.manager -eq $resolved.manager -and $_.id -ieq $resolved.id })
    if ($decorated.Count -eq 0) { Stop-Pkgs -Code 4 -Message "target '$target' not found" }
    if ($Parsed.flags['json']) {
        Set-PkgsJsonMode -Enabled
        $envelope = New-PkgsEnvelope -Command 'show' -Snapshot $snapshot -Packages @(ConvertTo-PkgsPackageJson -Package $decorated[0])
        Write-PkgsJson $envelope
        return 0
    }
    Show-PkgsPackageDetails -Package $decorated[0]
    return 0
}

# ---------------------------------------------------------------------
#  Mutations
# ---------------------------------------------------------------------
function Invoke-PkgsMutationCommand {
    param(
        [Parameter(Mandatory)][ValidateSet('upgrade', 'install', 'remove')][string]$Operation,
        [Parameter(Mandatory)]$Parsed
    )

    $targets = @($Parsed.positionals | Where-Object { $_ })
    if ($targets.Count -eq 0) {
        if ($Operation -eq 'upgrade' -and (Test-PkgsInteractive) -and -not $Parsed.flags['json']) {
            $snapshot = Get-PkgsSnapshot -Refresh:([bool]$Parsed.flags['refresh'])
            Invoke-PkgsUi -Snapshot $snapshot -Config (Get-PkgsConfig) -OutdatedOnly
            return 0
        }
        if ($Operation -eq 'upgrade') {
            Stop-Pkgs -Code 2 -Message 'upgrade requires explicit targets; upgrading everything is not supported (select packages in the interactive UI instead)'
        }
        Stop-Pkgs -Code 2 -Message "$Operation requires at least one target"
    }

    $version = ''
    if ($Operation -eq 'install' -and $Parsed.values['pkg-version']) {
        $version = [string](@($Parsed.values['pkg-version'])[-1])
        if ($targets.Count -ne 1) { Stop-Pkgs -Code 2 -Message '--pkg-version takes exactly one target' }
    }

    $snapshot = Get-PkgsSnapshot -Refresh:([bool]$Parsed.flags['refresh'])
    $json = [bool]$Parsed.flags['json']
    $override = [bool]$Parsed.flags['override-protection']
    $dryRun = [bool]$Parsed.flags['dry-run']

    $requestedManagers = @()
    foreach ($value in @($Parsed.values['manager'])) {
        foreach ($part in ([string]$value -split ',')) {
            if ($part.Trim()) { $requestedManagers += $part.Trim() }
        }
    }

    Write-PkgsDim 'Verifying targets against the package managers...'
    # JSON mode cannot satisfy the interactive typed override gate, so the
    # override is never honored there; protected targets surface as blocks.
    $plan = New-PkgsPlan -Operation $Operation -Targets $targets -Snapshot $snapshot -Config (Get-PkgsConfig) -OverrideProtection:($override -and -not $json) -Version $version

    $overrideNotice = ''
    if ($json -and $override) {
        $refusedOverride = @($plan.entries | Where-Object { $_.blocked -and $_.protection.protected -and -not $_.protection.hardBlock })
        if ($refusedOverride.Count -gt 0) {
            foreach ($entry in $refusedOverride) {
                $entry.reason = "protected by pkgs ($($entry.protection.summary)); --override-protection cannot be authorized in JSON mode (no prompt is allowed); rerun without --json to authorize the override"
            }
            $overrideNotice = '--override-protection is not honored in JSON mode because typed authorization cannot be obtained; the protected targets were refused'
            Write-PkgsWarn $overrideNotice
        }
    }

    if ($requestedManagers.Count -gt 0) {
        $mismatch = @($plan.entries | Where-Object { $requestedManagers -notcontains $_.manager })
        if ($mismatch.Count -gt 0) {
            $messages = @()
            foreach ($entry in $mismatch) {
                $message = "$($entry.target): target manager '$($entry.manager)' does not match -m $($requestedManagers -join ',')"
                $messages += $message
                Write-PkgsError $message
            }
            if ($json) {
                Write-PkgsMutationJson -Operation $Operation -Snapshot $snapshot -Plan $plan -ExitCode 4 -DryRun $dryRun -Message ($messages -join '; ')
            }
            return 4
        }
    }
    if ($json) {
        Set-PkgsJsonMode -Enabled
    }
    else {
        Show-PkgsPlan -Plan $plan
    }

    $blocked = @($plan.entries | Where-Object { $_.blocked })
    if ($dryRun) {
        $hardBlocked = @($blocked | Where-Object { $_.protection.hardBlock })
        $protectedBlocked = @($blocked | Where-Object { $_.protection.protected })
        $dryRunExit = if ($blocked.Count -eq 0) { 0 }
                      elseif ($hardBlocked.Count -gt 0 -or $protectedBlocked.Count -gt 0) { 6 }
                      else { 5 }
        if ($json) {
            Write-PkgsMutationJson -Operation $Operation -Snapshot $snapshot -Plan $plan -ExitCode $dryRunExit -DryRun $true -Message $overrideNotice
        }
        return $dryRunExit
    }

    if ($blocked.Count -gt 0) {
        $hardBlocked = @($blocked | Where-Object { $_.protection.hardBlock })
        $protectedBlocked = @($blocked | Where-Object { $_.protection.protected })
        $blockedExit = if ($hardBlocked.Count -gt 0 -or $protectedBlocked.Count -gt 0) { 6 } else { 5 }
        foreach ($entry in $blocked) { Write-PkgsError "$($entry.target): $($entry.reason)" }
        if ($json) {
            Write-PkgsMutationJson -Operation $Operation -Snapshot $snapshot -Plan $plan -ExitCode $blockedExit -DryRun $false -Message $overrideNotice
        }
        return $blockedExit
    }

    $interactive = Test-PkgsInteractive
    $yes = [bool]$Parsed.flags['yes']

    if ($json -and -not $yes) {
        $message = 'JSON mutation mode requires --yes (JSON mode never prompts; the plan was not executed)'
        Write-PkgsWarn $message
        Write-PkgsMutationJson -Operation $Operation -Snapshot $snapshot -Plan $plan -ExitCode 3 -DryRun $false -Message $message
        return 3
    }
    if (-not $interactive -and -not $yes) {
        $message = 'non-interactive mutation requires --yes (the plan above was not executed)'
        Write-PkgsWarn $message
        if ($json) {
            Write-PkgsMutationJson -Operation $Operation -Snapshot $snapshot -Plan $plan -ExitCode 3 -DryRun $false -Message $message
        }
        return 3
    }
    if ($interactive -and -not $json) {
        if ($override) {
            if (-not (Read-PkgsTypedConfirmation -Word 'OVERRIDE' -Prompt "This bypasses pkgs protection. Type 'OVERRIDE' to continue")) { return 0 }
        }
        $answer = Read-Host 'Proceed? [y/N]'
        if ($answer -notmatch '^(?i)y(es)?$') { return 0 }
    }

    $results = @(Invoke-PkgsPlan -Plan $plan -CaptureOutput:$json)
    $ok = (@($results | Where-Object { -not $_.ok }).Count -eq 0)
    $finalExit = if ($ok) { 0 } else { 5 }

    if ($json) {
        Write-PkgsMutationJson -Operation $Operation -Snapshot $snapshot -Plan $plan -ExitCode $finalExit -DryRun $false -Results $results
    }

    if (-not $ok) { return 5 }
    return 0
}

# ---------------------------------------------------------------------
#  Protection commands
# ---------------------------------------------------------------------
function Invoke-PkgsPinCommand {
    param($Parsed)

    if ($Parsed.flags['list']) {
        $snapshot = Get-PkgsSnapshot -Refresh:([bool]$Parsed.flags['refresh'])
        $livePins = @(Get-PkgsLiveNativePins -Refresh)
        $rows = @()
        foreach ($pin in $livePins) {
            $rows += [pscustomobject]@{
                Target = "$($pin.manager):$($pin.id)"
                Mechanism = $pin.mechanism
                Detail = $pin.detail
                PinType = [string](Get-PkgsProperty -Object $pin -Name 'type' -Default '')
                PinSource = [string](Get-PkgsProperty -Object $pin -Name 'source' -Default '')
                Source = 'native'
            }
        }
        foreach ($entry in @((Get-PkgsConfig).ignored)) {
            if (-not $entry) { continue }
            $rows += [pscustomobject]@{
                Target = "$($entry.manager):$($entry.id)";
                Mechanism = if ($entry.kind) { [string]$entry.kind } else { 'ignore' };
                Detail = [string](Get-PkgsProperty $entry 'reason' -Default '');
                PinType = if ($entry.kind) { [string]$entry.kind } else { 'ignore' };
                PinSource = 'pkgs';
                Source = 'pkgs'
            }
        }
        if ($Parsed.flags['json']) {
            Set-PkgsJsonMode -Enabled
            $envelope = New-PkgsEnvelope -Command 'pin' -Snapshot $snapshot -Extra @{
                pins = @($rows | ForEach-Object { [ordered]@{ target = $_.Target; mechanism = $_.Mechanism; detail = $_.Detail; source = $_.Source; pin_type = $_.PinType; pin_source = $_.PinSource } })
            }
            Write-PkgsJson $envelope
            return 0
        }
        $columns = @(
            @{ Header = 'TARGET'; Expression = { param($r) $r.Target } }
            @{ Header = 'MECHANISM'; Expression = { param($r) $r.Mechanism } }
            @{ Header = 'DETAIL'; Expression = { param($r) $r.Detail } }
            @{ Header = 'PIN SOURCE'; Expression = { param($r) $r.PinSource } }
            @{ Header = 'SOURCE'; Expression = { param($r) $r.Source } }
        )
        Write-PkgsTable -Rows $rows -Columns $columns
        return 0
    }

    $targets = @($Parsed.positionals | Where-Object { $_ })
    if ($targets.Count -eq 0) { Stop-Pkgs -Code 2 -Message 'pin requires targets or --list' }
    $pinJson = [bool]$Parsed.flags['json']
    if (($pinJson -or -not (Test-PkgsInteractive)) -and -not $Parsed.flags['yes'] -and -not $Parsed.flags['dry-run']) {
        $message = if ($pinJson) { 'JSON mode requires --yes for pin changes (no prompt is shown)' } else { 'non-interactive pin changes require --yes' }
        Stop-Pkgs -Code 3 -Message $message
    }

    $snapshot = Get-PkgsSnapshot
    $config = Get-PkgsConfig
    $results = @()
    foreach ($target in $targets) {
        try {
            Set-PkgsPin -Config $config -Target $target -Snapshot $snapshot -Remove:([bool]$Parsed.flags['remove']) `
                -DryRun:([bool]$Parsed.flags['dry-run']) -Yes:([bool]$Parsed.flags['yes']) -Interactive:(-not $pinJson)
            $results += [pscustomobject]@{ target = $target; ok = $true; message = '' }
        }
        catch {
            $message = $_.Exception.Message -replace '^PKGS_EXIT:\d+:', ''
            $results += [pscustomobject]@{ target = $target; ok = $false; message = $message }
            Write-PkgsError "$target`: $message"
        }
    }
    $pinOk = (@($results | Where-Object { -not $_.ok }).Count -eq 0)
    $pinExit = if ($pinOk) { 0 } else { 5 }
    if ($pinJson) {
        Set-PkgsJsonMode -Enabled
        Write-PkgsJson ([ordered]@{ schema = $script:PkgsSchema; command = 'pin'; ok = $pinOk; exit_code = $pinExit; results = @($results) })
    }
    if (-not $pinOk) { return 5 }
    return 0
}

function Confirm-PkgsProtectionChange {
    <#
        Persistent protection changes (ignore/unprotect) need explicit intent.
        --yes is the non-interactive intent; on a TTY the exact targets are
        listed and a [y/N] answer is required.
    #>
    param(
        [Parameter(Mandatory)][string]$Action,
        [Parameter(Mandatory)][string[]]$Targets,
        [Parameter(Mandatory)]$Parsed
    )

    $json = [bool]$Parsed.flags['json']
    $yes = [bool]$Parsed.flags['yes']
    if (($json -or -not (Test-PkgsInteractive)) -and -not $yes) {
        $message = if ($json) { 'JSON mode requires --yes for protection changes (no prompt is shown)' } else { 'non-interactive protection changes require --yes' }
        Stop-Pkgs -Code 3 -Message $message
    }
    if ($yes) { return $true }

    Write-Host ''
    Write-Host "$Action`:" -ForegroundColor DarkGray
    foreach ($target in $Targets) { Write-Host "  $target" }
    $answer = Read-Host 'Apply this protection change? [y/N]'
    return ($answer -match '^(?i)y(es)?$')
}

function Invoke-PkgsIgnoreCommand {
    param($Parsed)
    $config = Get-PkgsConfig

    if ($Parsed.flags['list']) {
        $rows = @()
        foreach ($entry in @($config.ignored)) {
            if (-not $entry) { continue }
            $rows += [pscustomobject]@{
                Target = "$($entry.manager):$($entry.id)"
                Kind = if ($entry.kind) { [string]$entry.kind } else { 'ignore' }
                Reason = [string](Get-PkgsProperty $entry 'reason' -Default '')
                Added = [string](Get-PkgsProperty $entry 'added' -Default '')
            }
        }
        if ($Parsed.flags['json']) {
            Set-PkgsJsonMode -Enabled
            Write-PkgsJson ([ordered]@{
                schema = $script:PkgsSchema; command = 'ignore';
                ignored = @($rows | ForEach-Object { [ordered]@{ target = $_.Target; kind = $_.Kind; reason = $_.Reason; added = $_.Added } });
                guard = @($config.guard); guard_exceptions = @($config.guardExceptions)
            })
            return 0
        }
        $columns = @(
            @{ Header = 'TARGET'; Expression = { param($r) $r.Target } }
            @{ Header = 'KIND'; Expression = { param($r) $r.Kind } }
            @{ Header = 'REASON'; Expression = { param($r) $r.Reason } }
            @{ Header = 'ADDED'; Expression = { param($r) $r.Added } }
        )
        Write-PkgsTable -Rows $rows -Columns $columns
        Write-PkgsDim ''
        Write-PkgsDim "Guard patterns: $(@($config.guard).Count) | guard exceptions: $(@($config.guardExceptions).Count) | config: $(Get-PkgsConfigPath)"
        return 0
    }

    $targets = @($Parsed.positionals | Where-Object { $_ })
    if ($targets.Count -eq 0) { Stop-Pkgs -Code 2 -Message 'ignore requires targets or --list' }
    $snapshot = Get-PkgsSnapshot
    $reason = ''
    if ($Parsed.values['reason']) { $reason = [string](@($Parsed.values['reason'])[-1]) }

    $results = @()
    $resolvedTargets = @()
    foreach ($target in $targets) {
        $resolved = Resolve-PkgsTarget -Spec $target -Snapshot $snapshot -AllowMissing
        if (-not $resolved.manager) { Stop-Pkgs -Code 4 -Message "cannot resolve '$target'; use manager:id" }
        $resolvedTargets += $resolved
    }

    $actionLabel = if ($Parsed.flags['remove']) { 'Remove local protection' } else { 'Add local protection' }
    $exactTargets = @($resolvedTargets | ForEach-Object { "$($_.manager):$($_.id)" })
    if (-not (Confirm-PkgsProtectionChange -Action $actionLabel -Targets $exactTargets -Parsed $Parsed)) { return 0 }

    foreach ($resolved in $resolvedTargets) {
        if ($Parsed.flags['remove']) {
            $removed = Remove-PkgsIgnoredRecord -Config $config -Manager $resolved.manager -Id $resolved.id
            if ($removed) { Write-PkgsOk "unprotected $($resolved.manager):$($resolved.id)" }
            else { Write-PkgsWarn "no local protection entry for $($resolved.manager):$($resolved.id)" }
            $results += [pscustomobject]@{ target = "$($resolved.manager):$($resolved.id)"; ok = $true; removed = $removed }
        }
        else {
            $verb = Add-PkgsIgnoredRecord -Config $config -Manager $resolved.manager -Id $resolved.id -Reason $reason -Kind 'ignore'
            Write-PkgsOk "protected $($resolved.manager):$($resolved.id) ($verb)"
            $results += [pscustomobject]@{ target = "$($resolved.manager):$($resolved.id)"; ok = $true; action = $verb }
        }
    }
    Clear-PkgsSnapshot
    if ($Parsed.flags['json']) {
        Set-PkgsJsonMode -Enabled
        Write-PkgsJson ([ordered]@{ schema = $script:PkgsSchema; command = 'ignore'; ok = $true; exit_code = 0; results = @($results) })
    }
    return 0
}

function Invoke-PkgsUnprotectCommand {
    param($Parsed)
    $targets = @($Parsed.positionals | Where-Object { $_ })
    if ($targets.Count -eq 0) { Stop-Pkgs -Code 2 -Message 'unprotect requires targets' }
    $snapshot = Get-PkgsSnapshot
    $config = Get-PkgsConfig
    $resolvedTargets = @()
    foreach ($target in $targets) {
        $resolved = Resolve-PkgsTarget -Spec $target -Snapshot $snapshot -AllowMissing
        if (-not $resolved.manager) { Stop-Pkgs -Code 4 -Message "cannot resolve '$target'; use manager:id" }
        $resolvedTargets += $resolved
    }

    $exactTargets = @($resolvedTargets | ForEach-Object { "$($_.manager):$($_.id)" })
    if (-not (Confirm-PkgsProtectionChange -Action 'Remove local protection and add a guard exception' -Targets $exactTargets -Parsed $Parsed)) { return 0 }

    $results = @()
    foreach ($resolved in $resolvedTargets) {
        $null = Remove-PkgsIgnoredRecord -Config $config -Manager $resolved.manager -Id $resolved.id
        $exists = @($config.guardExceptions | Where-Object { $_ -and $_.manager -eq $resolved.manager -and ([string]$_.id) -ieq $resolved.id }).Count -gt 0
        if (-not $exists) {
            $config.guardExceptions = @($config.guardExceptions) + [pscustomobject]@{
                manager = $resolved.manager; id = $resolved.id; added = (Get-Date).ToString('yyyy-MM-dd')
            }
            Save-PkgsConfig -Config $config
        }
        Write-PkgsOk "unprotected $($resolved.manager):$($resolved.id) (local entry removed, guard exception recorded)"
        $results += [pscustomobject]@{ target = "$($resolved.manager):$($resolved.id)"; ok = $true }
    }
    Clear-PkgsSnapshot
    if ($Parsed.flags['json']) {
        Set-PkgsJsonMode -Enabled
        Write-PkgsJson ([ordered]@{ schema = $script:PkgsSchema; command = 'unprotect'; ok = $true; exit_code = 0; results = @($results) })
    }
    return 0
}

# ---------------------------------------------------------------------
#  Doctor
# ---------------------------------------------------------------------
function Invoke-PkgsDoctorCommand {
    param($Parsed)

    $add = {
        param($Name, $Status, $Detail)
        $script:PkgsDoctorChecks += [pscustomobject]@{ name = $Name; status = $Status; detail = $Detail }
    }
    $script:PkgsDoctorChecks = @()

    $psVersion = $PSVersionTable.PSVersion
    if ($psVersion -ge [version]'7.4') { & $add 'powershell' 'OK' "$psVersion" }
    else { & $add 'powershell' 'WARN' "$psVersion (7.4+ expected)" }

    $mpm = Get-PkgsMpmPath
    if ($mpm) { & $add 'mpm' 'OK' "v$(Get-PkgsMpmVersion) at $mpm" }
    else { & $add 'mpm' 'FAIL' 'not found (scoop install main/meta-package-manager)' }

    foreach ($tool in @(
        @{ name = 'fzf'; test = 'PKGS_TEST_FZF'; required = $false },
        @{ name = 'bat'; test = 'PKGS_TEST_BAT'; required = $false },
        @{ name = 'jq'; test = $null; required = $false },
        @{ name = 'gsudo'; test = 'PKGS_TEST_GSUDO'; required = $false }
    )) {
        $path = Get-PkgsTool -Name $tool.name -TestOverride $tool.test
        if ($path) { & $add $tool.name 'OK' $path }
        elseif ($tool.name -eq 'fzf') { & $add $tool.name 'FAIL' 'not found; interactive UI unavailable' }
        else { & $add $tool.name 'WARN' 'not found (optional)' }
    }

    try {
        $config = Get-PkgsConfig -Refresh
        & $add 'config' 'OK' "$(Get-PkgsConfigPath) | $(@($config.ignored).Count) ignore entries | $(@($config.guard).Count) guard patterns"
    }
    catch {
        $message = $_.Exception.Message -replace '^PKGS_EXIT:\d+:', ''
        & $add 'config' 'FAIL' $message
    }

    $snapshotPath = Get-PkgsSnapshotPath
    if (Test-Path -LiteralPath $snapshotPath) {
        $size = (Get-Item -LiteralPath $snapshotPath).Length
        try {
            $cached = Get-Content -LiteralPath $snapshotPath -Raw -Encoding utf8 | ConvertFrom-Json
            $age = Get-PkgsAgeSeconds -Timestamp $cached.generated
            & $add 'cache' 'OK' "$snapshotPath | ${age}s old | $([math]::Round($size / 1024, 1)) KiB"
        }
        catch { & $add 'cache' 'WARN' "$snapshotPath | unreadable" }
    }
    else { & $add 'cache' 'OK' 'empty (will be built on first query)' }

    if ($mpm) {
        try {
            $snapshot = Get-PkgsSnapshot
            foreach ($manager in @($snapshot.managers | Sort-Object id)) {
                if ($manager.excluded) {
                    & $add "manager:$($manager.id)" 'INFO' "excluded: $($manager.excludeReason)"
                    continue
                }
                $detail = "$($manager.package_count) package(s), $($manager.outdated_count) outdated"
                if ($manager.version) { $detail = "v$($manager.version) | $detail" }
                if (@($manager.errors).Count -gt 0) { $detail += " | errors: $(@($manager.errors) -join '; ')" }
                if (@($manager.anomalies).Count -gt 0) { $detail += " | anomalies: $(@($manager.anomalies) -join '; ')" }
                $status = if (@($manager.errors).Count -gt 0 -or @($manager.anomalies).Count -gt 0) { 'WARN' } else { 'OK' }
                & $add "manager:$($manager.id)" $status $detail
            }
            if (@($snapshot.native_pins).Count -gt 0) {
                & $add 'native-pins' 'INFO' (@($snapshot.native_pins | ForEach-Object { "$($_.manager):$($_.id) ($($_.mechanism))" }) -join ', ')
            }
            else { & $add 'native-pins' 'OK' 'none configured' }
            if (-not $snapshot.pip_outdated_checked) { & $add 'pip-outdated' 'INFO' 'not checked in this snapshot; use --with-pip' }
            try {
                $decorated = @(Get-PkgsDecoratedPackages -Snapshot $snapshot -Config (Get-PkgsConfig))
                $stats = Get-PkgsInventoryStats -Packages $decorated -Snapshot $snapshot
                $script:PkgsDoctorInventory = $stats
                & $add 'inventory' 'OK' "$($stats.total_records) records | $($stats.visible_records) visible | $($stats.hidden_pip_records) pip | $($stats.outdated_visible) outdated | $($stats.protected_records) protected | $($stats.unknown_update_records) unknown | $($stats.unsupported_update_records) unsupported | $($stats.broken_records) broken"
            }
            catch {
                & $add 'inventory' 'WARN' "could not calculate inventory: $($_.Exception.Message)"
            }
        }
        catch {
            $message = $_.Exception.Message -replace '^PKGS_EXIT:\d+:', ''
            & $add 'snapshot' 'FAIL' $message
        }
    }

    & $add 'uv' 'INFO' 'excluded: mpm uv manager is environment-relative (project-local risk)'
    & $add 'pip' 'INFO' 'read-only adapters for explicitly configured global interpreters'
    & $add 'msstore' 'INFO' 'winget Store inventory adapter; mpm 8.3.0 omits Store packages'
    & $add 'background' 'OK' 'no service, tray, watcher or scheduled task; nothing stays running'

    $failed = @($script:PkgsDoctorChecks | Where-Object { $_.status -eq 'FAIL' })
    $ok = ($failed.Count -eq 0)

    if ($Parsed.flags['json']) {
        Set-PkgsJsonMode -Enabled
        Write-PkgsJson ([ordered]@{
            schema = $script:PkgsSchema
            command = 'doctor'
            ok = $ok
            generated = (Get-Date).ToUniversalTime().ToString('o')
            checks = @($script:PkgsDoctorChecks)
            inventory = $script:PkgsDoctorInventory
        })
        if (-not $ok) { return 1 }
        return 0
    }

    Write-Host ''
    foreach ($check in $script:PkgsDoctorChecks) {
        $color = switch ($check.status) {
            'OK' { 'Green' } 'WARN' { 'Yellow' } 'FAIL' { 'Red' } default { 'DarkGray' }
        }
        Write-Host ("  {0,-5} {1,-22} {2}" -f $check.status, $check.name, $check.detail) -ForegroundColor $color
    }
    Write-Host ''
    if (-not $ok) { Write-PkgsError "$($failed.Count) check(s) failed"; return 1 }
    Write-PkgsOk 'no failing checks'
    return 0
}

# ---------------------------------------------------------------------
#  Misc commands
# ---------------------------------------------------------------------
function Invoke-PkgsConfigCommand {
    param($Parsed)
    $action = if ($Parsed.positionals.Count -gt 0) { [string]$Parsed.positionals[0] } else { 'show' }
    switch ($action.ToLowerInvariant()) {
        'path' { Write-PkgsInfo (Get-PkgsConfigPath); return 0 }
        'show' {
            $config = Get-PkgsConfig
            Write-PkgsJson $config
            return 0
        }
        'validate' {
            try {
                $config = Get-PkgsConfig -Refresh
                $allowed = @('version', 'cacheTtlSeconds', 'managers', 'pip', 'guard', 'guardExceptions', 'ignored', 'ui')
                $unknown = @($config.PSObject.Properties.Name | Where-Object { $allowed -notcontains $_ })
                if ($unknown.Count -gt 0) {
                    Write-PkgsWarn "unknown top-level keys: $($unknown -join ', ')"
                    return 1
                }
                Write-PkgsOk "configuration is valid: $(Get-PkgsConfigPath)"
                return 0
            }
            catch {
                $message = $_.Exception.Message -replace '^PKGS_EXIT:\d+:', ''
                Write-PkgsError $message
                return 1
            }
        }
        default { Stop-Pkgs -Code 2 -Message "unknown config action '$action' (show|path|validate)" }
    }
}

function Invoke-PkgsRefreshCommand {
    param($Parsed)
    $snapshot = Get-PkgsSnapshot -Refresh -IncludePipOutdated:([bool]$Parsed.flags['with-pip'])
    Write-PkgsOk "snapshot rebuilt in $($snapshot.elapsed_ms) ms"
    Write-PkgsInfo "  managers: $(@($snapshot.managers | Where-Object { -not $_.excluded }).Count) | packages: $(@($snapshot.packages).Count) | outdated: $(@($snapshot.packages | Where-Object { $_.outdated }).Count)"
    if (@($snapshot.errors).Count -gt 0) {
        foreach ($snapErr in @($snapshot.errors)) { $suffix = if ($snapErr.id) { " [$($snapErr.id)]" } else { '' }; Write-PkgsWarn "$($snapErr.manager)/$($snapErr.scope)$suffix`: $($snapErr.message)" }
    }
    return 0
}

function Invoke-PkgsCleanCommand {
    $dir = Get-PkgsCachePath
    $freed = 0
    if (Test-Path -LiteralPath $dir) {
        $files = Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction Ignore
        $freed = ($files | Measure-Object -Property Length -Sum).Sum
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction Ignore
    }
    Write-PkgsOk "cache cleared ($([math]::Round($freed / 1024, 1)) KiB)"
    return 0
}

function Invoke-PkgsVersionCommand {
    Write-PkgsInfo "pkgs $($script:PkgsVersion) (schema $($script:PkgsSchema))"
    Write-PkgsInfo "PowerShell $($PSVersionTable.PSVersion)"
    $mpm = Get-PkgsMpmPath
    if ($mpm) { Write-PkgsInfo "mpm $(Get-PkgsMpmVersion) at $mpm" }
    else { Write-PkgsWarn 'mpm not found' }
    return 0
}

# ---------------------------------------------------------------------
#  Dispatch
# ---------------------------------------------------------------------
function Invoke-PkgsMain {
    param([string[]]$Argv)

    $commands = @('ui', 'browse', 'outdated', 'installed', 'managers', 'search', 'upgrade', 'install',
                  'remove', 'uninstall', 'pin', 'ignore', 'unprotect', 'show', 'doctor', 'howto',
                  'config', 'refresh', 'clean', 'version', 'help')

    if ($Argv.Count -eq 0) {
        $command = 'ui'
        $rest = @()
    }
    elseif ($Argv[0] -in @('--version', '-v', 'version')) {
        $null = Invoke-PkgsVersionCommand
        return 0
    }
    elseif ($Argv[0] -in @('--help', '-h', 'help')) {
        if ($Argv.Count -gt 1) { Write-Host (Get-PkgsCommandHelp -Command $Argv[1]) }
        else { Show-PkgsHelp }
        return 0
    }
    elseif ($commands -contains $Argv[0].ToLowerInvariant()) {
        $command = $Argv[0].ToLowerInvariant()
        if ($Argv.Count -gt 1) { $rest = @($Argv[1..($Argv.Count - 1)]) } else { $rest = @() }
    }
    else {
        $command = 'ui'
        $rest = @($Argv)
    }

    $aliases = @{ 'browse' = 'ui'; 'uninstall' = 'remove' }
    if ($aliases.ContainsKey($command)) { $command = $aliases[$command] }
    $script:PkgsCommandName = $command

    if ($command -eq 'howto') {
        $topic = if ($rest.Count -gt 0) { [string]$rest[0] } else { 'overview' }
        Show-PkgsHowTo -Topic $topic
        return 0
    }
    if ($command -eq 'help') {
        if ($rest.Count -gt 0) { Write-Host (Get-PkgsCommandHelp -Command $rest[0]) } else { Show-PkgsHelp }
        return 0
    }

    if (Test-PkgsJsonArgument -Arguments $rest -Command $command) { Set-PkgsJsonMode -Enabled }
    $parsed = ConvertFrom-PkgsArguments -Arguments $rest -Command $command
    if ($parsed.flags['help']) {
        Write-Host (Get-PkgsCommandHelp -Command $command)
        return 0
    }
    if ($parsed.flags['json']) { Set-PkgsJsonMode -Enabled }

    switch ($command) {
        'ui' {
            $requestedManagers = @()
            foreach ($value in @($parsed.values['manager'])) {
                foreach ($part in ([string]$value -split ',')) { if ($part.Trim()) { $requestedManagers += $part.Trim() } }
            }
            $withPip = [bool]$parsed.flags['with-pip'] -or (@($requestedManagers | Where-Object { $_ -like 'pip*' }).Count -gt 0)
            $snapshot = Get-PkgsSnapshot -Refresh:([bool]$parsed.flags['refresh']) -IncludePipOutdated:$withPip
            $managers = Get-PkgsManagerFilter -Parsed $parsed -Snapshot $snapshot
            Invoke-PkgsUi -Snapshot $snapshot -Config (Get-PkgsConfig) -Manager $managers -OutdatedOnly:([bool]$parsed.flags['outdated-only']) -IncludePip:$withPip
        }
        'outdated' { return (Invoke-PkgsInstalledCommand -Parsed $parsed -OutdatedOnly) }
        'installed' { return (Invoke-PkgsInstalledCommand -Parsed $parsed) }
        'managers' { return (Invoke-PkgsManagersCommand -Parsed $parsed) }
        'search' { return (Invoke-PkgsSearchCommand -Parsed $parsed) }
        'show' { return (Invoke-PkgsShowCommand -Parsed $parsed) }
        'upgrade' { return (Invoke-PkgsMutationCommand -Operation upgrade -Parsed $parsed) }
        'install' { return (Invoke-PkgsMutationCommand -Operation install -Parsed $parsed) }
        'remove' { return (Invoke-PkgsMutationCommand -Operation remove -Parsed $parsed) }
        'pin' { return (Invoke-PkgsPinCommand -Parsed $parsed) }
        'ignore' { return (Invoke-PkgsIgnoreCommand -Parsed $parsed) }
        'unprotect' { return (Invoke-PkgsUnprotectCommand -Parsed $parsed) }
        'doctor' { return (Invoke-PkgsDoctorCommand -Parsed $parsed) }
        'config' { return (Invoke-PkgsConfigCommand -Parsed $parsed) }
        'refresh' { return (Invoke-PkgsRefreshCommand -Parsed $parsed) }
        'clean' { return (Invoke-PkgsCleanCommand) }
        'version' { return (Invoke-PkgsVersionCommand) }
        default { Stop-Pkgs -Code 2 -Message "unknown command '$command'" }
    }
    return 0
}

# ---------------------------------------------------------------------
#  Entry
# ---------------------------------------------------------------------
$exitCode = 0
try {
    $exitCode = Invoke-PkgsMain -Argv @($args)
}
catch {
    $message = $_.Exception.Message
    if ($message -match '^PKGS_EXIT:(?<code>\d+):(?<detail>.*)$') {
        $exitCode = [int]$Matches.code
        $detail = $Matches.detail
        if ($detail) {
            if ($script:PkgsJsonRequested) {
                $json = [ordered]@{
                    schema    = $script:PkgsSchema
                    command   = $script:PkgsCommandName
                    ok        = $false
                    exit_code = $exitCode
                    error     = [ordered]@{ code = $exitCode; message = $detail }
                } | ConvertTo-Json -Depth 6
                [Console]::Out.WriteLine($json)
            }
            Write-PkgsError $detail
        }
    }
    else {
        $exitCode = 1
        if ($script:PkgsJsonRequested) {
            $json = [ordered]@{
                schema    = $script:PkgsSchema
                command   = $script:PkgsCommandName
                ok        = $false
                exit_code = $exitCode
                error     = [ordered]@{ code = 1; message = $message }
            } | ConvertTo-Json -Depth 6
            [Console]::Out.WriteLine($json)
        }
        Write-PkgsError $message
    }
}
finally {
    Clear-PkgsPreviewCache
}

if ($InShell) {
    $global:LASTEXITCODE = $exitCode
    return
}
exit $exitCode
