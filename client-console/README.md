# GVT Cloud Client Console

This folder contains the first runnable client shell for the GVT cloud desktop
client. It is deliberately self-contained so it can run with mock data before
the server repository is finished, then switch to the real HTTP API for
integration.

## Run

```powershell
npm install
npm run serve
```

Open `http://127.0.0.1:5177/` in a browser. The local launcher service serves
the console and exposes `/launch-viewer`, which starts the existing
`direct-stream/client/gvt_spice_viewer.exe` with the selected desktop ports and
resolution.

For a no-install folder build:

```powershell
npm run portable
```

The portable output is written to `../build/gvt-cloud-client-portable/`. Launch
it with `GVT Cloud Client.exe`. `Open Web Console.bat` remains as an optional
management-console fallback, but ordinary users should not need it. Source
control keeps the packaging recipe, not the generated runtime binaries.

The first screen also supports direct connection, closer to SPICE/VNC habits:
enter `host:port` such as `192.168.0.188:5004` and click Connect. The client
remembers recent addresses in `localStorage`. For the current RTP transport the
port is the gvt-stream video port; companion ports are derived from the current
VM convention:

- `5004 -> video`, `5900 -> SPICE audio/session`, `5905 -> native input`
- `5006 -> video`, `5901 -> SPICE audio/session`, `5906 -> native input`

## Test

```powershell
npm test
```

## Current scope

- Server configuration without storing passwords or tokens in `localStorage`.
- Mock/real API switch for the required `/api/*` endpoints.
- Desktop list, search, status filters, details panel, mode switching, start,
  stop, restart, physical-output selection, and safe log summaries.
- Direct launch of the existing `gvt_spice_viewer` path through the local
  launcher helper, with the old viewer plan modal kept as a failure fallback.
- Direct `host:port` connection history for a portable, viewer-like workflow.
- Default video settings remain on the known-good path: 15 ms latency, no FEC,
  no `drop-on-latency`, H.265 by default, native input enabled, and
  `--invert-case` retained.

Runtime binaries, GStreamer, SPICE DLLs, logs, credentials, and VM images are
not part of this source folder.
