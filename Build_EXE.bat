@echo off
chcp 65001 >nul
title Dong Goi VPN Manager sang EXE
taskkill /IM VPN_Manager.exe /F 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0build_exe.ps1"
pause
