@echo off
cd /d "%~dp0"
set "PS1FILE="
for %%f in ("%~dp0make*desktop*shortcut*.ps1") do set "PS1FILE=%%f"
if not defined PS1FILE (
    echo Could not find make-desktop-shortcut.ps1 in this folder.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1FILE%"
pause
