# GVT Cloud Client Test Tools

This folder keeps local measurement and smoke-test helpers for the current
host/QEMU streaming route.

## Reference model from Sunshine and Moonlight

Moonlight does not rely on a separate benchmark binary for the common remote
video numbers. Its Qt client keeps `VIDEO_STATS` in
`app/streaming/video/decoder.h` and renders/logs them from
`app/streaming/video/ffmpeg.cpp`: incoming FPS, decoded FPS, rendered FPS,
network/jitter drops, host processing latency, reassembly time, decode time,
pacer queue delay, render time, RTT, and bitrate.

Sunshine exposes the complementary service-side view from `src/stream.cpp`.
Its video broadcast path periodically logs frame processing latency, send-batch
latency, FEC block latency, and whole-frame network latency. It also stamps a
frame processing latency field into its video frame header for the client side
to consume.

Our scripts mirror that split:

- `measure-gvt-video-performance.ps1` launches `gvt_spice_viewer` with client
  video probes enabled, parses `video-probe fps` from `gvt_spice_viewer.log`,
  and samples the remote QEMU `update-stats` log over SSH when available.
- `run-gvt-stream-smoke.ps1` wraps the measurement script with acceptance
  thresholds for steady depay/decode FPS, startup markers, and encode failures.
- `measure-gvt-video-latency.ps1` measures video-after-input latency from a
  trigger to the first visible client-side frame change in a selected region.

By default the performance scripts use project-local runtimes:

```text
tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64
runtime\virtviewer\bin
```

## Examples

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\run-gvt-stream-smoke.ps1 `
  -DurationSec 20 `
  -LeaveWindowOpen `
  -StopExistingViewer
```

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\measure-gvt-video-performance.ps1 `
  -DurationSec 30 `
  -OutDir build\video-performance\manual
```

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\measure-gvt-video-latency.ps1 `
  -WindowProcessName gvt_spice_viewer `
  -UseVideoArea `
  -Trials 5
```
