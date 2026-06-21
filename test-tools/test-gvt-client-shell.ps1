<#
.SYNOPSIS
Validates the native GVT Cloud Client shell launches the viewer with expected arguments.
#>
param(
    [string]$ServerHost = "192.168.0.188",
    [int]$VideoPort = 5004,
    [ValidateSet("h264", "h265")]
    [string]$Codec = "h265",
    [int]$Latency = 15,
    [int]$StreamFps = 59,
    [int]$BitrateMbps = 18,
    [string]$LauncherPath = "",
    [string]$OutDir = "build\client-shell-test",
    [int]$TimeoutSec = 30
)

$ErrorActionPreference = "Stop"

$clientRoot = Split-Path -Parent $PSScriptRoot
$stamp = Get-Date -Format "yyyyMMdd-HHmmss"
$runDir = Join-Path (Join-Path $clientRoot $OutDir) "shell-$stamp"
New-Item -ItemType Directory -Force -Path $runDir | Out-Null

$summaryPath = Join-Path $runDir "summary.json"
$logPath = Join-Path $runDir "shell.log"

function Write-ShellLog {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date).ToString("yyyy-MM-dd HH:mm:ss.fff"), $Message
    Write-Host $line
    Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
}

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

function Stop-ProcessQuietly {
    param([int]$ProcessId)
    try {
        Stop-Process -Id $ProcessId -Force -ErrorAction Stop
    } catch {
    }
}

function Test-CommandLineContains {
    param(
        [string]$CommandLine,
        [string[]]$Needles
    )

    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($needle in $Needles) {
        if ($CommandLine -notlike "*$needle*") {
            [void]$missing.Add($needle)
        }
    }
    return $missing.ToArray()
}

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;

public static class GvtShellWin32 {
    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr FindWindow(string lpClassName, string lpWindowName);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr GetDlgItem(IntPtr hDlg, int nIDDlgItem);

    [DllImport("user32.dll", SetLastError=true, CharSet=CharSet.Unicode)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 Msg, IntPtr wParam, string lParam);

    [DllImport("user32.dll", SetLastError=true)]
    public static extern IntPtr SendMessage(IntPtr hWnd, UInt32 Msg, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll")]
    public static extern bool SetForegroundWindow(IntPtr hWnd);
}
"@

function Wait-ShellWindow {
    param(
        [string]$ClassName,
        [string]$Title,
        [int]$TimeoutSec
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $found = [GvtShellWin32]::FindWindow($ClassName, $Title)
        if ($found -ne [IntPtr]::Zero) {
            return $found
        }
        Start-Sleep -Milliseconds 200
    }
    return [IntPtr]::Zero
}

function Assert-ShellControl {
    param(
        [IntPtr]$Window,
        [int]$ControlId,
        [string]$Name
    )
    $control = [GvtShellWin32]::GetDlgItem($Window, $ControlId)
    if ($control -eq [IntPtr]::Zero) {
        throw "Missing shell UI control: $Name"
    }
    return $control
}

function Set-StartEnvironment {
    param(
        [Diagnostics.ProcessStartInfo]$StartInfo,
        [string]$Name,
        [string]$Value
    )

    if ($null -ne $StartInfo.EnvironmentVariables) {
        $StartInfo.EnvironmentVariables[$Name] = $Value
    } elseif ($null -ne $StartInfo.Environment) {
        $StartInfo.Environment[$Name] = $Value
    } else {
        throw "ProcessStartInfo does not expose an environment collection."
    }
}

$launcherCandidates = @()
if (-not [string]::IsNullOrWhiteSpace($LauncherPath)) {
    $launcherCandidates += $LauncherPath
}
$launcherCandidates += (Join-Path $clientRoot "build\gvt-cloud-client-portable\GVT Cloud Client.exe")
$launcherCandidates += (Join-Path $clientRoot "build\native-launcher\GVT Cloud Client.exe")
$launcher = Resolve-FirstExistingPath -Candidates $launcherCandidates -Kind "GVT Cloud Client.exe"
$launcherDir = Split-Path -Parent $launcher

$viewerCandidates = @(
    (Join-Path $launcherDir "app\viewer\gvt_spice_viewer.exe"),
    (Join-Path $launcherDir "viewer\gvt_spice_viewer.exe"),
    (Join-Path $clientRoot "build\viewer\gvt_spice_viewer.exe")
)
$viewer = Resolve-FirstExistingPath -Candidates $viewerCandidates -Kind "gvt_spice_viewer.exe"
$endpoint = "{0}:{1}" -f $ServerHost, $VideoPort
$bitrateKbps = $BitrateMbps * 1000
$expectedSpicePort = 5900 + [Math]::Max(0, [int](($VideoPort - 5004) / 4))
$expectedInputPort = 5905 + [Math]::Max(0, [int](($VideoPort - 5004) / 4))

$summary = [ordered]@{
    ok = $false
    run_dir = $runDir
    launcher_path = $launcher
    viewer_path = $viewer
    endpoint = $endpoint
    expected = [ordered]@{
        codec = $Codec
        video_port = $VideoPort
        spice_port = $expectedSpicePort
        input_port = $expectedInputPort
        latency = $Latency
        stream_fps = $StreamFps
        stream_bitrate_kbps = $bitrateKbps
    }
}

$launcherProcess = $null
$viewerProcessId = $null
$viewerCommandLine = ""

try {
    Write-ShellLog "launcher: $launcher"
    Write-ShellLog "viewer: $viewer"
    Write-ShellLog "endpoint: $endpoint"

    Get-Process -Name "gvt_spice_viewer" -ErrorAction SilentlyContinue | Stop-Process -Force
    Get-Process -Name "GVT Cloud Client" -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Milliseconds 500

    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $launcher
    $startInfo.WorkingDirectory = $launcherDir
    $startInfo.UseShellExecute = $false
    Set-StartEnvironment -StartInfo $startInfo -Name "GVT_VIEWER_EXE" -Value $viewer
    Set-StartEnvironment -StartInfo $startInfo -Name "GVT_SPICE_VIEWER_VIDEO_DEBUG" -Value "1"
    Set-StartEnvironment -StartInfo $startInfo -Name "GVT_SPICE_VIEWER_DROP_COMPLETE_FRAMES" -Value "1"
    Set-StartEnvironment -StartInfo $startInfo -Name "GVT_SPICE_VIEWER_UDP_BUFFER_SIZE" -Value "2097152"

    $launcherProcess = [Diagnostics.Process]::Start($startInfo)
    Write-ShellLog "started launcher pid=$($launcherProcess.Id)"
    try {
        $launcherProcess.WaitForInputIdle(5000) | Out-Null
    } catch {
    }

    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    $hwnd = [IntPtr]::Zero
    while ((Get-Date) -lt $deadline -and $hwnd -eq [IntPtr]::Zero) {
        $launcherProcess.Refresh()
        $hwnd = $launcherProcess.MainWindowHandle
        if ($hwnd -eq [IntPtr]::Zero) {
            $hwnd = [GvtShellWin32]::FindWindow("GVTCloudClientWindow", "GVT Cloud Client")
        }
        Start-Sleep -Milliseconds 200
    }
    if ($hwnd -eq [IntPtr]::Zero) {
        throw "Launcher window did not appear."
    }
    [void][GvtShellWin32]::SetForegroundWindow($hwnd)

    $IDC_ENDPOINT = 1001
    $IDC_CONNECT = 1002
    $IDC_SETTINGS = 1004
    $IDC_ADD_CONNECTION = 1006
    $WM_SETTEXT = 0x000C
    $WM_CLOSE = 0x0010
    $BM_CLICK = 0x00F5

    $endpointHwnd = Assert-ShellControl -Window $hwnd -ControlId $IDC_ENDPOINT -Name "main endpoint"
    $connectHwnd = Assert-ShellControl -Window $hwnd -ControlId $IDC_CONNECT -Name "main connect"
    $settingsHwnd = Assert-ShellControl -Window $hwnd -ControlId $IDC_SETTINGS -Name "main settings"
    $addHwnd = Assert-ShellControl -Window $hwnd -ControlId $IDC_ADD_CONNECTION -Name "main add connection"

    [void][GvtShellWin32]::SendMessage($addHwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
    $editWindow = Wait-ShellWindow -ClassName "GVTCloudClientEditWindow" -Title "GVT Cloud Client | Edit Connection" -TimeoutSec 5
    if ($editWindow -eq [IntPtr]::Zero) {
        throw "Add Connection did not open the edit window."
    }
    foreach ($item in @(
        @(2001, "edit endpoint"),
        @(2002, "edit display name"),
        @(2003, "edit codec"),
        @(2004, "edit fps"),
        @(2005, "edit bitrate"),
        @(2006, "edit latency"),
        @(2007, "edit remote resolution"),
        @(2008, "edit reconnect"),
        @(2013, "edit test connection"),
        @(2014, "edit save"),
        @(2015, "edit save reconnect")
    )) {
        [void](Assert-ShellControl -Window $editWindow -ControlId ([int]$item[0]) -Name ([string]$item[1]))
    }
    [void][GvtShellWin32]::SendMessage($editWindow, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    Write-ShellLog "validated Add/Edit Connection window controls"

    [void][GvtShellWin32]::SendMessage($settingsHwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
    $settingsWindow = Wait-ShellWindow -ClassName "GVTCloudClientSettingsWindow" -Title "GVT Cloud Client | Settings" -TimeoutSec 5
    if ($settingsWindow -eq [IntPtr]::Zero) {
        throw "Settings did not open the settings window."
    }
    foreach ($item in @(
        @(3001, "settings codec"),
        @(3002, "settings fps"),
        @(3003, "settings bitrate"),
        @(3004, "settings latency"),
        @(3005, "settings remote resolution"),
        @(3006, "settings reconnect"),
        @(3009, "settings start viewer"),
        @(3010, "settings tray"),
        @(3011, "settings remember recent"),
        @(3012, "settings restore"),
        @(3013, "settings save"),
        @(3014, "settings apply")
    )) {
        [void](Assert-ShellControl -Window $settingsWindow -ControlId ([int]$item[0]) -Name ([string]$item[1]))
    }
    [void][GvtShellWin32]::SendMessage($settingsWindow, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    Write-ShellLog "validated Settings window controls"

    [void][GvtShellWin32]::SendMessage($endpointHwnd, $WM_SETTEXT, [IntPtr]::Zero, $endpoint)
    Write-ShellLog "filled main server address control"

    [void][GvtShellWin32]::SendMessage($connectHwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
    Write-ShellLog "clicked Connect"

    while ((Get-Date) -lt $deadline -and [string]::IsNullOrWhiteSpace($viewerCommandLine)) {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($launcherProcess.Id)" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq "gvt_spice_viewer.exe" })
        if ($children.Count -gt 0) {
            $child = $children | Sort-Object ProcessId -Descending | Select-Object -First 1
            $viewerProcessId = [int]$child.ProcessId
            $viewerCommandLine = [string]$child.CommandLine
            break
        }
        $globalViewer = @(Get-CimInstance Win32_Process -Filter "Name='gvt_spice_viewer.exe'" -ErrorAction SilentlyContinue |
            Where-Object { ([string]$_.CommandLine) -like "*$viewer*" })
        if ($globalViewer.Count -gt 0) {
            $child = $globalViewer | Sort-Object ProcessId -Descending | Select-Object -First 1
            $viewerProcessId = [int]$child.ProcessId
            $viewerCommandLine = [string]$child.CommandLine
            break
        }
        $debugLog = Join-Path $launcherDir "gvt_client_debug.log"
        if (Test-Path -LiteralPath $debugLog) {
            $loggedCommand = Get-Content -LiteralPath $debugLog -Tail 20 -ErrorAction SilentlyContinue |
                Where-Object { $_ -like "*gvt_spice_viewer.exe*" } |
                Select-Object -Last 1
            if (-not [string]::IsNullOrWhiteSpace($loggedCommand)) {
                $viewerCommandLine = [string]$loggedCommand
                $viewerProcess = Get-Process -Name "gvt_spice_viewer" -ErrorAction SilentlyContinue |
                    Sort-Object Id -Descending |
                    Select-Object -First 1
                if ($viewerProcess) {
                    $viewerProcessId = [int]$viewerProcess.Id
                }
                break
            }
        }
        Start-Sleep -Milliseconds 300
    }

    if ([string]::IsNullOrWhiteSpace($viewerCommandLine)) {
        throw "Launcher did not start gvt_spice_viewer.exe."
    }
    Write-ShellLog "viewer pid=$viewerProcessId"
    Write-ShellLog "viewer command line: $viewerCommandLine"

    $needles = @(
        "--video-codec",
        $Codec,
        "--video-port",
        "$VideoPort",
        "--latency",
        "$Latency",
        "--stream-fps",
        "$StreamFps",
        "--stream-bitrate-kbps",
        "$bitrateKbps",
        "--stream-keyint",
        "$StreamFps",
        "--connection-id",
        "--thumbnail-path",
        "--spice-host",
        $ServerHost,
        "--spice-port",
        "$expectedSpicePort",
        "--input-host",
        $ServerHost,
        "--input-port",
        "$expectedInputPort",
        "--stream-control-host",
        $ServerHost,
        "--stream-control-port",
        "$VideoPort",
        "--native-input",
        "--spice-input-tablet",
        "--no-drop-on-latency"
    )
    $missing = @(Test-CommandLineContains -CommandLine $viewerCommandLine -Needles $needles)
    if ($missing.Count -gt 0) {
        $summary.missing_command_line_parts = $missing
        throw "Viewer command line is missing expected parts: $($missing -join ', ')"
    }

    $debugLog = Join-Path $launcherDir "gvt_client_debug.log"
    if (Test-Path -LiteralPath $debugLog) {
        Copy-Item -LiteralPath $debugLog -Destination (Join-Path $runDir "gvt_client_debug.log") -Force
        $summary.launcher_debug_log = Join-Path $runDir "gvt_client_debug.log"
    }

    $summary.ok = $true
    $summary.viewer_pid = $viewerProcessId
    $summary.viewer_command_line = $viewerCommandLine
    Write-ShellLog "GVT client shell: PASS"
} catch {
    $summary.error = $_.Exception.Message
    Write-ShellLog "GVT client shell: FAIL: $($_.Exception.Message)"
    $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    exit 1
} finally {
    if ($viewerProcessId) {
        Stop-ProcessQuietly -ProcessId $viewerProcessId
    }
    if ($launcherProcess -and -not $launcherProcess.HasExited) {
        Stop-ProcessQuietly -ProcessId $launcherProcess.Id
    }
}

$summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host "Summary: $summaryPath"
exit 0
