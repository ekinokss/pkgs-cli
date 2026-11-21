@echo off
rem pkgs - standalone entry point for shells without the PowerShell profile.
rem install.ps1 writes the real absolute entry path into this file.
rem The profile also defines a lazy `pkgs` function that shadows this shim.
pwsh -NoProfile -File "__PKGS_ENTRY__" %*
exit /b %ERRORLEVEL%
