const desktops = [
  {
    id: "win10-main",
    name: "win10-gvt-main",
    subtitle: "Windows 10 · Intel GVT-g",
    status: "running",
    mode: "client",
    profile: "classic",
    fps: 60,
    resolution: "1920x1200",
    host: "192.168.0.188",
    videoPort: 5900,
    inputPort: 5905,
    audio: "client",
    input: "client",
    startedAt: "2026-06-06 21:12:08",
    uptime: "2小时26分",
    command:
      "qemu-system-x86_64 --nodefaults -enable-kvm -cpu host -m 4096 -smp 4 -display gvt-stream,host=0.0.0.0,port=5900,codec=h264,fps=60 -device vfio-pci-nohotplug,sysfsdev=/sys/bus/pci/devices/0000:00:02.0/f8cd7bd7-eabf-4d0b-ab00-d899e4107ae7,display=on,x-igd-opregion=on,ramfb=on -spice port=5910,addr=0.0.0.0,disable-ticketing -device qemu-xhci -device usb-tablet",
  },
  {
    id: "win10-energy",
    name: "win10-office-save",
    subtitle: "Windows 10 · 节能池",
    status: "running",
    mode: "client",
    profile: "energy",
    fps: "15-60",
    resolution: "1920x1080",
    host: "192.168.0.188",
    videoPort: 5902,
    inputPort: 5907,
    audio: "client",
    input: "client",
    startedAt: "2026-06-06 22:41:31",
    uptime: "56分",
    command:
      "qemu-system-x86_64 --display gvt-stream,port=5902,codec=h264,fps=60,idle_capture_ms=66,idle_after_ms=1500,idle_probe_ms=500 -device vfio-pci-nohotplug,display=on,x-igd-opregion=on,ramfb=on -spice port=5912,disable-ticketing",
  },
  {
    id: "win10-hdmi",
    name: "win10-lab-physical",
    subtitle: "Windows 10 · DP-1 直出",
    status: "stopped",
    mode: "physical",
    profile: "physical",
    fps: "本地屏",
    resolution: "2560x1440",
    host: "192.168.0.188",
    videoPort: "DP-1",
    inputPort: 5915,
    audio: "client",
    input: "client",
    startedAt: "-",
    uptime: "-",
    command:
      "qemu-system-x86_64 --display gvt-physical,connector=DP-1,mode=2560x1440@60 -device vfio-pci-nohotplug,display=on,x-igd-opregion=on,ramfb=on -chardev socket,id=native-input,host=0.0.0.0,port=5915,server=on",
  },
];

let selectedId = desktops[0].id;

const grid = document.querySelector("#desktopGrid");
const detail = document.querySelector("#detailsPanel");
const cardTemplate = document.querySelector("#desktopCardTemplate");
const settingsModal = document.querySelector("#settingsModal");
const viewer = document.querySelector("#viewerWindow");
const viewerTitle = document.querySelector("#viewerTitle");
const viewerMode = document.querySelector("#viewerMode");
const viewerImage = document.querySelector("#viewerImage");
const physicalPlaceholder = document.querySelector("#physicalPlaceholder");
const viewerStatus = document.querySelector("#viewerStatus");

function statusText(status) {
  return status === "running" ? "运行中" : "已关机";
}

function modeText(vm) {
  if (vm.mode === "physical") return "物理显示屏";
  if (vm.profile === "energy") return "节能 15-60fps";
  return `经典 ${vm.fps}fps`;
}

function renderCards() {
  grid.innerHTML = "";
  desktops.forEach((vm) => {
    const card = cardTemplate.content.firstElementChild.cloneNode(true);
    card.dataset.id = vm.id;
    card.classList.toggle("selected", vm.id === selectedId);
    card.querySelector("h2").textContent = vm.name;
    card.querySelector("p").textContent = vm.subtitle;
    card.querySelector(".state-pill").textContent = statusText(vm.status);
    card.querySelector(".stream-pill").textContent = modeText(vm);
    card.querySelector(".meta-line").innerHTML = `
      <span>${vm.host}:${vm.videoPort} · 输入 ${vm.inputPort}</span>
      <span>${vm.resolution} · 音频 ${vm.audio === "client" ? "客户端" : "盒子外接"}</span>
    `;
    if (vm.status !== "running") {
      card.querySelector(".thumb img").style.filter = "grayscale(1) brightness(0.7)";
    }
    grid.appendChild(card);
  });
  if (window.lucide) window.lucide.createIcons();
}

function renderDetails() {
  const vm = desktops.find((item) => item.id === selectedId);
  if (!vm) return;
  const isPhysical = vm.mode === "physical";
  detail.innerHTML = `
    <div class="detail-header">
      <h2>${vm.name}</h2>
      <div class="status-line">
        <span class="badge ${vm.status === "running" ? "green" : "amber"}">${statusText(vm.status)}</span>
        <span class="badge">${vm.resolution}</span>
        <span class="badge">${modeText(vm)}</span>
      </div>
    </div>

    <section class="detail-section">
      <h3>桌面模式</h3>
      <div class="segmented">
        <button data-field="mode" data-value="client" class="${!isPhysical ? "active" : ""}">客户端解码</button>
        <button data-field="mode" data-value="physical" class="${isPhysical ? "active" : ""}">物理屏直出</button>
      </div>
    </section>

    <section class="detail-section ${isPhysical ? "hidden" : ""}">
      <h3>客户端解码档位</h3>
      <div class="segmented">
        <button data-field="profile" data-value="classic" class="${vm.profile === "classic" ? "active" : ""}">经典模式</button>
        <button data-field="profile" data-value="energy" class="${vm.profile === "energy" ? "active" : ""}">节能模式</button>
      </div>
      <div class="segmented ${vm.profile === "energy" ? "hidden" : ""}">
        <button data-field="fps" data-value="60" class="${vm.fps === 60 ? "active" : ""}">60fps</button>
        <button data-field="fps" data-value="30" class="${vm.fps === 30 ? "active" : ""}">30fps</button>
      </div>
      <div class="kv ${vm.profile === "energy" ? "" : "hidden"}">
        <span>动态范围</span><span>15fps - 60fps</span>
        <span>降帧等待</span><span>1500ms</span>
        <span>变化探测</span><span>500ms</span>
      </div>
    </section>

    <section class="detail-section ${isPhysical ? "" : "hidden"}">
      <h3>物理显示屏</h3>
      <div class="kv">
        <span>输出接口</span><span>${vm.videoPort}</span>
        <span>画面输出</span><span>盒子 DP/HDMI</span>
        <span>本地窗口</span><span>${vm.resolution} 输入焦点</span>
      </div>
      <div class="segmented">
        <button data-field="input" data-value="client" class="${vm.input === "client" ? "active" : ""}">客户端键鼠</button>
        <button data-field="input" data-value="box" class="${vm.input === "box" ? "active" : ""}">盒子外接</button>
      </div>
      <div class="segmented">
        <button data-field="audio" data-value="client" class="${vm.audio === "client" ? "active" : ""}">客户端音频</button>
        <button data-field="audio" data-value="box" class="${vm.audio === "box" ? "active" : ""}">盒子外接</button>
      </div>
    </section>

    <section class="detail-section">
      <h3>连接与运行</h3>
      <div class="kv">
        <span>地址</span><span>${vm.host}</span>
        <span>画面端口</span><span>${vm.videoPort}</span>
        <span>输入端口</span><span>${vm.inputPort}</span>
        <span>启动时间</span><span>${vm.startedAt}</span>
        <span>运行时间</span><span>${vm.uptime}</span>
      </div>
    </section>

    <section class="detail-section">
      <h3>QEMU 命令行</h3>
      <pre class="code-box">${vm.command}</pre>
    </section>

    <div class="detail-actions">
      <button class="button ${vm.status === "running" ? "ghost" : "primary"}" data-detail-action="power">
        <i data-lucide="power"></i><span>${vm.status === "running" ? "关机" : "开机"}</span>
      </button>
      <button class="button primary" data-detail-action="connect">
        <i data-lucide="play"></i><span>连接</span>
      </button>
    </div>
  `;
  if (window.lucide) window.lucide.createIcons();
}

function updateVm(id, patch) {
  const vm = desktops.find((item) => item.id === id);
  if (!vm) return;
  Object.assign(vm, patch);
  if (patch.mode === "client" && vm.profile === "physical") {
    vm.profile = "classic";
    vm.fps = 60;
    vm.videoPort = 5900;
  }
  if (patch.mode === "physical") {
    vm.profile = "physical";
    vm.fps = "本地屏";
    vm.videoPort = vm.videoPort === 5900 ? "DP-1" : vm.videoPort;
  }
  renderCards();
  renderDetails();
}

function connectVm(vm) {
  selectedId = vm.id;
  renderCards();
  renderDetails();
  viewerTitle.textContent = vm.name;
  viewerMode.textContent = vm.mode === "physical" ? "物理屏直出 · 输入窗口" : `${modeText(vm)} · H.264`;
  const physical = vm.mode === "physical";
  viewerImage.classList.toggle("hidden", physical);
  physicalPlaceholder.classList.toggle("hidden", !physical);
  viewerStatus.innerHTML = physical
    ? `
      <span><i data-lucide="monitor-up"></i> ${vm.videoPort} 物理输出</span>
      <span><i data-lucide="keyboard"></i> 原生输入 ${vm.inputPort}</span>
      <span><i data-lucide="volume-2"></i> ${vm.audio === "client" ? "客户端音频" : "盒子外接音频"}</span>
      <span>${vm.input === "client" ? "客户端键鼠" : "盒子外接键鼠"}</span>
    `
    : `
      <span><i data-lucide="radio"></i> H.264 RTP ${vm.videoPort}</span>
      <span><i data-lucide="keyboard"></i> 原生输入 ${vm.inputPort}</span>
      <span><i data-lucide="volume-2"></i> SPICE 音频</span>
      <span>${vm.profile === "energy" ? "15-60fps" : "15ms"}</span>
    `;
  viewer.classList.remove("hidden");
  document.querySelector("#viewerStage").focus();
  if (window.lucide) window.lucide.createIcons();
}

grid.addEventListener("click", (event) => {
  const card = event.target.closest(".desktop-card");
  const action = event.target.closest("[data-action]")?.dataset.action;
  if (!card) return;
  const vm = desktops.find((item) => item.id === card.dataset.id);
  selectedId = vm.id;
  renderCards();
  renderDetails();
  if (action === "power") {
    vm.status = vm.status === "running" ? "stopped" : "running";
    vm.startedAt = vm.status === "running" ? "2026-06-06 23:38:12" : "-";
    vm.uptime = vm.status === "running" ? "刚刚" : "-";
    renderCards();
    renderDetails();
  }
  if (action === "connect") connectVm(vm);
});

detail.addEventListener("click", (event) => {
  const vm = desktops.find((item) => item.id === selectedId);
  const fieldButton = event.target.closest("[data-field]");
  const actionButton = event.target.closest("[data-detail-action]");
  if (fieldButton) {
    const field = fieldButton.dataset.field;
    let value = fieldButton.dataset.value;
    if (field === "fps") value = Number(value);
    updateVm(vm.id, { [field]: value });
  }
  if (actionButton?.dataset.detailAction === "power") {
    updateVm(vm.id, {
      status: vm.status === "running" ? "stopped" : "running",
      startedAt: vm.status === "running" ? "-" : "2026-06-06 23:38:12",
      uptime: vm.status === "running" ? "-" : "刚刚",
    });
  }
  if (actionButton?.dataset.detailAction === "connect") connectVm(vm);
});

document.querySelectorAll("[data-open-settings]").forEach((button) => {
  button.addEventListener("click", () => settingsModal.classList.remove("hidden"));
});

document.querySelectorAll("[data-close-settings]").forEach((button) => {
  button.addEventListener("click", () => settingsModal.classList.add("hidden"));
});

document.querySelector("#loginBtn").addEventListener("click", () => {
  const host = document.querySelector("#settingsHost").value.trim();
  const port = document.querySelector("#settingsPort").value.trim();
  document.querySelector("#serverAddr").textContent = `${host}:${port}`;
  settingsModal.classList.add("hidden");
  document.querySelector(".topbar p").textContent = `已登录 root@openeuler111，最近刷新 ${new Date().toLocaleTimeString("zh-CN", { hour12: false })}`;
});

document.querySelector("#refreshBtn").addEventListener("click", () => {
  document.querySelector(".topbar p").textContent = `已登录 root@openeuler111，最近刷新 ${new Date().toLocaleTimeString("zh-CN", { hour12: false })}`;
});

document.querySelector("#closeViewer").addEventListener("click", () => {
  viewer.classList.add("hidden");
});

document.querySelector("#autoSizeBtn").addEventListener("click", () => {
  const vm = desktops.find((item) => item.id === selectedId);
  if (!vm) return;
  const [w, h] = vm.resolution.split("x").map(Number);
  const maxW = Math.min(window.innerWidth - 80, w);
  const scaledH = Math.round((maxW / w) * h) + 76;
  viewer.style.width = `${maxW}px`;
  viewer.querySelector(".viewer-stage").style.height = `${Math.min(window.innerHeight - 130, scaledH - 76)}px`;
  viewer.style.left = "40px";
  viewer.style.top = "40px";
});

renderCards();
renderDetails();
if (window.lucide) window.lucide.createIcons();
