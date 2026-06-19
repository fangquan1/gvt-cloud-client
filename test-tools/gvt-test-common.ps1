Set-StrictMode -Version 2.0

$script:GvtTestToolsRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$script:GvtClientRoot = Split-Path -Parent $script:GvtTestToolsRoot

function Resolve-GvtClientRoot {
    return $script:GvtClientRoot
}

function Resolve-GvtFirstExistingPath {
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

function Resolve-GvtGstreamerRoot {
    param([string]$Requested = "")

    $candidates = @()
    if (-not [string]::IsNullOrWhiteSpace($Requested)) {
        $candidates += $Requested
    }
    $candidates += (Join-Path $script:GvtClientRoot "tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64")
    if (-not [string]::IsNullOrWhiteSpace($env:GVT_GSTREAMER_ROOT)) {
        $candidates += $env:GVT_GSTREAMER_ROOT
        $candidates += (Join-Path $env:GVT_GSTREAMER_ROOT "gstreamer\1.0\mingw_x86_64")
    }
    $candidates += "C:\job\gvtg-test\tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64"

    return Resolve-GvtFirstExistingPath -Candidates $candidates -Kind "GStreamer root"
}

function Resolve-GvtGstExe {
    param(
        [string]$Name,
        [string]$GstRoot = ""
    )

    $root = Resolve-GvtGstreamerRoot -Requested $GstRoot
    return Resolve-GvtFirstExistingPath -Candidates @((Join-Path $root "bin\$Name")) -Kind $Name
}

function ConvertTo-GvtRemoteSingleQuoted {
    param([string]$Value)

    if ($Value -match "'") {
        throw "Remote shell values with single quotes are not supported: $Value"
    }
    return "'" + $Value + "'"
}

function ConvertTo-GvtBase64Utf8 {
    param([string]$Text)

    return [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Text))
}

function ConvertFrom-GvtBase64Utf8 {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return ""
    }
    return [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Text))
}

function ConvertFrom-GvtJsonLine {
    param(
        [string[]]$Lines,
        [string]$Context = "JSON"
    )

    $candidates = @($Lines | ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_.StartsWith("{") -or $_.StartsWith("[") })
    for ($i = $candidates.Count - 1; $i -ge 0; $i--) {
        try {
            return ($candidates[$i] | ConvertFrom-Json)
        } catch {
        }
    }

    $joined = ($Lines -join " ")
    throw "$Context did not contain a parseable JSON response. Output: $joined"
}

function Invoke-GvtQgaCommand {
    param(
        [Parameter(Mandatory = $true)][hashtable]$Command,
        [string]$ServerSsh = "root@192.168.0.188",
        [string]$QgaSock = "/root/qemu_cmd/win10-gvt-stream-qga.sock",
        [int]$TimeoutSec = 8,
        [switch]$BatchMode,
        [switch]$AllowError
    )

    if ([string]::IsNullOrWhiteSpace($ServerSsh)) {
        throw "ServerSsh is empty."
    }

    $ssh = (Get-Command ssh.exe -ErrorAction Stop).Source
    $json = $Command | ConvertTo-Json -Depth 12 -Compress
    $payloadB64 = ConvertTo-GvtBase64Utf8 $json
    $remote = "python3 - " +
        (ConvertTo-GvtRemoteSingleQuoted $QgaSock) + " " +
        (ConvertTo-GvtRemoteSingleQuoted $payloadB64) + " " +
        $TimeoutSec.ToString()

    $python = @'
import base64
import socket
import sys

sock_path = sys.argv[1]
payload = base64.b64decode(sys.argv[2])
timeout = float(sys.argv[3])

s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
s.settimeout(timeout)
s.connect(sock_path)
s.sendall(payload + b"\n")

buf = b""
while True:
    try:
        part = s.recv(65536)
    except socket.timeout:
        break
    if not part:
        break
    buf += part
    if b"\n" in buf:
        break

s.close()
text = buf.decode("utf-8", "replace").strip()
if text.startswith("\xff"):
    text = text[1:]
print(text)
'@

    $sshArgs = @("-o", "ConnectTimeout=5")
    if ($BatchMode) {
        $sshArgs += @("-o", "BatchMode=yes")
    }
    $sshArgs += @($ServerSsh, $remote)

    $oldErrorActionPreference = $ErrorActionPreference
    $ErrorActionPreference = "Continue"
    try {
        $output = $python | & $ssh @sshArgs 2>&1
    }
    finally {
        $ErrorActionPreference = $oldErrorActionPreference
    }

    $lines = @($output | ForEach-Object { $_.ToString() } | Where-Object { $_ })
    if ($LASTEXITCODE -ne 0) {
        throw "ssh/QGA command failed with exit code $LASTEXITCODE. Output: $($lines -join ' ')"
    }
    if ($lines.Count -eq 0) {
        throw "QGA command returned no response."
    }

    $response = ConvertFrom-GvtJsonLine -Lines $lines -Context "QGA command"
    if ($response.PSObject.Properties.Name -contains "error") {
        if (-not $AllowError) {
            throw "QGA error: $($response.error.desc)"
        }
    }
    return $response
}

function Invoke-GvtQgaGuestExec {
    param(
        [string]$Path,
        [string[]]$ArgumentList = @(),
        [string]$ServerSsh = "root@192.168.0.188",
        [string]$QgaSock = "/root/qemu_cmd/win10-gvt-stream-qga.sock",
        [int]$TimeoutSec = 30,
        [switch]$BatchMode,
        [switch]$NoCapture
    )

    $argsObj = @{
        path = $Path
        arg = $ArgumentList
    }
    if (-not $NoCapture) {
        $argsObj["capture-output"] = $true
    }

    $start = Invoke-GvtQgaCommand `
        -Command @{ execute = "guest-exec"; arguments = $argsObj } `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -TimeoutSec $TimeoutSec `
        -BatchMode:$BatchMode

    $guestPid = [int]$start.return.pid
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Start-Sleep -Milliseconds 300
        $status = Invoke-GvtQgaCommand `
            -Command @{ execute = "guest-exec-status"; arguments = @{ pid = $guestPid } } `
            -ServerSsh $ServerSsh `
            -QgaSock $QgaSock `
            -TimeoutSec $TimeoutSec `
            -BatchMode:$BatchMode
        if ([bool]$status.return.exited) {
            $stdout = ""
            $stderr = ""
            if ($status.return.PSObject.Properties.Name -contains "out-data") {
                $stdout = ConvertFrom-GvtBase64Utf8 $status.return."out-data"
            }
            if ($status.return.PSObject.Properties.Name -contains "err-data") {
                $stderr = ConvertFrom-GvtBase64Utf8 $status.return."err-data"
            }
            return [pscustomobject]@{
                Pid = $guestPid
                Exited = $true
                ExitCode = if ($status.return.PSObject.Properties.Name -contains "exitcode") { [int]$status.return.exitcode } else { $null }
                Stdout = $stdout
                Stderr = $stderr
                Raw = $status.return
            }
        }
    } while ((Get-Date) -lt $deadline)

    throw "guest-exec pid $guestPid did not exit within $TimeoutSec seconds."
}

function Write-GvtQgaFile {
    param(
        [Parameter(Mandatory = $true)][string]$GuestPath,
        [byte[]]$Bytes,
        [string]$Text,
        [string]$ServerSsh = "root@192.168.0.188",
        [string]$QgaSock = "/root/qemu_cmd/win10-gvt-stream-qga.sock",
        [int]$ChunkBytes = 24576,
        [switch]$BatchMode
    )

    if ($null -eq $Bytes) {
        if ($null -eq $Text) {
            throw "Write-GvtQgaFile requires Bytes or Text."
        }
        $Bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    }

    $open = Invoke-GvtQgaCommand `
        -Command @{ execute = "guest-file-open"; arguments = @{ path = $GuestPath; mode = "w" } } `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -BatchMode:$BatchMode
    $handle = [int]$open.return

    try {
        for ($offset = 0; $offset -lt $Bytes.Length; $offset += $ChunkBytes) {
            $count = [Math]::Min($ChunkBytes, $Bytes.Length - $offset)
            $chunk = New-Object byte[] $count
            [Array]::Copy($Bytes, $offset, $chunk, 0, $count)
            $chunkB64 = [Convert]::ToBase64String($chunk)
            [void](Invoke-GvtQgaCommand `
                -Command @{ execute = "guest-file-write"; arguments = @{ handle = $handle; "buf-b64" = $chunkB64; count = $count } } `
                -ServerSsh $ServerSsh `
                -QgaSock $QgaSock `
                -BatchMode:$BatchMode)
        }
        [void](Invoke-GvtQgaCommand `
            -Command @{ execute = "guest-file-flush"; arguments = @{ handle = $handle } } `
            -ServerSsh $ServerSsh `
            -QgaSock $QgaSock `
            -BatchMode:$BatchMode)
    }
    finally {
        [void](Invoke-GvtQgaCommand `
            -Command @{ execute = "guest-file-close"; arguments = @{ handle = $handle } } `
            -ServerSsh $ServerSsh `
            -QgaSock $QgaSock `
            -BatchMode:$BatchMode `
            -AllowError)
    }
}

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
    $bitsPerSample = 16
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
        $writer.Write([int16]$bitsPerSample)
        $writer.Write([Text.Encoding]::ASCII.GetBytes("data"))
        $writer.Write([int]$dataSize)

        $twoPi = 2.0 * [Math]::PI
        for ($i = 0; $i -lt $totalFrames; $i++) {
            $t = [double]$i / [double]$SampleRate
            $sample =
                0.10 * [Math]::Sin($twoPi * 440.0 * $t) +
                0.06 * [Math]::Sin($twoPi * 880.0 * $t) +
                0.04 * [Math]::Sin($twoPi * 1760.0 * $t)

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

function Read-GvtPcm16Wav {
    param([Parameter(Mandatory = $true)][string]$Path)

    $reader = [IO.BinaryReader]::new([IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite))
    try {
        $riff = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        [void]$reader.ReadInt32()
        $wave = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
        if ($riff -ne "RIFF" -or $wave -ne "WAVE") {
            throw "$Path is not a RIFF/WAVE file."
        }

        $formatTag = $null
        $channels = $null
        $sampleRate = $null
        $bitsPerSample = $null
        $data = $null

        while ($reader.BaseStream.Position -lt $reader.BaseStream.Length) {
            $chunkId = [Text.Encoding]::ASCII.GetString($reader.ReadBytes(4))
            $chunkSize = $reader.ReadInt32()
            if ($chunkId -eq "fmt ") {
                $formatTag = $reader.ReadInt16()
                $channels = $reader.ReadInt16()
                $sampleRate = $reader.ReadInt32()
                [void]$reader.ReadInt32()
                [void]$reader.ReadInt16()
                $bitsPerSample = $reader.ReadInt16()
                $remaining = $chunkSize - 16
                if ($remaining -gt 0) {
                    [void]$reader.BaseStream.Seek($remaining, [IO.SeekOrigin]::Current)
                }
            } elseif ($chunkId -eq "data") {
                $data = $reader.ReadBytes($chunkSize)
            } else {
                [void]$reader.BaseStream.Seek($chunkSize, [IO.SeekOrigin]::Current)
            }
            if (($chunkSize % 2) -eq 1) {
                [void]$reader.BaseStream.Seek(1, [IO.SeekOrigin]::Current)
            }
        }
    }
    finally {
        $reader.Dispose()
    }

    if ($formatTag -ne 1 -or $bitsPerSample -ne 16) {
        throw "$Path must be 16-bit PCM WAV. format=$formatTag bits=$bitsPerSample"
    }
    if ($null -eq $data -or $channels -le 0) {
        throw "$Path has no readable PCM data."
    }

    $frames = [int]($data.Length / ([int]$channels * 2))
    $samples = New-Object double[] $frames
    for ($i = 0; $i -lt $frames; $i++) {
        $acc = 0.0
        for ($ch = 0; $ch -lt $channels; $ch++) {
            $byteIndex = ($i * $channels + $ch) * 2
            $value = [BitConverter]::ToInt16($data, $byteIndex)
            $acc += [double]$value / 32768.0
        }
        $samples[$i] = $acc / [double]$channels
    }

    return [pscustomobject]@{
        Path = $Path
        SampleRate = [int]$sampleRate
        Channels = [int]$channels
        Frames = $frames
        DurationSec = [double]$frames / [double]$sampleRate
        Samples = $samples
    }
}

function Get-GvtPulseTimes {
    param(
        [Parameter(Mandatory = $true)][double[]]$Samples,
        [Parameter(Mandatory = $true)][int]$SampleRate,
        [double]$MinGapSec = 1.0
    )

    $window = [Math]::Max(64, [int]($SampleRate * 0.010))
    $hop = [Math]::Max(16, [int]($SampleRate * 0.005))
    $frames = New-Object System.Collections.Generic.List[object]
    $maxRms = 0.0

    for ($i = 0; ($i + $window) -le $Samples.Length; $i += $hop) {
        $sum = 0.0
        for ($j = 0; $j -lt $window; $j++) {
            $v = $Samples[$i + $j]
            $sum += $v * $v
        }
        $rms = [Math]::Sqrt($sum / [double]$window)
        if ($rms -gt $maxRms) {
            $maxRms = $rms
        }
        [void]$frames.Add([pscustomobject]@{ Index = $i; Rms = $rms })
    }

    if ($maxRms -lt 0.005) {
        return @()
    }

    $threshold = [Math]::Max(0.025, $maxRms * 0.42)
    $times = New-Object System.Collections.Generic.List[double]
    $lastTime = -999.0
    $inPulse = $false

    foreach ($frame in $frames) {
        $time = [double]$frame.Index / [double]$SampleRate
        if ($frame.Rms -ge $threshold) {
            if (-not $inPulse -and ($time - $lastTime) -ge $MinGapSec) {
                [void]$times.Add($time)
                $lastTime = $time
            }
            $inPulse = $true
        } else {
            $inPulse = $false
        }
    }

    return $times.ToArray()
}
