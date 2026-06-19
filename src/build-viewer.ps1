$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $Root "build\viewer"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Gcc = "C:\Program Files\mingw64\bin\gcc.exe"
if (!(Test-Path $Gcc)) {
    $Gcc = "gcc.exe"
}

& $Gcc `
    -mwindows `
    -O2 `
    -Wall `
    -Wextra `
    -o (Join-Path $OutDir "gvt_spice_viewer.exe") `
    (Join-Path $PSScriptRoot "gvt_spice_viewer.c") `
    -lws2_32 `
    -lshell32 `
    -lgdi32 `
    -luser32

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Built $OutDir\gvt_spice_viewer.exe"
