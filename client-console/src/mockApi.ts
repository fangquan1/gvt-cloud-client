import { defaultDesktops, defaultStatus } from "./defaults.js";
import type {
  ApiClient,
  Desktop,
  HostStatus,
  LoginRequest,
  LogSummary,
  ModeRequest,
  ServerConfig,
  Session
} from "./models.js";
import { trimLogLines } from "./security.js";

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

export class MockApiClient implements ApiClient {
  private items = defaultDesktops();
  private host = defaultStatus();

  async login(config: ServerConfig, request: LoginRequest): Promise<Session> {
    return {
      token: "mock-session-token",
      user: request.username || config.username || "mock",
      expiresAt: new Date(Date.now() + 3600_000).toISOString()
    };
  }

  async status(): Promise<HostStatus> {
    this.host.activeVmCount = this.items.filter((item) => item.status === "running").length;
    this.host.refreshedAt = new Date().toISOString();
    return clone(this.host);
  }

  async desktops(): Promise<Desktop[]> {
    return clone(this.items);
  }

  async desktop(id: string): Promise<Desktop> {
    return clone(this.requireDesktop(id));
  }

  async startDesktop(id: string): Promise<Desktop> {
    const desktop = this.requireDesktop(id);
    desktop.status = "running";
    desktop.runtime.uptimeSeconds = Math.max(desktop.runtime.uptimeSeconds, 1);
    return clone(desktop);
  }

  async stopDesktop(id: string): Promise<Desktop> {
    const desktop = this.requireDesktop(id);
    desktop.status = "stopped";
    desktop.runtime.uptimeSeconds = 0;
    return clone(desktop);
  }

  async restartDesktop(id: string): Promise<Desktop> {
    const desktop = this.requireDesktop(id);
    desktop.status = "running";
    desktop.runtime.uptimeSeconds = 1;
    return clone(desktop);
  }

  async setDesktopMode(id: string, request: ModeRequest): Promise<Desktop> {
    const desktop = this.requireDesktop(id);
    desktop.mode = request.mode;
    if (request.mode === "physical") {
      desktop.physicalConnector = this.host.connector;
      this.host.activeSource = desktop.id;
    }
    return clone(desktop);
  }

  async selectOutput(id: string): Promise<HostStatus> {
    this.requireDesktop(id);
    this.host.activeSource = id;
    return clone(this.host);
  }

  async logs(id: string): Promise<LogSummary> {
    this.requireDesktop(id);
    const trimmed = trimLogLines([
      "gvt-stream: encode-start fps=60 fec=0/0 latency=15ms",
      "gvt-stream-input: native input connected",
      "spice-audio: playback connected",
      "debug token=should-not-leak password=should-not-leak"
    ]);
    return { desktopId: id, ...trimmed };
  }

  private requireDesktop(id: string): Desktop {
    const desktop = this.items.find((item) => item.id === id);
    if (!desktop) {
      throw new Error(`desktop not found: ${id}`);
    }
    return desktop;
  }
}
