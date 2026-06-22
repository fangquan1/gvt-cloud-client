<#
.SYNOPSIS
Runs a short automated GVT Cloud video receive smoke test.
#>
param(
    [string]$ServerHost = "192.168.0.188",
    [int]$VideoPort = 5004,
    [int]$SpicePort = 5900,
    [int]$InputPort = 5905,
    [ValidateSet("h264", "h265")]
    [string]$Codec = "h265",
    [int]$Latency = 15,
    [int]$WarmupSec = 3,
    [int]$DurationSec = 20,
    [double]$MinDepayFps = 50.0,
    [double]$MinDecodeFps = 50.0,
    [int]$MinProbeSamples = 5,
    [double]$MinLowBandwidthDecodeFps = 1.0,
    [int]$MinLowBandwidthStreamdFrames = 1,
    [int]$MaxEncodeFailures = 0,
    [string]$ViewerPath = "",
    [string]$GstRoot = "",
    [string]$SpiceRuntime = "",
    [string]$OutDir = "build\video-performance",
    [string]$ServerSsh = "root@192.168.0.188",
    [string]$ServerLog = "/root/qemu_cmd/win10-gvt-stream-diag.log",
    [switch]$LeaveWindowOpen,
    [switch]$StopExistingViewer,
    [switch]$RequireServerStats,
    [switch]$RequireFullRateClientFps
)

$ErrorActionPreference = "Stop"
$ClientRoot = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runOutDir = Join-Path $OutDir "smoke-$stamp"
$measureScript = Join-Path $PSScriptRoot "measure-gvt-video-performance.ps1"

$measureArgs = @{
    ServerHost = $ServerHost
    VideoPort = $VideoPort
    SpicePort = $SpicePort
    InputPort = $InputPort
    Codec = $Codec
    Latency = $Latency
    WarmupSec = $WarmupSec
    DurationSec = $DurationSec
    SpiceRuntime = $SpiceRuntime
    OutDir = $runOutDir
    ServerSsh = $ServerSsh
    ServerLog = $ServerLog
}

if (-not [string]::IsNullOrWhiteSpace($ViewerPath)) {
    $measureArgs.ViewerPath = $ViewerPath
}
if (-not [string]::IsNullOrWhiteSpace($GstRoot)) {
    $measureArgs.GstRoot = $GstRoot
}
if ($LeaveWindowOpen) {
    $measureArgs.LeaveWindowOpen = $true
}
if ($StopExistingViewer) {
    $measureArgs.StopExistingViewer = $true
}

& $measureScript @measureArgs
if (-not $?) {
    exit 1
}

$summaryPath = Join-Path (Join-Path $ClientRoot $runOutDir) "summary.json"
$summary = Get-Content -LiteralPath $summaryPath -Raw | ConvertFrom-Json
$failures = New-Object System.Collections.Generic.List[string]

function Get-SmokeNumber {
    param($Value, [double]$Default = 0.0)

    if ($null -eq $Value) {
        return $Default
    }
    try {
        return [double]$Value
    } catch {
        return $Default
    }
}

if ($summary.client.probe_samples -lt $MinProbeSamples) {
    [void]$failures.Add("Only $($summary.client.probe_samples) steady probe samples, expected at least $MinProbeSamples.")
}

if ($null -eq $summary.client.stream_control_start_sent_ms) {
    [void]$failures.Add("No client stream-control start marker found.")
}

if ($null -eq $summary.client.gst_receiver_ready_ms) {
    [void]$failures.Add("No client gst receiver ready marker found.")
}

if ($RequireServerStats -and -not $summary.server.log_available) {
    [void]$failures.Add("Remote server log was not available.")
}

if ($summary.server.log_available -and $null -ne $summary.server.encode_failures_last -and [double]$summary.server.encode_failures_last -gt $MaxEncodeFailures) {
    [void]$failures.Add("Server encode failures $($summary.server.encode_failures_last), expected <= $MaxEncodeFailures.")
}

$depayAvg = Get-SmokeNumber $summary.client.depay_out_fps.avg -Default (-1.0)
$decodeAvg = Get-SmokeNumber $summary.client.decode_out_fps.avg -Default (-1.0)
$streamdEncodedDelta = Get-SmokeNumber $summary.server.streamd_encoded.delta
$streamdRoiDelta = Get-SmokeNumber $summary.server.streamd_roi.delta
$streamdFailureDelta = Get-SmokeNumber $summary.server.streamd_failures.delta
$dirtySkippedDelta = Get-SmokeNumber $summary.server.dirty_skipped.delta
$dirtyRoiDelta = Get-SmokeNumber $summary.server.dirty_roi.delta
$lowBandwidthActive = (-not $RequireFullRateClientFps) -and
    [bool]$summary.server.log_available -and
    ($streamdEncodedDelta -ge $MinLowBandwidthStreamdFrames) -and
    (($streamdRoiDelta -gt 0) -or ($dirtyRoiDelta -gt 0) -or ($dirtySkippedDelta -gt 0))

if ($lowBandwidthActive) {
    if ($decodeAvg -lt $MinLowBandwidthDecodeFps) {
        [void]$failures.Add("Low-bandwidth decode FPS avg $($summary.client.decode_out_fps.avg), expected >= $MinLowBandwidthDecodeFps while ROI/static skipping is active.")
    }
    if ($streamdFailureDelta -gt 0) {
        [void]$failures.Add("streamd failures delta $streamdFailureDelta, expected 0.")
    }
} else {
    if ($null -eq $summary.client.depay_out_fps.avg -or $depayAvg -lt $MinDepayFps) {
        [void]$failures.Add("Client depay FPS avg $($summary.client.depay_out_fps.avg), expected >= $MinDepayFps.")
    }

    if ($null -eq $summary.client.decode_out_fps.avg -or $decodeAvg -lt $MinDecodeFps) {
        [void]$failures.Add("Client decode FPS avg $($summary.client.decode_out_fps.avg), expected >= $MinDecodeFps.")
    }
}

if ($failures.Count -gt 0) {
    Write-Host "GVT stream smoke: FAIL"
    foreach ($failure in $failures) {
        Write-Host "  - $failure"
    }
    Write-Host "  Summary: $summaryPath"
    exit 1
}

Write-Host "GVT stream smoke: PASS"
Write-Host "  Summary: $summaryPath"
Write-Host "  Client FPS avg: depay=$($summary.client.depay_out_fps.avg) decode=$($summary.client.decode_out_fps.avg)"
Write-Host "  Low-bandwidth active: $lowBandwidthActive streamd_delta=$streamdEncodedDelta roi_delta=$streamdRoiDelta dirty_skipped_delta=$dirtySkippedDelta"
Write-Host "  Viewer pid: $($summary.viewer_pid), running=$($summary.viewer_running)"
