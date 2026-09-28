"""Versioned SQLite control-plane state and private atomic file primitives."""
from contextlib import contextmanager
import json
import os
from pathlib import Path
import re
import sqlite3
import tempfile
import time


def name(value):
    if not re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9_-]{0,63}', value):
        raise ValueError('name must be 1-64 letters, digits, dash or underscore')
    return value


def root(kind='state'):
    var, default = ('XDG_CONFIG_HOME', '.config') if kind == 'config' else ('XDG_STATE_HOME', '.local/state')
    path = Path(os.environ.get(var, str(Path.home()/default))) / 'cybervps'
    path.mkdir(parents=True, exist_ok=True, mode=0o700)
    return path


def atomic(path, data):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, temporary = tempfile.mkstemp(dir=path.parent)
    try:
        with os.fdopen(fd, 'w', encoding='utf-8') as f:
            json.dump(data, f, indent=2)
            f.flush()
            os.fsync(f.fileno())
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


@contextmanager
def database():
    path = root() / 'control.sqlite3'
    if path.is_symlink():
        raise ValueError('database must not be a symlink')
    connection = sqlite3.connect(path, timeout=15)
    os.chmod(path, 0o600)
    connection.row_factory = sqlite3.Row
    connection.execute('PRAGMA foreign_keys=ON')
    connection.execute('PRAGMA journal_mode=WAL')
    version = connection.execute('PRAGMA user_version').fetchone()[0]
    if version > 1:
        connection.close()
        raise ValueError('control database was created by a newer CyberVPS')
    if version == 0:
        connection.executescript('''
        BEGIN IMMEDIATE;
        CREATE TABLE nodes(name TEXT PRIMARY KEY, host TEXT NOT NULL, user TEXT NOT NULL,
                           port INTEGER NOT NULL, identity_file TEXT, tags TEXT NOT NULL DEFAULT '[]');
        CREATE TABLE providers(name TEXT PRIMARY KEY, kind TEXT NOT NULL, config TEXT NOT NULL);
        CREATE TABLE runtime(kind TEXT, name TEXT, data TEXT NOT NULL, PRIMARY KEY(kind,name));
        CREATE TABLE operations(id INTEGER PRIMARY KEY, timestamp REAL, actor TEXT, component TEXT,
                                target TEXT, action TEXT, result INTEGER, request_id TEXT);
        CREATE TABLE schedules(name TEXT PRIMARY KEY, interval_seconds INTEGER, next_run REAL,
                               argv TEXT, enabled INTEGER NOT NULL DEFAULT 1);
        PRAGMA user_version=1;
        COMMIT;
        ''')
    try:
        with connection:
            yield connection
    finally:
        connection.close()


def save_runtime(kind, resource, data):
    with database() as db:
        db.execute('INSERT INTO runtime VALUES(?,?,?) ON CONFLICT(kind,name) DO UPDATE SET data=excluded.data',
                   (kind, resource, json.dumps(data)))


def audit(component, target, action, result, request_id=''):
    with database() as db:
        db.execute('INSERT INTO operations(timestamp,actor,component,target,action,result,request_id) VALUES(?,?,?,?,?,?,?)',
                   (time.time(), str(os.getuid()) if hasattr(os, 'getuid') else os.getlogin(), component,
                    target, action, result, request_id))
