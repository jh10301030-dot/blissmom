@echo off
title 블리스맘 AI Office
cd /d "C:\Users\USER\Downloads\blissmom-claude-custom-office-shell-ui-dpuqrz\blissmom-claude-custom-office-shell-ui-dpuqrz"
start "" cmd /c "timeout /t 6 >nul && start http://localhost:3000"
npm run dev
