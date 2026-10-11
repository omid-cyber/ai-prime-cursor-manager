@echo off
setlocal
set "APPDIR=%~dp0"
echo ============================================================
echo AI Prime Cursor Manager - Diagnostic Launcher
echo ============================================================
echo.
if not exist "%APPDIR%AIPrimeCursorManager.ps1" (
  echo ERROR: AIPrimeCursorManager.ps1 was not found.
  echo Extract the entire ZIP archive first; do not run it from inside ZIP.
  pause
  exit /b 2
)
if not exist "%APPDIR%bridge\server.mjs" (
  echo ERROR: bridge\server.mjs was not found.
  echo Extract the entire ZIP archive and keep the bridge folder beside the script.
  pause
  exit /b 3
)
where powershell.exe >nul 2>&1
if errorlevel 1 (
  echo ERROR: Windows PowerShell was not found.
  pause
  exit /b 4
)
where node.exe >nul 2>&1
if errorlevel 1 (
  echo WARNING: node.exe was not found on PATH. The UI may open, but Bridge features need Node.js 20+.
  echo.
)
echo Running source UI with a visible PowerShell console so startup errors stay visible.
echo Close the app when finished, then read any error shown below.
echo.
echo Running XAML/resource preflight checks before launching the WPF UI...
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -File "%APPDIR%Test-XamlResources.ps1" -SourceFile "%APPDIR%AIPrimeCursorManager.ps1"
if errorlevel 1 (
  echo.
  echo FATAL: UI preflight failed. The app will not be launched.
  pause
  exit /b 5
)
echo.
powershell.exe -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -NoExit -File "%APPDIR%AIPrimeCursorManager.ps1"
echo.
echo PowerShell returned exit code %ERRORLEVEL%.
echo If no app window appeared, copy the red error text above (never include API keys).
pause

echo Tip: Cloudflare tunnel output is saved under %LOCALAPPDATA%\AIPrimeCursorBridge\cloudflared.stdout.log and cloudflared.stderr.log.
echo Do not share API keys or the tunnel URL publicly.