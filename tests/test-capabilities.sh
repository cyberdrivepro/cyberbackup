#!/usr/bin/env bash
# No root, package manager, network, or live cgroup changes are performed.
set -euo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d)"
trap 'rm -rf "$TEST_ROOT"' EXIT
export CYBERVPS_ROOT_VIEW="$TEST_ROOT/root"
export CYBERVPS_PROC_ROOT="$TEST_ROOT/proc"
export CYBERVPS_CGROUP_ROOT="$TEST_ROOT/cgroup"
mkdir -p "$CYBERVPS_ROOT_VIEW" "$CYBERVPS_PROC_ROOT/1" "$CYBERVPS_PROC_ROOT/self" "$CYBERVPS_CGROUP_ROOT"
# shellcheck source=lib/privilege.sh
source "$REPO_DIR/lib/privilege.sh"
# shellcheck source=lib/resources.sh
source "$REPO_DIR/lib/resources.sh"
# shellcheck source=lib/capabilities.sh
source "$REPO_DIR/lib/capabilities.sh"

passed=0
assert_eq() {
    if [ "$1" != "$2" ]; then printf 'FAIL: %s: expected %s; got %s\n' "$3" "$2" "$1"; exit 1; fi
    passed=$((passed+1))
}
# Command mocks remain scoped to this process. The only sudo probe is -n true.
id() { [ "$1" = -u ] && printf '%s\n' "$fixture_uid"; }
sudo() { [ "$*" = '-n true' ] || return 99; [ "$fixture_sudo" = true ]; }
cyber_probe() { "$@"; }
systemctl() { [ "$fixture_systemd" = true ]; }
apt-get() { return 0; }
nproc() { echo 64; }
getconf() { echo 64; }
daytona() { return 1; }
for v in $(compgen -e | grep '^DAYTONA_' 2>/dev/null || true); do unset "$v"; done
unset CYBERROOT_GUEST CYBERROOT_PREFIX container || true
fixture_uid=0 fixture_sudo=false fixture_systemd=false
detect_privilege
assert_eq "$CYBER_PRIVILEGE_MODE" ROOT 'UID 0 on host'
touch "$CYBERVPS_ROOT_VIEW/.dockerenv"
detect_privilege
assert_eq "$CYBER_PRIVILEGE_MODE" CONTAINER_ROOT 'UID 0 in container'
assert_eq "$CYBER_IS_ROOT" true 'root capability in container'
CYBER_DISTRO_ID=debian
printf 'bash\n' > "$CYBERVPS_PROC_ROOT/1/comm"
detect_capabilities
assert_eq "$CYBER_SYSTEM_PACKAGES" AVAILABLE 'root container package access'
assert_eq "$CYBER_SYSTEMD_SYSTEM" false 'installed systemctl without systemd PID1'
fixture_systemd=true
detect_capabilities
assert_eq "$CYBER_SYSTEMD_SYSTEM" false 'PID1 check independent of working user manager'
assert_eq "$CYBER_SYSTEMD_USER" true 'operational user manager'
printf 'systemd\n' > "$CYBERVPS_PROC_ROOT/1/comm"
detect_capabilities
assert_eq "$CYBER_SYSTEMD_SYSTEM" true 'PID1 plus operational manager'
fixture_uid=1000
detect_privilege
assert_eq "$CYBER_PRIVILEGE_MODE" ROOTLESS 'non-root with denied sudo'
fixture_sudo=true
detect_privilege
assert_eq "$CYBER_PRIVILEGE_MODE" SUDO_AUTHORIZED 'preauthorized noninteractive sudo'
fixture_uid=0 CYBERROOT_GUEST=testbox
detect_privilege
assert_eq "$CYBER_PRIVILEGE_MODE" CYBERROOT_GUEST 'virtual guest classification'
assert_eq "$CYBER_CAN_ADMIN" false 'guest cannot authorize host operations'
if cyber_run_privileged true 2>/dev/null; then echo 'FAIL: guest system administration'; exit 1; fi
passed=$((passed+1))

# 755 GiB host, 1 GiB sandbox, nested cgroup and 1.5 CPU quota.
printf 'MemTotal: 791674880 kB\nMemAvailable: 734003200 kB\n' > "$CYBERVPS_PROC_ROOT/meminfo"
printf '0::/sandbox/worker\n' > "$CYBERVPS_PROC_ROOT/self/cgroup"
mkdir -p "$CYBERVPS_CGROUP_ROOT/sandbox/worker"
printf 'cpu memory cpuset\n' > "$CYBERVPS_CGROUP_ROOT/cgroup.controllers"
printf 'max\n' > "$CYBERVPS_CGROUP_ROOT/memory.max"
printf 'max 100000\n' > "$CYBERVPS_CGROUP_ROOT/cpu.max"
printf '1073741824\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/memory.max"
printf '268435456\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/memory.current"
printf '805306368\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/memory.high"
printf '150000 100000\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/cpu.max"
printf '0-3,6,8-9\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/cpuset.cpus.effective"
printf 'max\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/worker/memory.max"
printf 'max 100000\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/worker/cpu.max"
CYBER_HOME="$TEST_ROOT"
detect_resources
assert_eq "$CYBER_RAM_TOTAL_MB" 1024 'ancestor cgroup memory limit'
assert_eq "$CYBER_HOST_RAM_TOTAL_MB" 773120 'host memory separately exposed'
assert_eq "$CYBER_RAM_AVAIL_MB" 768 'available memory bounded by cgroup usage'
assert_eq "$CYBER_RAM_HIGH_BYTES" 805306368 'memory.high remains a separate throttle threshold'
assert_eq "$CYBER_NPROC" 1.50 'fractional quota'
assert_eq "$(_resource_cpuset_count '0-3,6,8-9')" 7 'cpuset ranges'
printf '4\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/worker/cpuset.cpus.effective"
detect_resources
assert_eq "$CYBER_NPROC" 1.00 'cpuset tighter than quota'
# Malformed/unlimited values cannot become effective resources.
printf 'nonsense\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/memory.max"
printf 'max 100000\n' > "$CYBERVPS_CGROUP_ROOT/sandbox/cpu.max"
detect_resources
assert_eq "$CYBER_RAM_TOTAL_MB" 773120 'invalid memory limit falls back to host'

# cgroup v1 memory/cpu/cpuset controllers.
export CYBERVPS_CGROUP_ROOT="$TEST_ROOT/v1"
mkdir -p "$CYBERVPS_CGROUP_ROOT"/{memory,cpu,cpuset}/sandbox
printf '5:memory:/sandbox\n4:cpu,cpuacct:/sandbox\n3:cpuset:/sandbox\n' > "$CYBERVPS_PROC_ROOT/self/cgroup"
printf '536870912\n' > "$CYBERVPS_CGROUP_ROOT/memory/sandbox/memory.limit_in_bytes"
printf '536870912\n' > "$CYBERVPS_CGROUP_ROOT/memory/sandbox/memory.usage_in_bytes"
printf '25000\n' > "$CYBERVPS_CGROUP_ROOT/cpu/sandbox/cpu.cfs_quota_us"
printf '100000\n' > "$CYBERVPS_CGROUP_ROOT/cpu/sandbox/cpu.cfs_period_us"
printf '0-3\n' > "$CYBERVPS_CGROUP_ROOT/cpuset/sandbox/cpuset.cpus"
detect_resources
assert_eq "$CYBER_CGROUP_VERSION" 1 'v1 controller resolution'
assert_eq "$CYBER_RAM_TOTAL_MB" 512 'v1 memory limit'
assert_eq "$CYBER_RAM_AVAIL_MB" 0 'exhausted cgroup memory'
assert_eq "$CYBER_NPROC" 0.25 'v1 fractional CPU quota'
printf '9223372036854771712\n' > "$CYBERVPS_CGROUP_ROOT/memory/sandbox/memory.limit_in_bytes"
printf '%s\n' -1 > "$CYBERVPS_CGROUP_ROOT/cpu/sandbox/cpu.cfs_quota_us"
detect_resources
assert_eq "$CYBER_RAM_TOTAL_MB" 773120 'v1 unlimited sentinel ignored'
assert_eq "$CYBER_NPROC" 4.00 'v1 unlimited quota respects cpuset'
printf 'PASS: %s capability/resource assertions\n' "$passed"
