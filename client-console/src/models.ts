export type AuthMethod = "none" | "password" | "token";
export type DesktopStatus = "running" | "stopped" | "starting" | "stopping" | "error";
export type DesktopMode = "realtime60" | "realtime30" | "powersave" | "physical";
export type OutputSource = "client" | "box";
export type FilterKey = "all" | "running" | "stopped" | "physical";

export interface ServerConfig {
  id: string;
  name: string;
  host: string;
  managementPort: number;
  authMethod: AuthMethod;
  username?: string;
}

export interface LoginRequest {
  username?: string;
  password?: string;
  token?: string;
}

export interface Session {
  token: string;
  user: string;
  expiresAt?: string;
}

export interface HostStatus {
  online: boolean;
  hostName: string;
  version: string;
  connector: string;
  activeSource?: string;
  activeVmCount: number;
  cpuLoadPercent: number;
  availableMemoryMiB: number;
  failureCount: number;
  refreshedAt: string;
}

export interface DesktopPorts {
  video: number;
  input: number;
  spice: number;
}

export interface DesktopResolution {
  width: number;
  height: number;
}

export interface DesktopRuntime {
  uptimeSeconds: number;
  fps?: number;
  latencyMs?: number;
  droppedPackets?: number;
  encodeFailures?: number;
}

export interface DesktopResources {
  vcpus: number;
  memoryMiB: number;
}

export interface QemuCommand {
  args: string[];
  line: string;
}

export interface GvtProfile {
  id: string;
  resolution: DesktopResolution;
  availableInstances: number;
  description: string;
}

export interface Desktop {
  id: string;
  name: string;
  address: string;
  status: DesktopStatus;
  mode: DesktopMode;
  gvtProfile: string;
  resources: DesktopResources;
  resolution: DesktopResolution;
  ports: DesktopPorts;
  runtime: DesktopRuntime;
  thumbnailUrl?: string;
  qemuSummary: string;
  qemuCommand: QemuCommand;
  physicalConnector?: string;
  keyboardSource: OutputSource;
  audioSource: OutputSource;
}

export interface ModeRequest {
  mode: DesktopMode;
}

export interface ResourceRequest {
  vcpus: number;
  memoryMiB: number;
}

export interface LogSummary {
  desktopId: string;
  lines: string[];
  truncated: boolean;
}

export interface LinkStatus {
  video: "idle" | "connecting" | "connected" | "disabled" | "error";
  input: "idle" | "connecting" | "connected" | "error";
  audio: "idle" | "connecting" | "connected" | "disabled" | "error";
}

export interface ViewerLaunchPlan {
  desktopId: string;
  title: string;
  physical: boolean;
  videoEnabled: boolean;
  resolution: DesktopResolution;
  links: LinkStatus;
  args: string[];
  summary: string;
}

export interface ClientDefaults {
  videoLatencyMs: number;
  fecEnabled: boolean;
  dropOnLatency: boolean;
  nativeInput: boolean;
  invertCase: boolean;
  realtime60CaptureMs: number;
  realtime30CaptureMs: number;
  powersaveIdleCaptureMs: number;
  powersaveIdleAfterMs: number;
  powersaveIdleProbeMs: number;
}

export interface ApiClient {
  login(config: ServerConfig, request: LoginRequest): Promise<Session>;
  status(): Promise<HostStatus>;
  desktops(): Promise<Desktop[]>;
  gvtProfiles(): Promise<GvtProfile[]>;
  desktop(id: string): Promise<Desktop>;
  startDesktop(id: string): Promise<Desktop>;
  stopDesktop(id: string): Promise<Desktop>;
  restartDesktop(id: string): Promise<Desktop>;
  setDesktopMode(id: string, request: ModeRequest): Promise<Desktop>;
  setDesktopProfile(id: string, profile: string): Promise<Desktop>;
  setDesktopResources(id: string, request: ResourceRequest): Promise<Desktop>;
  selectOutput(id: string): Promise<HostStatus>;
  logs(id: string): Promise<LogSummary>;
}
