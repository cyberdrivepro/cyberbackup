#!/usr/bin/env python3
"""Owned service/job supervisor. Legacy command strings are parsed to argv once."""
import argparse
import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import sys
import threading
import time

from control_state import atomic, audit, name, root, save_runtime
from process_identity import identity, read_record


def paths(kind, resource):
    name(resource)
    folder = 'services' if kind == 'service' else 'jobs'
    config = (root('config') if kind == 'service' else root()) / folder / f'{resource}.json'
    state = root() / folder / f'{resource}.state.json'
    pidfile = root() / folder / f'{resource}.pid'
    logs = root() / 'logs' / folder
    for p in (config.parent, state.parent, logs):
        p.mkdir(parents=True, exist_ok=True, mode=0o700)
    return config, state, pidfile, logs


def load(path, default=None):
    if path.is_symlink():
        raise ValueError('managed file is a symlink')
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return {} if default is None else default


def alive(pidfile):
    try:
        read_record(Path(str(pidfile)+'.identity.json'))
        return True
    except (OSError, ValueError, KeyError):
        return False


def record(kind, resource, data):
    config, state, _, _ = paths(kind, resource)
    atomic(state, data)
    if kind == 'job':
        atomic(config, data)
    save_runtime(kind, resource, data)


def pump(stream, path):
    with path.open('ab', buffering=0) as output:
        for line in iter(stream.readline, b''):
            if output.tell() + len(line) > 1048576:
                output.seek(0)
                output.truncate()
            output.write(line)


def worker(kind, resource):
    config, state, pidfile, logs = paths(kind, resource)
    cfg = load(config)
    # Explicit shell command is kept only for backwards-compatible job API.
    argv = cfg.get('argv') or shlex.split(cfg.get('command', ''))
    if not argv or not isinstance(argv, list) or not all(isinstance(a, str) for a in argv):
        raise ValueError('nonempty argv required')
    stopped = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stopped.set())
    signal.signal(signal.SIGINT, lambda *_: stopped.set())
    child = None
    def reload_child(*_):
        if child is not None and child.poll() is None:
            child.send_signal(signal.SIGHUP)
    if hasattr(signal, 'SIGHUP'):
        signal.signal(signal.SIGHUP, reload_child)
    atomic(Path(str(pidfile)+'.identity.json'), identity(os.getpid()))
    pidfile.write_text(str(os.getpid()))
    data = dict(cfg, state='STARTING', pid=os.getpid(), started_at=time.time(), exit_code=None)
    record(kind, resource, data)
    restarts = 0
    code = 0
    while not stopped.is_set():
        child = subprocess.Popen(argv, cwd=cfg.get('working_directory') or str(Path.home()),
                                 stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                 start_new_session=True)
        data.update(state='RUNNING', child_pid=child.pid, crash_count=restarts)
        record(kind, resource, data)
        stdout = logs / (f'{resource}.log' if kind == 'job' else f'{resource}.stdout.log')
        stderr = logs / f'{resource}.stderr.log'
        readers = [threading.Thread(target=pump, args=(stream,path), daemon=True)
                   for stream,path in ((child.stdout,stdout),(child.stderr,stderr))]
        for reader in readers:
            reader.start()
        started = time.monotonic()
        timed_out = False
        while child.poll() is None and not stopped.wait(0.1):
            if cfg.get('timeout', 0) and time.monotonic()-started > cfg['timeout']:
                timed_out = True
                break
        if child.poll() is None:
            # Only the private process group created above; child remains unreaped.
            os.killpg(child.pid, signal.SIGTERM)
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(child.pid, signal.SIGKILL)
                child.wait()
        code = child.wait()
        for reader in readers:
            reader.join(timeout=2)
        data.update(exit_code=code, completed_at=time.time())
        if stopped.is_set():
            data['state'] = 'CANCELLED' if kind == 'job' else 'STOPPED'
            break
        if timed_out:
            data['state'] = 'TIMEOUT'
            break
        policy = cfg.get('restart', 'never') if kind == 'service' else 'never'
        retry = policy in {'always', 'unless-stopped'} or (policy == 'on-failure' and code != 0)
        if not retry or restarts >= cfg.get('max_restarts', 5):
            data['state'] = 'SUCCESS' if code == 0 else 'FAILED'
            break
        data['state'] = 'RESTARTING'
        record(kind, resource, data)
        stopped.wait(min(30, 2**restarts))
        restarts += 1
    record(kind, resource, data)
    pidfile.unlink(missing_ok=True)
    Path(str(pidfile)+'.identity.json').unlink(missing_ok=True)
    audit(kind, resource, 'completed', code)


def start(kind, resource):
    config, state, pidfile, _ = paths(kind, resource)
    if not config.exists():
        raise ValueError('resource is not registered')
    if alive(pidfile):
        return
    lock = state.with_suffix('.start.lock')
    # Atomic lock prevents concurrent starts; a stale lock requires explicit repair.
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    try:
        worker_log = state.with_suffix('.supervisor.log')
        with worker_log.open('ab') as log:
            proc = subprocess.Popen([sys.executable, __file__, kind, '_worker', resource],
                                    stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
        for _ in range(100):
            data = load(state)
            if data.get('pid') == proc.pid and data.get('state') not in {None, 'STARTING'}:
                if data['state'] == 'FAILED':
                    raise ValueError(f'start failed; see {worker_log}')
                print(f'{resource}: {data["state"]}')
                return
            if proc.poll() is not None:
                raise ValueError(f'supervisor exited; see {worker_log}')
            time.sleep(0.05)
        raise ValueError(f'start timed out; see {worker_log}')
    finally:
        lock.unlink(missing_ok=True)


def stop(kind, resource):
    _, state, pidfile, _ = paths(kind, resource)
    if alive(pidfile):
        result = subprocess.run([sys.executable, str(Path(__file__).with_name('process_identity.py')),
                                 'stop', str(pidfile)+'.identity.json'])
        if result.returncode:
            raise ValueError('could not stop owned supervisor')
    data = load(state)
    data['state'] = 'CANCELLED' if kind == 'job' else 'STOPPED'
    record(kind, resource, data)
    print(f'{resource}: {data["state"]}')


def main():
    cli = argparse.ArgumentParser()
    cli.add_argument('kind', choices=['service', 'job'])
    cli.add_argument('action')
    cli.add_argument('name', nargs='?')
    cli.add_argument('--cmd')
    cli.add_argument('--cwd', default=str(Path.home()))
    cli.add_argument('--backend', default='supervisor')
    cli.add_argument('--enabled', choices=['true','false'], default='true')
    cli.add_argument('--restart', choices=['never','on-failure','always','unless-stopped'], default='on-failure')
    cli.add_argument('--port', type=int, default=0)
    cli.add_argument('--health-type', choices=['process','http','tcp'], default='process')
    cli.add_argument('--health-target', default='')
    cli.add_argument('--timeout', type=int, default=0)
    cli.add_argument('--shell', action='store_true')
    args, argv = cli.parse_known_args()
    if argv[:1] == ['--']:
        argv = argv[1:]
    if args.action == 'list':
        directory = (root('config') if args.kind == 'service' else root()) / ('services' if args.kind == 'service' else 'jobs')
        print('NAME STATE BACKEND ENABLED COMMAND')
        for p in sorted(directory.glob('*.json')):
            if p.name.endswith(('.state.json','.identity.json')):
                continue
            cfg = load(p)
            _, state, pidfile, _ = paths(args.kind, p.stem)
            data = load(state)
            status = 'RUNNING' if alive(pidfile) else data.get('state','STOPPED')
            if status in {'RUNNING','STARTING','RESTARTING'} and not alive(pidfile):
                status = 'CRASHED'
            print(p.stem, status, 'supervisor', cfg.get('enabled',True), cfg.get('command',''))
        return 0
    config, state, pidfile, logs = paths(args.kind, args.name or '')
    if args.action in {'add','run'}:
        if alive(pidfile):
            raise ValueError('stop the existing resource before changing its definition')
        if args.cmd is not None:
            argv = ['bash','-c',args.cmd] if args.shell else shlex.split(args.cmd)
        if not argv:
            raise ValueError('nonempty command argv required')
        if not 0 <= args.port <= 65535 or args.timeout < 0:
            raise ValueError('invalid port or timeout')
        cfg = {'name':args.name, 'argv':argv, 'command':shlex.join(argv), 'working_directory':args.cwd,
               'backend':'supervisor','enabled':args.enabled=='true','restart':args.restart,
               'port':args.port,'health_type':args.health_type,'health_target':args.health_target,
               'timeout':args.timeout,'max_restarts':5,'crash_count':0}
        atomic(config,cfg)
        save_runtime(args.kind,args.name,cfg)
        if args.action == 'run':
            start(args.kind,args.name)
        return 0
    if args.action == '_worker':
        worker(args.kind,args.name)
    elif args.action == 'start':
        cfg=load(config)
        if cfg.get('port'):
            import socket
            with socket.socket() as s:
                s.bind(('127.0.0.1',int(cfg['port'])))
        start(args.kind,args.name)
    elif args.action in {'stop','cancel'}:
        stop(args.kind,args.name)
    elif args.action == 'restart':
        stop(args.kind,args.name)
        start(args.kind,args.name)
    elif args.action == 'remove':
        stop(args.kind,args.name)
        config.unlink(missing_ok=True)
        state.unlink(missing_ok=True)
        with __import__('control_state').database() as db:
            db.execute('DELETE FROM runtime WHERE kind=? AND name=?',(args.kind,args.name))
    elif args.action in {'enable','disable'}:
        cfg=load(config)
        cfg['enabled']=args.action=='enable'
        atomic(config,cfg)
    elif args.action in {'status','info'}:
        data = load(config) if args.action == 'info' else load(state)
        if args.action == 'status' and data.get('state') in {'RUNNING','RESTARTING'} and not alive(pidfile):
            data['state']='CRASHED'
        print(json.dumps(data,indent=2))
        if args.kind=='service' and args.action=='status':
            return 0 if alive(pidfile) else 3
    elif args.action == 'alive':
        return 0 if alive(pidfile) else 1
    elif args.action == 'health':
        if not alive(pidfile):
            return 3
        cfg=load(config)
        if cfg.get('health_type')=='tcp':
            import socket
            with socket.create_connection(('127.0.0.1',int(cfg.get('health_target') or cfg['port'])),timeout=3):
                pass
        elif cfg.get('health_type')=='http':
            import urllib.request
            target=cfg.get('health_target','')
            if not target.startswith(('https://','http://127.0.0.1:','http://localhost:')):
                raise ValueError('health URL must use HTTPS or localhost HTTP')
            with urllib.request.urlopen(target,timeout=5) as response:
                if response.status>=400:
                    return 8
        print('PASS: health check')
    elif args.action == 'reload':
        return subprocess.run([sys.executable, str(Path(__file__).with_name('process_identity.py')),
                               'reload', str(pidfile)+'.identity.json']).returncode
    else:
        raise ValueError('unknown runtime action')
    return 0


if __name__ == '__main__':
    try:
        sys.exit(main())
    except (ValueError,OSError,KeyError,json.JSONDecodeError) as exc:
        print(f'Runtime operation failed: {exc}',file=sys.stderr)
        sys.exit(8)
