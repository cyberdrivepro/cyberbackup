use serde::Serialize;
use std::{
    collections::BTreeMap,
    env, fs,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant},
};

#[derive(Serialize)]
pub struct Capabilities {
    protocol_version: u32,
    version: &'static str,
    platform: &'static str,
    architecture: &'static str,
    privilege: String,
    container: bool,
    logical_cpu_available: usize,
    cgroup_memory_max_bytes: Option<u64>,
    cgroup_cpu_quota: Option<f64>,
    features: BTreeMap<&'static str, &'static str>,
}

fn sudo_authorized() -> bool {
    let Ok(mut child) = Command::new("sudo")
        .args(["-n", "true"])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
    else {
        return false;
    };
    let started = Instant::now();
    loop {
        match child.try_wait() {
            Ok(Some(status)) => return status.success(),
            Err(_) => {
                let _ = child.kill();
                let _ = child.wait();
                return false;
            }
            _ => {}
        }
        if started.elapsed() >= Duration::from_secs(2) {
            let _ = child.kill();
            let _ = child.wait();
            return false;
        }
        thread::sleep(Duration::from_millis(20));
    }
}

pub fn detect() -> Capabilities {
    let container = cfg!(target_os = "linux")
        && (std::path::Path::new("/.dockerenv").exists()
            || std::path::Path::new("/run/.containerenv").exists()
            || env::var_os("container").is_some()
            || fs::read_to_string("/proc/1/cgroup")
                .map(|s| {
                    ["docker", "kubepods", "containerd", "libpod", "lxc"]
                        .iter()
                        .any(|v| s.contains(v))
                })
                .unwrap_or(false));
    let administrator = crate::platform::administrator();
    let privilege = if cfg!(windows) {
        if administrator {
            "WINDOWS_ADMIN"
        } else {
            "WINDOWS_USER"
        }
    } else if env::var_os("CYBERROOT_GUEST").is_some() || env::var_os("CYBERROOT_PREFIX").is_some()
    {
        "CYBERROOT_GUEST"
    } else if administrator {
        if container {
            "CONTAINER_ROOT"
        } else {
            "ROOT"
        }
    } else if sudo_authorized() {
        "SUDO_AUTHORIZED"
    } else {
        "ROOTLESS"
    };
    let cgroup_memory_max_bytes = fs::read_to_string("/sys/fs/cgroup/memory.max")
        .ok()
        .and_then(|s| s.trim().parse::<u64>().ok())
        .filter(|n| *n > 0 && *n < (1 << 60));
    let cgroup_cpu_quota = fs::read_to_string("/sys/fs/cgroup/cpu.max")
        .ok()
        .and_then(|s| {
            let mut parts = s.split_whitespace();
            let quota: f64 = parts.next()?.parse().ok()?;
            let period: f64 = parts.next()?.parse().ok()?;
            if quota > 0.0 && period > 0.0 {
                Some(quota / period)
            } else {
                None
            }
        });
    let features = BTreeMap::from([
        ("local_argv_execution", "AVAILABLE"),
        ("sqlite_state", "AVAILABLE"),
        ("ed25519_identity", "AVAILABLE"),
        ("one_time_local_pairing", "AVAILABLE"),
        (
            "secret_backend",
            if cfg!(windows) {
                "DPAPI_CURRENT_USER"
            } else {
                "OWNER_ONLY_FILE"
            },
        ),
        ("network_relay", "NOT IMPLEMENTED"),
        ("remote_pty", "NOT IMPLEMENTED"),
        ("conpty", "NOT IMPLEMENTED"),
        ("persistent_scheduler", "NOT IMPLEMENTED"),
        ("process_restart_supervision", "NOT IMPLEMENTED"),
        ("provider_lifecycle", "UNKNOWN"),
        ("disk_persistence", "UNKNOWN"),
        (
            "cgroup_scope",
            "ROOT_MOUNT_ONLY; use shell doctor for nested/v1 effective limits",
        ),
        (
            "timeout_scope",
            if cfg!(unix) {
                "CHILD_PROCESS_GROUP"
            } else {
                "DIRECT_CHILD_HANDLE"
            },
        ),
    ]);
    Capabilities {
        protocol_version: 1,
        version: env!("CARGO_PKG_VERSION"),
        platform: env::consts::OS,
        architecture: env::consts::ARCH,
        privilege: privilege.to_owned(),
        container,
        logical_cpu_available: thread::available_parallelism()
            .map(usize::from)
            .unwrap_or(1),
        cgroup_memory_max_bytes,
        cgroup_cpu_quota,
        features,
    }
}
