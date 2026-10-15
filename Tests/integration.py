"""Exercise the real executable against isolated status-line and app-server inputs."""
import json, os, pathlib, plistlib, subprocess, tempfile

root = pathlib.Path(__file__).resolve().parents[1]
binary = root.parent / 'Nocci.app/Contents/MacOS/Nocci'
with tempfile.TemporaryDirectory(prefix='notch-tests-') as folder:
    directory = pathlib.Path(folder)
    env = dict(os.environ, NOCCI_DATA_DIR=folder)
    payload = {'rate_limits': {'five_hour': {'used_percentage': 23.5, 'resets_at': 2000000000}}, 'transcript_path': 'PRIVATE', 'session_id': 'PRIVATE', 'other': 'PRIVATE'}
    result = subprocess.run([binary, '--claude-statusline'], input=json.dumps(payload), text=True, capture_output=True, env=env, check=True)
    snapshot = before = (directory / 'claude.json').read_text()
    assert 'PRIVATE' not in snapshot
    assert json.loads(snapshot)['windows'][0]['used'] == 23.5
    assert (directory / 'claude.json').stat().st_mode & 0o777 == 0o600
    # A session-start event carries no rate_limits. It must not erase the
    # reading a previous event delivered.
    kept = subprocess.run([binary, '--claude-statusline'], input='{}', text=True, capture_output=True, env=env, check=True)
    snapshot = json.loads((directory / 'claude.json').read_text())
    assert snapshot['windows'][0]['used'] == 23.5, 'an empty event kept the last reading'
    assert snapshot['updated'] == json.loads(before)['updated'], 'the capture time still describes the reading'
    assert snapshot['lastEvent'] > snapshot['updated'], 'the empty event was recorded separately'
    assert '24% used' in kept.stdout, 'the status line still prints the kept reading'
    (directory / 'claude.json').unlink()
    subprocess.run([binary, '--claude-statusline'], input='{}', text=True, capture_output=True, env=env, check=True)
    assert json.loads((directory / 'claude.json').read_text())['windows'] == []
    bad = subprocess.run([binary, '--claude-statusline'], input='{', text=True, capture_output=True, env=env)
    assert bad.returncode != 0
    mock = directory / 'codex'
    mock.write_text('''#!/usr/bin/env python3
import json, sys
first = json.loads(sys.stdin.readline())
assert first['method'] == 'initialize'
open(sys.argv[0] + '.client', 'w').write(json.dumps(first['params']['clientInfo']))
print(json.dumps({'id': first['id'], 'result': {}}), flush=True)
assert json.loads(sys.stdin.readline())['method'] == 'initialized'
request = json.loads(sys.stdin.readline())
assert request['method'] == 'account/rateLimits/read'
print(json.dumps({'id': request['id'], 'result': {'rateLimitsByLimitId': {'codex': {'primary': {'usedPercent': 64, 'windowDurationMins': 300, 'resetsAt': 2000000000}}}}}), flush=True)
sys.stdin.read()
''')
    mock.chmod(0o700)
    env['NOCCI_CODEX_PATH'] = str(mock)
    # A command-line defaults value conflicts with the fixture, without
    # modifying the user's persistent defaults or touching a real account.
    response = subprocess.run([binary, '--check-codex', '-codexPath', '/bin/false'], text=True, capture_output=True, env=env, check=True, timeout=20)
    assert json.loads(response.stdout)['windows'][0]['used'] == 64
    version = plistlib.loads((binary.parent.parent / 'Info.plist').read_bytes())['CFBundleShortVersionString']
    assert json.loads((directory / 'codex.client').read_text()) == {'name': 'notch_usage', 'title': 'Nocci', 'version': version}, 'Codex is told the real app version'
    # A Codex that hangs up after its first answer must not take Nocci down
    # with SIGPIPE on the next write; it is reported as disconnected.
    hangup = directory / 'hangup-codex'
    hangup.write_text('''#!/usr/bin/env python3
import json, os, sys
first = json.loads(sys.stdin.readline())
os.close(0)
print(json.dumps({'id': first['id'], 'result': {}}), flush=True)
''')
    hangup.chmod(0o700)
    closed = subprocess.run([binary, '--check-codex'], text=True, capture_output=True,
                            env=dict(env, NOCCI_CODEX_PATH=str(hangup)), timeout=20)
    assert closed.returncode == 1 and 'Codex stopped answering' in closed.stderr, 'a hang-up is reported, not a crash'
    # npm's codex is a script for `node`, which sits beside it; a Finder launch's
    # PATH does not include that folder.
    runtime = directory / 'fakenode'
    runtime.write_text('#!/bin/sh\nexec /usr/bin/python3 "$@"\n')
    runtime.chmod(0o700)
    scripted = directory / 'npm-codex'
    scripted.write_text('#!/usr/bin/env fakenode\n' + mock.read_text().split('\n', 1)[1])
    scripted.chmod(0o700)
    npm = subprocess.run([binary, '--check-codex'], text=True, capture_output=True, timeout=20,
                         env=dict(env, NOCCI_CODEX_PATH=str(scripted), PATH='/usr/bin:/bin:/usr/sbin:/sbin'))
    assert npm.returncode == 0 and json.loads(npm.stdout)['windows'][0]['used'] == 64, 'an interpreter beside Codex is found'
    env['NOCCI_CODEX_PATH'] = str(directory / 'missing-codex')
    invalid = subprocess.run([binary, '--check-codex', '-codexPath', str(mock)], text=True, capture_output=True, env=env, timeout=20)
    assert invalid.returncode != 0 and not invalid.stdout
    assert "Codex wasn’t found" in invalid.stderr
    # Claude Code hooks: every call exits 0 silently, whatever it receives.
    sessions = directory / 'Sessions'
    def hook(data, host=None, tab=None):
        hook_env = {key: value for key, value in env.items() if key not in ('__CFBundleIdentifier', 'NOCCI_TERMINAL_TAB')}
        if host:
            hook_env['__CFBundleIdentifier'] = host
        if tab:
            hook_env['NOCCI_TERMINAL_TAB'] = tab
        raw = data if isinstance(data, bytes) else json.dumps(data).encode()
        result = subprocess.run([binary, '--claude-hook'], input=raw, capture_output=True, env=hook_env, timeout=20)
        assert result.returncode == 0 and result.stdout == b'' and result.stderr == b'', result
    base = {'session_id': 'integration-1', 'cwd': '/tmp/example/api-server', 'transcript_path': 'PRIVATE', 'user_prompt': 'PRIVATE'}
    hook(dict(base, hook_event_name='PermissionRequest', tool_name='Bash', tool_input={'command': 'PRIVATE'}), 'com.example.Editor')
    files = list(sessions.glob('*.json'))
    record = json.loads(files[0].read_text())
    assert len(files) == 1 and record['state'] == 'permission' and record['project'] == 'api-server' and record['host'] == 'com.example.Editor'
    assert 'PRIVATE' not in files[0].read_text() and 'integration-1' not in files[0].name and 'Bash' not in files[0].read_text()
    assert files[0].stat().st_mode & 0o777 == 0o600 and sessions.stat().st_mode & 0o777 == 0o700
    assert record.get('started') == record['since'], 'the first event records when the session started'
    hook(dict(base, hook_event_name='Stop'))
    assert json.loads(files[0].read_text())['state'] == 'yourTurn'
    assert json.loads(files[0].read_text()).get('started') == record['started'], 'the start never moves'
    hook(dict(base, hook_event_name='SessionEnd'))
    assert json.loads(files[0].read_text())['state'] == 'ended'
    for garbage in [b'', b'{', b'[1]', b'x' * (20 * 1024 * 1024)]:
        hook(garbage)
    hook(dict(base, session_id='integration-2', hook_event_name='Notification', notification_type='idle_prompt'))
    assert len(list(sessions.glob('*.json'))) == 1, 'garbage and ignored events create nothing'
    tab = '0F2B7C6A-1D8E-4B23-9A55-3C1E0D7F8A91'
    hook(dict(base, session_id='integration-4', hook_event_name='SessionStart'), 'com.github.amirabazi.nocci', tab=tab)
    hosted = [f for f in sessions.glob('*.json') if json.loads(f.read_text()).get('tab')]
    assert len(hosted) == 1 and json.loads(hosted[0].read_text())['tab'] == tab, 'a Nocci tab is recorded'
    hook(dict(base, session_id='integration-5', hook_event_name='SessionStart'), tab='not a tab')
    assert len(list(sessions.glob('*.json'))) == 3, 'a malformed tab still records the session'
    assert all(json.loads(f.read_text()).get('tab') in (None, tab) for f in sessions.glob('*.json')), 'a malformed tab is dropped'
print('23 integration checks passed: privacy filtering, permissions, kept reading, capture time, event time, printed line, absent limits, malformed input, handshake, client version, Codex hang-up, npm Codex, override isolation, invalid override, hook state, hook privacy, hook permissions, hook start time, hook finished turn, hook ended marker, hook garbage, hook tab, hook malformed tab')
