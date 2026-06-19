import { copyFileSync, cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const repoRoot = path.resolve(scriptDir, "..");
const workspaceRoot = path.resolve(repoRoot, "..");
const outRoot = path.resolve(repoRoot, "build", "gvt-cloud-client-portable");
const allowMissingRuntime = process.env.GVT_ALLOW_MISSING_RUNTIME === "1";

function copyIfExists(src, dest) {
  if (!src || !existsSync(src)) {
    return false;
  }
  mkdirSync(path.dirname(dest), { recursive: true });
  cpSync(src, dest, { recursive: true });
  return true;
}

function firstExisting(paths) {
  return paths.find((item) => item && existsSync(item));
}

function copyRequired(src, dest, label) {
  if (copyIfExists(src, dest)) {
    return;
  }
  const message = `${label} was not found. Set the documented environment variable or install the runtime before packaging.`;
  if (allowMissingRuntime) {
    console.warn(message);
    return;
  }
  throw new Error(message);
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

run("powershell", ["-ExecutionPolicy", "Bypass", "-File", path.join(repoRoot, "src", "build-viewer.ps1")], repoRoot);
run("powershell", ["-ExecutionPolicy", "Bypass", "-File", path.join(repoRoot, "native-launcher", "build.ps1")], repoRoot);

rmSync(outRoot, { recursive: true, force: true });
mkdirSync(outRoot, { recursive: true });
mkdirSync(path.join(outRoot, "app"), { recursive: true });

const viewerExe = path.join(repoRoot, "build", "viewer", "gvt_spice_viewer.exe");
copyRequired(viewerExe, path.join(outRoot, "app", "viewer", "gvt_spice_viewer.exe"), "gvt_spice_viewer.exe");

copyFileSync(
  path.join(repoRoot, "build", "native-launcher", "GVT Cloud Client.exe"),
  path.join(outRoot, "GVT Cloud Client.exe")
);

const gstRoot = firstExisting([
  path.join(repoRoot, "tools", "gstreamer-1.0-mingw-x86_64-1.18.6"),
  process.env.GVT_GSTREAMER_ROOT,
  path.join(workspaceRoot, "tools", "gstreamer-1.0-mingw-x86_64-1.18.6"),
]);
copyRequired(
  gstRoot,
  path.join(outRoot, "tools", "gstreamer-1.0-mingw-x86_64-1.18.6"),
  "GStreamer Windows runtime"
);

const spiceRuntime = firstExisting([
  path.join(repoRoot, "runtime", "virtviewer", "bin"),
  process.env.GVT_SPICE_RUNTIME,
  "C:\\Program Files\\VirtViewer v11.0-256\\bin"
]);
copyRequired(spiceRuntime, path.join(outRoot, "runtime", "virtviewer", "bin"), "VirtViewer/SPICE runtime");

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
and the SPICE/GStreamer runtimes copied from the packaging machine.
`;
writeFileSync(path.join(outRoot, "README.txt"), readme);

console.log(`Portable client written to ${outRoot}`);
