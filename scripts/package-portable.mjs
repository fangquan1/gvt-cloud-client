import { copyFileSync, cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const workspaceRoot = path.resolve(repoRoot, "..", "..");
const outRoot = path.resolve(repoRoot, "build", "gvt-cloud-client-portable");

function copyIfExists(src, dest) {
  if (!existsSync(src)) {
    return false;
  }
  mkdirSync(path.dirname(dest), { recursive: true });
  cpSync(src, dest, { recursive: true });
  return true;
}

function run(command, args, cwd) {
  const result = spawnSync(command, args, { cwd, stdio: "inherit" });
  if (result.error) {
    console.error(result.error.message);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

run("powershell", ["-ExecutionPolicy", "Bypass", "-File", path.join(repoRoot, "native-launcher", "build.ps1")], repoRoot);

rmSync(outRoot, { recursive: true, force: true });
mkdirSync(outRoot, { recursive: true });
mkdirSync(path.join(outRoot, "app"), { recursive: true });

const builtViewerExe = path.join(repoRoot, "src", "gvt_spice_viewer.exe");
const legacyViewerExe = path.join(workspaceRoot, "direct-stream", "client", "gvt_spice_viewer.exe");
const viewerExe = process.env.GVT_VIEWER_EXE || (existsSync(builtViewerExe) ? builtViewerExe : legacyViewerExe);
copyIfExists(viewerExe, path.join(outRoot, "app", "viewer", "gvt_spice_viewer.exe"));

copyFileSync(
  path.join(repoRoot, "build", "native-launcher", "GVT Cloud Client.exe"),
  path.join(outRoot, "GVT Cloud Client.exe")
);

const gstRoot = process.env.GVT_GSTREAMER_ROOT ||
  path.join(workspaceRoot, "tools", "gstreamer-1.0-mingw-x86_64-1.18.6");
copyIfExists(gstRoot, path.join(outRoot, "tools", "gstreamer-1.0-mingw-x86_64-1.18.6"));

const spiceRuntime = process.env.GVT_SPICE_RUNTIME ||
  "C:\\Program Files\\VirtViewer v11.0-256\\bin";
copyIfExists(spiceRuntime, path.join(outRoot, "runtime", "virtviewer", "bin"));

const portableViewer = path.join(outRoot, "app", "viewer", "gvt_spice_viewer.exe");
const portableGstRoot = path.join(outRoot, "tools", "gstreamer-1.0-mingw-x86_64-1.18.6", "gstreamer", "1.0", "mingw_x86_64");
if (existsSync(portableViewer) && existsSync(portableGstRoot) && process.env.GVT_SKIP_GST_WARMUP !== "1") {
  console.log("Prewarming GStreamer registry...");
  const warmup = spawnSync(portableViewer, ["--gst-warmup", "--gst-root", portableGstRoot], {
    cwd: path.dirname(portableViewer),
    stdio: "inherit",
    windowsHide: true
  });
  if (warmup.error) {
    console.warn(`GStreamer warmup failed to launch: ${warmup.error.message}`);
  } else if (warmup.status !== 0) {
    console.warn(`GStreamer warmup exited with status ${warmup.status}`);
  }
}

const readme = `GVT Cloud Client Portable
=========================

Run:
  GVT Cloud Client.exe

The first screen accepts a server address like:
  192.168.0.188:5004

Current port convention:
  5004 video, 5900 SPICE audio/session, 5905 native input
  5008 video, 5901 SPICE audio/session, 5906 native input

This portable folder contains only the native launcher, gvt_spice_viewer.exe,
and the SPICE/GStreamer runtimes when they are found on the packaging machine.
`;
writeFileSync(path.join(outRoot, "README.txt"), readme);

console.log(`Portable client written to ${outRoot}`);
