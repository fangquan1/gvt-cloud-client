import { copyFileSync, cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawnSync } from "node:child_process";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const consoleRoot = path.resolve(scriptDir, "..");
const repoRoot = path.resolve(consoleRoot, "..");
const workspaceRoot = path.resolve(repoRoot, "..", "..");
const outRoot = path.resolve(repoRoot, "build", "gvt-cloud-client-portable");
const distRoot = path.join(consoleRoot, "dist");

function copyIfExists(src, dest) {
  if (!existsSync(src)) {
    return false;
  }
  mkdirSync(path.dirname(dest), { recursive: true });
  cpSync(src, dest, { recursive: true });
  return true;
}

function run(command, args, cwd) {
  const executable = process.platform === "win32" && command === "npm" ? process.env.ComSpec || "cmd.exe" : command;
  const finalArgs = process.platform === "win32" && command === "npm" ? ["/d", "/s", "/c", "npm", ...args] : args;
  const result = spawnSync(executable, finalArgs, { cwd, stdio: "inherit" });
  if (result.error) {
    console.error(result.error.message);
  }
  if (result.status !== 0) {
    process.exit(result.status ?? 1);
  }
}

run("npm", ["run", "build"], consoleRoot);
run("powershell", ["-ExecutionPolicy", "Bypass", "-File", path.join(repoRoot, "native-launcher", "build.ps1")], repoRoot);

rmSync(outRoot, { recursive: true, force: true });
mkdirSync(outRoot, { recursive: true });
mkdirSync(path.join(outRoot, "app"), { recursive: true });
mkdirSync(path.join(outRoot, "app", "scripts"), { recursive: true });

cpSync(distRoot, path.join(outRoot, "app", "dist"), { recursive: true });
copyFileSync(path.join(scriptDir, "launcher-server.mjs"), path.join(outRoot, "app", "scripts", "launcher-server.mjs"));

const builtViewerExe = path.join(repoRoot, "src", "gvt_spice_viewer.exe");
const legacyViewerExe = path.join(workspaceRoot, "direct-stream", "client", "gvt_spice_viewer.exe");
const viewerExe = process.env.GVT_VIEWER_EXE || (existsSync(builtViewerExe) ? builtViewerExe : legacyViewerExe);
copyIfExists(viewerExe, path.join(outRoot, "app", "viewer", "gvt_spice_viewer.exe"));

copyFileSync(
  path.join(repoRoot, "build", "native-launcher", "GVT Cloud Client.exe"),
  path.join(outRoot, "GVT Cloud Client.exe")
);

const nodeExe = process.execPath;
copyIfExists(nodeExe, path.join(outRoot, "runtime", "node", "node.exe"));

const gstRoot = process.env.GVT_GSTREAMER_ROOT ||
  path.join(workspaceRoot, "tools", "gstreamer-1.0-mingw-x86_64-1.18.6");
copyIfExists(gstRoot, path.join(outRoot, "tools", "gstreamer-1.0-mingw-x86_64-1.18.6"));

const spiceRuntime = process.env.GVT_SPICE_RUNTIME ||
  "C:\\Program Files\\VirtViewer v11.0-256\\bin";
copyIfExists(spiceRuntime, path.join(outRoot, "runtime", "virtviewer", "bin"));

rmSync(path.join(outRoot, "app", "dist", "test"), { recursive: true, force: true });

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

const bat = String.raw`@echo off
setlocal
cd /d "%~dp0"

set "GVT_CLIENT_HOME=%~dp0"
set "GVT_VIEWER_EXE=%GVT_CLIENT_HOME%app\viewer\gvt_spice_viewer.exe"
set "GVT_CONSOLE_HOST=127.0.0.1"
set "GVT_CONSOLE_PORT=5177"

if exist "%GVT_CLIENT_HOME%runtime\node\node.exe" (
  set "NODE_EXE=%GVT_CLIENT_HOME%runtime\node\node.exe"
) else (
  set "NODE_EXE=node.exe"
)

start "GVT Cloud Client Service" /min "%NODE_EXE%" "%GVT_CLIENT_HOME%app\scripts\launcher-server.mjs"
powershell -NoProfile -Command "Start-Sleep -Milliseconds 800; Start-Process 'http://127.0.0.1:5177/'"
`;
writeFileSync(path.join(outRoot, "Open Web Console.bat"), bat.replaceAll("\n", "\r\n"));

const readme = `GVT Cloud Client Portable
=========================

Run:
  GVT Cloud Client.exe

The first screen accepts a server address like:
  192.168.0.188:5004

Current port convention:
  5004 video, 5900 SPICE audio/session, 5905 native input
  5008 video, 5901 SPICE audio/session, 5906 native input

This portable folder contains the web console, local launcher, node runtime
when available, gvt_spice_viewer.exe when available at packaging time, and the
SPICE/GStreamer runtimes when they are found on the packaging machine.

Open Web Console.bat is a fallback management console. Ordinary users should
start with GVT Cloud Client.exe.
`;
writeFileSync(path.join(outRoot, "README.txt"), readme);

console.log(`Portable client written to ${outRoot}`);
