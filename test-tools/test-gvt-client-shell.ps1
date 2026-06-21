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
    [int]$TimeoutSec = 30,
    [switch]$UseRealViewer,
    [string]$MockViewerPath = ""
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

function Add-ShellCase {
    param(
        [string]$Name,
        [bool]$Ok,
        [string]$Detail = ""
    )
    [void]$script:shellCases.Add([ordered]@{
        name = $Name
        ok = $Ok
        detail = $Detail
    })
}

function Get-ShellFeatureMatrix {
    @(
        [ordered]@{
            feature = "main_window"
            coverage = "automated"
            checks = "endpoint combo, connect, settings, help, add connection, more menu controls"
        },
        [ordered]@{
            feature = "edit_connection_dialog"
            coverage = "automated"
            checks = "endpoint, display name, codec, fps, bitrate, latency, reconnect, start viewer, tray, test/save/cancel controls"
        },
        [ordered]@{
            feature = "settings_dialog"
            coverage = "automated"
            checks = "default codec/fps/bitrate/latency/session behavior controls and restore/save/apply/cancel controls"
        },
        [ordered]@{
            feature = "isolated_config_load"
            coverage = "automated"
            checks = "test-local gvt_client_settings.json and gvt_client_connections.json are loaded from the launcher directory"
        },
        [ordered]@{
            feature = "address_bar_existing_connection"
            coverage = "automated"
            checks = "typed endpoint resolves to the seeded connection instead of creating a default connection"
        },
        [ordered]@{
            feature = "viewer_launch_stream_args"
            coverage = "automated"
            checks = "codec, latency, stream fps, bitrate kbps, keyint, connection id, thumbnail path"
        },
        [ordered]@{
            feature = "viewer_launch_ports"
            coverage = "automated"
            checks = "video/control port, derived SPICE port, derived native input port"
        },
        [ordered]@{
            feature = "viewer_launch_input_flags"
            coverage = "automated"
            checks = "native input, invert-case, SPICE tablet input, no-drop-on-latency flags"
        },
        [ordered]@{
            feature = "full_test_integration"
            coverage = "automated"
            checks = "run-gvt-full-test.ps1 executes this shell test before stream smoke/audio/AV/latency stages"
        }
    )
}

function Set-ShellSummaryCases {
    param([System.Collections.Specialized.OrderedDictionary]$Summary)
    if ($Summary.Contains("cases")) {
        $Summary.Remove("cases")
    }
    $Summary.Add("cases", [object[]]$script:shellCases.ToArray())
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
$sourceLauncher = Resolve-FirstExistingPath -Candidates $launcherCandidates -Kind "GVT Cloud Client.exe"
$sourceLauncherDir = Split-Path -Parent $sourceLauncher
$launcherDir = Join-Path $runDir "isolated-app"
New-Item -ItemType Directory -Force -Path $launcherDir | Out-Null
$launcher = Join-Path $launcherDir (Split-Path -Leaf $sourceLauncher)
Copy-Item -LiteralPath $sourceLauncher -Destination $launcher -Force

$endpoint = "{0}:{1}" -f $ServerHost, $VideoPort
$bitrateKbps = $BitrateMbps * 1000
$expectedSpicePort = 5900 + [Math]::Max(0, [int](($VideoPort - 5004) / 4))
$expectedInputPort = 5905 + [Math]::Max(0, [int](($VideoPort - 5004) / 4))
$settingsPath = Join-Path $launcherDir "gvt_client_settings.json"
$connectionsPath = Join-Path $launcherDir "gvt_client_connections.json"
$historyPath = Join-Path $launcherDir "gvt_client_history.txt"
$thumbnailDir = Join-Path $launcherDir "thumbnails"
$thumbnailPath = Join-Path $thumbnailDir "conn-shell-test.bmp"
New-Item -ItemType Directory -Force -Path $thumbnailDir | Out-Null

$settingsJson = [ordered]@{
    codec = $Codec
    fps = $StreamFps
    bitrate_mbps = $BitrateMbps
    latency_ms = $Latency
    use_remote_resolution = $true
    reconnect = $false
    reconnect_attempts = 3
    reconnect_interval_sec = 5
    start_viewer = $true
    minimize_tray_on_connect = $false
    remember_recent = $true
}
$connectionsJson = [ordered]@{
    connections = @(
        [ordered]@{
            id = "conn-shell-test"
            name = "Shell Test VM"
            endpoint = $endpoint
            codec = $Codec
            fps = $StreamFps
            bitrate_mbps = $BitrateMbps
            latency_ms = $Latency
            use_remote_resolution = $true
            reconnect = $false
            reconnect_attempts = 3
            reconnect_interval_sec = 5
            start_viewer = $true
            minimize_tray_on_connect = $false
            thumbnail = $thumbnailPath
        }
    )
}
$settingsJson | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $settingsPath -Encoding UTF8
$connectionsJson | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $connectionsPath -Encoding UTF8
Set-Content -LiteralPath $historyPath -Value $endpoint -Encoding UTF8

if ($UseRealViewer) {
    $viewerCandidates = @(
        (Join-Path $sourceLauncherDir "app\viewer\gvt_spice_viewer.exe"),
        (Join-Path $sourceLauncherDir "viewer\gvt_spice_viewer.exe"),
        (Join-Path $clientRoot "build\viewer\gvt_spice_viewer.exe")
    )
    $viewer = Resolve-FirstExistingPath -Candidates $viewerCandidates -Kind "gvt_spice_viewer.exe"
    $viewerMode = "real_viewer"
} else {
    $mockCandidates = @()
    if (-not [string]::IsNullOrWhiteSpace($MockViewerPath)) {
        $mockCandidates += $MockViewerPath
    }
    try {
        $mockCandidates += (Get-Command powershell.exe -ErrorAction Stop).Source
    } catch {
    }
    $mockCandidates += (Join-Path $env:SystemRoot "System32\WindowsPowerShell\v1.0\powershell.exe")
    $viewer = Resolve-FirstExistingPath -Candidates $mockCandidates -Kind "mock viewer executable"
    $viewerMode = "mock_viewer"
}
$viewerProcessName = [IO.Path]::GetFileName($viewer)
$viewerProcessBaseName = [IO.Path]::GetFileNameWithoutExtension($viewer)
$shellCases = New-Object System.Collections.Generic.List[object]
Add-ShellCase -Name "isolated launcher directory" -Ok $true -Detail $launcherDir
Add-ShellCase -Name "seeded shell settings" -Ok (Test-Path -LiteralPath $settingsPath) -Detail $settingsPath
Add-ShellCase -Name "seeded shell connection" -Ok (Test-Path -LiteralPath $connectionsPath) -Detail $connectionsPath

$summary = [ordered]@{
    ok = $false
    run_dir = $runDir
    source_launcher_path = $sourceLauncher
    isolated_app_dir = $launcherDir
    launcher_path = $launcher
    viewer_path = $viewer
    viewer_mode = $viewerMode
    endpoint = $endpoint
    seeded_settings_path = $settingsPath
    seeded_connections_path = $connectionsPath
    feature_matrix = @(Get-ShellFeatureMatrix)
    cases = @()
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
    Set-ShellSummaryCases -Summary $summary
    Write-ShellLog "launcher: $launcher"
    Write-ShellLog "source launcher: $sourceLauncher"
    Write-ShellLog "viewer: $viewer"
    Write-ShellLog "viewer mode: $viewerMode"
    Write-ShellLog "endpoint: $endpoint"
    Write-ShellLog "isolated app dir: $launcherDir"

    if ($UseRealViewer) {
        Get-Process -Name $viewerProcessBaseName -ErrorAction SilentlyContinue | Stop-Process -Force
    }
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
    Add-ShellCase -Name "main window opens" -Ok $true -Detail "hwnd=$hwnd"
    [void][GvtShellWin32]::SetForegroundWindow($hwnd)

    $IDC_ENDPOINT = 1001
    $IDC_CONNECT = 1002
    $IDC_SETTINGS = 1004
    $IDC_HELP_BUTTON = 1005
    $IDC_ADD_CONNECTION = 1006
    $IDC_MORE = 1007
    $WM_SETTEXT = 0x000C
    $WM_CLOSE = 0x0010
    $BM_CLICK = 0x00F5

    $endpointHwnd = Assert-ShellControl -Window $hwnd -ControlId $IDC_ENDPOINT -Name "main endpoint"
    $connectHwnd = Assert-ShellControl -Window $hwnd -ControlId $IDC_CONNECT -Name "main connect"
    $settingsHwnd = Assert-ShellControl -Window $hwnd -ControlId $IDC_SETTINGS -Name "main settings"
    [void](Assert-ShellControl -Window $hwnd -ControlId $IDC_HELP_BUTTON -Name "main help")
    $addHwnd = Assert-ShellControl -Window $hwnd -ControlId $IDC_ADD_CONNECTION -Name "main add connection"
    [void](Assert-ShellControl -Window $hwnd -ControlId $IDC_MORE -Name "main more menu")
    Add-ShellCase -Name "main window controls" -Ok $true -Detail "endpoint/connect/settings/help/add/more"

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
        @(2009, "edit reconnect attempts"),
        @(2010, "edit reconnect interval"),
        @(2011, "edit start viewer"),
        @(2012, "edit minimize tray"),
        @(2013, "edit test connection"),
        @(2014, "edit save"),
        @(2015, "edit save reconnect"),
        @(2016, "edit cancel")
    )) {
        [void](Assert-ShellControl -Window $editWindow -ControlId ([int]$item[0]) -Name ([string]$item[1]))
    }
    [void][GvtShellWin32]::SendMessage($editWindow, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    Add-ShellCase -Name "edit connection controls" -Ok $true -Detail "all expected edit controls present"
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
        @(3007, "settings reconnect attempts"),
        @(3008, "settings reconnect interval"),
        @(3009, "settings start viewer"),
        @(3010, "settings tray"),
        @(3011, "settings remember recent"),
        @(3012, "settings restore"),
        @(3013, "settings save"),
        @(3014, "settings apply"),
        @(3015, "settings cancel")
    )) {
        [void](Assert-ShellControl -Window $settingsWindow -ControlId ([int]$item[0]) -Name ([string]$item[1]))
    }
    [void][GvtShellWin32]::SendMessage($settingsWindow, $WM_CLOSE, [IntPtr]::Zero, [IntPtr]::Zero)
    Add-ShellCase -Name "settings controls" -Ok $true -Detail "all expected settings controls present"
    Write-ShellLog "validated Settings window controls"

    [void][GvtShellWin32]::SendMessage($endpointHwnd, $WM_SETTEXT, [IntPtr]::Zero, $endpoint)
    Add-ShellCase -Name "address bar filled" -Ok $true -Detail $endpoint
    Write-ShellLog "filled main server address control"

    [void][GvtShellWin32]::SendMessage($connectHwnd, $BM_CLICK, [IntPtr]::Zero, [IntPtr]::Zero)
    Write-ShellLog "clicked Connect"

    while ((Get-Date) -lt $deadline -and [string]::IsNullOrWhiteSpace($viewerCommandLine)) {
        $children = @(Get-CimInstance Win32_Process -Filter "ParentProcessId=$($launcherProcess.Id)" -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ieq $viewerProcessName })
        if ($children.Count -gt 0) {
            $child = $children | Sort-Object ProcessId -Descending | Select-Object -First 1
            $viewerProcessId = [int]$child.ProcessId
            $viewerCommandLine = [string]$child.CommandLine
            break
        }
        $globalViewer = @(Get-CimInstance Win32_Process -Filter "Name='$viewerProcessName'" -ErrorAction SilentlyContinue |
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
                Where-Object { $_ -like "*--stream-bitrate-kbps*" -and $_ -like "*--stream-fps*" } |
                Select-Object -Last 1
            if (-not [string]::IsNullOrWhiteSpace($loggedCommand)) {
                $viewerCommandLine = [string]$loggedCommand
                $viewerProcess = Get-Process -Name $viewerProcessBaseName -ErrorAction SilentlyContinue |
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
        throw "Launcher did not start the viewer command."
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
        "--invert-case",
        "--spice-input-tablet",
        "--no-drop-on-latency"
    )
    $missing = @(Test-CommandLineContains -CommandLine $viewerCommandLine -Needles $needles)
    if ($missing.Count -gt 0) {
        $summary["missing_command_line_parts"] = $missing
        throw "Viewer command line is missing expected parts: $($missing -join ', ')"
    }
    Add-ShellCase -Name "viewer stream arguments" -Ok $true -Detail "codec=$Codec fps=$StreamFps bitrate_kbps=$bitrateKbps latency=$Latency"
    Add-ShellCase -Name "viewer port arguments" -Ok $true -Detail "video=$VideoPort spice=$expectedSpicePort input=$expectedInputPort control=$VideoPort"
    Add-ShellCase -Name "viewer input flags" -Ok $true -Detail "native-input/invert-case/spice-input-tablet/no-drop-on-latency"

    $savedConnections = Get-Content -LiteralPath $connectionsPath -Raw | ConvertFrom-Json
    $savedConnectionList = @($savedConnections.connections)
    if ($savedConnectionList.Count -ne 1) {
        throw "Expected one saved shell connection, found $($savedConnectionList.Count)."
    }
    if ($savedConnectionList[0].id -ne "conn-shell-test") {
        throw "Expected address bar to use the seeded connection, got '$($savedConnectionList[0].id)'."
    }
    if ([int]$savedConnectionList[0].fps -ne $StreamFps -or [int]$savedConnectionList[0].bitrate_mbps -ne $BitrateMbps) {
        throw "Saved connection parameters changed unexpectedly."
    }
    Add-ShellCase -Name "address bar used seeded connection" -Ok $true -Detail "connection_count=1 id=conn-shell-test"

    $debugLog = Join-Path $launcherDir "gvt_client_debug.log"
    if (Test-Path -LiteralPath $debugLog) {
        Copy-Item -LiteralPath $debugLog -Destination (Join-Path $runDir "gvt_client_debug.log") -Force
        $summary["launcher_debug_log"] = Join-Path $runDir "gvt_client_debug.log"
        Add-ShellCase -Name "launcher debug log copied" -Ok $true -Detail $summary["launcher_debug_log"]
    }

    $summary["ok"] = $true
    $summary["viewer_pid"] = $viewerProcessId
    $summary["viewer_command_line"] = $viewerCommandLine
    Set-ShellSummaryCases -Summary $summary
    Write-ShellLog "GVT client shell: PASS"
} catch {
    $summary["error"] = $_.Exception.Message
    Set-ShellSummaryCases -Summary $summary
    Write-ShellLog "GVT client shell: FAIL: $($_.Exception.Message)"
    $summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
    exit 1
} finally {
    if ($viewerProcessId) {
        Stop-ProcessQuietly -ProcessId $viewerProcessId
    }
    if ($launcherProcess -and -not $launcherProcess.HasExited) {
        Stop-ProcessQuietly -ProcessId $launcherProcess.Id
    }
}

$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $summaryPath -Encoding UTF8
Write-Host "Summary: $summaryPath"
exit 0
