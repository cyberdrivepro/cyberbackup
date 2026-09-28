CREATE TABLE nodes(name TEXT PRIMARY KEY,address TEXT NOT NULL,created_at INTEGER NOT NULL);
CREATE TABLE jobs(id INTEGER PRIMARY KEY,program TEXT NOT NULL,state TEXT NOT NULL,created_at INTEGER NOT NULL,finished_at INTEGER,exit_code INTEGER);
CREATE TABLE pairing_invites(code_hash TEXT PRIMARY KEY,expires_at INTEGER NOT NULL,consumed_at INTEGER);
CREATE TABLE trusted_controllers(name TEXT PRIMARY KEY,public_key TEXT NOT NULL UNIQUE,created_at INTEGER NOT NULL);
CREATE TABLE audit_events(id INTEGER PRIMARY KEY,event TEXT NOT NULL,actor TEXT NOT NULL,created_at INTEGER NOT NULL);
PRAGMA user_version=1;
