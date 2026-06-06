import { HttpApiClient } from "./api.js";
import { CLIENT_DEFAULTS, DEFAULT_SERVER } from "./defaults.js";
import { filterDesktops, formatUptime, modeLabel, statusLabel } from "./filters.js";
import { buildLaunchPlan, modePayload } from "./launcher.js";
import { MockApiClient } from "./mockApi.js";
import type { ApiClient, Desktop, DesktopMode, FilterKey, ServerConfig } from "./models.js";
import { Store } from "./store.js";

const CONFIG_KEY = "gvt-cloud-client.server";
const store = new Store();
let api: ApiClient = new MockApiClient();

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
  if (!raw) {
    return;
  }
  try {
    const parsed = JSON.parse(raw) as Partial<ServerConfig>;
    store.set({ server: { ...DEFAULT_SERVER, ...parsed } });
  } catch {
    localStorage.removeItem(CONFIG_KEY);
  }
}

function saveConfig(config: ServerConfig): void {
  localStorage.setItem(CONFIG_KEY, JSON.stringify(config));
}

function useApi(config: ServerConfig, mode: "mock" | "real"): void {
  api = mode === "mock" ? new MockApiClient() : new HttpApiClient(config);
  store.set({ apiMode: mode, server: config });
}

async function refreshAll(): Promise<void> {
  try {
    const [status, desktops] = await Promise.all([api.status(), api.desktops()]);
    store.set({ status, desktops, error: undefined });
  } catch (error) {
    store.set({ error: error instanceof Error ? error.message : String(error) });
  }
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
  useApi(server, apiMode);
  saveConfig(server);

  try {
    const session = await api.login(server, {
      username: server.username,
      password: valueOf("serverPassword") || undefined,
      token: valueOf("serverToken") || undefined
    });
    sessionStorage.setItem("gvt-cloud-client.session", session.token);
    store.set({ session, error: undefined });
    hide("settingsBackdrop");
    await refreshAll();
  } catch (error) {
    store.set({ error: error instanceof Error ? error.message : String(error) });
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
    store.set({ error: error instanceof Error ? error.message : String(error) });
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
  } catch (error) {
    store.set({ error: error instanceof Error ? error.message : String(error) });
  }
}

async function restart(id: string): Promise<void> {
  try {
    const updated = await api.restartDesktop(id);
    const desktops = store.get().desktops.map((item) => item.id === id ? updated : item);
    store.set({ desktops, selectedDesktopId: id });
  } catch (error) {
    store.set({ error: error instanceof Error ? error.message : String(error) });
  }
}

async function loadLogs(id: string): Promise<void> {
  const logs = await api.logs(id);
  const target = document.getElementById("logBox");
  if (target) {
    target.textContent = `${logs.truncated ? "[truncated]\n" : ""}${logs.lines.join("\n")}`;
  }
}

function openViewer(id: string): void {
  const desktop = desktopById(id);
  if (!desktop) {
    return;
  }
  const state = store.get();
  const plan = buildLaunchPlan(desktop, state.server, CLIENT_DEFAULTS);
  store.set({ viewer: plan });
  show("viewerBackdrop");
}

function render(): void {
  const state = store.get();
  const selected = state.selectedDesktopId ? desktopById(state.selectedDesktopId) : undefined;
  const filtered = filterDesktops(state.desktops, state.filter, state.query);
  const running = state.desktops.filter((item) => item.status === "running").length;
  const physical = state.desktops.filter((item) => item.mode === "physical").length;

  document.getElementById("app")!.innerHTML = `
    <div class="shell">
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
            <button class="button primary" data-refresh>${icon("+")}刷新桌面</button>
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
          <label class="search">${icon("⌕")}<input id="searchInput" type="search" placeholder="搜索桌面、地址或端口" value="${escapeHtml(state.query)}" /></label>
        </section>
        <section class="desktop-grid">
          ${filtered.map(cardHtml).join("") || `<p class="muted">没有匹配的桌面。</p>`}
        </section>
      </main>
      <aside class="details">
        ${selected ? detailHtml(selected) : `<div class="details-inner"><h2>选择一个桌面</h2><p class="muted">详情、模式、端口和安全日志摘要会显示在这里。</p></div>`}
      </aside>
    </div>
    ${settingsHtml(state.server, state.apiMode)}
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
          <span>视频 ${item.ports.video}</span>
          <span>输入 ${item.ports.input}</span>
          <span>音频 ${item.ports.spice}</span>
          <span>${formatUptime(item.runtime.uptimeSeconds)}</span>
        </div>
        <div class="card-actions">
          <button class="icon-btn" data-power="${item.id}" title="开关机">${icon("⏻")}</button>
          <button class="icon-btn" data-connect="${item.id}" title="连接">${icon("▶")}</button>
          <button class="icon-btn" data-detail="${item.id}" title="详情">${icon("›")}</button>
        </div>
      </div>
    </article>
  `;
}

function detailHtml(item: Desktop): string {
  const payload = modePayload(item.mode);
  return `
    <div class="details-inner">
      <div class="detail-section">
        <h2>${escapeHtml(item.name)}</h2>
        <p class="muted">${statusLabel(item.status)} · ${modeLabel(item.mode)} · ${item.resolution.width}x${item.resolution.height}</p>
      </div>
      <div class="detail-section kv">
        <span>视频端口</span><strong>${item.ports.video}</strong>
        <span>输入端口</span><strong>${item.ports.input}</strong>
        <span>SPICE 音频</span><strong>${item.ports.spice}</strong>
        <span>键鼠来源</span><strong>${item.keyboardSource === "client" ? "客户端" : "盒子外接"}</strong>
        <span>音频来源</span><strong>${item.audioSource === "client" ? "客户端" : "盒子外接"}</strong>
        <span>QEMU 摘要</span><strong>${escapeHtml(item.qemuSummary)}</strong>
      </div>
      <div class="detail-section">
        <h3>模式</h3>
        <div class="mode-grid">
          ${modeButton(item, "realtime60")}
          ${modeButton(item, "realtime30")}
          ${modeButton(item, "powersave")}
          ${modeButton(item, "physical")}
        </div>
        <small>当前模式参数: ${escapeHtml(JSON.stringify(payload))}</small>
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
          <label>用户名<input id="serverUser" value="${escapeHtml(server.username || "")}" /></label>
          <label>登录方式
            <select id="authMethod">
              <option value="none" ${server.authMethod === "none" ? "selected" : ""}>无认证</option>
              <option value="password" ${server.authMethod === "password" ? "selected" : ""}>密码</option>
              <option value="token" ${server.authMethod === "token" ? "selected" : ""}>令牌</option>
            </select>
          </label>
          <label>密码<input id="serverPassword" type="password" autocomplete="current-password" placeholder="仅本次登录使用" /></label>
          <label>令牌<input id="serverToken" type="password" autocomplete="off" placeholder="仅本次登录使用" /></label>
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
  document.querySelectorAll("[data-close-settings]").forEach((button) => button.addEventListener("click", () => hide("settingsBackdrop")));
  document.querySelectorAll("[data-login]").forEach((button) => button.addEventListener("click", () => void loginFromModal()));
  document.querySelectorAll("[data-refresh]").forEach((button) => button.addEventListener("click", () => void refreshAll()));
  document.querySelectorAll("[data-filter]").forEach((button) => button.addEventListener("click", () => {
    store.set({ filter: (button as HTMLElement).dataset.filter as FilterKey });
  }));
  document.querySelectorAll("[data-detail]").forEach((button) => button.addEventListener("click", () => {
    store.set({ selectedDesktopId: (button as HTMLElement).dataset.detail });
  }));
  document.querySelectorAll("[data-connect]").forEach((button) => button.addEventListener("click", () => openViewer((button as HTMLElement).dataset.connect || "")));
  document.querySelectorAll("[data-power]").forEach((button) => button.addEventListener("click", () => void power((button as HTMLElement).dataset.power || "")));
  document.querySelectorAll("[data-restart]").forEach((button) => button.addEventListener("click", () => void restart((button as HTMLElement).dataset.restart || "")));
  document.querySelectorAll("[data-logs]").forEach((button) => button.addEventListener("click", () => void loadLogs((button as HTMLElement).dataset.logs || "")));
  document.querySelectorAll("[data-mode]").forEach((button) => button.addEventListener("click", () => {
    const [id, mode] = ((button as HTMLElement).dataset.mode || "").split(":") as [string, DesktopMode];
    void setMode(id, mode);
  }));
  document.querySelectorAll("[data-close-viewer]").forEach((button) => button.addEventListener("click", () => hide("viewerBackdrop")));
  document.querySelectorAll("[data-auto-viewer]").forEach((button) => button.addEventListener("click", () => {
    const stage = document.querySelector(".viewer-stage");
    stage?.scrollIntoView({ block: "center", behavior: "smooth" });
  }));
  document.getElementById("searchInput")?.addEventListener("input", (event) => {
    store.set({ query: (event.target as HTMLInputElement).value });
  });
}

loadConfig();
store.subscribe(render);
void refreshAll();
