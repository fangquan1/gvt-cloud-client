<#
.SYNOPSIS
Waits until the Windows guest desktop is ready for automated desktop tests.

.DESCRIPTION
The script combines QGA checks with a client-side video marker check. The
recommended ready marker is provided by guest\gvt-test-agent.ps1.
#>
param(
    [string]$ServerSsh = "root@192.168.0.188",
    [string]$QgaSock = "/root/qemu_cmd/win10-gvt-stream-qga.sock",
    [string]$WindowProcessName = "gvt_spice_viewer",
    [int]$TimeoutSec = 120,
    [switch]$BatchMode,
    [switch]$SkipQga,
    [switch]$SkipMarker,
    [int]$SourceWidth = 1920,
    [int]$SourceHeight = 1200,
    [int]$ToolbarHeight = 32,
    [int]$MarkerGuestX = 28,
    [int]$MarkerGuestY = 28,
    [int]$MarkerGuestWidth = 220,
    [int]$MarkerGuestHeight = 58,
    [double]$MinGreenRatio = 0.22,
    [int]$StableSamples = 3
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "gvt-test-common.ps1")

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class GvtReadyWin32 {
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
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);

    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

function Get-GvtViewerClientRect {
    param([string]$Name)

    $proc = Get-Process -Name $Name -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1

    if (-not $proc) {
        return $null
    }

    [GvtReadyWin32+RECT]$clientRect = New-Object GvtReadyWin32+RECT
    if (-not [GvtReadyWin32]::GetClientRect($proc.MainWindowHandle, [ref]$clientRect)) {
        return $null
    }

    [GvtReadyWin32+POINT]$topLeft = New-Object GvtReadyWin32+POINT
    $topLeft.X = 0
    $topLeft.Y = 0
    if (-not [GvtReadyWin32]::ClientToScreen($proc.MainWindowHandle, [ref]$topLeft)) {
        return $null
    }

    [void][GvtReadyWin32]::SetForegroundWindow($proc.MainWindowHandle)

    return [pscustomobject]@{
        Pid = $proc.Id
        Title = $proc.MainWindowTitle
        Left = $topLeft.X
        Top = $topLeft.Y
        Width = $clientRect.Right - $clientRect.Left
        Height = $clientRect.Bottom - $clientRect.Top
    }
}

function Convert-ToGvtVideoRect {
    param($ClientRect)

    $clientW = [Math]::Max(1, $ClientRect.Width)
    $clientH = [Math]::Max(1, $ClientRect.Height)
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
        Pid = $ClientRect.Pid
        Title = $ClientRect.Title
        Left = $ClientRect.Left + $videoX
        Top = $ClientRect.Top + $videoY
        Width = $videoW
        Height = $videoH
    }
}

function Get-GvtMarkerRect {
    param($VideoRect)

    $scaleX = [double]$VideoRect.Width / [double]$SourceWidth
    $scaleY = [double]$VideoRect.Height / [double]$SourceHeight
    return [System.Drawing.Rectangle]::new(
        $VideoRect.Left + [int]($MarkerGuestX * $scaleX),
        $VideoRect.Top + [int]($MarkerGuestY * $scaleY),
        [Math]::Max(12, [int]($MarkerGuestWidth * $scaleX)),
        [Math]::Max(8, [int]($MarkerGuestHeight * $scaleY))
    )
}

function Capture-GvtRect {
    param([System.Drawing.Rectangle]$Rect)

    $bmp = [System.Drawing.Bitmap]::new($Rect.Width, $Rect.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0, $Rect.Size)
    $g.Dispose()
    return $bmp
}

function Test-GvtReadyMarker {
    param([System.Drawing.Rectangle]$Rect)

    $bmp = Capture-GvtRect -Rect $Rect
    try {
        $green = 0
        $samples = 0
        for ($y = 0; $y -lt $bmp.Height; $y += 3) {
            for ($x = 0; $x -lt $bmp.Width; $x += 3) {
                $c = $bmp.GetPixel($x, $y)
                if ($c.G -ge 135 -and $c.R -le 120 -and $c.B -le 120 -and ($c.G - $c.R) -ge 35) {
                    $green++
                }
                $samples++
            }
        }

        $ratio = if ($samples -gt 0) { [double]$green / [double]$samples } else { 0.0 }
        return [pscustomobject]@{
            Ready = ($ratio -ge $MinGreenRatio)
            GreenRatio = [Math]::Round($ratio, 4)
            Samples = $samples
            Rect = "{0},{1} {2}x{3}" -f $Rect.Left, $Rect.Top, $Rect.Width, $Rect.Height
        }
    }
    finally {
        $bmp.Dispose()
    }
}

function Test-GvtGuestProcesses {
    $scriptText = @"
`$names = Get-Process explorer,dwm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName
`$names -join ','
"@
    $exec = Invoke-GvtQgaGuestExec `
        -Path "powershell.exe" `
        -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $scriptText) `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -BatchMode:$BatchMode `
        -TimeoutSec 15

    $names = @($exec.Stdout -split "[,\r\n ]+" | Where-Object { $_ })
    return [pscustomobject]@{
        Ready = (($names -contains "explorer") -and ($names -contains "dwm"))
        Processes = $names
        ExitCode = $exec.ExitCode
    }
}

$requireMarker = -not $SkipMarker
$deadline = (Get-Date).AddSeconds($TimeoutSec)
$qgaReady = $SkipQga
$processReady = $SkipQga
$markerStable = 0
$lastMarker = $null
$lastViewer = $null

Write-Host "Waiting for guest desktop readiness..."

while ((Get-Date) -lt $deadline) {
    if (-not $SkipQga -and -not $qgaReady) {
        try {
            [void](Invoke-GvtQgaCommand `
                -Command @{ execute = "guest-ping" } `
                -ServerSsh $ServerSsh `
                -QgaSock $QgaSock `
                -BatchMode:$BatchMode `
                -TimeoutSec 6)
            $qgaReady = $true
            Write-Host "  qga=ready"
        }
        catch {
            Start-Sleep -Seconds 2
            continue
        }
    }

    if (-not $SkipQga -and -not $processReady) {
        try {
            $procCheck = Test-GvtGuestProcesses
            if ($procCheck.Ready) {
                $processReady = $true
                Write-Host "  guest_processes=$($procCheck.Processes -join ',')"
            }
        }
        catch {
            Write-Host "  guest_process_check=retry"
        }
    }

    if ($requireMarker) {
        $clientRect = Get-GvtViewerClientRect -Name $WindowProcessName
        if ($clientRect) {
            $videoRect = Convert-ToGvtVideoRect -ClientRect $clientRect
            $markerRect = Get-GvtMarkerRect -VideoRect $videoRect
            $lastViewer = $videoRect
            $lastMarker = Test-GvtReadyMarker -Rect $markerRect
            if ($lastMarker.Ready) {
                $markerStable++
            } else {
                $markerStable = 0
            }
        } else {
            $markerStable = 0
        }
    } else {
        $markerStable = $StableSamples
    }

    if ($qgaReady -and $processReady -and $markerStable -ge $StableSamples) {
        $summary = [ordered]@{
            ready = $true
            qga_ready = [bool]$qgaReady
            process_ready = [bool]$processReady
            marker_stable_samples = $markerStable
            marker = $lastMarker
            viewer = $lastViewer
        }
        Write-Host ($summary | ConvertTo-Json -Depth 6)
        exit 0
    }

    Start-Sleep -Seconds 1
}

$failure = [ordered]@{
    ready = $false
    qga_ready = [bool]$qgaReady
    process_ready = [bool]$processReady
    marker_stable_samples = $markerStable
    marker = $lastMarker
    viewer = $lastViewer
    timeout_sec = $TimeoutSec
}
Write-Host ($failure | ConvertTo-Json -Depth 6)
exit 1
