#!/usr/bin/env python3
"""Daytona SDK adapter; lifecycle policies are provider settings, never keepalives."""
import argparse
import json
import sys
from control_state import audit, database, name
from fleet_control import read_secret


def summary(sandbox):
    return {key:getattr(sandbox,key,None) for key in ('id','name','state','auto_stop_interval',
              'auto_archive_interval','auto_delete_interval','snapshot','labels')}


def main():
    cli=argparse.ArgumentParser(description=__doc__)
    cli.add_argument('action',choices=['add-account','accounts','capabilities','list','create','inspect','start','stop','delete','lifecycle','snapshot','volume-list','volume-create','preview'])
    cli.add_argument('resource',nargs='?')
    cli.add_argument('--account',default='default')
    cli.add_argument('--secret',default='daytona-api-key')
    cli.add_argument('--region')
    cli.add_argument('--profile',choices=['ephemeral','development','long-running'],default='development')
    cli.add_argument('--snapshot')
    cli.add_argument('--port',type=int,default=8080)
    cli.add_argument('--yes',action='store_true')
    cli.add_argument('--dry-run',action='store_true')
    args=cli.parse_args()
    if args.action=='capabilities':
        print(json.dumps({'provider':'daytona','operations':['list','create','start','stop','delete','inspect','lifecycle','snapshot','volume-list','volume-create','preview'],
                          'cost':'UNKNOWN','bootstrap':'NOT IMPLEMENTED','provider_lifecycle_precedes_node_services':True}))
        return 0
    if args.action=='accounts':
        with database() as db: print(json.dumps([dict(r) for r in db.execute('SELECT * FROM providers WHERE kind=?',('daytona',))],indent=2))
        return 0
    if args.action=='add-account':
        cfg={'secret':name(args.secret),'region':args.region}
        with database() as db: db.execute('INSERT INTO providers VALUES(?,?,?)',(name(args.account),'daytona',json.dumps(cfg)))
        return 0
    policy={'auto_stop_interval':15,'auto_archive_interval':10080,'auto_delete_interval':-1}
    if args.profile=='ephemeral': policy.update(auto_delete_interval=0)
    elif args.profile=='long-running': policy.update(auto_stop_interval=0)
    if args.dry_run:
        print(json.dumps({'action':args.action,'account':args.account,'resource':args.resource,'policy':policy,'destructive_auto_delete':policy['auto_delete_interval']==0},indent=2))
        return 0
    if args.action in {'create','delete','stop','lifecycle','snapshot','volume-create'} and not args.yes:
        raise ValueError('provider mutation requires --yes; inspect --dry-run first')
    try:
        from daytona import Daytona, DaytonaConfig, CreateSandboxFromSnapshotParams
    except ImportError:
        print('Daytona capability unavailable: install the optional daytona SDK.',file=sys.stderr)
        return 3
    with database() as db: row=db.execute('SELECT config FROM providers WHERE name=? AND kind=?',(args.account,'daytona')).fetchone()
    if row is None: raise ValueError('register account with provider daytona add-account first')
    cfg=json.loads(row['config'])
    client=Daytona(DaytonaConfig(api_key=read_secret(cfg['secret']),api_url='https://app.daytona.io/api',target=cfg.get('region')))
    if args.action=='list': result=[summary(s) for s in client.list(request_timeout=30)]
    elif args.action=='create':
        options=dict(policy,name=name(args.resource or ''),public=False)
        if args.snapshot: options['snapshot']=args.snapshot
        result=summary(client.create(CreateSandboxFromSnapshotParams(**options),timeout=60))
    elif args.action=='volume-list':
        result=[{'id':v.id,'name':v.name} for v in client.volume.list()]
    elif args.action=='volume-create':
        v=client.volume.get(name(args.resource or ''),True)
        result={'id':v.id,'name':v.name}
    else:
        s=client.get(args.resource,request_timeout=30)
        if args.action=='start': client.start(s,timeout=60)
        elif args.action=='stop': client.stop(s,timeout=60)
        elif args.action=='delete': client.delete(s,timeout=60,wait=True)
        elif args.action=='lifecycle':
            s.set_autostop_interval(policy['auto_stop_interval'])
            s.set_auto_archive_interval(policy['auto_archive_interval'])
            s.set_auto_delete_interval(policy['auto_delete_interval'])
        elif args.action=='snapshot':
            if not args.snapshot: raise ValueError('--snapshot name required')
            s.create_snapshot(args.snapshot)
        if args.action=='preview':
            if not 1024<=args.port<=65535: raise ValueError('port must be unprivileged')
            # Authenticated preview link only; no signed token printed.
            link=s.get_preview_link(args.port)
            result={'url':link.url,'authentication':'provider access required'}
        else: result=summary(s)
    audit('provider',args.resource or args.account,args.action,0)
    print(json.dumps(result,indent=2,default=str))
    return 0


if __name__=='__main__':
    try: sys.exit(main())
    except Exception as exc:
        # SDK exception strings can contain credential-bearing request URLs.
        print(f'Daytona operation failed ({type(exc).__name__}); check account, permissions and provider state.',file=sys.stderr)
        sys.exit(8)
