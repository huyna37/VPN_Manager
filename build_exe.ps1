# Script Dong Goi Tu Dong Sophos VPN sang File EXE (Nhung truc tiep cau hinh)
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8

Write-Host "===============================================" -ForegroundColor Cyan
Write-Host "   BAT DAU DONG GOI SOPHOS VPN SANG FILE EXE   " -ForegroundColor Cyan
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

# Nhung truc tiep cac file cau hinh vao EXE (Khong can file ben ngoai)
$targetFiles = @(
    "vpn_config.json",
    "config\sophos\sophos.ovpn"
)

Write-Host "-> Dang ma hoa va nhung truc tiep cac file cau hinh vao EXE..." -ForegroundColor Yellow
$extractCodeLines = @()

foreach ($relPath in $targetFiles) {
    $fullPath = Join-Path $baseDir $relPath
    if (Test-Path $fullPath) {
        $bytes = [System.IO.File]::ReadAllBytes($fullPath)
        $b64 = [Convert]::ToBase64String($bytes)
        $escapedRelPath = $relPath.Replace('\', '\\')
        $extractCodeLines += "                EnsureFileExists(exeDir, `"$escapedRelPath`", `"$b64`");"
        Write-Host "   + Da nhung: $relPath ($([Math]::Round($bytes.Length / 1KB, 2)) KB)" -ForegroundColor Green
    } else {
        Write-Host "   [!] Canh bao: Khong tim thay file $relPath" -ForegroundColor Yellow
    }
}

$extractCodeBlock = $extractCodeLines -join "`r`n"

Write-Host "-> Dang doc ma nguon vpn_manager.ps1..." -ForegroundColor Yellow
$ps1Code = Get-Content -Path $ps1File -Raw -Encoding UTF8
$escapedCode = $ps1Code.Replace('"', '""')

$csHeader = @"
using System;
using System.IO;
using System.Diagnostics;
using System.Text;
using System.Windows.Shell;

namespace SophosVPNApp
{
    class Program
    {
        private static void EnsureFileExists(string baseDir, string relativePath, string base64Content)
        {
            try
            {
                string fullPath = Path.Combine(baseDir, relativePath);
                if (!File.Exists(fullPath))
                {
                    string dir = Path.GetDirectoryName(fullPath);
                    if (!string.IsNullOrEmpty(dir) && !Directory.Exists(dir))
                    {
                        Directory.CreateDirectory(dir);
                    }
                    byte[] bytes = Convert.FromBase64String(base64Content);
                    File.WriteAllBytes(fullPath, bytes);
                }
            }
            catch {}
        }

        private static void RegisterTaskbarJumpList()
        {
            try
            {
                string currentExe = Process.GetCurrentProcess().MainModule.FileName;
                JumpList jumpList = new JumpList();

                JumpTask task1 = new JumpTask();
                task1.Title = "1. Dang nhap Sophos VPN";
                task1.Description = "1-Click Ket noi Sophos SSL VPN";
                task1.ApplicationPath = currentExe;
                task1.Arguments = "-Connect sophos";
                task1.IconResourcePath = currentExe;

                JumpTask task2 = new JumpTask();
                task2.Title = "2. Ngat ket noi VPN";
                task2.Description = "Ngat toan bo ket noi Sophos VPN";
                task2.ApplicationPath = currentExe;
                task2.Arguments = "-Disconnect";
                task2.IconResourcePath = currentExe;

                jumpList.JumpItems.Add(task1);
                jumpList.JumpItems.Add(task2);
                jumpList.ShowFrequentCategory = false;
                jumpList.ShowRecentCategory = false;
                jumpList.Apply();
            }
            catch {}
        }

        [STAThread]
        static void Main(string[] args)
        {
            try
            {
                string exeDir = AppDomain.CurrentDomain.BaseDirectory;

$extractCodeBlock

                if (args == null || args.Length == 0)
                {
                    RegisterTaskbarJumpList();
                }

                string tempPs1 = Path.Combine(Path.GetTempPath(), "sophos_vpn_rt.ps1");
                
                string code = @"
"@

$csFooter = @"
";
                File.WriteAllText(tempPs1, code, Encoding.UTF8);

                string extraArgs = (args != null && args.Length > 0) ? (" " + string.Join(" ", args)) : "";
                ProcessStartInfo psi = new ProcessStartInfo();
                psi.FileName = "powershell.exe";
                psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + tempPs1 + "\"" + extraArgs;
                psi.WorkingDirectory = exeDir;
                psi.EnvironmentVariables["VPN_MANAGER_APP_DIR"] = exeDir;
                psi.UseShellExecute = false;
                psi.CreateNoWindow = true;
                psi.WindowStyle = ProcessWindowStyle.Hidden;

                Process p = Process.Start(psi);
                p.WaitForExit();
            }
            catch (Exception ex)
            {
                System.Windows.Forms.MessageBox.Show("Loi khoi chay Sophos VPN: " + ex.Message, "Sophos VPN Error", System.Windows.Forms.MessageBoxButtons.OK, System.Windows.Forms.MessageBoxIcon.Error);
            }
        }
    }
}
"@

$fullCs = $csHeader + $escapedCode + $csFooter
Set-Content -Path $csFile -Value $fullCs -Encoding UTF8

$manifestFile = Join-Path $baseDir "app.manifest"
$manifestXml = @"
<?xml version="1.0" encoding="utf-8"?>
<assembly manifestVersion="1.0" xmlns="urn:schemas-microsoft-com:asm.v1">
  <trustInfo xmlns="urn:schemas-microsoft-com:asm.v2">
    <security>
      <requestedPrivileges xmlns="urn:schemas-microsoft-com:asm.v3">
        <requestedExecutionLevel level="asInvoker" uiAccess="false" />
      </requestedPrivileges>
    </security>
  </trustInfo>
</assembly>
"@
Set-Content -Path $manifestFile -Value $manifestXml -Encoding UTF8

Write-Host "-> Dang thuc thi bien dich C# sang VPN_Manager.exe (Chay quyen Standard User - 0 UAC Prompt)..." -ForegroundColor Yellow
$compileArgs = "/codepage:65001 /utf8output /target:winexe /win32manifest:`"$manifestFile`" /out:`"$exeFile`" /r:System.Windows.Forms.dll /r:`"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\PresentationFramework.dll`" /r:`"C:\Windows\Microsoft.NET\Framework64\v4.0.30319\WPF\WindowsBase.dll`" `"$csFile`""
Start-Process -FilePath $cscExe -ArgumentList $compileArgs -Wait -NoNewWindow
Remove-Item -Path $manifestFile -Force -ErrorAction SilentlyContinue

if (Test-Path $exeFile) {
    Remove-Item -Path $csFile -Force -ErrorAction SilentlyContinue
    $fileInfo = Get-Item $exeFile
    Write-Host "===============================================" -ForegroundColor Green
    Write-Host "[OK] THANH CONG: Da nhung cau hinh vao VPN_Manager.exe!" -ForegroundColor Green
    Write-Host "-> Kich thuoc EXE: $([Math]::Round($fileInfo.Length / 1KB, 2)) KB" -ForegroundColor Green
    Write-Host "===============================================" -ForegroundColor Green
} else {
    Write-Host "[-] LOI: Bien dich that bai!" -ForegroundColor Red
}
