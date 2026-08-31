import assert from "node:assert/strict";
import test from "node:test";
import { summarizeSnapshot } from "../src/agent/agentRunner.js";
import type { DesktopContextSnapshot } from "../src/hostClient.js";

const snapshot: DesktopContextSnapshot = {
  id: "ctx-desktop",
  capturedAt: new Date().toISOString(),
  cursor: { x: -200, y: 300 },
  foregroundWindow: {
    hwnd: "0x1", processId: 100, processName: "explorer", title: "Program Manager",
    className: "Progman", bounds: { x: -1920, y: 0, width: 4480, height: 1440 },
    monitorId: "laptop", dpi: 120,
  },
  windowUnderCursor: null,
  targetWindow: null,
  focusedElement: {
    name: "Previously focused.txt", controlType: "ListItem",
    bounds: { x: -500, y: 100, width: 80, height: 60 },
  },
  elementUnderCursor: { name: "Desktop", controlType: "List" },
  selectedDesktopItems: [],
  selectedDesktopItemCount: 0,
  selectedDesktopItemsTruncated: false,
  monitors: [
    {
      id: "laptop", deviceName: "DISPLAY1", isPrimary: true,
      bounds: { x: -1920, y: 0, width: 1920, height: 1080 },
      workArea: { x: -1920, y: 0, width: 1920, height: 1040 }, dpi: 120,
    },
    {
      id: "external", deviceName: "DISPLAY2", isPrimary: false,
      bounds: { x: 0, y: 0, width: 2560, height: 1440 },
      workArea: { x: 0, y: 0, width: 2560, height: 1400 }, dpi: 96,
    },
  ],
};

test("summary distinguishes keyboard focus, desktop selection, and all monitors", () => {
  const summary = JSON.parse(summarizeSnapshot(snapshot));

  assert.equal(summary.focusedElement.name, "Previously focused.txt");
  assert.match(summary.focusedElement.meaning, /does not imply selection/);
  assert.deepEqual(summary.selectedDesktopItems, []);
  assert.equal(summary.selectedDesktopItemCount, 0);
  assert.equal(summary.selectedDesktopItemsTruncated, false);
  assert.equal(summary.elementUnderCursor.name, "Desktop");
  assert.equal(summary.cursor.monitorId, "laptop");
  assert.equal(summary.monitors.length, 2);
  assert.deepEqual(summary.monitors.map((monitor: { dpi: number }) => monitor.dpi), [120, 96]);
});

test("summary reports actual selected desktop items separately", () => {
  const selected = {
    ...snapshot,
    selectedDesktopItems: [{ name: "Selected.txt", controlType: "ListItem" }],
    selectedDesktopItemCount: 1,
  } satisfies DesktopContextSnapshot;

  const summary = JSON.parse(summarizeSnapshot(selected));
  assert.deepEqual(summary.selectedDesktopItems.map((item: { name: string }) => item.name), ["Selected.txt"]);
});
