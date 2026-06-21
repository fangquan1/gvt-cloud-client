$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $Root "build\native-launcher"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Gcc = "C:\Program Files\mingw64\bin\gcc.exe"
if (!(Test-Path $Gcc)) {
    $Gcc = "gcc.exe"
}

& $Gcc `
    -municode `
    -mwindows `
    -O2 `
    -Wall `
    -Wextra `
    -o (Join-Path $OutDir "GVT Cloud Client.exe") `
    (Join-Path $PSScriptRoot "gvt_cloud_client.c") `
    -lcomctl32 `
    -lshell32 `
    -lws2_32

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Built $OutDir\GVT Cloud Client.exe"
