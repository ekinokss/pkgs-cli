# =====================================================================
#  pkgs-snapshot.ps1 - read-only inventory built from mpm + adapters
#  Every package manager remains the source of truth. Nothing here
#  mutates package state.
# =====================================================================

# ---------------------------------------------------------------------
#  Parsers
# ---------------------------------------------------------------------
function ConvertFrom-MpmInventoryJson {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [Parameter(Mandatory)][string]$Kind
    )

    if ([string]::IsNullOrWhiteSpace($Text)) {
        Stop-Pkgs -Code 5 -Message "mpm $Kind returned no output"
    }
    try {
        $obj = $Text | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Stop-Pkgs -Code 5 -Message "mpm $Kind returned malformed JSON: $($_.Exception.Message)"
    }

    $blocks = @{}
    $errors = @()
    foreach ($prop in $obj.PSObject.Properties) {
        $managerId = $prop.Name
        $block = $prop.Value
        $blockErrors = @(Get-PkgsProperty -Object $block -Name 'errors' -Default @())
        foreach ($e in $blockErrors) {
            if ($e) { $errors += [pscustomobject]@{ manager = $managerId; scope = $Kind; message = [string]$e } }
        }
        $blocks[$managerId] = [pscustomobject]@{
            id       = $managerId
            name     = Get-PkgsProperty -Object $block -Name 'name' -Default $managerId
            packages = @(Get-PkgsProperty -Object $block -Name 'packages' -Default @())
            errors   = $blockErrors
        }
    }
    return [pscustomobject]@{ managers = $blocks; errors = $errors }
}

function ConvertFrom-MpmManagersText {
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Text)

    $managers = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^Manager ID\s') { continue }
        if ($line -match '^[\s\-]+$') { continue }
        if ($line -notmatch '^(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\s{2,}(?<rest>.+)$') { continue }

        $id = $Matches.id
        $rest = $Matches.rest.Trim()
        $parts = @($rest -split '\s{2,}')
        $name = if ($parts.Count -ge 1) { $parts[0].Trim() } else { $id }
        $cli = if ($parts.Count -ge 2) { $parts[1].Trim() } else { '' }
        $version = if ($parts.Count -ge 3) { $parts[-1].Trim() } else { '' }
        $version = $version -replace '^[✓✘]\s*', ''
        $detected = $cli -match '^✓'
        $managers += [pscustomobject]@{
            id       = $id
            name     = $name
            cli      = ($cli -replace '^[✓✘]\s*', '')
            version  = $version
            detected = $detected
        }
    }
    return @($managers)
}

function ConvertFrom-WingetTable {
    <#
        winget has no JSON output for list/upgrade/pin. Parse its fixed
        table defensively; unreadable rows are skipped and counted by the
        caller through $script:LastWingetSkipped.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Text,
        [string[]]$RequiredColumns = @('Name', 'Id', 'Version')
    )

    $script:LastWingetSkipped = 0
    if ([string]::IsNullOrWhiteSpace($Text)) { return @() }
    if ($Text -match '(?i)no installed package|no package found|no pins configured') { return @() }

    $lines = @($Text -split "`r?`n")
    $headerIndex = -1
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^Name\s{2,}Id\s{2,}' -or ($lines[$i] -match '\bId\b' -and $lines[$i] -match '\bVersion\b' -and $lines[$i] -match '\bName\b')) {
            $headerIndex = $i
            break
        }
    }
    if ($headerIndex -lt 0) {
        $script:LastWingetSkipped = 1
        return @()
    }

    $header = $lines[$headerIndex]
    $headerMatch = [regex]::Match($header, '(?<name>Name)\s+(?<id>Id)\s+(?<version>Version)(?:\s+(?<available>Available))?(?:\s+(?<source>Source))?(?:\s+(?<pin>Pin\s?[Tt]ype))?')
    if (-not $headerMatch.Success) {
        $script:LastWingetSkipped = 1
        return @()
    }

    $cols = [ordered]@{
        name    = 0
        id      = $headerMatch.Groups['id'].Index
        version = $headerMatch.Groups['version'].Index
    }
    foreach ($extra in 'available', 'source', 'pin') {
        if ($headerMatch.Groups[$extra].Success) { $cols[$extra] = $headerMatch.Groups[$extra].Index }
    }

    $rows = @()
    for ($i = $headerIndex + 1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^\s*[-─]+\s*$') { continue }
        if ($line -match '^\s*\d+ package\(s\)' -or $line -match '^\s*\d+ upgrades? available\.?\s*$') { continue }
        if ($line -match '^The following packages') { continue }
        if ($line -match '^\s*Name\s+Id\s+Version') {
            $repeatHeader = [regex]::Match($line, '(?<name>Name)\s+(?<id>Id)\s+(?<version>Version)(?:\s+(?<available>Available))?(?:\s+(?<source>Source))?(?:\s+(?<pin>Pin\s?[Tt]ype))?')
            if ($repeatHeader.Success) {
                $cols = [ordered]@{ name = 0; id = $repeatHeader.Groups['id'].Index; version = $repeatHeader.Groups['version'].Index }
                foreach ($extra in 'available', 'source', 'pin') {
                    if ($repeatHeader.Groups[$extra].Success) { $cols[$extra] = $repeatHeader.Groups[$extra].Index }
                }
            }
            continue
        }
        if ($line.Length -le $cols.version) { $script:LastWingetSkipped++; continue }

        # The ID is the last whitespace-delimited token before the Version
        # column. This survives a display name longer than its column, which
        # shifts the ID right but never splits the ID itself.
        $prefix = $line.Substring(0, $cols.version).TrimEnd()
        $nameParts = @($prefix -split '\s+')
        if ($nameParts.Count -lt 2) { $script:LastWingetSkipped++; continue }
        $id = $nameParts[-1]
        $name = (@($nameParts[0..($nameParts.Count - 2)]) -join ' ').Trim()

        $rightTokens = @($line.Substring($cols.version).Trim() -split '\s+')
        $version = $rightTokens[0]
        $rest = @($rightTokens | Select-Object -Skip 1)
        $available = ''
        $source = ''
        $pintype = ''

        # Peel optional columns from the right so an empty Available value does
        # not shift Source into the wrong column.
        if ($cols.Contains('pin') -and $rest.Count -gt 0) {
            $pintype = $rest[-1]
            $rest = @($rest | Select-Object -SkipLast 1)
        }
        if ($cols.Contains('source') -and $rest.Count -gt 0) {
            $source = $rest[-1]
            $rest = @($rest | Select-Object -SkipLast 1)
        }
        if ($cols.Contains('available') -and $rest.Count -gt 0) {
            $available = $rest[-1]
        }

        if (-not $id -or $id -notmatch '^[A-Za-z0-9{][A-Za-z0-9._+{}\\-]*$' -or -not $version) {
            $script:LastWingetSkipped++
            continue
        }

        # winget sometimes collapses an empty Available column; reject rows
        # whose "source" cannot be a winget source name.
        if ($source -and $source -notmatch '^(winget|msstore|microsoftstore)$') {
            $available = $source
            $source = ''
        }
        $rows += [pscustomobject]@{
            name      = if ($name) { $name } else { $id }
            id        = $id
            version   = $version
            available = $available
            source    = $source
            pintype   = $pintype
        }
    }
    return @($rows)
}

function ConvertFrom-WingetPinList {
    param([AllowEmptyString()][string]$Text)
    if ([string]::IsNullOrWhiteSpace($Text)) {
        throw 'winget pin list returned no output; protection state is unknown'
    }
    if ($Text -match '(?i)no pins configured') { return @() }
    if ($Text -match '(?i)no installed package|no package found') {
        throw 'winget pin list returned an unexpected empty-result message; protection state is unknown'
    }
    $rows = ConvertFrom-WingetTable -Text $Text -RequiredColumns @('Name', 'Id', 'Version')
    if ($script:LastWingetSkipped -gt 0) {
        throw "winget pin list output was not fully readable ($($script:LastWingetSkipped) unparsed line(s)); protection state is unknown"
    }
    return @($rows | ForEach-Object {
        [pscustomobject]@{
            manager   = 'winget'
            id        = $_.id
            mechanism = 'winget pin'
            detail    = if ($_.pintype) { $_.pintype } else { 'pinned' }
            type      = [string]$_.pintype
            source    = [string]$_.source
        }
    })
}

function ConvertFrom-ChocoPinList {
    param([AllowEmptyString()][string]$Text)
    $pins = @()
    foreach ($line in ($Text -split "`r?`n")) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        if ($line -match '^(Chocolatey|Pin|Outdated|\s)') { continue }
        if ($line -notmatch '^(?<id>[A-Za-z0-9][A-Za-z0-9._-]*)\|(?<ver>\S*)') { continue }
        $pins += [pscustomobject]@{
            manager   = 'choco'
            id        = $Matches.id
            mechanism = 'choco pin'
            detail    = if ($Matches.ver) { "version $($Matches.ver)" } else { 'pinned' }
        }
    }
    return @($pins)
}

function Get-PkgsScoopPortableRoot {
    <#
        Infer the Scoop installation root from its shim or app script path.
        Supported shapes:
          <root>\shims\scoop.ps1|scoop.cmd
          <root>\apps\scoop\current\bin\scoop.ps1
    #>
    $scoop = Get-PkgsTool -Name 'scoop' -TestOverride 'PKGS_TEST_SCOOP'
    if (-not $scoop) { return '' }
    try { $full = [IO.Path]::GetFullPath([string]$scoop) } catch { return '' }
    if ($full -match '^(?<root>.+)[\\/]shims[\\/]scoop\.(?:ps1|cmd)$') { return $Matches.root }
    if ($full -match '^(?<root>.+)[\\/]apps[\\/]scoop[\\/]current[\\/]bin[\\/]scoop\.ps1$') { return $Matches.root }
    return ''
}

function Get-PkgsScoopFileState {
    <#
        Classify a configuration-file path without treating every failed
        Test-Path as absence. Only a provably absent path is optional; an
        existing directory, denied access, or an unclassifiable path is a
        configuration error.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Path)

    $state = [ordered]@{
        path  = [string]$Path
        kind  = 'unknown'
        error = ''
    }
    if (-not $Path) {
        $state.error = 'Scoop configuration path is empty'
        return [pscustomobject]$state
    }
    try {
        $attributes = [IO.File]::GetAttributes($Path)
        if (($attributes -band [IO.FileAttributes]::Directory) -ne 0) {
            $state.kind = 'directory'
            $state.error = "Scoop configuration path '$Path' is a directory, not a file"
            return [pscustomobject]$state
        }
        $state.kind = 'file'
        return [pscustomobject]$state
    }
    catch [IO.FileNotFoundException] {
        $state.kind = 'absent'
        return [pscustomobject]$state
    }
    catch [IO.DirectoryNotFoundException] {
        $state.kind = 'absent'
        return [pscustomobject]$state
    }
    catch [UnauthorizedAccessException] {
        $state.kind = 'unreadable'
        $state.error = "cannot access Scoop configuration '$Path': $($_.Exception.Message)"
        return [pscustomobject]$state
    }
    catch {
        $state.kind = 'unknown'
        $state.error = "cannot establish whether Scoop configuration '$Path' exists: $($_.Exception.Message)"
        return [pscustomobject]$state
    }
}

function Get-PkgsScoopRootInfo {
    <#
        Resolve Scoop's effective user and global installation roots using the
        precedence implemented by Scoop itself:
          user:   SCOOP env, config root_path, portable root, USERPROFILE\scoop
          global: SCOOP_GLOBAL env, config global_path, CommonApplicationData\scoop
        The returned roots are apps directories (root\apps). Configuration read
        failures are returned as errors and must fail identity corroboration.
    #>
    $override = Get-PkgsTestOverride -Name 'PKGS_TEST_SCOOP_ROOT'
    if ($override) {
        return [pscustomobject]@{
            roots         = @([string]$override)
            userRoot      = [string]$override
            globalRoot    = ''
            configFile    = ''
            configError   = ''
            portableRoot  = ''
            sources       = @('PKGS_TEST_SCOOP_ROOT')
            errors        = @()
        }
    }

    $errors = @()
    $portableRoot = Get-PkgsScoopPortableRoot

    $configHome = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config' }
    $ordinaryConfigFile = Join-Path $configHome 'scoop\config.json'
    $portableConfigFile = if ($portableRoot) { Join-Path $portableRoot 'config.json' } else { '' }

    $ordinaryState = Get-PkgsScoopFileState -Path $ordinaryConfigFile
    $portableState = if ($portableConfigFile) { Get-PkgsScoopFileState -Path $portableConfigFile } else { $null }

    $ordinaryConfig = $null
    $portableConfig = $null
    $configErrors = @()
    $candidates = @([pscustomobject]@{ label = 'ordinary'; path = $ordinaryConfigFile; state = $ordinaryState })
    if ($portableState) { $candidates += [pscustomobject]@{ label = 'portable'; path = $portableConfigFile; state = $portableState } }

    foreach ($candidate in $candidates) {
        $state = $candidate.state
        if ($state.kind -eq 'absent') { continue }
        if ($state.kind -ne 'file') {
            $configErrors += $state.error
            continue
        }
        try {
            $parsed = Get-Content -LiteralPath $candidate.path -Raw -Encoding utf8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($null -eq $parsed -or $parsed -isnot [pscustomobject]) {
                throw 'JSON root is not an object'
            }
            if ($candidate.label -eq 'portable') { $portableConfig = $parsed }
            else { $ordinaryConfig = $parsed }
        }
        catch {
            $configErrors += "cannot read Scoop configuration '$($candidate.path)': $($_.Exception.Message)"
        }
    }
    $errors += @($configErrors)
    $configError = @($configErrors) -join '; '

    # Scoop uses the portable config only when it exists. If it exists but is
    # untrustworthy, never silently fall back to the ordinary config.
    $config = $null
    $configFile = ''
    if ($portableState) {
        if ($portableState.kind -eq 'file') {
            if ($portableConfig) { $config = $portableConfig; $configFile = $portableConfigFile }
        }
        elseif ($portableState.kind -eq 'absent') {
            if ($ordinaryState.kind -eq 'file' -and $ordinaryConfig) {
                $config = $ordinaryConfig
                $configFile = $ordinaryConfigFile
            }
        }
    }
    elseif ($ordinaryState.kind -eq 'file' -and $ordinaryConfig) {
        $config = $ordinaryConfig
        $configFile = $ordinaryConfigFile
    }

    $userValue = $env:SCOOP
    if (-not $userValue -and $config) { $userValue = [string](Get-PkgsProperty -Object $config -Name 'root_path' -Default '') }
    if (-not $userValue) { $userValue = $portableRoot }
    if (-not $userValue) {
        $userProfile = [Environment]::GetFolderPath('UserProfile')
        if (-not $userProfile) { $userProfile = $HOME }
        $userValue = Join-Path $userProfile 'scoop'
    }

    $globalValue = $env:SCOOP_GLOBAL
    if (-not $globalValue -and $config) { $globalValue = [string](Get-PkgsProperty -Object $config -Name 'global_path' -Default '') }
    if (-not $globalValue) {
        $commonData = [Environment]::GetFolderPath('CommonApplicationData')
        if (-not $commonData) { $commonData = $env:ProgramData }
        $globalValue = Join-Path $commonData 'scoop'
    }

    $resolveRoot = {
        param([string]$Value)
        if (-not $Value) { return '' }
        try { return $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Value) }
        catch {
            $script:PkgsScoopRootResolveError = "cannot resolve Scoop root '$Value': $($_.Exception.Message)"
            return ''
        }
    }
    $script:PkgsScoopRootResolveError = ''
    $userInstallRoot = & $resolveRoot $userValue
    $globalInstallRoot = & $resolveRoot $globalValue
    if ($script:PkgsScoopRootResolveError) { $errors += $script:PkgsScoopRootResolveError }

    $userAppsRoot = if ($userInstallRoot) { Join-Path $userInstallRoot 'apps' } else { '' }
    $globalAppsRoot = if ($globalInstallRoot) { Join-Path $globalInstallRoot 'apps' } else { '' }
    $roots = @()
    foreach ($root in @($userAppsRoot, $globalAppsRoot)) {
        if (-not $root) { continue }
        if (@($roots | Where-Object { [string]::Equals([string]$_, [string]$root, [StringComparison]::OrdinalIgnoreCase) }).Count -eq 0) {
            $roots += [string]$root
        }
    }

    return [pscustomobject]@{
        roots        = @($roots)
        userRoot     = $userAppsRoot
        globalRoot   = $globalAppsRoot
        configFile   = $configFile
        configError  = $configError
        portableRoot = $portableRoot
        sources      = @('SCOOP env/config/portable/default', 'SCOOP_GLOBAL env/config/default')
        errors       = @($errors)
    }
}

function Get-PkgsScoopRoots {
    $info = Get-PkgsScoopRootInfo
    return @($info.roots)
}

function Get-PkgsScoopRootState {
    <#
        Classify one path without treating every failed Test-Path as absence.
        An existing regular file, denied access, or unclassifiable error is a
        refusal; only a provably absent path is an optional-root skip.
    #>
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Root)

    $state = [ordered]@{
        path        = [string]$Root
        kind        = 'unknown'
        isDirectory = $false
        error       = ''
    }
    if (-not $Root) {
        $state.error = 'Scoop apps root path is empty'
        return [pscustomobject]$state
    }
    try {
        $attributes = [IO.File]::GetAttributes($Root)
        if (($attributes -band [IO.FileAttributes]::Directory) -eq 0) {
            $state.kind = 'file'
            $state.error = "Scoop apps root '$Root' exists but is not a directory"
            return [pscustomobject]$state
        }
        $state.kind = 'directory'
        $state.isDirectory = $true
        return [pscustomobject]$state
    }
    catch [IO.FileNotFoundException] {
        $state.kind = 'absent'
        return [pscustomobject]$state
    }
    catch [IO.DirectoryNotFoundException] {
        $state.kind = 'absent'
        return [pscustomobject]$state
    }
    catch [UnauthorizedAccessException] {
        $state.kind = 'unreadable'
        $state.error = "cannot access Scoop apps root '$Root': $($_.Exception.Message)"
        return [pscustomobject]$state
    }
    catch {
        $state.kind = 'unknown'
        $state.error = "cannot establish whether Scoop apps root '$Root' exists: $($_.Exception.Message)"
        return [pscustomobject]$state
    }
}

function Get-PkgsScoopIdentityEvidence {
    <#
        Corroborate an mpm/Scoop package ID against the real Scoop apps
        directories. This is a literal direct-child name comparison: IDs are
        never treated as paths, prefixes or wildcard expressions. A missing
        optional root is normal; an existing unreadable root, a missing exact
        directory or multiple matching roots is not trustworthy evidence.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Id,
        [string[]]$Roots
    )

    $idText = [string]$Id
    $rootInfo = $null
    if ($PSBoundParameters.ContainsKey('Roots')) {
        $rootList = @($Roots)
        $rootErrors = @()
    }
    else {
        $rootInfo = Get-PkgsScoopRootInfo
        $rootList = @($rootInfo.roots)
        $rootErrors = @($rootInfo.errors)
    }
    $evidence = [ordered]@{
        ok               = $false
        id               = $idText
        reason           = ''
        matchedRoot      = ''
        matchedDirectory = ''
        matchCount       = 0
        searchedRoots    = @()
        errors           = @()
    }

    if ([string]::IsNullOrWhiteSpace($idText)) {
        $evidence.reason = 'Scoop package ID is empty'
        return [pscustomobject]$evidence
    }

    $identityMatches = @()
    $errors = @()
    foreach ($rootError in $rootErrors) {
        $message = if ($rootError.message) { [string]$rootError.message } else { [string]$rootError }
        $errors += [pscustomobject]@{ root = ''; message = $message }
    }
    foreach ($root in $rootList) {
        $evidence.searchedRoots += [string]$root
        $state = Get-PkgsScoopRootState -Root ([string]$root)
        if ($state.kind -eq 'absent') { continue }
        if ($state.kind -ne 'directory') {
            $message = if ($state.error) { $state.error } else { "Scoop apps root '$root' is not a readable directory (state: $($state.kind))" }
            $errors += [pscustomobject]@{ root = [string]$root; message = $message }
            continue
        }
        try {
            foreach ($directory in [IO.Directory]::EnumerateDirectories($root)) {
                $leaf = [IO.Path]::GetFileName($directory)
                if ([string]::Equals($leaf, $idText, [StringComparison]::OrdinalIgnoreCase)) {
                    $identityMatches += [pscustomobject]@{ root = [string]$root; directory = [string]$directory }
                }
            }
        }
        catch {
            $errors += [pscustomobject]@{
                root    = [string]$root
                message = "cannot enumerate Scoop apps root '$root': $($_.Exception.Message)"
            }
        }
    }

    $evidence.matchCount = $identityMatches.Count
    $evidence.errors = @($errors)
    if ($errors.Count -gt 0) {
        $evidence.reason = (@($errors | ForEach-Object { $_.message }) -join '; ')
        return [pscustomobject]$evidence
    }
    if ($identityMatches.Count -eq 0) {
        $searched = if (@($evidence.searchedRoots).Count -gt 0) { @($evidence.searchedRoots) -join ', ' } else { '(no Scoop apps roots)' }
        $evidence.reason = "exact Scoop app directory '$idText' was not found under: $searched"
        return [pscustomobject]$evidence
    }
    if ($identityMatches.Count -gt 1) {
        $locations = @($identityMatches | ForEach-Object { $_.directory }) -join ', '
        $evidence.reason = "Scoop app ID '$idText' is ambiguous; matching directories: $locations"
        return [pscustomobject]$evidence
    }

    $evidence.ok = $true
    $evidence.matchedRoot = $identityMatches[0].root
    $evidence.matchedDirectory = $identityMatches[0].directory
    return [pscustomobject]$evidence
}

function Get-PkgsScoopInstallMetadata {
    <#
        Reads the active installation metadata for one Scoop app.

        Scoop 0.6.0 writes scoop-install.json for new installs and falls back to
        the legacy install.json for existing installs. Prefer the new file at
        current\; never fall back to the legacy file when the preferred file
        exists but is malformed. A missing or unreadable state is reported as
        unknown, not as an assumed unheld package.
    #>
    param([Parameter(Mandatory)][string]$AppRoot)

    $candidates = @(
        [pscustomobject]@{ Path = (Join-Path $AppRoot 'current\scoop-install.json'); Format = 'scoop-install.json' }
        [pscustomobject]@{ Path = (Join-Path $AppRoot 'current\install.json'); Format = 'install.json' }
    )
    $chosen = @($candidates | Where-Object { Test-Path -LiteralPath $_.Path } | Select-Object -First 1)
    if ($chosen.Count -eq 0) {
        return [pscustomobject]@{
            path     = ''
            format   = ''
            exists   = $false
            readable = $false
            held     = $false
            error    = 'installation metadata is missing (scoop-install.json/install.json)'
        }
    }

    $file = $chosen[0]
    try {
        $info = Get-Content -LiteralPath $file.Path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        if ($null -eq $info -or $info -isnot [pscustomobject]) { throw 'metadata is not a JSON object' }
        $holdProperty = $info.PSObject.Properties['hold']
        if ($holdProperty -and $holdProperty.Value -isnot [bool]) { throw 'hold is not a boolean' }
        $held = (Get-PkgsProperty -Object $info -Name 'hold' -Default $false) -eq $true
        return [pscustomobject]@{
            path     = $file.Path
            format   = $file.Format
            exists   = $true
            readable = $true
            held     = $held
            error    = ''
        }
    }
    catch {
        return [pscustomobject]@{
            path     = $file.Path
            format   = $file.Format
            exists   = $true
            readable = $false
            held     = $false
            error    = "cannot read $($file.Format): $($_.Exception.Message)"
        }
    }
}

function Get-PkgsScoopHoldReport {
    param([string[]]$Roots)

    $pins = @()
    $errors = @()
    $states = @()
    $existingRoots = 0

    foreach ($root in $Roots) {
        if (-not $root -or -not (Test-Path -LiteralPath $root)) { continue }
        $existingRoots++
        foreach ($app in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction Ignore)) {
            if ($app.Name -eq 'scoop') { continue }
            $metadata = Get-PkgsScoopInstallMetadata -AppRoot $app.FullName
            $states += [pscustomobject]@{
                manager  = 'scoop'
                id       = $app.Name
                held     = [bool]$metadata.held
                readable = [bool]$metadata.readable
                path     = $metadata.path
                format   = $metadata.format
                error    = $metadata.error
            }
            if (-not $metadata.readable) {
                $errors += [pscustomobject]@{
                    manager = 'scoop'
                    id      = $app.Name
                    scope   = 'pins'
                    message = $metadata.error
                    path    = $metadata.path
                }
                continue
            }
            if ($metadata.held) {
                $pins += [pscustomobject]@{
                    manager   = 'scoop'
                    id        = $app.Name
                    mechanism = 'scoop hold'
                    detail    = 'held'
                }
            }
        }
    }

    if ($existingRoots -eq 0) {
        $errors += [pscustomobject]@{
            manager = 'scoop'
            id      = ''
            scope   = 'pins'
            message = 'scoop apps root not found'
            path    = ''
        }
    }

    return [pscustomobject]@{
        pins   = @($pins)
        errors = @($errors)
        states = @($states)
    }
}

function Get-PkgsScoopHolds {
    param([string[]]$Roots)
    return @((Get-PkgsScoopHoldReport -Roots $Roots).pins)
}

# ---------------------------------------------------------------------
#  Adapters for coverage mpm does not provide
# ---------------------------------------------------------------------
function Add-PkgsWingetStorePackages {
    param(
        [Parameter(Mandatory)]$Records,
        [AllowEmptyString()][string]$InstalledText,
        [AllowEmptyString()][string]$UpgradeText,
        [bool]$UpgradeOk,
        [ref]$Anomalies,
        [ref]$Errors
    )

    $installed = ConvertFrom-WingetTable -Text $InstalledText
    if ($script:LastWingetSkipped -gt 0) {
        $Anomalies.Value += [pscustomobject]@{ manager = 'msstore'; kind = 'parse'; message = "$($script:LastWingetSkipped) unreadable row(s) in winget Store list" }
    }
    foreach ($row in $installed) {
        $key = 'msstore|' + $row.id.ToLowerInvariant()
        $Records[$key] = [pscustomobject]@{
            manager           = 'msstore'
            id                = $row.id
            name              = $row.name
            installed_version = $row.version
            version_known     = (Test-PkgsPlausibleVersion $row.version)
            latest_version    = ''
            outdated          = $false
            update_known      = $UpgradeOk
            update_method     = 'winget Store upgrade list'
            broken            = -not (Test-PkgsPlausibleVersion $row.version)
            source            = 'msstore'
            implicit          = $true
            installers        = @()
            instances         = 1
            notes             = @()
        }
    }

    $upgrades = ConvertFrom-WingetTable -Text $UpgradeText
    if ($script:LastWingetSkipped -gt 0) {
        $Anomalies.Value += [pscustomobject]@{ manager = 'msstore'; kind = 'parse'; message = "$($script:LastWingetSkipped) unreadable row(s) in winget Store upgrade list" }
    }
    foreach ($row in $upgrades) {
        $key = 'msstore|' + $row.id.ToLowerInvariant()
        if (-not $Records.Contains($key)) {
            if (-not (Test-PkgsPlausibleVersion $row.version)) { continue }
            $Records[$key] = [pscustomobject]@{
                manager           = 'msstore'
                id                = $row.id
                name              = $row.name
                installed_version = $row.version
                version_known     = (Test-PkgsPlausibleVersion $row.version)
                latest_version    = ''
                outdated          = $false
                update_known      = $UpgradeOk
                update_method     = 'winget Store upgrade list'
                broken            = $false
                source            = 'msstore'
                implicit          = $true
                installers        = @()
                instances         = 1
                notes             = @()
            }
        }
        $record = $Records[$key]
        if ($UpgradeOk -and (Test-PkgsPlausibleVersion $row.available) -and (Test-PkgsPlausibleVersion $row.version)) {
            $record.latest_version = $row.available
            $record.outdated = $true
            $record.update_known = $true
        }
        elseif ($UpgradeOk) {
            $record.notes += 'malformed Store upgrade entry ignored'
            $Anomalies.Value += [pscustomobject]@{ manager = 'msstore'; kind = 'version'; message = "ignored malformed Store upgrade entry for $($row.id)" }
        }
    }
    if (-not $UpgradeOk) {
        $Errors.Value += [pscustomobject]@{ manager = 'msstore'; scope = 'outdated'; message = 'winget Store upgrade query failed; update status unknown' }
    }
}

function Add-PkgsPipPackages {
    param(
        [Parameter(Mandatory)]$Records,
        [Parameter(Mandatory)]$Interpreter,
        [AllowEmptyString()][string]$InstalledText,
        [AllowEmptyString()][string]$OutdatedText,
        [bool]$OutdatedOk,
        [bool]$OutdatedChecked,
        [ref]$Anomalies,
        [ref]$Errors
    )

    $managerId = [string]$Interpreter.id
    try {
        $items = @()
        if (-not [string]::IsNullOrWhiteSpace($InstalledText)) {
            $items = @($InstalledText | ConvertFrom-Json -ErrorAction Stop)
        }
        foreach ($item in $items) {
            $id = [string](Get-PkgsProperty -Object $item -Name 'name')
            $ver = [string](Get-PkgsProperty -Object $item -Name 'version')
            if (-not $id) { continue }
            $key = $managerId.ToLowerInvariant() + '|' + $id.ToLowerInvariant()
            $Records[$key] = [pscustomobject]@{
                manager           = $managerId
                id                = $id
                name              = $id
                installed_version = $ver
                version_known     = (Test-PkgsPlausibleVersion $ver)
                latest_version    = ''
                outdated          = $false
                update_known      = $OutdatedChecked
                update_method     = if ($OutdatedChecked) { 'pip outdated check' } else { 'none' }
                broken            = -not (Test-PkgsPlausibleVersion $ver)
                source            = 'pip'
                implicit          = $false
                installers        = @()
                instances         = 1
                notes             = @()
            }
        }

        if ($OutdatedChecked -and $OutdatedOk -and -not [string]::IsNullOrWhiteSpace($OutdatedText)) {
            $outdated = @($OutdatedText | ConvertFrom-Json -ErrorAction Stop)
            foreach ($item in $outdated) {
                $id = [string](Get-PkgsProperty -Object $item -Name 'name')
                $ver = [string](Get-PkgsProperty -Object $item -Name 'version')
                $latest = [string](Get-PkgsProperty -Object $item -Name 'latest_version')
                if (-not $id) { continue }
                if (-not (Test-PkgsPlausibleVersion $ver) -or -not (Test-PkgsPlausibleVersion $latest)) { continue }
                $key = $managerId.ToLowerInvariant() + '|' + $id.ToLowerInvariant()
                if (-not $Records.Contains($key)) {
                    $Records[$key] = [pscustomobject]@{
                        manager           = $managerId
                        id                = $id
                        name              = $id
                        installed_version = $ver
                        version_known     = (Test-PkgsPlausibleVersion $ver)
                        latest_version    = ''
                        outdated          = $false
                        update_known      = $true
                        update_method     = 'pip outdated check'
                        broken            = $false
                        source            = 'pip'
                        implicit          = $false
                        installers        = @()
                        instances         = 1
                        notes             = @()
                    }
                }
                $Records[$key].latest_version = $latest
                $Records[$key].outdated = $true
                $Records[$key].update_known = $true
            }
        }
        elseif ($OutdatedChecked -and -not $OutdatedOk) {
            $Errors.Value += [pscustomobject]@{ manager = $managerId; scope = 'outdated'; message = 'pip outdated query failed; update status unknown' }
        }
    }
    catch {
        $Errors.Value += [pscustomobject]@{ manager = $managerId; scope = 'installed'; message = "pip output could not be parsed: $($_.Exception.Message)" }
    }
}

# ---------------------------------------------------------------------
#  Snapshot construction
# ---------------------------------------------------------------------
function Build-PkgsSnapshot {
    [CmdletBinding()]
    param([switch]$IncludePipOutdated)

    $sw = [Diagnostics.Stopwatch]::StartNew()
    Clear-PkgsRunCache
    $mpm = Assert-PkgsMpm
    $mpmVersion = Get-PkgsMpmVersion
    $cfg = Get-PkgsConfig

    $winget = Get-PkgsTool -Name 'winget' -TestOverride 'PKGS_TEST_WINGET'
    $choco  = Get-PkgsTool -Name 'choco'  -TestOverride 'PKGS_TEST_CHOCO'
    $scoop  = Get-PkgsTool -Name 'scoop'  -TestOverride 'PKGS_TEST_SCOOP'

    $jobs = @()
    $jobs += @{ name = 'installed'; file = $mpm; args = @('--no-pip', '--no-uv', '--table-format', 'json', 'installed'); env = $null; timeout = 900; required = $true }
    $jobs += @{ name = 'outdated';  file = $mpm; args = @('--no-pip', '--no-uv', '--table-format', 'json', 'outdated');  env = $null; timeout = 900; required = $false }
    $jobs += @{ name = 'managers';  file = $mpm; args = @('--no-pip', '--no-uv', '--accessible', 'managers'); env = @{ COLUMNS = '250' }; timeout = 180; required = $false }

    if ($winget) {
        $winArgs = @('--accept-source-agreements', '--disable-interactivity', '--no-progress')
        $jobs += @{ name = 'msstore-installed'; file = $winget; args = (@('list', '--source', 'msstore') + $winArgs); env = @{ COLUMNS = '250' }; timeout = 240; required = $false }
        $jobs += @{ name = 'msstore-outdated'; file = $winget; args = (@('upgrade', '--source', 'msstore') + $winArgs); env = @{ COLUMNS = '250' }; timeout = 240; required = $false }
        $jobs += @{ name = 'winget-pins'; file = $winget; args = (@('pin', 'list') + $winArgs); env = @{ COLUMNS = '250' }; timeout = 120; required = $false }
    }
    if ($choco) {
        $jobs += @{ name = 'choco-pins'; file = $choco; args = @('pin', 'list', '--limit-output', '--no-color'); env = $null; timeout = 120; required = $false }
    }

    $pipInterpreters = @()
    foreach ($interpreter in @($cfg.pip.interpreters)) {
        if ($null -eq $interpreter) { continue }
        if ((Get-PkgsProperty -Object $interpreter -Name 'enabled' -Default $true) -ne $true) { continue }
        $python = [string](Get-PkgsProperty -Object $interpreter -Name 'python')
        if (-not $python -or -not (Test-Path -LiteralPath $python)) { continue }
        $pipInterpreters += $interpreter
        $pipArgs = @('-m', 'pip', 'list', '--format=json', '--disable-pip-version-check')
        $jobs += @{ name = ('pip-installed:' + $interpreter.id); file = $python; args = $pipArgs; env = $null; timeout = 180; required = $false }
        if ($IncludePipOutdated) {
            $pipOutArgs = @('-m', 'pip', 'list', '--outdated', '--format=json', '--disable-pip-version-check')
            $jobs += @{ name = ('pip-outdated:' + $interpreter.id); file = $python; args = $pipOutArgs; env = $null; timeout = 900; required = $false }
        }
    }

    $run = New-PkgsRunDir
    $results = @{}
    $processes = @()
    try {
        foreach ($job in $jobs) {
            $safe = ($job.name -replace '[^A-Za-z0-9._-]', '_')
            $out = Join-Path $run ($safe + '.out')
            $err = Join-Path $run ($safe + '.err')
            $p = $null
            try {
                $p = Start-PkgsProcess -FilePath $job.file -ArgumentList $job.args -OutFile $out -ErrFile $err -Environment $job.env
            }
            catch {
                $results[$job.name] = [pscustomobject]@{ ok = $false; exit = -1; out = ''; err = [string]$_.Exception.Message }
                continue
            }
            $processes += [pscustomobject]@{ job = $job; process = $p; out = $out; err = $err }
        }

        foreach ($item in $processes) {
            $ok = Wait-PkgsProcess -Process $item.process -TimeoutSeconds $item.job.timeout
            $exitCode = if ($ok) { $item.process.ExitCode } else { -1 }
            try { $item.process.Dispose() } catch { }
            $results[$item.job.name] = [pscustomobject]@{
                ok   = ($ok -and $exitCode -eq 0)
                exit = $exitCode
                out  = (Read-PkgsTextFile -Path $item.out)
                err  = (Read-PkgsTextFile -Path $item.err)
            }
        }
    }
    finally {
        Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction Ignore
        Clear-PkgsRunCache
    }

    $errors = @()
    $anomalies = @()
    $records = [ordered]@{}

    $installedResult = $results['installed']
    if (-not $installedResult -or -not $installedResult.ok) {
        $detail = if ($installedResult) { ($installedResult.err -split "`r?`n" | Select-Object -First 2) -join ' ' } else { 'not started' }
        Stop-Pkgs -Code 5 -Message "could not read the installed inventory from mpm: $detail"
    }

    $installedData = ConvertFrom-MpmInventoryJson -Text $installedResult.out -Kind 'installed'
    $errors += @($installedData.errors)

    $outdatedData = $null
    $outdatedResult = $results['outdated']
    $outdatedOk = $false
    if ($outdatedResult -and $outdatedResult.ok) {
        $outdatedData = ConvertFrom-MpmInventoryJson -Text $outdatedResult.out -Kind 'outdated'
        $errors += @($outdatedData.errors)
        $outdatedOk = $true
    }
    elseif ($outdatedResult) {
        $detail = ($outdatedResult.err -split "`r?`n" | Select-Object -First 2) -join ' '
        $errors += [pscustomobject]@{ manager = '*'; scope = 'outdated'; message = "mpm outdated failed: $detail" }
    }

    foreach ($managerId in $installedData.managers.Keys) {
        $block = $installedData.managers[$managerId]
        foreach ($pkg in $block.packages) {
            $id = [string](Get-PkgsProperty -Object $pkg -Name 'id')
            if (-not $id) { continue }
            $key = $managerId.ToLowerInvariant() + '|' + $id.ToLowerInvariant()
            $installedVersion = [string](Get-PkgsProperty -Object $pkg -Name 'installed_version')
            $name = [string](Get-PkgsProperty -Object $pkg -Name 'name')
            if ($records.Contains($key)) {
                $records[$key].instances++
                if (-not ($records[$key].notes -contains 'duplicate rows in backend output')) {
                    $records[$key].notes += 'duplicate rows in backend output'
                }
                continue
            }
            $broken = $false
            if ([string]::IsNullOrWhiteSpace($installedVersion) -and $managerId -notin 'micro','rustup') { $broken = $true }
            $initialNotes = @()
            if ($managerId -eq 'scoop' -and ($installedVersion -match '^\d{4}-\d{2}-\d{2}' -or $installedVersion -eq 'Install')) {
                # mpm's scoop parser can read the "Updated" date of a failed
                # install as the version. The app is incomplete either way.
                $broken = $true
                $installedVersion = ''
                $initialNotes += 'scoop reports an incomplete/failed install'
            }
            if ($managerId -eq 'rustup' -and -not $installedVersion) {
                $broken = $false
                $initialNotes += 'rustup does not report an installed version for this toolchain'
            }
            if ($managerId -eq 'micro' -and -not $installedVersion) {
                $broken = $false
                $initialNotes += 'micro does not report plugin versions'
            }
            $managerCap = Get-PkgsCapability -Manager $managerId
            $updateKnown = ($outdatedOk -and $managerCap.outdated -eq $true)
            $updateMethod = if ($managerCap.outdated -eq $true) { 'backend outdated listing' }
                            elseif ($managerCap.outdated -is [string] -and $managerCap.outdated -eq 'on-demand') { 'on-demand outdated check' }
                            else { 'none' }
            $records[$key] = [pscustomobject]@{
                manager           = $managerId
                id                = $id
                name              = if ($name) { $name } else { $id }
                installed_version = $installedVersion
                version_known     = (Test-PkgsPlausibleVersion $installedVersion)
                latest_version    = ''
                outdated          = $false
                update_known      = $updateKnown
                update_method     = $updateMethod
                broken            = $broken
                source            = $managerId
                implicit          = $false
                installers        = @()
                instances         = 1
                notes             = $initialNotes
            }
        }
    }

    if ($outdatedData) {
        foreach ($managerId in $outdatedData.managers.Keys) {
            $block = $outdatedData.managers[$managerId]
            foreach ($pkg in $block.packages) {
                $id = [string](Get-PkgsProperty -Object $pkg -Name 'id')
                if (-not $id) { continue }
                $installedVersion = [string](Get-PkgsProperty -Object $pkg -Name 'installed_version')
                $latestVersion = [string](Get-PkgsProperty -Object $pkg -Name 'latest_version')
                $name = [string](Get-PkgsProperty -Object $pkg -Name 'name')
                $key = $managerId.ToLowerInvariant() + '|' + $id.ToLowerInvariant()

                if (-not (Test-PkgsPlausibleVersion $installedVersion) -or -not (Test-PkgsPlausibleVersion $latestVersion)) {
                    $anomalies += [pscustomobject]@{ manager = $managerId; kind = 'version'; message = "ignored malformed outdated entry for $id ('$installedVersion' -> '$latestVersion')" }
                    continue
                }

                $managerCap = Get-PkgsCapability -Manager $managerId
                if ($managerCap.outdated -ne $true) {
                    $anomalies += [pscustomobject]@{ manager = $managerId; kind = 'capability'; message = "ignored outdated entry for $id from a manager without outdated support" }
                    continue
                }
                if (-not $records.Contains($key)) {
                    $records[$key] = [pscustomobject]@{
                        manager           = $managerId
                        id                = $id
                        name              = if ($name) { $name } else { $id }
                        installed_version = $installedVersion
                        version_known     = (Test-PkgsPlausibleVersion $installedVersion)
                        latest_version    = ''
                        outdated          = $false
                        update_known      = $true
                        update_method     = 'backend outdated listing'
                        broken            = $false
                        source            = $managerId
                        implicit          = $false
                        installers        = @()
                        instances         = 1
                        notes             = @()
                    }
                }
                $records[$key].latest_version = $latestVersion
                $records[$key].outdated = $true
                $records[$key].update_known = $true
            }
        }
    }

    $msstoreInstalled = $results['msstore-installed']
    $msstoreOutdated = $results['msstore-outdated']
    if ($msstoreInstalled) {
        if (-not $msstoreInstalled.ok) {
            $errors += [pscustomobject]@{ manager = 'msstore'; scope = 'installed'; message = 'winget Store list failed' }
        }
        Add-PkgsWingetStorePackages -Records $records `
            -InstalledText $msstoreInstalled.out `
            -UpgradeText $(if ($msstoreOutdated) { $msstoreOutdated.out } else { '' }) `
            -UpgradeOk ([bool]($msstoreOutdated -and $msstoreOutdated.ok)) `
            -Anomalies ([ref]$anomalies) -Errors ([ref]$errors)
    }

    $pipChecked = $false
    foreach ($interpreter in $pipInterpreters) {
        $inst = $results['pip-installed:' + $interpreter.id]
        $outd = $results['pip-outdated:' + $interpreter.id]
        $outdatedOkForPip = [bool]($outd -and $outd.ok)
        if ($outd) { $pipChecked = $true }
        Add-PkgsPipPackages -Records $records -Interpreter $interpreter `
            -InstalledText $(if ($inst) { $inst.out } else { '' }) `
            -OutdatedText $(if ($outd) { $outd.out } else { '' }) `
            -OutdatedOk $outdatedOkForPip `
            -OutdatedChecked ([bool]$outd) `
            -Anomalies ([ref]$anomalies) -Errors ([ref]$errors)
        if ($inst -and -not $inst.ok) {
            $errors += [pscustomobject]@{ manager = $interpreter.id; scope = 'installed'; message = 'pip list failed' }
        }
    }

    $nativePins = @()
    $nativePinErrors = @()
    if ($results['winget-pins'] -and $results['winget-pins'].ok) {
        try {
            $nativePins += @(ConvertFrom-WingetPinList -Text $results['winget-pins'].out)
        }
        catch {
            $pinError = [pscustomobject]@{ manager = 'winget'; id = ''; scope = 'pins'; message = $_.Exception.Message }
            $errors += $pinError
            $nativePinErrors += $pinError
        }
    }
    elseif ($results['winget-pins']) {
        $pinError = [pscustomobject]@{ manager = 'winget'; scope = 'pins'; message = 'could not read winget pin list' }
        $errors += $pinError
        $nativePinErrors += $pinError
    }
    if ($results['choco-pins'] -and $results['choco-pins'].ok) {
        $nativePins += @(ConvertFrom-ChocoPinList -Text $results['choco-pins'].out)
    }
    elseif ($results['choco-pins']) {
        $pinError = [pscustomobject]@{ manager = 'choco'; scope = 'pins'; message = 'could not read choco pin list' }
        $errors += $pinError
        $nativePinErrors += $pinError
    }

    $scoopRoots = @()
    if ($scoop) { $scoopRoots = @(Get-PkgsScoopRoots) }
    $scoopHoldReport = Get-PkgsScoopHoldReport -Roots $scoopRoots
    $nativePins += @($scoopHoldReport.pins)
    $nativePinErrors += @($scoopHoldReport.errors)
    foreach ($pinError in @($scoopHoldReport.errors)) {
        $errors += [pscustomobject]@{ manager = 'scoop'; id = $pinError.id; scope = 'pins'; message = $pinError.message }
    }

    # ---- managers -----------------------------------------------------
    $managerMap = [ordered]@{}
    $managersResult = $results['managers']
    if ($managersResult -and $managersResult.ok) {
        foreach ($m in (ConvertFrom-MpmManagersText -Text $managersResult.out)) {
            $managerMap[$m.id] = [pscustomobject]@{
                id            = $m.id
                name          = $m.name
                version       = $m.version
                cli           = $m.cli
                detected      = $m.detected
                source        = 'mpm'
                excluded      = $false
                excludeReason = ''
                capabilities  = Get-PkgsCapability -Manager $m.id
                errors        = @()
                anomalies     = @()
            }
        }
    }
    $allManagerIds = @($installedData.managers.Keys)
    if ($outdatedData) { $allManagerIds += @($outdatedData.managers.Keys) }
    foreach ($managerId in $allManagerIds) {
        if ($managerMap.Contains($managerId)) { continue }
        $name = $managerId
        if ($installedData.managers.ContainsKey($managerId)) { $name = $installedData.managers[$managerId].name }
        elseif ($outdatedData -and $outdatedData.managers.ContainsKey($managerId)) { $name = $outdatedData.managers[$managerId].name }
        $managerMap[$managerId] = [pscustomobject]@{
            id            = $managerId
            name          = $name
            version       = ''
            cli           = ''
            detected      = $true
            source        = 'mpm'
            excluded      = $false
            excludeReason = ''
            capabilities  = Get-PkgsCapability -Manager $managerId
            errors        = @()
            anomalies     = @()
        }
    }

    if ($winget) {
        $msName = 'Microsoft Store (winget)'
        $managerMap['msstore'] = [pscustomobject]@{
            id            = 'msstore'
            name          = $msName
            version       = ''
            cli           = $winget
            detected      = $true
            source        = 'winget-direct'
            excluded      = $false
            excludeReason = ''
            capabilities  = Get-PkgsCapability -Manager 'msstore'
            errors        = @()
            anomalies     = @()
        }
    }

    foreach ($interpreter in $pipInterpreters) {
        $managerMap[$interpreter.id] = [pscustomobject]@{
            id            = $interpreter.id
            name          = [string]$interpreter.label
            version       = [string](Get-PkgsProperty -Object $interpreter -Name 'version' -Default '')
            cli           = [string]$interpreter.python
            detected      = $true
            source        = 'pip'
            excluded      = $false
            excludeReason = ''
            capabilities  = Get-PkgsCapability -Manager $interpreter.id
            errors        = @()
            anomalies     = @()
        }
    }

    # mpm's uv manager is environment-relative: excluded from all inventory.
    $uvEntry = if ($managerMap.Contains('uv')) { $managerMap['uv'] } else { $null }
    if (-not $uvEntry) {
        $uvEntry = [pscustomobject]@{
            id = 'uv'; name = 'Python uv (environment-relative)'; version = ''; cli = ''
            detected = [bool](Get-PkgsTool -Name 'uv'); source = 'mpm'
            excluded = $false; excludeReason = ''; capabilities = $null; errors = @(); anomalies = @()
        }
    }
    $uvEntry.excluded = $true
    $uvEntry.excludeReason = "mpm's uv manager targets whatever environment uv resolves in the current directory; project-local environments are never scanned"
    $uvEntry.capabilities = Get-PkgsCapability -Manager 'uv'
    $uvEntry.source = 'excluded'
    $managerMap['uv'] = $uvEntry

    # mpm's pip manager is replaced by explicit interpreters.
    $mpmPip = if ($managerMap.Contains('pip')) { $managerMap['pip'] } else { $null }
    if ($mpmPip) {
        $mpmPip.excluded = $true
        $mpmPip.excludeReason = 'mpm frozen binary resolves pip to its own bootstrap Python; replaced by explicit global interpreters'
        $mpmPip.source = 'excluded'
        $mpmPip.capabilities = Get-PkgsCapability -Manager 'pip'
    }

    $packages = @($records.Values)
    foreach ($mgr in $managerMap.Values) {
        $mgrPackages = @($packages | Where-Object { $_.manager -eq $mgr.id })
        $mgr | Add-Member -NotePropertyName package_count -NotePropertyValue $mgrPackages.Count -Force
        $mgr | Add-Member -NotePropertyName outdated_count -NotePropertyValue @($mgrPackages | Where-Object { $_.outdated }).Count -Force
        $outdatedKnown = ($mgr.capabilities.outdated -eq $true)
        if ($mgr.id -like 'pip*') { $outdatedKnown = $pipChecked }
        $mgr | Add-Member -NotePropertyName outdated_known -NotePropertyValue $outdatedKnown -Force
        $mgr.errors = @($errors | Where-Object { $_.manager -eq $mgr.id } | ForEach-Object { $_.message })
        $mgr.anomalies = @($anomalies | Where-Object { $_.manager -eq $mgr.id } | ForEach-Object { $_.message })
    }

    $sw.Stop()
    $snapshot = [pscustomobject]@{
        schema                = $script:PkgsSnapshotSchema
        generated             = (Get-Date).ToUniversalTime().ToString('o')
        elapsed_ms            = $sw.ElapsedMilliseconds
        mpm_version           = $mpmVersion
        mpm_path              = $mpm
        managers              = @($managerMap.Values)
        packages              = $packages
        native_pins           = @($nativePins)
        native_pin_errors     = @($nativePinErrors)
        errors                = @($errors)
        anomalies             = @($anomalies)
        pip_outdated_checked  = $pipChecked
    }
    return $snapshot
}

function Save-PkgsSnapshot {
    param([Parameter(Mandatory)]$Snapshot)
    Initialize-PkgsPaths
    $path = Get-PkgsSnapshotPath
    $dir = Split-Path -Parent $path
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }
    $json = $Snapshot | ConvertTo-Json -Depth 12
    $tmp = "$path.$PID.tmp"
    [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Clear-PkgsSnapshot {
    $path = Get-PkgsSnapshotPath
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force -ErrorAction Ignore }
}

function Get-PkgsSnapshot {
    [CmdletBinding()]
    param(
        [switch]$Refresh,
        [switch]$IncludePipOutdated,
        [int]$MaxAgeSeconds = -1
    )

    $cfg = Get-PkgsConfig
    if ($MaxAgeSeconds -lt 0) { $MaxAgeSeconds = [int]$cfg.cacheTtlSeconds }
    $path = Get-PkgsSnapshotPath

    if (-not $Refresh -and (Test-Path -LiteralPath $path)) {
        $cached = $null
        try {
            $cached = Get-Content -LiteralPath $path -Raw -Encoding utf8 | ConvertFrom-Json -ErrorAction Stop
        }
        catch {
            Write-PkgsWarn "ignoring unreadable snapshot cache: $($_.Exception.Message)"
            $cached = $null
        }
        if ($cached -and $cached.schema -eq $script:PkgsSnapshotSchema) {
            $age = Get-PkgsAgeSeconds -Timestamp $cached.generated
            $pipOk = (-not $IncludePipOutdated) -or [bool]$cached.pip_outdated_checked
            if ($MaxAgeSeconds -gt 0 -and $age -le $MaxAgeSeconds -and $pipOk) {
                $cached | Add-Member -NotePropertyName cache_age_seconds -NotePropertyValue ([int]$age) -Force
                $cached | Add-Member -NotePropertyName from_cache -NotePropertyValue $true -Force
                return $cached
            }
        }
    }

    Write-PkgsDim 'Reading package managers (mpm)...'
    $snapshot = Build-PkgsSnapshot -IncludePipOutdated:$IncludePipOutdated
    Save-PkgsSnapshot -Snapshot $snapshot
    $snapshot | Add-Member -NotePropertyName cache_age_seconds -NotePropertyValue 0 -Force
    $snapshot | Add-Member -NotePropertyName from_cache -NotePropertyValue $false -Force
    Clear-PkgsPreviewCache
    return $snapshot
}
