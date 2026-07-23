@echo off
setlocal
if not defined WFPO_NATIVE_POWERSHELL exit /b 87
if not exist "%WFPO_NATIVE_POWERSHELL%" exit /b 2
"%WFPO_NATIVE_POWERSHELL%" -NoLogo -NoProfile -ExecutionPolicy Bypass -STA -File "%~dp0Install-WindowsFPSOptimizer.ps1" -NoLaunch -Quiet
exit /b %ERRORLEVEL%
