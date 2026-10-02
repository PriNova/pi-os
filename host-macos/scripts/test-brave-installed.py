#!/usr/bin/env python3
"""Opt-in signed-host → production TS browser tools acceptance, no models/accounts.
Leaves the user's Brave process and tabs running. Only a fresh loopback fixture receives input.
"""
import json, os, pathlib, plistlib, secrets, socket, subprocess, tempfile, time, urllib.request, re
if os.environ.get('PI_OS_INSTALLED_TEST') != '1':
    raise SystemExit('Coordinate the desktop, then set PI_OS_INSTALLED_TEST=1.')
ROOT = pathlib.Path(__file__).resolve().parents[2]
credentials_allowed = os.environ.get('PI_OS_TEST_CREDENTIALS') == '1'
APP = pathlib.Path(os.environ.get('PI_OS_TEST_APP', pathlib.Path.home() / 'Applications/pi-os.app')).resolve()
ORCA = os.environ.get('ORCA_CLI_COMMAND') or ('orca-dev' if os.environ.get('ORCA_DEV_REPO_ROOT') else 'orca')
root = pathlib.Path(tempfile.mkdtemp(prefix='pi-os-brave-installed-'))
token = secrets.token_hex(32)
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
def free_port():
    with socket.socket() as s: s.bind(('127.0.0.1', 0)); return s.getsockname()[1]
host_port, node_port = free_port(), free_port()
def request(port, path, body=None):
    req = urllib.request.Request(f'http://127.0.0.1:{port}{path}', data=None if body is None else json.dumps(body).encode(),
        headers={'X-Harness-Token': token, 'Content-Type': 'application/json'})
    with opener.open(req, timeout=15) as r: return json.load(r)
def wait_for(predicate, timeout=30):
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        value = predicate()
        if value: return value
        time.sleep(.1)
    raise RuntimeError('Timed out waiting for fixture state')
def gui(*args):
    r = subprocess.run([ORCA, 'computer', *args, '--no-screenshot', '--json'], capture_output=True, text=True, timeout=15)
    result = json.loads(r.stdout)
    if not result.get('ok'): raise RuntimeError(result.get('error'))
    return result['result']
def host_pid_at_port():
    r = subprocess.run(['/usr/sbin/lsof', '-t', f'-iTCP:{host_port}', '-sTCP:LISTEN'], capture_output=True, text=True)
    return int(r.stdout.strip()) if r.stdout.strip() else None
host_pid = None
fixture = None
record = root / 'invocation.json'
try:
    subprocess.run(['codesign', '--verify', '--strict', str(APP)], check=True)
    signature = subprocess.run(['codesign', '-dv', '--verbose=4', str(APP)], capture_output=True, text=True, check=True)
    assert 'Authority=Apple Development:' in signature.stderr or 'Authority=Developer ID Application:' in signature.stderr
    log = open(root / 'fixture.log', 'w')
    fixture = subprocess.Popen(['node', '--import', str(ROOT / 'node-harness/test/no-live-models.mjs'), str(ROOT / 'host-macos/scripts/brave-integration-fixture.mjs'), str(root)],
        stdout=log, stderr=log, env={**os.environ, 'PI_OS_INSTALLED_TEST': '1', 'PI_OFFLINE': '1', 'PI_OS_AGENT': '0'})
    wait_for((root / 'fixture-ready.json').exists)
    url = json.loads((root / 'fixture-ready.json').read_text())['url']
    assert url.startswith('http://127.0.0.1:')
    subprocess.run(['open', '-a', 'Brave Browser', url], check=True)
    env = {'PI_OS_INSTALLED_TEST': '1', 'PI_OFFLINE': '1', 'PI_OS_AGENT': '0', 'PI_OS_TOKEN': token,
        'PI_OS_HOST_PORT': str(host_port), 'PI_OS_NODE_PORT': str(node_port), 'PI_OS_SUPPORT_DIR': str(root / 'support'),
        'PI_OS_NODE_ENTRY': str(ROOT / 'host-macos/scripts/installed-fixture-harness.mjs'), 'PI_OS_TEST_RECORD_FILE': str(record),
        'PI_OS_NODE_WARM_TTL_SECONDS': '3', 'PI_OS_HOTKEY': 'Ctrl+Option+Cmd+Shift+Space', 'PI_OS_BROWSER_DIAGNOSTICS': '1'}
    cmd = ['open', '-n', '-g', '--stdout', str(root / 'host.log'), '--stderr', str(root / 'host.log')]
    for key, value in env.items(): cmd += ['--env', f'{key}={value}']
    # NSArgumentDomain is specific to this launched test instance; no stored setting changes.
    subprocess.run(cmd + [str(APP), '--args', '-braveConnectionEnabled', 'YES', '-braveConnectionPort', '9222', '-allowCredentialFieldInput', 'YES' if credentials_allowed else 'NO'], check=True)
    host_pid = wait_for(host_pid_at_port)
    assert request(host_port, '/health')['service'] == 'macos-host'
    state = gui('get-app-state', '--app', 'com.brave.Browser', '--restore-window')
    assert 'pi-os integrated Brave fixture' in state['snapshot']['treeText']
    gui('hotkey', '--app', 'com.brave.Browser', '--key', 'CmdOrCtrl+Ctrl+Alt+Shift+Space')
    state = gui('get-app-state', '--app', f'pid:{host_pid}')
    assert 'Ask about the pinned window' in state['snapshot']['treeText']
    gui('type-text', '--app', f'pid:{host_pid}', '--text', 'Validate only the local browser fixture. No model calls.')
    state = gui('get-app-state', '--app', f'pid:{host_pid}')
    ask = re.search(r'^\s*(\d+) button Ask\b', state['snapshot']['treeText'], re.M)
    assert ask
    gui('click', '--app', f'pid:{host_pid}', '--element-index', ask.group(1))
    wait_for(record.exists)
    context = json.loads(record.read_text())['contextId']
    (root / 'fixture-context.json').write_text(json.dumps({'hostURL': f'http://127.0.0.1:{host_port}', 'token': token,
        'contextId': context, 'capturesDir': str(root / 'support/captures'), 'credentialsAllowed': credentials_allowed}))
    os.chmod(root / 'fixture-context.json', 0o600)
    fixture.wait(timeout=90)
    report = json.loads((root / 'browser-report.json').read_text())
    report['credentialsAllowed'] = credentials_allowed
    report['appUnderTest'] = str(APP)
    report['bundleVersion'] = plistlib.loads((APP / 'Contents/Info.plist').read_bytes())['CFBundleVersion']
    (root / 'browser-report.json').write_text(json.dumps(report, indent=2))
    print(json.dumps(report, indent=2))
    request(node_port, '/fixture/finish', {})
    assert report['passed']
finally:
    print('Evidence:', root, flush=True)
    if host_pid:
        code = f'import AppKit; if let app = NSRunningApplication(processIdentifier: {host_pid}), app.executableURL?.path == {json.dumps(str(APP / "Contents/MacOS/pi-os"))} {{ _ = app.terminate() }}'
        subprocess.run(['swift', '-e', code], timeout=15)
        # Termination is asynchronous; do not race the next fixture's Carbon hotkey.
        for _ in range(60):
            alive = subprocess.run(['ps', '-p', str(host_pid), '-o', 'comm='], capture_output=True, text=True)
            if alive.stdout.strip() != str(APP / 'Contents/MacOS/pi-os'): break
            time.sleep(.1)
    if fixture and fixture.poll() is None:
        fixture.terminate()
        try: fixture.wait(timeout=3)
        except subprocess.TimeoutExpired: fixture.kill(); fixture.wait(timeout=3)
