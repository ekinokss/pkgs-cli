# Deterministic test double for fzf. Test-only.
# Reads the candidate lines, records them, and returns a deterministic
# selection according to PKGS_FAKE_FZF_MODE.

$lines = @($input)
if ($env:PKGS_FAKE_FZF_INPUT) {
    $lines | Set-Content -LiteralPath $env:PKGS_FAKE_FZF_INPUT -Encoding utf8
}

switch ($env:PKGS_FAKE_FZF_MODE) {
    'cancel' { exit 130 }
    'first' { $lines | Select-Object -First 1 }
    'last' { $lines | Select-Object -Last 1 }
    'none' { exit 1 }
    default { $lines }
}
exit 0
