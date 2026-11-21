@echo off
rem Fast, fault-tolerant preview helper for pkgs.
rem Usage: preview.cmd "<path to a precomputed detail file>"
setlocal
if "%~1"=="" (
  echo Package details are unavailable.
  exit /b 0
)
if not exist "%~1" (
  echo Package details are no longer available. Move the selection to refresh it.
  exit /b 0
)
bat --style=plain --color=always --paging=never "%~1" 2>nul
if errorlevel 1 type "%~1"
exit /b 0
