#!/usr/bin/env python3
"""Opt-in, model-free validation through the certificate-signed INSTALLED host.
LaunchServices supplies the permission identity, not terminal-inherited probe rights.
Only the two-window receiving fixture gets input; the user's normal host stays running.
"""
import json
import os
import pathlib
import plistlib
import re
import secrets
import shutil
import socket
import subprocess
import tempfile
import time
import urllib.request

if os.environ.get("PI_OS_INSTALLED_TEST") != "1":
    raise SystemExit("Coordinate an idle desktop, then set PI_OS_INSTALLED_TEST=1.")
ROOT = pathlib.Path(__file__).resolve().parents[2]
credentials_allowed = os.environ.get('PI_OS_TEST_CREDENTIALS') == '1'
APP = pathlib.Path(os.environ.get("PI_OS_TEST_APP", os.environ.get("PI_OS_INSTALL_PATH", pathlib.Path.home() / "Applications/pi-os.app"))).resolve()
ORCA = os.environ.get("ORCA_CLI_COMMAND") or ("orca-dev" if os.environ.get("ORCA_DEV_REPO_ROOT") else "orca")
root = pathlib.Path(tempfile.mkdtemp(prefix="pi-os-installed-test-"))
token = secrets.token_hex(32)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0)); return s.getsockname()[1]

host_port, node_port = free_port(), free_port()
host_pid = None
fixture = None
record_file = root / "invocation.json"
state = root / "state.json"
report = {"checks": [], "appUnderTest": str(APP), "modelCalls": 0}

def request(port, path, body=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(f"http://127.0.0.1:{port}{path}", data=data,
                                 headers={"X-Harness-Token": token, "Content-Type": "application/json"})
    with opener.open(req, timeout=15) as response: return json.load(response)

def wait_for(predicate, timeout=12):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.1)
    raise RuntimeError("Timed out waiting for test state")

def gui(*arguments):
    result = subprocess.run([ORCA, "computer", *arguments, "--no-screenshot", "--json"], capture_output=True, text=True, timeout=15)
    payload = json.loads(result.stdout)
    if not payload.get("ok"): raise RuntimeError(payload.get("error"))
    return payload["result"]

def command(name, window="A"):
    if fixture.poll() is not None: raise RuntimeError("Fixture exited (possible external input); validation stopped")
    fixture.stdin.write((json.dumps({"command": name, "window": window}) + "\n").encode()); fixture.stdin.flush()
    time.sleep(.2)

def current():
    command("state")
    return {w["name"]: w for w in json.loads(state.read_text())["windows"]}

def tool(name, args): return request(host_port, "/tools/" + name, {"arguments": args})
def check(name, condition):
    if not condition: raise AssertionError(name)
    report["checks"].append(name); print("PASS:", name, flush=True)

try:
    signature = subprocess.run(["codesign", "-dv", "--verbose=4", str(APP)], capture_output=True, text=True, check=True)
    check("certificate-signed application",  "Authority=Apple Development:" in signature.stderr or "Authority=Developer ID Application:" in signature.stderr)
    subprocess.run(["codesign", "--verify", "--strict", str(APP)], check=True)
    # A receiving-only disposable app. It requests no permissions and never injects events.
    receiver = root / "Input Fixture.app"
    mac = receiver / "Contents/MacOS"; mac.mkdir(parents=True)
    shutil.copy(ROOT / "host-macos/.build/debug/pi-os-input-fixture", mac / "fixture")
    (receiver / "Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier": "dev.pi-os.input-fixture",
        "CFBundleName": "pi-os input fixture", "CFBundleExecutable": "fixture", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0"}))
    subprocess.run(["codesign", "--force", "--sign", "-", str(receiver)], check=True)
    fixture_log = open(root / "fixture.log", "w")
    fixture = subprocess.Popen([str(mac / "fixture"), str(state)], stdin=subprocess.PIPE, stdout=fixture_log, stderr=fixture_log)
    wait_for(state.exists)
    # open --env passes only this test's overrides through LaunchServices; no global defaults.
    env = {"PI_OS_INSTALLED_TEST": "1", "PI_OS_AGENT": "0", "PI_OFFLINE": "1", "PI_OS_TOKEN": token,
        "PI_OS_HOST_PORT": str(host_port), "PI_OS_NODE_PORT": str(node_port), "PI_OS_SUPPORT_DIR": str(root / "support"),
        "PI_OS_NODE_ENTRY": str(ROOT / "host-macos/scripts/installed-fixture-harness.mjs"),
        "PI_OS_TEST_RECORD_FILE": str(record_file), "PI_OS_NODE_WARM_TTL_SECONDS": "3",
        "PI_OS_HOTKEY": "Ctrl+Option+Cmd+Shift+Space"}
    launch = ["open", "-n", "-g", "--stdout", str(root / "host.log"), "--stderr", str(root / "host.log")]
    for key, value in env.items(): launch += ["--env", f"{key}={value}"]
    subprocess.run(launch + [str(APP), '--args', '-allowCredentialFieldInput', 'YES' if credentials_allowed else 'NO'], check=True)
    def find_host():
        result = subprocess.run(["lsof", "-t", f"-iTCP:{host_port}", "-sTCP:LISTEN"], capture_output=True, text=True)
        return int(result.stdout.strip()) if result.stdout.strip() else None
    host_pid = wait_for(find_host)
    check("LaunchServices host readiness", request(host_port, "/health")["service"] == "macos-host")
    catalog = request(host_port, "/tools")["tools"]
    check("signed host exposes all nine native routes (AX + PostEvent granted)", len(catalog) == 9)
    command("front", "A")
    fixture_a = current()["A"]
    # Observe the fixture before delivering the test's dedicated Carbon shortcut.
    gui("get-app-state", "--app", f"pid:{fixture.pid}", "--window-id", str(fixture_a["id"]))
    gui("hotkey", "--app", f"pid:{fixture.pid}", "--window-id", str(fixture_a["id"]), "--key", "CmdOrCtrl+Ctrl+Alt+Shift+Space", "--restore-window")
    panel = gui("get-app-state", "--app", f"pid:{host_pid}")
    tree = panel["snapshot"]["treeText"]
    check("hotkey opens the native prompt",  "Ask about the pinned window" in tree)
    gui("type-text", "--app", f"pid:{host_pid}", "--text", "Validate only the disposable fixture; no model call.")
    panel = gui("get-app-state", "--app", f"pid:{host_pid}")
    ask = re.search(r"^\s*(\d+) button Ask\b", panel["snapshot"]["treeText"], re.M)
    if not ask: raise RuntimeError("Ask button not found in fresh state")
    gui("click", "--app", f"pid:{host_pid}", "--element-index", ask.group(1))
    wait_for(record_file.exists)
    command("arm")
    context = json.loads(record_file.read_text())["contextId"]
    snap = tool("desktop.getContext", {"contextId": context})
    check("pinned identity is exact fixture A", snap.get("ok") and snap["result"]["targetWindow"]["hwnd"].lower() == hex(fixture_a["id"]))
    check("signed host captured a PNG",  pathlib.Path(snap["result"]["screenshot"]["filePath"]).exists())

    def capture():
        result = tool("desktop.captureWindow", {"contextId": context})
        if not result.get("ok"): raise RuntimeError(result)
        return result["result"]
    def act(name, args=None, shot=None, expected_error=None):
        payload = {"contextId": context, **(args or {})}
        if shot: payload["screenshotId"] = shot["imageId"]
        result = tool(name, payload)
        if expected_error:
            check(expected_error + " refused", not result.get("ok") and result["error"]["code"] == expected_error)
        else:
            if not result.get("ok"):
                if name in ["input.click", "input.scroll"] and args and "x" in args:
                    bounds = current()["A"]["bounds"]
                    diagnostic = subprocess.run(["swift", str(ROOT / "host-macos/scripts/point-diagnostics.swift"),
                        str(bounds["x"] + args["x"]), str(bounds["y"] + args["y"])], capture_output=True, text=True, timeout=15)
                    (root / "point-diagnostics.json").write_text(diagnostic.stdout + diagnostic.stderr)
                raise RuntimeError(result)
        time.sleep(.15)
        return result
    command("front", "B")
    act("input.keyChord", {"key": "a", "modifiers": ["cmd"]})
    act("input.typeText", {"text": "pi-os signed ü 日本語 ☕"})
    values = current()
    check("Unicode text delivered only to pinned A", values["A"]["text"] == "pi-os signed ü 日本語 ☕" and values["B"]["text"] == "original-B")
    act("input.pressKey", {"key": "space"})
    act("input.pressKey", {"key": "backspace"})
    check("named Space/Backspace keys work", current()["A"]["text"] == "pi-os signed ü 日本語 ☕")
    act("input.keyChord", {"key": "s", "modifiers": ["cmd"]})
    check("Command-S saved the disposable document", (root / "window-A.saved.txt").read_text() == "pi-os signed ü 日本語 ☕")
    shot = capture(); button = current()["A"]["button"]
    command("move")
    act("input.click", button, shot)
    check("moved-window click reached the fixture button", current()["A"]["clicks"] == 1)
    shot = capture(); before = current()["A"]
    act("input.scroll", {**before["scroll"], "deltaY": -2}, shot)
    check("scroll moved the nested fixture viewport", current()["A"]["scrollY"] > before["scrollY"])
    shot = capture()
    act("input.click", current()["A"]["like"], shot)
    check("ordinary Like control is clicked and verified", current()["A"]["liked"])
    shot = capture()
    act("input.click", current()["A"]["delete"], shot, expected_error="file_deletion_blocked")
    check("delete control never activated", current()["A"]["deletionAttempts"] == 0)
    shot = capture(); command("resize")
    act("input.click", button, shot, expected_error="capture_stale")
    check("stale capture posted no click", current()["A"]["clicks"] == 1)
    command("multiline"); capture()
    clipboard_before = subprocess.check_output(["swift", "-e", "import AppKit; print(NSPasteboard.general.changeCount)"], text=True).strip()
    multiline_text = "First ü😀\r\n\r\n日本語\rLast\n"
    before_typing = time.monotonic()
    act("input.typeText", {"text": multiline_text})
    check("native multiline Unicode/CRLF/CR/blank-line fidelity", current()["A"]["multilineText"] == "First ü😀\n\n日本語\nLast\n")
    check("native typing is paced", time.monotonic() - before_typing >= .3)
    clipboard_after = subprocess.check_output(["swift", "-e", "import AppKit; print(NSPasteboard.general.changeCount)"], text=True).strip()
    check("native typing leaves clipboard unchanged", clipboard_before == clipboard_after)
    command("plain")
    capture(); command("secure")
    if credentials_allowed:
        act("input.keyChord", {"key": "a", "modifiers": ["cmd"]})
        act("input.typeText", {"text": "dummy-credential-QA-only"})
        check("explicit setting permits dummy password input", current()["A"]["credentialDummyMatches"])
    else:
        act("input.typeText", {"text": "MUST-NOT-APPEAR"}, expected_error="credential_input_blocked")
    shot = capture()
    act("input.click", current()["A"]["like"], shot)
    check("Like click works while a credential field had focus", not current()["A"]["liked"])
    command("username")
    if credentials_allowed:
        act("input.keyChord", {"key": "a", "modifiers": ["cmd"]})
        act("input.typeText", {"text": "dummy-credential-QA-only"})
        check("explicit setting permits dummy username input", current()["A"]["usernameDummyMatches"])
    else:
        act("input.typeText", {"text": "MUST-NOT-APPEAR"}, expected_error="credential_input_blocked")
    command("plain")
    check("credential field checks preserved normal text", current()["A"]["text"] == "pi-os signed ü 日本語 ☕")
    shot = capture()
    refreshed = tool("desktop.refreshContext", {"contextId": context})
    check("metadata refresh succeeds", refreshed.get("ok"))
    act("input.click", button, shot, expected_error="capture_stale")
    check("unseen refresh image cannot authorize a click", current()["A"]["clicks"] == 1)
    shot = capture(); command("ambiguous")
    act("input.click", button, shot, expected_error="focus_failed")
    check("ambiguous windows receive no click", current()["A"]["clicks"] == 1)
    capture(); command("close")
    before_closed = json.loads(state.read_text())["receivedEvents"]
    closed = tool("input.typeText", {"contextId": context, "text": "MUST-NOT-APPEAR"})
    # macOS 27 may retain a 1×1 CG descriptor after NSWindow.close(). It is stale,
    # not yet absent. Assert the safety invariant rather than falsely claiming its
    # CGWindowID has vanished. input_failed is NOT accepted (it can mean partial posts).
    check("closed window rejects input before posting", not closed.get("ok") and closed["error"]["code"] in ["target_gone", "capture_stale", "capture_failed", "focus_failed"])
    report["closedWindowOutcome"] = closed["error"]["code"]
    check("canary window remains unchanged throughout", current()["B"]["text"] == "original-B")
    check("closed-window rejection delivered no events", json.loads(state.read_text())["receivedEvents"] == before_closed)
    fixture.stdin.close(); fixture.wait(timeout=3)
    act("input.typeText", {"text": "MUST-NOT-APPEAR"}, expected_error="target_gone")
    request(node_port, "/fixture/finish", {})
    time.sleep(.6)
    final = gui("get-app-state", "--app", f"pid:{host_pid}")
    check("native reader displays deterministic completion",  "Installed-host validation completed" in final["snapshot"]["treeText"])
    report["passed"] = True
except BaseException as error:
    report["passed"] = False; report["error"] = str(error)
    raise
finally:
    (root / "report.json").write_text(json.dumps(report, indent=2))
    print("Evidence:", root, flush=True)
    if host_pid:
        # Public, graceful quit of ONLY the PID resolved on this test's private port.
        script = f'import AppKit; if let app = NSRunningApplication(processIdentifier: {host_pid}), app.executableURL?.path == {json.dumps(str(APP / "Contents/MacOS/pi-os"))} {{ _ = app.terminate() }}'
        subprocess.run(["swift", "-e", script], timeout=15)
        for _ in range(60):
            alive = subprocess.run(['ps', '-p', str(host_pid), '-o', 'comm='], capture_output=True, text=True)
            if alive.stdout.strip() != str(APP / 'Contents/MacOS/pi-os'): break
            time.sleep(.1)
    if fixture:
        if fixture.poll() is None:
            fixture.stdin.close()
            try: fixture.wait(timeout=3)
            except subprocess.TimeoutExpired: fixture.terminate(); fixture.wait(timeout=3)
        fixture_log.close()
