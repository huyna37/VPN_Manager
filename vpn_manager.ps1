# ==============================================================================
# UNG DUNG VPN MANAGER (SOPHOS SSL VPN & FORTICLIENT OFFICE SSO)
# Giao dien hien dai - Ho tro dang nhap tu dong & Nap profile vao Registry
# Giu nguyen cau hinh & Registry vinh vien khi tat ung dung
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
        forti_office = [PSCustomObject]@{
            enabled = $true
            name = "FortiClient (Office SSO)"
            tunnelName = "Office"
            server = "118.70.184.195:4443"
            servercert = "pin-sha256:7/VKi6b/toR0oi4GostxJ6homRPtXwDw44uT/Myh41o="
            sso = $true
            useExternalBrowser = $true
            exePath = "C:\Program Files\Fortinet\FortiClient\FortiClient.exe"
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

# Nap cau hinh FortiClient Office SSO vao Registry may tinh (Luu giu lau dai tren he thong)
function Register-FortiTunnels {
    param([bool]$verboseLog = $true)
    $regSuccess = $false
    try {
        $c = Load-Config
        $officeServer = if ($c.forti_office -and $c.forti_office.server) { $c.forti_office.server } else { "118.70.184.195:4443" }

        # Dam bao cac khoa goc cua FortiClient ton tai
        $hkcuRoot = "HKCU:\SOFTWARE\Fortinet\FortiClient"
        if (-not (Test-Path $hkcuRoot)) { New-Item -Path $hkcuRoot -Force | Out-Null }
        Set-ItemProperty -Path $hkcuRoot -Name "installed" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuRoot -Name "TraceLog" -Value 0 -Type DWord -ErrorAction SilentlyContinue

        $hkcuSettings = "HKCU:\SOFTWARE\Fortinet\FortiClient\FA_SETTINGS"
        if (-not (Test-Path $hkcuSettings)) { New-Item -Path $hkcuSettings -Force | Out-Null }
        Set-ItemProperty -Path $hkcuSettings -Name "installed" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuSettings -Name "enabled" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuSettings -Name "logenabled" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuSettings -Name "loglevel" -Value 6 -Type DWord -ErrorAction SilentlyContinue

        # Profile Office (SSO SAML qua trinh duyet)
        $hkcuOffice = "HKCU:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Office"
        if (-not (Test-Path $hkcuOffice)) { New-Item -Path $hkcuOffice -Force | Out-Null }
        Set-ItemProperty -Path $hkcuOffice -Name "Description" -Value "" -Type String -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "Server" -Value $officeServer -Type String -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "ServerSorted" -Value $officeServer -Type String -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "sso_enabled" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "use_external_browser" -Value 1 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "azure_auto_login" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "ServerCert" -Value "1" -Type String -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "promptusername" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "promptcertificate" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "dual_stack" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "SavePass" -Value 0 -Type DWord -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuOffice -Name "DATA3" -Value "" -Type String -ErrorAction SilentlyContinue

        # Mac dinh chon Profile Office lam ket noi hien tai trong FortiClient
        $hkcuFaVpn = "HKCU:\SOFTWARE\Fortinet\FortiClient\FA_VPN"
        if (-not (Test-Path $hkcuFaVpn)) { New-Item -Path $hkcuFaVpn -Force | Out-Null }
        Set-ItemProperty -Path $hkcuFaVpn -Name "connection" -Value "Office" -Type String -ErrorAction SilentlyContinue
        Set-ItemProperty -Path $hkcuFaVpn -Name "vpntype" -Value 2 -Type DWord -ErrorAction SilentlyContinue

        # Ghi them vao HKLM neu he thong cho phep
        $hklmWrote = $false
        try {
            $hklmOffice = "HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Office"
            if (-not (Test-Path $hklmOffice)) { New-Item -Path $hklmOffice -Force -ErrorAction Stop | Out-Null }
            Set-ItemProperty -Path $hklmOffice -Name "Description" -Value "" -Type String -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "Server" -Value $officeServer -Type String -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "ServerSorted" -Value $officeServer -Type String -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "sso_enabled" -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "use_external_browser" -Value 1 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "azure_auto_login" -Value 0 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "ServerCert" -Value "1" -Type String -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "promptusername" -Value 0 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "promptcertificate" -Value 0 -Type DWord -ErrorAction Stop
            Set-ItemProperty -Path $hklmOffice -Name "dual_stack" -Value 0 -Type DWord -ErrorAction Stop
            $hklmWrote = $true
        } catch {
            $hklmWrote = $false
        }

        # Import file .reg neu co
        $officeReg = Join-Path $baseDir "config\forti\FortiClient_Office_SSO.reg"
        if (-not (Test-Path $officeReg)) {
            $officeReg = Join-Path $env:TEMP "FortiClient_Office_SSO.reg"
        }
        if (Test-Path $officeReg) {
            Start-Process -FilePath "reg.exe" -ArgumentList "import `"$officeReg`"" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        }

        $regSuccess = $true
        if ($verboseLog) {
            Log-Status "[OK REGISTRY] Đã nạp cấu hình FortiClient Office SSO vào Registry!"
        }
    } catch {
        if ($verboseLog) {
            Log-Status "[-] Cảnh báo Registry: $($_.Exception.Message)"
        }
    }
    return $regSuccess
}

# Helper ket noi / mo FortiClient Office SSO
function Connect-FortiOffice {
    Log-Status "-------------------------------------------"
    Log-Status "Đang khởi chạy FortiClient Office (SSO SAML)..."

    # 1. Tu dong dong bo cau hinh vao Registry
    Register-FortiTunnels -verboseLog $false | Out-Null
    Log-Status "-> Đã đồng bộ tunnel 'Office' vào Registry (Gateway: 118.70.184.195:4443)."

    # 2. Tim kiem FortiClient.exe tren he thong
    $c = Load-Config
    $fortiExe = if ($c.forti_office -and $c.forti_office.exePath) { $c.forti_office.exePath } else { "C:\Program Files\Fortinet\FortiClient\FortiClient.exe" }
    if (-not (Test-Path $fortiExe)) {
        $fortiExe = "C:\Program Files\Fortinet\FortiClient\FortiClient.exe"
    }
    if (-not (Test-Path $fortiExe)) {
        $fortiExe = "C:\Program Files (x86)\Fortinet\FortiClient\FortiClient.exe"
    }

    if (Test-Path $fortiExe) {
        Stop-Process -Name "FortiClient" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 400

        $fortiDir = Split-Path -Path $fortiExe -Parent
        Start-Process -FilePath $fortiExe -WorkingDirectory $fortiDir -ErrorAction SilentlyContinue
        Log-Status "[OK] Đã mở FortiClient. Hãy chọn profile 'Office' và bấm SAML Login!"
    } else {
        Log-Status "[!] Lưu ý: Chưa tìm thấy FortiClient.exe tại đường dẫn mặc định."
        Log-Status "-> Đã nạp cấu hình Registry sẵn sàng. Hãy cài đặt FortiClient trên máy để sử dụng."
        [System.Windows.Forms.MessageBox]::Show("Đã nạp cấu hình Office vào Registry thành công!`nTuy nhiên chưa tìm thấy FortiClient.exe trên máy. Vui lòng cài đặt FortiClient để kết nối.", "FortiClient Office SSO", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
}

# Ham ghi log he thong / UI
function Log-Status([string]$msg) {
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
        Log-Status "[-] LỖI: Không tìm thấy cấu hình Sophos trong vpn_config.json!"
        return $false
    }

    $username = if ($CustomUser) { $CustomUser } else { $prof.username }
    $password = if ($CustomPass) { $CustomPass } else { $prof.password }
    $secret = if ($CustomSecret) { $CustomSecret } else { $prof.secret }
    $dir = $prof.dir
    $ovpnFile = $prof.ovpnFile
    $configName = if ($prof.configName) { $prof.configName } else { "sophos" }

    if ([string]::IsNullOrWhiteSpace($username) -or [string]::IsNullOrWhiteSpace($password)) {
        Log-Status "[-] Vui lòng nhập đầy đủ Tài khoản và Mật khẩu!"
        [System.Windows.Forms.MessageBox]::Show("Vui lòng nhập đầy đủ Tài khoản và Mật khẩu để đăng nhập!", "Sophos VPN", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return $false
    }

    Log-Status "Đang khởi tạo kết nối Sophos SSL VPN..."

    # Ngat tien trinh openvpn cu neu dang chay
    Stop-Process -Name "openvpn" -Force -ErrorAction SilentlyContinue

    # Tinh ma OTP tu dong
    $otp = ""
    if (-not [string]::IsNullOrWhiteSpace($secret)) {
        $otp = Get-TOTP -SecretKey $secret
        Log-Status "-> Đã sinh mã 2FA OTP tự động."
    }
    $fullPass = if ($otp) { "$password$otp" } else { $password }

    $srcDir = Get-Absolute-Path $dir
    $ovpnSrcFile = Join-Path $srcDir $ovpnFile
    if (-not (Test-Path $ovpnSrcFile)) {
        $ovpnSrcFile = Join-Path $baseDir "config\sophos\sophos.ovpn"
    }

    if (-not (Test-Path $ovpnSrcFile)) {
        Log-Status "[-] LỖI: Không tìm thấy file cấu hình sophos.ovpn!"
        [System.Windows.Forms.MessageBox]::Show("Không tìm thấy file cấu hình sophos.ovpn tại: $ovpnSrcFile", "Lỗi cấu hình", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
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
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command connect ${configName}.ovpn" -WorkingDirectory $userOpenVpnDir -ErrorAction SilentlyContinue
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command connect $configName" -WorkingDirectory $userOpenVpnDir -ErrorAction SilentlyContinue
        Log-Status "[OK] Đã gửi yêu cầu đăng nhập tới OpenVPN GUI!"
        $started = $true
    }

    # 2. Khoi chay OpenVPN CLI ngam de dam bao luon ket noi 100%
    Start-Sleep -Milliseconds 1200
    $ovpnProc = Get-Process -Name "openvpn" -ErrorAction SilentlyContinue
    if (-not $ovpnProc -and (Test-Path $openvpnExe)) {
        Start-Process -FilePath $openvpnExe -ArgumentList "--config `"$targetOvpn`"" -WorkingDirectory $userOpenVpnDir -WindowStyle Hidden -ErrorAction SilentlyContinue
        Log-Status "[OK] Đã khởi chạy kết nối OpenVPN thành công!"
        $started = $true
    }

    if (-not $started) {
        Log-Status "[-] LỖI: Không tìm thấy OpenVPN trên hệ thống!"
        [System.Windows.Forms.MessageBox]::Show("Không tìm thấy OpenVPN trên máy tính!`nVui lòng cài đặt OpenVPN trước khi kết nối.", "Lỗi OpenVPN", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        return $false
    }

    return $true
}

# Ham ngat ket noi Sophos
function Stop-SophosDisconnect {
    Log-Status "Đang ngắt kết nối Sophos SSL VPN..."

    if (Test-Path $openvpnGuiExe) {
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect_all" -ErrorAction SilentlyContinue
    }

    Stop-Process -Name "openvpn" -Force -ErrorAction SilentlyContinue
    Log-Status "[OK] Đã ngắt kết nối Sophos SSL VPN."
}

# Ham ngat toan bo VPN (Khong xoa config tren he thong)
function Stop-AllVPN {
    Log-Status "-------------------------------------------"
    Log-Status "Đang ngắt kết nối TOÀN BỘ VPN..."

    if (Test-Path $openvpnGuiExe) {
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect_all" -ErrorAction SilentlyContinue
    }

    Stop-Process -Name "openvpn", "FortiClient", "FortiTray", "FortiSSLVPNdaemon", "FortiVPN" -Force -ErrorAction SilentlyContinue
    Log-Status "[OK] Đã ngắt toàn bộ kết nối VPN an toàn!"
}

# Xu ly tham so dong lenh (CLI)
if ($Disconnect -or $Action -eq "disconnect") {
    Stop-AllVPN
    exit 0
}

if ($Connect -match "sophos" -or $Action -eq "connect_sophos") {
    Start-SophosConnect
    exit 0
}

if ($Action -eq "reg_office") {
    $ok = Register-FortiTunnels -verboseLog $true
    if ($ok) {
        $fcProcs = Get-Process -Name "FortiClient" -ErrorAction SilentlyContinue
        if ($fcProcs) {
            Stop-Process -Name "FortiClient" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
            $fExe = "C:\Program Files\Fortinet\FortiClient\FortiClient.exe"
            if (Test-Path $fExe) {
                $fDir = Split-Path -Path $fExe -Parent
                Start-Process -FilePath $fExe -WorkingDirectory $fDir -ErrorAction SilentlyContinue
            }
        }
    }
    exit 0
}

if ($Connect -match "office" -or $Action -eq "connect_office") {
    Connect-FortiOffice
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

# --- GIAO DIEN DANG NHAP VPN MANAGER (SOPHOS + FORTICLIENT OFFICE SSO) ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "VPN Manager - Sophos & FortiClient Office SSO"
$form.Size = New-Object System.Drawing.Size(460, 680)
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
$pnlHeader.Size = New-Object System.Drawing.Size(460, 65)
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(15, 45, 80)
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "VPN MANAGER"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12.5, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(18, 10)
$lblTitle.Size = New-Object System.Drawing.Size(410, 24)
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "Hỗ trợ Sophos SSL VPN & FortiClient Office SSO"
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(186, 215, 248)
$lblSub.Location = New-Object System.Drawing.Point(20, 36)
$lblSub.Size = New-Object System.Drawing.Size(410, 20)
$pnlHeader.Controls.Add($lblSub)

# --- GROUP 1: SOPHOS SSL VPN ---
$grpSophos = New-Object System.Windows.Forms.GroupBox
$grpSophos.Text = "  1. Sophos SSL VPN  "
$grpSophos.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$grpSophos.ForeColor = [System.Drawing.Color]::FromArgb(15, 45, 80)
$grpSophos.Location = New-Object System.Drawing.Point(18, 75)
$grpSophos.Size = New-Object System.Drawing.Size(408, 220)
$form.Controls.Add($grpSophos)

# Field 1: Tai khoan
$lblUser = New-Object System.Windows.Forms.Label
$lblUser.Text = "Tài khoản:"
$lblUser.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
$lblUser.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$lblUser.Location = New-Object System.Drawing.Point(15, 25)
$lblUser.Size = New-Object System.Drawing.Size(85, 20)
$grpSophos.Controls.Add($lblUser)

$txtUser = New-Object System.Windows.Forms.TextBox
$txtUser.Location = New-Object System.Drawing.Point(105, 22)
$txtUser.Size = New-Object System.Drawing.Size(285, 23)
$txtUser.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$txtUser.Text = $cfg.sophos.username
$grpSophos.Controls.Add($txtUser)

# Field 2: Mat khau
$lblPass = New-Object System.Windows.Forms.Label
$lblPass.Text = "Mật khẩu:"
$lblPass.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
$lblPass.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$lblPass.Location = New-Object System.Drawing.Point(15, 57)
$lblPass.Size = New-Object System.Drawing.Size(85, 20)
$grpSophos.Controls.Add($lblPass)

$txtPass = New-Object System.Windows.Forms.TextBox
$txtPass.Location = New-Object System.Drawing.Point(105, 54)
$txtPass.Size = New-Object System.Drawing.Size(285, 23)
$txtPass.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$txtPass.PasswordChar = '*'
$txtPass.Text = $cfg.sophos.password
$grpSophos.Controls.Add($txtPass)

# Field 3: Secret Key 2FA
$lblSecret = New-Object System.Windows.Forms.Label
$lblSecret.Text = "Secret 2FA:"
$lblSecret.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular)
$lblSecret.ForeColor = [System.Drawing.Color]::FromArgb(51, 65, 85)
$lblSecret.Location = New-Object System.Drawing.Point(15, 89)
$lblSecret.Size = New-Object System.Drawing.Size(85, 20)
$grpSophos.Controls.Add($lblSecret)

$txtSecret = New-Object System.Windows.Forms.TextBox
$txtSecret.Location = New-Object System.Drawing.Point(105, 86)
$txtSecret.Size = New-Object System.Drawing.Size(285, 23)
$txtSecret.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$txtSecret.PasswordChar = '*'
$txtSecret.Text = $cfg.sophos.secret
$grpSophos.Controls.Add($txtSecret)

# Checkbox Ghi nho & Badge 2FA
$chkSave = New-Object System.Windows.Forms.CheckBox
$chkSave.Text = "Ghi nhớ cấu hình"
$chkSave.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$chkSave.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$chkSave.Location = New-Object System.Drawing.Point(105, 118)
$chkSave.Size = New-Object System.Drawing.Size(140, 22)
$chkSave.Checked = $true
$grpSophos.Controls.Add($chkSave)

$lblOtpBadge = New-Object System.Windows.Forms.Label
$lblOtpBadge.Text = "● 2FA Auto"
$lblOtpBadge.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
$lblOtpBadge.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtpBadge.Location = New-Object System.Drawing.Point(260, 120)
$lblOtpBadge.Size = New-Object System.Drawing.Size(130, 20)
$lblOtpBadge.TextAlign = [System.Drawing.ContentAlignment]::MiddleRight
$grpSophos.Controls.Add($lblOtpBadge)

# NUT DANG NHAP SOPHOS
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = ">> ĐĂNG NHẬP SOPHOS"
$btnConnect.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnConnect.Location = New-Object System.Drawing.Point(15, 155)
$btnConnect.Size = New-Object System.Drawing.Size(250, 36)
$btnConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnConnect.ForeColor = [System.Drawing.Color]::White
$btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnConnect.FlatAppearance.BorderSize = 0
$grpSophos.Controls.Add($btnConnect)

# NUT NGAT SOPHOS
$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "NGẮT"
$btnDisconnect.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnDisconnect.Location = New-Object System.Drawing.Point(275, 155)
$btnDisconnect.Size = New-Object System.Drawing.Size(115, 36)
$btnDisconnect.BackColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
$btnDisconnect.ForeColor = [System.Drawing.Color]::White
$btnDisconnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDisconnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnDisconnect.FlatAppearance.BorderSize = 0
$grpSophos.Controls.Add($btnDisconnect)

# --- GROUP 2: FORTICLIENT OFFICE SSO ---
$grpForti = New-Object System.Windows.Forms.GroupBox
$grpForti.Text = "  2. FortiClient (Office SSO SAML)  "
$grpForti.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$grpForti.ForeColor = [System.Drawing.Color]::FromArgb(15, 45, 80)
$grpForti.Location = New-Object System.Drawing.Point(18, 305)
$grpForti.Size = New-Object System.Drawing.Size(408, 120)
$form.Controls.Add($grpForti)

$lblFortiInfo = New-Object System.Windows.Forms.Label
$lblFortiInfo.Text = "Gateway: 118.70.184.195:4443 | Tunnel: Office (SAML SSO)"
$lblFortiInfo.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Regular)
$lblFortiInfo.ForeColor = [System.Drawing.Color]::FromArgb(71, 85, 105)
$lblFortiInfo.Location = New-Object System.Drawing.Point(15, 24)
$lblFortiInfo.Size = New-Object System.Drawing.Size(375, 20)
$grpForti.Controls.Add($lblFortiInfo)

# NUT NAP CAU HINH FORTI OFFICE VAO REGISTRY
$btnRegOffice = New-Object System.Windows.Forms.Button
$btnRegOffice.Text = "📥 Nạp Forti sang máy này"
$btnRegOffice.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnRegOffice.Location = New-Object System.Drawing.Point(15, 55)
$btnRegOffice.Size = New-Object System.Drawing.Size(185, 36)
$btnRegOffice.BackColor = [System.Drawing.Color]::FromArgb(238, 242, 255)
$btnRegOffice.ForeColor = [System.Drawing.Color]::FromArgb(67, 56, 202)
$btnRegOffice.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRegOffice.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnRegOffice.FlatAppearance.BorderColor = [System.Drawing.Color]::FromArgb(199, 210, 254)
$btnRegOffice.Add_Click({
    $ok = Register-FortiTunnels -verboseLog $true
    if ($ok) {
        $fcProcs = Get-Process -Name "FortiClient" -ErrorAction SilentlyContinue
        if ($fcProcs) {
            Stop-Process -Name "FortiClient" -Force -ErrorAction SilentlyContinue
            Start-Sleep -Milliseconds 400
            $fExe = "C:\Program Files\Fortinet\FortiClient\FortiClient.exe"
            if (Test-Path $fExe) {
                $fDir = Split-Path -Path $fExe -Parent
                Start-Process -FilePath $fExe -WorkingDirectory $fDir -ErrorAction SilentlyContinue
            }
        }
        [System.Windows.Forms.MessageBox]::Show("Đã nạp cấu hình FortiClient Office SSO vào máy tính thành công!`nMở FortiClient và chọn profile 'Office' trong danh sách VPN.", "VPN Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})
$grpForti.Controls.Add($btnRegOffice)

# NUT MO FORTICLIENT SSO
$btnOpenOffice = New-Object System.Windows.Forms.Button
$btnOpenOffice.Text = "🌐 Mở Forti SSO (Browser)"
$btnOpenOffice.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnOpenOffice.Location = New-Object System.Drawing.Point(210, 55)
$btnOpenOffice.Size = New-Object System.Drawing.Size(180, 36)
$btnOpenOffice.BackColor = [System.Drawing.Color]::FromArgb(14, 116, 144)
$btnOpenOffice.ForeColor = [System.Drawing.Color]::White
$btnOpenOffice.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnOpenOffice.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnOpenOffice.FlatAppearance.BorderSize = 0
$btnOpenOffice.Add_Click({
    Connect-FortiOffice
})
$grpForti.Controls.Add($btnOpenOffice)

# Panel Trang thai ket noi tong hop
$pnlStatus = New-Object System.Windows.Forms.Panel
$pnlStatus.Location = New-Object System.Drawing.Point(18, 435)
$pnlStatus.Size = New-Object System.Drawing.Size(408, 40)
$pnlStatus.BackColor = [System.Drawing.Color]::FromArgb(241, 245, 249)
$pnlStatus.BorderStyle = [System.Windows.Forms.BorderStyle]::FixedSingle
$form.Controls.Add($pnlStatus)

$lblStatusVal = New-Object System.Windows.Forms.Label
$lblStatusVal.Text = "[o] Sophos: Chưa kết nối | Office: Chưa kết nối"
$lblStatusVal.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblStatusVal.Location = New-Object System.Drawing.Point(8, 9)
$lblStatusVal.Size = New-Object System.Drawing.Size(390, 20)
$pnlStatus.Controls.Add($lblStatusVal)

# KHUNG NHAT KY NHO
$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(18, 485)
$txtLog.Size = New-Object System.Drawing.Size(408, 140)
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
$trayIcon.Text = "VPN Manager"
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Font = New-Object System.Drawing.Font("Segoe UI", 9)

$mItemLogin = New-Object System.Windows.Forms.ToolStripMenuItem("Đăng nhập Sophos VPN")
$mItemLogin.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemLogin.Add_Click({
    $btnConnect.PerformClick()
})
$trayMenu.Items.Add($mItemLogin) | Out-Null

$mItemReg = New-Object System.Windows.Forms.ToolStripMenuItem("Nạp FortiClient Office SSO")
$mItemReg.Add_Click({
    $btnRegOffice.PerformClick()
})
$trayMenu.Items.Add($mItemReg) | Out-Null

$mItemOffice = New-Object System.Windows.Forms.ToolStripMenuItem("Mở FortiClient SSO (Browser)")
$mItemOffice.Add_Click({
    $btnOpenOffice.PerformClick()
})
$trayMenu.Items.Add($mItemOffice) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemDis = New-Object System.Windows.Forms.ToolStripMenuItem("Ngắt toàn bộ VPN")
$mItemDis.ForeColor = [System.Drawing.Color]::DarkRed
$mItemDis.Add_Click({ Stop-AllVPN })
$trayMenu.Items.Add($mItemDis) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemShow = New-Object System.Windows.Forms.ToolStripMenuItem("Mở Cửa Sổ")
$mItemShow.Add_Click({
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
})
$trayMenu.Items.Add($mItemShow) | Out-Null

$mItemExit = New-Object System.Windows.Forms.ToolStripMenuItem("Thoát")
$mItemExit.Add_Click({
    if ($timer) { $timer.Stop(); $timer.Dispose() }
    if ($trayIcon) { $trayIcon.Visible = $false; $trayIcon.Dispose() }
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

# Enter key triggers
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
            $lblOtpBadge.Text = "Không có 2FA"
            $lblOtpBadge.ForeColor = [System.Drawing.Color]::Gray
        }

        # Kiem tra tien trinh va IP ket noi
        if ($script:tickCount % 2 -eq 0) {
            $allIPs = @(Get-NetIPAddress -AddressFamily IPv4 -AddressState Preferred -ErrorAction SilentlyContinue)
            $sophosIP = $allIPs | Where-Object { 
                ($_.IPAddress -like "172.16.*" -or $_.InterfaceAlias -like "*OpenVPN*") -and $_.IPAddress -ne "127.0.0.1"
            }
            $officeIP = $allIPs | Where-Object { 
                ($_.InterfaceAlias -match "Fortinet|Ethernet 2|Ethernet 3" -or ($_.IPAddress -like "10.*" -and $_.IPAddress -notlike "10.150.*")) -and $_.IPAddress -ne "127.0.0.1"
            }

            $stSophos = if ($sophosIP) { "Sophos: " + $sophosIP[0].IPAddress } else { "Sophos: Chưa kết nối" }
            $stOffice = if ($officeIP) { "Office: " + $officeIP[0].IPAddress } else { "Office: Chưa kết nối" }

            $lblStatusVal.Text = "[*] $stSophos | $stOffice"
            if ($sophosIP -or $officeIP) {
                $lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(22, 163, 74)
                $trayIcon.Text = "VPN Manager | $stSophos | $stOffice"
            } else {
                $lblStatusVal.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
                $trayIcon.Text = "VPN Manager: Chưa kết nối"
            }
        }
    } catch {}
})
$timer.Start()

Log-Status "Ứng dụng VPN Manager đã sẵn sàng."
Log-Status "1. Sophos SSL VPN: Nhập tài khoản & bấm '>> ĐĂNG NHẬP SOPHOS'"
Log-Status "2. FortiClient Office SSO: Bấm '📥 Nạp Forti sang máy này' hoặc '🌐 Mở Forti SSO'"

# Khoi chay GUI
[System.Windows.Forms.Application]::Run($form)
