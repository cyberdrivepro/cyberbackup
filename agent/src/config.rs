use anyhow::{bail, Context, Result};
use std::{env, fs, path::PathBuf};

pub struct Config {
    pub state: PathBuf,
    pub secrets: PathBuf,
}

impl Config {
    pub fn new(state: Option<PathBuf>) -> Result<Self> {
        let state = state
            .or_else(|| {
                if cfg!(windows) {
                    env::var_os("LOCALAPPDATA").map(|p| PathBuf::from(p).join("CyberVPS/agent"))
                } else {
                    env::var_os("XDG_STATE_HOME")
                        .map(PathBuf::from)
                        .or_else(|| {
                            env::var_os("HOME").map(|p| PathBuf::from(p).join(".local/state"))
                        })
                        .map(|p| p.join("cybervps/agent"))
                }
            })
            .context("No current-user state directory; pass --state-dir")?;
        let secrets = state.join("secrets");
        crate::platform::private_directory(&state)?;
        crate::platform::private_directory(&secrets)?;
        Ok(Self { state, secrets })
    }
}

pub fn validate_name(name: &str) -> Result<()> {
    if name.is_empty()
        || name.len() > 80
        || !name
            .bytes()
            .all(|c| c.is_ascii_alphanumeric() || b"_-".contains(&c))
    {
        bail!("Name must contain 1-80 ASCII letters, digits, underscores, or hyphens");
    }
    Ok(())
}

pub fn reject_symlink(path: &std::path::Path) -> Result<()> {
    match fs::symlink_metadata(path) {
        Ok(meta) if meta.file_type().is_symlink() => bail!("Symlink state paths are not supported"),
        Ok(_) => Ok(()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error.into()),
    }
}
