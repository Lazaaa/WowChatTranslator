@echo off
rem WoW chat translator - starts the PowerShell window without a console
start "" powershell -NoProfile -ExecutionPolicy Bypass -STA -WindowStyle Hidden -File "%~dp0ChatTranslator.ps1"
