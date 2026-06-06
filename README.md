# GVT Cloud Client

Windows client for the GVT-g cloud desktop project.

Target repository: `https://github.com/fangquan1/gvt-cloud-client`

Start with:

- `docs/CLIENT_REQUIREMENTS.md`
- `prototype/ui-test/`
- `src/gvt_spice_viewer.c`

Current baseline:

- Video: QEMU `gvt-stream` H.264 RTP.
- Audio/session: SPICE playback via `spice-client-glib`.
- Input: QEMU native TCP input, with the current overlay path retained.
- UI: based on the `ui-test` desktop console prototype.

Do not commit runtime binaries, logs, VM images, passwords, or private server
configuration.
