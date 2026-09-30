#!/usr/bin/env bash
# No package operations or network: all effectful boundaries are fixtures.
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home" CYBERVPS_READ_ONLY=1
mkdir -p "$HOME"
# shellcheck source=lib/install.sh
source "$REPO_DIR/lib/install.sh"
passed=0
check() { if "$@"; then passed=$((passed + 1)); else printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
detect_environment() { :; }
CYBER_SYSTEM_PACKAGES=AVAILABLE CYBER_IS_CONTAINER=true CYBER_PACKAGE_MANAGER=apt-get
install_resolve_mode auto
check test "$CYBERVPS_INSTALL_MODE" = hybrid
CYBER_IS_CONTAINER=false
install_resolve_mode auto
check test "$CYBERVPS_INSTALL_MODE" = root
CYBER_SYSTEM_PACKAGES=UNAVAILABLE
install_resolve_mode auto
check test "$CYBERVPS_INSTALL_MODE" = rootless
rc=0; install_resolve_mode root >/dev/null 2>&1 || rc=$?
check test "$rc" -eq 3
cyber_can_admin() { return 0; }
cyber_run_privileged() { printf '%s\n' "$*" >> "$TEST_TMP/packages"; }
CYBERVPS_INSTALL_MODE=rootless
rc=0; install_system_component python || rc=$?
check test "$rc" -eq 3
check test ! -e "$TEST_TMP/packages"
CYBER_SYSTEM_PACKAGES=AVAILABLE
CYBERVPS_INSTALL_MODE=root
for manager in apt-get dnf yum apk pacman zypper; do
    CYBER_PACKAGE_MANAGER="$manager"
    install_system_component python
    check grep -q "$manager" "$TEST_TMP/packages"
done
check grep -q 'python3-venv' "$TEST_TMP/packages"
check grep -q 'py3-pip' "$TEST_TMP/packages"
check grep -q 'python-pip' "$TEST_TMP/packages"
check test "$(grep -c ' update$' "$TEST_TMP/packages")" -eq 1
install_system_component python
check test "$(grep -c ' update$' "$TEST_TMP/packages")" -eq 1
printf '#!/usr/bin/env bash\nprintf noexec-ok\n' > "$TEST_TMP/readable.sh"
chmod 0644 "$TEST_TMP/readable.sh"
check test "$(install_run_script "$TEST_TMP/readable.sh")" = noexec-ok
(
    install_component_ready() { return 0; }
    install_micromamba() { touch "$TEST_TMP/unexpected-micromamba"; return 8; }
    install_component python
    install_component node
)
check test ! -e "$TEST_TMP/unexpected-micromamba"
(
    unset CYBERVPS_READ_ONLY
    install_component() { printf '%s\n' "$1" >> "$TEST_TMP/components"; [ "$1" != cloudflared ]; }
    install_run_script() { install_component "$(basename "$1" .sh)"; }
    rc=0; install_profile full > "$TEST_TMP/report" || rc=$?
    [ "$rc" -eq 10 ]
)
check grep -q 'FAIL_OPTIONAL cloudflared' "$TEST_TMP/report"
check grep -q 'PASS ttyd' "$TEST_TMP/report"
check test -s "$HOME/.local/state/cybervps/install/latest.tsv"
(
    install_component() { printf '%s\n' "$1" >> "$TEST_TMP/required-components"; [ "$1" != python ]; }
    install_run_script() { install_component "$(basename "$1" .sh)"; }
    rc=0; install_profile hosting > "$TEST_TMP/required-report" || rc=$?
    [ "$rc" -eq 7 ]
)
check grep -q 'FAIL_REQUIRED python' "$TEST_TMP/required-report"
check grep -q 'cloudflared' "$TEST_TMP/required-components"
# Regression: primary reset -> official GitHub binary, verified before execution.
(
    unset CYBERVPS_READ_ONLY
    CYBER_LIBC=glibc CYBER_MAMBA_ARCH=linux-64
    install_component_ready() { return 1; }
    printf '#!/usr/bin/env bash\nprintf "2.0-fixture\\n"\n' > "$TEST_TMP/mamba-fixture"
    mamba_expected_hash="$(cyber_download_digest "$TEST_TMP/mamba-fixture")"
    cyber_download() {
        printf '%s\n' "$1" >> "$TEST_TMP/mamba-urls"
        case "$1" in
            *micro.mamba.pm*) return 4 ;;
            *.sha256) printf '%s\n' "$mamba_expected_hash" > "$2" ;;
            https://github.com/mamba-org/micromamba-releases/*)
                cp "$TEST_TMP/mamba-fixture" "$2"
                verify_sha256 "$2" "$3" || return 9
                printf 'verified fixture\n' > "$2.source" ;;
            *) return 4 ;;
        esac
    }
    install_micromamba
)
check test -x "$HOME/bin/micromamba"
check grep -q 'micro.mamba.pm' "$TEST_TMP/mamba-urls"
check grep -q 'github.com/mamba-org/micromamba-releases' "$TEST_TMP/mamba-urls"
printf 'Installer engine: %s passed, 0 failed.\n' "$passed"
