param(
    [int]$Trials = 8,
    [string]$OutDir = "latency-captures\golden-1920x1200-0941-winr"
)

$measure = Join-Path $PSScriptRoot "measure-gvt-video-latency.ps1"

& $measure `
    -WindowProcessName "gvt_spice_viewer.video-debug" `
    -InputHost "192.168.0.188" `
    -InputPort 5905 `
    -Trigger tcp `
    -OpenAction combo `
    -OpenQcode "meta_l,r" `
    -Mode open `
    -UseVideoArea `
    -SourceWidth 1920 `
    -SourceHeight 1200 `
    -ToolbarHeight 32 `
    -Trials $Trials `
    -PrepWaitMs 1000 `
    -CleanNeutralMax 12000 `
    -MaxWaitMs 1800 `
    -FrameIntervalMs 10 `
    -GuestX 3300 `
    -GuestY 28600 `
    -RoiWidth 760 `
    -RoiHeight 420 `
    -OutDir $OutDir
