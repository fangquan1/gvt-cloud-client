# GVT Cloud Client Console

This folder contains the first runnable client shell for the GVT cloud desktop
client. It is deliberately self-contained so it can run with mock data before
the server repository is finished, then switch to the real HTTP API for
integration.

## Run

```powershell
npm install
npm run build
```

Open `dist/index.html` in a browser.

## Test

```powershell
npm test
```

## Current scope

- Server configuration without storing passwords or tokens in `localStorage`.
- Mock/real API switch for the required `/api/*` endpoints.
- Desktop list, search, status filters, details panel, mode switching, start,
  stop, restart, physical-output selection, and safe log summaries.
- Viewer launch plan generation for the existing `gvt_spice_viewer` path.
- Default video settings remain on the known-good path: 15 ms latency, no FEC,
  no `drop-on-latency`, native input enabled, and `--invert-case` retained.

Runtime binaries, GStreamer, SPICE DLLs, logs, credentials, and VM images are
not part of this source folder.
