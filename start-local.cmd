@echo off
setlocal
cd /d "%~dp0"

where powershell.exe >nul 2>nul
if errorlevel 1 (
  echo PowerShell was not found. Fakebook cannot be started.
  if /I not "%FAKEBOOK_NO_PAUSE%"=="1" pause
  exit /b 1
)

powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%~dp0scripts\start-local.ps1" %*
set "FAKEBOOK_EXIT_CODE=%ERRORLEVEL%"

if not "%FAKEBOOK_EXIT_CODE%"=="0" (
  echo.
  echo Fakebook failed to start. The error is shown above.
  echo Logs are stored in "%~dp0.run".
  if /I not "%FAKEBOOK_NO_PAUSE%"=="1" pause
  exit /b %FAKEBOOK_EXIT_CODE%
)

echo.
echo Fakebook is running at http://localhost:3001
if /I not "%FAKEBOOK_NO_PAUSE%"=="1" pause
exit /b %FAKEBOOK_EXIT_CODE%
