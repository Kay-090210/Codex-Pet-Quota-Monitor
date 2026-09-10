@echo off
setlocal
set "SCRIPT=%~dp0CodexPetQuota.ps1"
if not exist "%SCRIPT%" (
  echo File not found: "%SCRIPT%"
  exit /b 1
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -STA -File "%SCRIPT%" -Stop
exit /b %errorlevel%
