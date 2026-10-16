@echo off
setlocal
REM ============================================================
REM  Codex portable launcher for cmd.exe.
REM  All Codex state remains inside this folder.
REM ============================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

REM Prefer PowerShell 7, fall back to Windows PowerShell 5.1.
set "PSH=powershell.exe"
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "PSH=pwsh.exe"

"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\codex.ps1" %*
set "EC=%ERRORLEVEL%"
exit /b %EC%
