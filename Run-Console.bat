@echo off
REM Console version — prints the update list without opening a GUI window.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpdateChecker.ps1" -NoGui
pause
