# GVT Cloud Client

Windows client for the GVT-g cloud desktop project.

Target repository: `https://github.com/fangquan1/gvt-cloud-client`

Main source:

- `native-launcher/gvt_cloud_client.c`
- `src/gvt_spice_viewer.c`
- `scripts/package-portable.mjs`

Current baseline:

- Video: QEMU `gvt-stream` H.264 RTP.
- Audio/session: SPICE playback via `spice-client-glib`.
- Input: QEMU native TCP input, with the current overlay path retained.
- UI: native Win32 launcher plus native viewer. The old web console/prototype
  has been removed.

Build the portable client with:

```powershell
node scripts/package-portable.mjs
```

or:

```bat
scripts\build-portable-client.bat
```

Do not commit runtime binaries, logs, VM images, passwords, or private server
configuration.
