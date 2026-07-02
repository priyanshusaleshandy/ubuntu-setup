@echo off
:: Batch script launcher to run setup-profiles.ps1 with Admin privileges and Bypass policy
:: Double-click this file to launch the script.

:: Check for Administrative privileges
>nul 2>&1 "%SYSTEMROOT%\system32\cacls.exe" "%SYSTEMROOT%\system32\config\system"
if '%errorlevel%' NEQ '0' (
    echo Requesting Administrative Privileges...
    powershell -Command "Start-Process '%~dp0setup-profiles.bat' -Verb RunAs"
    exit /B
)

pushd "%~dp0"
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-profiles.ps1"
popd
exit /B
