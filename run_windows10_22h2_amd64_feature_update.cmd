@echo off
setlocal
cd /d "%~dp0"

where pwsh >nul 2>nul
if %errorlevel%==0 (
	set "PWSH=pwsh"
) else (
	set "PWSH=D:\float\Program\script\PowerShell-7\pwsh.exe"
)

"%PWSH%" -NoProfile -ExecutionPolicy Bypass -File "%~dp0run_windows10_22h2_amd64_feature_update.ps1"
echo.
pause

