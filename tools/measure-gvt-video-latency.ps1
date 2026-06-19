param(
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ForwardArgs
)

$script:Target = Join-Path (Split-Path -Parent $PSScriptRoot) "test-tools\measure-gvt-video-latency.ps1"
& $script:Target @ForwardArgs
exit $LASTEXITCODE
