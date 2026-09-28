#!/usr/bin/env python3
"""SSH fleet and constrained files API. Host keys must already be trusted."""
import argparse
import base64
from concurrent.futures import ThreadPoolExecutor, as_completed
import getpass
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile
import uuid
from control_state import audit, database, name, root


def emit(value):
    print(json.dumps(value, indent=2))


def node(resource):
    with database() as db:
        row=db.execute('SELECT * FROM nodes WHERE name=?',(name(resource),)).fetchone()
    if row is None:
        raise ValueError('node is not registered')
    return dict(row)


def ssh_args(row, interactive=False):
    args=['ssh','-o','BatchMode=yes','-o','StrictHostKeyChecking=yes','-o','ConnectTimeout=10',
          '-o','ServerAliveInterval=15','-o','ServerAliveCountMax=2','-p',str(row['port'])]
    if row.get('identity_file'):
        args+=['-i',row['identity_file'],'-o','IdentitiesOnly=yes']
    if interactive:
        args+=['-t']
    return args+[f"{row['user']}@{row['host']}"]


def execute(row, argv, timeout=30, data=None):
    request_id=str(uuid.uuid4())
    with tempfile.TemporaryFile() as output, tempfile.TemporaryFile() as error:
        try:
            process=subprocess.run(ssh_args(row)+[shlex.join(argv)],input=data,stdout=output,stderr=error,timeout=timeout)
            rc=process.returncode
        except subprocess.TimeoutExpired:
            rc=8
        output.seek(0); error.seek(0)
        result={'node':row['name'],'exit_code':rc,'stdout':output.read(65536).decode(errors='replace'),
                'stderr':error.read(8192).decode(errors='replace'),'request_id':request_id}
    # Metadata only: command arguments can contain credentials.
    audit('fleet',row['name'],'exec',rc,request_id)
    return result


FILE_HELPER=r'''
import base64,hashlib,json,os,pathlib,sys,tempfile
r=json.load(sys.stdin)
base=pathlib.Path.home().resolve()
p=(base/r['path']).resolve()
if not p.is_relative_to(base): raise ValueError('path outside remote home')
action=r['action']
if action=='ls':
    result=[{'name':x.name,'directory':x.is_dir(),'size':x.stat().st_size} for x in sorted(p.iterdir())][:1000]
elif action in ('cat','download'):
    if p.stat().st_size>16777216: raise ValueError('file exceeds 16 MiB limit')
    data=p.read_bytes()
    result={'content':base64.b64encode(data).decode(),'sha256':hashlib.sha256(data).hexdigest()}
elif action=='upload':
    data=base64.b64decode(r['content'],validate=True)
    if len(data)>16777216 or hashlib.sha256(data).hexdigest()!=r['sha256']: raise ValueError('size/hash mismatch')
    if not p.parent.is_dir(): raise ValueError('destination parent must exist')
    fd,tmp=tempfile.mkstemp(dir=p.parent)
    try:
        with os.fdopen(fd,'wb') as f: f.write(data); f.flush(); os.fsync(f.fileno())
        if r.get('overwrite'): os.replace(tmp,p)
        else: os.link(tmp,p); os.unlink(tmp)
    finally:
        if os.path.exists(tmp): os.unlink(tmp)
    result={'sha256':hashlib.sha256(p.read_bytes()).hexdigest(),'bytes':len(data)}
else: raise ValueError('unknown action')
print(json.dumps(result))
'''


def secret_path(resource):
    directory=root('config')/'secrets'
    directory.mkdir(mode=0o700,exist_ok=True)
    path=directory/name(resource)
    if path.is_symlink():
        raise ValueError('secret cannot be a symlink')
    return path


def read_secret(resource):
    path=secret_path(resource)
    if os.name!='nt' and path.stat().st_mode & 0o077:
        raise ValueError('secret permissions must be 0600')
    return path.read_text().strip()


def main():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('component',choices=['nodes','fleet','files','secret'])
    cli.add_argument('action')
    cli.add_argument('resource',nargs='?')
    cli.add_argument('--host')
    cli.add_argument('--user')
    cli.add_argument('--port',type=int,default=22)
    cli.add_argument('--identity-file')
    cli.add_argument('--tag',action='append',default=[])
    cli.add_argument('--concurrency',type=int,default=4)
    cli.add_argument('--timeout',type=int,default=30)
    cli.add_argument('--yes',action='store_true')
    cli.add_argument('--dry-run',action='store_true')
    cli.add_argument('--show',action='store_true')
    cli.add_argument('--overwrite',action='store_true')
    cli.add_argument('--local',type=Path)
    cli.add_argument('--path',default='.')
    args,command=cli.parse_known_args()
    if command[:1]==['--']: command=command[1:]
    if not 1<=args.timeout<=3600 or not 1<=args.concurrency<=32:
        raise ValueError('timeout must be 1-3600s; concurrency 1-32')
    if args.component=='secret':
        if args.action=='list':
            directory=root('config')/'secrets'
            emit([p.name for p in directory.glob('*') if p.is_file() and not p.is_symlink()])
            return 0
        p=secret_path(args.resource or '')
        if args.action=='set':
            if os.name=='nt':
                raise ValueError('use native cyberagent secret on Windows for DPAPI protection')
            value=getpass.getpass('Secret value: ') if sys.stdin.isatty() else sys.stdin.read(65537).rstrip('\n')
            if not value or len(value)>65536: raise ValueError('secret must contain 1-65536 characters')
            fd,tmp=tempfile.mkstemp(dir=p.parent)
            with os.fdopen(fd,'w') as f: f.write(value)
            os.replace(tmp,p)
        elif args.action=='get':
            if not args.show: raise ValueError('secret output requires --show')
            print(read_secret(args.resource))
        elif args.action=='delete': p.unlink()
        else: raise ValueError('unknown secret action')
        return 0
    if args.component=='nodes' and args.action=='add':
        name(args.resource or '')
        if not args.host or not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.:-]*',args.host):
            raise ValueError('valid SSH hostname/address required')
        if not args.user or not re.fullmatch(r'[A-Za-z0-9_][A-Za-z0-9_.-]*',args.user):
            raise ValueError('SSH user required')
        if not 1<=args.port<=65535: raise ValueError('invalid SSH port')
        key=str(Path(args.identity_file).expanduser().resolve()) if args.identity_file else None
        if key and not Path(key).is_file(): raise ValueError('identity file does not exist')
        with database() as db:
            db.execute('INSERT INTO nodes VALUES(?,?,?,?,?,?)',(args.resource,args.host,args.user,args.port,key,json.dumps(args.tag)))
        return 0
    if args.component=='nodes' and args.action=='list':
        with database() as db: emit([dict(r) for r in db.execute('SELECT * FROM nodes ORDER BY name')])
        return 0
    if args.component=='nodes' and args.action in {'inspect','remove','tag'}:
        row=node(args.resource or '')
        if args.action=='inspect': emit(row)
        elif args.action=='remove':
            with database() as db: db.execute('DELETE FROM nodes WHERE name=?',(row['name'],))
        else:
            tags=sorted(set(json.loads(row['tags'])+args.tag+command))
            with database() as db: db.execute('UPDATE nodes SET tags=? WHERE name=?',(json.dumps(tags),row['name']))
        return 0
    if args.component=='files':
        row=node(args.resource or '')
        request={'action':args.action,'path':args.path,'overwrite':args.overwrite}
        if args.action=='upload':
            if not args.local or args.local.stat().st_size>16777216: raise ValueError('upload requires --local file of at most 16 MiB')
            data=args.local.read_bytes()
            request.update(content=base64.b64encode(data).decode(),sha256=hashlib.sha256(data).hexdigest())
        result=execute(row,['python3','-c',FILE_HELPER],args.timeout,json.dumps(request).encode())
        if result['exit_code']: emit(result); return 8
        value=json.loads(result['stdout'])
        if args.action in {'cat','download'}:
            data=base64.b64decode(value['content'])
            if hashlib.sha256(data).hexdigest()!=value['sha256']: return 9
            if args.action=='cat': sys.stdout.buffer.write(data)
            else:
                if not args.local: raise ValueError('--local destination is required')
                mode='wb' if args.overwrite else 'xb'
                with args.local.open(mode) as f: f.write(data)
        else: emit(value)
        return 0
    if args.component=='nodes' and args.action=='shell':
        return subprocess.run(ssh_args(node(args.resource or ''),True)).returncode
    if args.component=='nodes' and args.action in {'exec','health','logs'} and args.resource:
        rows=[node(args.resource)]
    else:
        with database() as db: rows=[dict(r) for r in db.execute('SELECT * FROM nodes ORDER BY name')]
        rows=[r for r in rows if all(t in json.loads(r['tags']) for t in args.tag)]
    if args.action=='health': command=['sh','-c','uname -s; uptime; df -Pk "$HOME"']
    elif args.action=='logs': command=['sh','-c','tail -n 50 "${XDG_STATE_HOME:-$HOME/.local/state}/cybervps/logs/cybervps.log"']
    elif args.action=='backup': command=['cybervps','backup','create']
    elif args.action!='exec': raise ValueError('unsupported fleet operation')
    if not command: raise ValueError('command required after --')
    if args.dry_run:
        emit({'nodes':[r['name'] for r in rows],'argv':command})
        return 0
    if args.component=='fleet' and args.action not in {'health','logs'} and not args.yes:
        raise ValueError('fleet execution requires --yes; review --dry-run first')
    results=[]
    with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
        futures=[pool.submit(execute,row,command,args.timeout) for row in rows]
        for future in as_completed(futures): results.append(future.result())
    emit(results)
    failed=sum(r['exit_code']!=0 for r in results)
    return 10 if failed and failed<len(results) else (8 if failed else 0)


if __name__=='__main__':
    try: sys.exit(main())
    except (ValueError,OSError,KeyError) as exc:
        print(f'Control operation failed: {exc}',file=sys.stderr)
        sys.exit(6)
