param(
    [string]$InputHost = "192.168.0.188",
    [int]$InputPort = 5905,
    [string]$WindowProcessName = "gst-launch-1.0",
    [int]$GuestX = 16384,
    [int]$GuestY = 16384,
    [int]$ParkX = 5000,
    [int]$ParkY = 5000,
    [int]$CloseX = 30000,
    [int]$CloseY = 3000,
    [int]$RoiWidth = 420,
    [int]$RoiHeight = 360,
    [int]$Trials = 3,
    [int]$PrepWaitMs = 2400,
    [int]$CleanNeutralMax = 8000,
    [int]$MinChangedThreshold = 450,
    [int]$MaxWaitMs = 3000,
    [int]$FrameIntervalMs = 10,
    [switch]$UsePark,
    [ValidateSet("click", "key", "combo")]
    [string]$OpenAction = "click",
    [ValidateSet("left", "right")]
    [string]$OpenButton = "right",
    [string]$OpenQcode = "a",
    [int]$PrepBackspaces = 4,
    [ValidateSet("open", "close")]
    [string]$Mode = "open",
    [ValidateSet("tcp", "local")]
    [string]$Trigger = "tcp",
    [switch]$AssumeOpen,
    [switch]$UseVideoArea,
    [int]$SourceWidth = 1024,
    [int]$SourceHeight = 768,
    [int]$ToolbarHeight = 32,
    [switch]$ResizeJolt,
    [int]$ResizeJoltPixels = 24,
    [string]$OutDir = "latency-captures"
)

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32Measure {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern void keybd_event(byte bVk, byte bScan, uint dwFlags, UIntPtr dwExtraInfo);

    [DllImport("user32.dll")]
    public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter,
        int X, int Y, int cx, int cy, uint uFlags);
}
"@

function Get-TargetRect {
    param([string]$Name)

    $proc = Get-Process -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1

    if (-not $proc) {
        throw "No visible window found for process '$Name'."
    }

    [Win32Measure+RECT]$windowRect = New-Object Win32Measure+RECT
    if (-not [Win32Measure]::GetWindowRect($proc.MainWindowHandle, [ref]$windowRect)) {
        throw "GetWindowRect failed for PID $($proc.Id)."
    }

    [Win32Measure+RECT]$clientRect = New-Object Win32Measure+RECT
    if (-not [Win32Measure]::GetClientRect($proc.MainWindowHandle, [ref]$clientRect)) {
        throw "GetClientRect failed for PID $($proc.Id)."
    }

    [Win32Measure+POINT]$clientTopLeft = New-Object Win32Measure+POINT
    $clientTopLeft.X = 0
    $clientTopLeft.Y = 0
    if (-not [Win32Measure]::ClientToScreen($proc.MainWindowHandle, [ref]$clientTopLeft)) {
        throw "ClientToScreen failed for PID $($proc.Id)."
    }

    [void][Win32Measure]::SetForegroundWindow($proc.MainWindowHandle)
    Start-Sleep -Milliseconds 150

    [pscustomobject]@{
        Pid = $proc.Id
        Left = $clientTopLeft.X
        Top = $clientTopLeft.Y
        Width = $clientRect.Right - $clientRect.Left
        Height = $clientRect.Bottom - $clientRect.Top
        WindowLeft = $windowRect.Left
        WindowTop = $windowRect.Top
        WindowWidth = $windowRect.Right - $windowRect.Left
        WindowHeight = $windowRect.Bottom - $windowRect.Top
        Title = $proc.MainWindowTitle
        Hwnd = $proc.MainWindowHandle
    }
}

function Convert-ToVideoRect {
    param($WindowRect, [int]$SourceWidth, [int]$SourceHeight, [int]$ToolbarHeight)

    if ($SourceWidth -le 0 -or $SourceHeight -le 0) {
        return $WindowRect
    }

    $clientW = [Math]::Max(1, $WindowRect.Width)
    $clientH = [Math]::Max(1, $WindowRect.Height)
    $availH = [Math]::Max(1, $clientH - $ToolbarHeight)

    if ([int64]$clientW * $SourceHeight -le [int64]$availH * $SourceWidth) {
        $videoW = $clientW
        $videoH = [int]([int64]$clientW * $SourceHeight / $SourceWidth)
    } else {
        $videoH = $availH
        $videoW = [int]([int64]$availH * $SourceWidth / $SourceHeight)
    }

    $videoX = [int](($clientW - $videoW) / 2)
    $videoY = $ToolbarHeight + [int](($availH - $videoH) / 2)

    [pscustomobject]@{
        Pid = $WindowRect.Pid
        Left = $WindowRect.Left + $videoX
        Top = $WindowRect.Top + $videoY
        Width = $videoW
        Height = $videoH
        WindowLeft = $WindowRect.WindowLeft
        WindowTop = $WindowRect.WindowTop
        WindowWidth = $WindowRect.WindowWidth
        WindowHeight = $WindowRect.WindowHeight
        Title = $WindowRect.Title
        Hwnd = $WindowRect.Hwnd
    }
}

function Invoke-ResizeJolt {
    param($WindowRect, [int]$Pixels)

    $flags = 0x0004 -bor 0x0010
    [void][Win32Measure]::SetWindowPos(
        $WindowRect.Hwnd, [IntPtr]::Zero,
        $WindowRect.WindowLeft, $WindowRect.WindowTop,
        $WindowRect.WindowWidth + $Pixels, $WindowRect.WindowHeight + $Pixels,
        $flags)
    Start-Sleep -Milliseconds 180
    [void][Win32Measure]::SetWindowPos(
        $WindowRect.Hwnd, [IntPtr]::Zero,
        $WindowRect.WindowLeft, $WindowRect.WindowTop,
        $WindowRect.WindowWidth, $WindowRect.WindowHeight,
        $flags)
    Start-Sleep -Milliseconds 220
}

function New-RoiRect {
    param($WindowRect, [int]$GuestX, [int]$GuestY, [int]$Width, [int]$Height)

    $cx = $WindowRect.Left + [int]([double]$WindowRect.Width * $GuestX / 32767.0)
    $cy = $WindowRect.Top + [int]([double]$WindowRect.Height * $GuestY / 32767.0)
    [System.Drawing.Rectangle]::new(
        [Math]::Max($WindowRect.Left, $cx - [int]($Width / 2)),
        [Math]::Max($WindowRect.Top, $cy - [int]($Height / 2)),
        [Math]::Min($Width, $WindowRect.Left + $WindowRect.Width - [Math]::Max($WindowRect.Left, $cx - [int]($Width / 2))),
        [Math]::Min($Height, $WindowRect.Top + $WindowRect.Height - [Math]::Max($WindowRect.Top, $cy - [int]($Height / 2)))
    )
}

function Convert-NormToScreenPoint {
    param($WindowRect, [int]$X, [int]$Y)

    [pscustomobject]@{
        X = $WindowRect.Left + [int]([double]$WindowRect.Width * $X / 32767.0)
        Y = $WindowRect.Top + [int]([double]$WindowRect.Height * $Y / 32767.0)
    }
}

function Invoke-LocalClick {
    param($WindowRect, [int]$X, [int]$Y, [string]$Button)

    $pt = Convert-NormToScreenPoint -WindowRect $WindowRect -X $X -Y $Y
    [void][Win32Measure]::SetCursorPos($pt.X, $pt.Y)
    Start-Sleep -Milliseconds 80
    if ($Button -eq "right") {
        [Win32Measure]::mouse_event(0x0008, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
        [Win32Measure]::mouse_event(0x0010, 0, 0, 0, [UIntPtr]::Zero)
    } else {
        [Win32Measure]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
        Start-Sleep -Milliseconds 40
        [Win32Measure]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
    }
}

function Invoke-LocalEscape {
    param($WindowRect)

    $pt = Convert-NormToScreenPoint -WindowRect $WindowRect -X 16384 -Y 16384
    [void][Win32Measure]::SetCursorPos($pt.X, $pt.Y)
    Start-Sleep -Milliseconds 50
    [Win32Measure]::keybd_event(0x1B, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 40
    [Win32Measure]::keybd_event(0x1B, 0, 0x0002, [UIntPtr]::Zero)
}

function Invoke-LocalKey {
    param($WindowRect, [string]$Qcode)

    $pt = Convert-NormToScreenPoint -WindowRect $WindowRect -X 16384 -Y 16384
    [void][Win32Measure]::SetCursorPos($pt.X, $pt.Y)
    Start-Sleep -Milliseconds 30

    $vk = $null
    if ($Qcode.Length -eq 1 -and $Qcode -match '^[a-zA-Z]$') {
        $vk = [byte][char]($Qcode.ToUpperInvariant())
    } elseif ($Qcode -eq "backspace") {
        $vk = [byte]0x08
    } elseif ($Qcode -eq "esc") {
        $vk = [byte]0x1B
    } elseif ($Qcode -eq "enter") {
        $vk = [byte]0x0D
    }

    if ($null -eq $vk) {
        throw "Local key trigger does not know qcode '$Qcode'."
    }

    [Win32Measure]::keybd_event($vk, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 30
    [Win32Measure]::keybd_event($vk, 0, 0x0002, [UIntPtr]::Zero)
}

function Capture-Rect {
    param([System.Drawing.Rectangle]$Rect)

    $bmp = New-Object System.Drawing.Bitmap $Rect.Width, $Rect.Height, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0, $Rect.Size)
    $g.Dispose()
    $bmp
}

function Get-BitmapBytes {
    param([System.Drawing.Bitmap]$Bitmap)

    $rect = [System.Drawing.Rectangle]::new(0, 0, $Bitmap.Width, $Bitmap.Height)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $len = [Math]::Abs($data.Stride) * $Bitmap.Height
        $bytes = New-Object byte[] $len
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $len)
        [pscustomobject]@{ Bytes = $bytes; Stride = [Math]::Abs($data.Stride); Width = $Bitmap.Width; Height = $Bitmap.Height }
    } finally {
        $Bitmap.UnlockBits($data)
    }
}

function Compare-Frame {
    param($BaseInfo, $CurInfo)

    $changed = 0
    $neutralLight = 0
    $samples = 0
    $step = 2
    for ($y = 0; $y -lt $BaseInfo.Height; $y += $step) {
        $row = $y * $BaseInfo.Stride
        for ($x = 0; $x -lt $BaseInfo.Width; $x += $step) {
            $i = $row + $x * 4
            $b0 = [int]$BaseInfo.Bytes[$i]
            $g0 = [int]$BaseInfo.Bytes[$i + 1]
            $r0 = [int]$BaseInfo.Bytes[$i + 2]
            $b1 = [int]$CurInfo.Bytes[$i]
            $g1 = [int]$CurInfo.Bytes[$i + 1]
            $r1 = [int]$CurInfo.Bytes[$i + 2]
            $delta = [Math]::Abs($r1 - $r0) + [Math]::Abs($g1 - $g0) + [Math]::Abs($b1 - $b0)
            if ($delta -gt 70) {
                $changed++
            }
            $maxc = [Math]::Max($r1, [Math]::Max($g1, $b1))
            $minc = [Math]::Min($r1, [Math]::Min($g1, $b1))
            if ($maxc -gt 172 -and ($maxc - $minc) -lt 38) {
                $neutralLight++
            }
            $samples++
        }
    }
    [pscustomobject]@{
        Changed = $changed
        NeutralLight = $neutralLight
        Samples = $samples
    }
}

function Get-NeutralLightCount {
    param($Info)

    $neutralLight = 0
    $step = 2
    for ($y = 0; $y -lt $Info.Height; $y += $step) {
        $row = $y * $Info.Stride
        for ($x = 0; $x -lt $Info.Width; $x += $step) {
            $i = $row + $x * 4
            $b = [int]$Info.Bytes[$i]
            $g = [int]$Info.Bytes[$i + 1]
            $r = [int]$Info.Bytes[$i + 2]
            $maxc = [Math]::Max($r, [Math]::Max($g, $b))
            $minc = [Math]::Min($r, [Math]::Min($g, $b))
            if ($maxc -gt 172 -and ($maxc - $minc) -lt 38) {
                $neutralLight++
            }
        }
    }
    $neutralLight
}

function Wait-CleanRoi {
    param([System.Drawing.Rectangle]$Roi, [int]$MaxWaitMs, [int]$NeutralMax)

    $start = [Environment]::TickCount
    $lastNeutral = -1
    while (([Environment]::TickCount - $start) -lt $MaxWaitMs) {
        Start-Sleep -Milliseconds 100
        $bmp = Capture-Rect -Rect $Roi
        $info = Get-BitmapBytes -Bitmap $bmp
        $bmp.Dispose()
        $lastNeutral = Get-NeutralLightCount -Info $info
        if ($lastNeutral -lt $NeutralMax) {
            return [pscustomobject]@{ Clean = $true; Neutral = $lastNeutral }
        }
    }
    [pscustomobject]@{ Clean = $false; Neutral = $lastNeutral }
}

function Send-JsonLines {
    param([string[]]$Lines)

    $client = [System.Net.Sockets.TcpClient]::new()
    $client.NoDelay = $true
    $client.Connect($InputHost, $InputPort)
    try {
        $stream = $client.GetStream()
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $writer = [System.IO.StreamWriter]::new($stream, $utf8NoBom)
        $writer.NewLine = "`n"
        foreach ($line in $Lines) {
            $writer.WriteLine($line)
        }
        $writer.Flush()
    } finally {
        $client.Close()
    }
}

function New-RightClickJson {
    param([int]$X, [int]$Y)
    '{"type":"batch","items":[{"type":"move","x":' + $X + ',"y":' + $Y + '},{"type":"button","button":"right","down":true},{"type":"button","button":"right","down":false}]}'
}

function New-LeftClickJson {
    param([int]$X, [int]$Y)
    '{"type":"batch","items":[{"type":"move","x":' + $X + ',"y":' + $Y + '},{"type":"button","button":"left","down":true},{"type":"button","button":"left","down":false}]}'
}

function New-OpenClickJson {
    param([int]$X, [int]$Y, [string]$Button)
    if ($Button -eq "left") {
        New-LeftClickJson -X $X -Y $Y
    } else {
        New-RightClickJson -X $X -Y $Y
    }
}

function New-EscapeJson {
    '{"type":"batch","items":[{"type":"key","qcode":"esc","down":true},{"type":"key","qcode":"esc","down":false}]}'
}

function New-KeyJson {
    param([string]$Qcode)
    '{"type":"batch","items":[{"type":"key","qcode":"' + $Qcode + '","down":true},{"type":"key","qcode":"' + $Qcode + '","down":false}]}'
}

function New-ComboJson {
    param([string]$Qcodes)

    $items = @()
    foreach ($qcode in ($Qcodes -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })) {
        $items += ('"' + $qcode + '"')
    }
    if ($items.Count -eq 0) {
        throw "Combo trigger has no qcodes."
    }
    '{"type":"combo","qcodes":[' + ($items -join ',') + ']}'
}

function Invoke-OpenTrigger {
    param($WindowRect, [string]$Trigger, [int]$X, [int]$Y)

    if ($OpenAction -eq "combo") {
        if ($Trigger -eq "tcp") {
            Send-JsonLines @((New-ComboJson -Qcodes $OpenQcode))
        } else {
            throw "Local combo trigger is not implemented; use -Trigger tcp."
        }
    } elseif ($OpenAction -eq "key") {
        if ($Trigger -eq "tcp") {
            Send-JsonLines @((New-KeyJson -Qcode $OpenQcode))
        } else {
            Invoke-LocalKey -WindowRect $WindowRect -Qcode $OpenQcode
        }
    } else {
        if ($Trigger -eq "tcp") {
            Send-JsonLines @((New-OpenClickJson -X $X -Y $Y -Button $OpenButton))
        } else {
            Invoke-LocalClick -WindowRect $WindowRect -X $X -Y $Y -Button $OpenButton
        }
    }
}

function Invoke-PrepForOpen {
    param($WindowRect, [string]$Trigger)

    if ($OpenAction -eq "combo") {
        if ($Trigger -eq "tcp") {
            Send-JsonLines @((New-EscapeJson))
        } else {
            Invoke-LocalEscape -WindowRect $WindowRect
        }
        return
    }

    if ($OpenAction -eq "key") {
        if ($Trigger -eq "tcp") {
            Send-JsonLines @((New-LeftClickJson -X $GuestX -Y $GuestY))
            for ($i = 0; $i -lt $PrepBackspaces; $i++) {
                Send-JsonLines @((New-KeyJson -Qcode "backspace"))
            }
        } else {
            Invoke-LocalClick -WindowRect $WindowRect -X $GuestX -Y $GuestY -Button "left"
            for ($i = 0; $i -lt $PrepBackspaces; $i++) {
                Invoke-LocalKey -WindowRect $WindowRect -Qcode "backspace"
            }
        }
        return
    }

    if ($Trigger -eq "tcp") {
        Send-JsonLines @((New-EscapeJson))
        Send-JsonLines @((New-LeftClickJson -X $CloseX -Y $CloseY))
    } else {
        Invoke-LocalEscape -WindowRect $WindowRect
        Invoke-LocalClick -WindowRect $WindowRect -X $CloseX -Y $CloseY -Button "left"
    }
}

$resolvedOut = Join-Path (Get-Location) $OutDir
New-Item -ItemType Directory -Force -Path $resolvedOut | Out-Null
$runDir = Join-Path $resolvedOut ("measure-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$outerWin = Get-TargetRect -Name $WindowProcessName
$win = if ($UseVideoArea) {
    Convert-ToVideoRect -WindowRect $outerWin -SourceWidth $SourceWidth -SourceHeight $SourceHeight -ToolbarHeight $ToolbarHeight
} else {
    $outerWin
}
$roi = New-RoiRect -WindowRect $win -GuestX $GuestX -GuestY $GuestY -Width $RoiWidth -Height $RoiHeight

Write-Host ("window pid={0} title='{1}' rect={2},{3} {4}x{5}" -f $win.Pid, $win.Title, $win.Left, $win.Top, $win.Width, $win.Height)
Write-Host ("roi={0},{1} {2}x{3}" -f $roi.Left, $roi.Top, $roi.Width, $roi.Height)

$results = @()
$sw = [System.Diagnostics.Stopwatch]::StartNew()

for ($trial = 1; $trial -le $Trials; $trial++) {
    if ($ResizeJolt) {
        Invoke-ResizeJolt -WindowRect $outerWin -Pixels $ResizeJoltPixels
        $outerWin = Get-TargetRect -Name $WindowProcessName
        $win = if ($UseVideoArea) {
            Convert-ToVideoRect -WindowRect $outerWin -SourceWidth $SourceWidth -SourceHeight $SourceHeight -ToolbarHeight $ToolbarHeight
        } else {
            $outerWin
        }
        $roi = New-RoiRect -WindowRect $win -GuestX $GuestX -GuestY $GuestY -Width $RoiWidth -Height $RoiHeight
    }

    if ($Mode -eq "open") {
        Invoke-PrepForOpen -WindowRect $win -Trigger $Trigger
        $clean = Wait-CleanRoi -Roi $roi -MaxWaitMs $PrepWaitMs -NeutralMax $CleanNeutralMax
        if (-not $clean.Clean) {
            Write-Host ("warning=roi_not_clean neutral={0}" -f $clean.Neutral)
        }
        if ($UsePark) {
            Invoke-OpenTrigger -WindowRect $win -Trigger $Trigger -X $ParkX -Y $ParkY
            Start-Sleep -Milliseconds $PrepWaitMs
        }
    } elseif (-not ($AssumeOpen -and $trial -eq 1)) {
        Invoke-OpenTrigger -WindowRect $win -Trigger $Trigger -X $GuestX -Y $GuestY
        Start-Sleep -Milliseconds $PrepWaitMs
    }

    $baseBmp = Capture-Rect -Rect $roi
    $basePath = Join-Path $runDir ("trial-{0}-baseline.png" -f $trial)
    $baseBmp.Save($basePath, [System.Drawing.Imaging.ImageFormat]::Png)
    $baseInfo = Get-BitmapBytes -Bitmap $baseBmp
    $baseBmp.Dispose()

    $noiseMax = 0
    $neutralBase = 0
    for ($n = 0; $n -lt 8; $n++) {
        Start-Sleep -Milliseconds $FrameIntervalMs
        $noiseBmp = Capture-Rect -Rect $roi
        $noiseInfo = Get-BitmapBytes -Bitmap $noiseBmp
        $noiseScore = Compare-Frame -BaseInfo $baseInfo -CurInfo $noiseInfo
        $noiseBmp.Dispose()
        $noiseMax = [Math]::Max($noiseMax, $noiseScore.Changed)
        $neutralBase = [Math]::Max($neutralBase, $noiseScore.NeutralLight)
    }

    $thresholdChanged = [Math]::Max($MinChangedThreshold, [int]($noiseMax * 4 + 120))
    $thresholdNeutral = [Math]::Min($baseInfo.Width * $baseInfo.Height / 8, [Math]::Max(350, [int]($neutralBase + 850)))

    $sendBefore = $sw.Elapsed.TotalMilliseconds
    if ($Mode -eq "open") {
        Invoke-OpenTrigger -WindowRect $win -Trigger $Trigger -X $GuestX -Y $GuestY
    } else {
        if ($Trigger -eq "tcp") {
            Send-JsonLines @((New-LeftClickJson -X $CloseX -Y $CloseY))
        } else {
            Invoke-LocalClick -WindowRect $win -X $CloseX -Y $CloseY -Button "left"
        }
    }
    $sendAfter = $sw.Elapsed.TotalMilliseconds
    $sendMs = $sendAfter

    $detectedMs = $null
    $detectedScore = $null
    $detectedPath = $null
    while (($sw.Elapsed.TotalMilliseconds - $sendMs) -lt $MaxWaitMs) {
        Start-Sleep -Milliseconds $FrameIntervalMs
        $curBmp = Capture-Rect -Rect $roi
        $curInfo = Get-BitmapBytes -Bitmap $curBmp
        $score = Compare-Frame -BaseInfo $baseInfo -CurInfo $curInfo
        $since = $sw.Elapsed.TotalMilliseconds - $sendMs

        if ($score.Changed -ge $thresholdChanged -or $score.NeutralLight -ge $thresholdNeutral) {
            $detectedMs = [Math]::Round($since, 1)
            $detectedScore = $score
            $detectedPath = Join-Path $runDir ("trial-{0}-detected.png" -f $trial)
            $curBmp.Save($detectedPath, [System.Drawing.Imaging.ImageFormat]::Png)
            $curBmp.Dispose()
            break
        }
        $curBmp.Dispose()
    }

    if ($null -eq $detectedMs) {
        $detectedMs = -1
    }

    $row = [pscustomobject]@{
        Trial = $trial
        SendWindowMs = [Math]::Round($sendAfter - $sendBefore, 2)
        LatencyMs = $detectedMs
        NoiseChangedMax = $noiseMax
        ThresholdChanged = $thresholdChanged
        ThresholdNeutral = $thresholdNeutral
        DetectedChanged = if ($detectedScore) { $detectedScore.Changed } else { $null }
        DetectedNeutral = if ($detectedScore) { $detectedScore.NeutralLight } else { $null }
        BaselinePng = $basePath
        DetectedPng = $detectedPath
    }
    $results += $row
    Write-Host ($row | ConvertTo-Json -Compress)
}

$csv = Join-Path $runDir "results.csv"
$results | Export-Csv -NoTypeInformation -Encoding UTF8 -Path $csv
$valid = @($results | Where-Object { $_.LatencyMs -ge 0 } | ForEach-Object { [double]$_.LatencyMs } | Sort-Object)
if ($valid.Count -gt 0) {
    $median = $valid[[int][Math]::Floor(($valid.Count - 1) / 2)]
    Write-Host ("median_latency_ms={0}" -f $median)
} else {
    Write-Host "median_latency_ms=NA"
}
Write-Host ("results_csv={0}" -f $csv)
