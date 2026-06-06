import assert from "node:assert/strict";
import test from "node:test";
import { DEFAULT_SERVER } from "../src/defaults.js";
import { MockApiClient } from "../src/mockApi.js";

test("mock API supports login, mode switch, output select, and sanitized logs", async () => {
  const api = new MockApiClient();
  const session = await api.login(DEFAULT_SERVER, { username: "tester", password: "secret" });
  assert.equal(session.user, "tester");

  const updated = await api.setDesktopMode("vm1", { mode: "physical" });
  assert.equal(updated.mode, "physical");

  const status = await api.selectOutput("vm1");
  assert.equal(status.activeSource, "vm1");

  const logs = await api.logs("vm1");
  assert.equal(logs.lines.some((line) => line.includes("should-not-leak")), false);
});
