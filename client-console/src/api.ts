import type {
  ApiClient,
  CreateDesktopRequest,
  Desktop,
  DesktopMode,
  DesktopStatus,
  GvtProfile,
  HostStatus,
  LoginRequest,
  LogSummary,
  ModeRequest,
  ResourceRequest,
  ServerConfig,
  Session
} from "./models.js";
import { trimLogLines } from "./security.js";

interface ServerSession {
  token: string;
  expires_at?: number;
  expiresAt?: string;
  user?: string;
}

interface ServerStatus {
  version?: string;
  host?: {
    name?: string;
    memory?: {
      MemAvailable?: number;
    } | null;
  };
  outputd?: {
    active?: string;
    connector?: string;
    failed?: number;
  };
  active_source?: string;
  input_source?: string;
  audio_source?: string;
  desktops?: ServerDesktop[];
}

interface ServerDesktop {
  id: string;
  name?: string;
  state?: string;
  mode?: string;
  gvt_profile?: string;
  ports?: {
    video?: number;
    input?: number;
    spice?: number;
    audio?: number;
  };
  resolution?: string;
  resources?: {
    vcpus?: number;
    memory_mib?: number;
  };
  qemu_command?: {
    args?: string[];
    line?: string;
  };
  tap?: string;
  mac?: string;
  overlay?: string;
  disk_size_gib?: number;
  install_iso?: string;
  gvt_stream?: {
    fps?: number | null;
    capture_ms?: number | null;
    encoded?: number | null;
    encode_failures?: number | null;
  };
}

interface ServerDesktopList {
  desktops: ServerDesktop[];
}

interface ServerGvtProfile {
  id: string;
  resolution?: string;
  available_instances?: number;
  description?: string;
}

interface ServerGvtProfileList {
  profiles: ServerGvtProfile[];
}

interface ServerLog {
  id?: string;
  log?: string;
  lines?: string[];
  truncated?: boolean;
}

export class ApiError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export class HttpApiClient implements ApiClient {
  constructor(private readonly config: ServerConfig, private sessionToken = "") {}

  async login(_config: ServerConfig, request: LoginRequest): Promise<Session> {
    const session = await this.post<ServerSession>("/api/login", request, false);
    this.sessionToken = session.token;
    return {
      token: session.token,
      user: session.user || request.username || this.config.username || "user",
      expiresAt: session.expiresAt || (session.expires_at ? new Date(session.expires_at * 1000).toISOString() : undefined)
    };
  }

  async status(): Promise<HostStatus> {
    return normalizeStatus(await this.get<ServerStatus>("/api/status"), this.config);
  }

  async desktops(): Promise<Desktop[]> {
    const result = await this.get<ServerDesktopList | ServerDesktop[]>("/api/desktops");
    const items = Array.isArray(result) ? result : result.desktops;
    return items.map((item) => normalizeDesktop(item, this.config));
  }

  async gvtProfiles(): Promise<GvtProfile[]> {
    const result = await this.get<ServerGvtProfileList | ServerGvtProfile[]>("/api/gvtg-profiles");
    const items = Array.isArray(result) ? result : result.profiles;
    return items.map(normalizeGvtProfile);
  }

  async desktop(id: string): Promise<Desktop> {
    return normalizeDesktop(await this.get<ServerDesktop>(`/api/desktops/${encodeURIComponent(id)}`), this.config);
  }

  async createDesktop(request: CreateDesktopRequest): Promise<Desktop> {
    return normalizeDesktop(
      await this.post<ServerDesktop>("/api/desktops", {
        name: request.name,
        vcpus: request.vcpus,
        memory_mib: request.memoryMiB,
        disk_size_gib: request.diskSizeGiB,
        qcow2_path: request.qcow2Path || "",
        iso_path: request.isoPath || "",
        mode: toServerMode(request.mode),
        gvt_profile: request.gvtProfile
      }),
      this.config
    );
  }

  async startDesktop(id: string): Promise<Desktop> {
    return normalizeDesktop(await this.post<ServerDesktop>(`/api/desktops/${encodeURIComponent(id)}/start`, {}), this.config);
  }

  async stopDesktop(id: string): Promise<Desktop> {
    return normalizeDesktop(await this.post<ServerDesktop>(`/api/desktops/${encodeURIComponent(id)}/stop`, {}), this.config);
  }

  async restartDesktop(id: string): Promise<Desktop> {
    return normalizeDesktop(await this.post<ServerDesktop>(`/api/desktops/${encodeURIComponent(id)}/restart`, {}), this.config);
  }

  async setDesktopMode(id: string, request: ModeRequest): Promise<Desktop> {
    const body = { mode: toServerMode(request.mode) };
    return normalizeDesktop(await this.post<ServerDesktop>(`/api/desktops/${encodeURIComponent(id)}/mode`, body), this.config);
  }

  async setDesktopProfile(id: string, profile: string): Promise<Desktop> {
    return normalizeDesktop(
      await this.post<ServerDesktop>(`/api/desktops/${encodeURIComponent(id)}/profile`, { profile }),
      this.config
    );
  }

  async setDesktopResources(id: string, request: ResourceRequest): Promise<Desktop> {
    return normalizeDesktop(
      await this.post<ServerDesktop>(`/api/desktops/${encodeURIComponent(id)}/resources`, {
        vcpus: request.vcpus,
        memory_mib: request.memoryMiB
      }),
      this.config
    );
  }

  async setDesktopIso(id: string, request: { isoPath: string }): Promise<Desktop> {
    return normalizeDesktop(
      await this.post<ServerDesktop>(`/api/desktops/${encodeURIComponent(id)}/iso`, {
        iso_path: request.isoPath
      }),
      this.config
    );
  }

  async selectOutput(id: string): Promise<HostStatus> {
    return normalizeStatus(await this.post<ServerStatus>("/api/output/select", { source: id }), this.config);
  }

  async logs(id: string): Promise<LogSummary> {
    const result = await this.get<ServerLog>(`/api/logs/${encodeURIComponent(id)}`);
    const rawLines = result.lines || (result.log || "").split(/\r?\n/);
    const trimmed = trimLogLines(rawLines);
    return { desktopId: result.id || id, ...trimmed };
  }

  private url(path: string): string {
    return `http://${this.config.host}:${this.config.managementPort}${path}`;
  }

  private get<T>(path: string): Promise<T> {
    return this.request<T>("GET", path);
  }

  private post<T>(path: string, body: unknown, withAuth = true): Promise<T> {
    return this.request<T>("POST", path, body, withAuth);
  }

  private async request<T>(method: string, path: string, body?: unknown, withAuth = true): Promise<T> {
    const headers: Record<string, string> = { "Accept": "application/json" };
    if (body !== undefined) {
      headers["Content-Type"] = "application/json";
    }
    if (withAuth && this.sessionToken) {
      headers.Authorization = `Bearer ${this.sessionToken}`;
    }

    const response = await fetch(this.url(path), {
      method,
      headers,
      body: body === undefined ? undefined : JSON.stringify(body)
    });
    if (!response.ok) {
      const payload = await response.json().catch(() => ({ error: "" })) as { error?: string };
      throw new ApiError(payload.error || `${method} ${path} failed`, response.status);
    }
    return await response.json() as T;
  }
}

export function createApiClient(config: ServerConfig, useMock: boolean): ApiClient {
  if (useMock) {
    throw new Error("MockApiClient is imported from mockApi.ts to keep test bundles explicit");
  }
  return new HttpApiClient(config);
}

function normalizeStatus(raw: ServerStatus, config: ServerConfig): HostStatus {
  const desktops = raw.desktops || [];
  return {
    online: true,
    hostName: raw.host?.name || config.name || config.host,
    version: raw.version || "gvt-cloud-server",
    connector: raw.outputd?.connector || "",
    activeSource: raw.active_source || raw.outputd?.active || "",
    activeVmCount: desktops.filter((item) => item.state === "running").length,
    cpuLoadPercent: 0,
    availableMemoryMiB: raw.host?.memory?.MemAvailable
      ? Math.round(raw.host.memory.MemAvailable / 1024 / 1024)
      : 0,
    failureCount: Number(raw.outputd?.failed || 0),
    refreshedAt: new Date().toISOString()
  };
}

function normalizeDesktop(raw: ServerDesktop, config: ServerConfig): Desktop {
  const resolution = parseResolution(raw.resolution || "1024x768");
  const fps = raw.gvt_stream?.fps ?? undefined;
  const encodeFailures = raw.gvt_stream?.encode_failures ?? undefined;
  const mode = fromServerMode(raw.mode);
  return {
    id: raw.id,
    name: raw.name || raw.id,
    address: config.host,
    status: fromServerStatus(raw.state),
    mode,
    gvtProfile: raw.gvt_profile || "",
    resources: {
      vcpus: Number(raw.resources?.vcpus || 4),
      memoryMiB: Number(raw.resources?.memory_mib || 4096)
    },
    resolution,
    ports: {
      video: Number(raw.ports?.video || 0),
      input: Number(raw.ports?.input || 0),
      spice: Number(raw.ports?.spice || raw.ports?.audio || 0)
    },
    runtime: {
      uptimeSeconds: 0,
      fps: fps === null ? undefined : fps,
      latencyMs: 15,
      droppedPackets: 0,
      encodeFailures: encodeFailures === null ? undefined : encodeFailures
    },
    thumbnailUrl: "assets/desktop-win10.png",
    qemuSummary: summaryFor(raw),
    qemuCommand: {
      args: Array.isArray(raw.qemu_command?.args) ? raw.qemu_command.args.map(String) : [],
      line: raw.qemu_command?.line || ""
    },
    diskPath: raw.overlay || undefined,
    diskSizeGiB: raw.disk_size_gib ? Number(raw.disk_size_gib) : undefined,
    installIso: raw.install_iso || undefined,
    physicalConnector: mode === "physical" ? "DP/HDMI" : undefined,
    keyboardSource: "client",
    audioSource: "client"
  };
}

function normalizeGvtProfile(raw: ServerGvtProfile): GvtProfile {
  return {
    id: raw.id,
    resolution: parseResolution(raw.resolution || "1024x768"),
    availableInstances: Number(raw.available_instances || 0),
    description: raw.description || ""
  };
}

function parseResolution(value: string): { width: number; height: number } {
  const match = /^(\d+)x(\d+)$/i.exec(value.trim());
  if (!match) {
    return { width: 1024, height: 768 };
  }
  return { width: Number(match[1]), height: Number(match[2]) };
}

function fromServerStatus(value?: string): DesktopStatus {
  if (value === "running" || value === "starting" || value === "stopping" || value === "error") {
    return value;
  }
  return "stopped";
}

function fromServerMode(value?: string): DesktopMode {
  if (value === "realtime30") {
    return "realtime30";
  }
  if (value === "power_save" || value === "powersave") {
    return "powersave";
  }
  if (value === "physical") {
    return "physical";
  }
  return "realtime60";
}

function toServerMode(value: DesktopMode): string {
  if (value === "powersave") {
    return "power_save";
  }
  if (value === "realtime60") {
    return "realtime";
  }
  return value;
}

function summaryFor(raw: ServerDesktop): string {
  const stream = raw.gvt_stream;
  if (!stream) {
    return "gvt-stream status unavailable";
  }
  const fps = stream.fps === null || stream.fps === undefined ? "-" : stream.fps.toFixed(1);
  const capture = stream.capture_ms === null || stream.capture_ms === undefined ? "-" : stream.capture_ms;
  const failures = stream.encode_failures === null || stream.encode_failures === undefined ? "-" : stream.encode_failures;
  return `gvt-stream fps=${fps} capture_ms=${capture} encode_failures=${failures}`;
}
