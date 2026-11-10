@echo off
title CampusNet - Uninstall AutoStart
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Uninstall-AutoStart.ps1"
echo.
pause
