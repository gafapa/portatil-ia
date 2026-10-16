@echo off
setlocal
REM ============================================================
REM  Claude Code - portable launcher (cmd.exe)
REM  All state (config, sessions, projects, cache) stays inside
REM  this folder via CLAUDE_CONFIG_DIR. Credentials are
REM  password-protected: you are prompted on startup and
REM  .credentials.json is kept encrypted as .credentials.json.enc.
REM  Safe to move / USB / copy anywhere on disk.
REM ============================================================

REM --- Locate this folder (works even with spaces in the path) ---
set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

REM --- Find PowerShell (pwsh recommended, fall back to 5.1) ---
set "PSH=pwsh.exe"
where pwsh.exe >nul 2>nul
if errorlevel 1 set "PSH=powershell.exe"

"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\claude.ps1" %*
set "EC=%ERRORLEVEL%"
exit /b %EC%
