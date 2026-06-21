$ErrorActionPreference = "Stop"
$Root = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $Root "build\native-launcher"
New-Item -ItemType Directory -Force -Path $OutDir | Out-Null

$Gcc = "C:\Program Files\mingw64\bin\gcc.exe"
if (!(Test-Path $Gcc)) {
    $Gcc = "gcc.exe"
}

$Windres = Join-Path (Split-Path -Parent $Gcc) "windres.exe"
if (!(Test-Path $Windres)) {
    $Windres = "windres.exe"
}
$env:PATH = "$(Split-Path -Parent $Gcc);$env:PATH"

$ResourceObj = Join-Path $OutDir "gvt_cloud_client_res.o"
& $Windres `
    --preprocessor gcc.exe `
    --preprocessor-arg -E `
    --preprocessor-arg -xc `
    --preprocessor-arg -DRC_INVOKED `
    -O coff `
    -i (Join-Path $PSScriptRoot "gvt_cloud_client.rc") `
    -o $ResourceObj

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $Gcc `
    -municode `
    -mwindows `
    -O2 `
    -Wall `
    -Wextra `
    -o (Join-Path $OutDir "GVT Cloud Client.exe") `
    (Join-Path $PSScriptRoot "gvt_cloud_client.c") `
    $ResourceObj `
    -lcomctl32 `
    -lshell32 `
    -lws2_32

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Built $OutDir\GVT Cloud Client.exe"
