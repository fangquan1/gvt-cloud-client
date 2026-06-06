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

export class ApiError extends Error {
  readonly status: number;

  constructor(message: string, status: number) {
    super(message);
    this.name = "ApiError";
    this.status = status;
  }
}

export class HttpApiClient implements ApiClient {
  private sessionToken = "";

  constructor(private readonly config: ServerConfig) {}

  async login(_config: ServerConfig, request: LoginRequest): Promise<Session> {
    const session = await this.post<Session>("/api/login", request, false);
    this.sessionToken = session.token;
    return session;
  }

  status(): Promise<HostStatus> {
    return this.get<HostStatus>("/api/status");
  }

  desktops(): Promise<Desktop[]> {
    return this.get<Desktop[]>("/api/desktops");
  }

  desktop(id: string): Promise<Desktop> {
    return this.get<Desktop>(`/api/desktops/${encodeURIComponent(id)}`);
  }

  startDesktop(id: string): Promise<Desktop> {
    return this.post<Desktop>(`/api/desktops/${encodeURIComponent(id)}/start`, {});
  }

  stopDesktop(id: string): Promise<Desktop> {
    return this.post<Desktop>(`/api/desktops/${encodeURIComponent(id)}/stop`, {});
  }

  restartDesktop(id: string): Promise<Desktop> {
    return this.post<Desktop>(`/api/desktops/${encodeURIComponent(id)}/restart`, {});
  }

  setDesktopMode(id: string, request: ModeRequest): Promise<Desktop> {
    return this.post<Desktop>(`/api/desktops/${encodeURIComponent(id)}/mode`, request);
  }

  selectOutput(id: string): Promise<HostStatus> {
    return this.post<HostStatus>("/api/output/select", { id });
  }

  async logs(id: string): Promise<LogSummary> {
    const result = await this.get<LogSummary>(`/api/logs/${encodeURIComponent(id)}`);
    const trimmed = trimLogLines(result.lines);
    return { ...result, ...trimmed };
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
      throw new ApiError(`${method} ${path} failed`, response.status);
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
