@echo off
REM Clear a session stuck on the ClydeCube status light.
REM
REM   clear-light.cmd             report what is on the panel, change nothing
REM   clear-light.cmd all         clear every slot and every stale ghost, repaint
REM   clear-light.cmd 648a8e13    clear one session by id prefix
REM
REM Safe to run any time: a session that is genuinely alive re-earns its block on
REM its next hook, so the worst case is a block missing for a few seconds.
setlocal
if /i "%~1"=="all" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clear-light.ps1" -All
) else if "%~1"=="" (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clear-light.ps1"
) else (
  powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0clear-light.ps1" -Session "%~1"
)
pause
