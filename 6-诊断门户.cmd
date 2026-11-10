@echo off
title CampusNet - Probe Portal Parameters
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusNet.ps1" -Probe
echo.
pause
