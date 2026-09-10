@echo off
set "REPORTDIR=%LOCALAPPDATA%\InstagramCodexConnector\reports"
if not exist "%REPORTDIR%" mkdir "%REPORTDIR%"
if exist "%REPORTDIR%\latest.md" (
    start "" notepad "%REPORTDIR%\latest.md"
) else (
    start "" explorer "%REPORTDIR%"
)
