#Requires -Version 7.4
# Benchmarks for pkgs. Read-only: no package mutation is performed.
param(
    [switch]$SkipCold
)

$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
$pkgsRoot = Split-Path -Parent $here
$pkgs = Join-Path $pkgsRoot 'pkgs.ps1'
$cache = Join-Path $env:LOCALAPPDATA 'pkgs\cache\snapshot.json'
$pwsh = Join-Path $PSHOME 'pwsh.exe'

function Measure-Median {
    param([scriptblock]$Body, [int]$Runs = 5)
    $times = @()
    for ($i = 0; $i -lt $Runs; $i++) {
        $sw = [Diagnostics.Stopwatch]::StartNew()
        & $Body
        $sw.Stop()
        $times += $sw.ElapsedMilliseconds
    }
    $sorted = @($times | Sort-Object)
    return [pscustomobject]@{
        MedianMs = $sorted[[int][math]::Floor($sorted.Count / 2)]
        MinMs    = $sorted[0]
        MaxMs    = $sorted[-1]
        Raw      = $times
    }
}

function Invoke-PkgsCli {
    param([string[]]$Arguments, [string]$Stdout = $null, [string]$Stderr = $null)
    $params = @{
        FilePath     = $pwsh
        ArgumentList = @('-NoProfile', '-File', $pkgs) + $Arguments
        NoNewWindow  = $true
        PassThru     = $true
        Wait         = $true
    }
    if ($Stdout) { $params.RedirectStandardOutput = $Stdout }
    if ($Stderr) { $params.RedirectStandardError = $Stderr }
    $p = Start-Process @params
    $code = $p.ExitCode
    $p.Dispose()
    return $code
}

Write-Host 'pkgs benchmarks' -ForegroundColor Cyan
Write-Host "root: $pkgsRoot" -ForegroundColor DarkGray

# Fresh-process CLI parse/startup (dominated by mpm --version).
$version = Measure-Median -Runs 5 -Body { Invoke-PkgsCli -Arguments @('version') | Out-Null }
Write-Host ("version (new pwsh, includes mpm --version): {0} ms median ({1}-{2})" -f $version.MedianMs, $version.MinMs, $version.MaxMs)

# Warm read-only commands.
$warmOut = Join-Path $env:TEMP ('pkgs-bench-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
$warm = Measure-Median -Runs 5 -Body { Invoke-PkgsCli -Arguments @('outdated', '--json') -Stdout $warmOut | Out-Null }
Write-Host ("outdated --json (warm cache): {0} ms median ({1}-{2})" -f $warm.MedianMs, $warm.MinMs, $warm.MaxMs)

$managers = Measure-Median -Runs 5 -Body { Invoke-PkgsCli -Arguments @('managers', '--json') -Stdout $warmOut | Out-Null }
Write-Host ("managers --json (warm cache): {0} ms median ({1}-{2})" -f $managers.MedianMs, $managers.MinMs, $managers.MaxMs)

$installed = Measure-Median -Runs 5 -Body { Invoke-PkgsCli -Arguments @('installed', '--json', '--manager', 'scoop') -Stdout $warmOut | Out-Null }
Write-Host ("installed --manager scoop --json (warm): {0} ms median ({1}-{2})" -f $installed.MedianMs, $installed.MinMs, $installed.MaxMs)

# Live search (network + every manager).
$search = Measure-Median -Runs 2 -Body { Invoke-PkgsCli -Arguments @('search', '7zip', '--json') -Stdout $warmOut | Out-Null }
Write-Host ("search 7zip --json (live): {0} ms median ({1}-{2})" -f $search.MedianMs, $search.MinMs, $search.MaxMs)

# Cold snapshot + resource sampling.
if (-not $SkipCold) {
    Remove-Item -LiteralPath $cache -Force -ErrorAction Ignore
    $out = Join-Path $env:TEMP ('pkgs-bench-cold-' + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.json')
    $err = "$out.err"
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $pwsh -ArgumentList @('-NoProfile', '-File', $pkgs, 'outdated', '--json') `
        -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    $peakMpm = 0L
    $peakMpmCount = 0
    while (-not $p.HasExited) {
        $mpms = @(Get-Process mpm -ErrorAction Ignore)
        if ($mpms.Count -gt $peakMpmCount) { $peakMpmCount = $mpms.Count }
        foreach ($proc in $mpms) {
            if ($proc.WorkingSet64 -gt $peakMpm) { $peakMpm = $proc.WorkingSet64 }
        }
        Start-Sleep -Milliseconds 100
    }
    $sw.Stop()
    $code = $p.ExitCode
    $p.Dispose()
    $ok = $false
    try { $null = Get-Content -LiteralPath $out -Raw | ConvertFrom-Json; $ok = $true } catch { }
    Write-Host ("outdated --json (COLD cache): {0} ms, exit {1}, JSON valid {2}" -f $sw.ElapsedMilliseconds, $code, $ok)
    Write-Host ("  peak mpm working set: {0:N1} MiB; peak concurrent mpm processes: {1}" -f ($peakMpm / 1MB), $peakMpmCount)
    Remove-Item -LiteralPath $out, $err -Force -ErrorAction Ignore
}
else {
    Write-Host 'cold snapshot skipped'
}

# Profile startup (banner off), 5 runs.
$env:PWSH_NO_BANNER = '1'
$profileTimes = @()
for ($i = 0; $i -lt 5; $i++) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $p = Start-Process -FilePath $pwsh -ArgumentList @('-Command', 'exit') -NoNewWindow -PassThru -Wait
    $sw.Stop()
    $profileTimes += $sw.ElapsedMilliseconds
}
$sorted = @($profileTimes | Sort-Object)
Write-Host ("profile shell startup: {0} ms median ({1}-{2})" -f $sorted[2], $sorted[0], $sorted[-1])

# Residual processes after everything finishes.
Start-Sleep -Seconds 2
$left = @(Get-Process mpm -ErrorAction Ignore)
Write-Host ("residual mpm processes after benchmarks: {0}" -f $left.Count)

Remove-Item -LiteralPath $warmOut -Force -ErrorAction Ignore
