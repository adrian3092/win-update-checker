@echo off
REM Launches the Update Checker GUI. Bypasses the default execution policy
REM for this single invocation only — does not change system settings.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0UpdateChecker.ps1" %*
