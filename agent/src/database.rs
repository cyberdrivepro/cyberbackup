use crate::config::Config;
use anyhow::Result;
use rusqlite::{params, Connection};
use serde_json::{json, Value};

pub fn now() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs() as i64
}

pub fn open(config: &Config) -> Result<Connection> {
    let path = config.state.join("agent.sqlite");
    crate::config::reject_symlink(&path)?;
    let mut db = Connection::open(&path)?;
    crate::platform::private_file(&path)?;
    db.busy_timeout(std::time::Duration::from_secs(5))?;
    db.execute_batch("PRAGMA foreign_keys=ON;")?;
    let version: i64 = db.pragma_query_value(None, "user_version", |r| r.get(0))?;
    anyhow::ensure!(
        version <= 1,
        "Agent database schema is newer than this binary"
    );
    if version == 0 {
        let tx = db.transaction()?;
        tx.execute_batch(include_str!("../migrations/001_initial.sql"))?;
        tx.commit()?;
    }
    Ok(db)
}

pub fn start_job(db: &Connection, program: &str) -> Result<i64> {
    // Store program only. Arguments and environment may contain secrets.
    db.execute(
        "INSERT INTO jobs(program,state,created_at) VALUES(?1,'STARTING',?2)",
        params![program, now()],
    )?;
    Ok(db.last_insert_rowid())
}

pub fn finish_job(db: &Connection, id: i64, code: i32, timed_out: bool) -> Result<()> {
    let state = if timed_out {
        "TIMEOUT"
    } else if code == 0 {
        "SUCCESS"
    } else {
        "FAILED"
    };
    db.execute(
        "UPDATE jobs SET state=?1,exit_code=?2,finished_at=?3 WHERE id=?4",
        params![state, code, now(), id],
    )?;
    Ok(())
}

pub fn fail_job(db: &Connection, id: i64) -> Result<()> {
    db.execute(
        "UPDATE jobs SET state='FAILED_TO_START',finished_at=?1 WHERE id=?2",
        params![now(), id],
    )?;
    Ok(())
}

pub fn nodes(db: &Connection) -> Result<Value> {
    let mut query = db.prepare("SELECT name,address,created_at FROM nodes ORDER BY name")?;
    let rows = query.query_map([], |r| Ok(json!({"name":r.get::<_,String>(0)?,"address":r.get::<_,String>(1)?,"created_at":r.get::<_,i64>(2)?,"health":"UNKNOWN"})))?;
    Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
}

pub fn controllers(db: &Connection) -> Result<Value> {
    let mut query =
        db.prepare("SELECT name,public_key,created_at FROM trusted_controllers ORDER BY name")?;
    let rows = query.query_map([], |r| Ok(json!({"name":r.get::<_,String>(0)?,"public_key":r.get::<_,String>(1)?,"created_at":r.get::<_,i64>(2)?})))?;
    Ok(Value::Array(rows.collect::<rusqlite::Result<Vec<_>>>()?))
}

#[cfg(test)]
mod tests {
    #[test]
    fn migration_is_idempotent_and_persistent() {
        let tmp = tempfile::tempdir().unwrap();
        let config = crate::config::Config::new(Some(tmp.path().join("state"))).unwrap();
        let db = super::open(&config).unwrap();
        let id = super::start_job(&db, "example").unwrap();
        super::finish_job(&db, id, 124, true).unwrap();
        drop(db);
        let db = super::open(&config).unwrap();
        let state: String = db
            .query_row("SELECT state FROM jobs WHERE id=?1", [id], |r| r.get(0))
            .unwrap();
        assert_eq!(state, "TIMEOUT");
    }
}
