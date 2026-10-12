@echo off
REM EVREN LLM + OpenCode kurulumu (Windows CMD).
REM Asıl mantık scripts\install.ps1 içindedir; bu dosya yalnızca yönlendirir.
setlocal
set "HERE=%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%HERE%scripts\install.ps1" %*
exit /b %ERRORLEVEL%
