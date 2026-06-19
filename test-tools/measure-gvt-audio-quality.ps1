<#
.SYNOPSIS
Measures GVT Cloud SPICE audio quality with a deterministic reference clip.

.DESCRIPTION
The script records the local Windows render endpoint with GStreamer wasapisrc
loopback, triggers the guest test agent to play the same 20 second reference
WAV, then compares the recorded WAV against the reference.
#>
param(
    [string]$ServerSsh = "root@192.168.0.188",
    [string]$QgaSock = "/root/qemu_cmd/win10-gvt-stream-qga.sock",
    [string]$GuestRoot = "C:\ProgramData\GvtCloudTest",
    [ValidateSet("agent-file", "qga-once", "none")]
    [string]$GuestTrigger = "agent-file",
    [string]$GstRoot = "",
    [int]$DurationSec = 20,
    [int]$PreRollMs = 1200,
    [int]$PostRollSec = 2,
    [int]$SampleRate = 48000,
    [int]$LatencyUs = 10000,
    [string]$OutDir = "build\audio-quality",
    [switch]$BatchMode,
    [int]$MinDetectedPulses = 8,
    [double]$MaxClippedPct = 0.10,
    [double]$MaxDropoutWindowPct = 4.0,
    [double]$MinCorrelation = 0.55,
    [double]$MinSnrDb = 6.0,
    [double]$MaxPulseIntervalErrorMs = 120.0,
    [int]$MaxPopEvents = 3,
    [int]$MaxSeverePopEvents = 0,
    [double]$PopThresholdMad = 12.0,
    [double]$MinPopDelta = 0.035,
    [double]$SeverePopScore = 1.8,
    [double]$PeriodicPopConfidenceThreshold = 0.72,
    [int]$WaveformPlotPoints = 2400,
    [int]$SpectrumFftSize = 8192,
    [int]$SpectrumWindows = 24,
    [double]$SpectrumMaxHz = 12000.0,
    [switch]$RequireWaveformMatch
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "gvt-test-common.ps1")

function Quote-GvtProcessArg {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Join-GvtProcessArgs {
    param([string[]]$ArgList)

    return (($ArgList | ForEach-Object { Quote-GvtProcessArg $_ }) -join " ")
}

function Get-GvtWavRms {
    param([double[]]$Samples)

    if ($Samples.Length -eq 0) {
        return 0.0
    }
    $sum = 0.0
    foreach ($sample in $Samples) {
        $sum += $sample * $sample
    }
    return [Math]::Sqrt($sum / [double]$Samples.Length)
}

function Get-GvtClipStats {
    param([double[]]$Samples)

    $peak = 0.0
    $clipped = 0
    foreach ($sample in $Samples) {
        $abs = [Math]::Abs($sample)
        if ($abs -gt $peak) {
            $peak = $abs
        }
        if ($abs -ge 0.985) {
            $clipped++
        }
    }

    $pct = if ($Samples.Length -gt 0) { 100.0 * [double]$clipped / [double]$Samples.Length } else { 0.0 }
    return [pscustomobject]@{
        peak = [Math]::Round($peak, 5)
        clipped_samples = $clipped
        clipped_pct = [Math]::Round($pct, 5)
    }
}

function Measure-GvtAlignedAudio {
    param(
        $Reference,
        $Recorded,
        [double[]]$ReferencePulses,
        [double[]]$RecordedPulses
    )

    if ($Reference.SampleRate -ne $Recorded.SampleRate) {
        throw "Sample rates differ: reference=$($Reference.SampleRate), recorded=$($Recorded.SampleRate)"
    }
    $sr = [int]$Reference.SampleRate
    $offsetSec = $RecordedPulses[0] - $ReferencePulses[0]
    $offsetSamples = [int][Math]::Round($offsetSec * $sr)

    $refStart = 0
    $recStart = $offsetSamples
    if ($recStart -lt 0) {
        $refStart = -$recStart
        $recStart = 0
    }

    $count = [Math]::Min($Reference.Samples.Length - $refStart, $Recorded.Samples.Length - $recStart)
    if ($count -le ($sr * 2)) {
        throw "Not enough overlapping audio after alignment. count=$count"
    }

    $sumRef2 = 0.0
    $sumRec2 = 0.0
    $sumProd = 0.0
    for ($i = 0; $i -lt $count; $i++) {
        $r = $Reference.Samples[$refStart + $i]
        $d = $Recorded.Samples[$recStart + $i]
        $sumRef2 += $r * $r
        $sumRec2 += $d * $d
        $sumProd += $r * $d
    }

    $gain = if ($sumRef2 -gt 0.0) { $sumProd / $sumRef2 } else { 0.0 }
    $err = 0.0
    for ($i = 0; $i -lt $count; $i++) {
        $r = $Reference.Samples[$refStart + $i] * $gain
        $d = $Recorded.Samples[$recStart + $i]
        $delta = $d - $r
        $err += $delta * $delta
    }

    $corr = if ($sumRef2 -gt 0.0 -and $sumRec2 -gt 0.0) { $sumProd / [Math]::Sqrt($sumRef2 * $sumRec2) } else { 0.0 }
    $signal = $gain * $gain * $sumRef2
    $snr = if ($err -gt 0.0 -and $signal -gt 0.0) { 10.0 * [Math]::Log10($signal / $err) } else { 99.0 }

    $window = [Math]::Max(128, [int]($sr * 0.020))
    $dropouts = 0
    $activeWindows = 0
    for ($i = 0; ($i + $window) -le $count; $i += $window) {
        $sumRef = 0.0
        $sumRec = 0.0
        for ($j = 0; $j -lt $window; $j++) {
            $r = $Reference.Samples[$refStart + $i + $j]
            $d = $Recorded.Samples[$recStart + $i + $j]
            $sumRef += $r * $r
            $sumRec += $d * $d
        }
        $refRms = [Math]::Sqrt($sumRef / [double]$window)
        $recRms = [Math]::Sqrt($sumRec / [double]$window)
        if ($refRms -ge 0.025) {
            $activeWindows++
            $expected = [Math]::Abs($gain) * $refRms
            if ($recRms -lt [Math]::Max(0.0025, $expected * 0.10)) {
                $dropouts++
            }
        }
    }

    $dropoutPct = if ($activeWindows -gt 0) { 100.0 * [double]$dropouts / [double]$activeWindows } else { 0.0 }

    return [pscustomobject]@{
        offset_sec = [Math]::Round($offsetSec, 5)
        offset_samples = $offsetSamples
        overlap_sec = [Math]::Round([double]$count / [double]$sr, 3)
        gain = [Math]::Round($gain, 5)
        correlation = [Math]::Round($corr, 5)
        snr_db = [Math]::Round($snr, 2)
        dropout_windows = $dropouts
        active_windows = $activeWindows
        dropout_window_pct = [Math]::Round($dropoutPct, 4)
    }
}

function Measure-GvtPulseTiming {
    param([double[]]$RecordedPulses)

    $errors = New-Object System.Collections.Generic.List[double]
    for ($i = 1; $i -lt $RecordedPulses.Length; $i++) {
        $interval = $RecordedPulses[$i] - $RecordedPulses[$i - 1]
        [void]$errors.Add(($interval - 2.0) * 1000.0)
    }

    $maxAbs = 0.0
    foreach ($err in $errors) {
        $abs = [Math]::Abs($err)
        if ($abs -gt $maxAbs) {
            $maxAbs = $abs
        }
    }

    $driftRatio = $null
    if ($RecordedPulses.Length -ge 2) {
        $driftRatio = (($RecordedPulses[$RecordedPulses.Length - 1] - $RecordedPulses[0]) / (2.0 * ($RecordedPulses.Length - 1)))
    }

    return [pscustomobject]@{
        interval_errors_ms = @($errors | ForEach-Object { [Math]::Round($_, 2) })
        max_abs_interval_error_ms = [Math]::Round($maxAbs, 2)
        drift_ratio = if ($null -ne $driftRatio) { [Math]::Round($driftRatio, 6) } else { $null }
    }
}

$clientRoot = Resolve-GvtClientRoot
$resolvedOut = Join-Path $clientRoot $OutDir
New-Item -ItemType Directory -Force -Path $resolvedOut | Out-Null
$runDir = Join-Path $resolvedOut ("audio-" + (Get-Date -Format "yyyyMMdd-HHmmss"))
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$referenceWav = Join-Path $runDir "reference.wav"
$recordedWav = Join-Path $runDir "recorded-loopback.wav"
$recordedWavForGst = $recordedWav -replace "\\", "/"
$gstLog = Join-Path $runDir "gst-loopback.log"
$summaryJson = Join-Path $runDir "summary.json"
$reportMd = Join-Path $runDir "report.md"
$waveformAnalysisDir = Join-Path $runDir "waveform-analysis"
$waveformAnalysisJson = Join-Path $waveformAnalysisDir "waveform-analysis.json"
$waveformAnalysisLog = Join-Path $waveformAnalysisDir "waveform-analysis.log"

Write-Host "Generating reference audio..."
New-GvtReferenceAudioFile -Path $referenceWav -DurationSec $DurationSec -SampleRate $SampleRate -Channels 2

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

Write-Host "Recording loopback audio for about $recordSec seconds..."
$process = [Diagnostics.Process]::new()
$process.StartInfo = $startInfo
[void]$process.Start()

Start-Sleep -Milliseconds $PreRollMs

if ($GuestTrigger -eq "agent-file") {
    Write-Host "Triggering guest agent playback through command.json..."
    $cmd = @{
        command = "play-audio-test"
        duration_sec = $DurationSec
        sample_rate = $SampleRate
        generated_at = (Get-Date).ToString("o")
    } | ConvertTo-Json -Compress
    $guestCommandPath = Join-Path $GuestRoot "command.json"
    Write-GvtQgaFile `
        -GuestPath $guestCommandPath `
        -Text $cmd `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -BatchMode:$BatchMode
} elseif ($GuestTrigger -eq "qga-once") {
    Write-Host "Triggering guest one-shot playback through QGA guest-exec..."
    $guestAgent = Join-Path $GuestRoot "gvt-test-agent.ps1"
    [void](Invoke-GvtQgaCommand `
        -Command @{
            execute = "guest-exec"
            arguments = @{
                path = "powershell.exe"
                arg = @("-NoProfile", "-ExecutionPolicy", "Bypass", "-WindowStyle", "Hidden", "-File", $guestAgent, "-Once", "-Command", "play-audio-test", "-DurationSec", $DurationSec.ToString(), "-SampleRate", $SampleRate.ToString())
                "capture-output" = $false
            }
        } `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -BatchMode:$BatchMode)
} else {
    Write-Host "GuestTrigger=none. Start playback in the guest now."
}

$waitMs = [int](($recordSec + 8) * 1000)
if (-not $process.WaitForExit($waitMs)) {
    $process.Kill()
    $process.WaitForExit()
}

$stdout = $process.StandardOutput.ReadToEnd()
$stderr = $process.StandardError.ReadToEnd()
Set-Content -LiteralPath $gstLog -Value ($stdout + "`r`n" + $stderr) -Encoding UTF8

if (-not (Test-Path -LiteralPath $recordedWav)) {
    throw "Loopback recording was not created. See $gstLog"
}

Write-Host "Analyzing recorded audio..."
$ref = Read-GvtPcm16Wav -Path $referenceWav
$rec = Read-GvtPcm16Wav -Path $recordedWav
$refPulses = @(Get-GvtPulseTimes -Samples $ref.Samples -SampleRate $ref.SampleRate)
$recPulses = @(Get-GvtPulseTimes -Samples $rec.Samples -SampleRate $rec.SampleRate)
$clip = Get-GvtClipStats -Samples $rec.Samples
$recRms = Get-GvtWavRms -Samples $rec.Samples

$alignment = $null
$pulseTiming = $null
if ($refPulses.Count -gt 0 -and $recPulses.Count -gt 0) {
    $alignment = Measure-GvtAlignedAudio -Reference $ref -Recorded $rec -ReferencePulses $refPulses -RecordedPulses $recPulses
    $pulseTiming = Measure-GvtPulseTiming -RecordedPulses $recPulses
}

$waveformAnalysis = $null
$waveformAnalysisError = $null
try {
    New-Item -ItemType Directory -Force -Path $waveformAnalysisDir | Out-Null
    $python = (Get-Command python.exe -ErrorAction Stop).Source
    $analyzer = Join-Path $PSScriptRoot "analyze-gvt-audio-waveform.py"
    if (-not (Test-Path -LiteralPath $analyzer)) {
        throw "Waveform analyzer not found: $analyzer"
    }

    $analysisArgs = @(
        $analyzer,
        "--reference", $referenceWav,
        "--recorded", $recordedWav,
        "--out-dir", $waveformAnalysisDir,
        "--points", $WaveformPlotPoints.ToString(),
        "--pop-mad", $PopThresholdMad.ToString([Globalization.CultureInfo]::InvariantCulture),
        "--min-pop-delta", $MinPopDelta.ToString([Globalization.CultureInfo]::InvariantCulture),
        "--severe-score", $SeverePopScore.ToString([Globalization.CultureInfo]::InvariantCulture),
        "--max-pop-events", $MaxPopEvents.ToString(),
        "--max-severe-pop-events", $MaxSeverePopEvents.ToString(),
        "--periodic-confidence-threshold", $PeriodicPopConfidenceThreshold.ToString([Globalization.CultureInfo]::InvariantCulture),
        "--spectrum-fft-size", $SpectrumFftSize.ToString(),
        "--spectrum-windows", $SpectrumWindows.ToString(),
        "--spectrum-max-hz", $SpectrumMaxHz.ToString([Globalization.CultureInfo]::InvariantCulture)
    )
    $analysisOutput = & $python @analysisArgs 2>&1
    $analysisExit = $LASTEXITCODE
    Set-Content -LiteralPath $waveformAnalysisLog -Value (@($analysisOutput | ForEach-Object { $_.ToString() }) -join "`r`n") -Encoding UTF8
    if (Test-Path -LiteralPath $waveformAnalysisJson) {
        $waveformAnalysis = Get-Content -LiteralPath $waveformAnalysisJson -Raw | ConvertFrom-Json
    }
    if ($analysisExit -ne 0 -and $null -eq $waveformAnalysis) {
        throw "Waveform analyzer exited with $analysisExit. See $waveformAnalysisLog"
    }
} catch {
    $waveformAnalysisError = $_.Exception.Message
}

$failures = New-Object System.Collections.Generic.List[string]
if ($recRms -lt 0.002) {
    [void]$failures.Add("Recorded audio RMS is near silence: $([Math]::Round($recRms, 6)).")
}
if ($recPulses.Count -lt $MinDetectedPulses) {
    [void]$failures.Add("Detected only $($recPulses.Count) reference pulses, expected at least $MinDetectedPulses.")
}
if ([double]$clip.clipped_pct -gt $MaxClippedPct) {
    [void]$failures.Add("Clipped sample pct $($clip.clipped_pct), expected <= $MaxClippedPct.")
}
if ($alignment) {
    if ([double]$alignment.dropout_window_pct -gt $MaxDropoutWindowPct) {
        [void]$failures.Add("Dropout window pct $($alignment.dropout_window_pct), expected <= $MaxDropoutWindowPct.")
    }
    if ($RequireWaveformMatch -and [double]$alignment.correlation -lt $MinCorrelation) {
        [void]$failures.Add("Correlation $($alignment.correlation), expected >= $MinCorrelation.")
    }
    if ($RequireWaveformMatch -and [double]$alignment.snr_db -lt $MinSnrDb) {
        [void]$failures.Add("SNR $($alignment.snr_db) dB, expected >= $MinSnrDb dB.")
    }
}
if ($pulseTiming -and [double]$pulseTiming.max_abs_interval_error_ms -gt $MaxPulseIntervalErrorMs) {
    [void]$failures.Add("Pulse interval max error $($pulseTiming.max_abs_interval_error_ms) ms, expected <= $MaxPulseIntervalErrorMs ms.")
}
if ($waveformAnalysisError) {
    [void]$failures.Add("Waveform crackle/pop analysis failed: $waveformAnalysisError")
} elseif ($waveformAnalysis -and -not [bool]$waveformAnalysis.pass) {
    foreach ($failure in @($waveformAnalysis.failures)) {
        [void]$failures.Add("Crackle/pop analysis: $failure")
    }
}

$summary = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    pass = ($failures.Count -eq 0)
    failures = @($failures)
    output_dir = $runDir
    reference_wav = $referenceWav
    recorded_wav = $recordedWav
    gst_log = $gstLog
    waveform_analysis_path = $waveformAnalysisJson
    waveform_analysis_log = $waveformAnalysisLog
    guest_trigger = $GuestTrigger
    duration_sec = $DurationSec
    sample_rate = $SampleRate
    reference = [ordered]@{
        duration_sec = [Math]::Round($ref.DurationSec, 3)
        pulses = @($refPulses | ForEach-Object { [Math]::Round($_, 4) })
    }
    recorded = [ordered]@{
        duration_sec = [Math]::Round($rec.DurationSec, 3)
        rms = [Math]::Round($recRms, 6)
        pulses = @($recPulses | ForEach-Object { [Math]::Round($_, 4) })
        clip = $clip
    }
    alignment = $alignment
    pulse_timing = $pulseTiming
    waveform_analysis = $waveformAnalysis
    waveform_analysis_error = $waveformAnalysisError
    thresholds = [ordered]@{
        min_detected_pulses = $MinDetectedPulses
        max_clipped_pct = $MaxClippedPct
        max_dropout_window_pct = $MaxDropoutWindowPct
        min_correlation = $MinCorrelation
        min_snr_db = $MinSnrDb
        max_pulse_interval_error_ms = $MaxPulseIntervalErrorMs
        max_pop_events = $MaxPopEvents
        max_severe_pop_events = $MaxSeverePopEvents
        pop_threshold_mad = $PopThresholdMad
        min_pop_delta = $MinPopDelta
        severe_pop_score = $SeverePopScore
        periodic_pop_confidence_threshold = $PeriodicPopConfidenceThreshold
        spectrum_fft_size = $SpectrumFftSize
        spectrum_windows = $SpectrumWindows
        spectrum_max_hz = $SpectrumMaxHz
        require_waveform_match = [bool]$RequireWaveformMatch
    }
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryJson -Encoding UTF8

$report = @(
    "# GVT 音频质量报告",
    "",
    "- 结果: $($summary.pass)",
    "- 输出目录: $runDir",
    "- 录制 RMS: $([Math]::Round($recRms, 6))",
    "- 识别到的参考脉冲数: $($recPulses.Count)",
    "- 削波样本比例: $($clip.clipped_pct)%",
    "- 相关系数（参考）: $(if ($alignment) { $alignment.correlation } else { 'NA' })",
    "- SNR（参考）: $(if ($alignment) { $alignment.snr_db } else { 'NA' }) dB",
    "- dropout 窗口比例: $(if ($alignment) { $alignment.dropout_window_pct } else { 'NA' })%",
    "- 脉冲间隔最大误差: $(if ($pulseTiming) { $pulseTiming.max_abs_interval_error_ms } else { 'NA' }) ms",
    "- 爆音/微小爆音分析: $(if ($waveformAnalysis) { $waveformAnalysis.pass } else { 'NA' })",
    "- 爆音候选数量: $(if ($waveformAnalysis) { $waveformAnalysis.pop_detection.event_count } else { 'NA' })",
    "- 严重爆音候选数量: $(if ($waveformAnalysis) { $waveformAnalysis.pop_detection.severe_event_count } else { 'NA' })",
    "- 周期性爆音: $(if ($waveformAnalysis) { $waveformAnalysis.pop_detection.periodic.detected } else { 'NA' })",
    "- 周期性爆音置信度: $(if ($waveformAnalysis) { $waveformAnalysis.pop_detection.periodic.confidence } else { 'NA' })",
    "- 频域差异 RMS: $(if ($waveformAnalysis -and $waveformAnalysis.spectrum) { $waveformAnalysis.spectrum.delta_rms_db } else { 'NA' }) dB",
    "- 输入/输出波形图: $(if ($waveformAnalysis) { $waveformAnalysis.plots.waveform_overview_svg } else { 'NA' })",
    "- 爆音评分图: $(if ($waveformAnalysis) { $waveformAnalysis.plots.pop_score_svg } else { 'NA' })",
    "- 频域对比图: $(if ($waveformAnalysis -and $waveformAnalysis.plots.spectrum_comparison_svg) { $waveformAnalysis.plots.spectrum_comparison_svg } else { 'NA' })",
    "",
    "## 失败原因",
    ""
)
if ($failures.Count -eq 0) {
    $report += "- None"
} else {
    foreach ($failure in $failures) {
        $report += "- $failure"
    }
}
$report | Set-Content -LiteralPath $reportMd -Encoding UTF8

if ($failures.Count -gt 0) {
    Write-Host "GVT audio quality: FAIL"
    foreach ($failure in $failures) {
        Write-Host "  - $failure"
    }
    Write-Host "  Summary: $summaryJson"
    exit 1
}

Write-Host "GVT audio quality: PASS"
Write-Host "  Summary: $summaryJson"
Write-Host "  Correlation=$($alignment.correlation) SNR=$($alignment.snr_db)dB clipped=$($clip.clipped_pct)% dropouts=$($alignment.dropout_window_pct)%"
if ($waveformAnalysis) {
    Write-Host "  PopCandidates=$($waveformAnalysis.pop_detection.event_count) Severe=$($waveformAnalysis.pop_detection.severe_event_count) Periodic=$($waveformAnalysis.pop_detection.periodic.detected) Confidence=$($waveformAnalysis.pop_detection.periodic.confidence)"
}
