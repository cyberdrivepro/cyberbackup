use anyhow::Result;
use std::{fs, path::Path};

#[cfg(windows)]
mod windows;

pub fn private_directory(path: &Path) -> Result<()> {
    crate::config::reject_symlink(path)?;
    fs::create_dir_all(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        anyhow::ensure!(
            fs::metadata(path)?.uid() == unsafe { libc::geteuid() },
            "State directory is owned by another user"
        );
        fs::set_permissions(path, fs::Permissions::from_mode(0o700))?;
    }
    #[cfg(windows)]
    windows::owner_only(path, true)?;
    Ok(())
}

pub fn private_file(path: &Path) -> Result<()> {
    crate::config::reject_symlink(path)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::{MetadataExt, PermissionsExt};
        anyhow::ensure!(
            fs::metadata(path)?.uid() == unsafe { libc::geteuid() },
            "State file is owned by another user"
        );
        fs::set_permissions(path, fs::Permissions::from_mode(0o600))?;
    }
    #[cfg(windows)]
    windows::owner_only(path, false)?;
    Ok(())
}

pub fn protect(bytes: &[u8]) -> Result<Vec<u8>> {
    #[cfg(windows)]
    return windows::protect(bytes);
    #[cfg(not(windows))]
    Ok(bytes.to_vec())
}

pub fn unprotect(bytes: &[u8]) -> Result<Vec<u8>> {
    #[cfg(windows)]
    return windows::unprotect(bytes);
    #[cfg(not(windows))]
    Ok(bytes.to_vec())
}

pub fn administrator() -> bool {
    #[cfg(windows)]
    return windows::administrator();
    #[cfg(unix)]
    return unsafe { libc::geteuid() == 0 };
    #[cfg(not(any(windows, unix)))]
    false
}
