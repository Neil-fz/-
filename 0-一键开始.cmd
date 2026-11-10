@echo off
title CampusNet - One Click Setup
cd /d "%~dp0"
echo.
echo ============================================
echo   HAIT Campus Network - Auto Login Setup
echo ============================================
echo.
echo Step 1/3 : account setup
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusNet.ps1" -Setup
echo.
echo Step 2/3 : test login
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusNet.ps1" -Once
if errorlevel 1 (
    echo.
    echo [!] Test failed. Read the message above, fix it, then run this file again.
    echo     Tip: run 1-Configure.cmd again if the operator or password was wrong.
) else (
    echo.
    echo Step 3/3 : install auto start
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AutoStart.ps1"
)
echo.
pause
