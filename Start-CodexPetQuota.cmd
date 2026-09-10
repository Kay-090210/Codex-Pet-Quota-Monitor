@echo off
setlocal
set "LAUNCHER=%~dp0Run-CodexPetQuotaHidden.vbs"
if not exist "%LAUNCHER%" (
  echo File not found: "%LAUNCHER%"
  exit /b 1
)
wscript.exe //B //Nologo "%LAUNCHER%"
exit /b %errorlevel%
