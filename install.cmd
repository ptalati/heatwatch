@echo off
rem Double-click to install Heatwatch: adds shortcuts, starts it at sign-in, and launches it.
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -StartAtSignIn
echo.
pause
