@echo off
title CampusNet - Status
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusNet.ps1" -Status
echo.
pause
