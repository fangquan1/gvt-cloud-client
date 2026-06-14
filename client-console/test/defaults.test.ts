import assert from "node:assert/strict";
import test from "node:test";
import { CLIENT_DEFAULTS, defaultDesktops } from "../src/defaults.js";

test("low latency defaults keep the known-good no-FEC path", () => {
  assert.equal(CLIENT_DEFAULTS.videoCodec, "h265");
  assert.equal(CLIENT_DEFAULTS.videoLatencyMs, 15);
  assert.equal(CLIENT_DEFAULTS.fecEnabled, false);
  assert.equal(CLIENT_DEFAULTS.dropOnLatency, false);
  assert.equal(CLIENT_DEFAULTS.nativeInput, true);
  assert.equal(CLIENT_DEFAULTS.invertCase, true);
});

test("vm1/vm2 baseline ports match the current integration plan", () => {
  const desktops = defaultDesktops();
  const vm1 = desktops.find((item) => item.id === "vm1");
  const vm2 = desktops.find((item) => item.id === "vm2");
  assert.deepEqual(vm1?.ports, { video: 5004, input: 5905, spice: 5900 });
  assert.deepEqual(vm2?.ports, { video: 5006, input: 5906, spice: 5901 });
});
