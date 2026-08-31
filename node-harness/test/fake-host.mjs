import { createServer } from "node:http";
const DELAY_MS = Number.parseInt(process.env.FAKE_HOST_DELAY_MS ?? "0", 10);
const win = (over = {}) => ({
  hwnd: "0xA022C", processId: 20676, processName: "NOTEPAD",
  executablePath: "C:/Program Files/WindowsApps/Notepad.exe",
  title: "smoke - Notepad", className: "Notepad",
  bounds: { x: 100, y: 100, width: 800, height: 600 }, dpi: 96,
  monitorId: "m0", ...over,
});
const snapshot = {
  id: "ctx-smoke", capturedAt: new Date().toISOString(),
  cursor: { x: 300, y: 200 },
  foregroundWindow: win(), windowUnderCursor: null, targetWindow: win(),
  focusedElement: { name: "Text editor", controlType: "Document", value: "hello world" },
  elementUnderCursor: null,
  screenshot: { kind: "window", imageId: "shot-smoke", filePath: "C:/captures/smoke-shot.png",
    bounds: { x: 100, y: 100, width: 800, height: 600 } },
  monitors: [{ id: "m0", isPrimary: true, bounds: { x: 0, y: 0, width: 1920, height: 1080 },
    workArea: { x: 0, y: 0, width: 1920, height: 1032 }, dpi: 96 }],
};
createServer((req, res) => {
  let body = "";
  req.on("data", (c) => (body += c));
  req.on("end", () => {
    console.log(`[fake-host] ${req.method} ${req.url} body=${body.slice(0, 120)}`);
    res.writeHead(200, { "Content-Type": "application/json" });
    const respond = () => {
      if (req.url?.includes("captureWindow"))
        res.end(JSON.stringify({ ok: true, result: { kind: "window", imageId: "shot-fresh-" + Date.now(),
          filePath: "C:/captures/smoke-shot.png" } }));
      else
        res.end(JSON.stringify({ ok: true, result: snapshot }));
    };
    if (DELAY_MS > 0) setTimeout(respond, DELAY_MS);
    else respond();
  });
}).listen(17831, "127.0.0.1", () => console.log(`[fake-host] up (delay=${DELAY_MS}ms)`));
