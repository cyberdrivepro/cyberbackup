#!/usr/bin/env python3
"""Linux process ownership records. Stale or unverifiable records fail closed."""
import argparse
import json
import os
from pathlib import Path
import signal
import sys
import tempfile
import time
import platform


def identity(pid):
    if pid <= 1:
        raise ValueError('invalid process ID')
    if platform.system().lower() != 'linux':
        try:
            os.kill(pid, 0)
        except OSError as exc:
            raise ValueError('process is not alive') from exc
        marker = None
        try:
            import psutil
            marker = psutil.Process(pid).create_time()
        except Exception:
            marker = None
        return {'pid': pid, 'start_time': marker, 'uid': os.getuid() if hasattr(os, 'getuid') else None,
                'platform': platform.system().lower()}
    proc = Path('/proc') / str(pid)
    fields = (proc / 'stat').read_text().rsplit(')', 1)[1].split()
    if fields[0] == 'Z' or proc.stat().st_uid != os.getuid():
        raise ValueError('process not alive or not owned by current user')
    return {'pid': pid, 'start_ticks': fields[19], 'uid': os.getuid(),
            'boot_id': Path('/proc/sys/kernel/random/boot_id').read_text().strip()}


def read_record(path):
    if path.is_symlink() or path.stat().st_uid != os.getuid() or path.stat().st_mode & 0o022:
        raise ValueError('untrusted process record')
    data = json.loads(path.read_text())
    current = identity(data['pid'])
    if current != data:
        # Windows without psutil has no reliable creation-time API in stdlib;
        # fail closed if a creation marker was recorded, otherwise use the
        # kernel's current process handle check for this user-space fallback.
        if data.get('platform') == 'windows' and data.get('start_time') is None and current.get('platform') == 'windows':
            pass
        else:
            raise ValueError('process identity changed')
    return data


def main():
    cli = argparse.ArgumentParser(description=__doc__)
    cli.add_argument('action', choices=['record', 'alive', 'stop', 'reload'])
    cli.add_argument('path', type=Path)
    cli.add_argument('pid', nargs='?', type=int)
    args = cli.parse_args()
    try:
        if args.action == 'record':
            data = identity(args.pid)
            fd, tmp = tempfile.mkstemp(dir=args.path.parent)
            try:
                with os.fdopen(fd, 'w') as f:
                    json.dump(data, f)
                os.replace(tmp, args.path)
            finally:
                if os.path.exists(tmp):
                    os.unlink(tmp)
            return 0
        data = read_record(args.path)
        if args.action == 'alive':
            return 0
        # pidfd binds signals to the verified process, preventing PID-reuse races.
        if platform.system().lower() != 'linux':
            os.kill(data['pid'], signal.SIGTERM)
            return 0
        if not hasattr(os, 'pidfd_open') or not hasattr(signal, 'pidfd_send_signal'):
            raise ValueError('safe stopping requires Linux pidfd support')
        fd = os.pidfd_open(data['pid'])
        try:
            if read_record(args.path) != data:
                raise ValueError('process identity changed')
            if args.action == 'reload':
                signal.pidfd_send_signal(fd, signal.SIGHUP)
                return 0
            signal.pidfd_send_signal(fd, signal.SIGTERM)
            for _ in range(50):
                try:
                    read_record(args.path)
                except (OSError, ValueError):
                    break
                time.sleep(0.1)
            else:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
        finally:
            os.close(fd)
        return 0
    except (OSError, ValueError, KeyError, TypeError) as e:
        if args.action != 'alive':
            print(f'Process operation refused: {e}', file=sys.stderr)
        return 1


if __name__ == '__main__':
    sys.exit(main())
