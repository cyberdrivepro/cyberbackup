# Privilege, capabilities, and resources

`lib/detect.sh` is the canonical environment entry point. It composes `privilege.sh`, `resources.sh`, and `capabilities.sh`. The dashboard, preflight, and installers consume this model.

## Privilege

UID 0 is ROOT, or CONTAINER_ROOT when container evidence is present. A nonzero UID becomes SUDO_AUTHORIZED only when `sudo -n true` succeeds. Otherwise it is ROOTLESS. CyberRoot guest markers produce CYBERROOT_GUEST and never authorize host operations. `cyber_run_privileged` checks authority again before running an argv command; no passwords are requested or piped to sudo.

Container detection is separate from privilege. Container root may use its system package manager while lacking systemd, kernel modules, or host-root authority. Package capability means the distribution manager is installed and legitimate administration is available; an actual package operation may still fail because of policy, a read-only filesystem, locks, or network restrictions.

The Bash control plane reports the kernel/platform and does not claim native Windows administrator detection. Native Windows functionality belongs to CyberAgent.

## Operational capabilities

System systemd requires PID 1 to be systemd and a successful bounded manager query. User systemd requires a successful user-manager query. A `service` executable is reported as installed, not as proof a particular service works. Docker CLI and reachable daemon are distinct. QEMU installation and writable `/dev/kvm` are distinct; KVM_CANDIDATE requires a launch-time virtualization probe before accelerated execution is claimed. Public inbound access, nested virtualization, provider lifecycle, and persistent-volume durability remain UNKNOWN without evidence.

`cyber_feature_status NAME` reports AVAILABLE, PARTIAL, UNAVAILABLE, NOT INSTALLED, or UNKNOWN. Supported names include system-packages, systemd-system, systemd-user, docker, vm, desktop, and cyberroot.

## Effective resources

CPU and memory retain separate host-visible and effective fields. Detection resolves the current process cgroup via `/proc/self/cgroup` and `/proc/self/mountinfo`, checks nested ancestors, and supports cgroup v2 and v1 memory/cpu/cpuset controllers. Effective CPU is the minimum of process affinity, visible CPUs, quota/period, and cpuset. Fractional vCPUs are retained.

Effective RAM is bounded by sane numeric hard limits and host-visible memory. Available RAM is bounded by hard-limit minus cgroup usage, clamped at zero. `memory.high` is a throttle threshold, reported separately rather than treated as a hard cap. Unlimited and malformed values are ignored. Limits hidden by a provider's cgroup namespace cannot be inferred.

Disk availability is measured for the writable HOME directory only. Mount topology records overlay, bind/subtree, and read-only/writable options. Backing capacities of bind-mounted individual files are not added to user storage. Persistence is not inferred from mount type.

## Network diagnostics

`detect_network` explicitly probes GitHub, the distribution endpoint, and a configurable HTTPS endpoint; nothing runs automatically when sourcing `network.sh`. It checks DNS plus IPv4 and IPv6 HTTPS independently, with finite timeouts and TLS verification. It reports per-endpoint results and PARTIAL for mixed results. Failed DNS is DNS_FAILURE, not a claim that all connectivity is absent. Proxy values are never printed; address-family probes can reflect the proxy's transport.

Read-only/dry-run mode (`CYBERVPS_READ_ONLY=1`) skips probes. `CYBERVPS_NETWORK_NEUTRAL_URL` may override the neutral HTTPS endpoint.

## Tests and compatibility

`tests/test-capabilities.sh` exercises root, container root, rootless, authorized sudo, CyberRoot guest isolation, operational init detection, nested v2 limits, v1 limits, unlimited sentinels, cpuset, and fractional quotas. `tests/test-network.sh` uses isolated command fixtures for degraded connectivity and read-only behavior.

Compatibility fields `CYBER_NPROC`, `CYBER_RAM_TOTAL_MB`, and `CYBER_RAM_AVAIL_MB` now mean effective resources. New `CYBER_HOST_NPROC` and `CYBER_HOST_RAM_TOTAL_MB` preserve host-visible figures. Fixture roots (`CYBERVPS_PROC_ROOT`, `CYBERVPS_CGROUP_ROOT`, `CYBERVPS_ROOT_VIEW`) exist for tests; they cannot manufacture UID 0 or authorized sudo.
