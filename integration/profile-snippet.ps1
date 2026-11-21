# ── pkgs: lazy PowerShell integration ──────────────────────────────────
# Append this block to $PROFILE (CurrentUserCurrentHost), or re-run
# install.ps1 -ConfigureProfile. The modules are parsed on first use only.
#
# Set PKGS_LIB_DIR first if the checkout was deployed outside
# <profile>\lib\pkgs.

$script:PkgsLibDir = if ($env:PKGS_LIB_DIR) {
    $env:PKGS_LIB_DIR
}
else {
    Join-Path $PSScriptRoot 'lib\pkgs'
}

function pkgs {
    # Lazy: the CLI and its modules are parsed on the first call only.
    if (-not $script:PkgsScript) {
        $dir = $script:PkgsLibDir
        $escaped = $dir.Replace("'", "''")
        $prelude = "`$PkgsHome = '$escaped'`n`$InShell = `$true`n"
        $script:PkgsScript = [scriptblock]::Create(
            $prelude + (Get-Content -LiteralPath (Join-Path $dir 'pkgs.ps1') -Raw))
    }
    & $script:PkgsScript @args
}
