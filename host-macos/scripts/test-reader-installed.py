#!/usr/bin/env python3
"""Signed native reader/follow-up lifecycle fixture; no model or real account actions.
Runs a separate same-signed host and a disposable receiver. Does not touch normal preferences.
"""
import json, os, pathlib, plistlib, re, secrets, shutil, socket, subprocess, tempfile, time, urllib.request
if os.environ.get('PI_OS_INSTALLED_TEST') != '1':
    raise SystemExit('Coordinate an idle desktop and set PI_OS_INSTALLED_TEST=1.')
ROOT = pathlib.Path(__file__).resolve().parents[2]
APP = pathlib.Path(os.environ.get('PI_OS_TEST_APP', pathlib.Path.home() / 'Applications/pi-os.app')).resolve()
ORCA = os.environ.get('ORCA_CLI_COMMAND') or ('orca-dev' if os.environ.get('ORCA_DEV_REPO_ROOT') else 'orca')
root = pathlib.Path(tempfile.mkdtemp(prefix='pi-os-reader-installed-'))
token = secrets.token_hex(32)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1', 0)); return s.getsockname()[1]
host_port, node_port = free_port(), free_port()
report = {'checks': [], 'modelCalls': 0, 'fixtureOnly': True, 'appUnderTest': str(APP)}
record_file = root / 'invocation.json'
state_file = root / 'state.json'
fixture = None
host_pid = None

def request(port, path, body=None):
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=None if body is None else json.dumps(body).encode(),
        headers={'X-Harness-Token': token, 'Content-Type': 'application/json'})
    with opener.open(req, timeout=15) as r: return json.load(r)
def wait_for(predicate, timeout=15):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        value = predicate()
        if value: return value
        time.sleep(.1)
    raise RuntimeError('Fixture timed out')
def gui(*args, screenshot=False):
    cmd = [ORCA, 'computer', *args, '--json']
    if not screenshot: cmd += ['--no-screenshot']
    r = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    result = json.loads(r.stdout)
    if not result.get('ok'): raise RuntimeError(result.get('error'))
    return result['result']
def command(name):
    fixture.stdin.write((json.dumps({'command': name, 'window': 'A'}) + '\n').encode()); fixture.stdin.flush(); time.sleep(.2)
def record(): return json.loads(record_file.read_text())
def host_tree(): return gui('get-app-state', '--app', f'pid:{host_pid}')['snapshot']['treeText']
def click_label(label):
    tree = host_tree()
    match = re.search(r'^\s*(\d+) button ' + re.escape(label) + r'\b', tree, re.M)
    if not match: raise RuntimeError('Missing button: ' + label)
    gui('click', '--app', f'pid:{host_pid}', '--element-index', match.group(1))
def check(label, condition):
    if not condition: raise AssertionError(label)
    report['checks'].append(label); print('PASS:', label, flush=True)

try:
    subprocess.run(['codesign', '--verify', '--strict', str(APP)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(APP)], capture_output=True, text=True, check=True)
    check('certificate-signed host', 'Authority=Apple Development:' in signature.stderr or 'Authority=Developer ID Application:' in signature.stderr)
    report['bundleVersion'] = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
    receiver = root / 'Reader Fixture.app'; mac = receiver / 'Contents/MacOS'; mac.mkdir(parents=True)
    shutil.copy(ROOT / 'host-macos/.build/debug/pi-os-input-fixture', mac / 'fixture')
    (receiver / 'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'dev.pi-os.reader-fixture', 'CFBundleName': 'pi-os reader fixture',
        'CFBundleExecutable': 'fixture', 'CFBundlePackageType': 'APPL', 'LSMinimumSystemVersion': '14.0'}))
    subprocess.run(['codesign', '--force', '--sign', '-', str(receiver)], check=True)
    fixture_log = open(root / 'fixture.log', 'w')
    fixture = subprocess.Popen([str(mac / 'fixture'), str(state_file)], stdin=subprocess.PIPE, stdout=fixture_log, stderr=fixture_log)
    wait_for(state_file.exists)
    env = {'PI_OS_INSTALLED_TEST': '1', 'PI_OS_AGENT': '0', 'PI_OFFLINE': '1', 'PI_OS_TOKEN': token,
        'PI_OS_HOST_PORT': str(host_port), 'PI_OS_NODE_PORT': str(node_port), 'PI_OS_SUPPORT_DIR': str(root / 'support'),
        'PI_OS_NODE_ENTRY': str(ROOT / 'host-macos/scripts/installed-fixture-harness.mjs'), 'PI_OS_TEST_RECORD_FILE': str(record_file),
        'PI_OS_NODE_WARM_TTL_SECONDS': '3', 'PI_OS_HOTKEY': 'Ctrl+Option+Cmd+Shift+Space'}
    cmd = ['open', '-n', '-g', '--stdout', str(root / 'host.log'), '--stderr', str(root / 'host.log')]
    for key, value in env.items(): cmd += ['--env', f'{key}={value}']
    subprocess.run(cmd + [str(APP)], check=True)
    def find_host():
        r = subprocess.run(['lsof', '-t', f'-iTCP:{host_port}', '-sTCP:LISTEN'], capture_output=True, text=True)
        return int(r.stdout.strip()) if r.stdout.strip() else None
    host_pid = wait_for(find_host)
    check('LaunchServices readiness', request(host_port, '/health')['service'] == 'macos-host')
    command('front')
    fixture_window = next(w['id'] for w in json.loads(state_file.read_text())['windows'] if w['name'] == 'A')
    gui('get-app-state', '--app', f'pid:{fixture.pid}', '--window-id', str(fixture_window))
    # Observation may restore its previously focused window. Bring our receiver A
    # back after observation, before sending the dedicated test shortcut.
    command('front')
    gui('hotkey', '--app', f'pid:{fixture.pid}', '--window-id', str(fixture_window), '--key', 'CmdOrCtrl+Ctrl+Alt+Shift+Space', '--restore-window')
    check('native prompt opens', 'Ask about the pinned window' in host_tree())
    gui('type-text', '--app', f'pid:{host_pid}', '--text', 'First fixture question.')
    click_label('Ask'); wait_for(record_file.exists)
    command('arm')
    first = record(); context = first['contextId']; invocation = first['invocationId']
    check('native host explicitly requests session retention', first.get('retainSession') is True)
    pinned = request(host_port, '/tools/desktop.getContext', {'arguments': {'contextId': context}})
    check('actual Carbon hotkey pinned the exact receiver window', pinned['ok'] and pinned['result']['targetWindow']['hwnd'].lower() == hex(fixture_window))
    request(node_port, '/fixture/finish', {})
    wait_for(lambda: 'Follow-up on the pinned window' in host_tree())
    check('reader includes accessible follow-up composer', 'Ask follow-up' in host_tree())
    screenshot = gui('get-app-state', '--app', f'pid:{host_pid}', screenshot=True)
    (root / 'reader-ui.json').write_text(json.dumps(screenshot, indent=2))
    command('front')
    check('losing key/frontmost status does not dismiss reader', 'Follow-up on the pinned window' in host_tree())
    time.sleep(3.5)
    check('reader retains harness beyond ordinary warm TTL without polling', request(node_port, '/health')['service'] == 'installed-fixture-harness')
    # Observation/focus targets only this test host; no unrelated window receives text.
    tree = host_tree()
    field = re.search(r'^\s*(\d+) text entry area(?: \(settable\))? Follow-up on the pinned window', tree, re.M)
    if not field: raise RuntimeError('Follow-up editor not found')
    gui('click', '--app', f'pid:{host_pid}', '--element-index', field.group(1))
    gui('type-text', '--app', f'pid:{host_pid}', '--text', 'Second fixture question')
    gui('hotkey', '--app', f'pid:{host_pid}', '--key', 'Shift+Return')
    gui('type-text', '--app', f'pid:{host_pid}', '--text', 'with another line.')
    check('Shift-Return does not submit a follow-up', record()['turns'] == 1)
    click_label('Ask follow-up')
    wait_for(lambda: record()['turns'] == 2)
    second = record()
    check('follow-up reuses exact invocation and pinned context', second['invocationId'] == invocation and second['contextId'] == context)
    check('multiline follow-up delivered exactly', second['prompt'] == 'Second fixture question\nwith another line.')
    check('reader shrinks to working capsule during follow-up', 'Cancel task' in host_tree() and 'Follow-up on the pinned window' not in host_tree())
    request(node_port, '/fixture/finish', {})
    wait_for(lambda: 'Follow-up on the pinned window' in host_tree())
    check('completed follow-up re-enables reader composer', 'Ask follow-up' in host_tree())
    gui('type-text', '--app', f'pid:{host_pid}', '--text', 'Third question — simulated provider failure.')
    click_label('Ask follow-up'); wait_for(lambda: record()['turns'] == 3)
    request(node_port, '/fixture/fail', {})
    wait_for(lambda: 'Follow-up failed' in host_tree())
    check('failed follow-up preserves previous answer and offers explicit retry', 'Installed-host validation completed' in host_tree() and 'Follow-up on the pinned window' in host_tree())
    gui('type-text', '--app', f'pid:{host_pid}', '--text', 'Explicit dummy retry.')
    click_label('Ask follow-up'); wait_for(lambda: record()['turns'] == 4)
    request(node_port, '/fixture/finish', {})
    wait_for(lambda: 'Follow-up on the pinned window' in host_tree())
    check('explicit retry keeps the same thread', record()['invocationId'] == invocation and record()['contextId'] == context)
    try: click_label('Close conversation')
    except RuntimeError:
        # Orca can fail its post-click AX read when Close has already hidden the
        # last window. Verify closure independently; never replay that click.
        if not record()['closed']: raise
    wait_for(lambda: record()['closed'])
    outcome = request(host_port, '/tools/desktop.getContext', {'arguments': {'contextId': context}})
    check('explicit close disposes thread and revokes native context', not outcome['ok'] and outcome['error']['code'] == 'unknown_context')
    check('receiver and canary text were not edited', all(w['text'] == 'original-' + w['name'] for w in json.loads(state_file.read_text())['windows']))
    report['passed'] = True
except BaseException as error:
    report['passed'] = False; report['error'] = str(error); raise
finally:
    (root / 'report.json').write_text(json.dumps(report, indent=2)); print('Evidence:', root, flush=True)
    if host_pid:
        code = f'import AppKit; if let app = NSRunningApplication(processIdentifier: {host_pid}), app.executableURL?.path == {json.dumps(str(APP / "Contents/MacOS/pi-os"))} {{ _ = app.terminate() }}'
        subprocess.run(['swift', '-e', code], timeout=15)
        for _ in range(60):
            alive = subprocess.run(['ps', '-p', str(host_pid), '-o', 'comm='], capture_output=True, text=True)
            if alive.stdout.strip() != str(APP / 'Contents/MacOS/pi-os'): break
            time.sleep(.1)
    if fixture:
        fixture.stdin.close()
        try: fixture.wait(timeout=3)
        except subprocess.TimeoutExpired: fixture.terminate(); fixture.wait(timeout=3)
        fixture_log.close()
