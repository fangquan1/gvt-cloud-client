import assert from "node:assert/strict";
import test from "node:test";
import { JSDOM } from "jsdom";

test("app shell renders mock desktops and launches the native viewer", async () => {
  const dom = new JSDOM("<!doctype html><html><body><div id=\"app\"></div></body></html>", {
    url: "http://localhost/?mock=1",
    pretendToBeVisual: true
  });
  const previousWindow = globalThis.window;
  const previousDocument = globalThis.document;
  const previousLocalStorage = globalThis.localStorage;
  const previousSessionStorage = globalThis.sessionStorage;

  Object.defineProperty(globalThis, "window", { value: dom.window, configurable: true });
  Object.defineProperty(globalThis, "document", { value: dom.window.document, configurable: true });
  Object.defineProperty(globalThis, "localStorage", { value: dom.window.localStorage, configurable: true });
  Object.defineProperty(globalThis, "sessionStorage", { value: dom.window.sessionStorage, configurable: true });
  Object.defineProperty(globalThis, "fetch", {
    value: async (url: string, init?: RequestInit) => {
      assert.equal(url, "/launch-viewer");
      const payload = JSON.parse(String(init?.body || "{}")) as { args?: string[] };
      assert.equal(payload.args?.includes("--native-input"), true);
      return { ok: true, json: async () => ({ ok: true, pid: 1234 }) };
    },
    configurable: true
  });
  dom.window.localStorage.setItem("gvt-cloud-client.apiMode", "mock");

  try {
    await import("../src/main.js");
    await new Promise((resolve) => setTimeout(resolve, 10));

    assert.equal(dom.window.document.querySelector("h1")?.textContent, "云桌面");
    assert.equal(dom.window.document.querySelectorAll(".desktop-card").length, 3);
    assert.equal(dom.window.document.body.textContent?.includes("FEC 关闭"), true);

    const connectButton = dom.window.document.querySelector('[data-connect="vm1"]');
    assert.ok(connectButton);
    connectButton.dispatchEvent(new dom.window.Event("click", { bubbles: true }));
    await new Promise((resolve) => setTimeout(resolve, 10));

    const viewer = dom.window.document.querySelector("#viewerBackdrop");
    assert.equal(viewer?.classList.contains("hidden"), true);
  } finally {
    Object.defineProperty(globalThis, "window", { value: previousWindow, configurable: true });
    Object.defineProperty(globalThis, "document", { value: previousDocument, configurable: true });
    Object.defineProperty(globalThis, "localStorage", { value: previousLocalStorage, configurable: true });
    Object.defineProperty(globalThis, "sessionStorage", { value: previousSessionStorage, configurable: true });
    Reflect.deleteProperty(globalThis, "fetch");
    dom.window.close();
  }
});
