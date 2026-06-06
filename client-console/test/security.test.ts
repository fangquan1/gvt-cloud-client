import assert from "node:assert/strict";
import test from "node:test";
import { publicServerConfig, redactSecrets, trimLogLines } from "../src/security.js";

test("redaction removes passwords, bearer tokens, and session fields", () => {
  const text = "password=abc token=def Authorization: Bearer secret session: xyz";
  const redacted = redactSecrets(text);
  assert.equal(redacted.includes("abc"), false);
  assert.equal(redacted.includes("def"), false);
  assert.equal(redacted.includes("secret"), false);
  assert.equal(redacted.includes("xyz"), false);
});

test("log trimming keeps the tail and reports truncation", () => {
  const result = trimLogLines(["a", "b", "c"], 2);
  assert.deepEqual(result.lines, ["b", "c"]);
  assert.equal(result.truncated, true);
});

test("public server config never returns password or token fields", () => {
  const config = publicServerConfig({ host: "example", password: "p", token: "t" });
  assert.deepEqual(config, { host: "example" });
});
