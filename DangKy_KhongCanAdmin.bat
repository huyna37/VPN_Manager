@echo off
:: Dang ky Task Scheduler cho User hien tai de VPN Manager chay khong can quyen Admin
echo ====================================================
echo  DANG KY DICH VU VPN CHO USER %USERNAME% (0 ADMIN)
echo ====================================================
cd /d "%~dp0"
set BAT_PATH=%~dp0tools\run_forti.bat
if not exist "%~dp0tools\run_forti.bat" (
    echo @echo off > "%~dp0tools\run_forti.bat"
)
schtasks /create /tn "VPN_Manager_FortiClient" /tr "\"%BAT_PATH%\"" /sc ONCE /st 00:00 /ru "%USERNAME%" /rl HIGHEST /f
echo.
echo [OK] DA DANG KY THANH CONG!
echo Tu gio tro di, ban mo VPN_Manager.exe se KHONG BI HOI QUYEN ADMIN nua!
echo ====================================================
pause
