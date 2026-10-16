@echo off
setlocal
REM ============================================================
REM  Actualiza ESTE portable desde internet: descarga las ultimas
REM  versiones oficiales de los asistentes que lo necesiten y
REM  verifica la instalacion. No toca sesiones ni credenciales.
REM  Ver instalar.ps1.
REM
REM    actualizar.cmd              pregunta antes de descargar
REM    actualizar.cmd -Si          sin confirmacion
REM    actualizar.cmd -Forzar      descarga todo aunque este al dia
REM    actualizar.cmd -SoloVerificar
REM ============================================================

set "ROOT=%~dp0"
if "%ROOT:~-1%"=="\" set "ROOT=%ROOT:~0,-1%"

REM Prefer PowerShell 7, fall back to Windows PowerShell 5.1.
set "PSH=powershell.exe"
where pwsh.exe >nul 2>nul
if not errorlevel 1 set "PSH=pwsh.exe"

"%PSH%" -NoProfile -ExecutionPolicy Bypass -File "%ROOT%\instalar.ps1" -Destino "%ROOT%" %*
set "EC=%ERRORLEVEL%"

REM Keep the window open when started with a double click.
if "%~1"=="" (
  echo.
  pause
)
exit /b %EC%
