import assert from "node:assert/strict";
import test from "node:test";
import { defaultDesktops } from "../src/defaults.js";
import { filterDesktops, formatUptime, modeLabel } from "../src/filters.js";

test("desktop filtering supports status, physical output, and port search", () => {
  const desktops = defaultDesktops();
  assert.equal(filterDesktops(desktops, "running", "").length, 2);
  assert.equal(filterDesktops(desktops, "stopped", "").length, 1);
  assert.equal(filterDesktops(desktops, "physical", "").map((item) => item.id).join(","), "vm2");
  assert.equal(filterDesktops(desktops, "all", "5906").map((item) => item.id).join(","), "vm2");
});

test("labels are stable for user-facing modes", () => {
  assert.equal(modeLabel("realtime60"), "实时 60fps");
  assert.equal(modeLabel("powersave"), "节能 15-60fps");
  assert.equal(modeLabel("physical"), "物理屏输出");
  assert.equal(formatUptime(3660), "1h 1m");
});
