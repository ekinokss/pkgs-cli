# =====================================================================
#  pkgs-ui.ps1 - rendering, fzf interface, previews, confirmation
#  fzf is optional: every workflow has a non-interactive CLI form.
# =====================================================================

function Test-PkgsInteractive {
    if ($env:PKGS_TEST_MODE -eq '1' -and $env:PKGS_TEST_TTY -eq '1') { return $true }
    if ($env:PKGS_NO_INPUT -eq '1') { return $false }
    if ([Console]::IsInputRedirected) { return $false }
    return $true
}

function Get-PkgsHomeDirectory {
    if ($script:PkgsRoot) { return $script:PkgsRoot }
    if (Get-Variable -Name PkgsHome -Scope 1 -ErrorAction Ignore) { return $PkgsHome }
    return $PSScriptRoot
}

function Clear-PkgsPreviewCache {
    if ($script:PkgsPreviewDir) {
        Remove-Item -LiteralPath $script:PkgsPreviewDir -Recurse -Force -ErrorAction Ignore
        $script:PkgsPreviewDir = $null
    }
    $cache = Get-PkgsCachePath
    $legacy = Join-Path $cache 'preview'
    if (Test-Path -LiteralPath $legacy) { Remove-Item -LiteralPath $legacy -Recurse -Force -ErrorAction Ignore }
    if (Test-Path -LiteralPath $cache) {
        $cutoff = (Get-Date).ToUniversalTime().AddHours(-1)
        foreach ($dir in (Get-ChildItem -LiteralPath $cache -Directory -Filter 'preview-*' -ErrorAction Ignore)) {
            $ownerAlive = $true
            if ($dir.Name -match '^preview-(\d+)-') {
                $ownerAlive = [bool](Get-Process -Id ([int]$Matches[1]) -ErrorAction Ignore)
            }
            if (-not $ownerAlive -or $dir.LastWriteTimeUtc -lt $cutoff) {
                Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Ignore
            }
        }
    }
}

function Get-PkgsDecoratedPackages {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Config,
        $NativePins,
        [string[]]$Manager,
        [switch]$OutdatedOnly
    )

    if ($null -eq $NativePins) { $NativePins = @($Snapshot.native_pins) }
    $result = @()
    foreach ($pkg in @($Snapshot.packages)) {
        if ($Manager -and $Manager.Count -gt 0 -and ($Manager -notcontains $pkg.manager)) { continue }
        if ($OutdatedOnly -and -not $pkg.outdated) { continue }
        $result += Get-PkgsPackagePresentation -Package $pkg -Config $Config -NativePins $NativePins -PinErrors @($Snapshot.native_pin_errors) -Snapshot $Snapshot
    }
    return @($result)
}
# ---------------------------------------------------------------------
#  Tables
# ---------------------------------------------------------------------
function Write-PkgsTable {
    param(
        [AllowEmptyCollection()][object[]]$Rows = @(),
        [Parameter(Mandatory)][object[]]$Columns,
        [switch]$NoHeader
    )

    if (-not $Rows -or $Rows.Count -eq 0) {
        Write-PkgsDim '  (none)'
        return
    }

    $cells = @()
    foreach ($row in $Rows) {
        $line = @()
        foreach ($col in $Columns) {
            $value = & $col.Expression $row
            if ($null -eq $value) { $value = '' }
            $value = [string]$value
            if ($col.MaxWidth -and $col.MaxWidth -gt 2 -and $value.Length -gt $col.MaxWidth) {
                $value = $value.Substring(0, [Math]::Max(0, $col.MaxWidth - 3)) + '...'
            }
            $line += $value
        }
        $cells += , $line
    }

    $widths = @()
    for ($i = 0; $i -lt $Columns.Count; $i++) {
        $width = ([string]$Columns[$i].Header).Length
        foreach ($line in $cells) {
            if ($line[$i].Length -gt $width) { $width = $line[$i].Length }
        }
        $widths += $width
    }

    if (-not $NoHeader) {
        $header = @()
        for ($i = 0; $i -lt $Columns.Count; $i++) {
            $header += ([string]$Columns[$i].Header).PadRight($widths[$i])
        }
        Write-Host (($header -join '  ').TrimEnd()) -ForegroundColor DarkGray
        Write-Host (($header | ForEach-Object { '-' * $_.Length }) -join '  ') -ForegroundColor DarkGray
    }
    foreach ($line in $cells) {
        $out = @()
        for ($i = 0; $i -lt $Columns.Count; $i++) { $out += $line[$i].PadRight($widths[$i]) }
        Write-Host (($out -join '  ').TrimEnd())
    }
}

function Format-PkgsShortCapability {
    param($Capability, [string]$Kind)
    $items = @()
    switch ($Kind) {
        'read' {
            if ($Capability.installed -eq $true) { $items += 'i' }
            if ($Capability.outdated -eq $true) { $items += 'o' }
            elseif ($Capability.outdated -eq 'on-demand') { $items += 'o*' }
            if ($Capability.search -eq $true) { $items += 's' }
        }
        'write' {
            if ($Capability.install -eq $true) { $items += 'install' }
            if ($Capability.upgrade -eq $true) { $items += 'upgrade' }
            if ($Capability.remove -eq $true) { $items += 'remove' }
        }
    }
    if ($items.Count -eq 0) { return '-' }
    return ($items -join ',')
}

function Show-PkgsManagersTable {
    param([Parameter(Mandatory)]$Snapshot, [switch]$Compact)
    $rows = @()
    foreach ($m in @($Snapshot.managers | Sort-Object id)) {
        if ($m.excluded) {
            $rows += [pscustomobject]@{
                Manager = $m.id
                Version = $m.version
                Source = 'excluded'
                Packages = ''
                Outdated = ''
                Read = '-'
                Write = '-'
                Pin = '-'
                Notes = [string]$m.excludeReason
            }
            continue
        }
        $cap = if ($m.capabilities) { $m.capabilities } else { Get-PkgsCapability -Manager $m.id }
        $outdatedCell = $m.outdated_count
        if ($cap.outdated -is [string] -and $cap.outdated -eq 'on-demand' -and -not [bool](Get-PkgsProperty $Snapshot 'pip_outdated_checked' -Default $false)) { $outdatedCell = 'n/a' }
        elseif ($cap.outdated -ne $true) { $outdatedCell = '-' }
        $rows += [pscustomobject]@{
            Manager = $m.id
            Version = $m.version
            Source = $m.source
            Packages = $m.package_count
            Outdated = $outdatedCell
            Read = Format-PkgsShortCapability -Capability $cap -Kind read
            Write = Format-PkgsShortCapability -Capability $cap -Kind write
            Pin = $cap.pin
            Notes = $cap.notes
        }
    }
    if ($Compact) {
        $notesWidth = if ((Get-PkgsTerminalWidth) -lt 90) { 24 } else { 32 }
        $columns = @(
            @{ Header = 'MANAGER'; Expression = { param($r) $r.Manager }; MaxWidth = 18 }
            @{ Header = 'VERSION'; Expression = { param($r) $r.Version }; MaxWidth = 10 }
            @{ Header = 'PKGS'; Expression = { param($r) $r.Packages }; MaxWidth = 5 }
            @{ Header = 'OUTDATED'; Expression = { param($r) $r.Outdated }; MaxWidth = 8 }
            @{ Header = 'PIN'; Expression = { param($r) $r.Pin }; MaxWidth = 7 }
            @{ Header = 'NOTES'; Expression = { param($r) $r.Notes }; MaxWidth = $notesWidth }
        )
        Write-PkgsTable -Rows $rows -Columns $columns
        Write-PkgsDim 'Pin: native/local. Use `pkgs managers` for read/write capability details.'
        return
    }
    $columns = @(
        @{ Header = 'MANAGER'; Expression = { param($r) $r.Manager } }
        @{ Header = 'VERSION'; Expression = { param($r) $r.Version } }
        @{ Header = 'SOURCE'; Expression = { param($r) $r.Source } }
        @{ Header = 'PKGS'; Expression = { param($r) $r.Packages } }
        @{ Header = 'OUTDATED'; Expression = { param($r) $r.Outdated } }
        @{ Header = 'READ'; Expression = { param($r) $r.Read } }
        @{ Header = 'WRITE'; Expression = { param($r) $r.Write } }
        @{ Header = 'PIN'; Expression = { param($r) $r.Pin } }
        @{ Header = 'NOTES'; Expression = { param($r) $r.Notes } }
    )
    Write-PkgsTable -Rows $rows -Columns $columns
    Write-PkgsDim ''
    Write-PkgsDim 'READ: i=installed o=outdated s=search (o*=queried on demand)   WRITE: install,upgrade,remove'
}

function Show-PkgsPackageTable {
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [switch]$ShowStatus
    )
    $columns = @(
        @{ Header = 'PACKAGE'; Expression = { param($p) $p.display_name }; MaxWidth = 34 }
        @{ Header = 'TYPE'; Expression = { param($p) $p.type }; MaxWidth = 22 }
        @{ Header = 'INSTALLED'; Expression = { param($p) $p.installed_display }; MaxWidth = 14 }
        @{ Header = 'AVAILABLE'; Expression = { param($p) $p.available_display }; MaxWidth = 14 }
        @{ Header = 'MANAGER'; Expression = { param($p) $p.manager_name }; MaxWidth = 22 }
        @{ Header = 'STATUS'; Expression = { param($p) $p.status_label }; MaxWidth = 34 }
    )
    Write-PkgsTable -Rows $Packages -Columns $columns
}

# ---------------------------------------------------------------------
#  Details + previews
# ---------------------------------------------------------------------
function Get-PkgsDetailText {
    param([Parameter(Mandatory)]$Package)

    $lines = @()
    $lines += "Package      $($Package.display_name)"
    $lines += "Type         $($Package.type)"
    $lines += "Manager      $($Package.manager_name) [$($Package.manager)]"
    $lines += "Canonical ID $($Package.target)"
    $lines += "Scope        $($Package.scope)"
    $lines += "Installed    $($Package.installed_display)"
    $lines += "Available    $($Package.available_display)"
    $lines += "Update       $($Package.status_label)"
    $lines += "Evidence     $($Package.update_evidence)"
    $lines += "Source       $($Package.source)"
    $lines += "Name source  $($Package.name_source)"
    if ($Package.protected) {
        $lines += "Protection   $($Package.protection_summary)"
        foreach ($reason in @($Package.protection)) {
            $sourceNote = if ($reason.source) { " [$($reason.source)]" } else { '' }
            $lines += "             - $($reason.kind): $($reason.label) $($reason.detail)$sourceNote"
        }
    }
    else {
        $lines += "Protection   none"
    }
    if ($Package.notes -and @($Package.notes).Count -gt 0) {
        $lines += "Notes        $(@($Package.notes) -join '; ')"
    }
    $lines += "Operations   install=$($Package.operations.install) upgrade=$($Package.operations.upgrade) remove=$($Package.operations.remove)"
    if ($Package.capability.notes) { $lines += "Backend      $($Package.capability.notes)" }
    $lines += ''
    if ($Package.install_candidate) {
        $lines += "install      pkgs install $($Package.target) --dry-run"
    }
    else {
        if ($Package.operations.upgrade -eq $true) {
            $lines += "upgrade      pkgs upgrade $($Package.target) --dry-run"
        }
        else {
            $lines += "upgrade      unavailable: $($Package.capability.notes)"
        }
        if ($Package.operations.remove -eq $true) {
            $lines += "remove       pkgs remove $($Package.target) --dry-run"
        }
        else {
            $lines += "remove       unavailable: $($Package.capability.notes)"
        }
    }
    return ($lines -join [Environment]::NewLine)
}
function Show-PkgsPackageDetails {
    param([Parameter(Mandatory)]$Package)
    Write-Host ''
    Write-Host (Get-PkgsDetailText -Package $Package)
    Write-Host ''
}

function Get-PkgsPreviewKey {
    param([Parameter(Mandatory)][string]$Target)
    $bytes = [Text.Encoding]::UTF8.GetBytes($Target.ToLowerInvariant())
    $hash = [Security.Cryptography.SHA1]::HashData($bytes)
    return ([Convert]::ToHexString($hash)).ToLowerInvariant().Substring(0, 16)
}

function New-PkgsPreviewFiles {
    <#
        Precompute one detail file per visible row for this UI session only.
        File names are stable hashes of the canonical manager:id target, so
        selection changes never depend on row order or filename parsing.
    #>
    param([Parameter(Mandatory)][object[]]$Rows)

    Clear-PkgsPreviewCache
    $session = Join-Path (Get-PkgsCachePath) ("preview-{0}-{1}" -f $PID, [guid]::NewGuid().ToString('N').Substring(0, 8))
    $null = New-Item -ItemType Directory -Path $session -Force
    $script:PkgsPreviewDir = $session
    foreach ($row in $Rows) {
        $key = Get-PkgsPreviewKey -Target $row.Package.target
        $text = Get-PkgsDetailText -Package $row.Package
        [IO.File]::WriteAllText((Join-Path $session "$key.txt"), $text, [Text.UTF8Encoding]::new($false))
    }
    return $session
}

function Get-PkgsTerminalWidth {
    $override = Get-PkgsTestOverride -Name 'PKGS_TEST_WIDTH'
    if ($override -and $override -match '^\d+$') { return [int]$override }
    try {
        $width = [Console]::WindowWidth
        if ($width -gt 0) { return $width }
    }
    catch { }
    return 120
}

function Get-PkgsListLayout {
    param([int]$Width = 0)
    if ($Width -le 0) { $Width = Get-PkgsTerminalWidth }
    if ($Width -ge 110) {
        return [pscustomobject]@{ Mode = 'wide'; Package = 22; Type = 13; Installed = 9; Available = 13; Manager = 10; Status = 30 }
    }
    if ($Width -ge 96) {
        return [pscustomobject]@{ Mode = 'medium'; Package = 20; Type = 12; Installed = 8; Available = 12; Manager = 9; Status = 24 }
    }
    if ($Width -ge 72) {
        return [pscustomobject]@{ Mode = 'narrow'; Package = 20; Type = 10; Installed = 0; Available = 0; Manager = 0; Status = 26; Versions = 19 }
    }
    return [pscustomobject]@{ Mode = 'compact'; Package = 20; Type = 0; Installed = 0; Available = 0; Manager = 0; Status = 14; Versions = 17 }
}

function Format-PkgsUiCell {
    param([string]$Value, [int]$Width)
    if ($Width -le 0) { return '' }
    $text = if ($null -eq $Value) { '' } else { [string]$Value }
    if ($text.Length -gt $Width) {
        if ($Width -le 3) { return $text.Substring(0, $Width) }
        return $text.Substring(0, $Width - 3) + '...'
    }
    return $text.PadRight($Width)
}

function New-PkgsPackageRow {
    param(
        [Parameter(Mandatory)]$Package,
        [int]$Width = 0
    )

    $layout = Get-PkgsListLayout -Width $Width
    $esc = [char]27
    $name = Format-PkgsUiCell -Value $Package.display_name -Width $layout.Package
    $type = Format-PkgsUiCell -Value $Package.type -Width $layout.Type
    $manager = Format-PkgsUiCell -Value $Package.manager -Width $layout.Manager
    $statusColor = if ($Package.protected) { '33' } elseif ($Package.broken) { '35' } elseif ($Package.outdated) { '36' } elseif ($Package.update_state -eq 'unsupported') { '90' } else { '0' }
    $status = Format-PkgsUiCell -Value $Package.status_label -Width $layout.Status

    $parts = @()
    $parts += "$esc[36m$name$esc[0m"
    if ($layout.Mode -eq 'wide' -or $layout.Mode -eq 'medium') {
        $installed = Format-PkgsUiCell -Value $Package.installed_display -Width $layout.Installed
        $available = Format-PkgsUiCell -Value $Package.available_display -Width $layout.Available
        $parts += $type.TrimEnd()
        $parts += $installed.TrimEnd()
        $parts += $available.TrimEnd()
        $parts += $manager.TrimEnd()
    }
    elseif ($layout.Mode -eq 'narrow') {
        $versions = "$($Package.installed_display) -> $($Package.available_display)"
        $parts += $type.TrimEnd()
        $parts += (Format-PkgsUiCell -Value $versions -Width $layout.Versions).TrimEnd()
    }
    else {
        $versions = "$($Package.installed_display) -> $($Package.available_display)"
        $parts += (Format-PkgsUiCell -Value $versions -Width $layout.Versions).TrimEnd()
    }
    $parts += "$esc[${statusColor}m$($status.TrimEnd())$esc[0m"
    return ($parts -join '  ')
}

function Get-PkgsFzfPath { return (Get-PkgsTool -Name 'fzf' -TestOverride 'PKGS_TEST_FZF') }
function Get-PkgsBatPath { return (Get-PkgsTool -Name 'bat' -TestOverride 'PKGS_TEST_BAT') }

function Invoke-PkgsFzf {
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]]$InputLines,
        [Parameter(Mandatory)][string[]]$Arguments
    )
    $fzf = Get-PkgsFzfPath
    if (-not $fzf) { Stop-Pkgs -Code 5 -Message 'fzf not found in PATH' }

    $oldEncoding = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
        $output = @($InputLines | & $fzf @Arguments)
        $code = $LASTEXITCODE
    }
    finally {
        [Console]::OutputEncoding = $oldEncoding
    }

    if ($code -eq 130 -or $code -eq 1) { return @() }
    if ($code -ne 0) {
        Stop-Pkgs -Code 5 -Message "fzf failed (exit $code)"
    }
    return @($output)
}
function Get-PkgsPreviewCommand {
    param([Parameter(Mandatory)][string]$PreviewDir)
    $cmd = Join-Path (Get-PkgsHomeDirectory) 'preview.cmd'
    # Forward slash before the raw placeholder is required: fzf treats a
    # backslash before a placeholder as an escape and leaves {4} literal.
    return "`"$cmd`" `"$PreviewDir/{r4}.txt`""
}
function Select-PkgsRows {
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)][string]$Header,
        [switch]$NoMulti,
        [string]$Prompt = 'pkgs> '
    )

    if ($Packages.Count -eq 0) { return @() }
    if (Test-PkgsInteractive) { try { Clear-Host } catch { } }
    $wrapped = @()
    foreach ($pkg in $Packages) {
        $wrapped += [pscustomobject]@{
            Package = $pkg
            Key = Get-PkgsPreviewKey -Target $pkg.target
        }
    }

    $cfg = Get-PkgsConfig
    $width = Get-PkgsTerminalWidth
    $layout = Get-PkgsListLayout -Width $width
    $rows = @()
    $byTarget = @{}
    foreach ($item in $wrapped) {
        $pkg = $item.Package
        $display = New-PkgsPackageRow -Package $pkg -Width $width
        $rows += ("{0}`t{1}`t{2}`t{3}`t{4}" -f $display, $pkg.manager, $pkg.id, $item.Key, $pkg.target)
        if (-not $byTarget.ContainsKey($pkg.target)) { $byTarget[$pkg.target] = $pkg }
    }

    $previewCmd = Join-Path (Get-PkgsHomeDirectory) 'preview.cmd'
    $usePreview = ($cfg.ui.preview -ne $false) -and (Test-Path -LiteralPath $previewCmd)
    $previewDir = $null
    if ($usePreview) { $previewDir = New-PkgsPreviewFiles -Rows $wrapped }

    $fzfArgs = @(
        '--ansi', '--height', [string]$cfg.ui.height, '--layout=reverse', '--border',
        '--prompt', $Prompt,
        '--header', $Header,
        '--delimiter', "`t", '--with-nth', '1',
        '--info', 'inline'
    )
    if (-not $NoMulti) { $fzfArgs += '--multi' }
    if ($usePreview -and $previewDir) {
        $fzfArgs += @(
            '--preview', (Get-PkgsPreviewCommand -PreviewDir $previewDir),
            '--preview-window', 'down,45%,wrap',
            '--bind', 'ctrl-/:toggle-preview,alt-up:preview-up,alt-down:preview-down'
        )
    }

    try {
        $output = Invoke-PkgsFzf -InputLines $rows -Arguments $fzfArgs
    }
    finally {
        Clear-PkgsPreviewCache
    }

    $selected = @()
    foreach ($line in $output) {
        if (-not $line) { continue }
        $parts = $line -split "`t"
        $target = $null
        if ($parts.Count -ge 5) { $target = [string]$parts[4] }
        elseif ($parts.Count -ge 3) { $target = "$($parts[1]):$($parts[2])" }
        if (-not $target) { Write-PkgsWarn 'ignored a selection without a canonical identity'; continue }
        if (-not $byTarget.ContainsKey($target)) {
            Write-PkgsWarn "ignored selection with unknown identity: $target"
            continue
        }
        $selected += $byTarget[$target]
    }
    return @($selected)
}
function Show-PkgsActionMenu {
    param(
        [Parameter(Mandatory)][string[]]$Items,
        [Parameter(Mandatory)][string]$Header,
        [string]$Prompt = 'action> '
    )
    $fzf = Get-PkgsFzfPath
    if (-not $fzf) { Stop-Pkgs -Code 5 -Message 'fzf not found in PATH' }
    if (Test-PkgsInteractive) { try { Clear-Host } catch { } }
    $choice = @($Items | & $fzf '--height' '40%' '--layout=reverse' '--border' '--no-multi' '--prompt' $Prompt '--header' $Header '--info' 'inline')
    if ($LASTEXITCODE -ne 0 -or -not $choice) { return $null }
    return [string]$choice[0]
}

# ---------------------------------------------------------------------
#  Plan display + confirmation
# ---------------------------------------------------------------------
function Show-PkgsPlan {
    param([Parameter(Mandatory)]$Plan)
    $rows = @()
    foreach ($entry in @($Plan.entries)) {
        $rows += [pscustomobject]@{
            Target = $entry.target
            Change = if ($entry.from -and $entry.to) { "$($entry.from) -> $($entry.to)" } elseif ($entry.from) { $entry.from } elseif ($entry.to) { $entry.to } else { '' }
            State = if ($entry.blocked) { 'BLOCKED' } else { 'ready' }
            Reason = $entry.reason
        }
    }
    $columns = @(
        @{ Header = 'TARGET'; Expression = { param($r) $r.Target } }
        @{ Header = 'CHANGE'; Expression = { param($r) $r.Change } }
        @{ Header = 'STATE'; Expression = { param($r) $r.State } }
        @{ Header = 'REASON'; Expression = { param($r) $r.Reason } }
    )
    Write-Host ''
    Write-PkgsTable -Rows $rows -Columns $columns

    $commands = @($Plan.entries | Where-Object { -not $_.blocked -and ($_.invocation -or $_.native) })
    if ($commands.Count -gt 0) {
        Write-Host ''
        Write-Host $(if ($Plan.cached) { 'Execution (planned from the cached snapshot; mutations re-verify live)' } else { 'Execution' }) -ForegroundColor DarkGray
        foreach ($entry in $commands) {
            Write-Host "  pkgs:   $($entry.invocation)"
            if ($entry.native -and $entry.native -ne $entry.invocation) { Write-Host "  native: $($entry.native)" -ForegroundColor DarkGray }
        }
    }
    foreach ($entry in @($Plan.entries | Where-Object { $_.native -match '--purge' })) {
        Write-PkgsWarn "$($entry.target) removal includes --purge (application data will be deleted)"
    }
    foreach ($entry in @($Plan.entries | Where-Object { -not $_.blocked -and $_.manager -eq 'choco' })) {
        Write-PkgsDim "  choco runs through gsudo; a UAC prompt may appear"
        break
    }
    Write-Host ''
}

function Read-PkgsTypedConfirmation {
    param([Parameter(Mandatory)][string]$Word, [string]$Prompt)
    if (-not $Prompt) { $Prompt = "Type '$Word' to continue" }
    $answer = Read-Host "$Prompt"
    return ($answer -ceq $Word)
}

function Confirm-PkgsPlan {
    <#
        Returns 'yes', 'override' or 'no'. Native pins are never
        overridable: the pin must be removed deliberately first.
    #>
    param([Parameter(Mandatory)]$Plan)

    if (@($Plan.entries | Where-Object { $_.blocked -and $_.protection.hardBlock }).Count -gt 0) {
        return 'native-blocked'
    }
    if (@($Plan.entries | Where-Object { $_.blocked }).Count -gt 0) {
        Write-PkgsWarn 'some targets are protected by pkgs configuration'
        if (Test-PkgsInteractive) {
            if (Read-PkgsTypedConfirmation -Word 'OVERRIDE' -Prompt "This bypasses pkgs protection for these targets. Type 'OVERRIDE' to rebuild the plan") {
                return 'override'
            }
        }
        return 'no'
    }

    if (-not (Test-PkgsInteractive)) { return 'confirm-required' }
    $answer = Read-Host 'Proceed? [y/N]'
    if ($answer -match '^(?i)y(es)?$') { return 'yes' }
    return 'no'
}

# ---------------------------------------------------------------------
#  Interactive workflows
# ---------------------------------------------------------------------
function Read-PkgsPause {
    param([string]$Message = 'Press Enter to return')
    if (Test-PkgsInteractive) { $null = Read-Host $Message }
}

function Get-PkgsUiPackages {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Config,
        [string[]]$Manager,
        [switch]$OutdatedOnly,
        [switch]$IncludePip
    )
    $packages = @(Get-PkgsDecoratedPackages -Snapshot $Snapshot -Config $Config -Manager $Manager -OutdatedOnly:$OutdatedOnly)
    if (-not $IncludePip -and (-not $Manager -or $Manager.Count -eq 0)) {
        $packages = @($packages | Where-Object { $_.manager -notlike 'pip*' })
    }
    return @($packages)
}

function Format-PkgsAge {
    param([int]$Seconds)
    if ($Seconds -lt 60) { return "${Seconds}s" }
    if ($Seconds -lt 3600) { return ("{0}m" -f [int]($Seconds / 60)) }
    return ("{0}h" -f [int]($Seconds / 3600))
}
function Get-PkgsUiHeader {
    param($Snapshot, $Packages, [string]$Title)
    $stats = Get-PkgsInventoryStats -Packages $Packages -Snapshot $Snapshot
    $age = [int](Get-PkgsProperty -Object $Snapshot -Name 'cache_age_seconds' -Default 0)
    $width = Get-PkgsTerminalWidth
    if ($width -lt 90) {
        $line1 = "$Title | $($stats.visible_records) records | $($stats.outdated_visible) updates | $($stats.protected_records) protected"
        $line2 = 'Enter actions | Tab select | Ctrl-/ preview | Esc back'
    }
    else {
        $line1 = "$Title | $($stats.visible_records) visible | $($stats.outdated_visible) updates ($($stats.manual_update_records) manual) | $($stats.protected_records) protected | data $(Format-PkgsAge $age) old"
        $line2 = 'Enter details/actions | Tab multi-select | Ctrl-/ preview | Esc back | type to filter'
    }
    return @($line1, $line2) -join "`n"
}

function Invoke-PkgsUiProtect {
    <#
        Phase 2 regression: Enter on the action menu must never silently add
        protection. The exact targets are listed first and a [y/N] answer is
        required before any configuration is written.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Packages,
        [Parameter(Mandatory)]$Config
    )

    if ($Packages.Count -eq 0) { return }
    Write-Host ''
    Write-Host "Protect $($Packages.Count) package(s) with a local ignore entry:" -ForegroundColor DarkGray
    foreach ($pkg in $Packages) { Write-Host "  $($pkg.target)" }
    $answer = Read-Host 'Protect selected packages? [y/N]'
    if ($answer -notmatch '^(?i)y(es)?$') { return }

    foreach ($pkg in $Packages) {
        $null = Add-PkgsIgnoredRecord -Config $Config -Manager $pkg.manager -Id $pkg.id -Reason 'protected from pkgs UI' -Kind 'ignore'
        Write-PkgsOk "protected $($pkg.target)"
    }
}

function Show-PkgsUpdatesScreen {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Config,
        [string[]]$Manager,
        [switch]$IncludePip
    )

    while ($true) {
        $Snapshot = Get-PkgsSnapshot
        $packages = @(Get-PkgsUiPackages -Snapshot $Snapshot -Config $Config -Manager $Manager -OutdatedOnly -IncludePip:$IncludePip)
        if ($packages.Count -eq 0) {
            Write-PkgsInfo 'No available updates for the current filter.'
            Read-PkgsPause
            return
        }
        $packages = @($packages | Sort-Object @{ Expression = { if ($_.protected) { 1 } else { 0 } } }, manager_name, display_name)
        $header = Get-PkgsUiHeader -Snapshot $Snapshot -Packages $packages -Title 'Available Updates'
        $selected = @(Select-PkgsRows -Packages $packages -Header $header -Prompt 'updates> ')
        if ($selected.Count -eq 0) { return }

        $unprotected = @($selected | Where-Object { -not $_.protected -and $_.operations.upgrade -eq $true })
        $protected = @($selected | Where-Object { $_.protected -and $_.operations.upgrade -eq $true })
        $actions = @()
        if ($unprotected.Count -gt 0) { $actions += "Upgrade $($unprotected.Count) unprotected package(s)" }
        if ($protected.Count -gt 0) { $actions += "Override and upgrade $($protected.Count) protected package(s)" }
        if ($selected.Count -eq 1) { $actions += 'Show details' }
        if ($selected.Count -gt 0) { $actions += 'Protect selected (ignore)' }
        $actions += 'Back'

        $manual = @($selected | Where-Object { $_.outdated -and $_.operations.upgrade -ne $true }).Count
        $action = Show-PkgsActionMenu -Items $actions -Header "$($selected.Count) selected | $($unprotected.Count) unprotected upgrades | $($protected.Count) protected upgrades | $manual manual updates"
        if (-not $action -or $action -eq 'Back') { return }

        switch -Regex ($action) {
            '^Upgrade ' {
                Invoke-PkgsUiMutation -Operation upgrade -Packages $unprotected -Config $Config
            }
            '^Override and upgrade' {
                Invoke-PkgsUiMutation -Operation upgrade -Packages $protected -Config $Config -OverrideProtection
            }
            '^Show details' {
                Show-PkgsPackageDetails -Package $selected[0]
                Read-PkgsPause
            }
            '^Protect selected' {
                Invoke-PkgsUiProtect -Packages $selected -Config $Config
                return
            }
        }
    }
}

function Show-PkgsInstalledList {
    param(
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Config,
        [string]$FilterLabel = 'All packages'
    )

    while ($true) {
        $Snapshot = Get-PkgsSnapshot
        if ($Packages.Count -eq 0) {
            Write-PkgsInfo 'No installed packages match that filter.'
            Read-PkgsPause
            return
        }
        $sorted = @($Packages | Sort-Object manager_name, display_name)
        $header = Get-PkgsUiHeader -Snapshot $Snapshot -Packages $sorted -Title "Installed Packages - $FilterLabel"
        $selected = @(Select-PkgsRows -Packages $sorted -Header $header -Prompt 'installed> ')
        if ($selected.Count -eq 0) { return }

        $unprotectedRemove = @($selected | Where-Object { -not $_.protected -and $_.operations.remove -eq $true })
        $protectedRemove = @($selected | Where-Object { $_.protected -and $_.operations.remove -eq $true })
        $actions = @()
        if ($selected.Count -eq 1) { $actions += 'Show details' }
        if ($unprotectedRemove.Count -gt 0) { $actions += "Uninstall $($unprotectedRemove.Count) unprotected package(s)" }
        if ($protectedRemove.Count -gt 0) { $actions += "Override and uninstall $($protectedRemove.Count) protected package(s)" }
        if ($selected.Count -gt 0) { $actions += 'Protect selected (ignore)' }
        $actions += 'Back'

        $action = Show-PkgsActionMenu -Items $actions -Header "$($selected.Count) selected | $($unprotectedRemove.Count) removable | $($protectedRemove.Count) protected"
        if (-not $action -or $action -eq 'Back') { return }

        switch -Regex ($action) {
            '^Show details' {
                Show-PkgsPackageDetails -Package $selected[0]
                Read-PkgsPause
            }
            '^Uninstall ' {
                Invoke-PkgsUiMutation -Operation remove -Packages $unprotectedRemove -Config $Config
                return
            }
            '^Override and uninstall' {
                Invoke-PkgsUiMutation -Operation remove -Packages $protectedRemove -Config $Config -OverrideProtection
                return
            }
            '^Protect selected' {
                Invoke-PkgsUiProtect -Packages $selected -Config $Config
                return
            }
        }
    }
}

function Show-PkgsInstalledScreen {
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Config,
        [string[]]$Manager,
        [switch]$IncludePip
    )

    $all = @(Get-PkgsUiPackages -Snapshot $Snapshot -Config $Config -Manager $Manager -IncludePip:$IncludePip)
    if ($Manager -and $Manager.Count -gt 0) {
        $label = (@($Manager) -join ', ')
        Show-PkgsInstalledList -Packages $all -Snapshot $Snapshot -Config $Config -FilterLabel $label
        return
    }

    while ($true) {
        $choice = Show-PkgsActionMenu -Items @(
            "All packages ($($all.Count))",
            'By package manager...',
            'By package type...',
            'Back'
        ) -Header 'Installed Packages | choose a browsing scope'
        if (-not $choice -or $choice -eq 'Back') { return }

        if ($choice -like 'All packages*') {
            Show-PkgsInstalledList -Packages $all -Snapshot $Snapshot -Config $Config -FilterLabel 'All packages'
            continue
        }
        if ($choice -like 'By package manager*') {
            $groups = @($all | Group-Object -Property manager | Sort-Object Name)
            $map = @{}
            $items = @()
            foreach ($group in $groups) {
                $mgr = @($all | Where-Object manager -eq $group.Name) | Select-Object -First 1
                $label = "$($mgr.manager_name) [$($group.Name)] ($($group.Count))"
                $map[$label] = $group.Name
                $items += $label
            }
            $items += 'Back'
            $picked = Show-PkgsActionMenu -Items $items -Header 'Installed Packages | filter by manager'
            if ($picked -and $picked -ne 'Back' -and $map.ContainsKey($picked)) {
                $filtered = @($all | Where-Object manager -eq $map[$picked])
                Show-PkgsInstalledList -Packages $filtered -Snapshot $Snapshot -Config $Config -FilterLabel $picked
            }
            continue
        }
        if ($choice -like 'By package type*') {
            $groups = @($all | Group-Object -Property type | Sort-Object Name)
            $map = @{}
            $items = @()
            foreach ($group in $groups) {
                $label = "$($group.Name) ($($group.Count))"
                $map[$label] = $group.Name
                $items += $label
            }
            $items += 'Back'
            $picked = Show-PkgsActionMenu -Items $items -Header 'Installed Packages | filter by type'
            if ($picked -and $picked -ne 'Back' -and $map.ContainsKey($picked)) {
                $filtered = @($all | Where-Object type -eq $map[$picked])
                Show-PkgsInstalledList -Packages $filtered -Snapshot $Snapshot -Config $Config -FilterLabel $picked
            }
            continue
        }
    }
}

function Show-PkgsProtectedScreen {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Config, [switch]$IncludePip)

    while ($true) {
        $Snapshot = Get-PkgsSnapshot
        $all = @(Get-PkgsUiPackages -Snapshot $Snapshot -Config $Config -IncludePip:$IncludePip)
        $protected = @($all | Where-Object { $_.protected } | Sort-Object manager_name, display_name)
        if ($protected.Count -eq 0) {
            Write-PkgsInfo 'No installed packages are protected.'
            Read-PkgsPause
            return
        }
        $header = Get-PkgsUiHeader -Snapshot $Snapshot -Packages $protected -Title 'Protected / Ignored Packages'
        $selected = @(Select-PkgsRows -Packages $protected -Header $header -Prompt 'protected> ')
        if ($selected.Count -eq 0) { return }
        $actions = @()
        if ($selected.Count -eq 1) { $actions += 'Show details' }
        $actions += 'Unprotect instructions'
        $actions += 'Back'
        $action = Show-PkgsActionMenu -Items $actions -Header "$($selected.Count) protected package(s)"
        if (-not $action -or $action -eq 'Back') { return }
        if ($action -eq 'Show details') {
            Show-PkgsPackageDetails -Package $selected[0]
            Read-PkgsPause
        }
        else {
            Write-Host ''
            Write-Host 'Local protection can be removed with:' -ForegroundColor DarkGray
            Write-Host '  pkgs unprotect manager:id'
            Write-Host 'Native pins/holds must be removed deliberately:' -ForegroundColor DarkGray
            Write-Host '  pkgs pin --remove manager:id'
            Read-PkgsPause
        }
    }
}

function Show-PkgsManagersScreen {
    param([Parameter(Mandatory)]$Snapshot)
    Write-Host 'Package Managers & Health' -ForegroundColor Cyan
    Show-PkgsManagersTable -Snapshot $Snapshot -Compact
    if (@($Snapshot.errors).Count -gt 0) {
        Write-Host ''
        Write-PkgsWarn "backend errors: $(@($Snapshot.errors).Count)"
        foreach ($err in @($Snapshot.errors)) { Write-PkgsDim "  $($err.manager)/$($err.scope): $($err.message)" }
    }
    Read-PkgsPause
}

function Show-PkgsHelpScreen {
    Show-PkgsHowTo -Topic keys
    Write-Host ''
    Write-PkgsDim 'Useful commands: pkgs outdated | pkgs installed | pkgs managers | pkgs howto protection'
    Read-PkgsPause
}

function New-PkgsInstallCandidate {
    param($Manager, $Id, $Name, $LatestVersion, $Snapshot, $Config)
    $stub = [pscustomobject]@{
        manager           = $Manager
        id                = $Id
        name              = $Name
        installed_version = ''
        version_known     = $false
        latest_version    = $LatestVersion
        outdated          = $false
        update_known      = $true
        update_method     = 'manager search result'
        broken            = $false
        source            = $Manager
        implicit          = $false
        instances         = 1
        notes             = @()
    }
    return Get-PkgsPackagePresentation -Package $stub -Config $Config -NativePins @() -Snapshot $Snapshot -InstallCandidate
}

function Get-PkgsSearchCandidates {
    param([Parameter(Mandatory)][string]$Query, [Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Config)

    $candidates = @()
    $mpm = Assert-PkgsMpm
    $run = Invoke-PkgsNative -FilePath $mpm -TimeoutSeconds 900 -ArgumentList @('--no-pip', '--no-uv', '--table-format', 'json', 'search', $Query)
    if ($run.ExitCode -eq 0) {
        $data = ConvertFrom-MpmInventoryJson -Text $run.Stdout -Kind 'search'
        foreach ($mgrId in $data.managers.Keys) {
            $cap = Get-PkgsCapability -Manager $mgrId
            if ($cap.install -ne $true) { continue }
            foreach ($pkg in $data.managers[$mgrId].packages) {
                $id = [string]$pkg.id
                if (-not $id) { continue }
                $latest = [string](Get-PkgsProperty $pkg 'latest_version')
                $name = [string](Get-PkgsProperty $pkg 'name' -Default $id)
                $candidates += New-PkgsInstallCandidate -Manager $mgrId -Id $id -Name $name -LatestVersion $latest -Snapshot $Snapshot -Config $Config
            }
        }
    }

    $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
    if ($winget) {
        $store = Invoke-PkgsNative -FilePath $winget -TimeoutSeconds 240 -ArgumentList @(
            'search', '--source', 'msstore', '--query', $Query,
            '--accept-source-agreements', '--disable-interactivity', '--no-progress')
        if ($store.ExitCode -eq 0) {
            foreach ($row in (ConvertFrom-WingetTable -Text $store.Stdout)) {
                $candidates += New-PkgsInstallCandidate -Manager 'msstore' -Id $row.id -Name $row.name -LatestVersion $row.version -Snapshot $Snapshot -Config $Config
            }
        }
    }

    $seen = @{}
    return @($candidates | Where-Object {
        if ($seen.ContainsKey($_.target)) { return $false }
        $seen[$_.target] = $true
        return $true
    })
}

function Show-PkgsSearchInstallScreen {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Config)

    $query = Read-Host 'Search all package managers'
    if ([string]::IsNullOrWhiteSpace($query)) { return }
    Write-PkgsDim 'Searching...'
    $candidates = @(Get-PkgsSearchCandidates -Query $query -Snapshot $Snapshot -Config $Config)
    if ($candidates.Count -eq 0) {
        Write-PkgsInfo 'No packages found.'
        Read-PkgsPause
        return
    }
    $candidates = @($candidates | Sort-Object manager_name, display_name)
    $header = @(
        "Search & Install | '$query' | $($candidates.Count) results",
        'Enter install plan | Esc cancel | type to filter'
    ) -join "`n"
    $picked = @(Select-PkgsRows -Packages $candidates -Header $header -NoMulti -Prompt 'search> ')
    if ($picked.Count -eq 0) { return }

    $plan = New-PkgsPlan -Operation install -Targets @($picked[0].target) -Snapshot $Snapshot -Config $Config
    Show-PkgsPlan -Plan $plan
    if ((Confirm-PkgsPlan -Plan $plan) -ne 'yes') { return }
    $null = Invoke-PkgsPlan -Plan $plan
    Read-PkgsPause
}

function Show-PkgsHomeMenu {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Config, [switch]$IncludePip)

    $packages = @(Get-PkgsUiPackages -Snapshot $Snapshot -Config $Config -IncludePip:$IncludePip)
    $stats = Get-PkgsInventoryStats -Packages $packages -Snapshot $Snapshot
    $age = [int](Get-PkgsProperty -Object $Snapshot -Name 'cache_age_seconds' -Default 0)
    $updateLabel = if ($stats.outdated_visible -gt 0) { "Available Updates ($($stats.outdated_visible))" } else { 'Available Updates (none)' }
    $items = @(
        $updateLabel,
        "Installed Packages ($($stats.visible_records))",
        'Search & Install',
        "Protected / Ignored Packages ($($stats.protected_records))",
        "Package Managers & Health ($($stats.managers_active) active)",
        'Refresh Data',
        'Help / Keyboard Shortcuts',
        'Quit'
    )
    $width = Get-PkgsTerminalWidth
    if ($width -lt 90) {
        $header = @(
            'Package Management',
            "$($stats.visible_records) packages | $($stats.outdated_visible) updates | $($stats.protected_records) protected",
            'Enter select | Esc quit | type to filter'
        ) -join "`n"
    }
    else {
        $header = @(
            'Package Management',
            "$($stats.visible_records) visible packages | $($stats.outdated_visible) updates ($($stats.manual_update_records) manual) | $($stats.protected_records) protected | $($stats.managers_active) active managers | data $(Format-PkgsAge $age) old",
            'Enter select | Esc quit | type to filter | Updates is listed first'
        ) -join "`n"
    }
    return Show-PkgsActionMenu -Items $items -Header $header -Prompt 'pkgs> '
}

function Invoke-PkgsHomeScreen {
    param([Parameter(Mandatory)]$Snapshot, [Parameter(Mandatory)]$Config, [switch]$IncludePip)

    while ($true) {
        $snapshot = Get-PkgsSnapshot
        $choice = Show-PkgsHomeMenu -Snapshot $snapshot -Config $Config -IncludePip:$IncludePip
        if (-not $choice -or $choice -eq 'Quit') { return }
        if ($choice -like 'Available Updates*') {
            Show-PkgsUpdatesScreen -Snapshot $snapshot -Config $Config -IncludePip:$IncludePip
        }
        elseif ($choice -like 'Installed Packages*') {
            Show-PkgsInstalledScreen -Snapshot $snapshot -Config $Config -IncludePip:$IncludePip
        }
        elseif ($choice -like 'Search & Install*') {
            Show-PkgsSearchInstallScreen -Snapshot $snapshot -Config $Config
        }
        elseif ($choice -like 'Protected / Ignored*') {
            Show-PkgsProtectedScreen -Snapshot $snapshot -Config $Config -IncludePip:$IncludePip
        }
        elseif ($choice -like 'Package Managers*') {
            Show-PkgsManagersScreen -Snapshot $snapshot
        }
        elseif ($choice -like 'Refresh Data*') {
            $snapshot = Get-PkgsSnapshot -Refresh
            Write-PkgsOk 'Package data refreshed.'
            Read-PkgsPause
        }
        elseif ($choice -like 'Help / Keyboard*') {
            Show-PkgsHelpScreen
        }
    }
}

function Invoke-PkgsUi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Snapshot,
        [Parameter(Mandatory)]$Config,
        [string[]]$Manager,
        [switch]$OutdatedOnly,
        [switch]$IncludePip
    )

    if (-not (Get-PkgsFzfPath)) { Stop-Pkgs -Code 5 -Message 'fzf not found in PATH; install it with: winget install junegunn.fzf' }
    if (-not (Test-PkgsInteractive)) {
        Stop-Pkgs -Code 3 -Message 'interactive UI requires a terminal; use pkgs installed/outdated or pass explicit targets'
    }

    if ($OutdatedOnly) {
        Show-PkgsUpdatesScreen -Snapshot $Snapshot -Config $Config -Manager $Manager -IncludePip:$IncludePip
    }
    elseif ($Manager -and $Manager.Count -gt 0) {
        Show-PkgsInstalledScreen -Snapshot $Snapshot -Config $Config -Manager $Manager -IncludePip:$IncludePip
    }
    else {
        Invoke-PkgsHomeScreen -Snapshot $Snapshot -Config $Config -IncludePip:$IncludePip
    }
}
function Invoke-PkgsUiMutation {
    param(
        [Parameter(Mandatory)][ValidateSet('upgrade', 'remove')][string]$Operation,
        [Parameter(Mandatory)][object[]]$Packages,
        [Parameter(Mandatory)]$Config,
        [switch]$OverrideProtection
    )
    if ($Packages.Count -eq 0) { Write-PkgsWarn 'no selected package supports this operation'; return }

    $snapshot = Get-PkgsSnapshot
    $targets = @($Packages | Select-Object -ExpandProperty target)
    Write-PkgsDim 'Verifying targets against the package managers...'
    if ($OverrideProtection) {
        $plan = New-PkgsPlan -Operation $Operation -Targets $targets -Snapshot $snapshot -Config $Config -OverrideProtection
        Show-PkgsPlan -Plan $plan
        $stillBlocked = @($plan.entries | Where-Object { $_.blocked })
        if ($stillBlocked.Count -gt 0) {
            foreach ($entry in $stillBlocked) { Write-PkgsError "$($entry.target): $($entry.reason)" }
            return
        }
        if (-not (Read-PkgsTypedConfirmation -Word 'OVERRIDE' -Prompt "This bypasses pkgs protection. Type 'OVERRIDE' to continue")) { return }
        if (-not (Read-PkgsTypedConfirmation -Word 'CONFIRM' -Prompt "Type 'CONFIRM' to execute the protected operation")) { return }
        $null = Invoke-PkgsPlan -Plan $plan
        return
    }

    $plan = New-PkgsPlan -Operation $Operation -Targets $targets -Snapshot $snapshot -Config $Config
    Show-PkgsPlan -Plan $plan
    $answer = Confirm-PkgsPlan -Plan $plan
    if ($answer -eq 'native-blocked') {
        Write-PkgsError 'a selected package is blocked by a native pin/hold or an unreadable native protection state'
        foreach ($entry in @($plan.entries | Where-Object { $_.blocked })) { Write-PkgsError "  $($entry.target): $($entry.reason)" }
        return
    }
    if ($answer -eq 'override') {
        $plan = New-PkgsPlan -Operation $Operation -Targets $targets -Snapshot $snapshot -Config $Config -OverrideProtection
        Show-PkgsPlan -Plan $plan
        $stillBlocked = @($plan.entries | Where-Object { $_.blocked })
        if ($stillBlocked.Count -gt 0) {
            foreach ($entry in $stillBlocked) { Write-PkgsError "$($entry.target): $($entry.reason)" }
            return
        }
        if (-not (Read-PkgsTypedConfirmation -Word 'CONFIRM' -Prompt "Type 'CONFIRM' to apply the override")) { return }
    }
    elseif ($answer -ne 'yes') { return }
    $null = Invoke-PkgsPlan -Plan $plan
}

# ---------------------------------------------------------------------
#  Pin / ignore commands (shared by UI and CLI)
# ---------------------------------------------------------------------
function Get-PkgsPinTargetInfo {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)]$Snapshot)
    $resolved = Resolve-PkgsTarget -Spec $Target -Snapshot $Snapshot -AllowMissing
    # Install targets may not be present in the inventory.
    $manager = $resolved.manager
    $id = $resolved.id
    $cap = Get-PkgsCapability -Manager $manager
    return [pscustomobject]@{
        manager = $manager
        id = $id
        target = "$manager`:$id"
        pinKind = $cap.pin
        capability = $cap
    }
}

function Get-PkgsPinCommand {
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Id,
        [switch]$Remove
    )
    switch ($Manager) {
        'winget' {
            if ($Remove) { return "winget pin remove --id $Id --exact --source winget --accept-source-agreements --disable-interactivity --no-progress" }
            return "winget pin add --id $Id --exact --source winget --blocking --accept-source-agreements --disable-interactivity --no-progress"
        }
        'scoop' {
            if ($Remove) { return "scoop unhold $Id" }
            return "scoop hold $Id"
        }
        'choco' {
            if ($Remove) { return "gsudo choco pin remove -n=$Id" }
            return "gsudo choco pin add -n=$Id"
        }
        default { return $null }
    }
}

function Get-PkgsWingetPinReadState {
    <#
        Reads the live WinGet pin table and isolates the records for one exact
        package ID. A pin is only "owned" by pkgs when its source is the
        official winget source; a same-ID pin from another source must never be
        treated as the pin pkgs created or may remove.
    #>
    param([Parameter(Mandatory)][string]$Id)

    $pins = @(Get-PkgsLiveNativePins -Managers @('winget') -Refresh)
    $errors = @($script:PkgsPinReadErrors | Where-Object {
        $_ -and $_.manager -eq 'winget' -and ([string]$_.id -eq '' -or [string]$_.id -ieq $Id)
    })
    $matching = @($pins | Where-Object { $_.manager -eq 'winget' -and $_.id -ieq $Id })
    $owned = @($matching | Where-Object { [string]$_.source -eq 'winget' })

    return [pscustomobject]@{
        ok       = ($errors.Count -eq 0)
        error    = if ($errors.Count -gt 0) { [string]$errors[0].message } else { '' }
        matching = @($matching)
        owned    = @($owned)
    }
}

function Get-PkgsWingetPinAddPlan {
    <#
        Read-only preflight for adding a blocking WinGet pin. Requires exactly
        one installed record from the official winget source and refuses to
        replace an existing ordinary, gating, wrong-source or ambiguous pin.
    #>
    param([Parameter(Mandatory)][string]$Id)

    $identity = Get-PkgsWingetIdentityState -Id $Id
    if (-not $identity.ok) {
        return [pscustomobject]@{ ok = $false; already = $false; reason = "installed identity is unsafe: $($identity.reason)" }
    }
    if (-not $identity.installed) {
        return [pscustomobject]@{ ok = $false; already = $false; reason = 'the target is not installed; refusing to add a WinGet pin' }
    }

    $state = Get-PkgsWingetPinReadState -Id $Id
    if (-not $state.ok) {
        return [pscustomobject]@{ ok = $false; already = $false; reason = "could not read native pin state: $($state.error)" }
    }
    if ($state.matching.Count -gt 0) {
        if ($state.matching.Count -eq 1) {
            $pin = $state.matching[0]
            if ([string]$pin.source -eq 'winget' -and [string]$pin.type -eq 'Blocking') {
                return [pscustomobject]@{ ok = $true; already = $true; reason = 'a blocking winget pin already exists' }
            }
        }
        $labels = @($state.matching | ForEach-Object { "$($_.id)[$($_.source)/$(if ($_.type) { $_.type } else { 'unknown' })]" }) -join ', '
        return [pscustomobject]@{ ok = $false; already = $false; reason = "an existing native pin is present ($labels); remove it deliberately instead of replacing it" }
    }

    return [pscustomobject]@{ ok = $true; already = $false; reason = '' }
}

function Test-PkgsWingetPinRemovalTarget {
    <#
        Read-only ownership check for pin removal. The exact pin must be a
        single winget-source record with a readable type. A same-ID pin from
        another source is never removed.
    #>
    param([Parameter(Mandatory)][string]$Id)

    $state = Get-PkgsWingetPinReadState -Id $Id
    if (-not $state.ok) {
        return [pscustomobject]@{ ok = $false; reason = "could not read native pin state: $($state.error)" }
    }
    if ($state.matching.Count -eq 0) {
        return [pscustomobject]@{ ok = $false; reason = 'no native pin is recorded for this target' }
    }
    $unknown = @($state.matching | Where-Object { -not [string]$_.source })
    if ($unknown.Count -gt 0) {
        return [pscustomobject]@{ ok = $false; reason = 'a matching pin has no readable source; refusing to remove it' }
    }
    if ($state.owned.Count -eq 0) {
        $sources = @($state.matching | ForEach-Object { [string]$_.source } | Select-Object -Unique) -join ', '
        return [pscustomobject]@{ ok = $false; reason = "the recorded pin is not from source 'winget' ($sources); refusing to remove it" }
    }
    if ($state.owned.Count -gt 1) {
        return [pscustomobject]@{ ok = $false; reason = 'multiple winget-source pins matched this target; refusing to remove one' }
    }
    if (-not [string]$state.owned[0].type) {
        return [pscustomobject]@{ ok = $false; reason = 'the pin type is not readable; refusing to remove it' }
    }
    return [pscustomobject]@{ ok = $true; reason = ''; pin = $state.owned[0] }
}

function Test-PkgsNativePinState {
    param(
        [Parameter(Mandatory)][string]$Manager,
        [Parameter(Mandatory)][string]$Id,
        [switch]$Remove,
        [string]$ExpectedType = '',
        [string]$ExpectedSource = ''
    )

    if ($Manager -eq 'winget') {
        $state = Get-PkgsWingetPinReadState -Id $Id
        if (-not $state.ok) {
            return [pscustomobject]@{ ok = $false; reason = "could not read native pin state: $($state.error)" }
        }
        if ($Remove) {
            $unknown = @($state.matching | Where-Object { -not [string]$_.source })
            if ($unknown.Count -gt 0) {
                return [pscustomobject]@{ ok = $false; reason = 'a matching pin has no readable source after removal' }
            }
            if ($state.owned.Count -gt 0) {
                return [pscustomobject]@{ ok = $false; reason = 'the winget-source pin is still present after removal' }
            }
            return [pscustomobject]@{ ok = $true; reason = 'no winget-source pin remains' }
        }

        if ($state.matching.Count -eq 0) {
            return [pscustomobject]@{ ok = $false; reason = 'no native pin is present after a successful command' }
        }
        if ($state.matching.Count -gt 1) {
            return [pscustomobject]@{ ok = $false; reason = 'multiple native pin records matched; refusing to treat one as success' }
        }
        $pin = $state.matching[0]
        if (-not [string]$pin.source) {
            return [pscustomobject]@{ ok = $false; reason = 'the pin source is not readable' }
        }
        if ($ExpectedSource -and [string]$pin.source -ne $ExpectedSource) {
            return [pscustomobject]@{ ok = $false; reason = "pin source is '$($pin.source)', expected '$ExpectedSource'" }
        }
        if (-not [string]$pin.type) {
            return [pscustomobject]@{ ok = $false; reason = 'the pin type is not readable' }
        }
        if ($ExpectedType -and [string]$pin.type -ne $ExpectedType) {
            return [pscustomobject]@{ ok = $false; reason = "pin type is '$($pin.type)', expected '$ExpectedType'" }
        }
        return [pscustomobject]@{ ok = $true; reason = "winget pin is present ($($pin.type), $($pin.source))" }
    }

    $pins = @(Get-PkgsLiveNativePins -Managers @($Manager) -Refresh)
    $errors = @($script:PkgsPinReadErrors | Where-Object {
        $_ -and $_.manager -eq $Manager -and ([string]$_.id -eq '' -or [string]$_.id -ieq $Id)
    })
    if ($errors.Count -gt 0) {
        return [pscustomobject]@{ ok = $false; reason = "could not read native pin state: $($errors[0].message)" }
    }

    $present = @($pins | Where-Object { $_.manager -eq $Manager -and $_.id -ieq $Id }).Count -gt 0
    if ($Remove) {
        if ($present) { return [pscustomobject]@{ ok = $false; reason = 'the native pin/hold is still present after removal' } }
        return [pscustomobject]@{ ok = $true; reason = 'pin/hold is absent' }
    }
    if (-not $present) { return [pscustomobject]@{ ok = $false; reason = 'the native pin/hold is not present after a successful command' } }
    return [pscustomobject]@{ ok = $true; reason = 'pin/hold is present' }
}

function Set-PkgsPin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Config,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)]$Snapshot,
        [switch]$Remove,
        [switch]$DryRun,
        [switch]$Interactive,
        [switch]$Yes
    )

    $info = Get-PkgsPinTargetInfo -Config $Config -Target $Target -Snapshot $Snapshot
    if (-not $info.manager) { Stop-Pkgs -Code 4 -Message "cannot resolve pin target '$Target'; use manager:id" }
    if ($info.manager -eq 'winget' -and -not (Test-PkgsWingetToken -Value $info.id -AllowBraces:$Remove)) {
        Stop-Pkgs -Code 2 -Message "package ID '$($info.id)' is not a valid WinGet identity"
    }

    if ($info.pinKind -eq 'native') {
        $command = Get-PkgsPinCommand -Manager $info.manager -Id $info.id -Remove:$Remove
        if ($DryRun) {
            Write-PkgsInfo "PIN   $($info.target)"
            Write-PkgsInfo "  $command"
            return
        }

        $wingetPinPlan = $null
        if ($info.manager -eq 'winget') {
            $wingetPinPlan = if ($Remove) {
                Test-PkgsWingetPinRemovalTarget -Id $info.id
            } else {
                Get-PkgsWingetPinAddPlan -Id $info.id
            }
            if (-not $wingetPinPlan.ok) {
                Stop-Pkgs -Code 5 -Message "cannot change the WinGet pin for $($info.target): $($wingetPinPlan.reason)"
            }
            if (-not $Remove -and $wingetPinPlan.already) {
                Write-PkgsOk "  OK ($($wingetPinPlan.reason))"
                return
            }
        }

        if (-not $DryRun -and -not $Yes -and ($Interactive -or (Test-PkgsInteractive))) {
            Write-PkgsInfo "PIN   $($info.target)"
            Write-PkgsInfo "  $command"
            if (-not (Read-PkgsTypedConfirmation -Word 'PIN' -Prompt "Type 'PIN' to execute")) { return }
        }

        if ($info.manager -eq 'winget') {
            # Re-check immediately before the native command; another process
            # could have installed, removed, pinned or re-sourced the target.
            $recheck = if ($Remove) {
                Test-PkgsWingetPinRemovalTarget -Id $info.id
            } else {
                Get-PkgsWingetPinAddPlan -Id $info.id
            }
            if (-not $recheck.ok) {
                Stop-Pkgs -Code 5 -Message "WinGet pin target changed before execution for $($info.target): $($recheck.reason)"
            }
            if (-not $Remove -and $recheck.already) {
                Write-PkgsOk "  OK ($($recheck.reason))"
                return
            }
        }

        $exit = Invoke-PkgsNativePinCommand -Info $info -Remove:$Remove
        if ($exit -ne 0) {
            $script:PkgsPinCache = @{}
            $script:PkgsPinErrorCache = @{}
            Clear-PkgsSnapshot
            Stop-Pkgs -Code 5 -Message "native pin command failed (exit $exit) for $($info.target)"
        }
        $verification = if ($info.manager -eq 'winget') {
            Test-PkgsNativePinState -Manager $info.manager -Id $info.id -Remove:$Remove -ExpectedType 'Blocking' -ExpectedSource 'winget'
        }
        else {
            Test-PkgsNativePinState -Manager $info.manager -Id $info.id -Remove:$Remove
        }
        if (-not $verification.ok) {
            $script:PkgsPinCache = @{}
            $script:PkgsPinErrorCache = @{}
            Clear-PkgsSnapshot
            Stop-Pkgs -Code 5 -Message "native pin verification failed for $($info.target): $($verification.reason)"
        }
        Write-PkgsOk "  OK ($($verification.reason))"
        $script:PkgsPinCache = @{}
        $script:PkgsPinErrorCache = @{}
        Clear-PkgsSnapshot
        return
    }

    # Local pin for managers with no native mechanism.
    if ($DryRun) {
        if ($Remove) { Write-PkgsInfo "PIN   $($info.target) (local) would be removed" }
        else { Write-PkgsInfo "PIN   $($info.target) (local) would be added to pkgs protection" }
        return
    }
    if (-not $Yes -and ($Interactive -or (Test-PkgsInteractive))) {
        Write-PkgsInfo "PIN   $($info.target) (local)"
        if (-not (Read-PkgsTypedConfirmation -Word 'PIN' -Prompt "Type 'PIN' to execute")) { return }
    }
    if ($Remove) {
        $removed = Remove-PkgsIgnoredRecord -Config $Config -Manager $info.manager -Id $info.id
        if ($removed) { Write-PkgsOk "unpinned $($info.target) (local)" } else { Write-PkgsWarn "no local pin for $($info.target)" }
    }
    else {
        $null = Add-PkgsIgnoredRecord -Config $Config -Manager $info.manager -Id $info.id -Reason 'local pin' -Kind 'pin'
        Write-PkgsOk "pinned $($info.target) (local; native pin not available for $($info.manager))"
    }
    Clear-PkgsSnapshot
}

function Write-PkgsPinNativeOutput {
    param($Run)
    if (-not $Run) { return }
    foreach ($line in (([string]$Run.Stdout) -split "`r?`n")) {
        if ($line) { Write-PkgsDim $line }
    }
    foreach ($line in (([string]$Run.Stderr) -split "`r?`n")) {
        if ($line) { Write-PkgsError $line }
    }
}

function Invoke-PkgsNativePinCommand {
    param([Parameter(Mandatory)]$Info, [switch]$Remove)
    $command = Get-PkgsPinCommand -Manager $Info.manager -Id $Info.id -Remove:$Remove
    switch ($Info.manager) {
        'winget' {
            $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
            if (-not $winget) { throw 'winget not found' }
            $cliArgs = if ($Remove) {
                @('pin', 'remove', '--id', $Info.id, '--exact', '--source', 'winget', '--accept-source-agreements', '--disable-interactivity', '--no-progress')
            } else {
                @('pin', 'add', '--id', $Info.id, '--exact', '--source', 'winget', '--blocking', '--accept-source-agreements', '--disable-interactivity', '--no-progress')
            }
            if ($script:PkgsJsonRequested) {
                $run = Invoke-PkgsNative -FilePath $winget -ArgumentList $cliArgs -TimeoutSeconds 300
                Write-PkgsPinNativeOutput -Run $run
                return $run.ExitCode
            }
            & $winget @cliArgs | Out-Host
            return $LASTEXITCODE
        }
        'scoop' {
            $scoop = Get-PkgsTool -Name 'scoop' -TestOverride 'PKGS_TEST_SCOOP'
            if (-not $scoop) { throw 'scoop not found' }
            $cliArgs = if ($Remove) { @('unhold', $Info.id) } else { @('hold', $Info.id) }
            if ($script:PkgsJsonRequested) {
                $run = Invoke-PkgsNative -FilePath $scoop -ArgumentList $cliArgs -TimeoutSeconds 300
                Write-PkgsPinNativeOutput -Run $run
                return $run.ExitCode
            }
            & $scoop @cliArgs | Out-Host
            return $LASTEXITCODE
        }
        'choco' {
            $gsudo = Get-PkgsTool -Name 'gsudo' -TestOverride 'PKGS_TEST_GSUDO'
            $choco = Get-PkgsTool -Name 'choco' -TestOverride 'PKGS_TEST_CHOCO'
            if (-not $choco) { throw 'choco not found' }
            $verb = if ($Remove) { 'remove' } else { 'add' }
            if ($gsudo) {
                $file = $gsudo
                $cliArgs = @($choco, 'pin', $verb, "-n=$($Info.id)")
            }
            else {
                $file = $choco
                $cliArgs = @('pin', $verb, "-n=$($Info.id)")
            }
            if ($script:PkgsJsonRequested) {
                $run = Invoke-PkgsNative -FilePath $file -ArgumentList $cliArgs -TimeoutSeconds 300
                Write-PkgsPinNativeOutput -Run $run
                return $run.ExitCode
            }
            & $file @cliArgs | Out-Host
            return $LASTEXITCODE
        }
    }
    Write-PkgsWarn $command
    return 1
}
