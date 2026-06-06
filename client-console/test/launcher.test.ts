import assert from "node:assert/strict";
import test from "node:test";
import { DEFAULT_SERVER, defaultDesktops } from "../src/defaults.js";
import { buildLaunchPlan, buildViewerArgs, modePayload } from "../src/launcher.js";

test("viewer args disable drop-on-latency and keep native input", () => {
  const desktop = defaultDesktops()[0];
  const args = buildViewerArgs(desktop, DEFAULT_SERVER);
  assert.equal(args.includes("--latency"), true);
  assert.equal(args[args.indexOf("--latency") + 1], "15");
  assert.equal(args.includes("--no-drop-on-latency"), true);
  assert.equal(args.includes("--drop-on-latency"), false);
  assert.equal(args.includes("--native-input"), true);
  assert.equal(args.includes("--invert-case"), true);
});

test("physical output launch plan disables local video but keeps input and audio focus", () => {
  const desktop = defaultDesktops()[1];
  const plan = buildLaunchPlan(desktop, DEFAULT_SERVER);
  assert.equal(plan.physical, true);
  assert.equal(plan.videoEnabled, false);
  assert.equal(plan.links.video, "disabled");
  assert.equal(plan.links.input, "connecting");
  assert.equal(plan.links.audio, "connecting");
  assert.equal(plan.args.includes("--video-port"), false);
});

test("powersave mode payload exposes the agreed idle parameters", () => {
  assert.deepEqual(modePayload("powersave"), {
    mode: "powersave",
    capture_ms: 16,
    idle_capture_ms: 66,
    idle_after_ms: 1500,
    idle_probe_ms: 500
  });
});
