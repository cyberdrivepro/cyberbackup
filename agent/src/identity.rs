use crate::{config::Config, secrets};
use anyhow::Result;
use base64::{engine::general_purpose::STANDARD, Engine};
use ed25519_dalek::SigningKey;
use rand::RngCore;

pub fn public_key(config: &Config) -> Result<String> {
    let path = config.secrets.join("identity-ed25519");
    if !path.exists() {
        let mut bytes = [0u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut bytes);
        // Concurrent initialization may win; only accept an existing valid identity.
        if let Err(error) = secrets::put(config, "identity-ed25519", &bytes) {
            if !path.exists() {
                return Err(error);
            }
        }
        bytes.fill(0);
    }
    let mut bytes = secrets::get(config, "identity-ed25519")?;
    anyhow::ensure!(bytes.len() == 32, "Invalid identity key length");
    let array: [u8; 32] = bytes.as_slice().try_into()?;
    let key = SigningKey::from_bytes(&array);
    bytes.fill(0);
    Ok(STANDARD.encode(key.verifying_key().as_bytes()))
}

#[cfg(test)]
mod tests {
    #[test]
    fn identity_is_stable_and_public_key_valid() {
        use base64::Engine;
        let tmp = tempfile::tempdir().unwrap();
        let cfg = crate::config::Config::new(Some(tmp.path().join("state"))).unwrap();
        let first = super::public_key(&cfg).unwrap();
        assert_eq!(first, super::public_key(&cfg).unwrap());
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(first)
            .unwrap();
        assert!(ed25519_dalek::VerifyingKey::from_bytes(&bytes.try_into().unwrap()).is_ok());
    }
}
