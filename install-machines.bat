@echo off
rem Run ONCE to register the scheduled tasks (asks for admin only this time).
fltmc >nul 2>&1
if %errorlevel% neq 0 (
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-machines.ps1"
echo.
pause
