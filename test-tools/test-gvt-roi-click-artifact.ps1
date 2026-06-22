<#
.SYNOPSIS
Checks that ROI low-bandwidth rendering does not leave click trails.

.DESCRIPTION
Starts gvt_spice_viewer with the ROI compositor enabled, captures the video
area before and after local mouse clicks, and fails when extra GVT_READY-green
regions remain outside the expected marker rectangle.
#>
param(
    [string]$ServerHost = "192.168.0.188",
    [int]$VideoPort = 5004,
    [int]$SpicePort = 5900,
    [int]$InputPort = 5905,
    [ValidateSet("h264", "h265")]
    [string]$Codec = "h265",
    [int]$Latency = 15,
    [int]$SourceWidth = 1920,
    [int]$SourceHeight = 1200,
    [int]$ToolbarHeight = 0,
    [string]$ViewerPath = "",
    [string]$GstRoot = "",
    [string]$SpiceRuntime = "",
    [string]$OutDir = "test_output\data\roi-click-artifact",
    [string]$WindowProcessName = "gvt_spice_viewer",
    [int]$WarmupSec = 5,
    [int]$ReadyTimeoutSec = 30,
    [double]$MinMarkerGreenRatio = 0.25,
    [int]$SettleSec = 3,
    [int]$ClickCount = 3,
    [int]$ClickGuestX = 28000,
    [int]$ClickGuestY = 16000,
    [double]$MaxOutsideGreenRatio = 0.0008,
    [double]$MaxOutsideGreenGrowthRatio = 0.0004,
    [switch]$VideoDebug,
    [switch]$StopExistingViewer,
    [switch]$LeaveWindowOpen
)

$ErrorActionPreference = "Stop"
$ClientRoot = Split-Path -Parent $PSScriptRoot

Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Windows.Forms

Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class Win32RoiClick {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINT {
        public int X;
        public int Y;
    }

    [DllImport("user32.dll")]
    public static extern bool GetWindowRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);

    [DllImport("user32.dll")]
    public static extern bool SetCursorPos(int X, int Y);

    [DllImport("user32.dll")]
    public static extern void mouse_event(uint dwFlags, uint dx, uint dy, uint dwData, UIntPtr dwExtraInfo);
}
"@

function Resolve-FirstExistingPath {
    param(
        [string[]]$Candidates,
        [string]$Kind
    )

    foreach ($candidate in $Candidates) {
        if ([string]::IsNullOrWhiteSpace($candidate)) {
            continue
        }
        $expanded = [Environment]::ExpandEnvironmentVariables($candidate)
        if (Test-Path -LiteralPath $expanded) {
            return (Resolve-Path -LiteralPath $expanded).Path
        }
    }

    throw "Unable to find $Kind. Tried: $($Candidates -join ', ')"
}

function Resolve-ViewerExe {
    param([string]$Requested)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $candidates += $Requested
    }
    $candidates += (Join-Path $ClientRoot "build\viewer\gvt_spice_viewer.exe")
    $candidates += (Join-Path $ClientRoot "build\gvt-cloud-client-portable\app\viewer\gvt_spice_viewer.exe")
    return Resolve-FirstExistingPath -Candidates $candidates -Kind "gvt_spice_viewer.exe"
}

function Resolve-GstreamerRoot {
    param([string]$Requested)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $candidates += $Requested
    }
    $candidates += (Join-Path $ClientRoot "tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64")
    if (-not [string]::IsNullOrWhiteSpace($env:GVT_GSTREAMER_ROOT)) {
        $candidates += $env:GVT_GSTREAMER_ROOT
        $candidates += (Join-Path $env:GVT_GSTREAMER_ROOT "gstreamer\1.0\mingw_x86_64")
    }
    $candidates += "C:\job\gvtg-test\tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64"
    return Resolve-FirstExistingPath -Candidates $candidates -Kind "GStreamer root"
}

function Resolve-SpiceRuntime {
    param([string]$Requested)

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $candidates += $Requested
    }
    $candidates += (Join-Path $ClientRoot "runtime\virtviewer\bin")
    if (-not [string]::IsNullOrWhiteSpace($env:GVT_SPICE_RUNTIME)) {
        $candidates += $env:GVT_SPICE_RUNTIME
    }
    $candidates += "C:\Program Files\VirtViewer v11.0-256\bin"
    return Resolve-FirstExistingPath -Candidates $candidates -Kind "SPICE runtime"
}

function Quote-ProcessArg {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Join-ProcessArgs {
    param([string[]]$Values)
    return (($Values | ForEach-Object { Quote-ProcessArg $_ }) -join " ")
}

function Get-TargetClientRect {
    param([string]$Name)

    $proc = Get-Process -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1

    if (-not $proc) {
        throw "No visible window found for process '$Name'."
    }

    [Win32RoiClick+RECT]$windowRect = New-Object Win32RoiClick+RECT
    if (-not [Win32RoiClick]::GetWindowRect($proc.MainWindowHandle, [ref]$windowRect)) {
        throw "GetWindowRect failed for PID $($proc.Id)."
    }

    [Win32RoiClick+RECT]$clientRect = New-Object Win32RoiClick+RECT
    if (-not [Win32RoiClick]::GetClientRect($proc.MainWindowHandle, [ref]$clientRect)) {
        throw "GetClientRect failed for PID $($proc.Id)."
    }

    [Win32RoiClick+POINT]$clientTopLeft = New-Object Win32RoiClick+POINT
    $clientTopLeft.X = 0
    $clientTopLeft.Y = 0
    if (-not [Win32RoiClick]::ClientToScreen($proc.MainWindowHandle, [ref]$clientTopLeft)) {
        throw "ClientToScreen failed for PID $($proc.Id)."
    }

    [void][Win32RoiClick]::SetForegroundWindow($proc.MainWindowHandle)
    Start-Sleep -Milliseconds 200

    return [pscustomobject]@{
        Pid = $proc.Id
        Hwnd = $proc.MainWindowHandle
        Left = $clientTopLeft.X
        Top = $clientTopLeft.Y
        Width = $clientRect.Right - $clientRect.Left
        Height = $clientRect.Bottom - $clientRect.Top
        WindowLeft = $windowRect.Left
        WindowTop = $windowRect.Top
        WindowWidth = $windowRect.Right - $windowRect.Left
        WindowHeight = $windowRect.Bottom - $windowRect.Top
        Title = $proc.MainWindowTitle
    }
}

function Convert-ToVideoRect {
    param($WindowRect)

    if ($SourceWidth -le 0 -or $SourceHeight -le 0) {
        return $WindowRect
    }

    $clientW = [Math]::Max(1, [int]$WindowRect.Width)
    $clientH = [Math]::Max(1, [int]$WindowRect.Height)
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

    return [pscustomobject]@{
        Pid = $WindowRect.Pid
        Hwnd = $WindowRect.Hwnd
        Left = $WindowRect.Left + $videoX
        Top = $WindowRect.Top + $videoY
        Width = $videoW
        Height = $videoH
        Title = $WindowRect.Title
    }
}

function Convert-NormToScreenPoint {
    param($VideoRect, [int]$X, [int]$Y)

    return [pscustomobject]@{
        X = $VideoRect.Left + [int]([double]$VideoRect.Width * $X / 32767.0)
        Y = $VideoRect.Top + [int]([double]$VideoRect.Height * $Y / 32767.0)
    }
}

function Invoke-LocalLeftClick {
    param($VideoRect, [int]$X, [int]$Y)

    $pt = Convert-NormToScreenPoint -VideoRect $VideoRect -X $X -Y $Y
    [void][Win32RoiClick]::SetCursorPos($pt.X, $pt.Y)
    Start-Sleep -Milliseconds 80
    [Win32RoiClick]::mouse_event(0x0002, 0, 0, 0, [UIntPtr]::Zero)
    Start-Sleep -Milliseconds 45
    [Win32RoiClick]::mouse_event(0x0004, 0, 0, 0, [UIntPtr]::Zero)
}

function Capture-Rect {
    param([System.Drawing.Rectangle]$Rect)

    $bmp = [System.Drawing.Bitmap]::new($Rect.Width, $Rect.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0, $Rect.Size)
    $g.Dispose()
    return $bmp
}

function Get-BitmapBytes {
    param([System.Drawing.Bitmap]$Bitmap)

    $rect = [System.Drawing.Rectangle]::new(0, 0, $Bitmap.Width, $Bitmap.Height)
    $data = $Bitmap.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $len = [Math]::Abs($data.Stride) * $Bitmap.Height
        $bytes = New-Object byte[] $len
        [Runtime.InteropServices.Marshal]::Copy($data.Scan0, $bytes, 0, $len)
        return [pscustomobject]@{
            Bytes = $bytes
            Stride = [Math]::Abs($data.Stride)
            Width = $Bitmap.Width
            Height = $Bitmap.Height
        }
    } finally {
        $Bitmap.UnlockBits($data)
    }
}

function Test-PointInRect {
    param([int]$X, [int]$Y, [System.Drawing.Rectangle[]]$Rects)

    foreach ($rect in $Rects) {
        if ($X -ge $rect.Left -and $X -lt $rect.Right -and
            $Y -ge $rect.Top -and $Y -lt $rect.Bottom) {
            return $true
        }
    }
    return $false
}

function Measure-BitmapDiff {
    param($BaseInfo, $CurInfo, [System.Drawing.Rectangle[]]$IgnoreRects = @(), [int]$Step = 3)

    $changed = 0
    $samples = 0
    for ($y = 0; $y -lt $BaseInfo.Height; $y += $Step) {
        $row = $y * $BaseInfo.Stride
        for ($x = 0; $x -lt $BaseInfo.Width; $x += $Step) {
            if (Test-PointInRect -X $x -Y $y -Rects $IgnoreRects) {
                continue
            }
            $i = $row + $x * 4
            $db = [Math]::Abs([int]$BaseInfo.Bytes[$i] - [int]$CurInfo.Bytes[$i])
            $dg = [Math]::Abs([int]$BaseInfo.Bytes[$i + 1] - [int]$CurInfo.Bytes[$i + 1])
            $dr = [Math]::Abs([int]$BaseInfo.Bytes[$i + 2] - [int]$CurInfo.Bytes[$i + 2])
            if (($db + $dg + $dr) -ge 48 -and ($db -ge 18 -or $dg -ge 18 -or $dr -ge 18)) {
                $changed++
            }
            $samples++
        }
    }

    $ratio = if ($samples -gt 0) { [double]$changed / [double]$samples } else { 1.0 }
    return [pscustomobject]@{
        Changed = $changed
        Samples = $samples
        Ratio = [Math]::Round($ratio, 6)
    }
}

function Measure-OutsideGreen {
    param($Info, [System.Drawing.Rectangle]$MarkerRect, [int]$Step = 2)

    $green = 0
    $samples = 0
    for ($y = 0; $y -lt $Info.Height; $y += $Step) {
        $row = $y * $Info.Stride
        for ($x = 0; $x -lt $Info.Width; $x += $Step) {
            if ($x -ge $MarkerRect.Left -and $x -lt $MarkerRect.Right -and
                $y -ge $MarkerRect.Top -and $y -lt $MarkerRect.Bottom) {
                continue
            }
            $i = $row + $x * 4
            $b = [int]$Info.Bytes[$i]
            $g = [int]$Info.Bytes[$i + 1]
            $r = [int]$Info.Bytes[$i + 2]
            if ($g -ge 135 -and $r -le 125 -and $b -le 125 -and ($g - $r) -ge 35 -and ($g - $b) -ge 35) {
                $green++
            }
            $samples++
        }
    }

    $ratio = if ($samples -gt 0) { [double]$green / [double]$samples } else { 1.0 }
    return [pscustomobject]@{
        Green = $green
        Samples = $samples
        Ratio = [Math]::Round($ratio, 6)
    }
}

function Measure-GreenInRect {
    param($Info, [System.Drawing.Rectangle]$Rect, [int]$Step = 2)

    $green = 0
    $samples = 0
    $left = [Math]::Max(0, $Rect.Left)
    $top = [Math]::Max(0, $Rect.Top)
    $right = [Math]::Min($Info.Width, $Rect.Right)
    $bottom = [Math]::Min($Info.Height, $Rect.Bottom)

    for ($y = $top; $y -lt $bottom; $y += $Step) {
        $row = $y * $Info.Stride
        for ($x = $left; $x -lt $right; $x += $Step) {
            $i = $row + $x * 4
            $b = [int]$Info.Bytes[$i]
            $g = [int]$Info.Bytes[$i + 1]
            $r = [int]$Info.Bytes[$i + 2]
            if ($g -ge 135 -and $r -le 125 -and $b -le 125 -and ($g - $r) -ge 35 -and ($g - $b) -ge 35) {
                $green++
            }
            $samples++
        }
    }

    $ratio = if ($samples -gt 0) { [double]$green / [double]$samples } else { 0.0 }
    return [pscustomobject]@{
        Green = $green
        Samples = $samples
        Ratio = [Math]::Round($ratio, 6)
    }
}

function Get-ExpectedMarkerRect {
    param($VideoRect)

    $scaleX = [double]$VideoRect.Width / [double]$SourceWidth
    $scaleY = [double]$VideoRect.Height / [double]$SourceHeight
    $padX = [Math]::Max(8, [int](16 * $scaleX))
    $padY = [Math]::Max(8, [int](16 * $scaleY))
    $left = [Math]::Max(0, [int](28 * $scaleX) - $padX)
    $top = [Math]::Max(0, [int](28 * $scaleY) - $padY)
    $right = [Math]::Min([int]$VideoRect.Width, [int]((28 + 220) * $scaleX) + $padX)
    $bottom = [Math]::Min([int]$VideoRect.Height, [int]((28 + 58) * $scaleY) + $padY)
    return [System.Drawing.Rectangle]::new($left, $top, [Math]::Max(1, $right - $left), [Math]::Max(1, $bottom - $top))
}

function New-VideoCapture {
    param($VideoRect, [string]$Path)

    $rect = [System.Drawing.Rectangle]::new($VideoRect.Left, $VideoRect.Top, $VideoRect.Width, $VideoRect.Height)
    $bmp = Capture-Rect -Rect $rect
    $bmp.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $info = Get-BitmapBytes -Bitmap $bmp
    $bmp.Dispose()
    return $info
}

$outDirPath = if ([IO.Path]::IsPathRooted($OutDir)) {
    $OutDir
} else {
    Join-Path $ClientRoot $OutDir
}
New-Item -ItemType Directory -Force -Path $outDirPath | Out-Null

$viewer = Resolve-ViewerExe $ViewerPath
$gst = Resolve-GstreamerRoot $GstRoot
$spice = Resolve-SpiceRuntime $SpiceRuntime
$viewerDir = Split-Path -Parent $viewer
$viewerLog = Join-Path $viewerDir "gvt_spice_viewer.log"
$viewerLogStart = if (Test-Path -LiteralPath $viewerLog) { (Get-Content -LiteralPath $viewerLog -ErrorAction SilentlyContinue).Count } else { 0 }

if ($StopExistingViewer) {
    Get-Process -Name $WindowProcessName -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

& $viewer --gst-warmup --gst-root $gst | Out-Null

$viewerArgs = @(
    "--video-codec", $Codec,
    "--video-port", $VideoPort.ToString(),
    "--latency", $Latency.ToString(),
    "--spice-host", $ServerHost,
    "--spice-port", $SpicePort.ToString(),
    "--native-input",
    "--input-host", $ServerHost,
    "--input-port", $InputPort.ToString(),
    "--stream-control-host", $ServerHost,
    "--stream-control-port", $VideoPort.ToString(),
    "--gst-root", $gst,
    "--spice-runtime", $spice,
    "--source-width", $SourceWidth.ToString(),
    "--source-height", $SourceHeight.ToString(),
    "--no-drop-on-latency",
    "--auto-size"
)

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $viewer
$startInfo.WorkingDirectory = $viewerDir
$startInfo.UseShellExecute = $false
$startInfo.Arguments = Join-ProcessArgs $viewerArgs
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_ROI_COMPOSITOR"] = "1"
if ($VideoDebug) {
    $startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_VIDEO_DEBUG"] = "1"
}
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_DROP_COMPLETE_FRAMES"] = "0"
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_UDP_BUFFER_SIZE"] = "2097152"
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_JITTER_DROPOUT_MS"] = "60"
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_JITTER_MISORDER_MS"] = "20"
$startInfo.EnvironmentVariables["PATH"] = (Join-Path $gst "bin") + ";" + $spice + ";" + $env:PATH

$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
[void]$process.Start()

$summary = [ordered]@{
    ok = $false
    viewer_path = $viewer
    viewer_pid = $process.Id
    viewer_args = $startInfo.Arguments
    out_dir = $outDirPath
}

try {
    Start-Sleep -Seconds $WarmupSec
    $clientRect = Get-TargetClientRect -Name $WindowProcessName
    $videoRect = Convert-ToVideoRect -WindowRect $clientRect
    $markerRect = Get-ExpectedMarkerRect -VideoRect $videoRect
    $ignoreClickRect = [System.Drawing.Rectangle]::new(
        [Math]::Max(0, [int]([double]$videoRect.Width * $ClickGuestX / 32767.0) - 48),
        [Math]::Max(0, [int]([double]$videoRect.Height * $ClickGuestY / 32767.0) - 48),
        96,
        96)
    $ignoreRects = @($markerRect, $ignoreClickRect)

    $beforePath = Join-Path $outDirPath "before.png"
    $settlePath = Join-Path $outDirPath "settle.png"
    $afterPath = Join-Path $outDirPath "after.png"

    $readyDeadline = (Get-Date).AddSeconds($ReadyTimeoutSec)
    $readyAttempts = 0
    $readyMarker = $null
    $before = $null
    do {
        $readyAttempts++
        $before = New-VideoCapture -VideoRect $videoRect -Path $beforePath
        $readyMarker = Measure-GreenInRect -Info $before -Rect $markerRect
        if ($readyMarker.Ratio -ge $MinMarkerGreenRatio) {
            break
        }
        Start-Sleep -Milliseconds 500
    } while ((Get-Date) -lt $readyDeadline)
    if (-not $readyMarker -or $readyMarker.Ratio -lt $MinMarkerGreenRatio) {
        throw "ROI click test did not see the ready marker within $ReadyTimeoutSec seconds. marker_green_ratio=$($readyMarker.Ratio)"
    }

    Start-Sleep -Seconds $SettleSec
    $settle = New-VideoCapture -VideoRect $videoRect -Path $settlePath
    $preDiff = Measure-BitmapDiff -BaseInfo $before -CurInfo $settle -IgnoreRects $ignoreRects
    $preGreen = Measure-OutsideGreen -Info $settle -MarkerRect $markerRect

    for ($i = 0; $i -lt $ClickCount; $i++) {
        Invoke-LocalLeftClick -VideoRect $videoRect -X $ClickGuestX -Y $ClickGuestY
        Start-Sleep -Milliseconds 250
    }
    Start-Sleep -Seconds $SettleSec
    $after = New-VideoCapture -VideoRect $videoRect -Path $afterPath

    $postDiff = Measure-BitmapDiff -BaseInfo $settle -CurInfo $after -IgnoreRects $ignoreRects
    $postGreen = Measure-OutsideGreen -Info $after -MarkerRect $markerRect
    $outsideGreenGrowthRatio = [Math]::Round([Math]::Max(0.0, $postGreen.Ratio - $preGreen.Ratio), 6)
    $passed = ($preGreen.Ratio -le $MaxOutsideGreenRatio) -and
        ($postGreen.Ratio -le $MaxOutsideGreenRatio) -and
        ($outsideGreenGrowthRatio -le $MaxOutsideGreenGrowthRatio)

    $summary["ok"] = [bool]$passed
    $summary["client_rect"] = "{0},{1} {2}x{3}" -f $clientRect.Left, $clientRect.Top, $clientRect.Width, $clientRect.Height
    $summary["video_rect"] = "{0},{1} {2}x{3}" -f $videoRect.Left, $videoRect.Top, $videoRect.Width, $videoRect.Height
    $summary["marker_rect_local"] = "{0},{1} {2}x{3}" -f $markerRect.Left, $markerRect.Top, $markerRect.Width, $markerRect.Height
    $summary["click_guest"] = "{0},{1}" -f $ClickGuestX, $ClickGuestY
    $summary["ready_attempts"] = $readyAttempts
    $summary["ready_marker_green"] = $readyMarker
    $summary["before_png"] = $beforePath
    $summary["settle_png"] = $settlePath
    $summary["after_png"] = $afterPath
    $summary["pre_diff"] = $preDiff
    $summary["post_diff"] = $postDiff
    $summary["pre_outside_green"] = $preGreen
    $summary["post_outside_green"] = $postGreen
    $summary["outside_green_growth_ratio"] = $outsideGreenGrowthRatio
    $summary["max_outside_green_ratio"] = $MaxOutsideGreenRatio
    $summary["max_outside_green_growth_ratio"] = $MaxOutsideGreenGrowthRatio
    $summary["failure_reason"] = if ($passed) {
        ""
    } elseif ($postGreen.Ratio -gt $MaxOutsideGreenRatio) {
        "post_outside_green_ratio"
    } elseif ($preGreen.Ratio -gt $MaxOutsideGreenRatio) {
        "pre_outside_green_ratio"
    } else {
        "outside_green_growth_ratio"
    }
}
catch {
    $summary["ok"] = $false
    $summary["failure_reason"] = "exception"
    $summary["error"] = $_.Exception.Message
    $summary["error_position"] = $_.InvocationInfo.PositionMessage
}
finally {
    if (Test-Path -LiteralPath $viewerLog) {
        $logTailPath = Join-Path $outDirPath "viewer.log"
        $lines = @(Get-Content -LiteralPath $viewerLog -ErrorAction SilentlyContinue)
        if ($lines.Count -gt $viewerLogStart) {
            $lines[$viewerLogStart..($lines.Count - 1)] | Set-Content -LiteralPath $logTailPath -Encoding UTF8
            $summary["viewer_log"] = $logTailPath
        }
    }

    if (-not $LeaveWindowOpen -and -not $process.HasExited) {
        try {
            [void]$process.CloseMainWindow()
            if (-not $process.WaitForExit(3000)) {
                $process.Kill()
            }
        } catch {
        }
    }
}

$summaryPath = Join-Path $outDirPath "summary.json"
$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host ($summary | ConvertTo-Json -Depth 8 -Compress)
Write-Host "summary=$summaryPath"

if (-not [bool]$summary.ok) {
    exit 1
}
