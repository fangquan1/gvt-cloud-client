import assert from "node:assert/strict";
import test from "node:test";
import { derivePorts, directEndpointToDesktop, endpointToServerConfig, parseDirectEndpoint } from "../src/directConnect.js";
import { buildViewerArgs } from "../src/launcher.js";

test("direct endpoint parser accepts host:port and derives companion ports", () => {
  const endpoint = parseDirectEndpoint("192.168.0.188:5006");
  assert.equal(endpoint.host, "192.168.0.188");
  assert.deepEqual(endpoint.ports, { video: 5006, spice: 5901, input: 5906 });
});

test("direct endpoint parser uses vm1 defaults when port is omitted", () => {
  const endpoint = parseDirectEndpoint("192.168.0.188");
  assert.equal(endpoint.videoPort, 5004);
  assert.deepEqual(derivePorts(endpoint.videoPort), { video: 5004, spice: 5900, input: 5905 });
});

test("direct connection launch args include codec and low latency defaults", () => {
  const endpoint = parseDirectEndpoint("192.168.0.188:5004");
  const args = buildViewerArgs(directEndpointToDesktop(endpoint), endpointToServerConfig(endpoint));
  assert.equal(args[args.indexOf("--video-codec") + 1], "h265");
  assert.equal(args[args.indexOf("--latency") + 1], "15");
  assert.equal(args.includes("--no-drop-on-latency"), true);
  assert.equal(args[args.indexOf("--spice-port") + 1], "5900");
  assert.equal(args[args.indexOf("--input-port") + 1], "5905");
});
