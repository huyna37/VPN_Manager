# ==============================================================================
# UNG DUNG DANG NHAP SOPHOS SSL VPN (SIMPLE LOGIN)
# Giao dien Popup Dang nhap truc tiep - An 100% tinh nang sao chep mat khau
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
if (-not (Test-Path $openvpnExe)) {
    $openvpnExe = "C:\Program Files (x86)\OpenVPN\bin\openvpn.exe"
}
$openvpnGuiExe = "C:\Program Files\OpenVPN\bin\openvpn-gui.exe"
if (-not (Test-Path $openvpnGuiExe)) {
    $openvpnGuiExe = "C:\Program Files (x86)\OpenVPN\bin\openvpn-gui.exe"
}

$userOpenVpnDir = Join-Path $env:USERPROFILE "OpenVPN\config"
if (-not (Test-Path $userOpenVpnDir)) {
    try { New-Item -ItemType Directory -Path $userOpenVpnDir -Force | Out-Null } catch {}
}

# Dong bo duong dan cau hinh OpenVPN GUI
try {
    $hkcuGui = "HKCU:\Software\OpenVPN-GUI"
    if (-not (Test-Path $hkcuGui)) { New-Item -Path $hkcuGui -Force | Out-Null }
    Set-ItemProperty -Path $hkcuGui -Name "config_dir" -Value $userOpenVpnDir -Type String -Force -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $hkcuGui -Name "silent_connection" -Value "0" -Type String -Force -ErrorAction SilentlyContinue
} catch {}

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

# Tinh TOTP 6 so tu Secret Key Base32 (Chuan RFC 6238)
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
    
    $hmac = New-Object System.Security.Cryptography.HMACSHA1 -ArgumentList (,$key)
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

# Ham ghi log he thong / UI
function Log-Status([string]$msg) {
    $time = (Get-Date).ToString("HH:mm:ss")
    $logLine = "[$time] $msg"
    try {
        if ($lblStatusHint -and -not $lblStatusHint.IsDisposed) {
            $lblStatusHint.Text = $msg
        }
        if ($txtLog -and -not $txtLog.IsDisposed) {
            $txtLog.AppendText("$logLine`r`n")
            $txtLog.SelectionStart = $txtLog.Text.Length
            $txtLog.ScrollToCaret()
            return
        }
    } catch {}
    Write-Host $logLine
}

# Ham ket noi Sophos SSL VPN
function Start-SophosConnect {
    param(
        [string]$CustomUser = "",
        [string]$CustomPass = "",
        [string]$CustomSecret = ""
    )

    $c = Load-Config
    $prof = $c.sophos
    if (-not $prof) {
        Log-Status "[-] LOI: Khong tim thay cau hinh Sophos trong vpn_config.json!"
        return $false
    }

    $username = if ($CustomUser) { $CustomUser } else { $prof.username }
    $password = if ($CustomPass) { $CustomPass } else { $prof.password }
    $secret = if ($CustomSecret) { $CustomSecret } else { $prof.secret }
    $dir = $prof.dir
    $ovpnFile = $prof.ovpnFile
    $configName = if ($prof.configName) { $prof.configName } else { "sophos" }

    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        Log-Status "[-] Vui long nhap day du Tai khoan va Mat khau!"
        [System.Windows.Forms.MessageBox]::Show("Vui long nhap day du Tai khoan va Mat khau de dang nhap!", "Sophos VPN", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }

    Log-Status "Dang khoi tao ket noi Sophos SSL VPN..."

    # Ngat tien trinh openvpn cu neu dang chay
    Stop-Process -Name "openvpn" -Force -ErrorAction SilentlyContinue

    # Tinh ma OTP tu dong
    $otp = ""
    if (-not [string]::IsNullOrWhiteSpace($secret)) {
        $otp = Get-TOTP -SecretKey $secret
        Log-Status "-> Da xac thuc sinh ma 2FA OTP thanh cong."
    }
    $fullPass = if ($otp) { "$password$otp" } else { $password }

    $srcDir = Get-Absolute-Path $dir
    $ovpnSrcFile = Join-Path $srcDir $ovpnFile
    if (-not (Test-Path $ovpnSrcFile)) {
        $ovpnSrcFile = Join-Path $baseDir "config\sophos\sophos.ovpn"
    }

    if (-not (Test-Path $ovpnSrcFile)) {
        Log-Status "[-] LOI: Khong tim thay file cau hinh sophos.ovpn!"
        [System.Windows.Forms.MessageBox]::Show("Khong tim thay file cau hinh sophos.ovpn tai: $ovpnSrcFile", "Loi cau hinh", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }

    # Ghi file xac thuc tam thoi vao OpenVPN user config
    $targetAuth = Join-Path $userOpenVpnDir "${configName}_auth.txt"
    $targetOvpn = Join-Path $userOpenVpnDir "${configName}.ovpn"
    Set-Content -Path $targetAuth -Value @($username, $fullPass) -Encoding ASCII

    # Sao chep file .ovpn va chen duong dan tuyet doi toi file auth
    $ovpnContent = Get-Content -Path $ovpnSrcFile -Raw
    $escapedAuth = ($targetAuth -replace '\\', '/')
    $ovpnContent = $ovpnContent -replace "(?m)^auth-user-pass.*$", "auth-user-pass `"$escapedAuth`""
    if ($ovpnContent -notmatch "auth-user-pass") {
        $ovpnContent += "`r`nauth-user-pass `"$escapedAuth`""
    }
    Set-Content -Path $targetOvpn -Value $ovpnContent -Encoding UTF8

    # Dong thoi ghi vao thu muc he thong OpenVPN neu co quyen
    $sysConfigDir = "C:\Program Files\OpenVPN\config"
    if (Test-Path $sysConfigDir) {
        try {
            Set-Content -Path (Join-Path $sysConfigDir "${configName}_auth.txt") -Value @($username, $fullPass) -Encoding ASCII -ErrorAction SilentlyContinue
            Set-Content -Path (Join-Path $sysConfigDir "${configName}.ovpn") -Value $ovpnContent -Encoding UTF8 -ErrorAction SilentlyContinue
        } catch {}
    }

    $started = $false

    # 1. Mo OpenVPN GUI de hien thi bieu tuong khay he thong
    if (Test-Path $openvpnGuiExe) {
        $guiProc = Get-Process -Name "openvpn-gui" -ErrorAction SilentlyContinue
        if (-not $guiProc) {
            Start-Process -FilePath $openvpnGuiExe -WorkingDirectory $userOpenVpnDir -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 800
        }
        # Gui lenh connect toi OpenVPN GUI
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command connect ${configName}.ovpn" -WorkingDirectory $userOpenVpnDir -ErrorAction SilentlyContinue
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command connect $configName" -WorkingDirectory $userOpenVpnDir -ErrorAction SilentlyContinue
        Log-Status "[OK] Da gui yeu cau dang nhap toi OpenVPN!"
        $started = $true
    }

    # 2. Khoi chay OpenVPN CLI ngam de dam bao luon ket noi 100%
    Start-Sleep -Milliseconds 1200
    $ovpnProc = Get-Process -Name "openvpn" -ErrorAction SilentlyContinue
    if (-not $ovpnProc -and (Test-Path $openvpnExe)) {
        Start-Process -FilePath $openvpnExe -ArgumentList "--config `"$targetOvpn`"" -WorkingDirectory $userOpenVpnDir -WindowStyle Hidden -ErrorAction SilentlyContinue
        Log-Status "[OK] Da khoi chay ket noi OpenVPN thanh cong!"
        $started = $true
    }

    if (-not $started) {
        Log-Status "[-] LOI: Khong tim thay OpenVPN tren he thong!"
        [System.Windows.Forms.MessageBox]::Show("Khong tim thay OpenVPN tren may tinh!`nVui long cai dat OpenVPN truoc khi ket noi.", "Loi OpenVPN", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }

    return $true
}

# Ham ngat ket noi
function Stop-SophosDisconnect {
    Log-Status "Dang ngat ket noi Sophos SSL VPN..."

    if (Test-Path $openvpnGuiExe) {
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect_all" -ErrorAction SilentlyContinue
    }

    Stop-Process -Name "openvpn" -Force -ErrorAction SilentlyContinue
    Clean-AuthFiles
    Log-Status "[OK] Da ngat ket noi va don dep phien lam viec an toan."
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

# --- GIAO DIEN POPUP DANG NHAP SOPHOS VPN (SIMPLE & MODERN LOGIN FORM) ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "Dang Nhap Sophos SSL VPN"
$form.Size = New-Object System.Drawing.Size(430, 520)
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
$pnlHeader.Size = New-Object System.Drawing.Size(430, 65)
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(15, 45, 80)
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "SOPHOS SSL VPN"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(18, 10)
$lblTitle.Size = New-Object System.Drawing.Size(380, 24)
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "Dang nhap ket noi mang noi bo an toan"
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(186, 215, 248)
$lblSub.Location = New-Object System.Drawing.Point(20, 36)
$lblSub.Size = New-Object System.Drawing.Size(380, 20)
$pnlHeader.Controls.Add($lblSub)

# Card Form Dang Nhap
$pnlCard = New-Object System.Windows.Forms.Panel
$pnlCard.Location = New-Object System.Drawing.Point(18, 78)
$pnlCard.Size = New-Object System.Drawing.Size(378, 175)
$pnlCard.BackColor = [System.Drawing.Color]::White
$pnlCard.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($pnlCard)

# Field 1: Tai khoan
$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Text = "Tai khoan:"
$lblUser.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblUser.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$lblUser.Location = New-Object System.Drawing.Point(15, 16)
$lblUser.Size = New-Object System.Drawing.Size(95, 20)
$pnlCard.Controls.Add($lblUser)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(120, 14)
$txtUser.Size = New-Object System.Drawing.Size(235, 24)
$txtUser.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$txtUser.Text = $cfg.sophos.username
$pnlCard.Controls.Add($txtUser)

# Field 2: Mat khau (PasswordChar = '*')
$lblPass = New-Object System.Windows.Forms.Label
$lblPass.Text = "Mat khau:"
$lblPass.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblPass.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$lblPass.Location = New-Object System.Drawing.Point(15, 52)
$lblPass.Size = New-Object System.Drawing.Size(95, 20)
$pnlCard.Controls.Add($lblPass)

$txtPass = New-Object System.Windows.Forms.TextBox
$txtPass.Location = New-Object System.Drawing.Point(120, 50)
$txtPass.Size = New-Object System.Drawing.Size(235, 24)
$txtPass.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$txtPass.PasswordChar = '*'
$txtPass.Text = $cfg.sophos.password
$pnlCard.Controls.Add($txtPass)

# Field 3: Secret Key 2FA (PasswordChar = '*')
$lblSecret = New-Object System.Windows.Forms.Label
$lblSecret.Text = "Secret Key:"
$lblSecret.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$lblSecret.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$lblSecret.Location = New-Object System.Drawing.Point(15, 88)
$lblSecret.Size = New-Object System.Drawing.Size(95, 20)
$pnlCard.Controls.Add($lblSecret)

$txtSecret = New-Object System.Windows.Forms.TextBox
$txtSecret.Location = New-Object System.Drawing.Point(120, 86)
$txtSecret.Size = New-Object System.Drawing.Size(235, 24)
$txtSecret.Font = New-Object System.Drawing.Font("Segoe UI", 9.5)
$txtSecret.PasswordChar = '*'
$txtSecret.Text = $cfg.sophos.secret
$pnlCard.Controls.Add($txtSecret)

# Checkbox Ghi nho & Trang thai 2FA
$chkSave = New-Object System.Windows.Forms.CheckBox
$chkSave.Text = "Ghi nho mat khau"
$chkSave.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$chkSave.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$chkSave.Location = New-Object System.Drawing.Point(120, 120)
$chkSave.Size = New-Object System.Drawing.Size(130, 22)
$chkSave.Checked = $true
$pnlCard.Controls.Add($chkSave)

$lblOtpBadge = New-Object System.Windows.Forms.Label
$lblOtpBadge.Text = "● 2FA Auto"
$lblOtpBadge.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$lblOtpBadge.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtpBadge.Location = New-Object System.Drawing.Point(260, 122)
$lblOtpBadge.Size = New-Object System.Drawing.Size(95, 20)
$lblOtpBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$pnlCard.Controls.Add($lblOtpBadge)

# Panel Trang thai ket noi
$pnlStatus = New-Object System.Windows.Forms.Panel
$pnlStatus.Location = New-Object System.Drawing.Point(18, 260)
$pnlStatus.Size = New-Object System.Drawing.Size(378, 38)
$pnlStatus.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$pnlStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($pnlStatus)

$lblStatusVal = New-Object System.Windows.Forms.Label
$lblStatusVal.Text = "[o] Chua ket noi"
$lblStatusVal.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblStatusVal.Location = New-Object System.Drawing.Point(10, 8)
$lblStatusVal.Size = New-Object System.Drawing.Size(355, 20)
$pnlStatus.Controls.Add($lblStatusVal)

# NUT BAM DANG NHAP (PRIMARY)
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = ">> DANG NHAP VPN"
$btnConnect.Font = New-Object System.Drawing.Font("Segoe UI", 11, [System.Drawing.FontStyle]::Bold)
$btnConnect.Location = New-Object System.Drawing.Point(18, 308)
$btnConnect.Size = New-Object System.Drawing.Size(235, 42)
$btnConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnConnect.ForeColor = [System.Drawing.Color]::White
$btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnConnect.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnConnect)

# NUT BAM NGAT KET NOI
$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "[X] NGAT"
$btnDisconnect.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnDisconnect.Location = New-Object System.Drawing.Point(260, 308)
$btnDisconnect.Size = New-Object System.Drawing.Size(136, 42)
$btnDisconnect.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
$btnDisconnect.ForeColor = [System.Drawing.Color]::White
$btnDisconnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDisconnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnDisconnect.FlatAppearance.BorderSize = 0
$form.Controls.Add($btnDisconnect)

# KHUNG NHAT KY NHO
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(18, 360)
$txtLog.Size = New-Object System.Drawing.Size(378, 105)
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
$mItemLogin.Add_Click({
    $btnConnect.PerformClick()
})
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

$form.Add_FormClosing({
    param($sender, $e)
    if ($e.CloseReason -eq [System.Windows.Forms.CloseReason]::UserClosing) {
        $e.Cancel = $true
        $form.Hide()
    }
})

# Enter key trigger login
$txtPass.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $btnConnect.PerformClick()
    }
})
$txtUser.Add_KeyDown({
    param($s, $e)
    if ($e.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
        $txtPass.Focus()
    }
})

# --- SU KIEN NUT BAM ---
$btnConnect.Add_Click({
    $u = $txtUser.Text.Trim()
    $p = $txtPass.Text.Trim()
    $s = $txtSecret.Text.Trim()

    if ($chkSave.Checked) {
        $cfg.sophos.username = $u
        $cfg.sophos.password = $p
        $cfg.sophos.secret = $s
        Save-Config $cfg
    }

    Start-SophosConnect -CustomUser $u -CustomPass $p -CustomSecret $s
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

        # Cap nhat badge 2FA
        $curSec = $txtSecret.Text.Trim()
        if (-not [string]::IsNullOrWhiteSpace($curSec)) {
            $lblOtpBadge.Text = "● 2FA (" + $rem + "s)"
            if ($rem -le 5) {
                $lblOtpBadge.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
            } else {
                $lblOtpBadge.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
            }
        } else {
            $lblOtpBadge.Text = "Khong co 2FA"
            $lblOtpBadge.ForeColor = [System.Drawing.Color]::Gray
        }

        # Kiem tra tien trinh OpenVPN va IP ket noi
        if ($script:tickCount % 2 -eq 0) {
            $ovpnProc = Get-Process -Name "openvpn" -ErrorAction SilentlyContinue
            $allIPs = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue)
            $sophosIP = $allIPs | Where-Object { 
                ($_.IPAddress -like "172.16.*" -or $_.InterfaceAlias -like "*OpenVPN*") -and $_.IPAddress -ne "127.0.0.1"
            }

            if ($sophosIP) {
                $lblStatusVal.Text = "[*] DA KET NOI (" + $sophosIP[0].IPAddress + ")"
                $lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
                $trayIcon.Text = "Sophos VPN: Da ket noi (" + $sophosIP[0].IPAddress + ")"
            } elseif ($ovpnProc) {
                $lblStatusVal.Text = "[~] Dang xac thuc & ket noi..."
                $lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(202, 138, 4)
                $trayIcon.Text = "Sophos VPN: Dang ket noi..."
            } else {
                $lblStatusVal.Text = "[o] Chua ket noi"
                $lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
                $trayIcon.Text = "Sophos VPN: Chua ket noi"
            }
        }
    } catch {}
})
$timer.Start()

Log-Status "Ung dung Sophos SSL VPN da san sang."
Log-Status "Bam '>> DANG NHAP VPN' de ket noi."

# Khoi chay GUI
[System.Windows.Forms.Application]::Run($form)
