@echo off
setlocal
set "APPDIR=%~dp0"
if not exist "%APPDIR%AIPrimeCursorManager.ps1" (
  echo ERROR: AIPrimeCursorManager.ps1 was not found.
  echo Extract the entire ZIP archive first.
  pause
  exit /b 2
)
if not exist "%APPDIR%bridge\server.mjs" (
  echo ERROR: bridge\server.mjs was not found.
  echo Keep the bridge folder alongside the app files.
  pause
  exit /b 3
)
echo Running XAML/resource preflight checks before launching the WPF UI...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APPDIR%Test-XamlResources.ps1" -SourceFile "%APPDIR%AIPrimeCursorManager.ps1"
if errorlevel 1 (
  echo.
  echo FATAL: UI preflight failed. The app will not be launched.
  pause
  exit /b 5
)
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%APPDIR%AIPrimeCursorManager.ps1"
set "RC=%ERRORLEVEL%"
if not "%RC%"=="0" (
  echo.
  echo AI Prime Cursor Manager exited with code %RC%.
  echo For detailed startup errors, run Start-AI-Prime-Cursor-Manager-Diagnostics.bat.
  pause
)
exit /b %RC%