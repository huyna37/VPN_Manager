@echo off
chcp 65001 >nul
title Sophos SSL VPN Client

if exist "%~dp0VPN_Manager.exe" (
    start "" "%~dp0VPN_Manager.exe"
) else (
    start "" powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0vpn_manager.ps1"
)
