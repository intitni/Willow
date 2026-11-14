use aes_gcm::{Aes256Gcm, KeyInit, Nonce, aead::{Aead, Payload}};
use serde_json::{Value, json};
use std::{fs::{self, OpenOptions}, io::Write, os::unix::fs::OpenOptionsExt, path::{Path, PathBuf}};

const HEADER: &[u8] = b"WILLOWCFG1";

pub struct ConfigStore {
    root: PathBuf,
    cipher: Aes256Gcm,
}

impl ConfigStore {
    pub fn new(root: &Path, key: &[u8]) -> anyhow::Result<Self> {
        Ok(Self { root: root.to_owned(), cipher: Aes256Gcm::new_from_slice(key)
            .map_err(|_| anyhow::anyhow!("Invalid configuration encryption key"))? })
    }

    pub fn load(&self) -> anyhow::Result<Value> {
        let encrypted = self.root.join("plugin-config.encrypted");
        let legacy = self.root.join("plugin-config.json");
        let value = if encrypted.exists() {
            let bytes = fs::read(encrypted)?;
            if bytes.len() < HEADER.len() + 12 + 16 || !bytes.starts_with(HEADER) {
                anyhow::bail!("Invalid encrypted plugin configuration; original file preserved");
            }
            let nonce = Nonce::from_slice(&bytes[HEADER.len()..HEADER.len() + 12]);
            let plaintext = self.cipher.decrypt(nonce, Payload { msg: &bytes[HEADER.len() + 12..], aad: HEADER })
                .map_err(|_| anyhow::anyhow!("Cannot decrypt plugin configuration; original file preserved"))?;
            serde_json::from_slice(&plaintext)?
        } else if legacy.exists() {
            let value: Value = serde_json::from_slice(&fs::read(&legacy)?)?;
            if !value.is_object() { anyhow::bail!("Plugin configuration must be an object"); }
            self.save(&value)?;
            value
        } else { json!({}) };
        if !value.is_object() { anyhow::bail!("Plugin configuration must be an object"); }
        // Delete plaintext only after successful encryption/decryption. Also clean
        // the old writer's temporary file after an interrupted migration.
        for file in [legacy, self.root.join("plugin-config.tmp")] {
            if file.exists() { fs::remove_file(file)?; }
        }
        Ok(value)
    }

    pub fn save(&self, value: &Value) -> anyhow::Result<()> {
        let mut nonce = [0u8; 12];
        getrandom::getrandom(&mut nonce).map_err(|_| anyhow::anyhow!("Cannot generate encryption nonce"))?;
        let ciphertext = self.cipher.encrypt(Nonce::from_slice(&nonce), Payload {
            msg: &serde_json::to_vec(value)?, aad: HEADER,
        }).map_err(|_| anyhow::anyhow!("Cannot encrypt plugin configuration"))?;
        let temp = self.root.join("plugin-config.encrypted.tmp");
        let mut file = OpenOptions::new().write(true).create(true).truncate(true).mode(0o600).open(&temp)?;
        file.write_all(HEADER)?;
        file.write_all(&nonce)?;
        file.write_all(&ciphertext)?;
        file.sync_all()?;
        fs::rename(temp, self.root.join("plugin-config.encrypted"))?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encryption_migration_and_failure_preservation() {
        let root = std::env::temp_dir().join(format!("willow-crypto-{}", std::process::id()));
        fs::create_dir_all(&root).unwrap();
        let store = ConfigStore::new(&root, &[7; 32]).unwrap();
        let value = json!({"plugin": {"token": "private-token"}});
        fs::write(root.join("plugin-config.json"), value.to_string()).unwrap();
        assert_eq!(store.load().unwrap(), value);
        assert!(!root.join("plugin-config.json").exists());
        let path = root.join("plugin-config.encrypted");
        let first = fs::read(&path).unwrap();
        assert!(!String::from_utf8_lossy(&first).contains("private-token"));
        assert_eq!(store.load().unwrap(), value);
        store.save(&value).unwrap();
        assert_ne!(first, fs::read(&path).unwrap());
        assert!(ConfigStore::new(&root, &[8; 32]).unwrap().load().is_err());
        let mut corrupted = fs::read(&path).unwrap();
        *corrupted.last_mut().unwrap() ^= 1;
        fs::write(&path, &corrupted).unwrap();
        fs::write(root.join("plugin-config.json"), value.to_string()).unwrap();
        assert!(store.load().is_err());
        assert_eq!(fs::read(&path).unwrap(), corrupted);
        assert!(root.join("plugin-config.json").exists());
        fs::remove_dir_all(root).unwrap();
    }
}
