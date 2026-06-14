import type { Desktop, DesktopPorts, DesktopResolution, ServerConfig } from "./models.js";

export interface DirectEndpoint {
  host: string;
  videoPort: number;
  ports: DesktopPorts;
  resolution: DesktopResolution;
}

export const DEFAULT_DIRECT_ENDPOINT = "192.168.0.188:5004";

export function parseDirectEndpoint(value: string): DirectEndpoint {
  const cleaned = value.trim()
    .replace(/^gvt:\/\//i, "")
    .replace(/^spice:\/\//i, "");
  if (!cleaned) {
    throw new Error("Enter a server address, for example 192.168.0.188:5004");
  }

  const match = cleaned.match(/^([^:/\s]+)(?::([0-9]{1,5}))?$/);
  if (!match) {
    throw new Error("Use host:port, for example 192.168.0.188:5004");
  }

  const host = match[1];
  const videoPort = Number(match[2] || 5004);
  if (!host || videoPort < 1 || videoPort > 65535) {
    throw new Error("The server address or port is invalid");
  }

  return {
    host,
    videoPort,
    ports: derivePorts(videoPort),
    resolution: { width: 1920, height: 1200 }
  };
}

export function derivePorts(videoPort: number): DesktopPorts {
  const slot = videoPort >= 5004 ? Math.max(0, Math.floor((videoPort - 5004) / 4)) : 0;
  return {
    video: videoPort,
    spice: 5900 + slot,
    input: 5905 + slot
  };
}

export function endpointToServerConfig(endpoint: DirectEndpoint): ServerConfig {
  return {
    id: endpoint.host,
    name: endpoint.host,
    host: endpoint.host,
    managementPort: 0,
    authMethod: "none"
  };
}

export function directEndpointToDesktop(endpoint: DirectEndpoint): Desktop {
  return {
    id: `direct-${endpoint.host}-${endpoint.videoPort}`,
    name: endpoint.host,
    address: endpoint.host,
    status: "running",
    mode: "realtime60",
    gvtProfile: "direct",
    resources: { vcpus: 0, memoryMiB: 0 },
    resolution: endpoint.resolution,
    ports: endpoint.ports,
    runtime: { uptimeSeconds: 0, latencyMs: 15 },
    qemuSummary: `Direct gvt-stream connection to ${endpoint.host}:${endpoint.videoPort}`,
    qemuCommand: { args: [], line: "" },
    keyboardSource: "client",
    audioSource: "client"
  };
}
