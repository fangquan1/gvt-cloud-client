<#
.SYNOPSIS
Measures GVT Cloud client video receive performance.

.DESCRIPTION
Launches gvt_spice_viewer with video probes enabled, samples the client
gvt_spice_viewer.log, optionally samples the remote QEMU log over SSH, then
writes summary.json, summary.csv, report.md, viewer.log, and server.log.
#>
param(
    [string]$ServerHost = "192.168.0.188",
    [int]$VideoPort = 5004,
    [int]$SpicePort = 5900,
    [int]$InputPort = 5905,
    [ValidateSet("h264", "h265")]
    [string]$Codec = "h264",
    [int]$Latency = 15,
    [int]$SourceWidth = 1920,
    [int]$SourceHeight = 1200,
    [int]$WarmupSec = 3,
    [int]$DurationSec = 20,
    [string]$ViewerPath = "",
    [string]$GstRoot = "",
    [string]$SpiceRuntime = "",
    [string]$OutDir = "build\video-performance",
    [string]$ServerSsh = "root@192.168.0.188",
    [string]$ServerLog = "/root/qemu_cmd/win10-gvt-stream-diag.log",
    [switch]$LeaveWindowOpen,
    [switch]$KeepProbeViewerOpen,
    [switch]$SkipGstWarmup,
    [switch]$StopExistingViewer
)

$ErrorActionPreference = "Stop"
$ClientRoot = Split-Path -Parent $PSScriptRoot
$script:SshPath = $null
$script:LastSshCommand = $null
$script:LastSshExitCode = $null
$script:LastSshOutputPreview = @()

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
    param([string[]]$ArgList)

    return (($ArgList | ForEach-Object { Quote-ProcessArg $_ }) -join " ")
}

function Get-LocalLineCount {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        return 0
    }

    return (Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue | Measure-Object -Line).Lines
}

function Get-LocalLogTail {
    param(
        [string]$Path,
        [int]$StartLine
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $allLines = @(Get-Content -LiteralPath $Path -ErrorAction SilentlyContinue)
    $tail = New-Object System.Collections.Generic.List[string]
    for ($i = $StartLine; $i -lt $allLines.Count; $i++) {
        [void]$tail.Add($allLines[$i])
    }
    return $tail.ToArray()
}

function Get-RemoteQuoted {
    param([string]$Value)

    if ($Value -match "'") {
        throw "Remote paths with single quotes are not supported: $Value"
    }
    return "'" + $Value + "'"
}

function Invoke-SshText {
    param([string]$RemoteCommand)

    if ([string]::IsNullOrWhiteSpace($ServerSsh)) {
        return @()
    }

    try {
        $sshCommand = Get-Command ssh.exe -ErrorAction Stop
        $script:SshPath = $sshCommand.Source
        $script:LastSshCommand = $RemoteCommand
        $sshArgs = @("-o", "BatchMode=yes", "-o", "ConnectTimeout=5", $ServerSsh, $RemoteCommand)
        $oldErrorActionPreference = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        try {
            $output = & $sshCommand.Source @sshArgs 2>&1
        }
        finally {
            $ErrorActionPreference = $oldErrorActionPreference
        }
        $lines = @($output | ForEach-Object { $_.ToString() })
        $script:LastSshExitCode = $LASTEXITCODE
        $script:LastSshOutputPreview = @($lines | Select-Object -First 5)
        if ($LASTEXITCODE -ne 0 -and $lines.Count -eq 0) {
            return @()
        }
        return $lines
    }
    catch {
        $script:LastSshExitCode = -1
        $script:LastSshOutputPreview = @($_.Exception.Message)
        return @()
    }
}

function Get-RemoteLineCount {
    if ([string]::IsNullOrWhiteSpace($ServerLog)) {
        return $null
    }

    $quotedLog = Get-RemoteQuoted $ServerLog
    $lines = Invoke-SshText "wc -l < $quotedLog"
    if ($lines.Count -eq 0) {
        return $null
    }

    foreach ($line in $lines) {
        $count = 0
        if ([int]::TryParse(($line.ToString().Trim()), [ref]$count)) {
            return $count
        }
    }

    return $null
}

function Get-RemoteLogTail {
    param([Nullable[int]]$StartLine)

    $quotedLog = Get-RemoteQuoted $ServerLog
    if ($null -eq $StartLine) {
        return Invoke-SshText "tail -n 300 $quotedLog"
    }

    return Invoke-SshText "awk 'NR>$StartLine {print}' $quotedLog"
}

function Get-NumberStats {
    param([object[]]$Values)

    $numbers = @($Values | Where-Object { $null -ne $_ } | ForEach-Object { [double]$_ })
    if ($numbers.Count -eq 0) {
        return [ordered]@{
            count = 0
            avg = $null
            min = $null
            max = $null
        }
    }

    $measure = $numbers | Measure-Object -Average -Minimum -Maximum
    return [ordered]@{
        count = $numbers.Count
        avg = [Math]::Round([double]$measure.Average, 2)
        min = [Math]::Round([double]$measure.Minimum, 2)
        max = [Math]::Round([double]$measure.Maximum, 2)
    }
}

function Get-FieldNumber {
    param(
        [string]$Line,
        [string]$Name
    )

    $pattern = "(?:^|\s)" + [regex]::Escape($Name) + "=([0-9.]+)"
    if ($Line -match $pattern) {
        return [double]$Matches[1]
    }
    return $null
}

function Copy-TextLines {
    param(
        [string[]]$Lines,
        [string]$Path
    )

    if ($Lines.Count -eq 0) {
        Set-Content -LiteralPath $Path -Value "" -Encoding UTF8
        return
    }
    Set-Content -LiteralPath $Path -Value $Lines -Encoding UTF8
}

New-Item -ItemType Directory -Force -Path (Join-Path $ClientRoot $OutDir) | Out-Null
$OutDirPath = (Resolve-Path -LiteralPath (Join-Path $ClientRoot $OutDir)).Path

$ViewerPath = Resolve-ViewerExe $ViewerPath
$GstRoot = Resolve-GstreamerRoot $GstRoot
$SpiceRuntime = Resolve-SpiceRuntime $SpiceRuntime
$ViewerDir = Split-Path -Parent $ViewerPath
$ViewerLog = Join-Path $ViewerDir "gvt_spice_viewer.log"

if ($StopExistingViewer) {
    Get-Process -Name "gvt_spice_viewer" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500
}

if (-not $SkipGstWarmup) {
    & $ViewerPath --gst-warmup --gst-root $GstRoot | Out-Null
}

$localStartLine = Get-LocalLineCount $ViewerLog
$remoteStartLine = Get-RemoteLineCount

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
    "--gst-root", $GstRoot,
    "--spice-runtime", $SpiceRuntime,
    "--source-width", $SourceWidth.ToString(),
    "--source-height", $SourceHeight.ToString(),
    "--no-drop-on-latency",
    "--auto-size"
)

$startInfo = New-Object System.Diagnostics.ProcessStartInfo
$startInfo.FileName = $ViewerPath
$startInfo.WorkingDirectory = $ViewerDir
$startInfo.UseShellExecute = $false
$startInfo.Arguments = Join-ProcessArgs $viewerArgs
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_VIDEO_DEBUG"] = "1"
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_DROP_COMPLETE_FRAMES"] = "1"
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_UDP_BUFFER_SIZE"] = "2097152"
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_JITTER_DROPOUT_MS"] = "60"
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_JITTER_MISORDER_MS"] = "20"
$startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_VIDEO_TAIL"] = "queue name=post_decode_q leaky=downstream max-size-buffers=1 max-size-time=0 max-size-bytes=0 ! d3d11videosink name=vsink sync=false async=false qos=true max-lateness=0 processing-deadline=0 render-delay=0 enable-last-sample=false"
$startInfo.EnvironmentVariables["PATH"] = (Join-Path $GstRoot "bin") + ";" + $SpiceRuntime + ";" + $env:PATH

$process = New-Object System.Diagnostics.Process
$process.StartInfo = $startInfo
[void]$process.Start()
$probeProcess = $process
$probeViewerReplaced = $false

$totalWaitSec = [Math]::Max(1, $WarmupSec + $DurationSec)
Start-Sleep -Seconds $totalWaitSec

$localLines = @(Get-LocalLogTail -Path $ViewerLog -StartLine $localStartLine)
$serverLines = @(Get-RemoteLogTail -StartLine $remoteStartLine)

if ($LeaveWindowOpen -and -not $KeepProbeViewerOpen) {
    if (-not $probeProcess.HasExited) {
        $probeProcess.CloseMainWindow() | Out-Null
        if (-not $probeProcess.WaitForExit(2000)) {
            $probeProcess.Kill()
            $probeProcess.WaitForExit()
        }
    }
    Start-Sleep -Milliseconds 1500

    $steadyStartInfo = New-Object System.Diagnostics.ProcessStartInfo
    $steadyStartInfo.FileName = $ViewerPath
    $steadyStartInfo.WorkingDirectory = $ViewerDir
    $steadyStartInfo.UseShellExecute = $false
    $steadyStartInfo.Arguments = Join-ProcessArgs $viewerArgs
    $steadyStartInfo.EnvironmentVariables["GVT_SPICE_VIEWER_DROP_COMPLETE_FRAMES"] = "1"
    $steadyStartInfo.EnvironmentVariables["GVT_SPICE_VIEWER_UDP_BUFFER_SIZE"] = "2097152"
    $steadyStartInfo.EnvironmentVariables["GVT_SPICE_VIEWER_JITTER_DROPOUT_MS"] = "60"
    $steadyStartInfo.EnvironmentVariables["GVT_SPICE_VIEWER_JITTER_MISORDER_MS"] = "20"
    $steadyStartInfo.EnvironmentVariables["GVT_SPICE_VIEWER_VIDEO_TAIL"] = $startInfo.EnvironmentVariables["GVT_SPICE_VIEWER_VIDEO_TAIL"]
    $steadyStartInfo.EnvironmentVariables["PATH"] = $startInfo.EnvironmentVariables["PATH"]

    $steadyProcess = New-Object System.Diagnostics.Process
    $steadyProcess.StartInfo = $steadyStartInfo
    [void]$steadyProcess.Start()
    $process = $steadyProcess
    $probeViewerReplaced = $true
    Start-Sleep -Seconds 3
}
elseif (-not $LeaveWindowOpen -and -not $process.HasExited) {
    $process.CloseMainWindow() | Out-Null
    if (-not $process.WaitForExit(2000)) {
        $process.Kill()
        $process.WaitForExit()
    }
}

Start-Sleep -Milliseconds 500

$pipeline = ($localLines | Where-Object { $_ -match "video pipeline:" } | Select-Object -Last 1)
$streamControlReadyMs = $null
$mediaStackReadyMs = $null
$gstReceiverReadyMs = $null
$probeRows = New-Object System.Collections.Generic.List[object]

foreach ($line in $localLines) {
    if ($line -match "^\+(\d+)ms\s+media-stack ready total=(\d+)ms") {
        $mediaStackReadyMs = [int]$Matches[2]
    }
    elseif ($line -match "^\+(\d+)ms\s+stream-control start-sent") {
        $streamControlReadyMs = [int]$Matches[1]
    }
    elseif ($line -match "^\+(\d+)ms\s+gst receiver thread ready total=(\d+)ms") {
        $gstReceiverReadyMs = [int]$Matches[2]
    }
    elseif ($line -match "^\+(\d+)ms\s+video-probe fps\s+jitter_out=(\d+)\s+depay_out=(\d+)\s+parse_out=(\d+)\s+decode_out=(\d+)") {
        [void]$probeRows.Add([pscustomobject]@{
            elapsed_ms = [int]$Matches[1]
            jitter_out = [int]$Matches[2]
            depay_out = [int]$Matches[3]
            parse_out = [int]$Matches[4]
            decode_out = [int]$Matches[5]
        })
    }
}

$steadyProbeRows = @($probeRows | Where-Object { $_.elapsed_ms -ge ($WarmupSec * 1000) })
if ($steadyProbeRows.Count -eq 0) {
    $steadyProbeRows = @($probeRows)
}

$serverUpdateRows = New-Object System.Collections.Generic.List[object]
$encodeStartLine = ($serverLines | Where-Object { $_ -match "encode-start" } | Select-Object -Last 1)
$streamStopped = [bool]($serverLines | Where-Object { $_ -match "stream stopped|encode-finish" } | Select-Object -First 1)

foreach ($line in $serverLines) {
    if ($line -notmatch "update-stats") {
        continue
    }

    [void]$serverUpdateRows.Add([pscustomobject]@{
        fps = Get-FieldNumber -Line $line -Name "fps"
        encoded = Get-FieldNumber -Line $line -Name "encoded"
        encode_failures = Get-FieldNumber -Line $line -Name "encode_failures"
        bitrate = Get-FieldNumber -Line $line -Name "bitrate"
        target_bitrate = Get-FieldNumber -Line $line -Name "target_bitrate"
        capture_ms = Get-FieldNumber -Line $line -Name "capture_ms"
    })
}

$lastServerUpdate = $null
if ($serverUpdateRows.Count -gt 0) {
    $lastServerUpdate = $serverUpdateRows[$serverUpdateRows.Count - 1]
}

$viewerLogOut = Join-Path $OutDirPath "viewer.log"
$serverLogOut = Join-Path $OutDirPath "server.log"
$summaryJson = Join-Path $OutDirPath "summary.json"
$summaryCsv = Join-Path $OutDirPath "summary.csv"
$reportMd = Join-Path $OutDirPath "report.md"

Copy-TextLines -Lines $localLines -Path $viewerLogOut
Copy-TextLines -Lines $serverLines -Path $serverLogOut

$summary = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    client_root = $ClientRoot
    viewer_path = $ViewerPath
    viewer_pid = $process.Id
    viewer_running = (-not $process.HasExited)
    viewer_left_open = [bool]$LeaveWindowOpen
    probe_viewer_pid = $probeProcess.Id
    probe_viewer_replaced = $probeViewerReplaced
    keep_probe_viewer_open = [bool]$KeepProbeViewerOpen
    duration_sec = $DurationSec
    warmup_sec = $WarmupSec
    codec = $Codec
    server_host = $ServerHost
    video_port = $VideoPort
    spice_port = $SpicePort
    input_port = $InputPort
    source_width = $SourceWidth
    source_height = $SourceHeight
    latency_ms = $Latency
    output_dir = $OutDirPath
    viewer_log = $viewerLogOut
    server_log = $serverLogOut
    pipeline = $pipeline
    client = [ordered]@{
        probe_samples_total = $probeRows.Count
        probe_samples = $steadyProbeRows.Count
        jitter_out_fps = Get-NumberStats @($steadyProbeRows | ForEach-Object { $_.jitter_out })
        depay_out_fps = Get-NumberStats @($steadyProbeRows | ForEach-Object { $_.depay_out })
        parse_out_fps = Get-NumberStats @($steadyProbeRows | ForEach-Object { $_.parse_out })
        decode_out_fps = Get-NumberStats @($steadyProbeRows | ForEach-Object { $_.decode_out })
        media_stack_ready_ms = $mediaStackReadyMs
        stream_control_start_sent_ms = $streamControlReadyMs
        gst_receiver_ready_ms = $gstReceiverReadyMs
    }
    server = [ordered]@{
        log_available = ($serverLines.Count -gt 0)
        start_line = $remoteStartLine
        ssh_path = $script:SshPath
        ssh_last_command = $script:LastSshCommand
        ssh_last_exit_code = $script:LastSshExitCode
        ssh_last_output_preview = $script:LastSshOutputPreview
        encode_start = $encodeStartLine
        update_samples = $serverUpdateRows.Count
        fps = Get-NumberStats @($serverUpdateRows | ForEach-Object { $_.fps })
        capture_ms = Get-NumberStats @($serverUpdateRows | ForEach-Object { $_.capture_ms })
        bitrate = Get-NumberStats @($serverUpdateRows | ForEach-Object { $_.bitrate })
        target_bitrate = Get-NumberStats @($serverUpdateRows | ForEach-Object { $_.target_bitrate })
        encoded_last = if ($null -ne $lastServerUpdate) { $lastServerUpdate.encoded } else { $null }
        encode_failures_last = if ($null -ne $lastServerUpdate) { $lastServerUpdate.encode_failures } else { $null }
        stream_stopped = $streamStopped
    }
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

$flat = [pscustomobject]@{
    generated_at = $summary.generated_at
    viewer_pid = $summary.viewer_pid
    viewer_running = $summary.viewer_running
    codec = $summary.codec
    warmup_sec = $summary.warmup_sec
    duration_sec = $summary.duration_sec
    latency_ms = $summary.latency_ms
    probe_samples = $summary.client.probe_samples
    depay_fps_avg = $summary.client.depay_out_fps.avg
    parse_fps_avg = $summary.client.parse_out_fps.avg
    decode_fps_avg = $summary.client.decode_out_fps.avg
    stream_control_start_sent_ms = $summary.client.stream_control_start_sent_ms
    gst_receiver_ready_ms = $summary.client.gst_receiver_ready_ms
    server_update_samples = $summary.server.update_samples
    server_fps_avg = $summary.server.fps.avg
    server_capture_ms_avg = $summary.server.capture_ms.avg
    server_encode_failures_last = $summary.server.encode_failures_last
}
$flat | Export-Csv -LiteralPath $summaryCsv -NoTypeInformation -Encoding UTF8

$reportLines = @(
    "# GVT video performance report",
    "",
    "- Generated: $($summary.generated_at)",
    "- Viewer: $ViewerPath",
    "- Output: $OutDirPath",
    "- Client probe samples: $($summary.client.probe_samples) steady / $($summary.client.probe_samples_total) total",
    "- Client FPS: depay avg $($summary.client.depay_out_fps.avg), parse avg $($summary.client.parse_out_fps.avg), decode avg $($summary.client.decode_out_fps.avg)",
    "- Startup: media stack $($summary.client.media_stack_ready_ms) ms, stream control start $($summary.client.stream_control_start_sent_ms) ms, gst receiver $($summary.client.gst_receiver_ready_ms) ms",
    "- Server samples: $($summary.server.update_samples), fps avg $($summary.server.fps.avg), capture avg $($summary.server.capture_ms.avg) ms, encode failures last $($summary.server.encode_failures_last)",
    "- Viewer left open: $([bool]$LeaveWindowOpen), pid $($process.Id)",
    "- Probe viewer replaced for steady run: $probeViewerReplaced, probe pid $($probeProcess.Id)",
    "",
    "## Reference model",
    "",
    "- Moonlight exposes a client-side video stats overlay: incoming, decoded, rendered FPS, dropped frames, network/reassembly/decode/pacer/render times.",
    "- Sunshine emits service-side periodic video/network latency logs around frame processing, send batches, FEC, and whole-frame network latency.",
    "- This script mirrors that split using our client probe FPS plus the remote QEMU update-stats log."
)
Set-Content -LiteralPath $reportMd -Value $reportLines -Encoding UTF8

Write-Host "GVT video performance summary"
Write-Host "  Output: $OutDirPath"
Write-Host "  Client FPS avg: depay=$($summary.client.depay_out_fps.avg) parse=$($summary.client.parse_out_fps.avg) decode=$($summary.client.decode_out_fps.avg)"
Write-Host "  Startup ms: stream-control=$($summary.client.stream_control_start_sent_ms) gst-ready=$($summary.client.gst_receiver_ready_ms)"
Write-Host "  Server: samples=$($summary.server.update_samples) fps=$($summary.server.fps.avg) encode_failures=$($summary.server.encode_failures_last)"
if ($LeaveWindowOpen) {
    Write-Host "  Viewer left open, pid=$($process.Id)"
}
