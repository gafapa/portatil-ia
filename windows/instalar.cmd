@echo off
setlocal
REM ============================================================
REM  Instala o actualiza los asistentes portables en un pendrive
REM  (o en otra carpeta) descargandolos de internet, y verifica
REM  la instalacion. Ver instalar.ps1.
REM
REM    instalar.cmd                      asistente interactivo
REM    instalar.cmd E:\portatil          instala/actualiza ahi
REM    instalar.cmd E:\portatil -Si      sin confirmacion
REM    instalar.cmd E:\portatil -Forzar  descarga todo de nuevo
REM    instalar.cmd E:\portatil -SoloVerificar
REM ============================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

REM Prefer PowerShell 7, fall back to Windows PowerShell 5.1.
set "PSH=powershell.exe"
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "PSH=pwsh.exe"

"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\instalar.ps1" %*
set "EC=%ERRORLEVEL%"

REM Keep the window open when started with a double click.
if "%~1"=="" (
  echo.
  pause
)
exit /b %EC%
