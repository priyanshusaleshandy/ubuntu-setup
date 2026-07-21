@echo off
:: Launches Setup Center CLI with Execution Policy Bypassed & Auto-Elevation
cd /d "%~dp0"
if exist "%~dp0setup-center-cli.ps1" (
    powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup-center-cli.ps1"
) else (
    powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12; iex (irm https://raw.githubusercontent.com/Priyanshu8494/ubuntu-setup/main/setup-center-cli.ps1)"
)
