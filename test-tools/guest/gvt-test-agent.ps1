param(
    [string]$Root = "C:\ProgramData\GvtCloudTest",
    [switch]$Once,
    [ValidateSet("none", "play-audio-test", "av-sync-test")]
    [string]$Command = "none",
    [int]$DurationSec = 20,
    [int]$SampleRate = 48000
)

$ErrorActionPreference = "Stop"
$script:CurrentPlayer = $null
$script:CurrentPlaybackTimer = $null
$script:MarkerForm = $null
$script:MarkerLabel = $null

function New-GvtReferenceAudioFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$DurationSec = 20,
        [int]$SampleRate = 48000,
        [int]$Channels = 2,
        [double]$PulseStartSec = 0.5,
        [double]$PulseIntervalSec = 2.0
    )

    $dir = Split-Path -Parent $Path
    if (-not [string]::IsNullOrWhiteSpace($dir)) {
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
    }

    $totalFrames = [int]($DurationSec * $SampleRate)
    $bytesPerSample = 2
    $blockAlign = $Channels * $bytesPerSample
    $dataSize = $totalFrames * $blockAlign
    $writer = [IO.BinaryWriter]::new([IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read))
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes("RIFF"))
        $writer.Write([int](36 + $dataSize))
        $writer.Write([Text.Encoding]::ASCII.GetBytes("WAVE"))
        $writer.Write([Text.Encoding]::ASCII.GetBytes("fmt "))
        $writer.Write([int]16)
        $writer.Write([int16]1)
        $writer.Write([int16]$Channels)
        $writer.Write([int]$SampleRate)
        $writer.Write([int]($SampleRate * $blockAlign))
        $writer.Write([int16]$blockAlign)
        $writer.Write([int16]16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes("data"))
        $writer.Write([int]$dataSize)

        $twoPi = 2.0 * [Math]::PI
        for ($i = 0; $i -lt $totalFrames; $i++) {
            $t = [double]$i / [double]$SampleRate
            $sample =
                0.10 * [Math]::Sin($twoPi * 440.0 * $t) +
                0.03 * [Math]::Sin($twoPi * 660.0 * $t)

            $pulseIndex = [Math]::Round(($t - $PulseStartSec) / $PulseIntervalSec)
            $pulseCenter = $PulseStartSec + $pulseIndex * $PulseIntervalSec
            $pulseDt = $t - $pulseCenter
            if ($pulseIndex -ge 0 -and $pulseCenter -lt $DurationSec -and [Math]::Abs($pulseDt) -lt 0.035) {
                $phase = ($pulseDt + 0.035) / 0.070
                $env = [Math]::Sin([Math]::PI * $phase)
                $sample += 0.58 * $env * [Math]::Sin($twoPi * 1000.0 * $pulseDt)
            }

            if ($sample -gt 0.90) { $sample = 0.90 }
            if ($sample -lt -0.90) { $sample = -0.90 }
            $pcm = [int16][Math]::Round($sample * 32767.0)
            for ($ch = 0; $ch -lt $Channels; $ch++) {
                $writer.Write($pcm)
            }
        }
    }
    finally {
        $writer.Dispose()
    }
}

function New-GvtClickFile {
    param(
        [Parameter(Mandatory = $true)][string]$Path,
        [int]$SampleRate = 48000
    )

    $channels = 2
    $durationSec = 0.12
    $totalFrames = [int]($durationSec * $SampleRate)
    $bytesPerSample = 2
    $blockAlign = $channels * $bytesPerSample
    $dataSize = $totalFrames * $blockAlign
    $writer = [IO.BinaryWriter]::new([IO.File]::Open($Path, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::Read))
    try {
        $writer.Write([Text.Encoding]::ASCII.GetBytes("RIFF"))
        $writer.Write([int](36 + $dataSize))
        $writer.Write([Text.Encoding]::ASCII.GetBytes("WAVE"))
        $writer.Write([Text.Encoding]::ASCII.GetBytes("fmt "))
        $writer.Write([int]16)
        $writer.Write([int16]1)
        $writer.Write([int16]$channels)
        $writer.Write([int]$SampleRate)
        $writer.Write([int]($SampleRate * $blockAlign))
        $writer.Write([int16]$blockAlign)
        $writer.Write([int16]16)
        $writer.Write([Text.Encoding]::ASCII.GetBytes("data"))
        $writer.Write([int]$dataSize)

        $twoPi = 2.0 * [Math]::PI
        for ($i = 0; $i -lt $totalFrames; $i++) {
            $t = [double]$i / [double]$SampleRate
            $sample = 0.0
            if ($t -lt 0.050) {
                $env = [Math]::Sin([Math]::PI * ($t / 0.050))
                $sample = 0.82 * $env * [Math]::Sin($twoPi * 1000.0 * $t)
            }
            $pcm = [int16][Math]::Round($sample * 32767.0)
            for ($ch = 0; $ch -lt $channels; $ch++) {
                $writer.Write($pcm)
            }
        }
    }
    finally {
        $writer.Dispose()
    }
}

function Write-GvtStatus {
    param([hashtable]$Status)

    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $statusPath = Join-Path $Root "status.json"
    $Status.generated_at = (Get-Date).ToString("o")
    $Status | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $statusPath -Encoding UTF8
}

function Set-GvtMarkerText {
    param(
        [string]$Text,
        [string]$BackColor = "LimeGreen",
        [string]$ForeColor = "Black"
    )

    if ($script:MarkerForm -and $script:MarkerLabel) {
        $script:MarkerForm.BackColor = [System.Drawing.Color]::FromName($BackColor)
        $script:MarkerLabel.BackColor = [System.Drawing.Color]::FromName($BackColor)
        $script:MarkerLabel.ForeColor = [System.Drawing.Color]::FromName($ForeColor)
        $script:MarkerLabel.Text = $Text
        $script:MarkerForm.Refresh()
    }
}

function Stop-GvtCurrentPlayer {
    if ($script:CurrentPlaybackTimer) {
        try {
            $script:CurrentPlaybackTimer.Stop()
        } catch {
        }
        try {
            $script:CurrentPlaybackTimer.Dispose()
        } catch {
        }
        $script:CurrentPlaybackTimer = $null
    }
    if ($script:CurrentPlayer) {
        try {
            $script:CurrentPlayer.Stop()
        } catch {
        }
        try {
            $script:CurrentPlayer.Dispose()
        } catch {
        }
        $script:CurrentPlayer = $null
    }
}

function Complete-GvtAudioPlayback {
    Stop-GvtCurrentPlayer
    Write-GvtStatus @{
        state = "idle"
        last_command = "play-audio-test"
    }
    Set-GvtMarkerText -Text "GVT_READY"
}

function Invoke-GvtPlayAudioTest {
    param(
        [int]$DurationSec = 20,
        [int]$SampleRate = 48000,
        [switch]$Sync
    )

    Stop-GvtCurrentPlayer
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $wav = Join-Path $Root "audio-reference.wav"
    Set-GvtMarkerText -Text "GVT_AUDIO"
    New-GvtReferenceAudioFile -Path $wav -DurationSec $DurationSec -SampleRate $SampleRate -Channels 2

    $player = [System.Media.SoundPlayer]::new($wav)
    $player.Load()
    $script:CurrentPlayer = $player

    Write-GvtStatus @{
        state = "playing-audio-test"
        wav = $wav
        duration_sec = $DurationSec
        sample_rate = $SampleRate
    }

    if ($Sync) {
        $player.PlaySync()
        Complete-GvtAudioPlayback
    } else {
        $timer = [System.Windows.Forms.Timer]::new()
        $timer.Interval = [int]([Math]::Max(1, $DurationSec) * 1000)
        $timer.Add_Tick({
            Complete-GvtAudioPlayback
        })
        $script:CurrentPlaybackTimer = $timer
        $player.Play()
        $timer.Start()
    }
}

function Invoke-GvtAvSyncTest {
    param(
        [int]$DurationSec = 20,
        [int]$SampleRate = 48000
    )

    Stop-GvtCurrentPlayer
    New-Item -ItemType Directory -Force -Path $Root | Out-Null
    $click = Join-Path $Root "av-click.wav"
    New-GvtClickFile -Path $click -SampleRate $SampleRate
    $player = [System.Media.SoundPlayer]::new($click)
    $player.Load()
    $script:CurrentPlayer = $player

    Write-GvtStatus @{
        state = "running-av-sync-test"
        duration_sec = $DurationSec
        sample_rate = $SampleRate
    }

    $stopAt = (Get-Date).AddSeconds($DurationSec)
    while ((Get-Date) -lt $stopAt) {
        Set-GvtMarkerText -Text "GVT_FLASH" -BackColor "White" -ForeColor "Black"
        $player.Play()
        Start-Sleep -Milliseconds 90
        Set-GvtMarkerText -Text "GVT_READY" -BackColor "LimeGreen" -ForeColor "Black"
        Start-Sleep -Milliseconds 1910
    }

    Write-GvtStatus @{
        state = "idle"
        last_command = "av-sync-test"
    }
    Stop-GvtCurrentPlayer
}

function Invoke-GvtCommandObject {
    param([object]$CommandObject)

    $cmd = [string]$CommandObject.command
    $dur = $DurationSec
    $rate = $SampleRate
    if ($CommandObject.PSObject.Properties.Name -contains "duration_sec") {
        $dur = [int]$CommandObject.duration_sec
    }
    if ($CommandObject.PSObject.Properties.Name -contains "sample_rate") {
        $rate = [int]$CommandObject.sample_rate
    }

    if ($cmd -eq "play-audio-test") {
        Invoke-GvtPlayAudioTest -DurationSec $dur -SampleRate $rate
    } elseif ($cmd -eq "av-sync-test") {
        Invoke-GvtAvSyncTest -DurationSec $dur -SampleRate $rate
    } elseif ($cmd -eq "stop") {
        Stop-GvtCurrentPlayer
        [System.Windows.Forms.Application]::Exit()
    } else {
        Write-GvtStatus @{
            state = "idle"
            error = "unknown command: $cmd"
        }
    }
}

New-Item -ItemType Directory -Force -Path $Root | Out-Null

if ($Once) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    if ($Command -eq "play-audio-test") {
        Invoke-GvtPlayAudioTest -DurationSec $DurationSec -SampleRate $SampleRate
        Start-Sleep -Seconds ([Math]::Max(1, $DurationSec))
        Complete-GvtAudioPlayback
    } elseif ($Command -eq "av-sync-test") {
        Invoke-GvtAvSyncTest -DurationSec $DurationSec -SampleRate $SampleRate
    }
    exit 0
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$form = [System.Windows.Forms.Form]::new()
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::None
$form.StartPosition = [System.Windows.Forms.FormStartPosition]::Manual
$form.TopMost = $true
$form.ShowInTaskbar = $false
$form.Width = 220
$form.Height = 58
$form.Left = 28
$form.Top = 28
$form.BackColor = [System.Drawing.Color]::LimeGreen

$label = [System.Windows.Forms.Label]::new()
$label.Dock = [System.Windows.Forms.DockStyle]::Fill
$label.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$label.Font = [System.Drawing.Font]::new("Consolas", 17, [System.Drawing.FontStyle]::Bold)
$label.ForeColor = [System.Drawing.Color]::Black
$label.BackColor = [System.Drawing.Color]::LimeGreen
$label.Text = "GVT_READY"
[void]$form.Controls.Add($label)

$script:MarkerForm = $form
$script:MarkerLabel = $label

Write-GvtStatus @{
    state = "idle"
    marker = "GVT_READY"
    root = $Root
}

$timer = [System.Windows.Forms.Timer]::new()
$timer.Interval = 500
$timer.Add_Tick({
    try {
        $commandPath = Join-Path $Root "command.json"
        if (Test-Path -LiteralPath $commandPath) {
            $raw = Get-Content -LiteralPath $commandPath -Raw
            Remove-Item -LiteralPath $commandPath -Force
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $obj = $raw | ConvertFrom-Json
                Invoke-GvtCommandObject -CommandObject $obj
                Set-GvtMarkerText -Text "GVT_READY"
            }
        }
    }
    catch {
        Write-GvtStatus @{
            state = "idle"
            error = $_.Exception.Message
        }
        Set-GvtMarkerText -Text "GVT_ERROR" -BackColor "Red" -ForeColor "White"
    }
})
$timer.Start()

[System.Windows.Forms.Application]::Run($form)
