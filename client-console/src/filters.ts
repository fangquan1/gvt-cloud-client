import type { Desktop, FilterKey } from "./models.js";

export function formatUptime(seconds: number): string {
  if (seconds <= 0) {
    return "-";
  }
  const hours = Math.floor(seconds / 3600);
  const minutes = Math.floor((seconds % 3600) / 60);
  if (hours > 0) {
    return `${hours}h ${minutes}m`;
  }
  return `${minutes}m`;
}

export function modeLabel(mode: Desktop["mode"]): string {
  switch (mode) {
    case "realtime60":
      return "实时 60fps";
    case "realtime30":
      return "兼容 30fps";
    case "powersave":
      return "节能 15-60fps";
    case "physical":
      return "物理屏输出";
  }
}

export function statusLabel(status: Desktop["status"]): string {
  switch (status) {
    case "running":
      return "运行中";
    case "stopped":
      return "已关机";
    case "starting":
      return "启动中";
    case "stopping":
      return "停止中";
    case "error":
      return "异常";
  }
}

export function filterDesktops(items: Desktop[], filter: FilterKey, query: string): Desktop[] {
  const normalized = query.trim().toLowerCase();
  return items.filter((item) => {
    if (filter === "running" && item.status !== "running") {
      return false;
    }
    if (filter === "stopped" && item.status !== "stopped") {
      return false;
    }
    if (filter === "physical" && item.mode !== "physical") {
      return false;
    }
    if (!normalized) {
      return true;
    }
    const haystack = [
      item.name,
      item.address,
      String(item.ports.video),
      String(item.ports.input),
      String(item.ports.spice),
      item.physicalConnector || ""
    ].join(" ").toLowerCase();
    return haystack.includes(normalized);
  });
}
