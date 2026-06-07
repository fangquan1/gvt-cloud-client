import { ApiError, HttpApiClient } from "./api.js";
import { CLIENT_DEFAULTS, DEFAULT_SERVER } from "./defaults.js";
import { filterDesktops, formatUptime, modeLabel, statusLabel } from "./filters.js";
import { buildLaunchPlan, modePayload } from "./launcher.js";
import { MockApiClient } from "./mockApi.js";
import type { ApiClient, Desktop, DesktopMode, FilterKey, GvtProfile, ServerConfig } from "./models.js";
import { Store } from "./store.js";

const CONFIG_KEY = "gvt-cloud-client.server";
const API_MODE_KEY = "gvt-cloud-client.apiMode";
const SESSION_KEY = "gvt-cloud-client.session";
const store = new Store();
let api: ApiClient = new HttpApiClient(
  DEFAULT_SERVER,
  typeof sessionStorage === "undefined" ? "" : sessionStorage.getItem(SESSION_KEY) || ""
);

function icon(label: string): string {
  return `<span class="icon" aria-hidden="true">${label}</span>`;
}

function escapeHtml(value: string): string {
  return value.replace(/[&<>"']/g, (char) => ({
    "&": "&amp;",
    "<": "&lt;",
    ">": "&gt;",
    "\"": "&quot;",
    "'": "&#39;"
  }[char] || char));
}

function loadConfig(): void {
  const raw = localStorage.getItem(CONFIG_KEY);
  let config = store.get().server;
  try {
    if (raw) {
      const parsed = JSON.parse(raw) as Partial<ServerConfig>;
      config = { ...DEFAULT_SERVER, ...parsed };
      store.set({ server: config });
    }
  } catch {
    localStorage.removeItem(CONFIG_KEY);
  }
  const savedApiMode = localStorage.getItem(API_MODE_KEY);
  const search = typeof window === "undefined" ? "" : window.location.search;
  const mockAllowed = new URLSearchParams(search).has("mock");
  const apiMode = savedApiMode === "mock" && !mockAllowed ? "real" : savedApiMode;
  if (apiMode === "mock" || apiMode === "real") {
    store.set({ apiMode });
    useApi(config, apiMode);
  }
}

function saveConfig(config: ServerConfig, apiMode: "mock" | "real"): void {
  localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
  localStorage.setItem(API_MODE_KEY, apiMode === "mock" ? "real" : apiMode);
}

function useApi(config: ServerConfig, mode: "mock" | "real"): void {
  const sessionToken = sessionStorage.getItem(SESSION_KEY) || "";
  api = mode === "mock" ? new MockApiClient() : new HttpApiClient(config, sessionToken);
  store.set({ apiMode: mode, server: config });
}

async function refreshAll(): Promise<void> {
  try {
    const [status, desktops, gvtProfiles] = await Promise.all([api.status(), api.desktops(), api.gvtProfiles()]);
    store.set({ status, desktops, gvtProfiles, error: undefined });
  } catch (error) {
    handleApiError(error, true);
  }
}

function handleApiError(error: unknown, clearRuntime = false): void {
  const message = error instanceof Error ? error.message : String(error);
  if (error instanceof ApiError && error.status === 401) {
    sessionStorage.removeItem(SESSION_KEY);
    store.set({
      ...(clearRuntime ? { status: undefined, desktops: [], gvtProfiles: [] } : {}),
      error: "登录已失效，请重新登录"
    });
    return;
  }
  store.set({
    ...(clearRuntime ? { status: undefined, desktops: [], gvtProfiles: [] } : {}),
    error: message
  });
}

async function loginFromModal(): Promise<void> {
  const state = store.get();
  const server: ServerConfig = {
    id: valueOf("serverId") || state.server.id,
    name: valueOf("serverNameInput") || "GVT Server",
    host: valueOf("serverHost") || DEFAULT_SERVER.host,
    managementPort: Number(valueOf("serverPort") || DEFAULT_SERVER.managementPort),
    username: valueOf("serverUser") || undefined,
    authMethod: valueOf("authMethod") as ServerConfig["authMethod"]
  };
  const apiMode = (valueOf("apiMode") as "mock" | "real") || "mock";
  const password = server.authMethod === "password" ? valueOf("serverPassword") || undefined : undefined;
  const token = server.authMethod === "token" ? valueOf("serverToken") || undefined : undefined;
  store.set({ error: undefined });
  useApi(server, apiMode);
  saveConfig(server, apiMode);

  try {
    const session = await api.login(server, {
      username: server.username,
      password,
      token
    });
    sessionStorage.setItem(SESSION_KEY, session.token);
    store.set({ session, error: undefined });
    hide("settingsBackdrop");
    await refreshAll();
  } catch (error) {
    handleApiError(error);
  }
}

function valueOf(id: string): string {
  const element = document.getElementById(id) as HTMLInputElement | HTMLSelectElement | null;
  return element?.value.trim() || "";
}

function show(id: string): void {
  document.getElementById(id)?.classList.remove("hidden");
}

function hide(id: string): void {
  document.getElementById(id)?.classList.add("hidden");
}

function desktopById(id: string): Desktop | undefined {
  return store.get().desktops.find((item) => item.id === id);
}

async function setMode(id: string, mode: DesktopMode): Promise<void> {
  try {
    const updated = await api.setDesktopMode(id, { mode });
    const desktops = store.get().desktops.map((item) => item.id === id ? updated : item);
    store.set({ desktops, selectedDesktopId: id });
    if (mode === "physical") {
      await api.selectOutput(id);
      await refreshAll();
    }
  } catch (error) {
    handleApiError(error);
  }
}

async function setProfile(id: string, profile: string): Promise<void> {
  try {
    const updated = await api.setDesktopProfile(id, profile);
    const desktops = store.get().desktops.map((item) => item.id === id ? updated : item);
    store.set({ desktops, selectedDesktopId: id, error: undefined });
    await refreshAll();
  } catch (error) {
    handleApiError(error);
  }
}

async function setResources(id: string): Promise<void> {
  try {
    const vcpus = Number(valueOf("desktopVcpus"));
    const memoryMiB = Number(valueOf("desktopMemoryMiB"));
    const updated = await api.setDesktopResources(id, { vcpus, memoryMiB });
    const desktops = store.get().desktops.map((item) => item.id === id ? updated : item);
    store.set({ desktops, selectedDesktopId: id, error: undefined });
    await refreshAll();
  } catch (error) {
    handleApiError(error);
  }
}

async function createDesktopFromModal(): Promise<void> {
  try {
    const state = store.get();
    const fallbackProfile = state.gvtProfiles[0]?.id || "i915-GVTg_V5_8";
    const created = await api.createDesktop({
      name: valueOf("newDesktopName") || "Windows 10",
      vcpus: Number(valueOf("newDesktopVcpus") || 4),
      memoryMiB: Number(valueOf("newDesktopMemoryMiB") || 4096),
      diskSizeGiB: Number(valueOf("newDesktopDiskSizeGiB") || 80),
      qcow2Path: valueOf("newDesktopQcow2Path") || undefined,
      isoPath: valueOf("newDesktopIsoPath") || undefined,
      mode: (valueOf("newDesktopMode") as DesktopMode) || "realtime60",
      gvtProfile: valueOf("newDesktopProfile") || fallbackProfile
    });
    hide("createBackdrop");
    await refreshAll();
    store.set({ selectedDesktopId: created.id, error: undefined });
  } catch (error) {
    handleApiError(error);
  }
}

async function uploadCreateFile(kind: "iso" | "qcow2"): Promise<void> {
  const inputId = kind === "iso" ? "newDesktopIsoFile" : "newDesktopQcow2File";
  const pathId = kind === "iso" ? "newDesktopIsoPath" : "newDesktopQcow2Path";
  const input = document.getElementById(inputId) as HTMLInputElement | null;
  const file = input?.files?.[0];
  if (!file) {
    return;
  }
  setUploadMessage(`正在上传 ${file.name} ...`);
  try {
    const uploaded = await api.uploadFile(kind, file);
    const target = document.getElementById(pathId) as HTMLInputElement | null;
    if (target) {
      target.value = uploaded.path;
    }
    setUploadMessage(`已上传到 ${uploaded.path}`);
  } catch (error) {
    setUploadMessage("");
    handleApiError(error);
  }
}

function setUploadMessage(message: string): void {
  const target = document.getElementById("createUploadMessage");
  if (target) {
    target.textContent = message;
  }
}

async function setIso(id: string): Promise<void> {
  try {
    const updated = await api.setDesktopIso(id, { isoPath: valueOf("desktopIsoPath") });
    const desktops = store.get().desktops.map((item) => item.id === id ? updated : item);
    store.set({ desktops, selectedDesktopId: id, error: undefined });
    await refreshAll();
  } catch (error) {
    handleApiError(error);
  }
}

async function uploadDetailIso(id: string): Promise<void> {
  const input = document.getElementById("desktopIsoFile") as HTMLInputElement | null;
  const file = input?.files?.[0];
  if (!file) {
    return;
  }
  try {
    const uploaded = await api.uploadFile("iso", file);
    const target = document.getElementById("desktopIsoPath") as HTMLInputElement | null;
    if (target) {
      target.value = uploaded.path;
    }
    const updated = await api.setDesktopIso(id, { isoPath: uploaded.path });
    const desktops = store.get().desktops.map((item) => item.id === id ? updated : item);
    store.set({ desktops, selectedDesktopId: id, error: undefined });
  } catch (error) {
    handleApiError(error);
  }
}

async function power(id: string): Promise<void> {
  const desktop = desktopById(id);
  if (!desktop) {
    return;
  }
  try {
    const updated = desktop.status === "running"
      ? await api.stopDesktop(id)
      : await api.startDesktop(id);
    const desktops = store.get().desktops.map((item) => item.id === id ? updated : item);
    store.set({ desktops, selectedDesktopId: id });
    await refreshAll();
  } catch (error) {
    handleApiError(error);
  }
}

async function restart(id: string): Promise<void> {
  try {
    const updated = await api.restartDesktop(id);
    const desktops = store.get().desktops.map((item) => item.id === id ? updated : item);
    store.set({ desktops, selectedDesktopId: id });
    await refreshAll();
  } catch (error) {
    handleApiError(error);
  }
}

async function loadLogs(id: string): Promise<void> {
  const logs = await api.logs(id);
  const target = document.getElementById("logBox");
  if (target) {
    target.textContent = `${logs.truncated ? "[truncated]\n" : ""}${logs.lines.join("\n")}`;
  }
}

async function openViewer(id: string): Promise<void> {
  const desktop = desktopById(id);
  if (!desktop) {
    return;
  }
  const state = store.get();
  const plan = buildLaunchPlan(desktop, state.server, CLIENT_DEFAULTS);
  store.set({ viewer: plan, error: undefined });

  try {
    const response = await fetch("/launch-viewer", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(plan)
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({ error: "本地客户端启动失败" })) as { error?: string };
      throw new Error(payload.error || "本地客户端启动失败");
    }
  } catch (error) {
    store.set({ error: error instanceof Error ? error.message : String(error) });
    show("viewerBackdrop");
  }
}

function render(): void {
  const state = store.get();
  const selected = state.selectedDesktopId ? desktopById(state.selectedDesktopId) : undefined;
  const filtered = filterDesktops(state.desktops, state.filter, state.query);
  const running = state.desktops.filter((item) => item.status === "running").length;
  const physical = state.desktops.filter((item) => item.mode === "physical").length;

  document.getElementById("app")!.innerHTML = `
    <div class="shell ${selected ? "detail-open" : ""}">
      <aside class="rail">
        <div class="brand"><span class="brand-mark">G</span><span>GVT Console</span></div>
        <nav class="nav">
          <button class="active" data-view="desktops" title="桌面">${icon("▣")}<span>桌面</span></button>
          <button data-open-settings title="服务器">${icon("◫")}<span>服务器</span></button>
          <button data-open-settings title="设置">${icon("⚙")}<span>设置</span></button>
        </nav>
        <div class="server-card">
          <strong><span class="dot ${state.status?.online ? "online" : "offline"}"></span>${escapeHtml(state.server.name)}</strong>
          <span>${escapeHtml(state.server.host)}:${state.server.managementPort}</span>
          <span>${state.apiMode === "mock" ? "Mock API" : "Real API"}</span>
        </div>
      </aside>
      <main class="workspace">
        <header class="topbar">
          <div>
            <h1>云桌面</h1>
            <p>${state.status ? `最近刷新 ${new Date(state.status.refreshedAt).toLocaleTimeString()}` : "等待刷新"} · 默认 15ms · FEC 关闭</p>
          </div>
          <div class="top-actions">
            <button class="icon-btn" data-refresh title="刷新">${icon("↻")}</button>
            <button class="button" data-open-settings>${icon("☰")}连接设置</button>
            <button class="button primary" data-create>${icon("+")}创建桌面</button>
          </div>
        </header>
        <section class="stats-row" aria-label="运行概览">
          <div class="stat"><span>在线桌面</span><strong>${running} / ${state.desktops.length}</strong></div>
          <div class="stat"><span>当前输出</span><strong>${escapeHtml(state.status?.activeSource || "-")}</strong></div>
          <div class="stat"><span>物理屏</span><strong>${physical}</strong></div>
          <div class="stat"><span>可用内存</span><strong>${state.status?.availableMemoryMiB ?? "-"} MiB</strong></div>
        </section>
        <section class="toolbar">
          <div class="actions">
            ${filterButton("all", "全部", state.filter)}
            ${filterButton("running", "运行中", state.filter)}
            ${filterButton("stopped", "已关机", state.filter)}
            ${filterButton("physical", "物理屏", state.filter)}
          </div>
          <label class="search">${icon("⌕")}<input id="searchInput" name="gvtDesktopSearch" type="search" autocomplete="off" autocapitalize="off" spellcheck="false" data-lpignore="true" data-1p-ignore="true" readonly placeholder="搜索桌面、地址或端口" value="${escapeHtml(state.query)}" /></label>
        </section>
        <section class="desktop-grid">
          ${filtered.map(cardHtml).join("") || `<p class="muted">没有匹配的桌面。</p>`}
        </section>
      </main>
      ${selected ? `<aside class="details">${detailHtml(selected)}</aside>` : ""}
    </div>
    ${settingsHtml(state.server, state.apiMode)}
    ${createDesktopHtml(state.gvtProfiles)}
    ${viewerHtml()}
    ${state.error ? `<div class="toast">${escapeHtml(state.error)}</div>` : ""}
  `;
  bindEvents();
}

function filterButton(key: FilterKey, label: string, active: FilterKey): string {
  return `<button class="tab ${key === active ? "active" : ""}" data-filter="${key}">${label}</button>`;
}

function cardHtml(item: Desktop): string {
  const stateClass = item.status === "running" ? "state-running" : "state-stopped";
  return `
    <article class="desktop-card ${item.id}">
      <button class="thumb" data-connect="${item.id}" title="连接">
        <img src="${escapeHtml(item.thumbnailUrl || "assets/desktop-win10.png")}" alt="" />
        <span class="state-pill ${stateClass}">${statusLabel(item.status)}</span>
        <span class="stream-pill ${item.mode === "physical" ? "pill physical" : "pill ok"}">${modeLabel(item.mode)}</span>
      </button>
      <div class="desktop-body">
        <div class="desktop-title">
          <div><h2>${escapeHtml(item.name)}</h2><p>${escapeHtml(item.address)}</p></div>
          <button class="icon-btn" data-detail="${item.id}" title="详情">${icon("i")}</button>
        </div>
        <div class="meta">
          <span>${item.resolution.width}x${item.resolution.height}</span>
          <span>${item.resources.vcpus} vCPU</span>
          <span>${item.resources.memoryMiB} MiB</span>
          <span>视频 ${item.ports.video}</span>
          <span>输入 ${item.ports.input}</span>
          <span>音频 ${item.ports.spice}</span>
          <span>${formatUptime(item.runtime.uptimeSeconds)}</span>
        </div>
        <div class="card-actions">
          <button class="card-action ${item.status === "running" ? "danger" : "primary"}" data-power="${item.id}" title="${item.status === "running" ? "关机" : "开机"}"><span>${item.status === "running" ? "关机" : "开机"}</span></button>
          <button class="card-action" data-connect="${item.id}" title="连接"><span>连接</span></button>
          <button class="card-action" data-detail="${item.id}" title="详情"><span>详情</span></button>
        </div>
      </div>
    </article>
  `;
}

function detailHtml(item: Desktop): string {
  const payload = modePayload(item.mode);
  const profiles = store.get().gvtProfiles;
  const canEditResources = item.status !== "running";
  const qemuCommand = item.qemuCommand.line || "虚拟机未运行，暂无 QEMU 命令行。";
  return `
    <div class="details-inner">
      <div class="detail-section">
        <div class="details-header">
          <div>
            <h2>${escapeHtml(item.name)}</h2>
            <p class="muted">${statusLabel(item.status)} · ${modeLabel(item.mode)} · ${item.resolution.width}x${item.resolution.height}</p>
          </div>
          <button class="icon-btn" data-close-details title="收起详情">${icon("×")}</button>
        </div>
      </div>
      <div class="detail-section kv">
        <span>视频端口</span><strong>${item.ports.video}</strong>
        <span>输入端口</span><strong>${item.ports.input}</strong>
        <span>SPICE 音频</span><strong>${item.ports.spice}</strong>
        <span>vCPU</span><strong>${item.resources.vcpus}</strong>
        <span>内存</span><strong>${item.resources.memoryMiB} MiB</strong>
        <span>键鼠来源</span><strong>${item.keyboardSource === "client" ? "客户端" : "盒子外接"}</strong>
        <span>音频来源</span><strong>${item.audioSource === "client" ? "客户端" : "盒子外接"}</strong>
        <span>QEMU 摘要</span><strong>${escapeHtml(item.qemuSummary)}</strong>
      </div>
      <div class="detail-section">
        <h3>虚拟机配置</h3>
        <div class="form-grid compact">
          <label>CPU 核数<input id="desktopVcpus" type="number" min="1" max="16" step="1" value="${item.resources.vcpus}" ${canEditResources ? "" : "disabled"} /></label>
          <label>内存 MiB<input id="desktopMemoryMiB" type="number" min="1024" max="32768" step="256" value="${item.resources.memoryMiB}" ${canEditResources ? "" : "disabled"} /></label>
        </div>
        <div class="actions">
          <button class="button" data-resources="${item.id}" ${canEditResources ? "" : "disabled"}>${icon("✓")}保存配置</button>
        </div>
        <small>${canEditResources ? "配置会在下次开机时生效。" : "运行中的虚拟机请先关机，再修改 CPU 和内存。"}</small>
      </div>
      <div class="detail-section">
        <h3>安装 ISO</h3>
        <label>ISO 路径<input id="desktopIsoPath" value="${escapeHtml(item.installIso || "")}" placeholder="/root/iso/windows.iso" ${canEditResources ? "" : "disabled"} /></label>
        <label>从本地上传 ISO<input id="desktopIsoFile" type="file" accept=".iso" data-detail-upload-iso="${item.id}" ${canEditResources ? "" : "disabled"} /></label>
        <div class="actions">
          <button class="button" data-iso="${item.id}" ${canEditResources ? "" : "disabled"}>挂载 ISO</button>
          <button class="button" data-detach-iso="${item.id}" ${canEditResources ? "" : "disabled"}>卸载 ISO</button>
        </div>
        <small>${canEditResources ? "ISO 会在下次开机时作为光驱挂载，适合安装 Windows 或驱动。" : "运行中的虚拟机请先关机，再挂载或卸载 ISO。"}</small>
      </div>
      <div class="detail-section">
        <h3>模式</h3>
        <div class="mode-grid">
          ${modeButton(item, "realtime60")}
          ${modeButton(item, "realtime30")}
          ${modeButton(item, "powersave")}
          ${modeButton(item, "physical")}
          ${profiles.map((profile) => profileButton(item, profile)).join("")}
        </div>
        <small>当前模式参数: ${escapeHtml(JSON.stringify(payload))}</small>
      </div>
      <div class="detail-section">
        <h3>QEMU 命令行</h3>
        <pre class="logs">${escapeHtml(qemuCommand)}</pre>
      </div>
      <div class="detail-section">
        <h3>操作</h3>
        <div class="actions">
          <button class="button primary" data-connect="${item.id}">${icon("▶")}连接</button>
          <button class="button" data-power="${item.id}">${icon("⏻")}${item.status === "running" ? "关机" : "开机"}</button>
          <button class="button" data-restart="${item.id}">${icon("↻")}重启</button>
          <button class="button" data-logs="${item.id}">${icon("≡")}日志摘要</button>
        </div>
      </div>
      <pre class="logs" id="logBox">点击“日志摘要”读取裁剪和脱敏后的服务端日志。</pre>
    </div>
  `;
}

function modeButton(item: Desktop, mode: DesktopMode): string {
  return `<button class="button ${item.mode === mode ? "primary" : ""}" data-mode="${item.id}:${mode}">${modeLabel(mode)}</button>`;
}

function profileButton(item: Desktop, profile: GvtProfile): string {
  const active = item.gvtProfile === profile.id ? "primary" : "";
  const label = `${profile.id} ${profile.resolution.width}x${profile.resolution.height} free=${profile.availableInstances}`;
  return `<button class="button ${active}" data-profile="${item.id}:${profile.id}">${escapeHtml(label)}</button>`;
}

function settingsHtml(server: ServerConfig, apiMode: "mock" | "real"): string {
  return `
    <div class="modal-backdrop hidden" id="settingsBackdrop">
      <section class="modal" role="dialog" aria-modal="true" aria-label="连接设置">
        <header class="modal-header">
          <h2>连接设置</h2>
          <button class="icon-btn" data-close-settings title="关闭">${icon("×")}</button>
        </header>
        <div class="form-grid">
          <label>配置 ID<input id="serverId" value="${escapeHtml(server.id)}" /></label>
          <label>显示名称<input id="serverNameInput" value="${escapeHtml(server.name)}" /></label>
          <label>服务器地址<input id="serverHost" value="${escapeHtml(server.host)}" /></label>
          <label>管理端口<input id="serverPort" type="number" value="${server.managementPort}" /></label>
          <label>用户名<input id="serverUser" name="gvtServerUser" autocomplete="off" autocapitalize="off" spellcheck="false" data-lpignore="true" data-1p-ignore="true" value="${escapeHtml(server.username || "")}" /></label>
          <label>登录方式
            <select id="authMethod">
              <option value="none" ${server.authMethod === "none" ? "selected" : ""}>无认证</option>
              <option value="password" ${server.authMethod === "password" ? "selected" : ""}>密码</option>
              <option value="token" ${server.authMethod === "token" ? "selected" : ""}>令牌</option>
            </select>
          </label>
          <label>密码<input id="serverPassword" name="gvtServerPassword" type="password" autocomplete="off" data-lpignore="true" data-1p-ignore="true" placeholder="仅本次登录使用" /></label>
          <label>令牌<input id="serverToken" name="gvtServerToken" type="password" autocomplete="off" data-lpignore="true" data-1p-ignore="true" placeholder="仅本次登录使用" /></label>
          <label>API 模式
            <select id="apiMode">
              <option value="mock" ${apiMode === "mock" ? "selected" : ""}>Mock 数据</option>
              <option value="real" ${apiMode === "real" ? "selected" : ""}>真实服务端</option>
            </select>
          </label>
        </div>
        <footer class="modal-footer">
          <span class="muted">密码和令牌不会写入 localStorage。</span>
          <button class="button primary" data-login>${icon("↪")}保存并登录</button>
        </footer>
      </section>
    </div>
  `;
}

function createDesktopHtml(profiles: GvtProfile[]): string {
  const profileOptions = profiles.length
    ? profiles.map((profile) => `<option value="${escapeHtml(profile.id)}">${escapeHtml(profile.id)} ${profile.resolution.width}x${profile.resolution.height} free=${profile.availableInstances}</option>`).join("")
    : `<option value="i915-GVTg_V5_8">i915-GVTg_V5_8 1024x768</option>`;
  return `
    <div class="modal-backdrop hidden" id="createBackdrop">
      <section class="modal" role="dialog" aria-modal="true" aria-label="创建桌面">
        <header class="modal-header">
          <h2>创建桌面</h2>
          <button class="icon-btn" data-close-create title="关闭">${icon("×")}</button>
        </header>
        <div class="form-grid">
          <label>名称<input id="newDesktopName" value="Windows 10" /></label>
          <label>GVT-g 方案<select id="newDesktopProfile">${profileOptions}</select></label>
          <label>CPU 核数<input id="newDesktopVcpus" type="number" min="1" max="16" step="1" value="4" /></label>
          <label>内存 MiB<input id="newDesktopMemoryMiB" type="number" min="1024" max="32768" step="256" value="4096" /></label>
          <label>系统盘 GiB<input id="newDesktopDiskSizeGiB" type="number" min="20" max="1024" step="1" value="80" /></label>
          <label>模式
            <select id="newDesktopMode">
              <option value="realtime60">实时 60fps</option>
              <option value="realtime30">兼容 30fps</option>
              <option value="powersave">节能 15-60fps</option>
              <option value="physical">物理屏输出</option>
            </select>
          </label>
          <label class="wide">已有 qcow2 路径<input id="newDesktopQcow2Path" placeholder="/root/qemu_cmd/multivm/disks/win10.qcow2" /></label>
          <label class="wide">从本地上传 qcow2<input id="newDesktopQcow2File" type="file" accept=".qcow2" data-upload-kind="qcow2" /></label>
          <label class="wide">Windows ISO 路径<input id="newDesktopIsoPath" placeholder="/root/iso/windows.iso" /></label>
          <label class="wide">从本地上传 Windows ISO<input id="newDesktopIsoFile" type="file" accept=".iso" data-upload-kind="iso" /></label>
        </div>
        <footer class="modal-footer">
          <span class="muted" id="createUploadMessage">不填 qcow2 时会在默认磁盘目录创建新的 80G 系统盘；填写 ISO 后首次开机会从 ISO 启动安装。</span>
          <button class="button primary" data-create-submit>${icon("+")}创建</button>
        </footer>
      </section>
    </div>
  `;
}

function viewerHtml(): string {
  const plan = store.get().viewer;
  const image = desktopById(plan?.desktopId || "")?.thumbnailUrl || "assets/desktop-win10.png";
  return `
    <div class="viewer-backdrop hidden" id="viewerBackdrop">
      <section class="viewer">
        <header class="viewer-titlebar">
          <div><strong>${escapeHtml(plan?.title || "未连接")}</strong> <span class="muted">${plan?.physical ? "物理屏输出" : "客户端解码"}</span></div>
          <div class="viewer-actions">
            <button class="button" data-auto-viewer>AUTO</button>
            <button class="icon-btn" data-close-viewer title="断开">${icon("×")}</button>
          </div>
        </header>
        <div class="viewer-stage" tabindex="0">
          ${plan?.physical
            ? `<div class="physical-placeholder"><strong>物理显示屏输出中</strong><span>视频经 ${escapeHtml(desktopById(plan.desktopId)?.physicalConnector || "DP/HDMI")} 输出，当前窗口只接收输入焦点和音频状态。</span></div>`
            : `<img src="${escapeHtml(image)}" alt="Windows 桌面画面" />`}
        </div>
        <footer class="viewer-status">
          <span>视频: ${plan?.links.video || "idle"}</span>
          <span>输入: ${plan?.links.input || "idle"}</span>
          <span>音频: ${plan?.links.audio || "idle"}</span>
          <span>延迟: ${CLIENT_DEFAULTS.videoLatencyMs}ms</span>
          <span>FEC: off</span>
        </footer>
        <pre class="logs">${escapeHtml(plan ? plan.summary + "\n\nviewer args:\n" + plan.args.join(" ") : "")}</pre>
      </section>
    </div>
  `;
}

function bindEvents(): void {
  document.querySelectorAll("[data-open-settings]").forEach((button) => button.addEventListener("click", () => show("settingsBackdrop")));
  document.querySelectorAll("[data-create]").forEach((button) => button.addEventListener("click", () => show("createBackdrop")));
  document.querySelectorAll("[data-close-create]").forEach((button) => button.addEventListener("click", () => hide("createBackdrop")));
  document.querySelectorAll("[data-create-submit]").forEach((button) => button.addEventListener("click", () => void createDesktopFromModal()));
  document.querySelectorAll("[data-upload-kind]").forEach((input) => input.addEventListener("change", () => {
    void uploadCreateFile(((input as HTMLElement).dataset.uploadKind || "iso") as "iso" | "qcow2");
  }));
  document.querySelectorAll("[data-close-settings]").forEach((button) => button.addEventListener("click", () => hide("settingsBackdrop")));
  document.querySelectorAll("[data-login]").forEach((button) => button.addEventListener("click", () => void loginFromModal()));
  document.querySelectorAll("[data-refresh]").forEach((button) => button.addEventListener("click", () => void refreshAll()));
  document.querySelectorAll("[data-filter]").forEach((button) => button.addEventListener("click", () => {
    store.set({ filter: (button as HTMLElement).dataset.filter as FilterKey });
  }));
  document.querySelectorAll("[data-detail]").forEach((button) => button.addEventListener("click", () => {
    store.set({ selectedDesktopId: (button as HTMLElement).dataset.detail });
  }));
  document.querySelectorAll("[data-close-details]").forEach((button) => button.addEventListener("click", () => {
    store.set({ selectedDesktopId: undefined });
  }));
  document.querySelectorAll("[data-connect]").forEach((button) => button.addEventListener("click", () => void openViewer((button as HTMLElement).dataset.connect || "")));
  document.querySelectorAll("[data-power]").forEach((button) => button.addEventListener("click", () => void power((button as HTMLElement).dataset.power || "")));
  document.querySelectorAll("[data-restart]").forEach((button) => button.addEventListener("click", () => void restart((button as HTMLElement).dataset.restart || "")));
  document.querySelectorAll("[data-logs]").forEach((button) => button.addEventListener("click", () => void loadLogs((button as HTMLElement).dataset.logs || "")));
  document.querySelectorAll("[data-mode]").forEach((button) => button.addEventListener("click", () => {
    const [id, mode] = ((button as HTMLElement).dataset.mode || "").split(":") as [string, DesktopMode];
    void setMode(id, mode);
  }));
  document.querySelectorAll("[data-profile]").forEach((button) => button.addEventListener("click", () => {
    const [id, profile] = ((button as HTMLElement).dataset.profile || "").split(":") as [string, string];
    void setProfile(id, profile);
  }));
  document.querySelectorAll("[data-resources]").forEach((button) => button.addEventListener("click", () => {
    void setResources((button as HTMLElement).dataset.resources || "");
  }));
  document.querySelectorAll("[data-iso]").forEach((button) => button.addEventListener("click", () => {
    void setIso((button as HTMLElement).dataset.iso || "");
  }));
  document.querySelectorAll("[data-detach-iso]").forEach((button) => button.addEventListener("click", () => {
    const input = document.getElementById("desktopIsoPath") as HTMLInputElement | null;
    if (input) {
      input.value = "";
    }
    void setIso((button as HTMLElement).dataset.detachIso || "");
  }));
  document.querySelectorAll("[data-detail-upload-iso]").forEach((input) => input.addEventListener("change", () => {
    void uploadDetailIso((input as HTMLElement).dataset.detailUploadIso || "");
  }));
  document.querySelectorAll("[data-close-viewer]").forEach((button) => button.addEventListener("click", () => hide("viewerBackdrop")));
  document.querySelectorAll("[data-auto-viewer]").forEach((button) => button.addEventListener("click", () => {
    const stage = document.querySelector(".viewer-stage");
    stage?.scrollIntoView({ block: "center", behavior: "smooth" });
  }));
  const searchInput = document.getElementById("searchInput") as HTMLInputElement | null;
  if (searchInput) {
    let userEditedSearch = false;
    const unlockSearch = () => {
      searchInput.readOnly = false;
    };
    const markUserEdit = () => {
      userEditedSearch = true;
      unlockSearch();
    };
    const isLikelyAutofill = (value: string) => {
      const normalized = value.trim().toLowerCase();
      const username = (store.get().server.username || "").trim().toLowerCase();
      return !!normalized && (normalized === username || normalized === "root");
    };
    const clearAutofill = () => {
      const state = store.get();
      if (userEditedSearch) {
        return;
      }
      if (!state.query || isLikelyAutofill(state.query) || isLikelyAutofill(searchInput.value)) {
        searchInput.value = "";
        if (state.query && isLikelyAutofill(state.query)) {
          store.set({ query: "" });
        }
      }
    };
    searchInput.addEventListener("pointerdown", unlockSearch);
    searchInput.addEventListener("focus", unlockSearch);
    searchInput.addEventListener("keydown", markUserEdit);
    searchInput.addEventListener("paste", markUserEdit);
    searchInput.addEventListener("search", markUserEdit);
    searchInput.addEventListener("input", (event) => {
      const value = (event.target as HTMLInputElement).value;
      if (!userEditedSearch && isLikelyAutofill(value)) {
        clearAutofill();
        return;
      }
      store.set({ query: value });
    });
    clearAutofill();
    [50, 250, 1000, 2000].forEach((delay) => window.setTimeout(clearAutofill, delay));
  }
}

loadConfig();
store.subscribe(render);
void refreshAll();
