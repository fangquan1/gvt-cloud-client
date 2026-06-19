# GVT Cloud Client

Native Windows client for the current GVT-g cloud desktop route.

This repository keeps only the Win32 shell and portable client path:

- `native-launcher/gvt_cloud_client.c`: the first-window Win32 launcher.
- `src/gvt_spice_viewer.c`: embedded video, SPICE audio/session, and native input.
- `scripts/package-portable.mjs`: builds and assembles the portable folder.

Removed from `current`: Python client prototypes, input overlay scripts,
standalone RTP receive scripts, old batch launchers, and historical docs. Those
remain available in Git history if needed for reference.

Start with [CLIENT.md](CLIENT.md).
