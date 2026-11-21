# =====================================================================
#  pkgs-core.ps1 - paths, configuration, tool discovery, process I/O
#  Loaded lazily by pkgs.ps1. No side effects at load time.
# =====================================================================

$script:PkgsVersion        = '1.2.3'
$script:PkgsSchema         = 'pkgs/v1'
$script:PkgsSnapshotSchema = 'pkgs/snapshot/v2'

# ---------------------------------------------------------------------
#  Paths
# ---------------------------------------------------------------------
function Initialize-PkgsPaths {
    [CmdletBinding()]
    param()

    if (-not $script:PkgsConfigPath) {
        if ($env:PKGS_CONFIG) {
            $script:PkgsConfigPath = [IO.Path]::GetFullPath($env:PKGS_CONFIG)
        }
        else {
            $script:PkgsConfigPath = Join-Path $HOME '.config\pkgs\config.json'
        }
    }

    if (-not $script:PkgsCacheDir) {
        if ($env:PKGS_CACHE_DIR) {
            $script:PkgsCacheDir = [IO.Path]::GetFullPath($env:PKGS_CACHE_DIR)
        }
        else {
            $local = [Environment]::GetFolderPath('LocalApplicationData')
            $script:PkgsCacheDir = Join-Path $local 'pkgs\cache'
        }
    }

    if (-not $script:PkgsStateDir) {
        $script:PkgsStateDir = Split-Path -Parent $script:PkgsCacheDir
    }
}

function Get-PkgsConfigPath { Initialize-PkgsPaths; return $script:PkgsConfigPath }
function Get-PkgsCachePath  { Initialize-PkgsPaths; return $script:PkgsCacheDir }
function Get-PkgsSnapshotPath { return (Join-Path (Get-PkgsCachePath) 'snapshot.json') }

function Clear-PkgsRunCache {
    Initialize-PkgsPaths
    $root = Join-Path (Get-PkgsCachePath) 'run'
    if (-not (Test-Path -LiteralPath $root)) { return }
    $cutoff = (Get-Date).ToUniversalTime().AddHours(-1)
    foreach ($dir in (Get-ChildItem -LiteralPath $root -Directory -ErrorAction Ignore)) {
        if ($dir.LastWriteTimeUtc -lt $cutoff) {
            Remove-Item -LiteralPath $dir.FullName -Recurse -Force -ErrorAction Ignore
        }
    }
    $remaining = @(Get-ChildItem -LiteralPath $root -Force -ErrorAction Ignore)
    if ($remaining.Count -eq 0) { Remove-Item -LiteralPath $root -Force -ErrorAction Ignore }
}

function New-PkgsRunDir {
    Initialize-PkgsPaths
    $root = Join-Path (Get-PkgsCachePath) 'run'
    $null = New-Item -ItemType Directory -Path $root -Force -ErrorAction Ignore
    $dir = Join-Path $root ([guid]::NewGuid().ToString('N').Substring(0, 10))
    $null = New-Item -ItemType Directory -Path $dir -Force -ErrorAction Stop
    return $dir
}

# ---------------------------------------------------------------------
#  Output helpers
# ---------------------------------------------------------------------
function Write-PkgsInfo {
    param([string]$Text = '')
    if ($script:PkgsJsonRequested) { [Console]::Error.WriteLine($Text); return }
    Write-Host $Text
}

function Write-PkgsDim {
    param([string]$Text = '')
    if ($script:PkgsJsonRequested) { [Console]::Error.WriteLine($Text); return }
    Write-Host $Text -ForegroundColor DarkGray
}

function Write-PkgsOk {
    param([string]$Text)
    if ($script:PkgsJsonRequested) { [Console]::Error.WriteLine($Text); return }
    Write-Host $Text -ForegroundColor Green
}

function Write-PkgsWarn {
    param([string]$Text)
    if ($script:PkgsJsonRequested) { [Console]::Error.WriteLine("pkgs: $Text"); return }
    Write-Host "pkgs: $Text" -ForegroundColor DarkYellow
}

function Write-PkgsError {
    param([string]$Text)
    if ($script:PkgsJsonRequested) { [Console]::Error.WriteLine("pkgs: $Text"); return }
    Write-Host "pkgs: $Text" -ForegroundColor Red
}

function Get-PkgsAgeSeconds {
    param($Timestamp)
    if ($null -eq $Timestamp) { return [int]::MaxValue }
    if ($Timestamp -is [datetime]) {
        return [int]((Get-Date).ToUniversalTime() - $Timestamp.ToUniversalTime()).TotalSeconds
    }
    try {
        $parsed = [datetime]::Parse([string]$Timestamp, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::RoundtripKind)
        return [int]((Get-Date).ToUniversalTime() - $parsed.ToUniversalTime()).TotalSeconds
    }
    catch { return [int]::MaxValue }
}

function Stop-Pkgs {
    <#
        Terminates the current pkgs invocation with an exit code.
        Shell mode (profile function) sets $global:LASTEXITCODE instead of
        closing the interactive session.
    #>
    param(
        [Parameter(Mandatory)][int]$Code,
        [string]$Message = ''
    )
    $clean = ($Message -replace "`r?`n", ' ').Trim()
    throw "PKGS_EXIT:${Code}:$clean"
}

# ---------------------------------------------------------------------
#  Tool discovery (test mode may redirect executables)
# ---------------------------------------------------------------------
function Get-PkgsTestOverride {
    param([string]$Name)
    if ($env:PKGS_TEST_MODE -ne '1') { return $null }
    $value = [Environment]::GetEnvironmentVariable($Name)
    if ($value) { return $value }
    return $null
}

function Get-PkgsTool {
    param(
        [Parameter(Mandatory)][string]$Name,
        [string]$TestOverride
    )

    if ($TestOverride) {
        $value = Get-PkgsTestOverride -Name $TestOverride
        if ($value) {
            if (Test-Path -LiteralPath $value) { return (Get-Item -LiteralPath $value).FullName }
            return $value
        }
    }

    $cmd = Get-Command -Name $Name -CommandType Application, ExternalScript -ErrorAction Ignore |
           Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Get-PkgsMpmPath {
    if (-not $script:PkgsMpmPath) {
        $script:PkgsMpmPath = Get-PkgsTool -Name 'mpm' -TestOverride 'PKGS_TEST_MPM'
    }
    return $script:PkgsMpmPath
}

function Get-PkgsMpmVersion {
    if ($script:PkgsMpmVersion) { return $script:PkgsMpmVersion }
    $mpm = Get-PkgsMpmPath
    if (-not $mpm) { return $null }
    try {
        $run = Invoke-PkgsNative -FilePath $mpm -ArgumentList @('--version') -TimeoutSeconds 30
        # A real mpm banner can prepend artwork and ANSI color codes.
        # Require one unambiguous numeric version from a successful probe.
        $text = [regex]::Replace([string]$run.Stdout, ([string][char]27 + '\[[0-?]*[ -/]*[@-~]'), '')
        # Match a complete version field, not a prefix of a prerelease or build suffix.
        # Also reject a banner containing more than one mpm version label.
        $labels = [regex]::Matches($text, '(?m)(?<!\S)mpm,[ \t]+version(?=[ \t]|$)')
        $versionMatches = [regex]::Matches($text, '(?m)(?<!\S)mpm,[ \t]+version[ \t]+(?<version>\d+\.\d+\.\d+(?:\.\d+)?)[ \t]*\r?$')
        if ($run.ExitCode -eq 0 -and $labels.Count -eq 1 -and $versionMatches.Count -eq 1) {
            $script:PkgsMpmVersion = $versionMatches[0].Groups['version'].Value
        }
        else {
            $script:PkgsMpmVersion = 'unknown'
        }
    }
    catch {
        $script:PkgsMpmVersion = 'unknown'
    }
    return $script:PkgsMpmVersion
}

function Assert-PkgsMpm {
    $mpm = Get-PkgsMpmPath
    if (-not $mpm) {
        Stop-Pkgs -Code 5 -Message "Meta Package Manager (mpm) not found. Install it with: scoop install main/meta-package-manager"
    }
    $version = Get-PkgsMpmVersion
    if (-not $version -or $version -notmatch '^\d+\.\d+\.\d+(?:\.\d+)?$') {
        Stop-Pkgs -Code 5 -Message "mpm version could not be verified; pkgs requires mpm 8.3.0 or newer"
    }
    $parsed = [version]$version
    if ($parsed -lt [version]'8.3.0') {
        Stop-Pkgs -Code 5 -Message "mpm $version is too old; pkgs requires mpm 8.3.0 or newer (scoop update meta-package-manager)"
    }
    return $mpm
}

# ---------------------------------------------------------------------
#  Native process capture
# ---------------------------------------------------------------------
function Read-PkgsTextFile {
    <#
        Read a redirected output file only after its writer has closed it.
        Start-Process keeps the redirection handle open until the Process
        object is disposed, and a plain ReadAllBytes can race with the final
        flush. An exclusive open is the synchronization point.
    #>
    param([string]$Path, [int]$TimeoutMs = 250)

    if (-not $Path) { return '' }
    $deadline = [DateTime]::UtcNow.AddMilliseconds($TimeoutMs)
    while ($true) {
        if (Test-Path -LiteralPath $Path) {
            $stream = $null
            try {
                $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                $memory = New-Object System.IO.MemoryStream
                try {
                    $stream.CopyTo($memory)
                    $bytes = $memory.ToArray()
                }
                finally {
                    $memory.Dispose()
                    $stream.Dispose()
                }

                if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFF -and $bytes[1] -eq 0xFE) {
                    return [Text.Encoding]::Unicode.GetString($bytes, 2, $bytes.Length - 2)
                }
                if ($bytes.Length -ge 2 -and $bytes[0] -eq 0xFE -and $bytes[1] -eq 0xFF) {
                    return [Text.Encoding]::BigEndianUnicode.GetString($bytes, 2, $bytes.Length - 2)
                }
                $offset = 0
                if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) { $offset = 3 }
                return [Text.Encoding]::UTF8.GetString($bytes, $offset, $bytes.Length - $offset)
            }
            catch {
                if ($stream) { try { $stream.Dispose() } catch { } }
            }
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            # The writer kept its handle longer than expected. Fall back to a
            # shared read; a short wait has already given it time to flush.
            Start-Sleep -Milliseconds 25
            try { return [IO.File]::ReadAllText($Path, [Text.Encoding]::UTF8) } catch { return '' }
        }
        Start-Sleep -Milliseconds 25
    }
}
function Start-PkgsProcess {
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][string]$ErrFile,
        [hashtable]$Environment
    )

    # Test doubles and some real package managers are .ps1 files; run them
    # through the current PowerShell host so redirection still works.
    if ($FilePath -match '\.ps1$') {
        $hostExe = Join-Path $PSHOME 'pwsh.exe'
        if (-not (Test-Path -LiteralPath $hostExe)) { $hostExe = (Get-Command pwsh -ErrorAction Stop).Source }
        $ArgumentList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $FilePath) + @($ArgumentList)
        $FilePath = $hostExe
    }

    $params = @{
        FilePath               = $FilePath
        RedirectStandardOutput = $OutFile
        RedirectStandardError  = $ErrFile
        NoNewWindow            = $true
        PassThru               = $true
    }
    if ($ArgumentList -and $ArgumentList.Count -gt 0) { $params.ArgumentList = $ArgumentList }
    if ($Environment -and $Environment.Count -gt 0) { $params.Environment = $Environment }

    return Start-Process @params
}

function Wait-PkgsProcess {
    param(
        [Parameter(Mandatory)]$Process,
        [int]$TimeoutSeconds = 600
    )
    if ($Process.HasExited) { return $true }
    $ok = $Process.WaitForExit($TimeoutSeconds * 1000)
    if (-not $ok) {
        try { $Process.Kill($true) } catch { }
        try { $null = $Process.WaitForExit(5000) } catch { }
    }
    return $ok
}

function Invoke-PkgsNative {
    <#
        Run one native command, capture stdout/stderr, return an object.
        Throws a PKGS_EXIT:5 sentinel on timeout or start failure.
    #>
    param(
        [Parameter(Mandatory)][string]$FilePath,
        [string[]]$ArgumentList = @(),
        [hashtable]$Environment,
        [int]$TimeoutSeconds = 300
    )

    $run = New-PkgsRunDir
    $out = Join-Path $run 'stdout.txt'
    $err = Join-Path $run 'stderr.txt'
    try {
        try {
            $p = Start-PkgsProcess -FilePath $FilePath -ArgumentList $ArgumentList -OutFile $out -ErrFile $err -Environment $Environment
        }
        catch {
            Stop-Pkgs -Code 5 -Message "failed to start '$FilePath': $($_.Exception.Message)"
        }
        $ok = Wait-PkgsProcess -Process $p -TimeoutSeconds $TimeoutSeconds
        if (-not $ok) {
            try { $p.Dispose() } catch { }
            Stop-Pkgs -Code 5 -Message "'$([IO.Path]::GetFileName($FilePath))' timed out after ${TimeoutSeconds}s"
        }
        $exitCode = $p.ExitCode
        # Dispose before reading: Start-Process keeps its redirection handles
        # open until the Process object is disposed, and an early read can
        # observe an empty or partially flushed file.
        try { $p.Dispose() } catch { }
        return [pscustomobject]@{
            ExitCode = $exitCode
            Stdout   = (Read-PkgsTextFile -Path $out)
            Stderr   = (Read-PkgsTextFile -Path $err)
        }
    }
    finally {
        Remove-Item -LiteralPath $run -Recurse -Force -ErrorAction Ignore
        Clear-PkgsRunCache
    }
}

# ---------------------------------------------------------------------
#  Configuration
# ---------------------------------------------------------------------
function Get-PkgsDefaultGuard {
    return @(
        [pscustomobject]@{
            manager = 'winget'
            pattern = '^(Google\.PlatformTools|GoLang\.Go|LLVM\.LLVM|Rustlang\.Rustup|OpenJS\.NodeJS|Python\.Python\.\d+\.\d+|Python\.Launcher|EclipseAdoptium\..+|Microsoft\.DotNet\.SDK\.\d+|Microsoft\.VisualStudio\.\d{4}\.BuildTools|Anaconda\.Miniconda3|CondaForge\.Miniforge3)$'
            reason  = 'development toolchain'
        }
        [pscustomobject]@{
            manager = 'scoop'
            pattern = '^(corretto\d+-jdk|flutter|gcc|nodejs\d*|python\d*|rustup)$'
            reason  = 'development toolchain'
        }
        [pscustomobject]@{
            manager = 'rustup'
            pattern = '.*'
            reason  = 'Rust toolchain'
        }
    )
}

function Find-PkgsPythonInterpreters {
    <#
        Identified global Python environments only. Virtualenvs, conda envs
        below an envs\ directory, and the current directory are never scanned.
    #>
    $found = [ordered]@{}

    $candidates = New-Object System.Collections.Generic.List[string]
    foreach ($name in 'python', 'python3') {
        foreach ($cmd in (Get-Command -Name $name -CommandType Application -All -ErrorAction Ignore)) {
            if ($cmd.Source -and $cmd.Source -notmatch '\\WindowsApps\\python') {
                $candidates.Add($cmd.Source)
            }
        }
    }
    $roots = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\Python'),
        'C:\Python312', 'C:\Python311'
    )
    foreach ($root in $roots) {
        if (-not (Test-Path -LiteralPath $root)) { continue }
        Get-ChildItem -LiteralPath $root -Directory -Filter 'Python*' -ErrorAction Ignore |
            ForEach-Object {
                $exe = Join-Path $_.FullName 'python.exe'
                if (Test-Path -LiteralPath $exe) { $candidates.Add($exe) }
            }
    }
    foreach ($conda in @((Join-Path $HOME 'miniconda3\python.exe'), (Join-Path $HOME 'anaconda3\python.exe'), 'C:\ProgramData\miniconda3\python.exe')) {
        if (Test-Path -LiteralPath $conda) { $candidates.Add($conda) }
    }

    foreach ($path in $candidates) {
        try { $full = (Get-Item -LiteralPath $path -ErrorAction Stop).FullName } catch { continue }
        if ($full -match '(?i)[\\/](\.venv|venv|envs|site-packages|conda-meta)[\\/]') { continue }
        $key = $full.ToLowerInvariant()
        if ($found.Contains($key)) { continue }

        $label = $null
        try {
            $run = Invoke-PkgsNative -FilePath $full -ArgumentList @('--version') -TimeoutSeconds 20
            $text = (($run.Stdout + "`n" + $run.Stderr) -replace "`r", '')
            if ($text -match 'Python\s+(?<v>\d+\.\d+\.\d+)') { $label = $Matches.v }
        }
        catch { }
        if (-not $label) { continue }

        $short = $label -replace '^(\d+\.\d+)\..*$', '$1'
        $id = 'pip' + ($short -replace '\.', '')
        if ($full -match '(?i)miniconda|anaconda') { $id = 'pip-conda' }
        if (-not $found.Contains($id.ToLowerInvariant())) {
            $found[$id.ToLowerInvariant()] = [pscustomobject]@{
                id      = $id
                label   = "Python $label (global)"
                python  = $full
                version = $label
                enabled = $true
            }
        }
    }

    return @($found.Values)
}

function New-PkgsDefaultConfig {
    [CmdletBinding()]
    param([switch]$DetectPip)

    $interpreters = @()
    if ($DetectPip) {
        try { $interpreters = Find-PkgsPythonInterpreters } catch { $interpreters = @() }
    }

    return [pscustomobject]@{
        version    = 1
        cacheTtlSeconds = 600
        managers   = [pscustomobject]@{
            uv  = 'excluded'   # mpm's uv manager targets the environment uv resolves (project-local)
            pip = 'adapter'    # mpm's frozen binary resolves pip to its own bootstrap Python
        }
        pip        = [pscustomobject]@{
            interpreters = $interpreters
        }
        guard      = @(Get-PkgsDefaultGuard)
        guardExceptions = @()
        ignored    = @()
        ui         = [pscustomobject]@{
            height  = '85%'
            preview = $true
        }
    }
}

function Get-PkgsConfig {
    [CmdletBinding()]
    param([switch]$Refresh)

    if ($script:PkgsConfig -and -not $Refresh) { return $script:PkgsConfig }
    Initialize-PkgsPaths

    if (-not (Test-Path -LiteralPath $script:PkgsConfigPath)) {
        $script:PkgsConfig = New-PkgsDefaultConfig -DetectPip
        Save-PkgsConfig -Config $script:PkgsConfig
        return $script:PkgsConfig
    }

    try {
        $raw = Get-Content -LiteralPath $script:PkgsConfigPath -Raw -Encoding utf8
        $cfg = $raw | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Stop-Pkgs -Code 1 -Message "invalid configuration at $($script:PkgsConfigPath): $($_.Exception.Message)"
    }

    $defaults = New-PkgsDefaultConfig
    foreach ($name in 'version', 'cacheTtlSeconds', 'managers', 'pip', 'guard', 'guardExceptions', 'ignored', 'ui') {
        if (-not ($cfg.PSObject.Properties.Name -contains $name)) {
            $cfg | Add-Member -NotePropertyName $name -NotePropertyValue $defaults.$name
        }
    }
    if ($null -eq $cfg.pip) { $cfg.pip = $defaults.pip }
    if (-not ($cfg.pip.PSObject.Properties.Name -contains 'interpreters')) {
        $cfg.pip | Add-Member -NotePropertyName interpreters -NotePropertyValue @()
    }
    if ($null -eq $cfg.guard) { $cfg.guard = @() }
    if ($null -eq $cfg.guardExceptions) { $cfg.guardExceptions = @() }
    if ($null -eq $cfg.ignored) { $cfg.ignored = @() }

    # Force array semantics after a single-element JSON array is deserialized as an object.
    $cfg.guard = @($cfg.guard)
    $cfg.guardExceptions = @($cfg.guardExceptions)
    $cfg.ignored = @($cfg.ignored)
    $cfg.pip.interpreters = @($cfg.pip.interpreters)

    $script:PkgsConfig = $cfg
    return $script:PkgsConfig
}

function Save-PkgsConfig {
    param([Parameter(Mandatory)]$Config)

    Initialize-PkgsPaths
    $dir = Split-Path -Parent $script:PkgsConfigPath
    if (-not (Test-Path -LiteralPath $dir)) { $null = New-Item -ItemType Directory -Path $dir -Force }

    $json = $Config | ConvertTo-Json -Depth 12
    $tmp = "$($script:PkgsConfigPath).$PID.tmp"
    [IO.File]::WriteAllText($tmp, $json + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $script:PkgsConfigPath -Force
    $script:PkgsConfig = $Config
}

function Initialize-PkgsConfigFile {
    Initialize-PkgsPaths
    if (-not (Test-Path -LiteralPath $script:PkgsConfigPath)) {
        $cfg = Get-PkgsConfig
        Save-PkgsConfig -Config $cfg
    }
}

# ---------------------------------------------------------------------
#  Small utilities
# ---------------------------------------------------------------------
function Test-PkgsPlausibleVersion {
    param([string]$Version)
    if ([string]::IsNullOrWhiteSpace($Version)) { return $false }
    $v = $Version.Trim()
    if ($v -match '(?i)^(install|failed|unknown|n/?a|not installed)[,.]*$') { return $false }
    if ($v -match ',') { return $false }
    if ($v -notmatch '\d') { return $false }
    return $true
}

function Get-PkgsProperty {
    param($Object, [string]$Name, $Default = $null)
    if ($null -eq $Object) { return $Default }
    $prop = $Object.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $Default
}

function ConvertTo-PkgsArray {
    param($Value)
    if ($null -eq $Value) { return @() }
    return @($Value)
}
