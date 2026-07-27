@echo off
REM Double-click this. It handles the PowerShell bits for you.
REM
REM Windows blocks unsigned scripts by default and marks anything downloaded
REM from the internet. This clears both for the files in this folder, then
REM starts the wizard.

cd /d "%~dp0"
title CS2 AG2 Port

echo.
echo   Preparing...
powershell -NoProfile -ExecutionPolicy Bypass -Command "Get-ChildItem '%~dp0*.ps1' | Unblock-File" 2>nul

if not exist "%~dp0Start.ps1" (
    echo.
    echo   ERROR: Start.ps1 is not in this folder.
    echo.
    echo   You may have downloaded the source code instead of the release.
    echo   Get CS2-AG2-Model-Porter-windows.zip from the Releases page, extract it
    echo   somewhere, and double-click RUN-ME.bat from inside that folder.
    echo.
    pause
    exit /b 1
)

powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Start.ps1"

echo.
echo   The window stays open so you can read any messages above.
pause
