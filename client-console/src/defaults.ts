import type { ClientDefaults, Desktop, HostStatus, ServerConfig } from "./models.js";

export const CLIENT_DEFAULTS: ClientDefaults = {
  videoLatencyMs: 15,
  fecEnabled: false,
  dropOnLatency: false,
  nativeInput: true,
  invertCase: true,
  realtime60CaptureMs: 16,
  realtime30CaptureMs: 33,
  powersaveIdleCaptureMs: 66,
  powersaveIdleAfterMs: 1500,
  powersaveIdleProbeMs: 500
};

export const DEFAULT_SERVER: ServerConfig = {
  id: "openeuler111",
  name: "openeuler111",
  host: "192.168.0.188",
  managementPort: 8098,
  authMethod: "password",
  username: "root"
};

export function defaultStatus(now = new Date()): HostStatus {
  return {
    online: true,
    hostName: "openeuler111",
    version: "gvt-outputd dev",
    connector: "DP-1",
    activeSource: "vm1",
    activeVmCount: 2,
    cpuLoadPercent: 42,
    availableMemoryMiB: 1980,
    failureCount: 0,
    refreshedAt: now.toISOString()
  };
}

export function defaultDesktops(): Desktop[] {
  return [
    {
      id: "vm1",
      name: "win10-vm1",
      address: "192.168.0.188",
      status: "running",
      mode: "realtime60",
      gvtProfile: "i915-GVTg_V5_8",
      resources: { vcpus: 4, memoryMiB: 4096 },
      resolution: { width: 1024, height: 768 },
      ports: { video: 5004, input: 5905, spice: 5900 },
      runtime: { uptimeSeconds: 7360, fps: 60, latencyMs: 15, droppedPackets: 0, encodeFailures: 0 },
      thumbnailUrl: "assets/desktop-win10.png",
      qemuSummary: "gvt-stream h264 rtp + spice audio + native input",
      qemuCommand: {
        args: ["/usr/local/src/project/qemu/build/qemu-system-x86_64", "--nodefaults", "-enable-kvm", "-cpu", "host", "-m", "4096", "-smp", "4", "-name", "vm1"],
        line: "/usr/local/src/project/qemu/build/qemu-system-x86_64 --nodefaults -enable-kvm -cpu host -m 4096 -smp 4 -name vm1"
      },
      physicalConnector: "DP-1",
      keyboardSource: "client",
      audioSource: "client"
    },
    {
      id: "vm2",
      name: "win10-vm2",
      address: "192.168.0.188",
      status: "running",
      mode: "physical",
      gvtProfile: "i915-GVTg_V5_8",
      resources: { vcpus: 4, memoryMiB: 4096 },
      resolution: { width: 1024, height: 768 },
      ports: { video: 5006, input: 5906, spice: 5901 },
      runtime: { uptimeSeconds: 4120, fps: 60, latencyMs: 15, droppedPackets: 0, encodeFailures: 0 },
      thumbnailUrl: "assets/desktop-win10.png",
      qemuSummary: "published dmabuf -> gvt-outputd -> DP/HDMI",
      qemuCommand: {
        args: ["/usr/local/src/project/qemu/build/qemu-system-x86_64", "--nodefaults", "-enable-kvm", "-cpu", "host", "-m", "4096", "-smp", "4", "-name", "vm2"],
        line: "/usr/local/src/project/qemu/build/qemu-system-x86_64 --nodefaults -enable-kvm -cpu host -m 4096 -smp 4 -name vm2"
      },
      physicalConnector: "DP-1",
      keyboardSource: "client",
      audioSource: "client"
    },
    {
      id: "vm3",
      name: "win10-lab-offline",
      address: "192.168.0.188",
      status: "stopped",
      mode: "powersave",
      gvtProfile: "i915-GVTg_V5_4",
      resources: { vcpus: 4, memoryMiB: 4096 },
      resolution: { width: 1920, height: 1200 },
      ports: { video: 5010, input: 5910, spice: 5902 },
      runtime: { uptimeSeconds: 0 },
      thumbnailUrl: "assets/desktop-win10.png",
      qemuSummary: "overlay ready, vm stopped",
      qemuCommand: { args: [], line: "" },
      keyboardSource: "client",
      audioSource: "client"
    }
  ];
}
