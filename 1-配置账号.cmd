@echo off
title CampusNet - Setup Account
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusNet.ps1" -Setup
echo.
pause
