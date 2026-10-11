@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install\Update-DeadAsDiscoAP.ps1" %*
pause
