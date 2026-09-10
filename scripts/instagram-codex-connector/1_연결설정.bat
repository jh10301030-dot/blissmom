@echo off
cd /d "%~dp0"
set "PS1FILE="
for %%f in ("%~dp0setup*instagram*insights*.ps1") do set "PS1FILE=%%f"
if not defined PS1FILE (
    echo Could not find setup-instagram-insights.ps1 in this folder.
    echo Make sure the .ps1 file is in the same folder as this .bat file.
    pause
    exit /b 1
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%PS1FILE%"
pause
