# Script Dong Goi Tu Dong VPN Manager sang File EXE
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "  BAT DAU DONG GOI VPN MANAGER SANG FILE EXE   " -ForegroundColor Cyan
Write-Host "===============================================" -ForegroundColor Cyan

$baseDir = $PSScriptRoot
if ([string]::IsNullOrEmpty($baseDir)) {
    $baseDir = [System.AppDomain]::CurrentDomain.BaseDirectory
}
if ([string]::IsNullOrEmpty($baseDir)) {
    $baseDir = (Get-Location).Path
}


$ps1File = Join-Path $baseDir "vpn_manager.ps1"
$csFile = Join-Path $baseDir "VPN_Manager.cs"
$exeFile = Join-Path $baseDir "VPN_Manager.exe"
$cscExe = "C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe"

if (-not (Test-Path $ps1File)) {
    Write-Host "[-] LOI: Khong tim thay file vpn_manager.ps1" -ForegroundColor Red
    exit 1
}

if (-not (Test-Path $cscExe)) {
    Write-Host "[-] LOI: Khong tim thay trinh bien dich C# (csc.exe)" -ForegroundColor Red
    exit 1
}

Write-Host "-> Dang doc ma nguon vpn_manager.ps1..." -ForegroundColor Yellow
$ps1Code = Get-Content -Path $ps1File -Raw -Encoding UTF8
$escapedCode = $ps1Code.Replace('"', '""')

$csHeader = @"
using System;
using System.IO;
using System.Diagnostics;
using System.Text;

namespace VPNManagerApp
{
    class Program
    {
        [STAThread]
        static void Main()
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory;
                string tempPs1 = Path.Combine(Path.GetTempPath(), "vpn_manager_rt.ps1");
                
                string code = @"
"@

$csFooter = @"
";
                File.WriteAllText(tempPs1, code, Encoding.UTF8);

                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + tempPs1 + "\"";
                psi.WorkingDirectory = exeDir;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;

                Process p = Process.Start(psi);
                p.WaitForExit();
            }
            catch (Exception ex)
            {
                System.Windows.Forms.MessageBox.Show("Loi khoi chay VPN Manager: " + ex.Message, "VPN Manager Error", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
            }
        }
    }
}
"@

$fullCs = $csHeader + $escapedCode + $csFooter
Set-Content -Path $csFile -Value $fullCs -Encoding UTF8

Write-Host "-> Dang thuc thi bien dich C# sang VPN_Manager.exe..." -ForegroundColor Yellow
$compileArgs = "/target:winexe /out:`"$exeFile`" /r:System.Windows.Forms.dll `"$csFile`""
Start-Process -FilePath $cscExe -ArgumentList $compileArgs -Wait -NoNewWindow

if (Test-Path $exeFile) {
    Remove-Item -Path $csFile -Force -ErrorAction SilentlyContinue
    $fileInfo = Get-Item $exeFile
    Write-Host "===============================================" -ForegroundColor Green
    Write-Host "[OK] THANH CONG: Da dong goi file VPN_Manager.exe!" -ForegroundColor Green
    Write-Host "-> Kich thuoc: $([Math]::Round($fileInfo.Length / 1KB, 2)) KB" -ForegroundColor Green
    Write-Host "===============================================" -ForegroundColor Green
} else {
    Write-Host "[-] LOI: Bien dich that bai!" -ForegroundColor Red
}
