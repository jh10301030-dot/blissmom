@echo off
cd /d "%~dp0"
set "PS1FILE="
for %%f in ("%~dp0backfill*follower*history*.ps1") do set "PS1FILE=%%f"
if not defined PS1FILE (
    echo Could not find backfill-follower-history.ps1 in this folder.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1FILE%"
pause
