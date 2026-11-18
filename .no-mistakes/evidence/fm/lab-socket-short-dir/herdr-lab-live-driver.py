import json
import os
from pathlib import Path
import shutil
import socket
import stat
import subprocess
import tempfile
import time

root = Path.cwd()
helper = root / 'bin/fm-herdr-lab.sh'
environment = {k: v for k, v in os.environ.items()
               if not k.startswith(('HERDR_', 'XDG_', 'FM_HERDR_LAB_'))}
environment.update(SHELL='/bin/bash', TERM='xterm-256color')
print(subprocess.check_output(['herdr', '--version'], text=True).strip(), flush=True)

with tempfile.TemporaryDirectory(prefix='.lab-live-', dir=root) as fixture:
    home = Path(fixture)
    state = home / 'state'
    sessions = home / 'herdr/sessions'
    environment.update(HOME=fixture, XDG_DATA_HOME=fixture + '/data',
                       XDG_CACHE_HOME=fixture + '/cache', XDG_STATE_HOME=fixture + '/state-xdg',
                       FM_HERDR_LAB_STATE_DIR=str(state))
    short = '/proc/self/cwd'
    sentinel = 'bootstrap-fleet'
    fleet = 'fixture-fleet'
    companion = 'fm-lab-observer'
    first = 'fm-lab-live'
    guarded = 'fm-lab-guard'

    def run(*args, config=None, fleet_name=None, expected=0, script=helper):
        env = environment | {'XDG_CONFIG_HOME': config or fixture,
                             'FM_HERDR_LAB_FLEET_SESSION': fleet_name or fleet}
        print(f"$ XDG_CONFIG_HOME={env['XDG_CONFIG_HOME']} FM_HERDR_LAB_FLEET_SESSION={env['FM_HERDR_LAB_FLEET_SESSION']} "
              f"{script.name} {' '.join(args)}", flush=True)
        # Files prevent background product children from inheriting this API's pipes.
        with tempfile.TemporaryFile(dir=home) as out, tempfile.TemporaryFile(dir=home) as err:
            result = subprocess.run([str(script), *args], cwd=home, env=env,
                                    stdout=out, stderr=err, text=True, timeout=75)
            out.seek(0)
            err.seek(0)
            output, errors = out.read().decode(), err.read().decode()
        for stream in (output, errors):
            if stream:
                print(stream.rstrip(), flush=True)
        print(f"exit={result.returncode}", flush=True)
        if expected is not None:
            assert result.returncode == expected, (args, result.returncode)
        return result.returncode, output, errors

    def list_sessions(name, **kwargs):
        return {entry['name']: entry for entry in
                json.loads(run('run', name, 'session', 'list', '--json', **kwargs)[1])['sessions']}

    def record(name, suffix='socket-dir'):
        return state / (name + '.' + suffix)

    def provision(name, **kwargs):
        # Provision prepares a new name and snapshots the fleet before starting it.
        run('provision', name, **kwargs)

    def cleanup(name, **kwargs):
        if record(name, 'fleet-state.json').exists():
            run('teardown', name, expected=None, **kwargs)

    sentinel_dir = sessions / sentinel
    sentinel_dir.mkdir(parents=True)
    with socket.socket(socket.AF_UNIX) as bootstrap:
        bootstrap.bind(short + '/herdr/sessions/' + sentinel + '/herdr.sock'
                       if Path.cwd() == home else str((sentinel_dir / 'herdr.sock').relative_to(root)))
        bootstrap.listen(128)
        try:
            print('\nSHORT CONFIG: run a real companion through the ordinary path', flush=True)
            companion_env = dict(config=short, fleet_name=sentinel)
            provision(companion, **companion_env)
            original = list_sessions(companion, **companion_env)[companion]
            assert original['running'] and not original['default']
            assert original['socket_path'].startswith(short + '/herdr/')
            assert stat.S_ISSOCK((sessions / companion / 'herdr.sock').stat().st_mode)
            assert not record(companion).exists()
            print('PASS short configuration: real server running, original socket, no relocation record', flush=True)

            # The disposable fleet name points at the real companion's API socket.
            # Herdr's session list observes that socket directly. Stopping the
            # companion via its own helper route genuinely removes the listener.
            fleet_dir = sessions / fleet
            fleet_dir.mkdir()
            (fleet_dir / 'herdr.sock').symlink_to('../' + companion + '/herdr.sock')

            print('\nLONG CONFIG: compare the old helper and drive a full relocated lifecycle', flush=True)
            unrelocated = str(sessions / first / 'herdr-client.sock')
            byte_length = len(os.fsencode(unrelocated))
            assert byte_length > 103
            print(f'Unrelocated client socket would require {byte_length} bytes', flush=True)
            base = home / 'base-fm-herdr-lab.sh'
            base.write_bytes(subprocess.check_output(['git', 'show', '427056c4:bin/fm-herdr-lab.sh'], cwd=root))
            base.chmod(0o700)
            assert '103-byte sun_path limit' in run('provision', first, expected=1, script=base)[2]
            generated_name = run('name', 'long-root')[1].strip()
            assert generated_name.startswith('fm-lab-long-root-')
            provision(first)
            alias = Path(record(first).read_text().strip())
            alias_mode = alias.stat().st_mode & 0o777
            assert alias_mode == 0o700 and alias.stat().st_uid == os.getuid()
            print(f'Private config alias {alias}, mode {alias_mode:04o}, owner UID {alias.stat().st_uid}', flush=True)
            listing = list_sessions(first)
            entry = listing[first]
            assert entry['running'] and not entry['default'] and listing[fleet]['running']
            assert entry['socket_path'].startswith(str(alias) + '/')
            assert stat.S_ISSOCK(Path(entry['socket_path']).stat().st_mode)
            client_sock = alias / 'herdr/sessions' / first / 'herdr-client.sock'
            assert stat.S_ISSOCK(client_sock.stat().st_mode) and len(os.fsencode(str(client_sock))) <= 103
            print(f'Kernel-bound client socket {client_sock} ({len(os.fsencode(str(client_sock)))} bytes)', flush=True)
            assert json.loads(run('run', first, 'status', '--json')[1])['server']['running']
            assert json.loads(run('run', first, 'terminal', 'title', 'clear')[1])['result']['reason'] == 'no_foreground_client'
            run('viewer', 'start', first)
            assert json.loads(run('run', first, 'terminal', 'title', 'clear')[1])['result']['reason'] == 'cleared'
            before = json.loads(record(first, 'fleet-state.json').read_text())
            print(f'Tripwire before teardown: {json.dumps(before)}', flush=True)
            run('teardown', first)
            assert not alias.exists() and not record(first).exists() and not record(first, 'viewer').exists()
            assert not (sessions / first).exists() and not record(first, 'fleet-state.json').exists()
            assert list_sessions(companion, **companion_env)[companion] == original
            print('PASS relocated lifecycle: connected viewer, removed lab and alias, real companion unchanged', flush=True)

            print('\nTRIPWIRE: stop the disposable companion, guard teardown, then recover', flush=True)
            provision(guarded)
            guard_alias = Path(record(guarded).read_text().strip())
            before = record(guarded, 'fleet-state.json').read_bytes()
            run('stop', companion, **companion_env)
            assert not list_sessions(guarded)[fleet]['running']
            assert 'fleet-state tripwire requires exactly one running fixture-fleet session' in run('teardown', guarded, expected=1)[2]
            assert guard_alias.is_dir() and record(guarded, 'fleet-state.json').read_bytes() == before
            assert record(guarded).exists()
            provision(companion, **companion_env)
            assert list_sessions(guarded)[fleet]['running']
            run('teardown', guarded)
            assert not guard_alias.exists() and not record(guarded).exists()
            print('PASS tripwire: refused cleanup while the companion was stopped, retained records, then cleaned up on retry', flush=True)

            print('\nUNRELOCATABLE NAME: reject before creating a session or state records', flush=True)
            oversized = 'fm-lab-' + 'x' * 100
            assert '103-byte sun_path limit' in run('provision', oversized, expected=1)[2]
            assert oversized not in list_sessions(companion, **companion_env)
            assert not any(state.glob(oversized + '.*'))
            print('PASS unrelocatable name: no session or ownership record', flush=True)
        finally:
            if record(guarded, 'fleet-state.json').exists() or record(first, 'fleet-state.json').exists():
                if record(companion, 'fleet-state.json').exists() and not list_sessions(companion, **companion_env)[companion]['running']:
                    provision(companion, **companion_env)
                cleanup(guarded)
                cleanup(first)
            cleanup(companion, **companion_env)
            assert not any(state.glob('*.fleet-state.json'))
            assert not any(state.glob('*.socket-dir'))
            print('Disposable Herdr sessions and relocation records removed', flush=True)
