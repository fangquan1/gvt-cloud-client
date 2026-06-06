# GVT 云桌面客户端需求规划

## 仓库

- 目标 GitHub 仓库: `https://github.com/fangquan1/gvt-cloud-client`
- 本地初始仓库: `repos/gvt-cloud-client`
- 默认开发分支: `gvt-cloud-client-mvp`
- 当前状态: 本地需求与原型已整理；远端 GitHub 仓库待创建/推送。

## 产品定位

客户端是面向 Windows 用户的 GVT 云桌面控制台。它不是传统 `remote-viewer` 的简单包装，而是把 QEMU `gvt-stream` 原生 H.264 画面、SPICE 音频/session、QEMU 原生输入、物理 DP/HDMI 输出切换、多 VM 管理统一到一个桌面应用中。

核心目标:

- 通过一个应用管理服务器、云桌面列表、运行状态和连接窗口。
- 默认支持客户端解码模式: H.264 RTP 视频 + SPICE 音频/session + 原生输入。
- 支持物理屏输出模式: 视频显示在盒子 DP/HDMI，客户端窗口只承担输入焦点、音频和状态显示。
- 支持实时模式和节能模式，并把这些模式做成用户能理解的配置项。
- 保留低延迟手感，避免回到 FEC/rtpstorage 导致的高缓存或花屏链路。

非目标:

- 不把 Sunshine/Moonlight/RDP 安装进 Windows guest 作为主路线。
- 不在公开仓库里保存服务器密码、GitHub 密码、Web 密码、虚拟机镜像或私有日志。
- 不把当前实验归档里的可执行文件、GStreamer runtime、qcow2 镜像纳入源码仓库。

## 设计来源

当前 UI 原型位于 `ui-test/`:

- 主界面: 左侧导航、服务器状态、桌面列表、运行概览、筛选和搜索。
- 详情面板: 桌面状态、模式切换、端口、分辨率、QEMU 命令摘要。
- 设置弹窗: 服务器地址、管理端口、用户名、登录方式。
- 连接窗口: `AUTO` 尺寸、断开、视频/输入/音频状态。
- 模式 1: 客户端解码，经典 30/60fps 与节能 15-60fps。
- 模式 2: 物理 DP/HDMI 输出，键鼠和音频可在客户端/盒子外接之间切换。

界面实现时应保持这个方向: 安静、紧凑、偏运维控制台，不做营销页。

## 用户角色

- 管理者: 配置服务器、查看所有桌面、启动/停止 VM、切换物理输出源。
- 使用者: 连接自己的 Windows 桌面，关注低延迟、音频、键鼠和窗口尺寸。
- 调试者: 查看服务端日志摘要、端口、帧率、丢包、输入连接状态。

## 功能需求

### 服务器连接

- 支持保存多个服务器配置: 名称、地址、管理端口、认证方式。
- 支持登录后刷新桌面列表。
- 支持显示在线状态、主机负载、可用内存、当前活跃 VM 数。
- 密码和令牌只能保存在系统安全存储或本地加密配置中，不进入 Git。

### 桌面列表

- 每个桌面至少显示: 名称、状态、缩略图、分辨率、模式、视频端口、输入端口、音频端口、运行时间。
- 支持全部、运行中、已关机、物理屏筛选。
- 支持搜索桌面名、地址、端口。
- 支持开机、关机、重启、查看详情、连接。

### 客户端解码模式

- 视频默认接收 QEMU `gvt-stream` H.264 RTP。
- 默认 jitter latency 为 15ms，不启用 FEC，不主动丢 H.264 包。
- 默认输入走 QEMU 原生 TCP 输入通道，例如 VM1 `5905`、VM2 `5906`。
- 默认音频走 SPICE playback/session，例如 VM1 `5900`、VM2 `5901`。
- 支持经典实时模式:
  - `60fps`: `capture_ms=16`
  - `30fps`: 可作为兼容/降载选项
- 支持节能模式:
  - 动态或输入后 60fps
  - 低变化约 1500ms 后降至约 15fps
  - 默认参数: `idle_capture_ms=66`、`idle_after_ms=1500`、`idle_probe_ms=500`

### 物理屏输出模式

- 客户端不接收视频画面，视频由服务端 `gvt-outputd` 输出到 DP/HDMI。
- 连接窗口应显示同分辨率输入焦点区域和当前物理输出源。
- 支持切换键鼠来源:
  - 客户端键鼠
  - 盒子外接键鼠
- 支持切换音频来源:
  - 客户端 SPICE 音频
  - 盒子外接音频
- 物理屏模式下仍需显示输入连接、音频连接和当前 active source。

### 连接窗口

- `AUTO` 按钮按源分辨率和当前屏幕可用区域等比缩放。
- 支持断开连接但不关闭 VM。
- 显示视频、输入、音频三条链路状态。
- 客户端解码模式显示实际视频画面。
- 物理屏模式显示输入焦点占位，不伪造正在播放的视频。
- 未来应支持全屏、缩放比例、窗口置顶和低延迟统计浮层。

### 多 VM 与切换

- 支持 VM1/VM2 当前基线:
  - VM1: SPICE `5900`，输入 `5905`
  - VM2: SPICE `5901`，输入 `5906`
- 支持从 UI 调用服务端切换 active source。
- 切换物理输出时，应联动切换远程输入目标和音频连接。
- 当前大小写反转修复需保留: 输入 overlay 默认 `--invert-case`，直到服务端/guest 键盘映射根治。

## 服务端 API 需求

客户端至少需要这些接口:

- `POST /api/login`: 登录并返回 session/token。
- `GET /api/status`: 主机状态、版本、active source、connector、失败计数。
- `GET /api/desktops`: 桌面列表。
- `GET /api/desktops/{id}`: 单桌面详情。
- `POST /api/desktops/{id}/start`: 启动 VM。
- `POST /api/desktops/{id}/stop`: 停止 VM。
- `POST /api/desktops/{id}/restart`: 重启 VM。
- `POST /api/desktops/{id}/mode`: 设置实时/节能/物理输出模式。
- `POST /api/output/select`: 选择物理输出 active source。
- `GET /api/logs/{id}`: 返回裁剪后的安全日志摘要。

## 技术建议

第一版可以沿用现有能力快速收敛:

- UI: 从 `ui-test` 的 HTML/CSS/JS 迁移到 Tauri、Electron、Qt WebView 或原生 Win32/GTK 均可，优先选择能快速集成现有 C/GStreamer 客户端的方案。
- 视频: 继续使用 GStreamer RTP H.264 接收管线，默认低延迟参数。
- 音频/session: 继续使用 `spice-client-glib`。
- 输入: 继续使用当前原生输入 TCP 通道和 overlay 逻辑。
- 打包: Windows installer，外置或内置 GStreamer runtime，但 runtime 不进源码仓库。

现有客户端代码来源:

- `direct-stream/client/gvt_spice_viewer.c`
- `direct-stream/client/gvt_control_overlay.py`
- `direct-stream/client/receive-h264-rtp.bat`
- `start-gvt-spice-embedded-client.bat`
- `start-gvt-spice-embedded-client-节能模式.bat`
- `ui-test/`

## 里程碑

### M1: 原型落地

- 把 `ui-test` 迁移成可运行客户端壳。
- 可以配置服务器并展示模拟/真实桌面列表。
- 可以打开连接窗口并显示链路状态。

### M2: 真实连接

- 对接服务端 API 获取 VM 列表。
- 调用启动/停止/状态接口。
- 连接 H.264 RTP 视频、SPICE 音频和原生输入。
- `AUTO` 尺寸与当前 `gvt_spice_viewer` 行为一致。

### M3: 多 VM 与物理屏

- 支持 VM1/VM2 切换。
- 支持 `gvt-outputd` active source 切换。
- 物理屏模式联动输入与音频。

### M4: 可发布版本

- 增加安全配置存储、日志脱敏、错误恢复。
- 增加 Windows 打包和版本信息。
- 增加客户端端到端启动/连接/断开测试。

## 验收标准

- 实时模式默认 15ms 视频接收延迟配置，不启用 FEC。
- 花屏风险高的 `latest frame + drop-on-latency + queue=1` 方案不得作为默认。
- VM1/VM2 均可启动、连接、断开、停止。
- 物理屏模式可切换 active source，客户端输入能跟随目标 VM。
- UI 不展示敏感密码；日志面板必须裁剪和脱敏。
