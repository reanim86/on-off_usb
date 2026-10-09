@echo off
rem Switch to machine A without admin password (uses the scheduled task Machine_A).
schtasks /run /tn "Machine_A" >nul
timeout /t 3 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\User\Documents\Machines\usb-block.ps1" keys
echo.
pause
