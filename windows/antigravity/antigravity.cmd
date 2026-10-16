@echo off
setlocal
REM ============================================================
REM  antigravity - portable launcher (cmd.exe)
REM  Everything (data, config, cache) stays inside this folder.
REM  Credentials are password-protected: you are prompted on
REM  startup and auth.json.enc is kept encrypted.
REM  Safe to move / USB / copy anywhere on disk.
REM ============================================================

REM --- Locate this folder (works even with spaces in the path) ---
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

REM --- Prefer PowerShell 7, fall back to Windows PowerShell 5.1 ---
set "PSH=powershell.exe"
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "PSH=pwsh.exe"

"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\antigravity.ps1" %*
set "EC=%ERRORLEVEL%"
if not "%EC%"=="0" (
  echo.
  echo [antigravity] Startup failed with exit code %EC%.
  echo [antigravity] Press any key to close this window.
  pause >nul
)
exit /b %EC%
