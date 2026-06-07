import { DEFAULT_SERVER } from "./defaults.js";
import type { Desktop, FilterKey, GvtProfile, HostStatus, ServerConfig, Session, ViewerLaunchPlan } from "./models.js";

export interface AppState {
  server: ServerConfig;
  session?: Session;
  status?: HostStatus;
  desktops: Desktop[];
  gvtProfiles: GvtProfile[];
  selectedDesktopId?: string;
  filter: FilterKey;
  query: string;
  viewer?: ViewerLaunchPlan;
  apiMode: "mock" | "real";
  error?: string;
}

export type Listener = (state: AppState) => void;

export class Store {
  private state: AppState = {
    server: { ...DEFAULT_SERVER },
    desktops: [],
    gvtProfiles: [],
    filter: "all",
    query: "",
    apiMode: "real"
  };
  private listeners = new Set<Listener>();

  get(): AppState {
    return this.state;
  }

  set(patch: Partial<AppState>): void {
    this.state = { ...this.state, ...patch };
    this.emit();
  }

  subscribe(listener: Listener): () => void {
    this.listeners.add(listener);
    listener(this.state);
    return () => this.listeners.delete(listener);
  }

  private emit(): void {
    for (const listener of this.listeners) {
      listener(this.state);
    }
  }
}
