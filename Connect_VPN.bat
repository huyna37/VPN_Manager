@echo off
chcp 65001 >nul
title VPN Multi-Connect Manager

REM Khoi chay VPN Manager ngam/truc tiep (Khong can quyen Admin)
start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn_manager.ps1"
