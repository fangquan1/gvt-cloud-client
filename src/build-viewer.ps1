$ErrorActionPreference = "Stop"

$Root = Split-Path -Parent $PSScriptRoot
$OutDir = Join-Path $Root "build\viewer"
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

$ResourceObj = Join-Path $OutDir "gvt_spice_viewer_res.o"
& $Windres `
    --preprocessor gcc.exe `
    --preprocessor-arg -E `
    --preprocessor-arg -xc `
    --preprocessor-arg -DRC_INVOKED `
    -O coff `
    -i (Join-Path $PSScriptRoot "gvt_spice_viewer.rc") `
    -o $ResourceObj

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

& $Gcc `
    -mwindows `
    -O2 `
    -Wall `
    -Wextra `
    -o (Join-Path $OutDir "gvt_spice_viewer.exe") `
    (Join-Path $PSScriptRoot "gvt_spice_viewer.c") `
    $ResourceObj `
    -lws2_32 `
    -lshell32 `
    -lgdi32 `
    -luser32

if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
}

Write-Host "Built $OutDir\gvt_spice_viewer.exe"
