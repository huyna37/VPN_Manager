# UTF-8 Encoding & WinForms Assemblies
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic

# Tự động ẩn cửa sổ Console đen của PowerShell, chỉ giữ lại Giao diện GUI UI
try {
    $win32 = Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();' -Name "Win32ConsoleHelper" -Namespace "Win32Utils" -PassThru -ErrorAction SilentlyContinue
    if ($win32) {
        $hwnd = $win32::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { $win32::ShowWindow($hwnd, 0) }
    }
} catch {}

# Xác định thư mục ứng dụng & file cấu hình (Động 100% trên mọi máy & EXE)
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

# Đọc & Lưu cấu hình JSON
function Load-Config {
    if (Test-Path $configFile) {
        try { return (Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return $null
}

function Save-Config($cfg) {
    $cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8
}

# Hàm tính TOTP 6 số từ Secret Key Base32
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
    
    $hmac = New-Object System.Security.Cryptography.HMACSHA1
    $hmac.Key = $key
    $hash = $hmac.ComputeHash($stepBytes)
    
    $offset = $hash[$hash.Length - 1] -band 0x0F
    $binary = (($hash[$offset] -band 0x7F) -shl 24) -bor (($hash[$offset + 1] -band 0xFF) -shl 16) -bor (($hash[$offset + 2] -band 0xFF) -shl 8) -bor ($hash[$offset + 3] -band 0xFF)
    return ($binary % 1000000).ToString("D6")
}

$cfg = Load-Config

# --- GIAO DIỆN CHÍNH ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "VPN Multi-Connect Manager"
$form.Size = New-Object System.Drawing.Size(560, 680)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$form.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$form.Add_Shown({
    $form.Activate()
    $form.BringToFront()
})

# Header
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Location = New-Object System.Drawing.Point(0, 0)
$pnlHeader.Size = New-Object System.Drawing.Size(560, 65)
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(20, 70, 120)
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "QUẢN LÝ KẾT NỐI VPN TỰ ĐỘNG (1-CLICK)"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(20, 10)
$lblTitle.Size = New-Object System.Drawing.Size(520, 25)
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "Tự động tạo OTP, kết nối ngầm siêu tốc và hiển thị IP trực tiếp"
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(200, 225, 250)
$lblSub.Location = New-Object System.Drawing.Point(20, 35)
$lblSub.Size = New-Object System.Drawing.Size(520, 20)
$pnlHeader.Controls.Add($lblSub)

# Group Danh sách VPN
$grpVPN = New-Object System.Windows.Forms.GroupBox
$grpVPN.Text = "  Danh Sách VPN & Trạng Thái Trực Tiếp  "
$grpVPN.Location = New-Object System.Drawing.Point(20, 75)
$grpVPN.Size = New-Object System.Drawing.Size(505, 175)
$grpVPN.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($grpVPN)

# Row 1: Sophos SSL VPN
$chk1 = New-Object System.Windows.Forms.CheckBox
$chk1.Text = "1. Sophos SSL VPN"
$chk1.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
$chk1.Location = New-Object System.Drawing.Point(20, 30)
$chk1.Size = New-Object System.Drawing.Size(260, 28)
$chk1.Checked = [bool]$cfg.sophos.enabled
$grpVPN.Controls.Add($chk1)

$lblSt1 = New-Object System.Windows.Forms.Label
$lblSt1.Text = "○ Chưa kết nối"
$lblSt1.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt1.ForeColor = [System.Drawing.Color]::Gray
$lblSt1.Location = New-Object System.Drawing.Point(285, 34)
$lblSt1.Size = New-Object System.Drawing.Size(210, 22)
$grpVPN.Controls.Add($lblSt1)

# Row 2: OpenVPN DR Epay
$chk2 = New-Object System.Windows.Forms.CheckBox
$chk2.Text = "2. OpenVPN (VPN DR Epay)"
$chk2.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
$chk2.Location = New-Object System.Drawing.Point(20, 75)
$chk2.Size = New-Object System.Drawing.Size(260, 28)
$chk2.Checked = [bool]$cfg.openvpn_dr.enabled
$grpVPN.Controls.Add($chk2)

$lblSt2 = New-Object System.Windows.Forms.Label
$lblSt2.Text = "○ Chưa kết nối"
$lblSt2.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt2.ForeColor = [System.Drawing.Color]::Gray
$lblSt2.Location = New-Object System.Drawing.Point(285, 79)
$lblSt2.Size = New-Object System.Drawing.Size(210, 22)
$grpVPN.Controls.Add($lblSt2)

# Row 3: FortiClient
$chk3 = New-Object System.Windows.Forms.CheckBox
$chk3.Text = "3. FortiClient"
$chk3.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Regular)
$chk3.Location = New-Object System.Drawing.Point(20, 120)
$chk3.Size = New-Object System.Drawing.Size(260, 28)
$chk3.Checked = [bool]$cfg.forticlient.enabled
$grpVPN.Controls.Add($chk3)

$lblSt3 = New-Object System.Windows.Forms.Label
$lblSt3.Text = "○ Chưa kết nối"
$lblSt3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt3.ForeColor = [System.Drawing.Color]::Gray
$lblSt3.Location = New-Object System.Drawing.Point(285, 124)
$lblSt3.Size = New-Object System.Drawing.Size(210, 22)
$grpVPN.Controls.Add($lblSt3)

# Nút bấm Kết nối
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = ">> KẾT NỐI ĐÃ CHỌN"
$btnConnect.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnConnect.Location = New-Object System.Drawing.Point(20, 260)
$btnConnect.Size = New-Object System.Drawing.Size(245, 40)
$btnConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnConnect.ForeColor = [System.Drawing.Color]::White
$btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnConnect)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = "★ KẾT NỐI TẤT CẢ"
$btnAll.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnAll.Location = New-Object System.Drawing.Point(280, 260)
$btnAll.Size = New-Object System.Drawing.Size(245, 40)
$btnAll.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnAll.ForeColor = [System.Drawing.Color]::White
$btnAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnAll.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnAll)

# Nút bấm Ngắt & Cài đặt
$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "[X] TẮT TOÀN BỘ VPN"
$btnDisconnect.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnDisconnect.Location = New-Object System.Drawing.Point(20, 308)
$btnDisconnect.Size = New-Object System.Drawing.Size(245, 32)
$btnDisconnect.BackColor = [System.Drawing.Color]::FromArgb(211, 47, 47)
$btnDisconnect.ForeColor = [System.Drawing.Color]::White
$btnDisconnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDisconnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnDisconnect)

$btnConfig = New-Object System.Windows.Forms.Button
$btnConfig.Text = "Cài đặt Tài khoản và Key"
$btnConfig.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnConfig.Location = New-Object System.Drawing.Point(280, 308)
$btnConfig.Size = New-Object System.Drawing.Size(245, 32)
$btnConfig.BackColor = [System.Drawing.Color]::FromArgb(230, 235, 245)
$btnConfig.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$btnConfig.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConfig.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnConfig)

# Nhật ký hiển thị (Log Window)
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Nhật ký kết nối (Chi tiết):"
$lblLog.Location = New-Object System.Drawing.Point(20, 350)
$lblLog.Size = New-Object System.Drawing.Size(200, 18)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 370)
$txtLog.Size = New-Object System.Drawing.Size(505, 255)
$txtLog.Multiline = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(140, 240, 140)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$form.Controls.Add($txtLog)

function Log-Msg([string]$msg) {
    $time = (Get-Date).ToString("HH:mm:ss")
    $txtLog.AppendText("[$time] $msg`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# --- TIMER THEO DÕI TRẠNG THÁI IP TRỰC TIẾP ---
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 2000
$timer.Add_Tick({
    try {
        # 1. Sophos SSL VPN (172.16.x.x)
        $sophosIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match "^172\.16\." -and $_.AddressState -eq "Preferred" }
        if ($sophosIP) {
            $lblSt1.Text = "● ĐÃ KẾT NỐI ($($sophosIP[0].IPAddress))"
            $lblSt1.ForeColor = [System.Drawing.Color]::Green
        } else {
            $lblSt1.Text = "○ Chưa kết nối"
            $lblSt1.ForeColor = [System.Drawing.Color]::Gray
        }

        # 2. OpenVPN DR Epay (10.150.x.x)
        $drIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match "^10\.150\." -and $_.AddressState -eq "Preferred" }
        if ($drIP) {
            $lblSt2.Text = "● ĐÃ KẾT NỐI ($($drIP[0].IPAddress))"
            $lblSt2.ForeColor = [System.Drawing.Color]::Green
        } else {
            $lblSt2.Text = "○ Chưa kết nối"
            $lblSt2.ForeColor = [System.Drawing.Color]::Gray
        }

        # 3. FortiClient (10.x.x.x trên Ethernet 9 / Forti)
        $fortiIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.InterfaceAlias -match "Ethernet 9|Forti|PPP" -and $_.IPAddress -match "^10\." -and $_.AddressState -eq "Preferred" }
        if (-not $fortiIP) {
            $fortiIP = Get-NetIPAddress -InterfaceAlias "Ethernet 9" -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match "^10\." -and $_.AddressState -eq "Preferred" }
        }
        if ($fortiIP) {
            $lblSt3.Text = "● ĐÃ KẾT NỐI ($($fortiIP[0].IPAddress))"
            $lblSt3.ForeColor = [System.Drawing.Color]::Green
        } else {
            $lblSt3.Text = "○ Chưa kết nối"
            $lblSt3.ForeColor = [System.Drawing.Color]::Gray
        }
    } catch {}
})
$timer.Start()

# Helper gửi tín hiệu ngắt kết nối qua OpenVPN Management Port (0 Admin)
function Send-OpenVpnSignal([int]$port, [string]$signal = "SIGTERM") {
    try {
        $client = New-Object System.Net.Sockets.TcpClient
        $asyncResult = $client.BeginConnect("127.0.0.1", $port, $null, $null)
        if ($asyncResult.AsyncWaitHandle.WaitOne(500, $false)) {
            $client.EndConnect($asyncResult)
            $stream = $client.GetStream()
            $writer = New-Object System.IO.StreamWriter($stream)
            $writer.AutoFlush = $true
            $writer.WriteLine("signal $signal")
            Start-Sleep -Milliseconds 200
            $client.Close()
            return $true
        } else {
            $client.Close()
            return $false
        }
    } catch {
        return $false
    }
}

# Helper đồng bộ & kết nối OpenVPN Profile
function Connect-OpenVpnProfile($profileName, $configName, $ovpnSubDir, $ovpnFileName, $username, $password, $secret) {
    Log-Msg "-------------------------------------------"
    Log-Msg "Đang kết nối: $profileName (Tài khoản $username)..."
    $otp = Get-TOTP -SecretKey $secret
    if (-not $otp) {
        Log-Msg "[-] Chưa có Secret Key cho $profileName."
        return
    }
    Log-Msg "-> Mã OTP ${profileName}: $otp"
    $fullPass = "$password$otp"

    # Dọn dẹp các thư mục con trùng lặp trong OpenVPN User Config
    Get-ChildItem -Path $userOpenVpnDir -Directory -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue

    # Đồng bộ file vào thư mục local của VPN_Manager
    $srcDir = Get-Absolute-Path $ovpnSubDir
    Set-Content -Path (Join-Path $srcDir "auth.txt") -Value @($username, $fullPass) -Encoding ASCII

    # Đồng bộ file vào thư mục OpenVPN User Config (Chạy qua Service 0 Admin)
    $targetAuth = Join-Path $userOpenVpnDir "${configName}_auth.txt"
    $targetOvpn = Join-Path $userOpenVpnDir "${configName}.ovpn"
    Set-Content -Path $targetAuth -Value @($username, $fullPass) -Encoding ASCII

    $mgmtPort = if ($configName -eq "sophos") { 7501 } else { 7502 }
    $ovpnContent = Get-Content -Path (Join-Path $srcDir $ovpnFileName) -Raw
    $ovpnContent = $ovpnContent -replace "auth-user-pass.*", "auth-user-pass ${configName}_auth.txt"
    if ($ovpnContent -notmatch "management\s+127\.0\.0\.1") {
        $ovpnContent += "`r`nmanagement 127.0.0.1 $mgmtPort`r`n"
    } else {
        $ovpnContent = $ovpnContent -replace "management\s+127\.0\.0\.1\s+\d+", "management 127.0.0.1 $mgmtPort"
    }
    Set-Content -Path $targetOvpn -Value $ovpnContent -Encoding UTF8

    if (Test-Path $openvpnGuiExe) {
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command connect ${configName}.ovpn" -ErrorAction SilentlyContinue
        Log-Msg "[OK] Đã gửi lệnh kết nối $profileName ngầm (0 Admin)!"
    } else {
        $ovpnPath = Join-Path $srcDir $ovpnFileName
        $logPath = Join-Path $baseDir "${configName}.log"
        Start-Process -FilePath $openvpnExe -ArgumentList "--config `"$ovpnPath`" --auth-user-pass `"$targetAuth`" --log `"$logPath`" --verb 3" -WorkingDirectory $srcDir -WindowStyle Hidden
        Log-Msg "[OK] Đã gửi thông tin đăng nhập $profileName!"
    }
}

# Function ngắt kết nối toàn bộ VPN (Không đóng App)
function Stop-AllVPN {
    Log-Msg "-------------------------------------------"
    Log-Msg "Đang gửi lệnh ngắt kết nối TOÀN BỘ VPN..."

    # 1. Gửi tín hiệu ngắt kết nối SIGTERM qua Management Port cho Sophos (7501) và DR Epay (7502)
    Send-OpenVpnSignal 7501 "SIGTERM" | Out-Null
    Send-OpenVpnSignal 7502 "SIGTERM" | Out-Null

    # 2. Gửi lệnh ngắt kết nối tới OpenVPN GUI Client cho tất cả profile candidate
    if (Test-Path $openvpnGuiExe) {
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect sophos.ovpn" -ErrorAction SilentlyContinue
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect sophos" -ErrorAction SilentlyContinue
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect epay-dr.ovpn" -ErrorAction SilentlyContinue
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect epay-dr" -ErrorAction SilentlyContinue
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect dr-epay-vpn-UDP4-1195-config.ovpn" -ErrorAction SilentlyContinue
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect dr-epay-vpn-UDP4-1195-config" -ErrorAction SilentlyContinue
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect_all" -ErrorAction SilentlyContinue
    }

    # 3. Ép dừng các tiến trình openvpn.exe qua WMI (Hoạt động 100% không cần Admin)
    try {
        Get-WmiObject Win32_Process -Filter "Name = 'openvpn.exe'" -ErrorAction SilentlyContinue | ForEach-Object { $_.Terminate() }
    } catch {}

    # 4. Release IP trên Card mạng OpenVPN TAP
    try { Start-Process -FilePath "ipconfig.exe" -ArgumentList "/release `"OpenVPN TAP-Windows6`"" -WindowStyle Hidden -ErrorAction SilentlyContinue } catch {}

    # 5. Gửi lệnh ngắt FortiClient nếu có CLI
    $cliExe = Join-Path $baseDir "tools\FortiSSLVPNclient.exe"
    if (Test-Path $cliExe) {
        Start-Process -FilePath $cliExe -ArgumentList "disconnect" -WorkingDirectory $baseDir -WindowStyle Hidden -ErrorAction SilentlyContinue
    }

    Log-Msg "[OK] Đã gửi lệnh ngắt kết nối toàn bộ VPN thành công!"
    Log-Msg "[✓] Giao diện quản lý vẫn mở để bạn có thể kết nối lại bất cứ lúc nào."
}

# Function thực thi kết nối các VPN đã chọn
function Do-Connect([bool]$do1, [bool]$do2, [bool]$do3) {


    if ($do1 -or $do2) {
        if (Test-Path $openvpnGuiExe) {
            Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect_all" -ErrorAction SilentlyContinue
        }
        Stop-Process -Name "openvpn" -Force -ErrorAction SilentlyContinue
        Start-Sleep -Milliseconds 300
    }

    # 1. Sophos SSL VPN
    if ($do1) {
        Connect-OpenVpnProfile "1. Sophos SSL VPN" "sophos" $cfg.sophos.dir $cfg.sophos.ovpnFile $cfg.sophos.username $cfg.sophos.password $cfg.sophos.secret
    }

    # 2. OpenVPN DR Epay
    if ($do2) {
        Connect-OpenVpnProfile "2. OpenVPN (VPN DR Epay)" "epay-dr" $cfg.openvpn_dr.dir $cfg.openvpn_dr.ovpnFile $cfg.openvpn_dr.username $cfg.openvpn_dr.password $cfg.openvpn_dr.secret
    }

    # 3. FortiClient
    if ($do3) {
        Log-Msg "-------------------------------------------"
        Log-Msg "Đang kết nối: 3. FortiClient (Tài khoản $($cfg.forticlient.username))..."
        $u = $cfg.forticlient.username
        $p = $cfg.forticlient.password
        
        $cliExe = @(
            (Join-Path $baseDir "tools\FortiSSLVPNclient.exe"),
            (Join-Path $baseDir "FortiSSLVPNclient.exe"),
            "C:\Program Files\Fortinet\FortiClient\FortiSSLVPNclient.exe",
            "C:\Program Files (x86)\Fortinet\FortiClient\FortiSSLVPNclient.exe"
        ) | Where-Object { Test-Path $_ } | Select-Object -First 1

        if ($cliExe) {
            $serverAddr = "14.238.148.196:4443"
            try {
                $regServer = (Get-ItemProperty -Path "HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Production" -Name "Server" -ErrorAction SilentlyContinue).Server
                if (![string]::IsNullOrWhiteSpace($regServer)) { $serverAddr = $regServer }
            } catch {}

            Log-Msg "-> Tìm thấy FortiClient CLI: $cliExe"
            Log-Msg "-> Khởi chạy kết nối ngầm tới $serverAddr..."
            Start-Process -FilePath $cliExe -ArgumentList "connect -h `"$serverAddr`" -u `"${u}:${p}`" -i -m -q" -WorkingDirectory $baseDir -WindowStyle Hidden
            Log-Msg "[OK] Đã gửi lệnh kết nối FortiClient ngầm 1-click qua CLI!"
        } else {
            try {
                Set-ItemProperty -Path "HKCU:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Production" -Name "User" -Value $u -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKCU:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Production" -Name "promptusername" -Value 0 -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKCU:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Production" -Name "save_username" -Value 1 -Force -ErrorAction SilentlyContinue
                Set-ItemProperty -Path "HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Production" -Name "User" -Value $u -Force -ErrorAction SilentlyContinue
            } catch {}

            try { [System.Windows.Forms.Clipboard]::SetText($p) } catch {}

            $fortiGuiExe = "C:\Program Files\Fortinet\FortiClient\FortiGui.exe"
            $fortiExe = "C:\Program Files\Fortinet\FortiClient\FortiClient.exe"
            $targetLauncher = $fortiExe
            if (Test-Path $fortiGuiExe) { $targetLauncher = $fortiGuiExe }

            if (Test-Path $targetLauncher) {
                Start-Process -FilePath $targetLauncher -WorkingDirectory "C:\Program Files\Fortinet\FortiClient\" -ErrorAction SilentlyContinue
                Log-Msg "[OK] Đã bật giao diện FortiClient mượt mà và tự động nạp Tài khoản!"
                Log-Msg "[i] Mật khẩu đã được tự động copy vào Clipboard (Ctrl+V)."
                Log-Msg "[i] Bạn chỉ cần nhấp vào ô Mật khẩu -> dán (Ctrl+V) -> Bấm Connect để hoàn tất kết nối."
            } else {
                Log-Msg "[-] Không tìm thấy FortiClient tại $fortiExe"
            }
        }
    }

    Log-Msg "-------------------------------------------"
    Log-Msg "[✓] HOÀN TẤT GỬI LỆNH KẾT NỐI! Hãy theo dõi trạng thái đèn màu xanh ở trên."
}

# --- SỰ KIỆN NÚT BẤM ---
$btnConnect.Add_Click({ Do-Connect $chk1.Checked $chk2.Checked $chk3.Checked })
$btnAll.Add_Click({
    $chk1.Checked = $true; $chk2.Checked = $true; $chk3.Checked = $true
    Do-Connect $true $true $true
})
$btnDisconnect.Add_Click({ Stop-AllVPN })

# Popup Cài đặt Tài khoản, Mật khẩu & Secret Key
$btnConfig.Add_Click({
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Cài Đặt Đầy Đủ Thông Tin Đăng Nhập & Tùy Chọn Mặc Định"
    $dlg.Size = New-Object System.Drawing.Size(530, 620)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.AutoScroll = $true

    # 1. Sophos SSL VPN
    $grp1 = New-Object System.Windows.Forms.GroupBox
    $grp1.Text = "  1. Sophos SSL VPN  "; $grp1.Location = "15,10"; $grp1.Size = "480,155"
    $grp1.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp1)

    $l1u = New-Object System.Windows.Forms.Label; $l1u.Text = "Tài khoản:"; $l1u.Location = "15,25"; $l1u.Size = "90,20"; $grp1.Controls.Add($l1u)
    $t1u = New-Object System.Windows.Forms.TextBox; $t1u.Location = "110,23"; $t1u.Size = "350,23"; $t1u.Text = $cfg.sophos.username; $grp1.Controls.Add($t1u)

    $l1p = New-Object System.Windows.Forms.Label; $l1p.Text = "Mật khẩu:"; $l1p.Location = "15,55"; $l1p.Size = "90,20"; $grp1.Controls.Add($l1p)
    $t1p = New-Object System.Windows.Forms.TextBox; $t1p.Location = "110,53"; $t1p.Size = "350,23"; $t1p.Text = $cfg.sophos.password; $grp1.Controls.Add($t1p)

    $l1s = New-Object System.Windows.Forms.Label; $l1s.Text = "Secret Key:"; $l1s.Location = "15,85"; $l1s.Size = "90,20"; $grp1.Controls.Add($l1s)
    $t1s = New-Object System.Windows.Forms.TextBox; $t1s.Location = "110,83"; $t1s.Size = "350,23"; $t1s.Text = $cfg.sophos.secret; $grp1.Controls.Add($t1s)

    $c1e = New-Object System.Windows.Forms.CheckBox; $c1e.Text = "Mặc định tích chọn kết nối khi mở phần mềm"; $c1e.Location = "110,118"; $c1e.Size = "350,24"
    $c1e.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular); $c1e.Checked = [bool]$cfg.sophos.enabled; $grp1.Controls.Add($c1e)

    # 2. VPN DR Epay
    $grp2 = New-Object System.Windows.Forms.GroupBox
    $grp2.Text = "  2. OpenVPN (VPN DR Epay)  "; $grp2.Location = "15,175"; $grp2.Size = "480,155"
    $grp2.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp2)

    $l2u = New-Object System.Windows.Forms.Label; $l2u.Text = "Tài khoản:"; $l2u.Location = "15,25"; $l2u.Size = "90,20"; $grp2.Controls.Add($l2u)
    $t2u = New-Object System.Windows.Forms.TextBox; $t2u.Location = "110,23"; $t2u.Size = "350,23"; $t2u.Text = $cfg.openvpn_dr.username; $grp2.Controls.Add($t2u)

    $l2p = New-Object System.Windows.Forms.Label; $l2p.Text = "Mật khẩu:"; $l2p.Location = "15,55"; $l2p.Size = "90,20"; $grp2.Controls.Add($l2p)
    $t2p = New-Object System.Windows.Forms.TextBox; $t2p.Location = "110,53"; $t2p.Size = "350,23"; $t2p.Text = $cfg.openvpn_dr.password; $grp2.Controls.Add($t2p)

    $l2s = New-Object System.Windows.Forms.Label; $l2s.Text = "Secret Key:"; $l2s.Location = "15,85"; $l2s.Size = "90,20"; $grp2.Controls.Add($l2s)
    $t2s = New-Object System.Windows.Forms.TextBox; $t2s.Location = "110,83"; $t2s.Size = "350,23"; $t2s.Text = $cfg.openvpn_dr.secret; $grp2.Controls.Add($t2s)

    $c2e = New-Object System.Windows.Forms.CheckBox; $c2e.Text = "Mặc định tích chọn kết nối khi mở phần mềm"; $c2e.Location = "110,118"; $c2e.Size = "350,24"
    $c2e.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular); $c2e.Checked = [bool]$cfg.openvpn_dr.enabled; $grp2.Controls.Add($c2e)

    # 3. FortiClient
    $grp3 = New-Object System.Windows.Forms.GroupBox
    $grp3.Text = "  3. FortiClient  "; $grp3.Location = "15,340"; $grp3.Size = "480,125"
    $grp3.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp3)

    $l3u = New-Object System.Windows.Forms.Label; $l3u.Text = "Tài khoản:"; $l3u.Location = "15,25"; $l3u.Size = "90,20"; $grp3.Controls.Add($l3u)
    $t3u = New-Object System.Windows.Forms.TextBox; $t3u.Location = "110,23"; $t3u.Size = "350,23"; $t3u.Text = $cfg.forticlient.username; $grp3.Controls.Add($t3u)

    $l3p = New-Object System.Windows.Forms.Label; $l3p.Text = "Mật khẩu:"; $l3p.Location = "15,55"; $l3p.Size = "90,20"; $grp3.Controls.Add($l3p)
    $t3p = New-Object System.Windows.Forms.TextBox; $t3p.Location = "110,53"; $t3p.Size = "350,23"; $t3p.Text = $cfg.forticlient.password; $grp3.Controls.Add($t3p)

    $c3e = New-Object System.Windows.Forms.CheckBox; $c3e.Text = "Mặc định tích chọn kết nối khi mở phần mềm"; $c3e.Location = "110,88"; $c3e.Size = "350,24"
    $c3e.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular); $c3e.Checked = [bool]$cfg.forticlient.enabled; $grp3.Controls.Add($c3e)

    # Nút Lưu Cấu Hình
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "LƯU CẤU HÌNH"; $btnSave.Location = "150,480"; $btnSave.Size = "200,42"
    $btnSave.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
    $btnSave.ForeColor = [System.Drawing.Color]::White
    $btnSave.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $btnSave.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $btnSave.Cursor = [System.Windows.Forms.Cursors]::Hand
    $btnSave.Add_Click({
        $cfg.sophos.username = $t1u.Text.Trim()
        $cfg.sophos.password = $t1p.Text.Trim()
        $cfg.sophos.secret = $t1s.Text.Trim()
        $cfg.sophos.enabled = $c1e.Checked

        $cfg.openvpn_dr.username = $t2u.Text.Trim()
        $cfg.openvpn_dr.password = $t2p.Text.Trim()
        $cfg.openvpn_dr.secret = $t2s.Text.Trim()
        $cfg.openvpn_dr.enabled = $c2e.Checked

        $cfg.forticlient.username = $t3u.Text.Trim()
        $cfg.forticlient.password = $t3p.Text.Trim()
        $cfg.forticlient.enabled = $c3e.Checked

        Save-Config $cfg

        # Đồng bộ trực tiếp về checkbox màn hình chính
        $chk1.Checked = $c1e.Checked
        $chk2.Checked = $c2e.Checked
        $chk3.Checked = $c3e.Checked

        Log-Msg "[+] Đã lưu cấu hình Tài khoản, Mật khẩu & Tùy chọn mặc định thành công!"
        $dlg.Close()
    })
    $dlg.Controls.Add($btnSave)
    $dlg.ShowDialog()
})

Log-Msg "Hệ thống đã sẵn sàng."
Log-Msg "1. Sophos SFOS: Tài khoản $($cfg.sophos.username)"
Log-Msg "2. VPN DR Epay: Tài khoản $($cfg.openvpn_dr.username)"
Log-Msg "3. FortiClient: Tài khoản $($cfg.forticlient.username)"

# Thực thi GUI
[System.Windows.Forms.Application]::Run($form)
