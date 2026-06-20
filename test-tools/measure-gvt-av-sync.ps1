<#
.SYNOPSIS
Estimates audio/video sync using the guest test agent's flash+click pattern.

.DESCRIPTION
This is a practical diagnostic, not a lab-grade lip-sync instrument. It starts
WASAPI loopback recording, samples the client video marker ROI, triggers the
guest agent to flash the marker while playing clicks, and pairs detected audio
and video events.
#>
param(
    [string]$ServerSsh = "root@192.168.0.188",
    [string]$QgaSock = "/root/qemu_cmd/win10-gvt-stream-qga.sock",
    [string]$GuestRoot = "C:\ProgramData\GvtCloudTest",
    [string]$GuestAgentScheduledTaskName = "GvtCloudTestAgent",
    [int]$GuestCommandConsumeTimeoutSec = 8,
    [string]$WindowProcessName = "gvt_spice_viewer",
    [string]$GstRoot = "",
    [int]$DurationSec = 20,
    [int]$PreRollMs = 1200,
    [int]$PostRollSec = 2,
    [int]$SampleRate = 48000,
    [int]$LatencyUs = 10000,
    [int]$FrameIntervalMs = 15,
    [string]$OutDir = "build\av-sync",
    [switch]$BatchMode,
    [int]$SourceWidth = 1920,
    [int]$SourceHeight = 1200,
    [int]$ToolbarHeight = 32,
    [int]$MarkerGuestX = 28,
    [int]$MarkerGuestY = 28,
    [int]$MarkerGuestWidth = 220,
    [int]$MarkerGuestHeight = 58
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "gvt-test-common.ps1")

Add-Type -AssemblyName System.Drawing
Add-Type @"
using System;
using System.Runtime.InteropServices;

public static class GvtAvWin32 {
    [StructLayout(LayoutKind.Sequential)]
    public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }
    [StructLayout(LayoutKind.Sequential)]
    public struct POINT { public int X; public int Y; }
    [DllImport("user32.dll")]
    public static extern bool GetClientRect(IntPtr hWnd, out RECT lpRect);
    [DllImport("user32.dll")]
    public static extern bool ClientToScreen(IntPtr hWnd, ref POINT lpPoint);
    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

function Quote-GvtProcessArg {
    param([string]$Value)
    if ($null -eq $Value) { return '""' }
    if ($Value -notmatch '[\s"]') { return $Value }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Join-GvtProcessArgs {
    param([string[]]$ArgList)
    return (($ArgList | ForEach-Object { Quote-GvtProcessArg $_ }) -join " ")
}

function Get-GvtViewerVideoRect {
    $proc = Get-Process -Name $WindowProcessName -ErrorAction SilentlyContinue |
        Where-Object { $_.MainWindowHandle -ne 0 } |
        Sort-Object StartTime -Descending |
        Select-Object -First 1
    if (-not $proc) {
        throw "No visible window found for process '$WindowProcessName'."
    }

    [GvtAvWin32+RECT]$clientRect = New-Object GvtAvWin32+RECT
    [void][GvtAvWin32]::GetClientRect($proc.MainWindowHandle, [ref]$clientRect)
    [GvtAvWin32+POINT]$topLeft = New-Object GvtAvWin32+POINT
    $topLeft.X = 0
    $topLeft.Y = 0
    [void][GvtAvWin32]::ClientToScreen($proc.MainWindowHandle, [ref]$topLeft)
    [void][GvtAvWin32]::SetForegroundWindow($proc.MainWindowHandle)

    $clientW = [Math]::Max(1, $clientRect.Right - $clientRect.Left)
    $clientH = [Math]::Max(1, $clientRect.Bottom - $clientRect.Top)
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
        Left = $topLeft.X + $videoX
        Top = $topLeft.Y + $videoY
        Width = $videoW
        Height = $videoH
        Pid = $proc.Id
        Title = $proc.MainWindowTitle
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

function Get-GvtWhiteRatio {
    param([System.Drawing.Rectangle]$Rect)

    $bmp = [System.Drawing.Bitmap]::new($Rect.Width, $Rect.Height, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($Rect.Left, $Rect.Top, 0, 0, $Rect.Size)
    $g.Dispose()
    try {
        $white = 0
        $samples = 0
        for ($y = 0; $y -lt $bmp.Height; $y += 4) {
            for ($x = 0; $x -lt $bmp.Width; $x += 4) {
                $c = $bmp.GetPixel($x, $y)
                if ($c.R -gt 210 -and $c.G -gt 210 -and $c.B -gt 210) {
                    $white++
                }
                $samples++
            }
        }
        if ($samples -eq 0) {
            return 0.0
        }
        return [double]$white / [double]$samples
    }
    finally {
        $bmp.Dispose()
    }
}

function Get-GvtVideoFlashTimes {
    param([object[]]$Rows)

    $times = New-Object System.Collections.Generic.List[double]
    $inFlash = $false
    $lastTime = -99999.0
    foreach ($row in $Rows) {
        $hit = [double]$row.white_ratio -ge 0.35
        if ($hit -and -not $inFlash -and ([double]$row.ms - $lastTime) -ge 900.0) {
            [void]$times.Add([double]$row.ms)
            $lastTime = [double]$row.ms
        }
        $inFlash = $hit
    }
    return $times.ToArray()
}

function Get-GvtMedianDouble {
    param([object[]]$Values)

    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ } | Sort-Object)
    if ($numbers.Count -le 0) {
        return $null
    }

    $mid = [int]($numbers.Count / 2)
    if (($numbers.Count % 2) -eq 1) {
        return [double]$numbers[$mid]
    }
    return ([double]$numbers[$mid - 1] + [double]$numbers[$mid]) / 2.0
}

function Get-GvtNearestAvPairs {
    param(
        [object[]]$VideoTimesMs,
        [object[]]$AudioTimesMs,
        [double]$MaxDistanceMs = 750.0
    )

    $usedVideo = @{}
    $pairs = New-Object System.Collections.Generic.List[object]

    for ($ai = 0; $ai -lt $AudioTimesMs.Count; $ai++) {
        $audioMs = [double]$AudioTimesMs[$ai]
        $bestIndex = -1
        $bestAbs = [double]::PositiveInfinity
        $bestDiff = $null

        for ($vi = 0; $vi -lt $VideoTimesMs.Count; $vi++) {
            if ($usedVideo.ContainsKey([string]$vi)) {
                continue
            }
            $diff = $audioMs - [double]$VideoTimesMs[$vi]
            $abs = [Math]::Abs($diff)
            if ($abs -lt $bestAbs) {
                $bestIndex = $vi
                $bestAbs = $abs
                $bestDiff = $diff
            }
        }

        if ($bestIndex -ge 0 -and $bestAbs -le $MaxDistanceMs) {
            $usedVideo[[string]$bestIndex] = $true
            [void]$pairs.Add([pscustomobject]@{
                index = $pairs.Count
                video_index = $bestIndex
                audio_index = $ai
                video_ms = [Math]::Round([double]$VideoTimesMs[$bestIndex], 2)
                audio_ms = [Math]::Round($audioMs, 2)
                audio_minus_video_ms = [Math]::Round($bestDiff, 2)
                abs_ms = [Math]::Round($bestAbs, 2)
            })
        }
    }

    return $pairs
}

$clientRoot = Resolve-GvtClientRoot
$resolvedOut = Join-Path $clientRoot $OutDir
New-Item -ItemType Directory -Force -Path $resolvedOut | Out-Null
$runDir = Join-Path $resolvedOut ("avsync-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$recordedWav = Join-Path $runDir "recorded-loopback.wav"
$recordedWavForGst = $recordedWav -replace "\\", "/"
$gstLog = Join-Path $runDir "gst-loopback.log"
$videoCsv = Join-Path $runDir "video-flash-samples.csv"
$summaryJson = Join-Path $runDir "summary.json"
$reportMd = Join-Path $runDir "report.md"

$videoRect = Get-GvtViewerVideoRect
$markerRect = Get-GvtMarkerRect -VideoRect $videoRect
$guestAgentBeforeTrigger = Wait-GvtGuestTestAgentReady `
    -GuestRoot $GuestRoot `
    -ScheduledTaskName $GuestAgentScheduledTaskName `
    -ServerSsh $ServerSsh `
    -QgaSock $QgaSock `
    -TimeoutSec ([Math]::Max(8, $GuestCommandConsumeTimeoutSec)) `
    -ClearCommand `
    -BatchMode:$BatchMode
$guestAgentAfterTrigger = $null
$triggerMs = $null
$guestCommandConsumedMs = $null

$gstLaunch = Resolve-GvtGstExe -Name "gst-launch-1.0.exe" -GstRoot $GstRoot
$gstRootResolved = Split-Path -Parent (Split-Path -Parent $gstLaunch)
$recordSec = $DurationSec + [Math]::Ceiling($PreRollMs / 1000.0) + $PostRollSec
$numBuffers = [Math]::Ceiling(($recordSec * 1000000.0) / [double]$LatencyUs)
$gstArgs = @(
    "-e",
    "wasapisrc",
    "loopback=true",
    "low-latency=true",
    "buffer-time=50000",
    ("latency-time={0}" -f $LatencyUs),
    ("num-buffers={0}" -f $numBuffers),
    "!",
    "audioconvert",
    "!",
    "audioresample",
    "!",
    ("audio/x-raw,format=S16LE,rate={0},channels=2" -f $SampleRate),
    "!",
    "wavenc",
    "!",
    "filesink",
    ("location={0}" -f $recordedWavForGst)
)

$startInfo = [Diagnostics.ProcessStartInfo]::new()
$startInfo.FileName = $gstLaunch
$startInfo.WorkingDirectory = $runDir
$startInfo.UseShellExecute = $false
$startInfo.RedirectStandardOutput = $true
$startInfo.RedirectStandardError = $true
$startInfo.Arguments = Join-GvtProcessArgs -ArgList $gstArgs
$startInfo.EnvironmentVariables["PATH"] = (Join-Path $gstRootResolved "bin") + ";" + $env:PATH
$startInfo.EnvironmentVariables["GST_PLUGIN_PATH"] = Join-Path $gstRootResolved "lib\gstreamer-1.0"
$startInfo.EnvironmentVariables["GST_PLUGIN_SYSTEM_PATH_1_0"] = Join-Path $gstRootResolved "lib\gstreamer-1.0"

Write-Host "Starting loopback recorder and video ROI sampler..."
$sw = [Diagnostics.Stopwatch]::StartNew()
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
$audioStartMs = $sw.Elapsed.TotalMilliseconds
[void]$process.Start()

Start-Sleep -Milliseconds $PreRollMs

Write-Host "Triggering guest AV sync pattern..."
$triggerMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)
$cmd = @{
    command = "av-sync-test"
    duration_sec = $DurationSec
    sample_rate = $SampleRate
    generated_at = (Get-Date).ToString("o")
} | ConvertTo-Json -Compress
try {
    Write-GvtQgaFile `
        -GuestPath (Join-Path $GuestRoot "command.json") `
        -Text $cmd `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -BatchMode:$BatchMode
    $guestAgentAfterTrigger = Wait-GvtGuestTestCommandConsumed `
        -GuestRoot $GuestRoot `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -TimeoutSec $GuestCommandConsumeTimeoutSec `
        -BatchMode:$BatchMode
    $guestCommandConsumedMs = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)
} catch {
    if (-not $process.HasExited) {
        $process.Kill()
        $process.WaitForExit()
    }
    throw
}

$rows = New-Object System.Collections.Generic.List[object]
$endAt = $sw.Elapsed.TotalMilliseconds + (($DurationSec + $PostRollSec) * 1000.0)
while ($sw.Elapsed.TotalMilliseconds -lt $endAt) {
    $ratio = Get-GvtWhiteRatio -Rect $markerRect
    [void]$rows.Add([pscustomobject]@{
        ms = [Math]::Round($sw.Elapsed.TotalMilliseconds, 2)
        white_ratio = [Math]::Round($ratio, 4)
    })
    Start-Sleep -Milliseconds $FrameIntervalMs
}

if (-not $process.WaitForExit(8000)) {
    $process.Kill()
    $process.WaitForExit()
}

$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
Set-Content -LiteralPath $gstLog -Value ($stdout + "`r`n" + $stderr) -Encoding UTF8
$rows | Export-Csv -LiteralPath $videoCsv -NoTypeInformation -Encoding UTF8

if (-not (Test-Path -LiteralPath $recordedWav)) {
    throw "Loopback recording was not created. See $gstLog"
}

$videoTimesMs = @(Get-GvtVideoFlashTimes -Rows $rows)
$rec = Read-GvtPcm16Wav -Path $recordedWav
$audioPulseSec = @(Get-GvtPulseTimes -Samples $rec.Samples -SampleRate $rec.SampleRate)
$audioTimesMs = @($audioPulseSec | ForEach-Object { $audioStartMs + ($_ * 1000.0) })

$pairs = New-Object System.Collections.Generic.List[object]
$pairCount = [Math]::Min($videoTimesMs.Count, $audioTimesMs.Count)
for ($i = 0; $i -lt $pairCount; $i++) {
    [void]$pairs.Add([pscustomobject]@{
        index = $i
        video_ms = [Math]::Round($videoTimesMs[$i], 2)
        audio_ms = [Math]::Round($audioTimesMs[$i], 2)
        audio_minus_video_ms = [Math]::Round($audioTimesMs[$i] - $videoTimesMs[$i], 2)
    })
}

$offsets = @($pairs | ForEach-Object { [double]$_.audio_minus_video_ms })
$avgOffset = $null
$maxAbsOffset = $null
if ($offsets.Count -gt 0) {
    $avgOffset = [Math]::Round((($offsets | Measure-Object -Average).Average), 2)
    $maxAbsOffset = [Math]::Round((($offsets | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum), 2)
}

$relativeDrift = @()
if ($pairs.Count -ge 2) {
    $first = [double]$pairs[0].audio_minus_video_ms
    $relativeDrift = @($pairs | ForEach-Object { [Math]::Round(([double]$_.audio_minus_video_ms - $first), 2) })
}

$nearestPairToleranceMs = 750.0
$nearestPairs = @(Get-GvtNearestAvPairs -VideoTimesMs $videoTimesMs -AudioTimesMs $audioTimesMs -MaxDistanceMs $nearestPairToleranceMs)
$nearestOffsets = @($nearestPairs | ForEach-Object { [double]$_.audio_minus_video_ms })
$nearestAvgOffset = $null
$nearestMedianOffset = $null
$nearestMaxAbsOffset = $null
$nearestRelativeDrift = @()
$nearestMaxAbsRelativeDrift = $null
if ($nearestOffsets.Count -gt 0) {
    $nearestAvgOffset = [Math]::Round((($nearestOffsets | Measure-Object -Average).Average), 2)
    $nearestMedianOffset = [Math]::Round((Get-GvtMedianDouble -Values $nearestOffsets), 2)
    $nearestMaxAbsOffset = [Math]::Round((($nearestOffsets | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum), 2)
    $nearestRelativeDrift = @($nearestOffsets | ForEach-Object { [Math]::Round(([double]$_ - $nearestMedianOffset), 2) })
    if ($nearestRelativeDrift.Count -gt 0) {
        $nearestMaxAbsRelativeDrift = [Math]::Round((($nearestRelativeDrift | ForEach-Object { [Math]::Abs($_) } | Measure-Object -Maximum).Maximum), 2)
    }
}

$summary = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    output_dir = $runDir
    recorded_wav = $recordedWav
    video_csv = $videoCsv
    gst_log = $gstLog
    note = "Absolute offset is an estimate because gst-launch start time is used as audio sample-zero time."
    trigger_ms = $triggerMs
    guest_command_consumed_ms = $guestCommandConsumedMs
    guest_command_consume_after_trigger_ms = if ($null -ne $triggerMs -and $null -ne $guestCommandConsumedMs) { [Math]::Round($guestCommandConsumedMs - $triggerMs, 2) } else { $null }
    guest_agent_before_trigger = $guestAgentBeforeTrigger
    guest_agent_after_trigger = $guestAgentAfterTrigger
    video_rect = $videoRect
    marker_rect = "{0},{1} {2}x{3}" -f $markerRect.Left, $markerRect.Top, $markerRect.Width, $markerRect.Height
    video_flash_times_ms = @($videoTimesMs | ForEach-Object { [Math]::Round($_, 2) })
    audio_pulse_times_ms_estimated = @($audioTimesMs | ForEach-Object { [Math]::Round($_, 2) })
    nearest_pair_tolerance_ms = $nearestPairToleranceMs
    nearest_pairs = @($nearestPairs)
    nearest_average_audio_minus_video_ms_estimated = $nearestAvgOffset
    nearest_median_audio_minus_video_ms_estimated = $nearestMedianOffset
    nearest_max_abs_audio_minus_video_ms_estimated = $nearestMaxAbsOffset
    nearest_relative_offset_drift_ms = $nearestRelativeDrift
    nearest_max_abs_relative_offset_drift_ms = $nearestMaxAbsRelativeDrift
    pairs = $pairs
    average_audio_minus_video_ms_estimated = $avgOffset
    max_abs_audio_minus_video_ms_estimated = $maxAbsOffset
    relative_offset_drift_ms = $relativeDrift
    legacy_pairing_note = "pairs uses raw event order and can be wrong when either detector misses an event; prefer nearest_pairs and nearest_relative_offset_drift_ms."
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

$report = @(
    "# GVT AV sync report",
    "",
    "- Output: $runDir",
    "- Video flashes: $($videoTimesMs.Count)",
    "- Audio pulses: $($audioTimesMs.Count)",
    "- Guest command consumed after trigger: $(if ($null -ne $triggerMs -and $null -ne $guestCommandConsumedMs) { [Math]::Round($guestCommandConsumedMs - $triggerMs, 2) } else { 'NA' }) ms",
    "- Nearest paired events: $($nearestPairs.Count) (tolerance $nearestPairToleranceMs ms)",
    "- Nearest estimated audio-minus-video avg: $nearestAvgOffset ms",
    "- Nearest estimated audio-minus-video median: $nearestMedianOffset ms",
    "- Nearest relative drift max abs: $nearestMaxAbsRelativeDrift ms",
    "- Legacy index paired events: $pairCount",
    "- Legacy index estimated audio-minus-video avg: $avgOffset ms",
    "- Note: absolute offset uses gst-launch process start as audio sample-zero time; nearest-pair relative drift is the most useful stability signal.",
    "",
    "## Nearest pairs",
    ""
)
foreach ($pair in $nearestPairs) {
    $report += "- $($pair.index): video#$($pair.video_index)=$($pair.video_ms) ms audio#$($pair.audio_index)=$($pair.audio_ms) ms diff=$($pair.audio_minus_video_ms) ms"
}
$report += @(
    "",
    "## Legacy index pairs",
    ""
)
foreach ($pair in $pairs) {
    $report += "- $($pair.index): video=$($pair.video_ms) ms audio=$($pair.audio_ms) ms diff=$($pair.audio_minus_video_ms) ms"
}
$report | Set-Content -LiteralPath $reportMd -Encoding UTF8

Write-Host "GVT AV sync estimate"
Write-Host "  Summary: $summaryJson"
Write-Host "  Nearest pairs=$($nearestPairs.Count) estimated_audio_minus_video_avg_ms=$nearestAvgOffset relative_drift_max_ms=$nearestMaxAbsRelativeDrift"
Write-Host "  Legacy index pairs=$pairCount estimated_audio_minus_video_avg_ms=$avgOffset max_abs_ms=$maxAbsOffset"
