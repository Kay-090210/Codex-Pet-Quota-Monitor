@echo off
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0CodexPetQuota.ps1" -PingSettings
pause
