@echo off
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0collect-instagram-insights.ps1"
echo.
echo 작업이 끝났습니다. 이 창을 닫으려면 아무 키나 누르세요.
pause >nul
