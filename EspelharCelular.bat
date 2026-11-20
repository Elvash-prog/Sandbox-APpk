@echo off
rem Abre o Espelhar Celular sem precisar de administrador.
cd /d "%~dp0"
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -STA -File "%~dp0EspelharCelular.ps1"
