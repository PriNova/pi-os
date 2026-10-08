#!/usr/bin/env python3
"""Controlled native spike. Existing terminal AX grants only; never requests TCC.
Not evidence for installed-app signing/TCC or the full display/keyboard matrix.
"""
import json
import os
import pathlib
import plistlib
import shutil
import subprocess
import tempfile
import time

if os.environ.get("PI_OS_NATIVE_TEST") != "1":
    raise SystemExit("Native UI tests are opt-in. Coordinate an idle desktop/test window, then set PI_OS_NATIVE_TEST=1. Do not run during the DRACO benchmark reservation.")

ROOT = pathlib.Path(__file__).resolve().parents[2]
root = pathlib.Path(tempfile.mkdtemp(prefix="pi-os-native-spike-"))
app = root / "Input Fixture.app"
mac = app / "Contents/MacOS"
mac.mkdir(parents=True)
shutil.copy(ROOT / "host-macos/.build/debug/pi-os-input-fixture", mac / "fixture")
(app / "Contents/Info.plist").write_bytes(plistlib.dumps({
    "CFBundleIdentifier": "dev.pi-os.input-fixture", "CFBundleExecutable": "fixture",
    "CFBundleName": "pi-os input fixture", "CFBundlePackageType": "APPL", "LSMinimumSystemVersion": "14.0",
}))
# This app only receives test input; it has no capture/input permissions of its own.
subprocess.run(["codesign", "--force", "--sign", "-", str(app)], check=True)
state = root / "state.json"
with open(root / "fixture.log", "w") as log:
    child = subprocess.Popen([str(mac / "fixture"), str(state)], stdin=subprocess.PIPE, stdout=log, stderr=log)
    try:
        for _ in range(100):
            if state.exists():
                break
            time.sleep(.05)
        time.sleep(.25)
        result = subprocess.run([str(ROOT / "host-macos/.build/debug/pi-os-native-probe"), str(state)],
                                capture_output=True, text=True, timeout=15,
                                env={**os.environ, "PI_OS_FOCUS_DIAGNOSTICS": "1"})
        print(result.stdout, result.stderr)
        (root / "probe.txt").write_text(result.stdout + result.stderr)
        print("Evidence:", root)
        if result.returncode:
            raise SystemExit(result.returncode)

        def command(name, window="A"):
            child.stdin.write((json.dumps({"command": name, "window": window}) + "\n").encode())
            child.stdin.flush()
            time.sleep(.15)

        def current():
            command("state")
            return {w["name"]: w for w in json.loads(state.read_text())["windows"]}

        def action(kind, arguments=None, after_capture=None, expect=None):
            request = root / "action.json"
            request.write_text(json.dumps({"action": kind, "arguments": {"contextId": "ctx-fixture", **(arguments or {})}}))
            process = subprocess.Popen([str(ROOT / "host-macos/.build/debug/pi-os-native-probe"), str(state), str(request)],
                                       stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert process.stdout.readline().strip() == "CAPTURED", "Native capture did not complete"
                if after_capture:
                    command(after_capture)
                stdout, stderr = process.communicate("go\n", timeout=15)
                if expect:
                    assert process.returncode != 0 and expect in stderr, (stdout, stderr)
                    print("PASS refusal:", expect)
                    return None
                assert process.returncode == 0, stderr
                response = json.loads(stdout.strip().splitlines()[-1])
                print("PASS action:", response)
                return response
            finally:
                if process.poll() is None:
                    process.terminate(); process.wait(timeout=3)

        # Every probe captures A while B can be frontmost; input must go to exact A.
        command("front", "B")
        action("input.keyChord", {"key": "a", "modifiers": ["cmd"]})
        action("input.typeText", {"text": "pi-os native ü 日本語 ☕"})
        values = current()
        assert values["A"]["text"] == "pi-os native ü 日本語 ☕", values
        assert values["B"]["text"] == "original-B", "Wrong window received text"
        action("input.pressKey", {"key": "space"})
        action("input.pressKey", {"key": "backspace"})
        assert current()["A"]["text"] == "pi-os native ü 日本語 ☕"
        action("input.keyChord", {"key": "s", "modifiers": ["cmd"]})
        assert current()["A"]["saved"] == 1
        assert (root / "window-A.saved.txt").read_text() == "pi-os native ü 日本語 ☕"
        before = current()["A"]
        action("input.scroll", {**before["scroll"], "deltaY": -2})
        assert current()["A"]["scrollY"] > before["scrollY"]
        button = current()["A"]["button"]
        action("input.click", button, after_capture="move")
        assert current()["A"]["clicks"] == 1
        action("input.click", button, after_capture="resize", expect="capture_stale")
        assert current()["A"]["clicks"] == 1
        action("input.typeText", {"text": "MUST-NOT-APPEAR"}, after_capture="secure", expect="secure_input")
        command("plain")
        assert current()["A"]["text"] == "pi-os native ü 日本語 ☕"
        action("input.click", current()["A"]["button"], after_capture="ambiguous", expect="focus_failed")
        assert current()["A"]["clicks"] == 1
        action("input.typeText", {"text": "MUST-NOT-APPEAR"}, after_capture="close", expect="target_gone")
        assert current()["B"]["text"] == "original-B"
        print("PASS: native type/Command-save/click, movement transform, and stale/secure/ambiguous/gone refusals")
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=3)
        except subprocess.TimeoutExpired:
            child.terminate()  # only this exact owned fixture PID
            child.wait(timeout=3)
