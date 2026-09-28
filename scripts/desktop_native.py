#!/usr/bin/env python3
"""Bounded XRDP supervisor for Linux hosts without an operational init system."""
import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import socket
import subprocess
import sys
import time

from desktop_setup import atomic
from process_identity import identity, read_record

STATE = Path('/run/cybervps-desktop')
RECORD = STATE / 'supervisor.json'
LOG = STATE / 'native.log'
STOP = False


def running():
    try:
        return read_record(RECORD)
    except (OSError, ValueError, KeyError, TypeError):
        return None


def listening(port):
    try:
        with socket.create_connection(('127.0.0.1', port), timeout=0.5):
            return True
    except OSError:
        return False


def stop_children(children):
    for child in reversed(children):
        if child.poll() is None:
            child.terminate()
    for child in reversed(children):
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()


def worker(port):
    global STOP

    def request_stop(_signal, _frame):
        global STOP
        STOP = True

    signal.signal(signal.SIGTERM, request_stop)
    signal.signal(signal.SIGINT, request_stop)
    with (STATE / 'native.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        atomic(RECORD, json.dumps(identity(os.getpid())).encode(), 0o600)
        children = []
        try:
            for attempt in range(6):
                if STOP:
                    break
                # Fixed executable/config paths; no shell, supplied commands or PID adoption.
                children = [subprocess.Popen(['/usr/sbin/xrdp-sesman', '--nodaemon', '--config', '/etc/xrdp/sesman.ini'])]
                time.sleep(0.5)
                children.append(subprocess.Popen(['/usr/sbin/xrdp', '--nodaemon', '--config', '/etc/xrdp/xrdp.ini']))
                deadline = time.monotonic() + 15
                while not STOP and all(child.poll() is None for child in children):
                    if time.monotonic() >= deadline and not listening(port):
                        print('XRDP startup deadline exceeded', flush=True)
                        break
                    time.sleep(0.25)
                stop_children(children)
                children = []
                if STOP:
                    break
                print(f'XRDP process exited; restart {attempt + 1}/5', flush=True)
                for _ in range(min(30, 2 ** attempt) * 4):
                    if STOP:
                        break
                    time.sleep(0.25)
            return 0 if STOP else 8
        finally:
            stop_children(children)
            RECORD.unlink(missing_ok=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['start', 'stop', 'status', 'logs', 'worker'])
    parser.add_argument('--port', type=int, default=3389)
    args = parser.parse_args()
    if os.getuid() != 0 or sys.platform != 'linux':
        parser.error('requires authorized Linux root execution')
    if not 1024 <= args.port <= 65535:
        parser.error('invalid unprivileged listener port')
    if args.action in ('start', 'worker'):
        STATE.mkdir(mode=0o700, exist_ok=True)
    if STATE.exists() and (STATE.is_symlink() or STATE.stat().st_uid != 0 or STATE.stat().st_mode & 0o022):
        parser.error('untrusted desktop runtime directory')
    if args.action == 'worker':
        return worker(args.port)
    current = running()
    if args.action == 'status':
        print('RUNNING' if current and listening(args.port) else 'STOPPED_OR_UNHEALTHY')
        return 0 if current and listening(args.port) else 3
    if args.action == 'logs':
        if LOG.exists():
            print('\n'.join(LOG.read_text(errors='replace').splitlines()[-100:]))
        return 0
    if args.action == 'stop':
        if current is None:
            print('No owned desktop supervisor is running.')
            return 0
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            parser.error('safe stopping requires Linux pidfd support')
        descriptor = os.pidfd_open(current['pid'])
        try:
            if read_record(RECORD) != current:
                parser.error('desktop process identity changed')
            signal.pidfd_send_signal(descriptor, signal.SIGTERM)
            for _ in range(120):
                if running() is None:
                    return 0
                time.sleep(0.1)
            print('Supervisor is still stopping; inspect desktop logs.', file=sys.stderr)
            return 8
        finally:
            os.close(descriptor)
    if current:
        return 0 if listening(args.port) else 8
    if listening(args.port) or listening(3350):
        parser.error('XRDP or sesman port is already occupied; existing processes are not adopted')
    if LOG.exists() and LOG.stat().st_size > 5 * 1024 * 1024:
        os.replace(LOG, STATE / 'native.previous.log')
    with LOG.open('ab') as log:
        os.chmod(LOG, 0o600)
        child = subprocess.Popen([sys.executable, str(Path(__file__).resolve()), 'worker', '--port', str(args.port)],
                                 stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True)
    for _ in range(60):
        if child.poll() is not None:
            return 8
        if running() and listening(args.port):
            print(f'XRDP native supervisor ready on 127.0.0.1:{args.port}')
            return 0
        time.sleep(0.25)
    print(f'Desktop startup failed; inspect {LOG}', file=sys.stderr)
    return 8


if __name__ == '__main__':
    try:
        raise SystemExit(main())
    except (OSError, ValueError, subprocess.SubprocessError) as exc:
        print(f'Desktop operation failed: {exc}', file=sys.stderr)
        raise SystemExit(8)
