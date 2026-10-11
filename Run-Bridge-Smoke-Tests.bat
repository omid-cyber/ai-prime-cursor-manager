@echo off
setlocal
cd /d "%~dp0"
where node.exe >nul 2>&1
if errorlevel 1 (echo ERROR: Node.js 20+ is required.& pause & exit /b 2)
echo ============================================================
echo AI Prime Cursor Manager - Repeated smoke tests (5 runs)
echo ============================================================
for /L %%R in (1,1,5) do (
  echo.
  echo ---------- RUN %%R / 5: Bridge integration tests ----------
  node tests\bridge-smoke.test.mjs
  if errorlevel 1 (echo Bridge tests failed in run %%R.& pause & exit /b 1)
  echo.
  echo ---------- RUN %%R / 5: Tunnel static tests ----------
  node tests\tunnel-helper-smoke.test.mjs
  if errorlevel 1 (echo Tunnel tests failed in run %%R.& pause & exit /b 1)
)
echo.
echo ALL 5 REPEATED TEST RUNS PASSED.
pause
exit /b 0