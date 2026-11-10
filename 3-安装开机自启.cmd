@echo off
title CampusNet - Install AutoStart
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Install-AutoStart.ps1"
echo.
pause
