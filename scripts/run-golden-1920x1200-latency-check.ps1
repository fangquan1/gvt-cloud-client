param(
    [int]$Trials = 6,
    [string]$OutDir = "latency-captures\golden-1920x1200-0941-startmenu"
)

$measure = Join-Path $PSScriptRoot "measure-gvt-video-latency.ps1"

& $measure `
    -WindowProcessName "gvt_spice_viewer.video-debug" `
    -InputHost "192.168.0.188" `
    -InputPort 5905 `
    -Trigger tcp `
    -OpenAction combo `
    -OpenQcode "ctrl,esc" `
    -Mode open `
    -UseVideoArea `
    -SourceWidth 1920 `
    -SourceHeight 1200 `
    -ToolbarHeight 32 `
    -Trials $Trials `
    -PrepWaitMs 1600 `
    -MaxWaitMs 2500 `
    -FrameIntervalMs 10 `
    -GuestX 4500 `
    -GuestY 30500 `
    -RoiWidth 700 `
    -RoiHeight 460 `
    -OutDir $OutDir
