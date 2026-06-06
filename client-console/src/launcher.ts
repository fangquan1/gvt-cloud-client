import { CLIENT_DEFAULTS } from "./defaults.js";
import type { ClientDefaults, Desktop, LinkStatus, ServerConfig, ViewerLaunchPlan } from "./models.js";

export function buildViewerArgs(
  desktop: Desktop,
  server: ServerConfig,
  defaults: ClientDefaults = CLIENT_DEFAULTS
): string[] {
  const args = [
    "--spice-host", server.host,
    "--spice-port", String(desktop.ports.spice),
    "--input-host", desktop.address || server.host,
    "--input-port", String(desktop.ports.input),
    "--source-width", String(desktop.resolution.width),
    "--source-height", String(desktop.resolution.height),
    "--latency", String(defaults.videoLatencyMs),
    "--no-drop-on-latency"
  ];

  if (defaults.nativeInput) {
    args.push("--native-input");
  } else {
    args.push("--spice-input");
  }
  if (defaults.invertCase) {
    args.push("--invert-case");
  }
  if (desktop.mode !== "physical") {
    args.push("--video-port", String(desktop.ports.video));
  }
  return args;
}

export function buildLaunchPlan(
  desktop: Desktop,
  server: ServerConfig,
  defaults: ClientDefaults = CLIENT_DEFAULTS
): ViewerLaunchPlan {
  const physical = desktop.mode === "physical";
  const links: LinkStatus = {
    video: physical ? "disabled" : "connecting",
    input: desktop.keyboardSource === "client" ? "connecting" : "idle",
    audio: desktop.audioSource === "client" ? "connecting" : "disabled"
  };
  const args = buildViewerArgs(desktop, server, defaults);
  return {
    desktopId: desktop.id,
    title: desktop.name,
    physical,
    videoEnabled: !physical,
    resolution: desktop.resolution,
    links,
    args,
    summary: physical
      ? `${desktop.name} uses ${desktop.physicalConnector || "physical output"}; client keeps input/audio focus.`
      : `${desktop.name} uses H.264 RTP ${desktop.ports.video}, native input ${desktop.ports.input}, SPICE audio ${desktop.ports.spice}.`
  };
}

export function modePayload(mode: Desktop["mode"], defaults: ClientDefaults = CLIENT_DEFAULTS): Record<string, number | string> {
  if (mode === "realtime60") {
    return { mode, capture_ms: defaults.realtime60CaptureMs, idle_after_ms: 0, idle_probe_ms: 0 };
  }
  if (mode === "realtime30") {
    return { mode, capture_ms: defaults.realtime30CaptureMs, idle_after_ms: 0, idle_probe_ms: 0 };
  }
  if (mode === "powersave") {
    return {
      mode,
      capture_ms: defaults.realtime60CaptureMs,
      idle_capture_ms: defaults.powersaveIdleCaptureMs,
      idle_after_ms: defaults.powersaveIdleAfterMs,
      idle_probe_ms: defaults.powersaveIdleProbeMs
    };
  }
  return { mode };
}
