<#
.SYNOPSIS
Runs the full GVT Cloud desktop, video, audio, AV-sync, and input-latency test suite.

.DESCRIPTION
This orchestration script installs the guest test helper, optionally reboots
the Windows guest through QGA, waits for the test user's interactive desktop,
starts the viewer smoke test, checks the visual ready marker, then runs audio
quality, AV sync, and input-to-video latency tests in sequence.

Each stage writes timestamped console output and a per-stage log under
test_output\data\full-YYYYMMDD-HHMMSS by default.
#>
param(
    [string]$ServerHost = "192.168.0.188",
    [string]$ServerSsh = "root@192.168.0.188",
    [string]$QgaSock = "/root/qemu_cmd/win10-gvt-stream-qga.sock",
    [int]$VideoPort = 5004,
    [int]$SpicePort = 5900,
    [int]$InputPort = 5905,
    [string]$WindowProcessName = "gvt_spice_viewer",
    [int]$DesktopTimeoutSec = 180,
    [int]$InstallTimeoutSec = 120,
    [int]$RebootCommandTimeoutSec = 20,
    [int]$MarkerTimeoutSec = 60,
    [int]$MarkerStageTimeoutSec = 120,
    [int]$SmokeTimeoutSec = 180,
    [int]$AudioTimeoutSec = 180,
    [int]$AvSyncTimeoutSec = 180,
    [int]$LatencyTimeoutSec = 180,
    [int]$StageHeartbeatSec = 5,
    [int]$GuestDesktopPollSec = 3,
    [int]$SmokeDurationSec = 20,
    [int]$SmokeWarmupSec = 4,
    [int]$LatencyTrials = 3,
    [ValidateSet("win-r", "win-key", "right-click-upper")]
    [string]$LatencyTriggerProfile = "win-r",
    [double]$LatencyGoodMs = 600.0,
    [double]$LatencyPassMs = 1200.0,
    [string]$OutDir = "test_output\data",
    [switch]$SkipInstall,
    [switch]$SkipReboot,
    [switch]$BatchMode
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "gvt-test-common.ps1")

$clientRoot = Resolve-GvtClientRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runRelDir = Join-Path $OutDir "full-$stamp"
$runDir = Join-Path $clientRoot $runRelDir
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$events = New-Object System.Collections.Generic.List[object]
$stageResults = [ordered]@{}
$summaryPath = Join-Path $runDir "summary.json"
$statusPath = Join-Path $runDir "status.json"
$reportZhPath = Join-Path $runDir "report.md"
$reportHtmlPath = Join-Path $runDir "report.html"
$smokeOutDirRel = Join-Path $runRelDir "video-performance"
$audioOutDirRel = Join-Path $runRelDir "audio-quality"
$avOutDirRel = Join-Path $runRelDir "av-sync"
$latencyOutDirRel = Join-Path $runRelDir "latency-captures"

$stageTimeoutPlan = [ordered]@{
    install = $InstallTimeoutSec
    reboot = $RebootCommandTimeoutSec
    "guest-desktop" = $DesktopTimeoutSec
    smoke = $SmokeTimeoutSec
    marker = $MarkerStageTimeoutSec
    audio = $AudioTimeoutSec
    av_sync = $AvSyncTimeoutSec
    latency = $LatencyTimeoutSec
}

$script:currentFullStage = "main"
$script:currentFullStageStartedAt = Get-Date
$script:currentFullStageTimeoutSec = $null
$script:currentFullStageState = "starting"
$script:lastFullStatusMessage = ""
$script:lastFullLogStage = "main"

$expectedGuestUser = ""
$localConfigPath = Join-Path $clientRoot "secrets\gvt-test-guest.ps1"
if (Test-Path -LiteralPath $localConfigPath) {
    . $localConfigPath
    if ($null -ne $GvtGuestTestConfig -and $GvtGuestTestConfig.ContainsKey("GuestUser")) {
        $expectedGuestUser = [string]$GvtGuestTestConfig.GuestUser
    }
}

function Update-FullStatus {
    param(
        [string]$Stage = $script:currentFullStage,
        [string]$Message = "",
        [int]$TimeoutSec = -1,
        [string]$State = "",
        [switch]$StartStage
    )

    try {
        if ($StartStage) {
            $script:currentFullStage = $Stage
            $script:currentFullStageStartedAt = Get-Date
            if ($TimeoutSec -ge 0) {
                $script:currentFullStageTimeoutSec = $TimeoutSec
            } else {
                $script:currentFullStageTimeoutSec = $null
            }
            if ([string]::IsNullOrWhiteSpace($State)) {
                $script:currentFullStageState = "running"
            } else {
                $script:currentFullStageState = $State
            }
        } else {
            if ($TimeoutSec -ge 0) {
                $script:currentFullStageTimeoutSec = $TimeoutSec
            }
            if (-not [string]::IsNullOrWhiteSpace($State)) {
                $script:currentFullStageState = $State
            }
        }

        if (-not [string]::IsNullOrWhiteSpace($Stage)) {
            $script:lastFullLogStage = $Stage
        }
        if (-not [string]::IsNullOrWhiteSpace($Message)) {
            $script:lastFullStatusMessage = $Message
        }

        $now = Get-Date
        $elapsedSec = [Math]::Round(($now - $script:currentFullStageStartedAt).TotalSeconds, 1)
        $status = [ordered]@{
            updated_at = $now.ToString("o")
            run_dir = $runDir
            log_path = (Join-Path $runDir "full.log")
            current_stage = $script:currentFullStage
            current_stage_state = $script:currentFullStageState
            current_stage_started_at = $script:currentFullStageStartedAt.ToString("o")
            current_stage_timeout_sec = $script:currentFullStageTimeoutSec
            current_stage_elapsed_sec = $elapsedSec
            last_log_stage = $script:lastFullLogStage
            last_message = $script:lastFullStatusMessage
            stage_timeouts = $stageTimeoutPlan
            stages = $stageResults
        }
        $status | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $statusPath -Encoding UTF8
    } catch {
        # Status updates are diagnostic only; never let them break the test run.
    }
}

function Write-FullLog {
    param(
        [string]$Message,
        [string]$Stage = "main"
    )

    $line = "[{0}] [{1}] {2}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $Stage, $Message
    try {
        Write-Host $line
    } catch {
    }

    $fullLogPath = Join-Path $runDir "full.log"
    $logged = $false
    for ($i = 0; $i -lt 3 -and -not $logged; $i++) {
        try {
            Add-Content -LiteralPath $fullLogPath -Value $line -Encoding UTF8
            $logged = $true
        } catch {
            Start-Sleep -Milliseconds 150
        }
    }

    try {
        [void]$events.Add([ordered]@{
            time = (Get-Date).ToString("o")
            stage = $Stage
            message = $Message
        })
    } catch {
    }
    Update-FullStatus -Stage $Stage -Message $Message
}

trap {
    $fatalMessage = "fatal error: $($_.Exception.Message)"
    $fatalText = @(
        $fatalMessage,
        "at: $($_.InvocationInfo.PositionMessage)",
        "time: $((Get-Date).ToString("o"))"
    ) -join "`r`n"
    try {
        Set-Content -LiteralPath (Join-Path $runDir "fatal.log") -Value $fatalText -Encoding UTF8
    } catch {
    }
    try {
        Write-FullLog $fatalMessage "fatal"
    } catch {
    }
    try {
        Update-FullStatus -Stage "fatal" -Message $fatalMessage -State "failed" -StartStage
    } catch {
    }
    exit 2
}

function Quote-FullProcessArg {
    param([string]$Value)

    if ($null -eq $Value) {
        return '""'
    }
    if ($Value -notmatch '[\s"]') {
        return $Value
    }
    return '"' + ($Value -replace '"', '\"') + '"'
}

function Stop-FullProcessTree {
    param([int]$ProcessId)

    $children = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ParentProcessId -eq $ProcessId })
    foreach ($child in $children) {
        Stop-FullProcessTree -ProcessId ([int]$child.ProcessId)
    }

    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    } catch {
    }
}

function Invoke-FullScriptStage {
    param(
        [string]$Stage,
        [string]$ScriptPath,
        [string[]]$Arguments = @(),
        [int]$TimeoutSec = 300,
        [bool]$CaptureOutput = $true
    )

    $TimeoutSec = [Math]::Max(1, $TimeoutSec)
    $logPath = Join-Path $runDir "$Stage.log"
    $argList = @("-ExecutionPolicy", "Bypass", "-File", $ScriptPath) + $Arguments
    $argText = ($argList | ForEach-Object { Quote-FullProcessArg $_ }) -join " "

    Update-FullStatus -Stage $Stage -Message "starting stage" -TimeoutSec $TimeoutSec -State "running" -StartStage
    Write-FullLog "start script: $ScriptPath" $Stage
    Write-FullLog "log: $logPath" $Stage
    Write-FullLog "timeout_sec: $TimeoutSec heartbeat_sec: $StageHeartbeatSec" $Stage

    $psi = [Diagnostics.ProcessStartInfo]::new()
    $psi.FileName = "powershell.exe"
    $psi.WorkingDirectory = $clientRoot
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = $CaptureOutput
    $psi.RedirectStandardError = $CaptureOutput
    if ($CaptureOutput) {
        $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
        $psi.StandardOutputEncoding = $utf8NoBom
        $psi.StandardErrorEncoding = $utf8NoBom
    }
    $psi.Arguments = $argText

    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $psi
    $startedAt = Get-Date
    [void]$process.Start()
    Write-FullLog "pid: $($process.Id)" $Stage
    if (-not $CaptureOutput) {
        Write-FullLog "stdout/stderr capture disabled for this stage" $Stage
    }

    $stdoutTask = $null
    $stderrTask = $null
    if ($CaptureOutput) {
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
    }
    $timedOut = $false
    $heartbeatSec = [Math]::Max(1, $StageHeartbeatSec)
    $nextHeartbeatSec = $heartbeatSec
    while (-not $process.HasExited) {
        $elapsedSec = [int][Math]::Floor(((Get-Date) - $startedAt).TotalSeconds)
        if ($elapsedSec -ge $TimeoutSec) {
            $timedOut = $true
            Write-FullLog "timeout reached; stopping process tree pid=$($process.Id)" $Stage
            Stop-FullProcessTree -ProcessId $process.Id
            try {
                $process.WaitForExit(5000) | Out-Null
            } catch {
            }
            break
        }

        if ($elapsedSec -ge $nextHeartbeatSec) {
            Write-FullLog ("running elapsed_sec={0} timeout_sec={1}" -f $elapsedSec, $TimeoutSec) $Stage
            while ($nextHeartbeatSec -le $elapsedSec) {
                $nextHeartbeatSec += $heartbeatSec
            }
        }
        Start-Sleep -Milliseconds 500
    }

    if (-not $timedOut) {
        try {
            $process.WaitForExit() | Out-Null
        } catch {
        }
    }

    $stdout = ""
    $stderr = ""
    if ($CaptureOutput) {
        if ($stdoutTask.Wait(5000)) {
            $stdout = $stdoutTask.Result
        } else {
            $stdout = "[stdout read timed out after child process exit; a descendant may still hold the pipe open]"
            Write-FullLog $stdout $Stage
            try { $process.StandardOutput.Close() } catch {}
        }
        if ($stderrTask.Wait(5000)) {
            $stderr = $stderrTask.Result
        } else {
            $stderr = "[stderr read timed out after child process exit; a descendant may still hold the pipe open]"
            Write-FullLog $stderr $Stage
            try { $process.StandardError.Close() } catch {}
        }
    }
    $exitCode = $null
    try {
        $exitCode = $process.ExitCode
    } catch {
    }
    $finishedAt = Get-Date
    $durationSec = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
    $logText = @(
        "command: powershell.exe $argText",
        "started_at: $($startedAt.ToString("o"))",
        "finished_at: $($finishedAt.ToString("o"))",
        "duration_sec: $durationSec",
        "timeout_sec: $TimeoutSec",
        "capture_output: $CaptureOutput",
        "exit_code: $exitCode",
        "timed_out: $timedOut",
        "",
        "----- stdout -----",
        $stdout,
        "",
        "----- stderr -----",
        $stderr
    ) -join "`r`n"
    Set-Content -LiteralPath $logPath -Value $logText -Encoding UTF8

    if (-not [string]::IsNullOrWhiteSpace($stdout)) {
        foreach ($line in ($stdout -split "`r?`n" | Where-Object { $_ })) {
            Write-FullLog $line $Stage
        }
    }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) {
        foreach ($line in ($stderr -split "`r?`n" | Where-Object { $_ })) {
            Write-FullLog "stderr: $line" $Stage
        }
    }

    $ok = (-not $timedOut) -and ($exitCode -eq 0)
    $stageResults[$Stage] = [ordered]@{
        ok = $ok
        exit_code = $exitCode
        timed_out = $timedOut
        timeout_sec = $TimeoutSec
        duration_sec = $durationSec
        log = $logPath
        started_at = $startedAt.ToString("o")
        finished_at = $finishedAt.ToString("o")
    }
    Write-FullLog "finish ok=$ok exit=$exitCode timed_out=$timedOut duration_sec=$durationSec" $Stage
    $state = if ($ok) { "passed" } else { "failed" }
    Update-FullStatus -Stage $Stage -Message "finish ok=$ok exit=$exitCode timed_out=$timedOut" -State $state
    try {
        $process.Dispose()
    } catch {
    }
    return $ok
}

function Get-FullLatestDirectory {
    param([string]$Path)

    $fullPath = Join-Path $clientRoot $Path
    if (-not (Test-Path -LiteralPath $fullPath)) {
        return $null
    }
    return Get-ChildItem -LiteralPath $fullPath -Directory |
        Sort-Object LastWriteTime -Descending |
        Select-Object -First 1
}

function ConvertFrom-FullJsonText {
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) {
        return $null
    }

    $trimmed = $Text.Trim()
    try {
        return $trimmed | ConvertFrom-Json
    } catch {
        $lines = @($trimmed -split "`r?`n" | Where-Object { $_.Trim().StartsWith("{") -or $_.Trim().StartsWith("[") })
        if ($lines.Count -gt 0) {
            return ($lines[$lines.Count - 1] | ConvertFrom-Json)
        }
        throw
    }
}

function Test-FullHasProcess {
    param(
        [object]$Names,
        [string]$Name
    )

    if ($null -eq $Names) {
        return $false
    }
    if ($Names -is [array]) {
        return @($Names) -contains $Name
    }
    return [string]$Names -eq $Name
}

function Wait-FullGuestDesktop {
    param([int]$TimeoutSec)

    $stage = "guest-desktop"
    $logPath = Join-Path $runDir "$stage.log"
    $startedAt = Get-Date
    $deadline = $startedAt.AddSeconds($TimeoutSec)
    $attempt = 0
    $lastState = $null

    Update-FullStatus -Stage $stage -Message "waiting for guest desktop" -TimeoutSec $TimeoutSec -State "running" -StartStage
    Write-FullLog "waiting for QGA, interactive user, explorer/dwm, and helper session; timeout_sec=$TimeoutSec poll_sec=$GuestDesktopPollSec" $stage

    while ((Get-Date) -lt $deadline) {
        $attempt++
        try {
            [void](Invoke-GvtQgaCommand `
                -Command @{ execute = "guest-ping" } `
                -ServerSsh $ServerSsh `
                -QgaSock $QgaSock `
                -BatchMode:$BatchMode `
                -TimeoutSec 6)

            $guestScript = @'
$agent = @(Get-CimInstance Win32_Process |
    Where-Object { $_.CommandLine -like '*gvt-test-agent.ps1*' } |
    Select-Object ProcessId,SessionId,Name,CommandLine)
$state = [pscustomobject]@{
    user = (Get-CimInstance Win32_ComputerSystem).UserName
    processes = @(Get-Process explorer,dwm -ErrorAction SilentlyContinue | Select-Object -ExpandProperty ProcessName)
    agent = $agent
}
$state | ConvertTo-Json -Compress -Depth 6
'@
            $exec = Invoke-GvtQgaGuestExec `
                -Path "powershell.exe" `
                -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $guestScript) `
                -ServerSsh $ServerSsh `
                -QgaSock $QgaSock `
                -BatchMode:$BatchMode `
                -TimeoutSec 15

            $state = ConvertFrom-FullJsonText $exec.Stdout
            $lastState = $state
            $userOk = -not [string]::IsNullOrWhiteSpace([string]$state.user)
            if (-not [string]::IsNullOrWhiteSpace($expectedGuestUser)) {
                $userOk = ([string]$state.user).EndsWith("\" + $expectedGuestUser)
            }
            $dwmOk = Test-FullHasProcess $state.processes "dwm"
            $explorerOk = Test-FullHasProcess $state.processes "explorer"
            $agentOk = $false
            foreach ($agent in @($state.agent)) {
                if ($null -ne $agent -and [int]$agent.SessionId -gt 0) {
                    $agentOk = $true
                }
            }

            $line = "attempt=$attempt user=$($state.user) user_ok=$userOk explorer=$explorerOk dwm=$dwmOk agent_session=$agentOk"
            Write-FullLog $line $stage
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8

            if ($userOk -and $explorerOk -and $dwmOk -and $agentOk) {
                $stageResults[$stage] = [ordered]@{
                    ok = $true
                    log = $logPath
                    attempts = $attempt
                    state = $state
                    timeout_sec = $TimeoutSec
                    timed_out = $false
                    started_at = $startedAt.ToString("o")
                    finished_at = (Get-Date).ToString("o")
                }
                Update-FullStatus -Stage $stage -Message "guest desktop ready after $attempt attempts" -State "passed"
                return $true
            }
        } catch {
            $line = "attempt=$attempt waiting: $($_.Exception.Message)"
            Write-FullLog $line $stage
            Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
        }

        Start-Sleep -Seconds ([Math]::Max(1, $GuestDesktopPollSec))
    }

    $stageResults[$stage] = [ordered]@{
        ok = $false
        log = $logPath
        attempts = $attempt
        state = $lastState
        timeout_sec = $TimeoutSec
        timed_out = $true
        started_at = $startedAt.ToString("o")
        finished_at = (Get-Date).ToString("o")
    }
    Write-FullLog "timeout waiting for guest desktop after $attempt attempts" $stage
    Update-FullStatus -Stage $stage -Message "timeout waiting for guest desktop after $attempt attempts" -State "failed"
    return $false
}

function Read-FullJsonFile {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    return Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
}

function Get-FullLatencyStats {
    param([string]$CsvPath)

    if (-not (Test-Path -LiteralPath $CsvPath)) {
        return $null
    }
    $rows = @(Import-Csv -LiteralPath $CsvPath)
    $valid = @($rows | Where-Object { [double]$_.LatencyMs -ge 0 } | ForEach-Object { [double]$_.LatencyMs } | Sort-Object)
    $median = $null
    if ($valid.Count -gt 0) {
        $median = $valid[[int][Math]::Floor(($valid.Count - 1) / 2)]
    }
    return [ordered]@{
        csv = $CsvPath
        rows = $rows
        valid_count = $valid.Count
        median_ms = $median
    }
}

function ConvertTo-FullHtmlText {
    param([object]$Value)
    if ($null -eq $Value) {
        return "NA"
    }
    return [System.Net.WebUtility]::HtmlEncode([string]$Value)
}

function ConvertTo-FullReportLink {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    $full = $Path
    if (-not [IO.Path]::IsPathRooted($full)) {
        $full = Join-Path $clientRoot $full
    }
    if ($full.StartsWith($runDir, [StringComparison]::OrdinalIgnoreCase)) {
        $rel = $full.Substring($runDir.Length).TrimStart("\", "/")
        return ($rel -replace "\\", "/")
    }
    return "file:///" + (($full -replace "\\", "/") -replace " ", "%20")
}

function Format-FullStageState {
    param([object]$Value)
    if ($null -eq $Value) {
        return "未运行"
    }
    if ([bool]$Value) {
        return "通过"
    }
    return "失败"
}

function Get-FullNumber {
    param([object]$Value)
    if ($null -eq $Value) {
        return $null
    }
    try {
        return [double]$Value
    } catch {
        return $null
    }
}

function Format-FullNumber {
    param(
        [object]$Value,
        [int]$Digits = 1
    )
    $number = Get-FullNumber $Value
    if ($null -eq $number) {
        return "NA"
    }
    return [Math]::Round($number, $Digits).ToString([Globalization.CultureInfo]::InvariantCulture)
}

function New-FullGrade {
    param(
        [string]$Text,
        [string]$Class
    )
    [pscustomobject]@{ Text = $Text; Class = $Class }
}

function Get-FullHigherBetterGrade {
    param([object]$Value, [double]$Good, [double]$Fair)
    $number = Get-FullNumber $Value
    if ($null -eq $number) { return New-FullGrade "NA" "grade-na" }
    if ($number -ge $Good) { return New-FullGrade "好" "grade-good" }
    if ($number -ge $Fair) { return New-FullGrade "良好" "grade-fair" }
    return New-FullGrade "差" "grade-bad"
}

function Get-FullLowerBetterGrade {
    param([object]$Value, [double]$Good, [double]$Fair)
    $number = Get-FullNumber $Value
    if ($null -eq $number) { return New-FullGrade "NA" "grade-na" }
    if ($number -le $Good) { return New-FullGrade "好" "grade-good" }
    if ($number -le $Fair) { return New-FullGrade "良好" "grade-fair" }
    return New-FullGrade "差" "grade-bad"
}

function Get-FullPopGrade {
    param([object]$Pop)
    if ($null -eq $Pop) {
        return New-FullGrade "NA" "grade-na"
    }
    $events = Get-FullNumber (Get-FullMember -Object $Pop -Name "event_count")
    $severe = Get-FullNumber (Get-FullMember -Object $Pop -Name "severe_event_count")
    $periodic = [bool](Get-FullNestedMember -Object $Pop -Names @("periodic", "detected") -Default $false)
    if ($events -eq 0 -and $severe -eq 0 -and -not $periodic) {
        return New-FullGrade "好" "grade-good"
    }
    if ($severe -eq 0 -and $events -le 5 -and -not $periodic) {
        return New-FullGrade "良好" "grade-fair"
    }
    return New-FullGrade "差" "grade-bad"
}

function Get-FullAvDirectionText {
    param([object]$AudioMinusVideoMs)
    $value = Get-FullNumber $AudioMinusVideoMs
    if ($null -eq $value) {
        return "NA"
    }
    $abs = [Math]::Round([Math]::Abs($value), 1)
    if ($value -lt -1.0) {
        return "声音快于画面 $abs ms"
    }
    if ($value -gt 1.0) {
        return "画面快于声音 $abs ms"
    }
    return "基本同步"
}

function Get-FullLatencyTriggerDescription {
    param([string]$Profile)
    switch ($Profile) {
        "win-r" { return "TCP 原生输入发送 Win+R，观察 Run 对话框区域变化" }
        "win-key" { return "TCP 原生输入发送单 Win 键，观察开始菜单区域变化" }
        "right-click-upper" { return "TCP 原生输入在右上角空白区域右键，观察菜单区域变化" }
        default { return $Profile }
    }
}

function New-FullMetricCard {
    param(
        [string]$Label,
        [string]$Value,
        [string]$Unit,
        [object]$Grade,
        [string]$Help,
        [string]$Detail = ""
    )
    $valueHtml = ConvertTo-FullHtmlText $Value
    $unitHtml = if ([string]::IsNullOrWhiteSpace($Unit)) { "" } else { "<span class=`"unit`">$(ConvertTo-FullHtmlText $Unit)</span>" }
    $helpHtml = if ([string]::IsNullOrWhiteSpace($Help)) { "" } else { "<span class=`"help`" title=`"$(ConvertTo-FullHtmlText $Help)`">?</span>" }
    $detailHtml = if ([string]::IsNullOrWhiteSpace($Detail)) { "" } else { "<div class=`"detail`">$(ConvertTo-FullHtmlText $Detail)</div>" }
    "<div class=`"metric-card $($Grade.Class)`"><div class=`"metric-head`"><span>$(ConvertTo-FullHtmlText $Label)</span>$helpHtml</div><div class=`"metric-value`">$valueHtml$unitHtml</div><div class=`"metric-grade`">$($Grade.Text)</div>$detailHtml</div>"
}

function New-FullMetricRow {
    param(
        [string]$Label,
        [string]$Value,
        [string]$Unit,
        [object]$Grade,
        [string]$Help,
        [string]$Detail
    )
    $unitHtml = if ([string]::IsNullOrWhiteSpace($Unit)) { "" } else { " <span class=`"unit`">$(ConvertTo-FullHtmlText $Unit)</span>" }
    $helpHtml = if ([string]::IsNullOrWhiteSpace($Help)) { "" } else { "<span class=`"help`" title=`"$(ConvertTo-FullHtmlText $Help)`">?</span>" }
    "<tr><th>$(ConvertTo-FullHtmlText $Label) $helpHtml</th><td><strong>$(ConvertTo-FullHtmlText $Value)</strong>$unitHtml</td><td><span class=`"pill $($Grade.Class)`">$($Grade.Text)</span></td><td>$(ConvertTo-FullHtmlText $Detail)</td></tr>"
}

function Test-FullMember {
    param(
        [object]$Object,
        [string]$Name
    )
    if ($null -eq $Object) {
        return $false
    }
    if ($Object -is [System.Collections.IDictionary]) {
        return $Object.Contains($Name)
    }
    return @($Object.PSObject.Properties.Name) -contains $Name
}

function Get-FullMember {
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )
    if (Test-FullMember -Object $Object -Name $Name) {
        if ($Object -is [System.Collections.IDictionary]) {
            return $Object[$Name]
        }
        return $Object.$Name
    }
    return $Default
}

function Get-FullNestedMember {
    param(
        [object]$Object,
        [string[]]$Names,
        [object]$Default = $null
    )

    $current = $Object
    foreach ($name in $Names) {
        if ($null -eq $current) {
            return $Default
        }
        $current = Get-FullMember -Object $current -Name $name -Default $null
    }
    if ($null -eq $current) {
        return $Default
    }
    return $current
}

function Get-FullStageHtmlRows {
    param([object]$Stages)

    $names = @(
        @("install", "安装 guest helper"),
        @("reboot", "guest 重启"),
        @("guest-desktop", "guest 桌面和 helper"),
        @("smoke", "视频 smoke"),
        @("marker", "桌面 marker ready"),
        @("audio", "音频质量/爆音"),
        @("av_sync", "声画同步采集"),
        @("latency", "输入到画面延迟")
    )
    $rows = New-Object System.Collections.Generic.List[string]
    foreach ($item in $names) {
        $key = $item[0]
        $label = $item[1]
        $stage = $Stages.$key
        $ok = Get-FullMember -Object $stage -Name "ok"
        $durationValue = Get-FullMember -Object $stage -Name "duration_sec"
        $timeoutValue = Get-FullMember -Object $stage -Name "timeout_sec"
        $logValue = Get-FullMember -Object $stage -Name "log"
        $duration = if ($null -ne $durationValue) { "$durationValue s" } else { "NA" }
        $timeout = if ($null -ne $timeoutValue) { "$timeoutValue s" } else { "NA" }
        $log = if ($logValue) { ConvertTo-FullReportLink ([string]$logValue) } else { "" }
        $logHtml = if ($log) { "<a href=`"$log`">日志</a>" } else { "NA" }
        $stateClass = if ($ok) { "ok" } elseif ($null -eq $ok) { "muted" } else { "bad" }
        [void]$rows.Add("<tr><td>$label</td><td class=`"$stateClass`">$(Format-FullStageState $ok)</td><td>$duration</td><td>$timeout</td><td>$logHtml</td></tr>")
    }
    return ($rows -join "`n")
}

function Write-FullReports {
    param([object]$Summary)

    $smoke = $Summary.artifacts.smoke_summary
    $audio = $Summary.artifacts.audio_summary
    $wave = Get-FullNestedMember -Object $audio -Names @("waveform_analysis")
    $pop = Get-FullNestedMember -Object $wave -Names @("pop_detection")
    $audioDiag = Get-FullNestedMember -Object $audio -Names @("diagnostics")
    $pcmProbe = Get-FullNestedMember -Object $audioDiag -Names @("spice_pcm_probe")
    $viewerProc = Get-FullNestedMember -Object $audioDiag -Names @("viewer_process")
    $qemuSnapshot = Get-FullNestedMember -Object $audioDiag -Names @("qemu_cmdline")
    $av = $Summary.artifacts.av_sync_summary
    $lat = $Summary.artifacts.latency

    $overall = if ($Summary.overall_ok) { "通过" } else { "失败" }
    $popPass = if ($wave) { Format-FullStageState (Get-FullMember -Object $wave -Name "pass") } else { "NA" }
    $periodicDetected = [bool](Get-FullNestedMember -Object $pop -Names @("periodic", "detected") -Default $false)
    $periodicConfidence = Get-FullNestedMember -Object $pop -Names @("periodic", "confidence") -Default "NA"
    $periodicText = if ($pop) { "$(Format-FullStageState (-not $periodicDetected)) / 置信度 $periodicConfidence" } else { "NA" }
    $overviewSvg = ConvertTo-FullReportLink ([string](Get-FullNestedMember -Object $wave -Names @("plots", "waveform_overview_svg") -Default ""))
    $detailSvg = ConvertTo-FullReportLink ([string](Get-FullNestedMember -Object $wave -Names @("plots", "waveform_detail_svg") -Default ""))
    $scoreSvg = ConvertTo-FullReportLink ([string](Get-FullNestedMember -Object $wave -Names @("plots", "pop_score_svg") -Default ""))
    $spectrumSvg = ConvertTo-FullReportLink ([string](Get-FullNestedMember -Object $wave -Names @("plots", "spectrum_comparison_svg") -Default ""))

    $decodeFps = if ($smoke) { Get-FullNumber $smoke.client.decode_out_fps.avg } else { $null }
    $serverFps = if ($smoke) { Get-FullNumber $smoke.server.fps.avg } else { $null }
    $encodeFailures = if ($smoke) { Get-FullNumber $smoke.server.encode_failures_last } else { $null }
    $clipPct = Get-FullNumber (Get-FullNestedMember -Object $audio -Names @("recorded", "clip", "clipped_pct"))
    $dropoutPct = Get-FullNumber (Get-FullNestedMember -Object $audio -Names @("alignment", "dropout_window_pct"))
    $pulseErrorMs = Get-FullNumber (Get-FullNestedMember -Object $audio -Names @("pulse_timing", "max_abs_interval_error_ms"))
    $pcmEventCount = Get-FullNumber (Get-FullMember -Object $pcmProbe -Name "pcm_event_count")
    $pcmSampleJumps = Get-FullNumber (Get-FullMember -Object $pcmProbe -Name "samplejump_count")
    $pcmFirstSampleJumpMs = Get-FullMember -Object $pcmProbe -Name "first_samplejump_wall_ms" -Default $null
    $viewerSinkLine = Get-FullMember -Object $audioDiag -Name "spice_gst_audiosink_line" -Default "NA"
    $viewerExe = Get-FullMember -Object $viewerProc -Name "executable_path" -Default "NA"
    $viewerHash = Get-FullMember -Object $viewerProc -Name "sha256" -Default "NA"
    $qemuCmdlines = @(Get-FullMember -Object $qemuSnapshot -Name "cmdlines" -Default @())
    $qemuCmdlineText = if ($qemuCmdlines.Count -gt 0) { $qemuCmdlines -join " | " } else { "NA" }
    $spectrumDeltaDb = Get-FullNumber (Get-FullNestedMember -Object $wave -Names @("spectrum", "delta_rms_db"))
    $avNearestPairs = if ($av) { Get-FullMember -Object $av -Name "nearest_pairs" -Default $null } else { $null }
    $avLegacyPairs = if ($av) { Get-FullMember -Object $av -Name "pairs" -Default $null } else { $null }
    $avNearestPairCount = if ($null -ne $avNearestPairs) { @($avNearestPairs).Count } else { 0 }
    $avLegacyPairCount = if ($null -ne $avLegacyPairs) { @($avLegacyPairs).Count } else { 0 }
    $avPairCount = if ($av) { if ($avNearestPairCount -gt 0) { $avNearestPairCount } else { $avLegacyPairCount } } else { $null }
    $avAvgMs = if ($av) { Get-FullNumber (Get-FullMember -Object $av -Name "nearest_average_audio_minus_video_ms_estimated" -Default $null) } else { $null }
    if ($null -eq $avAvgMs -and $av) {
        $avAvgMs = Get-FullNumber (Get-FullMember -Object $av -Name "average_audio_minus_video_ms_estimated" -Default $null)
    }
    $avRelDriftMs = if ($av) { Get-FullNumber (Get-FullMember -Object $av -Name "nearest_max_abs_relative_offset_drift_ms" -Default $null) } else { $null }
    $avGradeBasisMs = if ($null -ne $avRelDriftMs) { $avRelDriftMs } elseif ($null -ne $avAvgMs) { [Math]::Abs($avAvgMs) } else { $null }
    $latMedianMs = if ($lat) { Get-FullNumber $lat.median_ms } else { $null }
    $avDirection = Get-FullAvDirectionText $avAvgMs
    $avDetail = if ($null -ne $avRelDriftMs) {
        "绝对偏移估算：$avDirection；最近事件相对漂移 max $(Format-FullNumber $avRelDriftMs 1) ms。"
    } else {
        $avDirection
    }
    $latencyTriggerDescription = Get-FullLatencyTriggerDescription $LatencyTriggerProfile

    $overallGrade = if ($Summary.overall_ok) { New-FullGrade "好" "grade-good" } else { New-FullGrade "差" "grade-bad" }
    $decodeGrade = Get-FullHigherBetterGrade -Value $decodeFps -Good 55 -Fair 45
    $serverFpsGrade = Get-FullHigherBetterGrade -Value $serverFps -Good 55 -Fair 45
    $encodeGrade = Get-FullLowerBetterGrade -Value $encodeFailures -Good 0 -Fair 3
    $clipGrade = Get-FullLowerBetterGrade -Value $clipPct -Good 0.01 -Fair 0.10
    $dropoutGrade = Get-FullLowerBetterGrade -Value $dropoutPct -Good 0.10 -Fair 2.00
    $pulseGrade = Get-FullLowerBetterGrade -Value $pulseErrorMs -Good 20 -Fair 120
    $popGrade = Get-FullPopGrade $pop
    $pcmSampleJumpGrade = Get-FullLowerBetterGrade -Value $pcmSampleJumps -Good 0 -Fair 5
    $periodicGrade = if ($pop) {
        if ($periodicDetected) { New-FullGrade "差" "grade-bad" } else { New-FullGrade "好" "grade-good" }
    } else {
        New-FullGrade "NA" "grade-na"
    }
    $spectrumGrade = Get-FullLowerBetterGrade -Value $spectrumDeltaDb -Good 6 -Fair 12
    $avGrade = Get-FullLowerBetterGrade -Value $avGradeBasisMs -Good 80 -Fair 150
    $latencyGrade = Get-FullLowerBetterGrade -Value $latMedianMs -Good $LatencyGoodMs -Fair $LatencyPassMs

    $zh = @(
        "# GVT 云桌面全量测试报告",
        "",
        "- 总体结果: $overall",
        "- 输出目录: $runDir",
        "- HTML 报告: $reportHtmlPath",
        "- 生成时间: $($Summary.generated_at)",
        "",
        "## 阶段结果",
        "",
        "- 安装 guest helper: $(Format-FullStageState $Summary.stages.install.ok)",
        "- guest 重启: $(Format-FullStageState $Summary.stages.reboot.ok)",
        "- guest 桌面和 helper: $(Format-FullStageState $Summary.stages.'guest-desktop'.ok)",
        "- 视频 smoke: $(Format-FullStageState $Summary.stages.smoke.ok)",
        "- 桌面 marker ready: $(Format-FullStageState $Summary.stages.marker.ok)",
        "- 音频质量/爆音: $(Format-FullStageState $Summary.stages.audio.ok)",
        "- 声画同步采集: $(Format-FullStageState $Summary.stages.av_sync.ok)",
        "- 输入到画面延迟: $(Format-FullStageState $Summary.stages.latency.ok)",
        "",
        "## 关键指标",
        "",
        "- 视频 client decode avg: $(Format-FullNumber $decodeFps 2) fps（评级: $($decodeGrade.Text)）",
        "- 视频 server fps avg: $(Format-FullNumber $serverFps 2) fps（评级: $($serverFpsGrade.Text)）",
        "- server encode failures: $(Format-FullNumber $encodeFailures 0)（评级: $($encodeGrade.Text)）",
        "- 音频 clipped: $(Format-FullNumber $clipPct 5)%（评级: $($clipGrade.Text)）",
        "- 音频 dropout windows: $(Format-FullNumber $dropoutPct 3)%（评级: $($dropoutGrade.Text)）",
        "- 音频 pulse interval max error: $(Format-FullNumber $pulseErrorMs 2) ms（评级: $($pulseGrade.Text)）",
        "- 爆音/微小爆音分析: $popPass（评级: $($popGrade.Text)）",
        "- 爆音候选数量: $(if ($pop) { $pop.event_count } else { 'NA' })",
        "- 严重爆音候选数量: $(if ($pop) { $pop.severe_event_count } else { 'NA' })",
        "- SPICE PCM samplejump: $(Format-FullNumber $pcmSampleJumps 0) / $(Format-FullNumber $pcmEventCount 0)",
        "- 周期性爆音: $periodicText",
        "- 频域差异 RMS: $(Format-FullNumber $spectrumDeltaDb 2) dB（评级: $($spectrumGrade.Text)）",
        "- AV sync nearest paired events: $(if ($av) { $avNearestPairCount } else { 'NA' })",
        "- AV sync legacy index paired events: $(if ($av) { $avLegacyPairCount } else { 'NA' })",
        "- AV sync audio-minus-video avg: $(Format-FullNumber $avAvgMs 2) ms（$avDirection；绝对偏移估算）",
        "- AV sync relative drift max: $(Format-FullNumber $avRelDriftMs 2) ms（评级: $($avGrade.Text)）",
        "- 输入到画面延迟 median: $(Format-FullNumber $latMedianMs 1) ms（评级: $($latencyGrade.Text)）",
        "- 输入延迟触发方式: $latencyTriggerDescription",
        "- viewer exe: $viewerExe",
        "- viewer sha256: $viewerHash",
        "- SPICE audio sink: $viewerSinkLine",
        "- QEMU cmdline: $qemuCmdlineText",
        "",
        "## 图表",
        "",
        "- 输入/输出全局波形: $(if ($overviewSvg) { $overviewSvg } else { 'NA' })",
        "- 局部细节波形: $(if ($detailSvg) { $detailSvg } else { 'NA' })",
        "- 爆音评分曲线: $(if ($scoreSvg) { $scoreSvg } else { 'NA' })",
        "- 频域对比曲线: $(if ($spectrumSvg) { $spectrumSvg } else { 'NA' })",
        "",
        "## 产物",
        "",
        "- full summary: $summaryPath",
        "- smoke summary: $($Summary.artifacts.smoke_summary_path)",
        "- audio summary: $($Summary.artifacts.audio_summary_path)",
        "- AV sync summary: $($Summary.artifacts.av_sync_summary_path)",
        "- latency csv: $(if ($lat) { $lat.csv } else { 'NA' })"
    )
    $zh | Set-Content -LiteralPath $reportZhPath -Encoding UTF8

    $cardHtml = @(
        (New-FullMetricCard -Label "总体结果" -Value $overall -Unit "" -Grade $overallGrade -Help "全量脚本按阶段退出码和关键数据有效性汇总。" -Detail "失败时优先看下方红色评级项。"),
        (New-FullMetricCard -Label "视频解码 FPS" -Value (Format-FullNumber $decodeFps 2) -Unit "fps" -Grade $decodeGrade -Help "客户端解码输出帧率，越接近 60Hz 越好；>=55 好，>=45 良好。" -Detail "客户端画面流畅度主指标。"),
        (New-FullMetricCard -Label "音频爆音" -Value $(if ($pop) { "$($pop.event_count) / $($pop.severe_event_count)" } else { "NA" }) -Unit "候选/严重" -Grade $popGrade -Help "逐采样扫描短促高频瞬态；0 个候选为好，少量非严重候选为良好。" -Detail "用于判断微小爆音、破音尖峰。"),
        (New-FullMetricCard -Label "频域差异" -Value (Format-FullNumber $spectrumDeltaDb 2) -Unit "dB" -Grade $spectrumGrade -Help "输入参考和录制输出的平均频谱差异 RMS；<=6dB 好，<=12dB 良好。" -Detail "辅助观察高频噪声和音色变化。"),
        (New-FullMetricCard -Label "声画同步" -Value (Format-FullNumber $avGradeBasisMs 1) -Unit "ms" -Grade $avGrade -Help "优先用最近音视频事件的相对漂移评分；audio-minus-video 绝对偏移只作估算。" -Detail $avDetail),
        (New-FullMetricCard -Label "输入延迟" -Value (Format-FullNumber $latMedianMs 1) -Unit "ms" -Grade $latencyGrade -Help "发送输入到画面 ROI 发生变化的中位耗时；Win+R 会包含系统 UI 启动误差，<=$([int]$LatencyGoodMs)ms 好，<=$([int]$LatencyPassMs)ms 良好/通过。" -Detail $latencyTriggerDescription)
    ) -join "`n"

    $stageRows = Get-FullStageHtmlRows -Stages $Summary.stages
    $artifactRows = @(
        @("总 summary", $summaryPath),
        @("状态 JSON", $statusPath),
        @("完整日志", (Join-Path $runDir "full.log")),
        @("视频 summary", $Summary.artifacts.smoke_summary_path),
        @("音频 summary", $Summary.artifacts.audio_summary_path),
        @("音频波形分析 JSON", $(Get-FullMember -Object $audio -Name "waveform_analysis_path" -Default "")),
        @("音频频域 CSV", $(Get-FullNestedMember -Object $wave -Names @("data", "spectrum_csv") -Default "")),
        @("AV sync summary", $Summary.artifacts.av_sync_summary_path),
        @("延迟 CSV", $(if ($lat) { $lat.csv } else { "" }))
    ) | ForEach-Object {
        $link = ConvertTo-FullReportLink ([string]$_[1])
        $pathText = ConvertTo-FullHtmlText $_[1]
        if ($link) {
            "<tr><td>$($_[0])</td><td><a href=`"$link`">$pathText</a></td></tr>"
        } else {
            "<tr><td>$($_[0])</td><td>NA</td></tr>"
        }
    }

    $imgOverview = if ($overviewSvg) { "<figure><img src=`"$overviewSvg`" alt=`"输入输出全局波形`"><figcaption>输入参考波形与客户端录制输出波形的全局包络。</figcaption></figure>" } else { "" }
    $imgDetail = if ($detailSvg) { "<figure><img src=`"$detailSvg`" alt=`"局部细节波形`"><figcaption>局部细节波形，优先显示最强爆音候选点附近。</figcaption></figure>" } else { "" }
    $imgScore = if ($scoreSvg) { "<figure><img src=`"$scoreSvg`" alt=`"爆音评分曲线`"><figcaption>瞬态爆音评分曲线；超过红线的位置会进入候选列表。</figcaption></figure>" } else { "" }
    $imgSpectrum = if ($spectrumSvg) { "<figure><img src=`"$spectrumSvg`" alt=`"频域对比曲线`"><figcaption>输入参考与客户端录制输出的频域对比；异常抬升的高频能量通常对应噪声、破音或爆音残留。</figcaption></figure>" } else { "" }
    $popRows = if ($pop) {
        @(Get-FullMember -Object $pop -Name "events" -Default @() | Select-Object -First 20 | ForEach-Object {
            "<tr><td>$($_.time_sec)</td><td>$($_.duration_ms)</td><td>$($_.peak_delta)</td><td>$($_.score)</td><td>$($_.severe)</td></tr>"
        }) -join "`n"
    } else {
        "<tr><td colspan=`"5`">无爆音分析数据</td></tr>"
    }
    $audioMetricRows = @(
        (New-FullMetricRow -Label "音频 clipped" -Value (Format-FullNumber $clipPct 5) -Unit "%" -Grade $clipGrade -Help "录制样本接近满幅的比例；削波会带来破音，越低越好。" -Detail "0.01% 以内好，0.10% 以内良好。"),
        (New-FullMetricRow -Label "dropout windows" -Value (Format-FullNumber $dropoutPct 3) -Unit "%" -Grade $dropoutGrade -Help "短窗口内接近静音或缺失的比例；越低越好。" -Detail "0.10% 以内好，2.00% 以内良好。"),
        (New-FullMetricRow -Label "pulse interval max error" -Value (Format-FullNumber $pulseErrorMs 2) -Unit "ms" -Grade $pulseGrade -Help "参考脉冲间隔的最大误差，用于判断音频节奏漂移或卡顿。" -Detail "20ms 以内好，120ms 以内良好。"),
        (New-FullMetricRow -Label "爆音候选数量" -Value $(if ($pop) { "$(Get-FullMember -Object $pop -Name "event_count" -Default "NA")" } else { "NA" }) -Unit "" -Grade $popGrade -Help "排除参考脉冲后检测到的短促高频瞬态数量。" -Detail "0 个候选为好；少量非严重候选为良好。"),
        (New-FullMetricRow -Label "严重爆音候选数量" -Value $(if ($pop) { "$(Get-FullMember -Object $pop -Name "severe_event_count" -Default "NA")" } else { "NA" }) -Unit "" -Grade $popGrade -Help "爆音评分超过严重阈值的候选数量。" -Detail "严重候选通常需要优先排查音频缓冲或编码链路。"),
        (New-FullMetricRow -Label "SPICE PCM samplejump" -Value (Format-FullNumber $pcmSampleJumps 0) -Unit "" -Grade $pcmSampleJumpGrade -Help "viewer playback-data 层的 pre-sink PCM 跳变统计；用于区分源侧异常和本机播放/录音异常。" -Detail "PCM probe events=$(Format-FullNumber $pcmEventCount 0)，first wall_ms=$(if ($null -ne $pcmFirstSampleJumpMs) { $pcmFirstSampleJumpMs } else { 'NA' })。"),
        (New-FullMetricRow -Label "SPICE audio sink" -Value $(if ($viewerSinkLine) { "$viewerSinkLine" } else { "NA" }) -Unit "" -Grade (New-FullGrade "诊断" "grade-na") -Help "本轮 viewer 实际写入的 SPICE_GST_AUDIOSINK 管线。" -Detail "用于确认 do-timestamp、queue、buffer 和 latency。"),
        (New-FullMetricRow -Label "QEMU cmdline" -Value $(if ($qemuCmdlineText) { "$qemuCmdlineText" } else { "NA" }) -Unit "" -Grade (New-FullGrade "诊断" "grade-na") -Help "远端当前 qemu-system-x86_64 实际命令行快照。" -Detail "重点核对 -audiodev spice timer-period/out.buffer-length 以及 HDA 设备。"),
        (New-FullMetricRow -Label "周期性爆音" -Value $(if ($pop) { if ($periodicDetected) { "检测到" } else { "未检测到" } } else { "NA" }) -Unit "" -Grade $periodicGrade -Help "候选爆音间隔是否呈稳定周期；周期性通常说明缓冲周期或调度周期问题。" -Detail "置信度 $periodicConfidence。"),
        (New-FullMetricRow -Label "频域差异 RMS" -Value (Format-FullNumber $spectrumDeltaDb 2) -Unit "dB" -Grade $spectrumGrade -Help "输入参考和录制输出频谱的平均差异；主要用于辅助观察高频噪声和音色变化。" -Detail "当前不作为硬失败条件。")
    ) -join "`n"
    $videoMetricRows = @(
        (New-FullMetricRow -Label "客户端 decode FPS" -Value (Format-FullNumber $decodeFps 2) -Unit "fps" -Grade $decodeGrade -Help "客户端实际解码输出帧率；目标 60Hz。" -Detail ">=55 好，>=45 良好。"),
        (New-FullMetricRow -Label "服务端 FPS" -Value (Format-FullNumber $serverFps 2) -Unit "fps" -Grade $serverFpsGrade -Help "服务端采集/编码侧平均帧率；目标接近客户端刷新目标。" -Detail ">=55 好，>=45 良好。"),
        (New-FullMetricRow -Label "服务端 encode failures" -Value (Format-FullNumber $encodeFailures 0) -Unit "" -Grade $encodeGrade -Help "服务端编码失败累计值；0 最好。" -Detail "0 好，<=3 良好。"),
        (New-FullMetricRow -Label "AV sync nearest pairs" -Value $(if ($av) { "$avPairCount" } else { "NA" }) -Unit "" -Grade $avGrade -Help "优先使用最近事件配对；旧的按序号配对在漏检事件时会产生数秒级假偏移。" -Detail "最近配对 $avNearestPairCount；旧序号配对 $avLegacyPairCount。"),
        (New-FullMetricRow -Label "AV sync relative drift max" -Value (Format-FullNumber $avRelDriftMs 2) -Unit "ms" -Grade $avGrade -Help "最近配对后，以中位 audio-minus-video 偏移为基准的最大相对漂移；比绝对偏移更可信。" -Detail $avDetail),
        (New-FullMetricRow -Label "输入到画面延迟 median" -Value (Format-FullNumber $latMedianMs 1) -Unit "ms" -Grade $latencyGrade -Help "发送输入触发后，到画面 ROI 首次明显变化的中位耗时；Win+R profile 的接受线为 <=$([int]$LatencyPassMs)ms。" -Detail $latencyTriggerDescription)
    ) -join "`n"

    $html = @"
<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<title>GVT 云桌面全量测试报告</title>
<style>
body{margin:0;background:#f4f6fa;color:#172033;font-family:"Segoe UI","Microsoft YaHei",Arial,sans-serif}
header{padding:30px 36px;background:#172033;color:#fff;border-bottom:4px solid #2e7d6f}
h1{margin:0 0 8px;font-size:28px;font-weight:720}
h2{margin:28px 0 12px;font-size:20px}
main{max-width:1200px;margin:0 auto;padding:24px 28px 48px}
.meta{color:#d9e2ef;font-size:13px}
.cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:14px}
.metric-card{background:#fff;border:1px solid #d9e2ef;border-left:5px solid #64748b;border-radius:8px;padding:14px 16px;min-height:132px}
.metric-head{display:flex;align-items:center;justify-content:space-between;gap:10px;font-size:13px;color:#536070}
.metric-value{font-size:28px;font-weight:720;margin-top:9px;color:#172033}
.unit{font-size:13px;font-weight:500;color:#697586;margin-left:5px}
.metric-grade{display:inline-flex;align-items:center;margin-top:10px;padding:3px 9px;border-radius:999px;font-size:13px;font-weight:650}
.detail{font-size:12px;color:#64748b;margin-top:8px;line-height:1.5}
.grade-good{border-left-color:#078669}.grade-good .metric-grade,.pill.grade-good{background:#e7f7ef;color:#047857}
.grade-fair{border-left-color:#d38b11}.grade-fair .metric-grade,.pill.grade-fair{background:#fff3d8;color:#9a6200}
.grade-bad{border-left-color:#cf2f2f}.grade-bad .metric-grade,.pill.grade-bad{background:#ffe8e8;color:#b91c1c}
.grade-na{border-left-color:#94a3b8}.grade-na .metric-grade,.pill.grade-na{background:#eef2f7;color:#64748b}
.ok{color:#047857}.bad{color:#b91c1c}.muted{color:#6b7280}
.help{display:inline-flex;align-items:center;justify-content:center;width:18px;height:18px;border-radius:50%;background:#edf2f7;color:#395064;font-size:12px;font-weight:700;cursor:help;flex:0 0 auto}
section{background:#fff;border:1px solid #d9e2ef;border-radius:8px;padding:18px;margin-top:18px}
table{width:100%;border-collapse:collapse;font-size:14px}th,td{border-bottom:1px solid #e5eaf3;padding:10px 8px;text-align:left;vertical-align:top}
th{background:#f8fafc;color:#475569;font-weight:650}
tbody th{width:28%}.pill{display:inline-flex;align-items:center;padding:3px 9px;border-radius:999px;font-weight:650;font-size:13px}
a{color:#1d4ed8;text-decoration:none}a:hover{text-decoration:underline}
figure{margin:16px 0;border:1px solid #e5eaf3;border-radius:8px;padding:10px;background:#fbfdff}
figure img{width:100%;height:auto;display:block}
figcaption{font-size:13px;color:#5b6475;margin-top:8px}
.note{font-size:13px;color:#5b6475;line-height:1.7}
</style>
</head>
<body>
<header>
<h1>GVT 云桌面全量测试报告</h1>
<div class="meta">生成时间：$(ConvertTo-FullHtmlText $Summary.generated_at)　输出目录：$(ConvertTo-FullHtmlText $runDir)</div>
</header>
<main>
<div class="cards">
$cardHtml
</div>
<section>
<h2>阶段结果</h2>
<table><thead><tr><th>阶段</th><th>结果</th><th>耗时</th><th>超时</th><th>日志</th></tr></thead><tbody>
$stageRows
</tbody></table>
</section>
<section>
<h2>音频质量与爆音分析</h2>
<p class="note">录制链路使用 WASAPI loopback，采样率为 $(if ($audio) { $audio.sample_rate } else { 'NA' }) Hz。爆音分析逐采样点扫描录制波形，排除测试参考脉冲和播放首尾过渡段后，查找短促高频瞬态及其周期性。</p>
<table><thead><tr><th>指标</th><th>数值</th><th>评级</th><th>说明</th></tr></thead><tbody>
$audioMetricRows
</tbody></table>
$imgOverview
$imgDetail
$imgScore
$imgSpectrum
<h2>爆音候选明细</h2>
<table><thead><tr><th>时间 s</th><th>持续 ms</th><th>峰值跳变</th><th>评分</th><th>严重</th></tr></thead><tbody>
$popRows
</tbody></table>
</section>
<section>
<h2>视频、声画同步、输入延迟</h2>
<table><thead><tr><th>指标</th><th>数值</th><th>评级</th><th>说明</th></tr></thead><tbody>
$videoMetricRows
</tbody></table>
</section>
<section>
<h2>数据产物</h2>
<table><thead><tr><th>名称</th><th>路径</th></tr></thead><tbody>
$($artifactRows -join "`n")
</tbody></table>
</section>
</main>
</body>
</html>
"@
    Set-Content -LiteralPath $reportHtmlPath -Value $html -Encoding UTF8
}

Update-FullStatus -Stage "main" -Message "starting full test" -State "running" -StartStage
Write-FullLog "full test output: $runDir"
Write-FullLog ("stage timeouts: " + (($stageTimeoutPlan.GetEnumerator() | ForEach-Object { "$($_.Key)=$($_.Value)s" }) -join ", "))
Write-FullLog "status: $statusPath"

if ($SkipInstall) {
    Update-FullStatus -Stage "install" -Message "skip install" -TimeoutSec 0 -State "skipped" -StartStage
    $stageResults["install"] = [ordered]@{ ok = $true; skipped = $true; timeout_sec = 0 }
    Write-FullLog "skip install" "install"
} else {
    [void](Invoke-FullScriptStage `
        -Stage "install" `
        -ScriptPath (Join-Path $PSScriptRoot "install-gvt-guest-test-agent.ps1") `
        -Arguments @("-BatchMode") `
        -TimeoutSec $InstallTimeoutSec)
}

if ($SkipReboot) {
    Update-FullStatus -Stage "reboot" -Message "skip reboot" -TimeoutSec 0 -State "skipped" -StartStage
    $stageResults["reboot"] = [ordered]@{ ok = $true; skipped = $true; timeout_sec = 0 }
    Write-FullLog "skip reboot" "reboot"
} else {
    $stage = "reboot"
    $startedAt = Get-Date
    Update-FullStatus -Stage $stage -Message "sending guest reboot" -TimeoutSec $RebootCommandTimeoutSec -State "running" -StartStage
    Write-FullLog "sending shutdown /r /t 0 /f through QGA; timeout_sec=$RebootCommandTimeoutSec" $stage
    try {
        $rebootResult = Invoke-GvtQgaGuestExec `
            -Path "shutdown.exe" `
            -ArgumentList @("/r", "/t", "0", "/f") `
            -ServerSsh $ServerSsh `
            -QgaSock $QgaSock `
            -BatchMode:$BatchMode `
            -TimeoutSec $RebootCommandTimeoutSec
        $finishedAt = Get-Date
        $stageResults[$stage] = [ordered]@{
            ok = ($rebootResult.ExitCode -eq 0)
            exit_code = $rebootResult.ExitCode
            timeout_sec = $RebootCommandTimeoutSec
            duration_sec = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
            started_at = $startedAt.ToString("o")
            finished_at = $finishedAt.ToString("o")
        }
        Write-FullLog "shutdown exit=$($rebootResult.ExitCode)" $stage
        $state = if ($rebootResult.ExitCode -eq 0) { "passed" } else { "failed" }
        Update-FullStatus -Stage $stage -Message "shutdown exit=$($rebootResult.ExitCode)" -State $state
        Start-Sleep -Seconds 8
    } catch {
        $finishedAt = Get-Date
        $stageResults[$stage] = [ordered]@{
            ok = $false
            error = $_.Exception.Message
            timeout_sec = $RebootCommandTimeoutSec
            duration_sec = [Math]::Round(($finishedAt - $startedAt).TotalSeconds, 3)
            started_at = $startedAt.ToString("o")
            finished_at = $finishedAt.ToString("o")
        }
        Write-FullLog "failed: $($_.Exception.Message)" $stage
        Update-FullStatus -Stage $stage -Message "failed: $($_.Exception.Message)" -State "failed"
    }
}

[void](Wait-FullGuestDesktop -TimeoutSec $DesktopTimeoutSec)

[void](Invoke-FullScriptStage `
    -Stage "smoke" `
    -ScriptPath (Join-Path $PSScriptRoot "run-gvt-stream-smoke.ps1") `
    -Arguments @(
        "-ServerHost", $ServerHost,
        "-VideoPort", $VideoPort.ToString(),
        "-SpicePort", $SpicePort.ToString(),
        "-InputPort", $InputPort.ToString(),
        "-DurationSec", $SmokeDurationSec.ToString(),
        "-WarmupSec", $SmokeWarmupSec.ToString(),
        "-OutDir", $smokeOutDirRel,
        "-LeaveWindowOpen",
        "-StopExistingViewer"
    ) `
    -TimeoutSec $SmokeTimeoutSec `
    -CaptureOutput $false)

[void](Invoke-FullScriptStage `
    -Stage "marker" `
    -ScriptPath (Join-Path $PSScriptRoot "wait-gvt-guest-ready.ps1") `
    -Arguments @(
        "-BatchMode",
        "-ServerSsh", $ServerSsh,
        "-QgaSock", $QgaSock,
        "-WindowProcessName", $WindowProcessName,
        "-TimeoutSec", $MarkerTimeoutSec.ToString()
    ) `
    -TimeoutSec $MarkerStageTimeoutSec)

[void](Invoke-FullScriptStage `
    -Stage "audio" `
    -ScriptPath (Join-Path $PSScriptRoot "measure-gvt-audio-quality.ps1") `
    -Arguments @(
        "-BatchMode",
        "-ServerSsh", $ServerSsh,
        "-QgaSock", $QgaSock,
        "-GuestTrigger", "agent-file",
        "-OutDir", $audioOutDirRel
    ) `
    -TimeoutSec $AudioTimeoutSec)

[void](Invoke-FullScriptStage `
    -Stage "av_sync" `
    -ScriptPath (Join-Path $PSScriptRoot "measure-gvt-av-sync.ps1") `
    -Arguments @(
        "-BatchMode",
        "-ServerSsh", $ServerSsh,
        "-QgaSock", $QgaSock,
        "-WindowProcessName", $WindowProcessName,
        "-OutDir", $avOutDirRel
    ) `
    -TimeoutSec $AvSyncTimeoutSec)

$latencyStageArgs = @(
    "-WindowProcessName", $WindowProcessName,
    "-UseVideoArea",
    "-Trigger", "tcp"
)
switch ($LatencyTriggerProfile) {
    "win-r" {
        $latencyStageArgs += @(
            "-OpenAction", "combo",
            "-OpenQcode", "meta_l,r",
            "-GuestX", "3000",
            "-GuestY", "28500",
            "-RoiWidth", "760",
            "-RoiHeight", "520"
        )
    }
    "win-key" {
        $latencyStageArgs += @(
            "-OpenAction", "combo",
            "-OpenQcode", "meta_l",
            "-GuestX", "3000",
            "-GuestY", "28500",
            "-RoiWidth", "760",
            "-RoiHeight", "520"
        )
    }
    "right-click-upper" {
        $latencyStageArgs += @(
            "-OpenAction", "click",
            "-OpenButton", "right",
            "-GuestX", "29200",
            "-GuestY", "3600",
            "-RoiWidth", "560",
            "-RoiHeight", "420"
        )
    }
}
$latencyStageArgs += @(
    "-Trials", $LatencyTrials.ToString(),
    "-OutDir", $latencyOutDirRel
)
Write-FullLog ("latency trigger profile: {0}; {1}" -f $LatencyTriggerProfile, (Get-FullLatencyTriggerDescription $LatencyTriggerProfile)) "latency"

[void](Invoke-FullScriptStage `
    -Stage "latency" `
    -ScriptPath (Join-Path $PSScriptRoot "measure-gvt-video-latency.ps1") `
    -Arguments $latencyStageArgs `
    -TimeoutSec $LatencyTimeoutSec)

$smokeDir = Get-FullLatestDirectory $smokeOutDirRel
$audioDir = Get-FullLatestDirectory $audioOutDirRel
$avDir = Get-FullLatestDirectory $avOutDirRel
$latencyDir = Get-FullLatestDirectory $latencyOutDirRel

$smokeSummaryPath = if ($smokeDir) { Join-Path $smokeDir.FullName "summary.json" } else { $null }
$audioSummaryPath = if ($audioDir) { Join-Path $audioDir.FullName "summary.json" } else { $null }
$avSummaryPath = if ($avDir) { Join-Path $avDir.FullName "summary.json" } else { $null }
$latencyCsvPath = if ($latencyDir) { Join-Path $latencyDir.FullName "results.csv" } else { $null }

$artifacts = [ordered]@{
    smoke_dir = if ($smokeDir) { $smokeDir.FullName } else { $null }
    smoke_summary_path = $smokeSummaryPath
    smoke_summary = Read-FullJsonFile $smokeSummaryPath
    audio_dir = if ($audioDir) { $audioDir.FullName } else { $null }
    audio_summary_path = $audioSummaryPath
    audio_summary = Read-FullJsonFile $audioSummaryPath
    av_sync_dir = if ($avDir) { $avDir.FullName } else { $null }
    av_sync_summary_path = $avSummaryPath
    av_sync_summary = Read-FullJsonFile $avSummaryPath
    latency_dir = if ($latencyDir) { $latencyDir.FullName } else { $null }
    latency = if ($latencyCsvPath) { Get-FullLatencyStats $latencyCsvPath } else { $null }
}

$overallOk = $true
foreach ($entry in $stageResults.GetEnumerator()) {
    if ($entry.Value.Contains("ok") -and -not [bool]$entry.Value.ok) {
        $overallOk = $false
    }
}
if ($artifacts.latency -and $artifacts.latency.valid_count -le 0) {
    $overallOk = $false
}
if ($artifacts.av_sync_summary) {
    $avCheckNearestPairs = Get-FullMember -Object $artifacts.av_sync_summary -Name "nearest_pairs" -Default $null
    $avCheckLegacyPairs = Get-FullMember -Object $artifacts.av_sync_summary -Name "pairs" -Default $null
    $avCheckPairCount = if ($null -ne $avCheckNearestPairs -and @($avCheckNearestPairs).Count -gt 0) {
        @($avCheckNearestPairs).Count
    } elseif ($null -ne $avCheckLegacyPairs) {
        @($avCheckLegacyPairs).Count
    } else {
        0
    }
    if ($avCheckPairCount -le 0) {
        $overallOk = $false
    }
}

$summary = [ordered]@{
    generated_at = (Get-Date).ToString("o")
    overall_ok = $overallOk
    output_dir = $runDir
    status_path = $statusPath
    stage_timeouts = $stageTimeoutPlan
    expected_guest_user = $expectedGuestUser
    test_config = [ordered]@{
        latency_trigger_profile = $LatencyTriggerProfile
        latency_trigger_description = Get-FullLatencyTriggerDescription $LatencyTriggerProfile
        latency_good_ms = $LatencyGoodMs
        latency_pass_ms = $LatencyPassMs
    }
    stages = $stageResults
    artifacts = $artifacts
    events = $events
    report = $reportZhPath
    report_html = $reportHtmlPath
}

$summary | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-FullReports -Summary $summary

Write-FullLog "summary: $summaryPath"
Write-FullLog "Chinese report: $reportZhPath"
Write-FullLog "HTML report: $reportHtmlPath"
$finalState = if ($overallOk) { "passed" } else { "failed" }
Update-FullStatus -Stage "summary" -Message "overall_ok=$overallOk" -State $finalState -StartStage

Write-Host ""
Write-Host "===== 中文结果 ====="
Get-Content -LiteralPath $reportZhPath | ForEach-Object { Write-Host $_ }
Write-Host "HTML 报告: $reportHtmlPath"

if (-not $overallOk) {
    exit 1
}
