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
- `install-gvt-guest-test-agent.ps1` installs a small Windows guest helper
  through QGA. The helper shows a green `GVT_READY` marker after desktop logon
  and accepts audio/AV test commands from QGA.
- `wait-gvt-guest-ready.ps1` waits for QGA, `explorer.exe`/`dwm.exe`, and the
  client-visible `GVT_READY` marker before desktop automation starts.
- `measure-gvt-audio-quality.ps1` records the client machine's WASAPI loopback
  audio while the guest helper plays a deterministic 20 second reference clip,
  then reports clipping, dropouts, pulse drift, correlation, SNR, and
  crackle/pop candidates. It also writes SVG waveform charts, an FFT spectrum
  comparison chart, and CSV/JSON waveform/spectrum data under the audio run
  directory.
- `measure-gvt-av-sync.ps1` runs a flash+click pattern from the guest helper and
  estimates audio-minus-video timing from client-side ROI samples and loopback
  audio. Treat its absolute offset as diagnostic because audio sample-zero is
  estimated from the local recorder start time.
- `run-gvt-full-test.ps1` orchestrates the complete local acceptance run:
  optional helper install, optional guest reboot, QGA desktop readiness, stream
  smoke, marker readiness, audio quality, AV sync, and input-to-video latency.
  It writes `full.log`, `status.json`, per-stage logs, a Chinese Markdown
  report, and a Chinese HTML report under
  `test_output\data\full-YYYYMMDD-HHMMSS`. Each stage has an explicit timeout
  and a heartbeat line so a long run can be inspected without attaching a
  debugger or polling guest state manually. The smoke stage leaves the viewer
  open for later tests, so the orchestrator does not pipe-capture smoke
  stdout/stderr; this avoids a stuck EOF wait when the viewer inherits console
  handles.

By default the performance scripts use project-local runtimes:

```text
tools\gstreamer-1.0-mingw-x86_64-1.18.6\gstreamer\1.0\mingw_x86_64
runtime\virtviewer\bin
```

## Examples

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\run-gvt-full-test.ps1 -BatchMode
```

The main report is `test_output\data\full-YYYYMMDD-HHMMSS\report.html`. The
same run directory keeps raw data under subdirectories such as
`audio-quality`, `video-performance`, `av-sync`, and `latency-captures`.
The HTML report is Chinese-only and includes metric help markers (`?`), simple
好/良好/差 ratings, waveform charts, pop-score charts, and spectrum comparison
charts. The default input-latency trigger is `Win+R`; pass
`-LatencyTriggerProfile right-click-upper` to switch that stage to a right-click
test in the upper-right desktop area. Because `Win+R` includes Windows Run UI
startup time and is intentionally conservative, the default report rating treats
input-to-video median latency `<= 1200 ms` as passing/良好; tune this with
`-LatencyGoodMs` and `-LatencyPassMs` if a different trigger profile needs a
tighter line.

Useful full-run knobs:

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\run-gvt-full-test.ps1 `
  -BatchMode `
  -DesktopTimeoutSec 180 `
  -SmokeTimeoutSec 180 `
  -AudioTimeoutSec 180 `
  -AvSyncTimeoutSec 180 `
  -LatencyTimeoutSec 180 `
  -StageHeartbeatSec 5
```

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

Install the guest-side desktop/audio helper once:

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\install-gvt-guest-test-agent.ps1
```

The installer can read local defaults from `secrets\gvt-test-guest.ps1`, which
is ignored by git. The credentialed install creates an interactive `ONLOGON`
scheduled task for the test user and can configure Windows AutoAdminLogon.
AutoAdminLogon stores the test account password in the guest registry, so use a
dedicated test-only account. If the green `GVT_READY` marker does not appear
immediately, reboot or log off/on once so the task runs inside the interactive
desktop session.
`-StartNow` is only a best-effort QGA launch and may run in a non-interactive
service session, so the reboot/logon path is the reliable one.
Then wait for the desktop before running visual automation:

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\wait-gvt-guest-ready.ps1 `
  -WindowProcessName gvt_spice_viewer
```

Record and analyze the SPICE audio path:

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\measure-gvt-audio-quality.ps1
```

By default the audio script fails on missing pulses, clipping, dropouts, and
pulse drift. It also fails on detected pop/crackle candidates by default
(`-MaxPopEvents 0 -MaxSeverePopEvents 0`). Raw waveform correlation/SNR are
reported as advisory because the Windows audio engine, SPICE path, and loopback
capture can introduce phase and mixing differences; pass `-RequireWaveformMatch`
only when you want a stricter same-device reference comparison. Frequency-domain
comparison is also advisory; it is saved as `spectrum-comparison.svg` and
`spectrum-data.csv` under the audio `waveform-analysis` directory.

Estimate sound-to-picture timing with the flash+click pattern:

```powershell
powershell -ExecutionPolicy Bypass -File test-tools\measure-gvt-av-sync.ps1 `
  -WindowProcessName gvt_spice_viewer
```
