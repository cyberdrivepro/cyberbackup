#!/usr/bin/env python3
"""Transactional Git releases, argv deployment templates and durable interval jobs."""
import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import time
import uuid
from control_state import atomic, audit, database, name, root
from runtime_control import load, paths, start, stop

REPO=Path(__file__).resolve().parent.parent


def run(argv,cwd=None,timeout=120):
    # Git URLs supplied here have already been checked to exclude embedded tokens.
    result=subprocess.run(argv,cwd=cwd,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=timeout)
    if result.returncode:
        raise ValueError(f'{argv[0]} operation failed (exit {result.returncode})')
    return result.stdout.decode(errors='replace').strip()


def git_url(value):
    if not (re.fullmatch(r'https://[A-Za-z0-9.-]+/[A-Za-z0-9_./-]+',value) or
            re.fullmatch(r'git@[A-Za-z0-9.-]+:[A-Za-z0-9_./-]+',value)):
        raise ValueError('use a credential-free HTTPS URL or SSH deploy-key URL')
    return value


def deploy(args):
    app=name(args.resource or '')
    directory=root()/ 'deployments'/app
    current=directory/'current.json'
    previous=directory/'previous.json'
    if args.action=='inspect':
        print(json.dumps(load(current),indent=2));return 0
    if args.action=='rollback':
        old=load(previous)
        if not old: raise ValueError('no previous deployment')
        active=load(current)
        stop('service',f'app-{app}')
        config,*_=paths('service',f'app-{app}')
        atomic(config,old['service'])
        try: start('service',f'app-{app}')
        except Exception:
            if active:
                atomic(config,active['service']);start('service',f'app-{app}')
            raise
        atomic(current,old);atomic(previous,active)
        return 0
    template=json.loads(args.template.read_text()) if args.template else load(current).get('template')
    if not template: raise ValueError('--template FILE is required for a new deployment')
    if template.get('format_version')!=1: raise ValueError('unsupported template format')
    for key in ('start_argv','build_argv'):
        value=template.get(key,[])
        if not isinstance(value,list) or not all(isinstance(x,str) and '\x00' not in x for x in value):
            raise ValueError(f'{key} must be a string array')
    if not template.get('start_argv'): raise ValueError('start_argv required')
    url=git_url(template['repo'])
    if args.dry_run:
        print(json.dumps({'application':app,'template':template,'operation':'clone, build, start, health, rollback on failure'},indent=2));return 0
    if not args.yes: raise ValueError('deployment runs project code; pass --yes after reviewing template')
    release=directory/'releases'/str(uuid.uuid4())
    release.parent.mkdir(parents=True,exist_ok=True,mode=0o700)
    run(['git','clone','--depth','1','--',url,str(release)],timeout=args.timeout)
    if template.get('build_argv'):
        run(template['build_argv'],cwd=release,timeout=args.timeout)
    commit=run(['git','rev-parse','HEAD'],cwd=release)
    service={'name':f'app-{app}','argv':template['start_argv'],'command':template['start_argv'][0],
             'working_directory':str(release),'restart':'on-failure','max_restarts':5,'enabled':True,
             'health_type':template.get('health_type','process'),'health_target':template.get('health_target','')}
    config,*_=paths('service',f'app-{app}')
    old=load(current)
    if old: stop('service',f'app-{app}')
    atomic(config,service)
    try:
        start('service',f'app-{app}')
        run([sys.executable,str(REPO/'scripts/runtime_control.py'),'service','health',f'app-{app}'],timeout=15)
    except Exception:
        stop('service',f'app-{app}')
        if old:
            atomic(config,old['service']);start('service',f'app-{app}')
        raise
    if old: atomic(previous,old)
    atomic(current,{'commit':commit,'release':str(release),'template':template,'service':service})
    audit('deploy',app,args.action,0)
    print(json.dumps({'application':app,'commit':commit,'state':'RUNNING'}))
    return 0


def update(args):
    state=root()/'updates'
    state.mkdir(exist_ok=True,mode=0o700)
    if args.action=='check':
        print(run(['git','ls-remote','--tags','https://github.com/cyberdrivepro/cyberbackup.git']))
        return 0
    bin_dir=Path.home()/'.local/bin'
    wrapper=bin_dir/'cybervps'
    current=load(state/'current.json')
    if args.action=='rollback':
        previous=load(state/'previous.json')
        if not previous: raise ValueError('no previous managed update')
        target=Path(previous['release'])
    elif args.action=='apply':
        commit=args.resource or ''
        if not re.fullmatch(r'[0-9a-f]{40}',commit): raise ValueError('update apply requires an explicit trusted 40-character commit SHA')
        target=state/'releases'/commit
        if args.dry_run: print(json.dumps({'commit':commit,'destination':str(target)}));return 0
        if not args.yes: raise ValueError('update requires --yes and trusted commit')
        if target.exists(): raise ValueError('release already staged; inspect or use a different commit')
        target.mkdir(parents=True,mode=0o700)
        run(['git','init',str(target)])
        run(['git','fetch','--depth','1','https://github.com/cyberdrivepro/cyberbackup.git',commit],cwd=target)
        actual=run(['git','rev-parse','FETCH_HEAD'],cwd=target)
        if actual!=commit: raise ValueError('fetched commit mismatch')
        run(['git','checkout','--detach',commit],cwd=target)
        for script in target.rglob('*.sh'): run(['bash','-n',str(script)])
        run(['bash',str(target/'cybervps.sh'),'--help'])
        cfg=root('config')
        backup=state/f'config-before-{commit}'
        shutil.copytree(cfg,backup,ignore=shutil.ignore_patterns('secrets','identity','*.key'),dirs_exist_ok=False)
    else: raise ValueError('unknown update operation')
    if not (target/'cybervps.sh').is_file(): raise ValueError('managed release is missing')
    bin_dir.mkdir(parents=True,exist_ok=True)
    if wrapper.exists() and not current: raise ValueError('existing unmanaged cybervps launcher will not be overwritten')
    import shlex
    temporary=bin_dir/f'.cybervps-{uuid.uuid4()}'
    temporary.write_text('#!/usr/bin/env bash\nexec bash '+shlex.quote(str(target/'cybervps.sh'))+' "$@"\n')
    temporary.chmod(0o700)
    os.replace(temporary,wrapper)
    if current: atomic(state/'previous.json',current)
    atomic(state/'current.json',{'release':str(target),'commit':target.name})
    print(f'Managed launcher updated: {wrapper}')
    return 0


def schedule(args,command):
    if args.action=='list':
        with database() as db: print(json.dumps([dict(r) for r in db.execute('SELECT * FROM schedules')],indent=2))
        return 0
    if args.action=='add':
        if not command or args.interval<60: raise ValueError('argv and interval >=60 seconds required')
        with database() as db:
            db.execute('INSERT INTO schedules(name,interval_seconds,next_run,argv) VALUES(?,?,?,?)',
                       (name(args.resource or ''),args.interval,time.time()+args.interval,json.dumps(command)))
        return 0
    if args.action=='remove':
        with database() as db: db.execute('DELETE FROM schedules WHERE name=?',(name(args.resource or ''),))
        return 0
    if args.action!='run': raise ValueError('unknown schedule action')
    # One tick, suitable for a user crontab or an explicitly supervised process.
    with database() as db:
        db.execute('BEGIN IMMEDIATE')
        rows=list(db.execute('SELECT * FROM schedules WHERE enabled=1 AND next_run<=?',(time.time(),)))
        for row in rows: db.execute('UPDATE schedules SET next_run=? WHERE name=?',(time.time()+row['interval_seconds'],row['name']))
    failed=0
    for row in rows:
        result=subprocess.run([sys.executable,str(REPO/'scripts/runtime_control.py'),'job','run',row['name'],
                               '--restart','never','--',*json.loads(row['argv'])])
        failed+=result.returncode!=0
    return 10 if failed else 0


def cleanup(args):
    candidates=[]
    now=time.time()
    for directory in (root()/'logs',Path(os.environ.get('XDG_CACHE_HOME',str(Path.home()/'.cache')))/'cybervps'):
        if not directory.exists(): continue
        for p in directory.rglob('*'):
            if p.is_symlink() or not p.is_file(): continue
            if (p.suffix=='.part' or p.name.endswith('.log.1')) and now-p.stat().st_mtime>7*86400:
                candidates.append(p)
    print(json.dumps({'delete':args.yes,'files':[str(p) for p in candidates]},indent=2))
    if args.yes:
        for p in candidates: p.unlink()
    return 0


def main():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('component',choices=['deploy','update','schedule','cleanup'])
    cli.add_argument('action',nargs='?',default='list')
    cli.add_argument('resource',nargs='?')
    cli.add_argument('--template',type=Path)
    cli.add_argument('--timeout',type=int,default=600)
    cli.add_argument('--interval',type=int,default=3600)
    cli.add_argument('--yes',action='store_true')
    cli.add_argument('--dry-run',action='store_true')
    args,command=cli.parse_known_args()
    if command[:1]==['--']: command=command[1:]
    if not 1<=args.timeout<=3600: raise ValueError('timeout must be 1-3600 seconds')
    if args.component=='deploy': return deploy(args)
    if args.component=='update': return update(args)
    if args.component=='schedule': return schedule(args,command)
    return cleanup(args)


if __name__=='__main__':
    try: sys.exit(main())
    except (ValueError,OSError,KeyError,subprocess.TimeoutExpired) as exc:
        print(f'Operation failed: {exc}',file=sys.stderr)
        sys.exit(8)
