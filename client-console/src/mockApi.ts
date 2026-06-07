import { defaultDesktops, defaultStatus } from "./defaults.js";
import type {
  ApiClient,
  Desktop,
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

function clone<T>(value: T): T {
  return JSON.parse(JSON.stringify(value)) as T;
}

export class MockApiClient implements ApiClient {
  private items = defaultDesktops();
  private host = defaultStatus();
  private profiles: GvtProfile[] = [
    {
      id: "i915-GVTg_V5_4",
      resolution: { width: 1920, height: 1200 },
      availableInstances: 1,
      description: "resolution: 1920x1200"
    },
    {
      id: "i915-GVTg_V5_8",
      resolution: { width: 1024, height: 768 },
      availableInstances: 2,
      description: "resolution: 1024x768"
    }
  ];

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

  async gvtProfiles(): Promise<GvtProfile[]> {
    return clone(this.profiles);
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

  async setDesktopProfile(id: string, profile: string): Promise<Desktop> {
    const desktop = this.requireDesktop(id);
    const selected = this.profiles.find((item) => item.id === profile);
    if (!selected) {
      throw new Error(`GVT-g profile not found: ${profile}`);
    }
    desktop.gvtProfile = profile;
    desktop.resolution = selected.resolution;
    return clone(desktop);
  }

  async setDesktopResources(id: string, request: ResourceRequest): Promise<Desktop> {
    const desktop = this.requireDesktop(id);
    if (desktop.status === "running") {
      throw new Error("stop the desktop before changing CPU or memory");
    }
    desktop.resources = { vcpus: request.vcpus, memoryMiB: request.memoryMiB };
    desktop.qemuCommand = { args: [], line: "" };
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
