# ==============================================================================
# UNG DUNG DANG NHAP SOPHOS SSL VPN
# Chi chua chuc nang Dang nhap / Ket noi don gian, an hoan toan sao chep mat khau
# ==============================================================================
param(
    [string]$Connect = "",
    [string]$Action = "",
    [switch]$Disconnect
)

[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Xac dinh thu muc goc ung dung
$baseDir = $env:VPN_MANAGER_APP_DIR
if ([string]::IsNullOrEmpty($baseDir)) { $baseDir = $PSScriptRoot }
if ([string]::IsNullOrEmpty($baseDir)) { $baseDir = [System.AppDomain]::CurrentDomain.BaseDirectory }
if ([string]::IsNullOrEmpty($baseDir)) { $baseDir = (Get-Location).Path }

function Get-Absolute-Path([string]$path) {
    if ([string]::IsNullOrEmpty($path)) { return "" }
    if ([System.IO.Path]::IsPathRooted($path)) { return $path }
    return Join-Path $baseDir $path
}

$configFile = Join-Path $baseDir "vpn_config.json"
$openvpnExe = "C:\Program Files\OpenVPN\bin\openvpn.exe"
$openvpnGuiExe = "C:\Program Files\OpenVPN\bin\openvpn-gui.exe"
if (-not (Test-Path $openvpnGuiExe)) {
    $openvpnGuiExe = "C:\Program Files (x86)\OpenVPN\bin\openvpn-gui.exe"
}

$userOpenVpnDir = Join-Path $env:USERPROFILE "OpenVPN\config"
if (-not (Test-Path $userOpenVpnDir)) {
    try { New-Item -ItemType Directory -Path $userOpenVpnDir -Force | Out-Null } catch {}
}

# Ham ghi log he thong / UI
function Log-Msg([string]$msg) {
    $time = (Get-Date).ToString("HH:mm:ss")
    $logLine = "[$time] $msg"
    try {
        if ($txtLog -and -not $txtLog.IsDisposed) {
            $txtLog.AppendText("$logLine`r`n")
            $txtLog.SelectionStart = $txtLog.Text.Length
            $txtLog.ScrollToCaret()
            return
        }
    } catch {}
    Write-Host $logLine
}

# Kiem tra quyen Admin
function Test-IsAdmin {
    try {
        $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object Security.Principal.WindowsPrincipal($identity)
        return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}
$script:isAdmin = Test-IsAdmin

function Restart-AsAdmin {
    $exePath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    if ($exePath -match "powershell") {
        $exePath = Join-Path $baseDir "VPN_Manager.exe"
    }
    if (Test-Path $exePath) {
        try {
            Start-Process -FilePath $exePath -Verb RunAs
            if ($timer) { $timer.Stop(); $timer.Dispose() }
            if ($trayIcon) { $trayIcon.Visible = $false; $trayIcon.Dispose() }
            $form.Close()
            [System.Windows.Forms.Application]::Exit()
        } catch {}
    }
}

# Cau hinh mac dinh
function Get-Default-Config {
    return [PSCustomObject]@{
        sophos = [PSCustomObject]@{
            enabled = $true
            name = "Sophos SSL VPN"
            username = "huyna"
            password = ""
            secret = ""
            dir = "config\sophos"
            configName = "sophos"
            ovpnFile = "sophos.ovpn"
        }
    }
}

function Load-Config {
    if (Test-Path $configFile) {
        try {
            $jsonStr = [System.IO.File]::ReadAllText($configFile, [System.Text.Encoding]::UTF8)
            $parsed = $jsonStr | ConvertFrom-Json
            if ($parsed -and $parsed.sophos) {
                return $parsed
            }
        } catch {}
    }
    return Get-Default-Config
}

function Save-Config($cfgData) {
    try {
        $json = $cfgData | ConvertTo-Json -Depth 5
        [System.IO.File]::WriteAllText($configFile, $json, [System.Text.Encoding]::UTF8)
    } catch {}
}

# Tinh TOTP 6 so tu Secret Key Base32
function Get-TOTP {
    param([string]$SecretKey)
    if ([string]::IsNullOrWhiteSpace($SecretKey)) { return "" }
    $SecretKey = $SecretKey.Trim().ToUpper().Replace(" ", "").Replace("-", "")
    $base32Chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZ234567"
    $bits = ""
    foreach ($c in $SecretKey.ToCharArray()) {
        $val = $base32Chars.IndexOf($c)
        if ($val -ge 0) { $bits += [Convert]::ToString($val, 2).PadLeft(5, '0') }
    }
    $byteCount = [Math]::Floor($bits.Length / 8)
    if ($byteCount -le 0) { return "" }
    $key = New-Object byte[] $byteCount
    for ($i = 0; $i -lt $byteCount; $i++) {
        $key[$i] = [Convert]::ToByte($bits.Substring($i * 8, 8), 2)
    }
    
    $unixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $step = [Math]::Floor($unixTime / 30)
    $stepBytes = [BitConverter]::GetBytes([long]$step)
    if ([BitConverter]::IsLittleEndian) { [Array]::Reverse($stepBytes) }
    
    $hmac = New-Object System.Security.Cryptography.HMACSHA1($key)
    try {
        $hash = $hmac.ComputeHash($stepBytes)
        $offset = $hash[$hash.Length - 1] -band 0x0F
        $binary = (($hash[$offset] -band 0x7F) -shl 24) -bor (($hash[$offset + 1] -band 0xFF) -shl 16) -bor (($hash[$offset + 2] -band 0xFF) -shl 8) -bor ($hash[$offset + 3] -band 0xFF)
        return ($binary % 1000000).ToString("D6")
    } finally {
        $hmac.Dispose()
    }
}

# Don dep file thong tin xac thuc tam thoi
function Clean-AuthFiles {
    try {
        if (Test-Path $userOpenVpnDir) {
            Remove-Item -Path (Join-Path $userOpenVpnDir "*_auth.txt") -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

[System.AppDomain]::CurrentDomain.add_ProcessExit({
    Clean-AuthFiles
})

# Ham ket noi Sophos SSL VPN
function Start-SophosConnect {
    $c = Load-Config
    $prof = $c.sophos
    if (-not $prof) {
        Log-Msg "[-] LOI: Khong tim thay cau hinh Sophos trong vpn_config.json!"
        return $false
    }

    $username = $prof.username
    $password = $prof.password
    $secret = $prof.secret
    $dir = $prof.dir
    $ovpnFile = $prof.ovpnFile
    $configName = if ($prof.configName) { $prof.configName } else { "sophos" }

    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        Log-Msg "[-] CHUA CAI DAT: Vui long nhap Tai khoan va Mat khau trong muc Cai dat!"
        [System.Windows.Forms.MessageBox]::Show("Chua co thong tin Tai khoan hoac Mat khau!`nVui long bam 'Cai dat' de thiet lap truoc khi ket noi.", "Sophos VPN", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }

    Log-Msg "-------------------------------------------"
    Log-Msg "Dang khoi tao ket noi Sophos SSL VPN (Tai khoan: $username)..."

    # Tinh ma OTP tu dong
    $otp = ""
    if (-not [string]::IsNullOrWhiteSpace($secret)) {
        $otp = Get-TOTP -SecretKey $secret
        Log-Msg "-> Da xac thuc 2FA OTP thanh cong."
    }
    $fullPass = if ($otp) { "$password$otp" } else { $password }

    $srcDir = Get-Absolute-Path $dir
    $ovpnSrcFile = Join-Path $srcDir $ovpnFile
    if (-not (Test-Path $ovpnSrcFile)) {
        $ovpnSrcFile = Join-Path $baseDir "config\sophos\sophos.ovpn"
    }

    if (-not (Test-Path $ovpnSrcFile)) {
        Log-Msg "[-] LOI: Khong tim thay file cau hinh sophos.ovpn!"
        [System.Windows.Forms.MessageBox]::Show("Khong tim thay file cau hinh sophos.ovpn tai: $ovpnSrcFile", "Loi cau hinh", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }

    # Ghi file xac thuc tam thoi vao OpenVPN config
    $targetAuth = Join-Path $userOpenVpnDir "${configName}_auth.txt"
    $targetOvpn = Join-Path $userOpenVpnDir "${configName}.ovpn"
    Set-Content -Path $targetAuth -Value @($username, $fullPass) -Encoding ASCII

    # Sao chep file .ovpn va tro toi file auth
    $ovpnContent = Get-Content -Path $ovpnSrcFile -Raw
    $ovpnContent = $ovpnContent -replace "auth-user-pass.*", "auth-user-pass ${configName}_auth.txt"
    Set-Content -Path $targetOvpn -Value $ovpnContent -Encoding UTF8

    $targetConnectName = "${configName}.ovpn"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $sysConfigDir = "C:\Program Files\OpenVPN\config"
        if (Test-Path $sysConfigDir) {
            $sysFiles = Get-ChildItem -Path $sysConfigDir -Filter "*.ovpn" -ErrorAction SilentlyContinue
            foreach ($sf in $sysFiles) {
                if ($sf.Name -eq "${configName}.ovpn" -or ($sf.Name -match "sophos")) {
                    $targetConnectName = $sf.Name
                    break
                }
            }
        }
    }

    if (Test-Path $openvpnGuiExe) {
        $guiProc = Get-Process -Name "openvpn-gui" -ErrorAction SilentlyContinue
        if (-not $guiProc) {
            Start-Process -FilePath $openvpnGuiExe
            Start-Sleep -Milliseconds 800
        }
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command connect $targetConnectName" -ErrorAction SilentlyContinue
        Log-Msg "[OK] Da gui lenh dang nhap Sophos toi OpenVPN GUI ($targetConnectName)!"
        return $true
    } elseif (Test-Path $openvpnExe) {
        Start-Process -FilePath $openvpnExe -ArgumentList "--config `"$targetOvpn`"" -WindowStyle Hidden
        Log-Msg "[OK] Da khoi chay ket noi Sophos qua OpenVPN CLI!"
        return $true
    } else {
        Log-Msg "[-] LOI: Khong tim thay OpenVPN tren he thong!"
        [System.Windows.Forms.MessageBox]::Show("Khong tim thay OpenVPN tren may tinh!`nVui long cai dat OpenVPN truoc khi ket noi.", "Loi OpenVPN", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }
}

# Ham ngat ket noi
function Stop-SophosDisconnect {
    Log-Msg "-------------------------------------------"
    Log-Msg "Dang ngat ket noi Sophos SSL VPN..."

    if (Test-Path $openvpnGuiExe) {
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect_all" -ErrorAction SilentlyContinue
    }

    Stop-Process -Name "openvpn" -Force -ErrorAction SilentlyContinue
    Clean-AuthFiles
    Log-Msg "[OK] Da ngat ket noi va don dep phien lam viec an toan."
}

# Xu ly tham so dong lenh (CLI)
if ($Disconnect -or $Action -eq "disconnect") {
    Stop-SophosDisconnect
    exit 0
}

if ($Connect -match "sophos" -or $Action -eq "connect") {
    Start-SophosConnect
    exit 0
}

# An Console den khi mo GUI
try {
    $win32 = Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();' -Name "Win32ConsoleHelper" -Namespace "Win32Utils" -PassThru -ErrorAction SilentlyContinue
    if ($win32) {
        $hwnd = $win32::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { $win32::ShowWindow($hwnd, 0) }
    }
} catch {}

$cfg = Load-Config

# --- GIAO DIEN CHINH (MODERN & SIMPLE LOGIN UI) ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Sophos SSL VPN Client"
$form.Size = New-Object System.Drawing.Size(460, 580)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)

try {
    $prop = $form.GetType().GetProperty("DoubleBuffered", [System.Reflection.BindingFlags]::Instance -bor [System.Reflection.BindingFlags]::NonPublic)
    if ($prop) { $prop.SetValue($form, $true, $null) }
} catch {}

# Header Panel
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Location = New-Object System.Drawing.Point(0, 0)
$pnlHeader.Size = New-Object System.Drawing.Size(460, 70)
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(15, 45, 80)
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "SOPHOS SSL VPN"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(18, 12)
$lblTitle.Size = New-Object System.Drawing.Size(300, 26)
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "Xac thuc tu dong 2FA OTP & Ket noi an toan"
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(186, 215, 248)
$lblSub.Location = New-Object System.Drawing.Point(20, 40)
$lblSub.Size = New-Object System.Drawing.Size(300, 20)
$pnlHeader.Controls.Add($lblSub)

# Nut Settings tren Header
$btnSettingHeader = New-Object System.Windows.Forms.Button
$btnSettingHeader.Text = "Cai dat"
$btnSettingHeader.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnSettingHeader.Location = New-Object System.Drawing.Point(345, 18)
$btnSettingHeader.Size = New-Object System.Drawing.Size(85, 32)
$btnSettingHeader.BackColor = [System.Drawing.Color]::FromArgb(30, 65, 105)
$btnSettingHeader.ForeColor = [System.Drawing.Color]::White
$btnSettingHeader.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnSettingHeader.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnSettingHeader.FlatAppearance.BorderSize = 0
$btnSettingHeader.Add_Click({ Show-ConfigDialog })
$pnlHeader.Controls.Add($btnSettingHeader)

# Card Thong tin & Trang thai
$pnlCard = New-Object System.Windows.Forms.Panel
$pnlCard.Location = New-Object System.Drawing.Point(18, 85)
$pnlCard.Size = New-Object System.Drawing.Size(408, 150)
$pnlCard.BackColor = [System.Drawing.Color]::White
$pnlCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($pnlCard)

# Dong 1: Tai khoan
$lblAccTitle = New-Object System.Windows.Forms.Label
$lblAccTitle.Text = "Tai khoan dang nhap:"
$lblAccTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$lblAccTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblAccTitle.Location = New-Object System.Drawing.Point(15, 15)
$lblAccTitle.Size = New-Object System.Drawing.Size(150, 20)
$pnlCard.Controls.Add($lblAccTitle)

$lblAccVal = New-Object System.Windows.Forms.Label
$lblAccVal.Text = if ($cfg.sophos.username) { $cfg.sophos.username } else { "(Chua cau hinh)" }
$lblAccVal.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblAccVal.ForeColor = [System.Drawing.Color]::FromArgb(30, 41, 59)
$lblAccVal.Location = New-Object System.Drawing.Point(170, 15)
$lblAccVal.Size = New-Object System.Drawing.Size(220, 20)
$pnlCard.Controls.Add($lblAccVal)

# Dong 2: Trang thai 2FA OTP
$lblOtpTitle = New-Object System.Windows.Forms.Label
$lblOtpTitle.Text = "Xac thuc 2FA OTP:"
$lblOtpTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$lblOtpTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblOtpTitle.Location = New-Object System.Drawing.Point(15, 48)
$lblOtpTitle.Size = New-Object System.Drawing.Size(150, 20)
$pnlCard.Controls.Add($lblOtpTitle)

$lblOtpVal = New-Object System.Windows.Forms.Label
$lblOtpVal.Text = "[*] Tu dong sinh ma khi dang nhap"
$lblOtpVal.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblOtpVal.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtpVal.Location = New-Object System.Drawing.Point(170, 48)
$lblOtpVal.Size = New-Object System.Drawing.Size(220, 20)
$pnlCard.Controls.Add($lblOtpVal)

# Dong 3: Trang thai Ket noi
$lblStatusTitle = New-Object System.Windows.Forms.Label
$lblStatusTitle.Text = "Trang thai mang:"
$lblStatusTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$lblStatusTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblStatusTitle.Location = New-Object System.Drawing.Point(15, 82)
$lblStatusTitle.Size = New-Object System.Drawing.Size(150, 20)
$pnlCard.Controls.Add($lblStatusTitle)

$lblStatusVal = New-Object System.Windows.Forms.Label
$lblStatusVal.Text = "[o] Chua ket noi"
$lblStatusVal.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$lblStatusVal.Location = New-Object System.Drawing.Point(170, 82)
$lblStatusVal.Size = New-Object System.Drawing.Size(220, 20)
$pnlCard.Controls.Add($lblStatusVal)

# Dong 4: IP VPN
$lblIpTitle = New-Object System.Windows.Forms.Label
$lblIpTitle.Text = "Dia chi IP VPN:"
$lblIpTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$lblIpTitle.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblIpTitle.Location = New-Object System.Drawing.Point(15, 114)
$lblIpTitle.Size = New-Object System.Drawing.Size(150, 20)
$pnlCard.Controls.Add($lblIpTitle)

$lblIpVal = New-Object System.Windows.Forms.Label
$lblIpVal.Text = "---.---.---.---"
$lblIpVal.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular)
$lblIpVal.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
$lblIpVal.Location = New-Object System.Drawing.Point(170, 114)
$lblIpVal.Size = New-Object System.Drawing.Size(220, 20)
$pnlCard.Controls.Add($lblIpVal)

# NUT BAM DANG NHAP (CONNECT)
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = ">> DANG NHAP VPN"
$btnConnect.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$btnConnect.Location = New-Object System.Drawing.Point(18, 250)
$btnConnect.Size = New-Object System.Drawing.Size(250, 44)
$btnConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnConnect.ForeColor = [System.Drawing.Color]::White
$btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnConnect.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnConnect)

# NUT BAM NGAT KET NOI (DISCONNECT)
$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "[X] NGAT"
$btnDisconnect.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnDisconnect.Location = New-Object System.Drawing.Point(278, 250)
$btnDisconnect.Size = New-Object System.Drawing.Size(148, 44)
$btnDisconnect.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
$btnDisconnect.ForeColor = [System.Drawing.Color]::White
$btnDisconnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDisconnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnDisconnect.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnDisconnect)

# KHUNG NHAT KY (LOGS)
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Nhat ky hoat dong:"
$lblLog.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblLog.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$lblLog.Location = New-Object System.Drawing.Point(18, 308)
$lblLog.Size = New-Object System.Drawing.Size(150, 18)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(18, 328)
$txtLog.Size = New-Object System.Drawing.Size(408, 195)
$txtLog.Multiline = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(24, 32, 47)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(134, 239, 172)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$form.Controls.Add($txtLog)

# --- SYSTEM TRAY (KHAY TASKBAR) ---
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = [System.Drawing.SystemIcons]::Shield
$trayIcon.Text = "Sophos SSL VPN"
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$mItemLogin = New-Object System.Windows.Forms.ToolStripMenuItem("Dang nhap Sophos VPN")
$mItemLogin.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemLogin.Add_Click({ Start-SophosConnect })
$trayMenu.Items.Add($mItemLogin) | Out-Null

$mItemDis = New-Object System.Windows.Forms.ToolStripMenuItem("Ngat ket noi")
$mItemDis.Add_Click({ Stop-SophosDisconnect })
$trayMenu.Items.Add($mItemDis) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemShow = New-Object System.Windows.Forms.ToolStripMenuItem("Mo Cua So")
$mItemShow.Add_Click({
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
})
$trayMenu.Items.Add($mItemShow) | Out-Null

$mItemConfig = New-Object System.Windows.Forms.ToolStripMenuItem("Cai dat tai khoan")
$mItemConfig.Add_Click({ Show-ConfigDialog })
$trayMenu.Items.Add($mItemConfig) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemExit = New-Object System.Windows.Forms.ToolStripMenuItem("Thoat")
$mItemExit.ForeColor = [System.Drawing.Color]::DarkRed
$mItemExit.Add_Click({
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    if ($trayIcon) { $trayIcon.Visible = $false; $trayIcon.Dispose() }
    Clean-AuthFiles
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
})
$trayMenu.Items.Add($mItemExit) | Out-Null

$trayIcon.ContextMenuStrip = $trayMenu
$trayIcon.Add_DoubleClick({
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
})

# Form Closing: thu nho ve Tray
$form.Add_FormClosing({
    param($sender, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $form.Hide()
    }
})

# --- SU KIEN NUT BAM ---
$btnConnect.Add_Click({
    Start-SophosConnect
})

$btnDisconnect.Add_Click({
    Stop-SophosDisconnect
})

# --- TIMER THEO DOI TRANG THAI ---
$tickCount = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $script:tickCount++
        $unixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $rem = 30 - ($unixTime % 30)

        # Cap nhat OTP Status
        if (-not [string]::IsNullOrWhiteSpace($cfg.sophos.secret)) {
            $lblOtpVal.Text = "[*] Ma 2FA san sang (Doi sau " + $rem + "s)"
            if ($rem -le 5) {
                $lblOtpVal.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
            } else {
                $lblOtpVal.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
            }
        } else {
            $lblOtpVal.Text = "Khong co 2FA"
            $lblOtpVal.ForeColor = [System.Drawing.Color]::Gray
        }

        # Kiem tra IP Sophos VPN (172.16.x.x)
        if ($script:tickCount % 2 -eq 0) {
            $allIPs = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue)
            $sophosIP = $allIPs | Where-Object { $_.IPAddress -like "172.16.*" }
            if ($sophosIP) {
                $lblStatusVal.Text = "[*] DA KET NOI AN TOAN"
                $lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
                $lblIpVal.Text = $sophosIP[0].IPAddress
                $lblIpVal.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
                $trayIcon.Text = "Sophos VPN: Da ket noi (" + $sophosIP[0].IPAddress + ")"
            } else {
                $lblStatusVal.Text = "[o] Chua ket noi"
                $lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
                $lblIpVal.Text = "---.---.---.---"
                $lblIpVal.ForeColor = [System.Drawing.Color]::FromArgb(107, 114, 128)
                $trayIcon.Text = "Sophos VPN: Chua ket noi"
            }
        }
    } catch {}
})
$timer.Start()

# --- DIALOG CAI DAT THONG TIN TAI KHOAN ---
function Show-ConfigDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Cai Dat Tai Khoan Sophos VPN"
    $dlg.Size = New-Object System.Drawing.Size(430, 270)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.BackColor = [System.Drawing.Color]::FromArgb(248, 250, 252)

    $l1u = New-Object System.Windows.Forms.Label; $l1u.Text = "Ten tai khoan:"; $l1u.Location = "20,25"; $l1u.Size = "110,20"; $l1u.Font = New-Object System.Drawing.Font("Segoe UI", 9); $dlg.Controls.Add($l1u)
    $t1u = New-Object System.Windows.Forms.TextBox; $t1u.Location = "140,22"; $t1u.Size = "245,23"; $t1u.Text = $cfg.sophos.username; $dlg.Controls.Add($t1u)

    $l1p = New-Object System.Windows.Forms.Label; $l1p.Text = "Mat khau:"; $l1p.Location = "20,65"; $l1p.Size = "110,20"; $l1p.Font = New-Object System.Drawing.Font("Segoe UI", 9); $dlg.Controls.Add($l1p)
    $t1p = New-Object System.Windows.Forms.TextBox; $t1p.Location = "140,62"; $t1p.Size = "245,23"; $t1p.Text = $cfg.sophos.password; $t1p.PasswordChar = '*'; $dlg.Controls.Add($t1p)

    $l1s = New-Object System.Windows.Forms.Label; $l1s.Text = "Secret Key (OTP):"; $l1s.Location = "20,105"; $l1s.Size = "110,20"; $l1s.Font = New-Object System.Drawing.Font("Segoe UI", 9); $dlg.Controls.Add($l1s)
    $t1s = New-Object System.Windows.Forms.TextBox; $t1s.Location = "140,102"; $t1s.Size = "245,23"; $t1s.Text = $cfg.sophos.secret; $t1s.PasswordChar = '*'; $dlg.Controls.Add($t1s)

    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "LUU CAU HINH"
    $btnSave.Location = "140,155"; $btnSave.Size = "150,36"
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
    $btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSave.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnSave.Add_Click({
        $cfg.sophos.username = $t1u.Text.Trim()
        $cfg.sophos.password = $t1p.Text.Trim()
        $cfg.sophos.secret = $t1s.Text.Trim()

        Save-Config $cfg
        $lblAccVal.Text = $cfg.sophos.username
        Log-Msg "[OK] Da luu thong tin tai khoan thanh cong!"
        $dlg.Close()
    })
    $dlg.Controls.Add($btnSave)
    $dlg.ShowDialog()
}

Log-Msg "Ung dung Sophos SSL VPN da san sang."
Log-Msg "Tai khoan hien tai: $($cfg.sophos.username)"
Log-Msg "Bam '>> DANG NHAP VPN' de ket noi."

# Khoi chay GUI
[System.Windows.Forms.Application]::Run($form)
