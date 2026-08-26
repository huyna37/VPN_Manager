# Tham so dong lenh ho tro goi tu phim tat hoac bat widget nhanh
param(
    [string]$Copy = "",
    [string]$CopyProfile = ""
)

# UTF-8 Encoding & WinForms Assemblies
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName Microsoft.VisualBasic


# Xac dinh thu muc ung dung & file cau hinh (Dong 100% tren moi may & EXE)
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

# Doc & Luu cau hinh JSON (Mac dinh de trong, doc truc tiep tu file vpn_config.json)
function Get-Default-Config {
    return [PSCustomObject]@{
        sophos = [PSCustomObject]@{
            enabled = $true
            name = "1. Sophos SSL VPN (SFOS)"
            username = "" # Tai khoan cau hinh trong vpn_config.json
            password = "" # Mat khau cau hinh trong vpn_config.json
            secret = ""   # Secret Key TOTP trong vpn_config.json
            dir = "config\sophos"
            configName = "sophos"
            ovpnFile = "sophos.ovpn"
        }
        openvpn_dr = [PSCustomObject]@{
            enabled = $true
            name = "2. OpenVPN (VPN DR Epay)"
            username = "" # Tai khoan cau hinh trong vpn_config.json
            password = "" # Mat khau cau hinh trong vpn_config.json
            secret = ""   # Secret Key TOTP trong vpn_config.json
            dir = "config\epay-dr"
            configName = "epay-dr"
            ovpnFile = "epay-dr.ovpn"
        }
        forticlient = [PSCustomObject]@{
            enabled = $false
            name = "3. FortiClient (Production)"
            username = "" # Tai khoan cau hinh trong vpn_config.json
            password = "" # Mat khau cau hinh trong vpn_config.json
            server = "14.238.148.196:4443"
            servercert = "pin-sha256:zJcknXTR0B49qZAztOTh7VW80yIwZYdPCWwm2mio="
            exePath = "C:\Program Files\Fortinet\FortiClient\FortiClient.exe"
        }
        forti_office = [PSCustomObject]@{
            enabled = $true
            name = "4. FortiClient (Office SSO)"
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
            $parsed = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($parsed) {
                # Bo sung cac truong mac dinh neu file json cu chua co
                $def = Get-Default-Config
                if (-not $parsed.sophos) { $parsed | Add-Member -NotePropertyName "sophos" -NotePropertyValue $def.sophos }
                if (-not $parsed.openvpn_dr) { $parsed | Add-Member -NotePropertyName "openvpn_dr" -NotePropertyValue $def.openvpn_dr }
                if (-not $parsed.forticlient) { $parsed | Add-Member -NotePropertyName "forticlient" -NotePropertyValue $def.forticlient }
                if (-not $parsed.forti_office) { $parsed | Add-Member -NotePropertyName "forti_office" -NotePropertyValue $def.forti_office }
                return $parsed
            }
        } catch {}
    }
    return Get-Default-Config
}

function Save-Config($cfgData) {
    $cfgData | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8
}

# Ham dang ky / dong bo cau hinh FortiClient Office SSO vao Windows Registry
function Register-FortiTunnels {
    param([bool]$verboseLog = $true)
    $regSuccess = $false
    try {
        # Dam bao cac khoa goc cua FortiClient ton tai de tranh loi Electron Logger (TraceLog)
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
        $officeServer = if ($cfg.forti_office.server) { $cfg.forti_office.server } else { "118.70.184.195:4443" }
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

        # Import file .reg cua Office neu co trong config\forti
        $officeReg = Join-Path $baseDir "config\forti\FortiClient_Office_SSO.reg"
        if (Test-Path $officeReg) {
            Start-Process -FilePath "reg.exe" -ArgumentList "import `"$officeReg`"" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        }

        $regSuccess = $true
        if ($verboseLog) {
            Log-Msg "[OK REGISTRY] Da tu dong nap cau hinh FortiClient Office SSO vao may tinh nay!"
        }
    } catch {
        if ($verboseLog) {
            Log-Msg "[-] Canh bao Registry: $($_.Exception.Message)"
        }
    }
    return $regSuccess
}

# Ham xoa bo cau hinh FortiClient Office SSO khoi Windows Registry khi thoat ung dung
function Unregister-FortiTunnels {
    try {
        $hkcuOffice = "HKCU:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Office"
        if (Test-Path $hkcuOffice) {
            Remove-Item -Path $hkcuOffice -Recurse -Force -ErrorAction SilentlyContinue
        }
        $hklmOffice = "HKLM:\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Office"
        if (Test-Path $hklmOffice) {
            Remove-Item -Path $hklmOffice -Recurse -Force -ErrorAction SilentlyContinue
        }
        # Fallback truc tiep bang reg.exe
        Start-Process -FilePath "reg.exe" -ArgumentList "delete `"HKCU\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Office`" /f" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
        Start-Process -FilePath "reg.exe" -ArgumentList "delete `"HKLM\SOFTWARE\Fortinet\FortiClient\Sslvpn\Tunnels\Office`" /f" -WindowStyle Hidden -Wait -ErrorAction SilentlyContinue
    } catch {}
}

# Tu dong dang ky don dep Registry khi tien trinh ket thuc
[System.AppDomain]::CurrentDomain.add_ProcessExit({
    Unregister-FortiTunnels
})

# Ham tinh TOTP 6 so tu Secret Key Base32
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

# Ham hien thi thong bao OSD Toast tu dong dong sau 1.4 giay
function Show-Quick-Toast([string]$title, [string]$passOtp, [string]$otp, [int]$rem) {
    try {
        if (-not [string]::IsNullOrEmpty($passOtp)) {
            [System.Windows.Forms.Clipboard]::SetText($passOtp)
        }

        $toast = New-Object System.Windows.Forms.Form
        $toast.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
        $toast.TopMost = $true
        $toast.ShowInTaskbar = $false
        $toast.Size = New-Object System.Drawing.Size(350, 95)
        $toast.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
        $toast.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual

        $screen = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
        $toast.Location = New-Object System.Drawing.Point(($screen.Right - 370), ($screen.Bottom - 115))

        $toast.Add_Paint({
            param($s, $e)
            $rect = New-Object System.Drawing.Rectangle(0, 0, ($toast.Width - 1), ($toast.Height - 1))
            $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(56, 189, 248), 2)
            $e.Graphics.DrawRectangle($pen, $rect)
            $pen.Dispose()
        })

        $lbl1 = New-Object System.Windows.Forms.Label
        $lbl1.Text = "[VPN] " + $title
        $lbl1.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
        $lbl1.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
        $lbl1.Location = New-Object System.Drawing.Point(15, 10)
        $lbl1.Size = New-Object System.Drawing.Size(320, 18)
        $toast.Controls.Add($lbl1)

        $lbl2 = New-Object System.Windows.Forms.Label
        $lbl2.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $lbl2.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
        $lbl2.Location = New-Object System.Drawing.Point(15, 32)
        $lbl2.Size = New-Object System.Drawing.Size(320, 22)
        $toast.Controls.Add($lbl2)

        $lbl3 = New-Object System.Windows.Forms.Label
        $lbl3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $lbl3.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $lbl3.Location = New-Object System.Drawing.Point(15, 58)
        $lbl3.Size = New-Object System.Drawing.Size(320, 20)
        $toast.Controls.Add($lbl3)

        if (-not [string]::IsNullOrEmpty($passOtp)) {
            $lbl2.Text = "[OK] ĐÃ COPY MẬT KHẨU + OTP VÀO CLIPBOARD!"
            $lbl3.Text = if ($otp) { "Mã OTP: " + $otp + " (Hết hạn sau " + $rem + "s)" } else { "Mật khẩu đã sẵn sàng để Dán (Ctrl+V)" }
        } else {
            $lbl2.Text = "[OK] ĐÃ KHỞI CHẠY FORTICLIENT OFFICE SSO!"
            $lbl3.Text = "Hãy bấm 'SAML Login' trên FortiClient để xác thực SSO."
        }

        $tTimer = New-Object System.Windows.Forms.Timer
        $tTimer.Interval = 1400
        $tTimer.Add_Tick({
            $tTimer.Stop()
            $tTimer.Dispose()
            $toast.Close()
            [System.Windows.Forms.Application]::ExitThread()
        })
        $tTimer.Start()

        [System.Windows.Forms.Application]::Run($toast)
    } catch {
        if (-not [string]::IsNullOrEmpty($passOtp)) {
            try { [System.Windows.Forms.Clipboard]::SetText($passOtp) } catch {}
        }
    }
}

# --- XU LY CHE DO COPY SIEU TOC QUA DONG LENH (CLI) ---
$targetProfileKey = if ($Copy) { $Copy } else { $CopyProfile }
if (-not [string]::IsNullOrWhiteSpace($targetProfileKey)) {
    $cCfg = Load-Config

    # Xu ly rieng cho FortiClient Office SSO (Khong dung user/pass ma mo giao dien FortiClient)
    if ($targetProfileKey -match "4|office|sso") {
        $cfg = $cCfg
        Register-FortiTunnels -verboseLog $false | Out-Null
        $fortiExe = $cCfg.forti_office.exePath
        if (-not (Test-Path $fortiExe)) { $fortiExe = "C:\Program Files\Fortinet\FortiClient\FortiClient.exe" }
        if (-not (Test-Path $fortiExe)) { $fortiExe = "C:\Program Files (x86)\Fortinet\FortiClient\FortiClient.exe" }

        if (Test-Path $fortiExe) {
            $fortiDir = Split-Path -Path $fortiExe -Parent
            Start-Process -FilePath $fortiExe -WorkingDirectory $fortiDir -ErrorAction SilentlyContinue
            Show-Quick-Toast "FortiClient Office SSO" "" "" 0
        } else {
            [System.Windows.Forms.MessageBox]::Show("Da dong bo cau hinh FortiClient Office SSO vao Registry!`nVui long cai dat FortiClient tren may tinh nay de ket noi.", "VPN Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
        exit 0
    }

    $prof = $null
    if ($cCfg.$targetProfileKey) {
        $prof = $cCfg.$targetProfileKey
    } else {
        if ($targetProfileKey -match "1|sophos") { $prof = $cCfg.sophos }
        elseif ($targetProfileKey -match "2|epay|dr|openvpn") { $prof = $cCfg.openvpn_dr }
        elseif ($targetProfileKey -match "3|forti.*prod|hanh") { $prof = $cCfg.forticlient }
    }

    if ($prof) {
        $pName = if ($prof.name) { $prof.name } else { $targetProfileKey }
        $pass = $prof.password
        $sec = $prof.secret
        $otp = ""
        if (-not [string]::IsNullOrWhiteSpace($sec)) {
            $otp = Get-TOTP -SecretKey $sec
        }
        $fullPass = if ($otp) { "$pass$otp" } else { $pass }
        $rem = 30 - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 30)

        if ([string]::IsNullOrEmpty($fullPass)) {
            [System.Windows.Forms.MessageBox]::Show("Chua cau hinh mat khau cho $pName!`nVui long mo VPN Manager va bam 'Cai dat' de nhap.", "VPN Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        } else {
            Show-Quick-Toast $pName $fullPass $otp $rem
        }
    } else {
        [System.Windows.Forms.MessageBox]::Show("Khong tim thay cau hinh VPN '$targetProfileKey'!", "VPN Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
    }
    exit 0
}

# An cua so Console den cua PowerShell khi mo giao dien GUI
try {
    $win32 = Add-Type -MemberDefinition '[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();' -Name "Win32ConsoleHelper" -Namespace "Win32Utils" -PassThru -ErrorAction SilentlyContinue
    if ($win32) {
        $hwnd = $win32::GetConsoleWindow()
        if ($hwnd -ne [IntPtr]::Zero) { $win32::ShowWindow($hwnd, 0) }
    }
} catch {}

$cfg = Load-Config

# --- GIAO DIEN CHINH ---
$form = New-Object System.Windows.Forms.Form
$form.Text = "VPN Multi-Connect Manager"
$form.Size = New-Object System.Drawing.Size(590, 780)
$form.StartPosition = "CenterScreen"
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.BackColor = [System.Drawing.Color]::FromArgb(245, 247, 250)
$form.Add_Shown({
    $form.Activate()
    $form.BringToFront()
})

# Header
$pnlHeader = New-Object System.Windows.Forms.Panel
$pnlHeader.Location = New-Object System.Drawing.Point(0, 0)
$pnlHeader.Size = New-Object System.Drawing.Size(590, 65)
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(20, 70, 120)
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "QUẢN LÝ KẾT NỐI VPN, SSO VÀ OTP"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(20, 10)
$lblTitle.Size = New-Object System.Drawing.Size(540, 25)
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "Tự động kết nối OpenVPN, FortiClient SSO Browser và Copy Pass+OTP 1-Click"
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(200, 225, 250)
$lblSub.Location = New-Object System.Drawing.Point(20, 35)
$lblSub.Size = New-Object System.Drawing.Size(540, 20)
$pnlHeader.Controls.Add($lblSub)

# Group Danh sach VPN
$grpVPN = New-Object System.Windows.Forms.GroupBox
$grpVPN.Text = "  Danh Sách VPN && Trạng Thái Trực Tiếp  "
$grpVPN.Location = New-Object System.Drawing.Point(20, 75)
$grpVPN.Size = New-Object System.Drawing.Size(535, 295)
$grpVPN.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($grpVPN)

# Nhat ky hien thi
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Nhật ký hoạt động:"
$lblLog.Location = New-Object System.Drawing.Point(20, 475)
$lblLog.Size = New-Object System.Drawing.Size(200, 18)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 495)
$txtLog.Size = New-Object System.Drawing.Size(535, 230)
$txtLog.Multiline = $true
$txtLog.ScrollBars = [System.Windows.Forms.ScrollBars]::Vertical
$txtLog.ReadOnly = $true
$txtLog.BackColor = [System.Drawing.Color]::FromArgb(25, 25, 25)
$txtLog.ForeColor = [System.Drawing.Color]::FromArgb(140, 240, 140)
$txtLog.Font = New-Object System.Drawing.Font("Consolas", 8.5)
$form.Controls.Add($txtLog)

# Log Message Helper
function Log-Msg([string]$msg) {
    $time = (Get-Date).ToString("HH:mm:ss")
    $txtLog.AppendText("[$time] $msg`r`n")
    $txtLog.SelectionStart = $txtLog.Text.Length
    $txtLog.ScrollToCaret()
    [System.Windows.Forms.Application]::DoEvents()
}

# Helper Copy Pass + OTP
function Copy-VpnCredentials($key, $btnControl = $null) {
    $prof = $cfg.$key
    if (-not $prof) { return }
    $pName = if ($prof.name) { $prof.name } else { $key }
    $pass = $prof.password
    $sec = $prof.secret
    $otp = ""
    if (-not [string]::IsNullOrWhiteSpace($sec)) {
        $otp = Get-TOTP -SecretKey $sec
    }
    $fullPass = if ($otp) { "$pass$otp" } else { $pass }
    if ([string]::IsNullOrEmpty($fullPass)) {
        Log-Msg "[-] CANH BAO: Chua co mat khau cho $pName. Vui long bam 'Cai dat' de nhap."
        [System.Windows.Forms.MessageBox]::Show("Chua co mat khau cho $pName!`r`nVui long bam nut 'Cai dat Tai khoan va Key' de cap nhat.", "Chua co mat khau", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    try {
        [System.Windows.Forms.Clipboard]::SetText($fullPass)
        $rem = 30 - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 30)
        if ($otp) {
            Log-Msg "[OK COPY] Da copy [Mat khau + OTP] cua $pName! (OTP: " + $otp + " - Con " + $rem + "s)"
        } else {
            Log-Msg "[OK COPY] Da copy [Mat khau] cua $pName vao Clipboard!"
        }

        if ($btnControl) {
            $origText = $btnControl.Text
            $origColor = $btnControl.BackColor
            $btnControl.Text = "[DA CHEP!]"
            $btnControl.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)

            $fbTimer = New-Object System.Windows.Forms.Timer
            $fbTimer.Interval = 1200
            $fbTimer.Add_Tick({
                $btnControl.Text = $origText
                $btnControl.BackColor = $origColor
                $fbTimer.Stop()
                $fbTimer.Dispose()
            })
            $fbTimer.Start()
        }
    } catch {
        Log-Msg "[-] LOI khi copy: $($_.Exception.Message)"
    }
}

# Quan ly danh sach Floating Widgets dang mo
$global:activeWidgets = @{}

# Helper Mo Widget Icon Noi (Floating Mini Shorticon)
function Show-FloatingWidget([string]$profKey) {
    if ([string]::IsNullOrWhiteSpace($profKey)) { return }
    if ($global:activeWidgets.ContainsKey($profKey) -and $global:activeWidgets[$profKey] -ne $null -and -not $global:activeWidgets[$profKey].IsDisposed) {
        $global:activeWidgets[$profKey].BringToFront()
        $global:activeWidgets[$profKey].Activate()
        return
    }

    $prof = $cfg.$profKey
    if (-not $prof) { return }
    $pName = if ($prof.name) { $prof.name } else { $profKey }

    $wForm = New-Object System.Windows.Forms.Form
    $wForm.Tag = $profKey
    $wForm.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
    $wForm.TopMost = $true
    $wForm.ShowInTaskbar = $false
    $wForm.Size = New-Object System.Drawing.Size(265, 74)
    $wForm.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
    $wForm.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
    $wForm.Cursor = [System.Windows.Forms.Cursors]::Hand

    # Ve vien 1px vien xanh cao cap
    $wForm.Add_Paint({
        param($s, $e)
        $rect = New-Object System.Drawing.Rectangle(0, 0, ($wForm.Width - 1), ($wForm.Height - 1))
        $pen = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(56, 189, 248), 1)
        $e.Graphics.DrawRectangle($pen, $rect)
        $pen.Dispose()
    })

    # Vi tri mac dinh: Goc tren ben phai man hinh
    $screenArea = [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea
    $yOffset = 100
    if ($profKey -eq "openvpn_dr") { $yOffset = 185 }
    elseif ($profKey -eq "forticlient") { $yOffset = 270 }
    elseif ($profKey -eq "forti_office") { $yOffset = 355 }
    $wForm.Location = New-Object System.Drawing.Point(($screenArea.Right - 285), $yOffset)

    # Tieu de VPN
    $wLblTitle = New-Object System.Windows.Forms.Label
    $wLblTitle.Text = "[VPN] " + $pName
    $wLblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $wLblTitle.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
    $wLblTitle.Location = New-Object System.Drawing.Point(10, 6)
    $wLblTitle.Size = New-Object System.Drawing.Size(220, 18)
    $wLblTitle.AutoEllipsis = $true
    $wForm.Controls.Add($wLblTitle)

    # Nut dong [X]
    $wBtnClose = New-Object System.Windows.Forms.Label
    $wBtnClose.Text = "X"
    $wBtnClose.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $wBtnClose.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $wBtnClose.Location = New-Object System.Drawing.Point(234, 2)
    $wBtnClose.Size = New-Object System.Drawing.Size(28, 24)
    $wBtnClose.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
    $wBtnClose.Cursor = [System.Windows.Forms.Cursors]::Hand
    $wBtnClose.Add_MouseEnter({ $wBtnClose.ForeColor = [System.Drawing.Color]::FromArgb(239, 68, 68) })
    $wBtnClose.Add_MouseLeave({ $wBtnClose.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184) })
    
    $closeWidgetAction = {
        param($s, $e)
        $parent = $s.FindForm()
        if (-not $parent) { $parent = $wForm }
        if ($parent) {
            $curTag = [string]$parent.Tag
            if ($curTag -and $global:activeWidgets.ContainsKey($curTag)) {
                $global:activeWidgets.Remove($curTag)
            }
            $parent.Close()
            $parent.Dispose()
        }
    }.GetNewClosure()

    $wBtnClose.Add_Click($closeWidgetAction)
    $wBtnClose.Add_MouseDown({ param($s, $e) $s.Capture = $false }.GetNewClosure())
    $wForm.Controls.Add($wBtnClose)

    # Nhan OTP & Dem nguoc
    $wLblOtp = New-Object System.Windows.Forms.Label
    $wLblOtp.Font = New-Object System.Drawing.Font("Consolas", 11, [System.Drawing.FontStyle]::Bold)
    $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
    $wLblOtp.Location = New-Object System.Drawing.Point(10, 26)
    $wLblOtp.Size = New-Object System.Drawing.Size(245, 22)
    $wForm.Controls.Add($wLblOtp)

    # Nhan goi y bam
    $wLblHint = New-Object System.Windows.Forms.Label
    $wLblHint.Text = if ($profKey -eq "forti_office") { "(Click để Mở FortiClient SSO)" } else { "(Click để Copy Pass+OTP)" }
    $wLblHint.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Italic)
    $wLblHint.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    $wLblHint.Location = New-Object System.Drawing.Point(10, 50)
    $wLblHint.Size = New-Object System.Drawing.Size(245, 16)
    $wForm.Controls.Add($wLblHint)

    # Cap nhat OTP lan dau ngay khi mo
    $pInit = $cfg.$profKey
    if ($pInit -and -not [string]::IsNullOrWhiteSpace($pInit.secret)) {
        $initOtp = Get-TOTP -SecretKey $pInit.secret
        $initRem = 30 - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 30)
        $wLblOtp.Text = "OTP: " + $initOtp + " (" + $initRem + "s)"
        if ($initRem -le 5) {
            $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
        } else {
            $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
        }
    } else {
        if ($profKey -eq "forti_office") {
            $wLblOtp.Text = "SSO Browser Login"
            $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
        } else {
            $wLblOtp.Text = "Không dùng OTP"
            $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
        }
    }

    # Ham thuc thi Copy / Mo khi click vao Widget
    $doCopyWidget = {
        param($s, $e)
        $curK = [string]$wForm.Tag
        if ($curK -eq "forti_office") {
            Connect-FortiOffice
            return
        }
        $pObj = $cfg.$curK
        if (-not $pObj) { return }
        $sec = $pObj.secret
        $p = $pObj.password
        $targetName = if ($pObj.name) { $pObj.name } else { $curK }
        $otp = ""
        if (-not [string]::IsNullOrWhiteSpace($sec)) { $otp = Get-TOTP -SecretKey $sec }
        $fullPass = if ($otp) { "$p$otp" } else { $p }

        if ([string]::IsNullOrEmpty($fullPass)) {
            [System.Windows.Forms.MessageBox]::Show("Chưa có mật khẩu cho $targetName!`nVui lòng bấm 'Cài đặt' để nhập.", "VPN Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        try {
            [System.Windows.Forms.Clipboard]::SetText($fullPass)
            $wForm.BackColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
            $wLblTitle.Text = "[ĐÃ CHÉP PASS+OTP!]"
            $wLblTitle.ForeColor = [System.Drawing.Color]::White

            $flashTimer = New-Object System.Windows.Forms.Timer
            $flashTimer.Interval = 800
            $flashTimer.Add_Tick({
                $wForm.BackColor = [System.Drawing.Color]::FromArgb(15, 23, 42)
                $wLblTitle.Text = "[VPN] " + $targetName
                $wLblTitle.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
                $flashTimer.Stop()
                $flashTimer.Dispose()
            }.GetNewClosure())
            $flashTimer.Start()
            $rem = 30 - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 30)
            if ($otp) {
                Log-Msg "[OK WIDGET] Đã copy Pass+OTP của $targetName! (OTP: " + $otp + " - Còn " + $rem + "s)"
            } else {
                Log-Msg "[OK WIDGET] Đã copy Mật khẩu của $targetName vào Clipboard!"
            }
        } catch {}
    }.GetNewClosure()

    # Ho tro Keo tha (Drag) hoac Click de copy
    $dragData = [PSCustomObject]@{
        isDown = $false
        startPos = [System.Drawing.Point]::Empty
        startLoc = [System.Drawing.Point]::Empty
    }

    $dragDown = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $dragData.isDown = $true
            $dragData.startPos = [System.Windows.Forms.Cursor]::Position
            $dragData.startLoc = $wForm.Location
        }
    }.GetNewClosure()

    $dragMove = {
        param($sender, $e)
        if ($dragData.isDown) {
            $cur = [System.Windows.Forms.Cursor]::Position
            $dx = $cur.X - $dragData.startPos.X
            $dy = $cur.Y - $dragData.startPos.Y
            $wForm.Location = New-Object System.Drawing.Point(($dragData.startLoc.X + $dx), ($dragData.startLoc.Y + $dy))
        }
    }.GetNewClosure()

    $dragUp = {
        param($sender, $e)
        if ($e.Button -eq [System.Windows.Forms.MouseButtons]::Left) {
            $cur = [System.Windows.Forms.Cursor]::Position
            $dist = [Math]::Abs($cur.X - $dragData.startPos.X) + [Math]::Abs($cur.Y - $dragData.startPos.Y)
            $dragData.isDown = $false
            if ($dist -lt 6) {
                $doCopyWidget.Invoke($sender, $e)
            }
        }
    }.GetNewClosure()

    $wForm.Add_MouseDown($dragDown); $wForm.Add_MouseMove($dragMove); $wForm.Add_MouseUp($dragUp)
    $wLblTitle.Add_MouseDown($dragDown); $wLblTitle.Add_MouseMove($dragMove); $wLblTitle.Add_MouseUp($dragUp)
    $wLblOtp.Add_MouseDown($dragDown); $wLblOtp.Add_MouseMove($dragMove); $wLblOtp.Add_MouseUp($dragUp)
    $wLblHint.Add_MouseDown($dragDown); $wLblHint.Add_MouseMove($dragMove); $wLblHint.Add_MouseUp($dragUp)

    # Timer cap nhat OTP cua Widget moi giay
    $wTimer = New-Object System.Windows.Forms.Timer
    $wTimer.Interval = 1000
    $wTimer.Add_Tick({
        param($s, $e)
        if ($wForm.IsDisposed) {
            $wTimer.Stop()
            $wTimer.Dispose()
            return
        }
        $curK = [string]$wForm.Tag
        $pObj = $cfg.$curK
        if ($pObj -and -not [string]::IsNullOrWhiteSpace($pObj.secret)) {
            $curOtp = Get-TOTP -SecretKey $pObj.secret
            $rem = 30 - ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() % 30)
            $wLblOtp.Text = "OTP: " + $curOtp + " (" + $rem + "s)"
            if ($rem -le 5) {
                $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(248, 113, 113)
            } else {
                $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
            }
        } else {
            if ($curK -eq "forti_office") {
                $wLblOtp.Text = "SSO Browser Login"
                $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(56, 189, 248)
            } else {
                $wLblOtp.Text = "Khong dung OTP"
                $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
            }
        }
    }.GetNewClosure())
    $wTimer.Start()

    $wForm.Add_FormClosed({
        param($s, $e)
        $wTimer.Stop()
        $wTimer.Dispose()
        $curTag = [string]$s.Tag
        if ($curTag -and $global:activeWidgets.ContainsKey($curTag)) {
            $global:activeWidgets.Remove($curTag)
        }
    }.GetNewClosure())

    $global:activeWidgets[$profKey] = $wForm
    $wForm.Show()
    Log-Msg "[OK WIDGET] Da mo Icon Noi cho $pName."
}

# --- SYSTEM TRAY (KHAY TASKBAR CANH DONG HO) ---
$trayIcon = New-Object System.Windows.Forms.NotifyIcon
$trayIcon.Icon = [System.Drawing.SystemIcons]::Shield
$trayIcon.Text = "VPN Multi-Connect Manager"
$trayIcon.Visible = $true

$trayMenu = New-Object System.Windows.Forms.ContextMenuStrip
$trayMenu.Font = New-Object System.Drawing.Font("Segoe UI", 9)

# Menu items
$mItemSophos = New-Object System.Windows.Forms.ToolStripMenuItem
$mItemSophos.Text = "1. Copy Sophos Pass+OTP"
$mItemSophos.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemSophos.Add_Click({ Copy-VpnCredentials "sophos" })
$trayMenu.Items.Add($mItemSophos) | Out-Null

$mItemDr = New-Object System.Windows.Forms.ToolStripMenuItem
$mItemDr.Text = "2. Copy OpenVPN DR Pass+OTP"
$mItemDr.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemDr.Add_Click({ Copy-VpnCredentials "openvpn_dr" })
$trayMenu.Items.Add($mItemDr) | Out-Null

$mItemForti = New-Object System.Windows.Forms.ToolStripMenuItem
$mItemForti.Text = "3. Copy FortiClient Production"
$mItemForti.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemForti.Add_Click({ Copy-VpnCredentials "forticlient" })
$trayMenu.Items.Add($mItemForti) | Out-Null

$mItemOffice = New-Object System.Windows.Forms.ToolStripMenuItem
$mItemOffice.Text = "4. Ket noi FortiClient Office SSO"
$mItemOffice.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemOffice.Add_Click({ Connect-FortiOffice })
$trayMenu.Items.Add($mItemOffice) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemWidgetSophos = New-Object System.Windows.Forms.ToolStripMenuItem("Mở Widget Nổi - Sophos")
$mItemWidgetSophos.Add_Click({ Show-FloatingWidget "sophos" })
$trayMenu.Items.Add($mItemWidgetSophos) | Out-Null

$mItemWidgetDr = New-Object System.Windows.Forms.ToolStripMenuItem("Mở Widget Nổi - OpenVPN DR")
$mItemWidgetDr.Add_Click({ Show-FloatingWidget "openvpn_dr" })
$trayMenu.Items.Add($mItemWidgetDr) | Out-Null

$mItemWidgetOffice = New-Object System.Windows.Forms.ToolStripMenuItem("Mở Widget Nổi - Forti Office SSO")
$mItemWidgetOffice.Add_Click({ Show-FloatingWidget "forti_office" })
$trayMenu.Items.Add($mItemWidgetOffice) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemShow = New-Object System.Windows.Forms.ToolStripMenuItem("Mở Cửa Sổ Chính")
$mItemShow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemShow.Add_Click({
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
})
$trayMenu.Items.Add($mItemShow) | Out-Null

$mItemConfig = New-Object System.Windows.Forms.ToolStripMenuItem("Cài đặt Tài khoản && Key")
$mItemConfig.Add_Click({ Show-ConfigDialog })
$trayMenu.Items.Add($mItemConfig) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemExit = New-Object System.Windows.Forms.ToolStripMenuItem("Thoát Hoàn Toàn")
$mItemExit.ForeColor = [System.Drawing.Color]::DarkRed
$mItemExit.Add_Click({
    Unregister-FortiTunnels
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
    $form.Close()
    [System.Windows.Forms.Application]::Exit()
})
$trayMenu.Items.Add($mItemExit) | Out-Null

$trayIcon.ContextMenuStrip = $trayMenu

# Click vao Tray Icon de bat menu hoac mo ung dung
$trayIcon.Add_DoubleClick({
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
})

# Thu nho xuong Taskbar Tray khi bam thu nho
$form.Add_Resize({
    if ($form.WindowState -eq [System.Windows.Forms.FormWindowState]::Minimized) {
        $form.Hide()
        $trayIcon.ShowBalloonTip(1500, "VPN Manager", "Ung dung da thu gon xuong Khay Taskbar. Click chuot vao icon ben canh dong ho de thao tac nhanh!", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$form.Add_FormClosing({
    param($s, $e)
    Unregister-FortiTunnels
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
})

# --- THIET KE CAC DONG VPN TRONG GIAO DIEN ---

# ROW 1: Sophos SSL VPN
$chk1 = New-Object System.Windows.Forms.CheckBox
$chk1.Text = "1. Sophos SSL VPN"
$chk1.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$chk1.Location = New-Object System.Drawing.Point(15, 20)
$chk1.Size = New-Object System.Drawing.Size(195, 24)
$chk1.Checked = [bool]$cfg.sophos.enabled
$grpVPN.Controls.Add($chk1)

$lblSt1 = New-Object System.Windows.Forms.Label
$lblSt1.Text = "[o] Chưa kết nối"
$lblSt1.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt1.ForeColor = [System.Drawing.Color]::Gray
$lblSt1.Location = New-Object System.Drawing.Point(215, 23)
$lblSt1.Size = New-Object System.Drawing.Size(185, 18)
$grpVPN.Controls.Add($lblSt1)

$lblOtp1 = New-Object System.Windows.Forms.Label
$lblOtp1.Text = ""
$lblOtp1.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblOtp1.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtp1.Location = New-Object System.Drawing.Point(405, 23)
$lblOtp1.Size = New-Object System.Drawing.Size(120, 18)
$grpVPN.Controls.Add($lblOtp1)

$btnCopy1 = New-Object System.Windows.Forms.Button
$btnCopy1.Text = "Copy Pass+OTP"
$btnCopy1.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnCopy1.Location = New-Object System.Drawing.Point(30, 44)
$btnCopy1.Size = New-Object System.Drawing.Size(235, 26)
$btnCopy1.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnCopy1.ForeColor = [System.Drawing.Color]::White
$btnCopy1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopy1.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopy1.Add_Click({ Copy-VpnCredentials "sophos" $btnCopy1 })
$grpVPN.Controls.Add($btnCopy1)

$btnFloat1 = New-Object System.Windows.Forms.Button
$btnFloat1.Text = "Icon Nổi"
$btnFloat1.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnFloat1.Location = New-Object System.Drawing.Point(275, 44)
$btnFloat1.Size = New-Object System.Drawing.Size(235, 26)
$btnFloat1.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$btnFloat1.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnFloat1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFloat1.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnFloat1.Add_Click({ Show-FloatingWidget "sophos" })
$grpVPN.Controls.Add($btnFloat1)

# ROW 2: OpenVPN DR Epay
$chk2 = New-Object System.Windows.Forms.CheckBox
$chk2.Text = "2. OpenVPN (VPN DR)"
$chk2.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$chk2.Location = New-Object System.Drawing.Point(15, 76)
$chk2.Size = New-Object System.Drawing.Size(195, 24)
$chk2.Checked = [bool]$cfg.openvpn_dr.enabled
$grpVPN.Controls.Add($chk2)

$lblSt2 = New-Object System.Windows.Forms.Label
$lblSt2.Text = "[o] Chưa kết nối"
$lblSt2.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt2.ForeColor = [System.Drawing.Color]::Gray
$lblSt2.Location = New-Object System.Drawing.Point(215, 79)
$lblSt2.Size = New-Object System.Drawing.Size(185, 18)
$grpVPN.Controls.Add($lblSt2)

$lblOtp2 = New-Object System.Windows.Forms.Label
$lblOtp2.Text = ""
$lblOtp2.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblOtp2.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtp2.Location = New-Object System.Drawing.Point(405, 79)
$lblOtp2.Size = New-Object System.Drawing.Size(120, 18)
$grpVPN.Controls.Add($lblOtp2)

$btnCopy2 = New-Object System.Windows.Forms.Button
$btnCopy2.Text = "Copy Pass+OTP"
$btnCopy2.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnCopy2.Location = New-Object System.Drawing.Point(30, 100)
$btnCopy2.Size = New-Object System.Drawing.Size(235, 26)
$btnCopy2.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnCopy2.ForeColor = [System.Drawing.Color]::White
$btnCopy2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopy2.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopy2.Add_Click({ Copy-VpnCredentials "openvpn_dr" $btnCopy2 })
$grpVPN.Controls.Add($btnCopy2)

$btnFloat2 = New-Object System.Windows.Forms.Button
$btnFloat2.Text = "Icon Nổi"
$btnFloat2.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnFloat2.Location = New-Object System.Drawing.Point(275, 100)
$btnFloat2.Size = New-Object System.Drawing.Size(235, 26)
$btnFloat2.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$btnFloat2.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnFloat2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFloat2.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnFloat2.Add_Click({ Show-FloatingWidget "openvpn_dr" })
$grpVPN.Controls.Add($btnFloat2)

# ROW 3: FortiClient Production
$chk3 = New-Object System.Windows.Forms.CheckBox
$chk3.Text = "3. FortiClient (Production)"
$chk3.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$chk3.Location = New-Object System.Drawing.Point(15, 132)
$chk3.Size = New-Object System.Drawing.Size(195, 24)
$chk3.Checked = [bool]$cfg.forticlient.enabled
$grpVPN.Controls.Add($chk3)

$lblSt3 = New-Object System.Windows.Forms.Label
$lblSt3.Text = "[o] Chưa kết nối"
$lblSt3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt3.ForeColor = [System.Drawing.Color]::Gray
$lblSt3.Location = New-Object System.Drawing.Point(215, 135)
$lblSt3.Size = New-Object System.Drawing.Size(185, 18)
$grpVPN.Controls.Add($lblSt3)

$lblOtp3 = New-Object System.Windows.Forms.Label
$lblOtp3.Text = ""
$lblOtp3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblOtp3.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtp3.Location = New-Object System.Drawing.Point(405, 135)
$lblOtp3.Size = New-Object System.Drawing.Size(120, 18)
$grpVPN.Controls.Add($lblOtp3)

$btnCopy3 = New-Object System.Windows.Forms.Button
$btnCopy3.Text = "Copy Mật Khẩu"
$btnCopy3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnCopy3.Location = New-Object System.Drawing.Point(30, 156)
$btnCopy3.Size = New-Object System.Drawing.Size(235, 26)
$btnCopy3.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnCopy3.ForeColor = [System.Drawing.Color]::White
$btnCopy3.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopy3.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopy3.Add_Click({ Copy-VpnCredentials "forticlient" $btnCopy3 })
$grpVPN.Controls.Add($btnCopy3)

$btnFloat3 = New-Object System.Windows.Forms.Button
$btnFloat3.Text = "Icon Nổi"
$btnFloat3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnFloat3.Location = New-Object System.Drawing.Point(275, 156)
$btnFloat3.Size = New-Object System.Drawing.Size(235, 26)
$btnFloat3.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$btnFloat3.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnFloat3.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFloat3.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnFloat3.Add_Click({ Show-FloatingWidget "forticlient" })
$grpVPN.Controls.Add($btnFloat3)

# ROW 4: FortiClient Office SSO
$chk4 = New-Object System.Windows.Forms.CheckBox
$chk4.Text = "4. FortiClient (Office SSO)"
$chk4.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$chk4.Location = New-Object System.Drawing.Point(15, 188)
$chk4.Size = New-Object System.Drawing.Size(195, 24)
$chk4.Checked = [bool]$cfg.forti_office.enabled
$grpVPN.Controls.Add($chk4)

$lblSt4 = New-Object System.Windows.Forms.Label
$lblSt4.Text = "[o] Chưa kết nối"
$lblSt4.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt4.ForeColor = [System.Drawing.Color]::Gray
$lblSt4.Location = New-Object System.Drawing.Point(215, 191)
$lblSt4.Size = New-Object System.Drawing.Size(185, 18)
$grpVPN.Controls.Add($lblSt4)

$lblOtp4 = New-Object System.Windows.Forms.Label
$lblOtp4.Text = "SSO Browser"
$lblOtp4.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
$lblOtp4.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblOtp4.Location = New-Object System.Drawing.Point(405, 191)
$lblOtp4.Size = New-Object System.Drawing.Size(120, 18)
$grpVPN.Controls.Add($lblOtp4)

$btnOpenOffice = New-Object System.Windows.Forms.Button
$btnOpenOffice.Text = "Mở Forti SSO (Browser)"
$btnOpenOffice.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$btnOpenOffice.Location = New-Object System.Drawing.Point(30, 212)
$btnOpenOffice.Size = New-Object System.Drawing.Size(235, 26)
$btnOpenOffice.BackColor = [System.Drawing.Color]::FromArgb(14, 116, 144)
$btnOpenOffice.ForeColor = [System.Drawing.Color]::White
$btnOpenOffice.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnOpenOffice.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnOpenOffice.Add_Click({ Connect-FortiOffice })
$grpVPN.Controls.Add($btnOpenOffice)

$btnRegOffice = New-Object System.Windows.Forms.Button
$btnRegOffice.Text = "Đồng bộ Forti sang máy này"
$btnRegOffice.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$btnRegOffice.Location = New-Object System.Drawing.Point(275, 212)
$btnRegOffice.Size = New-Object System.Drawing.Size(235, 26)
$btnRegOffice.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$btnRegOffice.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnRegOffice.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnRegOffice.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnRegOffice.Add_Click({ 
    $ok = Register-FortiTunnels -verboseLog $true
    if ($ok) {
        [System.Windows.Forms.MessageBox]::Show("Đã đồng bộ cấu hình FortiClient Office SSO vào máy tính thành công!`nMở FortiClient để kết nối ngay.", "VPN Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
    }
})
$grpVPN.Controls.Add($btnRegOffice)

# Ghi chu nhanh huong dan Forti SSO
$lblHintSSO = New-Object System.Windows.Forms.Label
$lblHintSSO.Text = "* Lưu ý: FortiClient Office dùng xác thực SSO qua trình duyệt Microsoft (Không dùng User/Pass text)"
$lblHintSSO.Font = New-Object System.Drawing.Font("Segoe UI", 7.5, [System.Drawing.FontStyle]::Italic)
$lblHintSSO.ForeColor = [System.Drawing.Color]::FromArgb(100, 116, 139)
$lblHintSSO.Location = New-Object System.Drawing.Point(15, 258)
$lblHintSSO.Size = New-Object System.Drawing.Size(505, 18)
$grpVPN.Controls.Add($lblHintSSO)

# Nut bam Ket noi
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = ">> KẾT NỐI ĐÃ CHỌN"
$btnConnect.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnConnect.Location = New-Object System.Drawing.Point(20, 385)
$btnConnect.Size = New-Object System.Drawing.Size(260, 38)
$btnConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnConnect.ForeColor = [System.Drawing.Color]::White
$btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnConnect)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = "KẾT NỐI TẤT CẢ"
$btnAll.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnAll.Location = New-Object System.Drawing.Point(295, 385)
$btnAll.Size = New-Object System.Drawing.Size(260, 38)
$btnAll.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnAll.ForeColor = [System.Drawing.Color]::White
$btnAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnAll.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnAll)

# Nut bam Ngat ket noi
$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "[X] TẮT TOÀN BỘ VPN"
$btnDisconnect.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$btnDisconnect.Location = New-Object System.Drawing.Point(20, 432)
$btnDisconnect.Size = New-Object System.Drawing.Size(535, 34)
$btnDisconnect.BackColor = [System.Drawing.Color]::FromArgb(211, 47, 47)
$btnDisconnect.ForeColor = [System.Drawing.Color]::White
$btnDisconnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDisconnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnDisconnect)

# --- TIMER THEO DOI TRANG THAI KET NOI & OTP LIVE ---
$tickCounter = 0
$timer = New-Object System.Windows.Forms.Timer
$timer.Interval = 1000
$timer.Add_Tick({
    try {
        $script:tickCounter++
        $unixTime = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
        $rem = 30 - ($unixTime % 30)

        # 1. Cap nhat OTP Live Sophos
        if (-not [string]::IsNullOrWhiteSpace($cfg.sophos.secret)) {
            $otp1 = Get-TOTP -SecretKey $cfg.sophos.secret
            $lblOtp1.Text = "OTP: " + $otp1 + " (" + $rem + "s)"
            if ($rem -le 5) {
                $lblOtp1.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
            } else {
                $lblOtp1.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
            }
            $mItemSophos.Text = "1. Copy Sophos Pass+OTP (" + $otp1 + ")"
        } else {
            $lblOtp1.Text = ""
            $mItemSophos.Text = "1. Copy Sophos"
        }

        # 2. Cap nhat OTP Live OpenVPN DR
        if (-not [string]::IsNullOrWhiteSpace($cfg.openvpn_dr.secret)) {
            $otp2 = Get-TOTP -SecretKey $cfg.openvpn_dr.secret
            $lblOtp2.Text = "OTP: " + $otp2 + " (" + $rem + "s)"
            if ($rem -le 5) {
                $lblOtp2.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
            } else {
                $lblOtp2.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
            }
            $mItemDr.Text = "2. Copy OpenVPN DR Pass+OTP (" + $otp2 + ")"
        } else {
            $lblOtp2.Text = ""
            $mItemDr.Text = "2. Copy OpenVPN DR"
        }

        # 3. Cap nhat OTP Live FortiClient Production neu co secret
        if (-not [string]::IsNullOrWhiteSpace($cfg.forticlient.secret)) {
            $otp3 = Get-TOTP -SecretKey $cfg.forticlient.secret
            $lblOtp3.Text = "OTP: " + $otp3 + " (" + $rem + "s)"
            if ($rem -le 5) {
                $lblOtp3.ForeColor = [System.Drawing.Color]::FromArgb(220, 38, 38)
            } else {
                $lblOtp3.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
            }
            $btnCopy3.Text = "Copy Pass+OTP"
            $mItemForti.Text = "3. Copy FortiClient Pass+OTP (" + $otp3 + ")"
        } else {
            $lblOtp3.Text = ""
            $btnCopy3.Text = "Copy Mật Khẩu"
            $mItemForti.Text = "3. Copy Mật Khẩu FortiClient"
        }

        # Cap nhat ToolTip Tray Icon
        $trayIcon.Text = "VPN Manager | Sophos: $otp1 | DR: $otp2"

        # Moi 2 giay kiem tra trang thai IP ket noi VPN thuc te
        if ($script:tickCounter % 2 -eq 0) {
            # 1. Sophos SSL VPN (172.16.x.x)
            $sophosIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match "^172\.16\." -and $_.AddressState -eq "Preferred" }
            if ($sophosIP) {
                $lblSt1.Text = "[*] ĐÃ KẾT NỐI (" + $sophosIP[0].IPAddress + ")"
                $lblSt1.ForeColor = [System.Drawing.Color]::Green
            } else {
                $lblSt1.Text = "[o] Chưa kết nối"
                $lblSt1.ForeColor = [System.Drawing.Color]::Gray
            }

            # 2. OpenVPN DR Epay (10.150.x.x)
            $drIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match "^10\.150\." -and $_.AddressState -eq "Preferred" }
            if ($drIP) {
                $lblSt2.Text = "[*] ĐÃ KẾT NỐI (" + $drIP[0].IPAddress + ")"
                $lblSt2.ForeColor = [System.Drawing.Color]::Green
            } else {
                $lblSt2.Text = "[o] Chưa kết nối"
                $lblSt2.ForeColor = [System.Drawing.Color]::Gray
            }

            # 3. FortiClient Production (14.238.148.196 / OpenConnect / IP VPN)
            $fortiDisplayIP = ""
            $ocProc = Get-Process -Name "openconnect" -ErrorAction SilentlyContinue
            if ($ocProc) {
                $logPath = Join-Path $baseDir "forti_openconnect.log"
                if (Test-Path $logPath) {
                    $logText = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
                    if ($logText -match "Configured as\s+([0-9\.]+)|Got Legacy IP address\s+([0-9\.]+)") {
                        $fortiDisplayIP = if ($matches[1]) { $matches[1] } else { $matches[2] }
                    }
                }
            }

            if (![string]::IsNullOrEmpty($fortiDisplayIP)) {
                $lblSt3.Text = "[*] ĐÃ KẾT NỐI ($fortiDisplayIP)"
                $lblSt3.ForeColor = [System.Drawing.Color]::Green
            } else {
                $lblSt3.Text = "[o] Chưa kết nối"
                $lblSt3.ForeColor = [System.Drawing.Color]::Gray
            }

            # 4. FortiClient Office SSO (Kiem tra card mang Fortinet Virtual Adapter)
            $officeIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { 
                (($_.InterfaceAlias -match "Fortinet|Ethernet 2|Ethernet 3" -or ($_.IPAddress -match "^10\." -and $_.IPAddress -notmatch "^10\.150\.")) -and $_.AddressState -eq "Preferred")
            }
            if ($officeIP -and $officeIP.Length -gt 0) {
                $lblSt4.Text = "[*] ĐÃ KẾT NỐI (" + $officeIP[0].IPAddress + ")"
                $lblSt4.ForeColor = [System.Drawing.Color]::Green
            } else {
                $lblSt4.Text = "[o] Chưa kết nối"
                $lblSt4.ForeColor = [System.Drawing.Color]::Gray
            }
        }
    } catch {}
})
$timer.Start()

# Helper ket noi OpenVPN tieu chuan
function Connect-OpenVpnProfile($profileName, $configName, $ovpnSubDir, $ovpnFileName, $username, $password, $secret) {
    Log-Msg "-------------------------------------------"
    Log-Msg "Dang ket noi: $profileName (Tai khoan $username)..."

    # Tinh OTP neu co Secret Key
    $otp = ""
    if (-not [string]::IsNullOrWhiteSpace($secret)) {
        $otp = Get-TOTP -SecretKey $secret
        if ($otp) {
            Log-Msg "-> Ma OTP ($profileName): $otp"
        }
    }
    $fullPass = if ($otp) { "$password$otp" } else { $password }

    $srcDir = Get-Absolute-Path $ovpnSubDir
    $ovpnSrcFile = Join-Path $srcDir $ovpnFileName
    if (-not (Test-Path $ovpnSrcFile)) {
        Log-Msg "[-] LOI: Khong tim thay file $ovpnFileName trong $srcDir"
        return
    }

    # Ghi file thong tin xac thuc vao thu muc OpenVPN
    $targetAuth = Join-Path $userOpenVpnDir "${configName}_auth.txt"
    $targetOvpn = Join-Path $userOpenVpnDir "${configName}.ovpn"
    Set-Content -Path $targetAuth -Value @($username, $fullPass) -Encoding ASCII

    # Sao chep va tro file .ovpn toi file auth
    $ovpnContent = Get-Content -Path $ovpnSrcFile -Raw
    $ovpnContent = $ovpnContent -replace "auth-user-pass.*", "auth-user-pass ${configName}_auth.txt"
    Set-Content -Path $targetOvpn -Value $ovpnContent -Encoding UTF8

    # Tu dong copy Mat khau + OTP vao Clipboard de tien su dung
    if ($fullPass) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($fullPass)
            Log-Msg "-> Da copy [Mat khau + OTP] vao Clipboard."
        } catch {}
    }

    # Chuan hoa che do ket noi:
    $targetConnectName = "${configName}.ovpn"
    $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) {
        $sysConfigDir = "C:\Program Files\OpenVPN\config"
        if (Test-Path $sysConfigDir) {
            $sysFiles = Get-ChildItem -Path $sysConfigDir -Filter "*.ovpn" -ErrorAction SilentlyContinue
            foreach ($sf in $sysFiles) {
                if ($sf.Name -eq "${configName}.ovpn" -or 
                    ($configName -match "epay|dr" -and $sf.Name -match "epay|dr") -or 
                    ($configName -match "sophos" -and $sf.Name -match "sophos")) {
                    $targetConnectName = $sf.Name
                    break
                }
            }
        }
    }

    # Goi OpenVPN GUI hoac OpenVPN CLI ket noi binh thuong
    if (Test-Path $openvpnGuiExe) {
        $guiProc = Get-Process -Name "openvpn-gui" -ErrorAction SilentlyContinue
        if (-not $guiProc) {
            Start-Process -FilePath $openvpnGuiExe
            Start-Sleep -Milliseconds 800
        }
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command connect $targetConnectName" -ErrorAction SilentlyContinue
        Log-Msg "[OK] Da gui lenh ket noi $profileName qua OpenVPN GUI ($targetConnectName)!"
    } elseif (Test-Path $openvpnExe) {
        Start-Process -FilePath $openvpnExe -ArgumentList "--config `"$targetOvpn`"" -WindowStyle Hidden
        Log-Msg "[OK] Da khoi chay $profileName qua OpenVPN CLI!"
    } else {
        Log-Msg "[-] LOI: Khong tim thay OpenVPN tren may tinh!"
    }
}

# Helper ket noi FortiClient Production (CLI / OpenConnect)
function Connect-FortiClient {
    Log-Msg "-------------------------------------------"
    Log-Msg "Dang ket noi: FortiClient Production (Tai khoan $($cfg.forticlient.username))..."
    $u = $cfg.forticlient.username
    $p = $cfg.forticlient.password
    $sec = $cfg.forticlient.secret
    $otp = ""
    if (-not [string]::IsNullOrWhiteSpace($sec)) { $otp = Get-TOTP -SecretKey $sec }
    $fullPass = if ($otp) { "$p$otp" } else { $p }

    $serverAddr = $cfg.forticlient.server
    if ([string]::IsNullOrWhiteSpace($serverAddr)) { $serverAddr = "14.238.148.196:4443" }

    $openConnectExe = Join-Path $baseDir "tools\openconnect.exe"
    if (-not (Test-Path $openConnectExe)) {
        $openConnectExe = "openconnect.exe"
    }

    $serverUrl = if ($serverAddr -match "^https?://") { $serverAddr } else { "https://$serverAddr" }
    $certVal = $cfg.forticlient.servercert
    if ([string]::IsNullOrWhiteSpace($certVal)) { $certVal = "pin-sha256:zJcknXTR0B49qZAztOTh7VW80yIwZYdPCWwm2mio=" }

    $passFile = Join-Path $baseDir "tools\oc_pass.txt"
    Set-Content -Path $passFile -Value $fullPass -Encoding ASCII

    $runBat = Join-Path $baseDir "tools\run_forti.bat"
    $toolsDir = Join-Path $baseDir "tools"
    $logFile = Join-Path $baseDir "forti_openconnect.log"
    $batContent = "@echo off`r`ncd /d `"$toolsDir`"`r`ntype `"$passFile`" | `"$openConnectExe`" --protocol=fortinet --no-dtls -u `"$u`" --passwd-on-stdin $serverUrl --servercert `"$certVal`" --non-inter > `"$logFile`" 2>&1"
    Set-Content -Path $runBat -Value $batContent -Encoding ASCII

    # Tu dong copy Mat khau vao Clipboard
    if ($fullPass) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($fullPass)
            Log-Msg "-> Da copy [Mat khau FortiClient] vao Clipboard."
        } catch {}
    }

    # Chay Task neu da dang ky (0 Admin), hoac khoi chay process
    $useTask = $false
    try {
        $chk = schtasks.exe /query /tn "VPN_Manager_FortiClient" 2>$null
        if ($chk -match "VPN_Manager_FortiClient") {
            schtasks.exe /run /tn "VPN_Manager_FortiClient" 2>$null | Out-Null
            $useTask = $true
        }
    } catch {}

    if (-not $useTask) {
        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$runBat`"" -WorkingDirectory $toolsDir -WindowStyle Hidden
    }
    Log-Msg "[OK] Da gui lenh ket noi FortiClient Production!"
}

# Helper ket noi FortiClient Office SSO (SAML Browser Login)
function Connect-FortiOffice {
    Log-Msg "-------------------------------------------"
    Log-Msg "Dang khoi chay: 4. FortiClient Office (SSO SAML qua trinh duyet)..."
    
    # 1. Tu dong dong bo cau hinh vao Registry may hien tai
    Register-FortiTunnels -verboseLog $false | Out-Null
    Log-Msg "-> Da kiem tra & dong bo tunnel 'Office' vao Registry (Gateway: $($cfg.forti_office.server), SSO: Enabled)."

    # 2. Tim kiem FortiClient.exe tren he thong
    $fortiExe = $cfg.forti_office.exePath
    if (-not (Test-Path $fortiExe)) {
        $fortiExe = "C:\Program Files\Fortinet\FortiClient\FortiClient.exe"
    }
    if (-not (Test-Path $fortiExe)) {
        $fortiExe = "C:\Program Files (x86)\Fortinet\FortiClient\FortiClient.exe"
    }

    if (Test-Path $fortiExe) {
        # Khoi chay giao dien FortiClient de nguoi dung xac thuc SSO 1-Click tren trinh duyet
        $fortiDir = Split-Path -Path $fortiExe -Parent
        Start-Process -FilePath $fortiExe -WorkingDirectory $fortiDir -ErrorAction SilentlyContinue
        Log-Msg "[OK] Đã mở FortiClient. Hãy chọn profile 'Office' và bấm SAML Login trên trình duyệt!"
    } else {
        # Neu may chua cai FortiClient GUI, thong bao va ho tro mo link dang nhap
        Log-Msg "[!] Luu y: Chua tim thay FortiClient.exe tai duong dan mac dinh."
        Log-Msg "-> Da luu cau hinh Registry san sang. Hay cai dat FortiClient tren may nay de su dung."
    }
}

# Function ngat ket noi toan bo VPN
function Stop-AllVPN {
    Log-Msg "-------------------------------------------"
    Log-Msg "Dang ngat ket noi TOAN BO VPN..."

    # Gui lenh disconnect toi OpenVPN GUI neu co
    if (Test-Path $openvpnGuiExe) {
        Start-Process -FilePath $openvpnGuiExe -ArgumentList "--command disconnect_all" -ErrorAction SilentlyContinue
    }

    # Dung cac tien trinh VPN CLI nen
    Stop-Process -Name "openvpn", "openconnect" -Force -ErrorAction SilentlyContinue
    try { schtasks.exe /end /tn "VPN_Manager_FortiClient" 2>$null | Out-Null } catch {}

    # Xoa bo Registry tunnel FortiClient Office
    Unregister-FortiTunnels

    Log-Msg "[OK] Da ngat ket noi VPN va don dep Registry thanh cong!"
}

# Function thuc thi ket noi cac VPN da chon
function Do-Connect([bool]$do1, [bool]$do2, [bool]$do3, [bool]$do4) {
    if (-not ($do1 -or $do2 -or $do3 -or $do4)) {
        Log-Msg "[-] CHUA CHON VPN: Vui long tich chon it nhat 1 VPN truoc khi bam Ket noi."
        [System.Windows.Forms.MessageBox]::Show("Vui long tich chon it nhat 1 VPN truoc khi bam '>> KET NOI DA CHON'!", "VPN Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
        return
    }

    if ($do1) {
        Connect-OpenVpnProfile "1. Sophos SSL VPN" "sophos" $cfg.sophos.dir $cfg.sophos.ovpnFile $cfg.sophos.username $cfg.sophos.password $cfg.sophos.secret
        if ($do2 -or $do3 -or $do4) { Start-Sleep -Seconds 1 }
    }

    if ($do2) {
        Connect-OpenVpnProfile "2. OpenVPN (VPN DR Epay)" "epay-dr" $cfg.openvpn_dr.dir $cfg.openvpn_dr.ovpnFile $cfg.openvpn_dr.username $cfg.openvpn_dr.password $cfg.openvpn_dr.secret
        if ($do3 -or $do4) { Start-Sleep -Seconds 1 }
    }

    if ($do3) {
        Connect-FortiClient
        if ($do4) { Start-Sleep -Seconds 1 }
    }

    if ($do4) {
        Connect-FortiOffice
    }

    Log-Msg "-------------------------------------------"
    Log-Msg "[OK] Hoan tat gui yeu cau ket noi."
}

# --- SU KIEN NUT BAM KET NOI ---
$btnConnect.Add_Click({ Do-Connect $chk1.Checked $chk2.Checked $chk3.Checked $chk4.Checked })
$btnAll.Add_Click({
    $chk1.Checked = $true
    $chk2.Checked = $true
    $chk3.Checked = $true
    $chk4.Checked = $true
    Do-Connect $true $true $true $true
})
$btnDisconnect.Add_Click({ Stop-AllVPN })

# Popup Cai dat Tai khoan, Mat khau va Secret Key (Mo tu Tray Menu khi can)
function Show-ConfigDialog {
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Cài Đặt Tài Khoản && Mật Khẩu VPN"
    $dlg.Size = New-Object System.Drawing.Size(530, 720)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.AutoScroll = $true

    # 1. Sophos SSL VPN
    $grp1 = New-Object System.Windows.Forms.GroupBox
    $grp1.Text = "  1. Sophos SSL VPN  "; $grp1.Location = "15,10"; $grp1.Size = "480,145"
    $grp1.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp1)

    $l1u = New-Object System.Windows.Forms.Label; $l1u.Text = "Tài khoản:"; $l1u.Location = "15,22"; $l1u.Size = "90,20"; $grp1.Controls.Add($l1u)
    $t1u = New-Object System.Windows.Forms.TextBox; $t1u.Location = "110,20"; $t1u.Size = "350,23"; $t1u.Text = $cfg.sophos.username; $grp1.Controls.Add($t1u)

    $l1p = New-Object System.Windows.Forms.Label; $l1p.Text = "Mật khẩu:"; $l1p.Location = "15,50"; $l1p.Size = "90,20"; $grp1.Controls.Add($l1p)
    $t1p = New-Object System.Windows.Forms.TextBox; $t1p.Location = "110,48"; $t1p.Size = "350,23"; $t1p.Text = $cfg.sophos.password; $grp1.Controls.Add($t1p)

    $l1s = New-Object System.Windows.Forms.Label; $l1s.Text = "Secret Key:"; $l1s.Location = "15,78"; $l1s.Size = "90,20"; $grp1.Controls.Add($l1s)
    $t1s = New-Object System.Windows.Forms.TextBox; $t1s.Location = "110,76"; $t1s.Size = "350,23"; $t1s.Text = $cfg.sophos.secret; $grp1.Controls.Add($t1s)

    $c1e = New-Object System.Windows.Forms.CheckBox; $c1e.Text = "Mặc định chọn kết nối khi mở ứng dụng"; $c1e.Location = "110,108"; $c1e.Size = "350,22"
    $c1e.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular); $c1e.Checked = [bool]$cfg.sophos.enabled; $grp1.Controls.Add($c1e)

    # 2. VPN DR Epay
    $grp2 = New-Object System.Windows.Forms.GroupBox
    $grp2.Text = "  2. OpenVPN (VPN DR Epay)  "; $grp2.Location = "15,165"; $grp2.Size = "480,145"
    $grp2.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp2)

    $l2u = New-Object System.Windows.Forms.Label; $l2u.Text = "Tài khoản:"; $l2u.Location = "15,22"; $l2u.Size = "90,20"; $grp2.Controls.Add($l2u)
    $t2u = New-Object System.Windows.Forms.TextBox; $t2u.Location = "110,20"; $t2u.Size = "350,23"; $t2u.Text = $cfg.openvpn_dr.username; $grp2.Controls.Add($t2u)

    $l2p = New-Object System.Windows.Forms.Label; $l2p.Text = "Mật khẩu:"; $l2p.Location = "15,50"; $l2p.Size = "90,20"; $grp2.Controls.Add($l2p)
    $t2p = New-Object System.Windows.Forms.TextBox; $t2p.Location = "110,48"; $t2p.Size = "350,23"; $t2p.Text = $cfg.openvpn_dr.password; $grp2.Controls.Add($t2p)

    $l2s = New-Object System.Windows.Forms.Label; $l2s.Text = "Secret Key:"; $l2s.Location = "15,78"; $l2s.Size = "90,20"; $grp2.Controls.Add($l2s)
    $t2s = New-Object System.Windows.Forms.TextBox; $t2s.Location = "110,76"; $t2s.Size = "350,23"; $t2s.Text = $cfg.openvpn_dr.secret; $grp2.Controls.Add($t2s)

    $c2e = New-Object System.Windows.Forms.CheckBox; $c2e.Text = "Mặc định chọn kết nối khi mở ứng dụng"; $c2e.Location = "110,108"; $c2e.Size = "350,22"
    $c2e.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular); $c2e.Checked = [bool]$cfg.openvpn_dr.enabled; $grp2.Controls.Add($c2e)

    # 3. FortiClient Production
    $grp3 = New-Object System.Windows.Forms.GroupBox
    $grp3.Text = "  3. FortiClient (Production)  "; $grp3.Location = "15,320"; $grp3.Size = "480,145"
    $grp3.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp3)

    $l3u = New-Object System.Windows.Forms.Label; $l3u.Text = "Tài khoản:"; $l3u.Location = "15,22"; $l3u.Size = "90,20"; $grp3.Controls.Add($l3u)
    $t3u = New-Object System.Windows.Forms.TextBox; $t3u.Location = "110,20"; $t3u.Size = "350,23"; $t3u.Text = $cfg.forticlient.username; $grp3.Controls.Add($t3u)

    $l3p = New-Object System.Windows.Forms.Label; $l3p.Text = "Mật khẩu:"; $l3p.Location = "15,50"; $l3p.Size = "90,20"; $grp3.Controls.Add($l3p)
    $t3p = New-Object System.Windows.Forms.TextBox; $t3p.Location = "110,48"; $t3p.Size = "350,23"; $t3p.Text = $cfg.forticlient.password; $grp3.Controls.Add($t3p)

    $l3s = New-Object System.Windows.Forms.Label; $l3s.Text = "Gateway:"; $l3s.Location = "15,78"; $l3s.Size = "90,20"; $grp3.Controls.Add($l3s)
    $t3s = New-Object System.Windows.Forms.TextBox; $t3s.Location = "110,76"; $t3s.Size = "350,23"; $t3s.Text = $cfg.forticlient.server; $grp3.Controls.Add($t3s)

    $c3e = New-Object System.Windows.Forms.CheckBox; $c3e.Text = "Mặc định chọn kết nối khi mở ứng dụng"; $c3e.Location = "110,108"; $c3e.Size = "350,22"
    $c3e.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular); $c3e.Checked = [bool]$cfg.forticlient.enabled; $grp3.Controls.Add($c3e)

    # 4. FortiClient Office SSO
    $grp4 = New-Object System.Windows.Forms.GroupBox
    $grp4.Text = "  4. FortiClient (Office SSO SAML)  "; $grp4.Location = "15,475"; $grp4.Size = "480,120"
    $grp4.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp4)

    $l4s = New-Object System.Windows.Forms.Label; $l4s.Text = "Gateway SSO:"; $l4s.Location = "15,22"; $l4s.Size = "90,20"; $grp4.Controls.Add($l4s)
    $t4s = New-Object System.Windows.Forms.TextBox; $t4s.Location = "110,20"; $t4s.Size = "350,23"; $t4s.Text = $cfg.forti_office.server; $grp4.Controls.Add($t4s)

    $l4info = New-Object System.Windows.Forms.Label; $l4info.Text = "Xác thực SSO qua Microsoft Azure AD trên trình duyệt ngoài."
    $l4info.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $l4info.ForeColor = [System.Drawing.Color]::FromArgb(70, 80, 95)
    $l4info.Location = "110,48"; $l4info.Size = "350,18"; $grp4.Controls.Add($l4info)

    $c4e = New-Object System.Windows.Forms.CheckBox; $c4e.Text = "Mặc định chọn kết nối khi mở ứng dụng"; $c4e.Location = "110,72"; $c4e.Size = "350,22"
    $c4e.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Regular); $c4e.Checked = [bool]$cfg.forti_office.enabled; $grp4.Controls.Add($c4e)

    # Nut Luu Cau Hinh
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "LƯU CẤU HÌNH"
    $btnSave.Location = "140,610"; $btnSave.Size = "220,40"
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
        $cfg.forticlient.server = $t3s.Text.Trim()
        $cfg.forticlient.enabled = $c3e.Checked

        $cfg.forti_office.server = $t4s.Text.Trim()
        $cfg.forti_office.enabled = $c4e.Checked

        Save-Config $cfg

        # Dong bo checkbox man hinh chinh
        $chk1.Checked = $c1e.Checked
        $chk2.Checked = $c2e.Checked
        $chk3.Checked = $c3e.Checked
        $chk4.Checked = $c4e.Checked

        Log-Msg "[OK] Đã lưu toàn bộ cấu hình tài khoản && mật khẩu thành công!"
        $dlg.Close()
    })
    $dlg.Controls.Add($btnSave)
    $dlg.ShowDialog()
}

Log-Msg "Hệ thống sẵn sàng."
Log-Msg "1. Sophos SFOS: Tài khoản $($cfg.sophos.username)"
Log-Msg "2. VPN DR Epay: Tài khoản $($cfg.openvpn_dr.username)"
Log-Msg "3. FortiClient Production: Tài khoản $($cfg.forticlient.username)"
Log-Msg "4. FortiClient Office SSO: Gateway $($cfg.forti_office.server) (SAML SSO)"
Log-Msg "-> Sẵn sàng kết nối VPN (Chỉ lưu Registry khi bấm Login, tự động xóa khi đóng App)."

# Thuc thi GUI
[System.Windows.Forms.Application]::Run($form)
