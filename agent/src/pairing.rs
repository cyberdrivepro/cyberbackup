use anyhow::{bail, Context, Result};
use base64::{
    engine::general_purpose::{STANDARD, URL_SAFE_NO_PAD},
    Engine,
};
use rand::RngCore;
use rusqlite::{params, Connection, TransactionBehavior};
use sha2::{Digest, Sha256};

fn hash(value: &str) -> String {
    format!("{:x}", Sha256::digest(value.as_bytes()))
}

pub fn create(db: &mut Connection, expires: u64) -> Result<String> {
    anyhow::ensure!(
        (30..=3600).contains(&expires),
        "Expiry must be between 30 and 3600 seconds"
    );
    let mut random = [0u8; 32];
    rand::rngs::OsRng.fill_bytes(&mut random);
    let code = URL_SAFE_NO_PAD.encode(random);
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    tx.execute(
        "DELETE FROM pairing_invites WHERE expires_at<?1 OR consumed_at IS NOT NULL",
        [crate::database::now()],
    )?;
    tx.execute(
        "INSERT INTO pairing_invites(code_hash,expires_at) VALUES(?1,?2)",
        params![hash(&code), crate::database::now() + expires as i64],
    )?;
    tx.commit()?;
    Ok(code)
}

pub fn redeem(db: &mut Connection, code: &str, controller: &str, public_key: &str) -> Result<()> {
    crate::config::validate_name(controller)?;
    let key: [u8; 32] = STANDARD
        .decode(public_key)?
        .try_into()
        .map_err(|_| anyhow::anyhow!("Public key must be 32 bytes"))?;
    ed25519_dalek::VerifyingKey::from_bytes(&key)
        .context("Invalid Ed25519 controller public key")?;
    let tx = db.transaction_with_behavior(TransactionBehavior::Immediate)?;
    let changed = tx.execute("UPDATE pairing_invites SET consumed_at=?1 WHERE code_hash=?2 AND consumed_at IS NULL AND expires_at>?1", params![crate::database::now(),hash(code)])?;
    if changed != 1 {
        bail!("Pairing invitation is invalid, expired, or already consumed");
    }
    tx.execute(
        "INSERT INTO trusted_controllers(name,public_key,created_at) VALUES(?1,?2,?3)",
        params![controller, public_key, crate::database::now()],
    )?;
    tx.execute(
        "INSERT INTO audit_events(event,actor,created_at) VALUES('controller-paired',?1,?2)",
        params![controller, crate::database::now()],
    )?;
    tx.commit()?;
    Ok(())
}

#[cfg(test)]
mod tests {
    #[test]
    fn pairing_is_one_use_and_expires() {
        let tmp = tempfile::tempdir().unwrap();
        let cfg = crate::config::Config::new(Some(tmp.path().join("state"))).unwrap();
        let mut db = crate::database::open(&cfg).unwrap();
        let public = crate::identity::public_key(&cfg).unwrap();
        let code = super::create(&mut db, 300).unwrap();
        super::redeem(&mut db, &code, "controller", &public).unwrap();
        assert!(super::redeem(&mut db, &code, "replay", &public).is_err());
        let expired = super::create(&mut db, 30).unwrap();
        db.execute("UPDATE pairing_invites SET expires_at=0", [])
            .unwrap();
        assert!(super::redeem(&mut db, &expired, "expired", &public).is_err());
        assert!(super::create(&mut db, 0).is_err());
    }
}
