#!/usr/bin/env python3
"""Bind-probed port reservations serialized with an OS lock."""
import argparse
import fcntl
import os
from pathlib import Path
import re
import socket
import tempfile


def free(port,host='127.0.0.1'):
    if not 1<=port<=65535:
        return False
    try:
        with socket.socket(socket.AF_INET6 if ':' in host else socket.AF_INET) as s:
            s.bind((host,port))
        return True
    except OSError:
        return False


def main():
    cli=argparse.ArgumentParser()
    cli.add_argument('action',choices=['probe','reserve'])
    cli.add_argument('port',type=int)
    cli.add_argument('--host',default='127.0.0.1')
    cli.add_argument('--key')
    cli.add_argument('--file',type=Path)
    args=cli.parse_args()
    if args.action=='probe': return 0 if free(args.port,args.host) else 1
    if not args.key or not re.fullmatch(r'[A-Z][A-Z0-9_]*_PORT',args.key):
        raise ValueError('invalid port reservation key')
    if not 1024<=args.port<=65535: raise ValueError('unprivileged port required')
    path=args.file
    path.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    if path.is_symlink(): raise ValueError('port config must not be a symlink')
    lock=path.with_suffix('.lock')
    with lock.open('a') as handle:
        fcntl.flock(handle,fcntl.LOCK_EX)
        values={}
        if path.exists():
            for line in path.read_text().splitlines():
                if re.fullmatch(r'[A-Z][A-Z0-9_]*_PORT=[0-9]+',line):
                    key,value=line.split('=')
                    values[key]=int(value)
        preferred=values.get(args.key,args.port)
        used={v for k,v in values.items() if k!=args.key}
        candidates=[preferred]+list(range(max(1024,preferred+1),65536))+list(range(1024,max(1024,preferred)))
        selected=next((p for p in candidates if p not in used and free(p)),None)
        if selected is None: raise ValueError('no free port in range')
        values[args.key]=selected
        fd,tmp=tempfile.mkstemp(dir=path.parent)
        with os.fdopen(fd,'w') as f:
            for key,value in sorted(values.items()): f.write(f'{key}={value}\n')
        os.replace(tmp,path)
        print(selected)
    return 0


if __name__=='__main__':
    raise SystemExit(main())
