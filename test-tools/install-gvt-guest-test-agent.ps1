<#
.SYNOPSIS
Installs the GVT desktop/audio test agent into the Windows guest through QGA.

.DESCRIPTION
The installed guest agent is a small PowerShell helper that runs in the user's
desktop session at logon, shows a GVT_READY marker, and accepts test commands
through C:\ProgramData\GvtCloudTest\command.json.
#>
param(
    [string]$ServerSsh = "root@192.168.0.188",
    [string]$QgaSock = "/root/qemu_cmd/win10-gvt-stream-qga.sock",
    [string]$GuestRoot = "C:\ProgramData\GvtCloudTest",
    [string]$GuestUser = "",
    [string]$GuestPassword = "",
    [switch]$ConfigureAutoLogon,
    [string]$ScheduledTaskName = "GvtCloudTestAgent",
    [switch]$BatchMode,
    [switch]$StartNow
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "gvt-test-common.ps1")

$localConfigPath = Join-Path (Resolve-GvtClientRoot) "secrets\gvt-test-guest.ps1"
if (Test-Path -LiteralPath $localConfigPath) {
    . $localConfigPath
    if ($null -ne $GvtGuestTestConfig) {
        if (-not $PSBoundParameters.ContainsKey("GuestUser") -and
            $GvtGuestTestConfig.ContainsKey("GuestUser")) {
            $GuestUser = [string]$GvtGuestTestConfig.GuestUser
        }
        if (-not $PSBoundParameters.ContainsKey("GuestPassword") -and
            $GvtGuestTestConfig.ContainsKey("GuestPassword")) {
            $GuestPassword = [string]$GvtGuestTestConfig.GuestPassword
        }
        if (-not $PSBoundParameters.ContainsKey("ConfigureAutoLogon") -and
            $GvtGuestTestConfig.ContainsKey("ConfigureAutoLogon") -and
            [bool]$GvtGuestTestConfig.ConfigureAutoLogon) {
            $ConfigureAutoLogon = $true
        }
        if (-not $PSBoundParameters.ContainsKey("ScheduledTaskName") -and
            $GvtGuestTestConfig.ContainsKey("ScheduledTaskName")) {
            $ScheduledTaskName = [string]$GvtGuestTestConfig.ScheduledTaskName
        }
    }
}

$localAgent = Join-Path $PSScriptRoot "guest\gvt-test-agent.ps1"
if (-not (Test-Path -LiteralPath $localAgent)) {
    throw "Missing guest agent source: $localAgent"
}

$guestAgent = Join-Path $GuestRoot "gvt-test-agent.ps1"
$guestStatus = Join-Path $GuestRoot "status.json"
$startupDir = "C:\ProgramData\Microsoft\Windows\Start Menu\Programs\Startup"
$startupCmd = Join-Path $startupDir "GVT Cloud Test Agent.cmd"
$agentCommand = "powershell.exe -STA -NoProfile -ExecutionPolicy Bypass -File `"$guestAgent`""

Write-Host "Checking QGA..."
[void](Invoke-GvtQgaCommand `
    -Command @{ execute = "guest-ping" } `
    -ServerSsh $ServerSsh `
    -QgaSock $QgaSock `
    -BatchMode:$BatchMode)

Write-Host "Creating guest directories..."
$mkdirScript = @"
New-Item -ItemType Directory -Force -Path '$GuestRoot' | Out-Null
New-Item -ItemType Directory -Force -Path '$startupDir' | Out-Null
"@
[void](Invoke-GvtQgaGuestExec `
    -Path "powershell.exe" `
    -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $mkdirScript) `
    -ServerSsh $ServerSsh `
    -QgaSock $QgaSock `
    -BatchMode:$BatchMode `
    -TimeoutSec 20)

Write-Host "Writing guest agent: $guestAgent"
$agentBytes = [IO.File]::ReadAllBytes($localAgent)
Write-GvtQgaFile `
    -GuestPath $guestAgent `
    -Bytes $agentBytes `
    -ServerSsh $ServerSsh `
    -QgaSock $QgaSock `
    -BatchMode:$BatchMode

$cmdText = @"
@echo off
start "" $agentCommand
"@
Write-Host "Writing startup command: $startupCmd"
Write-GvtQgaFile `
    -GuestPath $startupCmd `
    -Text $cmdText `
    -ServerSsh $ServerSsh `
    -QgaSock $QgaSock `
    -BatchMode:$BatchMode

if (-not [string]::IsNullOrWhiteSpace($GuestUser)) {
    if ([string]::IsNullOrWhiteSpace($GuestPassword)) {
        throw "GuestPassword is required when GuestUser is set."
    }

    Write-Host "Creating interactive scheduled task for guest user '$GuestUser'..."
    $deleteTask = Invoke-GvtQgaGuestExec `
        -Path "schtasks.exe" `
        -ArgumentList @("/Delete", "/TN", $ScheduledTaskName, "/F") `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -BatchMode:$BatchMode `
        -TimeoutSec 20 `
        -NoCapture
    [void]$deleteTask

    $createTask = Invoke-GvtQgaGuestExec `
        -Path "schtasks.exe" `
        -ArgumentList @(
            "/Create",
            "/TN", $ScheduledTaskName,
            "/TR", $agentCommand,
            "/SC", "ONLOGON",
            "/RU", $GuestUser,
            "/RP", $GuestPassword,
            "/RL", "HIGHEST",
            "/IT",
            "/F"
        ) `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -BatchMode:$BatchMode `
        -TimeoutSec 30

    if ($createTask.ExitCode -ne 0) {
        throw "Failed to create scheduled task. stdout=$($createTask.Stdout) stderr=$($createTask.Stderr)"
    }

    if ($ConfigureAutoLogon) {
        Write-Host "Configuring AutoAdminLogon for guest user '$GuestUser'..."
        $autoLogonScript = @"
`$computer = `$env:COMPUTERNAME
`$winlogon = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon'
New-ItemProperty -Path `$winlogon -Name AutoAdminLogon -Value '1' -PropertyType String -Force | Out-Null
New-ItemProperty -Path `$winlogon -Name DefaultUserName -Value '$GuestUser' -PropertyType String -Force | Out-Null
New-ItemProperty -Path `$winlogon -Name DefaultPassword -Value '$GuestPassword' -PropertyType String -Force | Out-Null
New-ItemProperty -Path `$winlogon -Name DefaultDomainName -Value `$computer -PropertyType String -Force | Out-Null
"@
        [void](Invoke-GvtQgaGuestExec `
            -Path "powershell.exe" `
            -ArgumentList @("-NoProfile", "-ExecutionPolicy", "Bypass", "-Command", $autoLogonScript) `
            -ServerSsh $ServerSsh `
            -QgaSock $QgaSock `
            -BatchMode:$BatchMode `
            -TimeoutSec 20)
    }
}

if ($StartNow) {
    Write-Host "Starting guest agent now through QGA. If no marker appears, reboot or log off/on so Startup runs in the desktop session."
    [void](Invoke-GvtQgaCommand `
        -Command @{
            execute = "guest-exec"
            arguments = @{
                path = "powershell.exe"
                arg = @("-STA", "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", $guestAgent)
                "capture-output" = $false
            }
        } `
        -ServerSsh $ServerSsh `
        -QgaSock $QgaSock `
        -BatchMode:$BatchMode)
}

Write-Host "GVT guest test agent installed."
Write-Host "  Agent:  $guestAgent"
Write-Host "  Status: $guestStatus"
Write-Host "  Startup: $startupCmd"
if (-not [string]::IsNullOrWhiteSpace($GuestUser)) {
    Write-Host "  Scheduled task: $ScheduledTaskName as $GuestUser"
}
Write-Host "Reboot or log off/on once if the green GVT_READY marker is not visible yet."
