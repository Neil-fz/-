@echo off
title CampusNet - Test Login
cd /d "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0CampusNet.ps1" -Once
echo.
pause
