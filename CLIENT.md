# GVT Cloud Client Notes

## Purpose

This repository builds the Windows portable client for the current GVT-g cloud
desktop route. The product entry point is a native Win32 launcher that starts
`gvt_spice_viewer.exe` with the right video, SPICE, input, and runtime paths.

The client talks to the patched QEMU `gvt-stream` backend:

```text
QEMU gvt-stream RTP video -> GStreamer D3D11 video sink
QEMU SPICE audio/session  -> spice-client-glib from VirtViewer
QEMU native input TCP     -> gvt_spice_viewer.exe
```

## Kept Files

- `native-launcher/gvt_cloud_client.c`: Win32 launcher UI.
- `native-launcher/build.ps1`: builds `GVT Cloud Client.exe`.
- `src/gvt_spice_viewer.c`: native viewer process.
- `src/build-viewer.ps1`: builds `gvt_spice_viewer.exe`.
- `scripts/package-portable.mjs`: builds and packages the portable client.

The old Python client, Python input overlay, diagnostic RTP receiver scripts,
and start/stop batch files are intentionally not part of `current`.

## Build Dependencies

Install these on the Windows packaging machine:

- Git.
- Node.js 18 or newer.
- MinGW-w64 GCC. The build scripts first try
  `C:\Program Files\mingw64\bin\gcc.exe`, then fall back to `gcc.exe` in `PATH`.
- GStreamer Windows runtime used by the current client:
  `gstreamer-1.0-mingw-x86_64-1.18.6`.
- VirtViewer runtime with SPICE client DLLs, tested with VirtViewer v11.0-256.

## Runtime Assets Required For Running

Important for fresh clones: the GStreamer and VirtViewer/SPICE runtimes are
large binary dependencies and are intentionally not committed to Git. The code
can compile without them, but running `gvt_spice_viewer.exe`, running the smoke
tests, or packaging the portable client will fail until these directories exist:

```text
tools\gstreamer-1.0-mingw-x86_64-1.18.6
runtime\virtviewer\bin
```

Expected contents:

```text
tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64\bin
tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64\lib\gstreamer-1.0
runtime\virtviewer\bin\spice-client-glib-2.0-8.dll
runtime\virtviewer\bin\glib-2.0-0.dll
```

How to populate them on a development machine:

```powershell
mkdir tools
mkdir runtime\virtviewer

# Copy or extract the GStreamer mingw_x86_64 runtime here:
# tools\gstreamer-1.0-mingw-x86_64-1.18.6\...

# If VirtViewer is installed locally, copy its bin directory into the repo:
robocopy "C:\Program Files\VirtViewer v11.0-256\bin" runtime\virtviewer\bin /E
```

These folders are ignored by `.gitignore`, so keeping local copies here will
not accidentally add hundreds of MB of runtime DLLs to commits.

If you need to use a different runtime without copying it into the repo, point
the package script or test scripts at it with environment variables:

```powershell
$env:GVT_GSTREAMER_ROOT = "C:\path\to\gstreamer-1.0-mingw-x86_64-1.18.6"
$env:GVT_SPICE_RUNTIME = "C:\Program Files\VirtViewer v11.0-256\bin"
```

`GVT_GSTREAMER_ROOT` should be the directory that contains:

```text
gstreamer\1.0\mingw_x86_64\bin
gstreamer\1.0\mingw_x86_64\lib\gstreamer-1.0
```

If `GVT_GSTREAMER_ROOT` is not set, the package script checks:

```text
<repo>\tools\gstreamer-1.0-mingw-x86_64-1.18.6
<parent-workspace>\tools\gstreamer-1.0-mingw-x86_64-1.18.6
```

If these paths are missing, typical failures are `Failed to load GStreamer
runtime DLLs`, `Failed to load VirtViewer SPICE runtime DLLs`, or a packaging
error saying the GStreamer/SPICE runtime was not found.

## Build Portable Client

From a fresh clone:

```powershell
git clone https://github.com/fangquan1/gvt-cloud-client.git
cd gvt-cloud-client

node scripts/package-portable.mjs
```

Output:

```text
build\gvt-cloud-client-portable\
  GVT Cloud Client.exe
  app\viewer\gvt_spice_viewer.exe
  runtime\virtviewer\bin\...
  tools\gstreamer-1.0-mingw-x86_64-1.18.6\...
  README.txt
```

The package script also prewarms the GStreamer registry through
`gvt_spice_viewer.exe --gst-warmup`. To skip that during CI or diagnostics:

```powershell
$env:GVT_SKIP_GST_WARMUP = "1"
node scripts/package-portable.mjs
```

For compile-only checks without copying runtimes:

```powershell
powershell -ExecutionPolicy Bypass -File src\build-viewer.ps1
powershell -ExecutionPolicy Bypass -File native-launcher\build.ps1
```

`GVT_ALLOW_MISSING_RUNTIME=1 node scripts/package-portable.mjs` is available
only for local smoke tests; it does not produce a truly portable client.

## Run

On the client machine, open:

```text
build\gvt-cloud-client-portable\GVT Cloud Client.exe
```

Enter a server endpoint and click `Connect`:

```text
192.168.0.188:5004
```

Port convention:

- `5004`: stream control TCP and video RTP UDP.
- `5900`: SPICE audio/session.
- `5905`: native input TCP.

For additional VMs, ports advance in slots of four:

```text
5008 -> SPICE 5901, input 5906
5012 -> SPICE 5902, input 5907
```

The launcher stores recent endpoints in `gvt_client_history.txt` next to the
portable executable.

### Guest Power Policy During Current Testing

For the current `current-detach` external encoder experiment, the Windows guest
is configured with both "turn off screen" and "sleep" set to `Never`. Manual and
automated client validation therefore assumes the guest desktop stays awake
while connected or between short reconnects.

Suspend/display-sleep reconnect behavior is not part of the active client
acceptance scope while this guest power policy is in place. Re-enable the
no-scanout/suspend reconnect cases if the guest power policy is changed back to
allow display sleep or system sleep.

## Direct Viewer Diagnostics

Normally use `GVT Cloud Client.exe`. For debugging, run the viewer directly:

```powershell
.\app\viewer\gvt_spice_viewer.exe `
  --video-codec h264 `
  --video-port 5004 `
  --latency 15 `
  --spice-host 192.168.0.188 `
  --spice-port 5900 `
  --native-input `
  --input-host 192.168.0.188 `
  --input-port 5905 `
  --stream-control-host 192.168.0.188 `
  --stream-control-port 5004 `
  --gst-root .\tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64 `
  --spice-runtime .\runtime\virtviewer\bin `
  --source-width 1920 `
  --source-height 1200 `
  --auto-size
```

Logs:

- `gvt_client_debug.log`: launcher log.
- `app\viewer\gvt_spice_viewer.log`: viewer, GStreamer, SPICE, and control log.

## Video Performance Smoke Test

`test-tools\run-gvt-stream-smoke.ps1` follows the Sunshine/Moonlight-style
model of collecting built-in stream metrics instead of relying on an external
benchmark binary. It launches `gvt_spice_viewer`, parses client-side
`video-probe fps` lines, samples the remote QEMU `update-stats` log over SSH,
and writes `summary.json`, `summary.csv`, `report.md`, `viewer.log`, and
`server.log`.

Example:

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\run-gvt-stream-smoke.ps1 `
  -DurationSec 20 `
  -WarmupSec 3 `
  -LeaveWindowOpen `
  -StopExistingViewer
```

Outputs go to `build\video-performance\smoke-*` by default. A passing local
60 FPS run should have steady `depay_out`, `parse_out`, and `decode_out` near
the guest refresh rate, plus server `encode_failures_last=0`.

## Video-After-Input Latency Test

`test-tools\measure-gvt-video-latency.ps1` measures the latency from an input
trigger to the first visible client-side video change in a selected region. It
is an end-to-end acceptance number for "input caused a visible video reaction",
not a pure keyboard/mouse dispatch benchmark.

Before running it:

- Start the portable client and connect to the VM.
- Keep the viewer window visible and unobstructed.
- Put the guest in a state where the trigger causes an obvious visual change.
  A right-click on the Windows desktop is the simplest test because it opens a
  context menu.
- Use the same guest resolution passed to the viewer, normally `1920x1200`.

Example, using the native input TCP channel on port `5905`:

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\measure-gvt-video-latency.ps1 `
  -WindowProcessName gvt_spice_viewer `
  -InputHost 192.168.0.188 `
  -InputPort 5905 `
  -UseVideoArea `
  -SourceWidth 1920 `
  -SourceHeight 1200 `
  -ToolbarHeight 32 `
  -OpenAction click `
  -OpenButton right `
  -GuestX 16384 `
  -GuestY 16384 `
  -Trials 5 `
  -OutDir build\latency-captures
```

Useful variants:

```powershell
# Send a local Windows click into the viewer instead of the TCP input channel.
powershell -ExecutionPolicy Bypass -File test-tools\measure-gvt-video-latency.ps1 `
  -Trigger local -WindowProcessName gvt_spice_viewer -UseVideoArea

# Measure a different region or make detection stricter/looser.
powershell -ExecutionPolicy Bypass -File test-tools\measure-gvt-video-latency.ps1 `
  -GuestX 12000 -GuestY 8000 -RoiWidth 500 -RoiHeight 420 `
  -MinChangedThreshold 700
```

Outputs go to `build\latency-captures` by default:

- `results.csv`: trial number, latency, changed pixel count, trigger time, and
  detection time.
- `trial-*-baseline.png`: captured ROI before the trigger.
- `trial-*-detected.png`: first captured ROI that crossed the change threshold.

For log correlation, compare the script's `trigger_ts` with:

- `app\viewer\gvt_spice_viewer.log`: `latency-input-send` and
  `latency-input-dispatch`.
- Server QEMU log: `latency-input-recv` and `latency-video-after-input`.

If the script cannot find the window, check `-WindowProcessName`. If it reports
no detection, confirm the trigger opens visible UI, move `-GuestX/-GuestY` into
the changed area, or raise `-MaxWaitMs`. If it detects too early, raise
`-MinChangedThreshold` or shrink the ROI.

## Runtime Notes

- The viewer sends `start` to the server only after the local GStreamer
  receiver is ready, so reconnect does not ask the server to encode too early.
- Closing the viewer closes the stream-control session; the server should stop
  encoding.
- The current default latency is `15 ms` and `drop-on-latency=false`, matching
  the low-latency no-green-frame baseline.
- SPICE is used for audio/session only. Primary video comes from QEMU
  `gvt-stream` RTP.
