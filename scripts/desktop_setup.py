#!/usr/bin/env python3
"""Authorized Debian/Ubuntu desktop install with private defaults and service-start guard."""
import argparse
import contextlib
import fcntl
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile


def atomic(path, data, mode=0o644):
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'wb') as handle:
            handle.write(data)
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def update_ini(path, section, changes):
    if path.is_symlink() or not path.is_file():
        raise ValueError(f'Expected regular installed configuration: {path}')
    original = path.read_bytes()
    backup = path.with_name(path.name + '.cybervps-original')
    if not backup.exists():
        with backup.open('xb') as handle:
            handle.write(original)
        os.chmod(backup, 0o600)
    lines, output, active, found = original.decode('utf-8').splitlines(), [], False, False
    pending = dict(changes)
    for line in lines:
        match = re.fullmatch(r'\s*\[([^]]+)\]\s*', line)
        if match:
            if active:
                output.extend(f'{key}={value}' for key, value in pending.items())
                pending.clear()
            active = match[1].lower() == section.lower()
            found = found or active
        key = line.split('=', 1)[0].strip() if '=' in line else ''
        matching = next((k for k in changes if k.lower() == key.lower()), None)
        if active and matching:
            if matching in pending:
                output.append(f'{matching}={pending.pop(matching)}')
            continue
        output.append(line)
    if not found:
        output.append(f'[{section}]')
    output.extend(f'{key}={value}' for key, value in pending.items())
    atomic(path, ('\n'.join(output) + '\n').encode(), path.stat().st_mode & 0o777)


def configure(port):
    update_ini(Path('/etc/xrdp/xrdp.ini'), 'Globals', {'port': f'tcp://127.0.0.1:{port}'})
    update_ini(Path('/etc/xrdp/sesman.ini'), 'Globals', {'ListenAddress': '127.0.0.1'})
    update_ini(Path('/etc/xrdp/sesman.ini'), 'Security', {'AllowRootLogin': 'false'})


@contextlib.contextmanager
def service_start_guard():
    policy = Path('/usr/sbin/policy-rc.d')
    if policy.is_symlink():
        raise ValueError('Existing policy-rc.d is a symlink; configure desktop packages manually')
    backup = Path('/usr/sbin/policy-rc.d.cybervps-save')
    if backup.exists():
        raise ValueError('A previous desktop install policy backup exists; inspect and restore it before retrying')
    existed = policy.exists()
    if existed:
        shutil.copy2(policy, backup)
    wrapper = '#!/bin/sh\ncase "$1" in xrdp|xrdp-sesman) exit 101;; esac\n'
    wrapper += 'exec /usr/sbin/policy-rc.d.cybervps-save "$@"\n' if existed else 'exit 0\n'
    atomic(policy, wrapper.encode(), 0o755)
    try:
        yield
    finally:
        if existed:
            os.replace(backup, policy)
        else:
            policy.unlink()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['install', 'configure'])
    parser.add_argument('--port', type=int, default=3389)
    args = parser.parse_args()
    if os.getuid() != 0:
        parser.error('requires authorized root execution')
    if not 1024 <= args.port <= 65535:
        parser.error('port must be between 1024 and 65535')
    state = Path('/run/cybervps-desktop')
    state.mkdir(mode=0o700, exist_ok=True)
    if state.is_symlink() or state.stat().st_uid != 0:
        parser.error('untrusted desktop runtime directory')
    with (state / 'install.lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        if args.action == 'install':
            with service_start_guard():
                subprocess.run(['apt-get', '-y', '--no-install-recommends', 'install',
                                'xfce4', 'xrdp', 'xorgxrdp', 'dbus-x11'],
                               env={**os.environ, 'DEBIAN_FRONTEND': 'noninteractive'}, check=True)
                configure(args.port)
        else:
            configure(args.port)
    print(f'Desktop configured for 127.0.0.1:{args.port}; root desktop login disabled.')
    print('Original configuration retained in /etc/xrdp/*.cybervps-original.')


if __name__ == '__main__':
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        raise SystemExit(f'Desktop setup failed: {exc}')
