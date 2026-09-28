use anyhow::{bail, Context, Result};
use std::{
    path::Path,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

pub struct Outcome {
    pub code: i32,
    pub timed_out: bool,
}

pub fn execute(
    argv: &[String],
    cwd: Option<&Path>,
    timeout_seconds: u64,
    extra_env: &[String],
) -> Result<Outcome> {
    if argv.is_empty() || argv[0].is_empty() {
        bail!("An executable is required");
    }
    if !(1..=86400).contains(&timeout_seconds) {
        bail!("Timeout must be 1-86400 seconds");
    }
    let mut command = Command::new(&argv[0]);
    command
        .args(&argv[1..])
        .env_clear()
        .stdin(Stdio::inherit())
        .stdout(Stdio::inherit())
        .stderr(Stdio::inherit());
    for name in [
        "PATH",
        "HOME",
        "USERPROFILE",
        "SYSTEMROOT",
        "WINDIR",
        "TEMP",
        "TMP",
        "LANG",
        "LC_ALL",
    ]
    .into_iter()
    .chain(extra_env.iter().map(String::as_str))
    {
        if name.is_empty() || name.contains('=') || name.contains('\0') {
            bail!("Invalid environment variable name");
        }
        if let Some(value) = std::env::var_os(name) {
            command.env(name, value);
        }
    }
    if let Some(cwd) = cwd {
        command.current_dir(cwd.canonicalize().context("Resolve working directory")?);
    }
    #[cfg(unix)]
    {
        use std::os::unix::process::CommandExt;
        command.process_group(0);
    }
    let mut child = command.spawn().context("Start requested executable")?;
    let started = Instant::now();
    loop {
        if let Some(status) = child.try_wait()? {
            return Ok(Outcome {
                code: status.code().unwrap_or(1),
                timed_out: false,
            });
        }
        if started.elapsed() >= Duration::from_secs(timeout_seconds) {
            #[cfg(unix)]
            unsafe {
                // The child has its own process group and has not been reaped.
                // Its PID cannot be reused while retained as this Child handle.
                libc::kill(-(child.id() as i32), libc::SIGKILL);
            }
            // Windows uses a process handle, never a broad name/PID kill command.
            match child.kill() {
                Ok(()) => {}
                Err(error) if child.try_wait()?.is_some() => {
                    let _ = error;
                }
                Err(error) => return Err(error).context("Terminate timed-out child"),
            }
            child.wait()?;
            return Ok(Outcome {
                code: 124,
                timed_out: true,
            });
        }
        thread::sleep(Duration::from_millis(25));
    }
}

#[cfg(test)]
mod tests {
    #[test]
    fn explicit_exit_code_is_preserved() {
        let argv: Vec<String> = if cfg!(windows) {
            vec!["cmd.exe", "/d", "/c", "exit", "7"]
        } else {
            vec!["/bin/sh", "-c", "exit 7"]
        }
        .into_iter()
        .map(String::from)
        .collect();
        let outcome = super::execute(&argv, None, 5, &[]).unwrap();
        assert_eq!(outcome.code, 7);
        assert!(!outcome.timed_out);
    }

    #[test]
    fn timeout_is_enforced() {
        let argv: Vec<String> = if cfg!(windows) {
            vec![
                "powershell.exe",
                "-NoProfile",
                "-NonInteractive",
                "-Command",
                "Start-Sleep -Seconds 10",
            ]
        } else {
            vec!["/bin/sh", "-c", "sleep 10"]
        }
        .into_iter()
        .map(String::from)
        .collect();
        let start = std::time::Instant::now();
        let outcome = super::execute(&argv, None, 1, &[]).unwrap();
        assert!(outcome.timed_out);
        assert_eq!(outcome.code, 124);
        assert!(start.elapsed() < std::time::Duration::from_secs(5));
    }
}
