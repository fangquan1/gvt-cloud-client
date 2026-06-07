import { createServer } from "node:http";
import { createReadStream, existsSync } from "node:fs";
import { stat } from "node:fs/promises";
import path from "node:path";
import { spawn } from "node:child_process";
import { fileURLToPath } from "node:url";

const scriptDir = path.dirname(fileURLToPath(import.meta.url));
const consoleRoot = path.resolve(scriptDir, "..");
const distRoot = path.join(consoleRoot, "dist");
const workspaceRoot = path.resolve(consoleRoot, "..", "..", "..");
const viewerExe = process.env.GVT_VIEWER_EXE || path.join(workspaceRoot, "direct-stream", "client", "gvt_spice_viewer.exe");
const port = Number(process.env.GVT_CONSOLE_PORT || 5177);
const host = process.env.GVT_CONSOLE_HOST || "127.0.0.1";

const mimeTypes = new Map([
  [".css", "text/css; charset=utf-8"],
  [".html", "text/html; charset=utf-8"],
  [".js", "text/javascript; charset=utf-8"],
  [".json", "application/json; charset=utf-8"],
  [".png", "image/png"],
  [".svg", "image/svg+xml"],
  [".webp", "image/webp"]
]);

const allowedArgs = new Map([
  ["--spice-host", true],
  ["--spice-port", true],
  ["--input-host", true],
  ["--input-port", true],
  ["--source-width", true],
  ["--source-height", true],
  ["--latency", true],
  ["--video-port", true],
  ["--no-drop-on-latency", false],
  ["--native-input", false],
  ["--spice-input", false],
  ["--spice-display", false],
  ["--invert-case", false]
]);

function sendJson(response, status, payload) {
  response.writeHead(status, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store"
  });
  response.end(JSON.stringify(payload));
}

function isLoopback(address) {
  return address === "127.0.0.1" || address === "::1" || address === "::ffff:127.0.0.1";
}

function normalizeArgs(args) {
  if (!Array.isArray(args)) {
    throw new Error("启动参数格式不对");
  }
  const normalized = [];
  for (let index = 0; index < args.length; index += 1) {
    const flag = String(args[index] ?? "");
    if (!allowedArgs.has(flag)) {
      throw new Error(`不允许的客户端参数: ${flag}`);
    }
    normalized.push(flag);
    if (allowedArgs.get(flag)) {
      index += 1;
      if (index >= args.length) {
        throw new Error(`客户端参数缺少值: ${flag}`);
      }
      const value = String(args[index] ?? "");
      if (!value || value.length > 128 || value.includes("\0")) {
        throw new Error(`客户端参数值无效: ${flag}`);
      }
      normalized.push(value);
    }
  }
  return normalized;
}

function normalizeSpiceInstallPayload(payload) {
  const title = String(payload.title || "GVT Install Console").slice(0, 80);
  const args = normalizeArgs(payload.args);
  const spiceHostIndex = args.indexOf("--spice-host");
  const spicePortIndex = args.indexOf("--spice-port");
  if (spiceHostIndex < 0 || spicePortIndex < 0) {
    throw new Error("SPICE 安装控制台缺少服务器或端口");
  }
  const spiceHost = args[spiceHostIndex + 1];
  const spicePort = args[spicePortIndex + 1];
  if (!/^[A-Za-z0-9.:-]+$/.test(spiceHost) || !/^[0-9]+$/.test(spicePort)) {
    throw new Error("SPICE 安装控制台地址无效");
  }
  return [...args, "--spice-display", "--spice-input"];
}

async function readBody(request) {
  const chunks = [];
  let size = 0;
  for await (const chunk of request) {
    size += chunk.length;
    if (size > 16 * 1024) {
      throw new Error("请求太大");
    }
    chunks.push(chunk);
  }
  return Buffer.concat(chunks).toString("utf8");
}

async function launchViewer(request, response) {
  if (!isLoopback(request.socket.remoteAddress)) {
    sendJson(response, 403, { error: "本地启动器只接受本机请求" });
    return;
  }
  try {
    const body = await readBody(request);
    const payload = JSON.parse(body);
    const viewerKind = String(payload.viewerKind || "gvt-stream");
    const exe = viewerExe;
    if (!existsSync(exe)) {
      sendJson(response, 500, { error: `找不到本地客户端: ${exe}` });
      return;
    }
    const args = viewerKind === "spice-install"
      ? normalizeSpiceInstallPayload(payload)
      : normalizeArgs(payload.args);
    const child = spawn(exe, args, {
      cwd: path.dirname(exe),
      detached: true,
      stdio: "ignore",
      windowsHide: false
    });
    child.unref();
    sendJson(response, 200, { ok: true, pid: child.pid });
  } catch (error) {
    sendJson(response, 400, { error: error instanceof Error ? error.message : String(error) });
  }
}

async function serveStatic(request, response) {
  const requestUrl = new URL(request.url || "/", `http://${request.headers.host || "localhost"}`);
  const relativePath = decodeURIComponent(requestUrl.pathname === "/" ? "/index.html" : requestUrl.pathname);
  const target = path.resolve(distRoot, `.${relativePath}`);
  if (!target.startsWith(distRoot)) {
    response.writeHead(403);
    response.end("Forbidden");
    return;
  }

  const fallback = path.join(distRoot, "index.html");
  const filePath = existsSync(target) ? target : fallback;
  try {
    const info = await stat(filePath);
    if (!info.isFile()) {
      response.writeHead(404);
      response.end("Not found");
      return;
    }
    const ext = path.extname(filePath).toLowerCase();
    response.writeHead(200, {
      "Content-Type": mimeTypes.get(ext) || "application/octet-stream",
      "Cache-Control": ext === ".html" ? "no-store" : "no-cache"
    });
    createReadStream(filePath).pipe(response);
  } catch {
    response.writeHead(404);
    response.end("Not found");
  }
}

const server = createServer((request, response) => {
  if (request.method === "GET" && request.url === "/health") {
    sendJson(response, 200, { ok: true, viewerExe });
    return;
  }
  if (request.method === "POST" && request.url === "/launch-viewer") {
    void launchViewer(request, response);
    return;
  }
  if (request.method === "GET" || request.method === "HEAD") {
    void serveStatic(request, response);
    return;
  }
  response.writeHead(405);
  response.end("Method not allowed");
});

server.listen(port, host, () => {
  console.log(`GVT client console: http://${host}:${port}/`);
  console.log(`GVT viewer exe: ${viewerExe}`);
});
