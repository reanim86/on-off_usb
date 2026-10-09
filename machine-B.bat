@echo off
rem Switch to machine B without admin password (uses the scheduled task Machine_B).
schtasks /run /tn "Machine_B" >nul
timeout /t 3 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "C:\Users\User\Documents\Machines\usb-block.ps1" keys
echo.
pause
