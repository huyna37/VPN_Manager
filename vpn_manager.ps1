param(
    [string]$Copy = "",
    [string]$CopyProfile = ""
)

# UTF-8 Encoding & WinForms Assemblies
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

# Xac dinh thu muc ung dung & file cau hinh
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
$ps1File = Join-Path $baseDir "vpn_manager.ps1"
$exeFile = Join-Path $baseDir "VPN_Manager.exe"

$openvpnExe = "C:\Program Files\OpenVPN\bin\openvpn.exe"
$openvpnGuiExe = "C:\Program Files\OpenVPN\bin\openvpn-gui.exe"
if (-not (Test-Path $openvpnGuiExe)) {
    $openvpnGuiExe = "C:\Program Files (x86)\OpenVPN\bin\openvpn-gui.exe"
}
if (-not (Test-Path $openvpnExe)) {
    $openvpnExe = "C:\Program Files (x86)\OpenVPN\bin\openvpn.exe"
}

$userOpenVpnDir = Join-Path $env:USERPROFILE "OpenVPN\config"
if (-not (Test-Path $userOpenVpnDir)) {
    try { New-Item -ItemType Directory -Path $userOpenVpnDir -Force | Out-Null } catch {}
}

# Doc & Luu cau hinh JSON
function Get-Default-Config {
    return [PSCustomObject]@{
        sophos = [PSCustomObject]@{
            enabled = $true
            name = "1. Sophos SSL VPN"
            username = ""
            password = ""
            secret = ""
            dir = "config\sophos"
            configName = "sophos"
            ovpnFile = "sophos.ovpn"
        }
        openvpn_dr = [PSCustomObject]@{
            enabled = $true
            name = "2. OpenVPN (VPN DR Epay)"
            username = ""
            password = ""
            secret = ""
            dir = "config\epay-dr"
            configName = "epay-dr"
            ovpnFile = "epay-dr.ovpn"
        }
        forticlient = [PSCustomObject]@{
            enabled = $false
            name = "3. FortiClient"
            username = ""
            password = ""
            secret = ""
            server = "14.238.148.196:4443"
            servercert = "pin-sha256:zJcknXTR0B49qZAztOTh7VW80yIwZYdPCWwm2mio="
        }
    }
}

function Load-Config {
    if (Test-Path $configFile) {
        try {
            $parsed = Get-Content $configFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if ($parsed) { return $parsed }
        } catch {}
    }
    return Get-Default-Config
}

function Save-Config($cfgData) {
    $cfgData | ConvertTo-Json -Depth 5 | Set-Content -Path $configFile -Encoding UTF8
}

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
        $lbl2.Text = "[OK] DA COPY MAT KHAU + OTP VAO CLIPBOARD!"
        $lbl2.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
        $lbl2.ForeColor = [System.Drawing.Color]::FromArgb(74, 222, 128)
        $lbl2.Location = New-Object System.Drawing.Point(15, 32)
        $lbl2.Size = New-Object System.Drawing.Size(320, 22)
        $toast.Controls.Add($lbl2)

        $lbl3 = New-Object System.Windows.Forms.Label
        $otpText = if ($otp) { "Ma OTP: " + $otp + " (Het han sau " + $rem + "s)" } else { "Mat khau da san sang de Dan (Ctrl+V)" }
        $lbl3.Text = $otpText
        $lbl3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
        $lbl3.ForeColor = [System.Drawing.Color]::FromArgb(203, 213, 225)
        $lbl3.Location = New-Object System.Drawing.Point(15, 58)
        $lbl3.Size = New-Object System.Drawing.Size(320, 20)
        $toast.Controls.Add($lbl3)

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
    $prof = $null
    if ($cCfg.$targetProfileKey) {
        $prof = $cCfg.$targetProfileKey
    } else {
        if ($targetProfileKey -match "1|sophos") { $prof = $cCfg.sophos }
        elseif ($targetProfileKey -match "2|epay|dr|openvpn") { $prof = $cCfg.openvpn_dr }
        elseif ($targetProfileKey -match "3|forti") { $prof = $cCfg.forticlient }
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
$form.Size = New-Object System.Drawing.Size(590, 715)
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
$pnlHeader.Size = New-Object System.Drawing.Size(590, 65)
$pnlHeader.BackColor = [System.Drawing.Color]::FromArgb(20, 70, 120)
$form.Controls.Add($pnlHeader)

$lblTitle = New-Object System.Windows.Forms.Label
$lblTitle.Text = "QUAN LY KET NOI VPN VA OTP"
$lblTitle.Font = New-Object System.Drawing.Font("Segoe UI", 12, [System.Drawing.FontStyle]::Bold)
$lblTitle.ForeColor = [System.Drawing.Color]::White
$lblTitle.Location = New-Object System.Drawing.Point(20, 10)
$lblTitle.Size = New-Object System.Drawing.Size(540, 25)
$pnlHeader.Controls.Add($lblTitle)

$lblSub = New-Object System.Windows.Forms.Label
$lblSub.Text = "Quick Copy Pass+OTP, Widget Icon Noi va Tu Dong Ket Noi"
$lblSub.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)
$lblSub.ForeColor = [System.Drawing.Color]::FromArgb(200, 225, 250)
$lblSub.Location = New-Object System.Drawing.Point(20, 35)
$lblSub.Size = New-Object System.Drawing.Size(540, 20)
$pnlHeader.Controls.Add($lblSub)

# Group Danh sach VPN
$grpVPN = New-Object System.Windows.Forms.GroupBox
$grpVPN.Text = "  Danh Sach VPN & Phim Tat Copy Pass+OTP  "
$grpVPN.Location = New-Object System.Drawing.Point(20, 75)
$grpVPN.Size = New-Object System.Drawing.Size(535, 230)
$grpVPN.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$form.Controls.Add($grpVPN)

# Nhat ky hien thi
$lblLog = New-Object System.Windows.Forms.Label
$lblLog.Text = "Nhat ky hoat dong:"
$lblLog.Location = New-Object System.Drawing.Point(20, 410)
$lblLog.Size = New-Object System.Drawing.Size(200, 18)
$form.Controls.Add($lblLog)

$txtLog = New-Object System.Windows.Forms.TextBox
$txtLog.Location = New-Object System.Drawing.Point(20, 430)
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
    $wLblHint.Text = "(Click de Copy Pass+OTP)"
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
        $wLblOtp.Text = "Khong dung OTP"
        $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
    }

    # Ham thuc thi Copy khi click vao Widget
    $doCopyWidget = {
        param($s, $e)
        $curK = [string]$wForm.Tag
        $pObj = $cfg.$curK
        if (-not $pObj) { return }
        $sec = $pObj.secret
        $p = $pObj.password
        $targetName = if ($pObj.name) { $pObj.name } else { $curK }
        $otp = ""
        if (-not [string]::IsNullOrWhiteSpace($sec)) { $otp = Get-TOTP -SecretKey $sec }
        $fullPass = if ($otp) { "$p$otp" } else { $p }

        if ([string]::IsNullOrEmpty($fullPass)) {
            [System.Windows.Forms.MessageBox]::Show("Chua co mat khau cho $targetName!`nVui long bam 'Cai dat' de nhap.", "VPN Manager", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        try {
            [System.Windows.Forms.Clipboard]::SetText($fullPass)
            $wForm.BackColor = [System.Drawing.Color]::FromArgb(22, 101, 52)
            $wLblTitle.Text = "[DA CHEP PASS+OTP!]"
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
                Log-Msg "[OK WIDGET] Da copy Pass+OTP cua $targetName! (OTP: " + $otp + " - Con " + $rem + "s)"
            } else {
                Log-Msg "[OK WIDGET] Da copy Mat khau cua $targetName vao Clipboard!"
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
            $wLblOtp.Text = "Khong dung OTP"
            $wLblOtp.ForeColor = [System.Drawing.Color]::FromArgb(148, 163, 184)
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
    Log-Msg "[OK WIDGET] Da mo Icon Noi cho $pName. Keo tha hoac click de copy."
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
$mItemForti.Text = "3. Copy FortiClient"
$mItemForti.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemForti.Add_Click({ Copy-VpnCredentials "forticlient" })
$trayMenu.Items.Add($mItemForti) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemWidgetSophos = New-Object System.Windows.Forms.ToolStripMenuItem("Mo Widget Noi - Sophos")
$mItemWidgetSophos.Add_Click({ Show-FloatingWidget "sophos" })
$trayMenu.Items.Add($mItemWidgetSophos) | Out-Null

$mItemWidgetDr = New-Object System.Windows.Forms.ToolStripMenuItem("Mo Widget Noi - OpenVPN DR")
$mItemWidgetDr.Add_Click({ Show-FloatingWidget "openvpn_dr" })
$trayMenu.Items.Add($mItemWidgetDr) | Out-Null

$trayMenu.Items.Add((New-Object System.Windows.Forms.ToolStripSeparator)) | Out-Null

$mItemShow = New-Object System.Windows.Forms.ToolStripMenuItem("Mo Cua So Chinh")
$mItemShow.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$mItemShow.Add_Click({
    $form.Show()
    $form.WindowState = [System.Windows.Forms.FormWindowState]::Normal
    $form.Activate()
    $form.BringToFront()
})
$trayMenu.Items.Add($mItemShow) | Out-Null

$mItemExit = New-Object System.Windows.Forms.ToolStripMenuItem("Thoat Hoan Toan")
$mItemExit.ForeColor = [System.Drawing.Color]::DarkRed
$mItemExit.Add_Click({
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
        $trayIcon.ShowBalloonTip(1500, "VPN Manager", "Ung dung da thu gon xuong Khay Taskbar. Click chuot vao icon ben canh dong ho de copy nhanh Pass+OTP!", [System.Windows.Forms.ToolTipIcon]::Info)
    }
})

$form.Add_FormClosing({
    param($s, $e)
    $trayIcon.Visible = $false
    $trayIcon.Dispose()
})

# --- THIET KE CAC DONG VPN TRONG GIAO DIEN ---

# ROW 1: Sophos SSL VPN
$chk1 = New-Object System.Windows.Forms.CheckBox
$chk1.Text = "1. Sophos SSL VPN"
$chk1.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$chk1.Location = New-Object System.Drawing.Point(15, 22)
$chk1.Size = New-Object System.Drawing.Size(195, 26)
$chk1.Checked = [bool]$cfg.sophos.enabled
$grpVPN.Controls.Add($chk1)

$lblSt1 = New-Object System.Windows.Forms.Label
$lblSt1.Text = "[o] Chua ket noi"
$lblSt1.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt1.ForeColor = [System.Drawing.Color]::Gray
$lblSt1.Location = New-Object System.Drawing.Point(215, 26)
$lblSt1.Size = New-Object System.Drawing.Size(185, 20)
$grpVPN.Controls.Add($lblSt1)

$lblOtp1 = New-Object System.Windows.Forms.Label
$lblOtp1.Text = ""
$lblOtp1.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblOtp1.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtp1.Location = New-Object System.Drawing.Point(405, 26)
$lblOtp1.Size = New-Object System.Drawing.Size(120, 20)
$grpVPN.Controls.Add($lblOtp1)

$btnCopy1 = New-Object System.Windows.Forms.Button
$btnCopy1.Text = "Copy Pass+OTP"
$btnCopy1.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnCopy1.Location = New-Object System.Drawing.Point(30, 50)
$btnCopy1.Size = New-Object System.Drawing.Size(235, 29)
$btnCopy1.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnCopy1.ForeColor = [System.Drawing.Color]::White
$btnCopy1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopy1.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopy1.Add_Click({ Copy-VpnCredentials "sophos" $btnCopy1 })
$grpVPN.Controls.Add($btnCopy1)

$btnFloat1 = New-Object System.Windows.Forms.Button
$btnFloat1.Text = "Icon Noi"
$btnFloat1.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnFloat1.Location = New-Object System.Drawing.Point(275, 50)
$btnFloat1.Size = New-Object System.Drawing.Size(235, 29)
$btnFloat1.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$btnFloat1.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnFloat1.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFloat1.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnFloat1.Add_Click({ Show-FloatingWidget "sophos" })
$grpVPN.Controls.Add($btnFloat1)

# ROW 2: OpenVPN DR Epay
$chk2 = New-Object System.Windows.Forms.CheckBox
$chk2.Text = "2. OpenVPN (VPN DR Epay)"
$chk2.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$chk2.Location = New-Object System.Drawing.Point(15, 88)
$chk2.Size = New-Object System.Drawing.Size(195, 26)
$chk2.Checked = [bool]$cfg.openvpn_dr.enabled
$grpVPN.Controls.Add($chk2)

$lblSt2 = New-Object System.Windows.Forms.Label
$lblSt2.Text = "[o] Chua ket noi"
$lblSt2.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt2.ForeColor = [System.Drawing.Color]::Gray
$lblSt2.Location = New-Object System.Drawing.Point(215, 92)
$lblSt2.Size = New-Object System.Drawing.Size(185, 20)
$grpVPN.Controls.Add($lblSt2)

$lblOtp2 = New-Object System.Windows.Forms.Label
$lblOtp2.Text = ""
$lblOtp2.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblOtp2.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtp2.Location = New-Object System.Drawing.Point(405, 92)
$lblOtp2.Size = New-Object System.Drawing.Size(120, 20)
$grpVPN.Controls.Add($lblOtp2)

$btnCopy2 = New-Object System.Windows.Forms.Button
$btnCopy2.Text = "Copy Pass+OTP"
$btnCopy2.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnCopy2.Location = New-Object System.Drawing.Point(30, 116)
$btnCopy2.Size = New-Object System.Drawing.Size(235, 29)
$btnCopy2.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnCopy2.ForeColor = [System.Drawing.Color]::White
$btnCopy2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopy2.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopy2.Add_Click({ Copy-VpnCredentials "openvpn_dr" $btnCopy2 })
$grpVPN.Controls.Add($btnCopy2)

$btnFloat2 = New-Object System.Windows.Forms.Button
$btnFloat2.Text = "Icon Noi"
$btnFloat2.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnFloat2.Location = New-Object System.Drawing.Point(275, 116)
$btnFloat2.Size = New-Object System.Drawing.Size(235, 29)
$btnFloat2.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$btnFloat2.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnFloat2.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFloat2.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnFloat2.Add_Click({ Show-FloatingWidget "openvpn_dr" })
$grpVPN.Controls.Add($btnFloat2)

# ROW 3: FortiClient
$chk3 = New-Object System.Windows.Forms.CheckBox
$chk3.Text = "3. FortiClient"
$chk3.Font = New-Object System.Drawing.Font("Segoe UI", 9.5, [System.Drawing.FontStyle]::Bold)
$chk3.Location = New-Object System.Drawing.Point(15, 154)
$chk3.Size = New-Object System.Drawing.Size(195, 26)
$chk3.Checked = [bool]$cfg.forticlient.enabled
$grpVPN.Controls.Add($chk3)

$lblSt3 = New-Object System.Windows.Forms.Label
$lblSt3.Text = "[o] Chua ket noi"
$lblSt3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblSt3.ForeColor = [System.Drawing.Color]::Gray
$lblSt3.Location = New-Object System.Drawing.Point(215, 158)
$lblSt3.Size = New-Object System.Drawing.Size(185, 20)
$grpVPN.Controls.Add($lblSt3)

$lblOtp3 = New-Object System.Windows.Forms.Label
$lblOtp3.Text = ""
$lblOtp3.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)
$lblOtp3.ForeColor = [System.Drawing.Color]::FromArgb(2, 132, 199)
$lblOtp3.Location = New-Object System.Drawing.Point(405, 158)
$lblOtp3.Size = New-Object System.Drawing.Size(120, 20)
$grpVPN.Controls.Add($lblOtp3)

$btnCopy3 = New-Object System.Windows.Forms.Button
$btnCopy3.Text = "Copy Mat Khau"
$btnCopy3.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnCopy3.Location = New-Object System.Drawing.Point(30, 182)
$btnCopy3.Size = New-Object System.Drawing.Size(235, 29)
$btnCopy3.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnCopy3.ForeColor = [System.Drawing.Color]::White
$btnCopy3.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnCopy3.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnCopy3.Add_Click({ Copy-VpnCredentials "forticlient" $btnCopy3 })
$grpVPN.Controls.Add($btnCopy3)

$btnFloat3 = New-Object System.Windows.Forms.Button
$btnFloat3.Text = "Icon Noi"
$btnFloat3.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$btnFloat3.Location = New-Object System.Drawing.Point(275, 182)
$btnFloat3.Size = New-Object System.Drawing.Size(235, 29)
$btnFloat3.BackColor = [System.Drawing.Color]::FromArgb(243, 244, 246)
$btnFloat3.ForeColor = [System.Drawing.Color]::FromArgb(55, 65, 81)
$btnFloat3.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnFloat3.Cursor = [System.Windows.Forms.Cursors]::Hand
$btnFloat3.Add_Click({ Show-FloatingWidget "forticlient" })
$grpVPN.Controls.Add($btnFloat3)

# Nut bam Ket noi
$btnConnect = New-Object System.Windows.Forms.Button
$btnConnect.Text = ">> KET NOI DA CHON"
$btnConnect.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnConnect.Location = New-Object System.Drawing.Point(20, 320)
$btnConnect.Size = New-Object System.Drawing.Size(260, 38)
$btnConnect.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 215)
$btnConnect.ForeColor = [System.Drawing.Color]::White
$btnConnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnConnect)

$btnAll = New-Object System.Windows.Forms.Button
$btnAll.Text = "KET NOI TAT CA"
$btnAll.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
$btnAll.Location = New-Object System.Drawing.Point(295, 320)
$btnAll.Size = New-Object System.Drawing.Size(260, 38)
$btnAll.BackColor = [System.Drawing.Color]::FromArgb(46, 125, 50)
$btnAll.ForeColor = [System.Drawing.Color]::White
$btnAll.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnAll.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnAll)

# Nut bam Ngat & Cai dat
$btnDisconnect = New-Object System.Windows.Forms.Button
$btnDisconnect.Text = "[X] TAT TOAN BO VPN"
$btnDisconnect.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnDisconnect.Location = New-Object System.Drawing.Point(20, 368)
$btnDisconnect.Size = New-Object System.Drawing.Size(260, 32)
$btnDisconnect.BackColor = [System.Drawing.Color]::FromArgb(211, 47, 47)
$btnDisconnect.ForeColor = [System.Drawing.Color]::White
$btnDisconnect.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnDisconnect.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnDisconnect)

$btnConfig = New-Object System.Windows.Forms.Button
$btnConfig.Text = "Cai dat Tai khoan va Key"
$btnConfig.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
$btnConfig.Location = New-Object System.Drawing.Point(295, 368)
$btnConfig.Size = New-Object System.Drawing.Size(260, 32)
$btnConfig.BackColor = [System.Drawing.Color]::FromArgb(230, 235, 245)
$btnConfig.ForeColor = [System.Drawing.Color]::FromArgb(30, 30, 30)
$btnConfig.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
$btnConfig.Cursor = [System.Windows.Forms.Cursors]::Hand
$form.Controls.Add($btnConfig)

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
            $mItemSophos.Text = "1. Copy Sophos (Chua co secret)"
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

        # 3. Cap nhat OTP Live FortiClient neu co secret
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
            $btnCopy3.Text = "Copy Mat Khau"
            $mItemForti.Text = "3. Copy Mat Khau FortiClient"
        }

        # Cap nhat ToolTip Tray Icon
        $trayIcon.Text = "VPN Manager | Sophos: $otp1 | DR: $otp2"

        # Moi 2 giay kiem tra trang thai IP ket noi VPN thuc te
        if ($script:tickCounter % 2 -eq 0) {
            # 1. Sophos SSL VPN (172.16.x.x)
            $sophosIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match "^172\.16\." -and $_.AddressState -eq "Preferred" }
            if ($sophosIP) {
                $lblSt1.Text = "[*] DA KET NOI (" + $sophosIP[0].IPAddress + ")"
                $lblSt1.ForeColor = [System.Drawing.Color]::Green
            } else {
                $lblSt1.Text = "[o] Chua ket noi"
                $lblSt1.ForeColor = [System.Drawing.Color]::Gray
            }

            # 2. OpenVPN DR Epay (10.150.x.x)
            $drIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { $_.IPAddress -match "^10\.150\." -and $_.AddressState -eq "Preferred" }
            if ($drIP) {
                $lblSt2.Text = "[*] DA KET NOI (" + $drIP[0].IPAddress + ")"
                $lblSt2.ForeColor = [System.Drawing.Color]::Green
            } else {
                $lblSt2.Text = "[o] Chua ket noi"
                $lblSt2.ForeColor = [System.Drawing.Color]::Gray
            }

            # 3. FortiClient
            $fortiConnected = $false
            $fortiDisplayIP = ""
            $ocProc = Get-Process -Name "openconnect", "openfortivpn", "forticlient" -ErrorAction SilentlyContinue
            if ($ocProc) {
                $logPath = Join-Path $baseDir "forti_openconnect.log"
                if (Test-Path $logPath) {
                    $logText = Get-Content $logPath -Raw -ErrorAction SilentlyContinue
                    if ($logText -match "Configured as\s+([0-9\.]+)|Got Legacy IP address\s+([0-9\.]+)") {
                        $fortiDisplayIP = if ($matches[1]) { $matches[1] } else { $matches[2] }
                        $fortiConnected = $true
                    }
                }
                if (-not $fortiConnected) {
                    $vpnIP = Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | Where-Object { 
                        $_.InterfaceAlias -notmatch "^(Ethernet|Wi-Fi|Loopback|OpenVPN|Bluetooth)" -and $_.AddressState -eq "Preferred" 
                    } 
                    if ($vpnIP) {
                        $fortiDisplayIP = $vpnIP[0].IPAddress
                        $fortiConnected = $true
                    }
                }
            }

            if ($fortiConnected -and ![string]::IsNullOrEmpty($fortiDisplayIP)) {
                $lblSt3.Text = "[*] DA KET NOI (" + $fortiDisplayIP + ")"
                $lblSt3.ForeColor = [System.Drawing.Color]::Green
            } else {
                $lblSt3.Text = "[o] Chua ket noi"
                $lblSt3.ForeColor = [System.Drawing.Color]::Gray
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

# Helper ket noi FortiClient
function Connect-FortiClient {
    Log-Msg "-------------------------------------------"
    Log-Msg "Dang ket noi: FortiClient (Tai khoan $($cfg.forticlient.username))..."
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
    Log-Msg "[OK] Da gui lenh ket noi FortiClient!"
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

    Log-Msg "[OK] Da ngat ket noi VPN thanh cong!"
}

# Function thuc thi ket noi cac VPN da chon
function Do-Connect([bool]$do1, [bool]$do2, [bool]$do3) {
    if ($do1) {
        Connect-OpenVpnProfile "1. Sophos SSL VPN" "sophos" $cfg.sophos.dir $cfg.sophos.ovpnFile $cfg.sophos.username $cfg.sophos.password $cfg.sophos.secret
        if ($do2 -or $do3) { Start-Sleep -Seconds 1 }
    }

    if ($do2) {
        Connect-OpenVpnProfile "2. OpenVPN (VPN DR Epay)" "epay-dr" $cfg.openvpn_dr.dir $cfg.openvpn_dr.ovpnFile $cfg.openvpn_dr.username $cfg.openvpn_dr.password $cfg.openvpn_dr.secret
        if ($do3) { Start-Sleep -Seconds 1 }
    }

    if ($do3) {
        Connect-FortiClient
    }

    Log-Msg "-------------------------------------------"
    Log-Msg "[OK] Hoan tat gui yeu cau ket noi."
}

# --- SU KIEN NUT BAM KET NOI ---
$btnConnect.Add_Click({ Do-Connect $chk1.Checked $chk2.Checked $chk3.Checked })
$btnAll.Add_Click({
    $chk1.Checked = $true
    $chk2.Checked = $true
    $chk3.Checked = $true
    Do-Connect $true $true $true
})
$btnDisconnect.Add_Click({ Stop-AllVPN })

# Popup Cai dat Tai khoan, Mat khau va Secret Key
$btnConfig.Add_Click({
    $dlg = New-Object System.Windows.Forms.Form
    $dlg.Text = "Cai Dat Tai Khoan & Mat Khau VPN"
    $dlg.Size = New-Object System.Drawing.Size(530, 650)
    $dlg.StartPosition = "CenterParent"
    $dlg.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
    $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.AutoScroll = $true

    # 1. Sophos SSL VPN
    $grp1 = New-Object System.Windows.Forms.GroupBox
    $grp1.Text = "  1. Sophos SSL VPN  "; $grp1.Location = "15,10"; $grp1.Size = "480,155"
    $grp1.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp1)

    $l1u = New-Object System.Windows.Forms.Label; $l1u.Text = "Tai khoan:"; $l1u.Location = "15,25"; $l1u.Size = "90,20"; $grp1.Controls.Add($l1u)
    $t1u = New-Object System.Windows.Forms.TextBox; $t1u.Location = "110,23"; $t1u.Size = "350,23"; $t1u.Text = $cfg.sophos.username; $grp1.Controls.Add($t1u)

    $l1p = New-Object System.Windows.Forms.Label; $l1p.Text = "Mat khau:"; $l1p.Location = "15,55"; $l1p.Size = "90,20"; $grp1.Controls.Add($l1p)
    $t1p = New-Object System.Windows.Forms.TextBox; $t1p.Location = "110,53"; $t1p.Size = "350,23"; $t1p.Text = $cfg.sophos.password; $grp1.Controls.Add($t1p)

    $l1s = New-Object System.Windows.Forms.Label; $l1s.Text = "Secret Key:"; $l1s.Location = "15,85"; $l1s.Size = "90,20"; $grp1.Controls.Add($l1s)
    $t1s = New-Object System.Windows.Forms.TextBox; $t1s.Location = "110,83"; $t1s.Size = "350,23"; $t1s.Text = $cfg.sophos.secret; $grp1.Controls.Add($t1s)

    $c1e = New-Object System.Windows.Forms.CheckBox; $c1e.Text = "Mac dinh chon ket noi khi mo ung dung"; $c1e.Location = "110,118"; $c1e.Size = "350,24"
    $c1e.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular); $c1e.Checked = [bool]$cfg.sophos.enabled; $grp1.Controls.Add($c1e)

    # 2. VPN DR Epay
    $grp2 = New-Object System.Windows.Forms.GroupBox
    $grp2.Text = "  2. OpenVPN (VPN DR Epay)  "; $grp2.Location = "15,175"; $grp2.Size = "480,155"
    $grp2.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp2)

    $l2u = New-Object System.Windows.Forms.Label; $l2u.Text = "Tai khoan:"; $l2u.Location = "15,25"; $l2u.Size = "90,20"; $grp2.Controls.Add($l2u)
    $t2u = New-Object System.Windows.Forms.TextBox; $t2u.Location = "110,23"; $t2u.Size = "350,23"; $t2u.Text = $cfg.openvpn_dr.username; $grp2.Controls.Add($t2u)

    $l2p = New-Object System.Windows.Forms.Label; $l2p.Text = "Mat khau:"; $l2p.Location = "15,55"; $l2p.Size = "90,20"; $grp2.Controls.Add($l2p)
    $t2p = New-Object System.Windows.Forms.TextBox; $t2p.Location = "110,53"; $t2p.Size = "350,23"; $t2p.Text = $cfg.openvpn_dr.password; $grp2.Controls.Add($t2p)

    $l2s = New-Object System.Windows.Forms.Label; $l2s.Text = "Secret Key:"; $l2s.Location = "15,85"; $l2s.Size = "90,20"; $grp2.Controls.Add($l2s)
    $t2s = New-Object System.Windows.Forms.TextBox; $t2s.Location = "110,83"; $t2s.Size = "350,23"; $t2s.Text = $cfg.openvpn_dr.secret; $grp2.Controls.Add($t2s)

    $c2e = New-Object System.Windows.Forms.CheckBox; $c2e.Text = "Mac dinh chon ket noi khi mo ung dung"; $c2e.Location = "110,118"; $c2e.Size = "350,24"
    $c2e.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular); $c2e.Checked = [bool]$cfg.openvpn_dr.enabled; $grp2.Controls.Add($c2e)

    # 3. FortiClient
    $grp3 = New-Object System.Windows.Forms.GroupBox
    $grp3.Text = "  3. FortiClient  "; $grp3.Location = "15,340"; $grp3.Size = "480,155"
    $grp3.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $dlg.Controls.Add($grp3)

    $l3u = New-Object System.Windows.Forms.Label; $l3u.Text = "Tai khoan:"; $l3u.Location = "15,25"; $l3u.Size = "90,20"; $grp3.Controls.Add($l3u)
    $t3u = New-Object System.Windows.Forms.TextBox; $t3u.Location = "110,23"; $t3u.Size = "350,23"; $t3u.Text = $cfg.forticlient.username; $grp3.Controls.Add($t3u)

    $l3p = New-Object System.Windows.Forms.Label; $l3p.Text = "Mat khau:"; $l3p.Location = "15,55"; $l3p.Size = "90,20"; $grp3.Controls.Add($l3p)
    $t3p = New-Object System.Windows.Forms.TextBox; $t3p.Location = "110,53"; $t3p.Size = "350,23"; $t3p.Text = $cfg.forticlient.password; $grp3.Controls.Add($t3p)

    $l3s = New-Object System.Windows.Forms.Label; $l3s.Text = "Secret Key:"; $l3s.Location = "15,85"; $l3s.Size = "90,20"; $grp3.Controls.Add($l3s)
    $t3s = New-Object System.Windows.Forms.TextBox; $t3s.Location = "110,83"; $t3s.Size = "350,23"; $t3s.Text = $cfg.forticlient.secret; $grp3.Controls.Add($t3s)

    $c3e = New-Object System.Windows.Forms.CheckBox; $c3e.Text = "Mac dinh chon ket noi khi mo ung dung"; $c3e.Location = "110,118"; $c3e.Size = "350,24"
    $c3e.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Regular); $c3e.Checked = [bool]$cfg.forticlient.enabled; $grp3.Controls.Add($c3e)

    # Nut Luu Cau Hinh
    $btnSave = New-Object System.Windows.Forms.Button
    $btnSave.Text = "LUU CAU HINH"
    $btnSave.Location = "150,510"; $btnSave.Size = "200,42"
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
        $cfg.forticlient.secret = $t3s.Text.Trim()
        $cfg.forticlient.enabled = $c3e.Checked

        Save-Config $cfg

        # Dong bo checkbox man hinh chinh
        $chk1.Checked = $c1e.Checked
        $chk2.Checked = $c2e.Checked
        $chk3.Checked = $c3e.Checked

        Log-Msg "[OK] Da luu cau hinh tai khoan & mat khau thanh cong!"
        $dlg.Close()
    })
    $dlg.Controls.Add($btnSave)
    $dlg.ShowDialog()
})

Log-Msg "He thong san sang."
Log-Msg "1. Sophos SFOS: Tai khoan $($cfg.sophos.username)"
Log-Msg "2. VPN DR Epay: Tai khoan $($cfg.openvpn_dr.username)"
Log-Msg "3. FortiClient: Tai khoan $($cfg.forticlient.username)"
Log-Msg "-> Ban co the bam 'Copy Pass+OTP' hoac 'Icon Noi' cho tung VPN!"

# Thuc thi GUI
[System.Windows.Forms.Application]::Run($form)
