#!/usr/bin/env bash
# CLI contracts: read-only planning, validation and unattended safety.
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
export HOME="$TEST_TMP/home"
mkdir -p "$HOME"
export CYBERVPS_READ_ONLY=1
passed=0
check() { if "$@"; then passed=$((passed + 1)); else printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
help="$(bash "$REPO_DIR/fresh-install.sh" --help)"
check grep -q -- '--mode MODE' <<< "$help"
check grep -q -- '--verify' <<< "$help"
plan="$(bash "$REPO_DIR/fresh-install.sh" --dry-run </dev/null)"
check grep -q 'Selected profile: hosting' <<< "$plan"
check grep -q 'Install mode:' <<< "$plan"
check test -z "$(find "$HOME" -mindepth 1 -print -quit)"
plan="$(bash "$REPO_DIR/fresh-install.sh" --profile developer --mode rootless --dry-run)"
check grep -q 'Install mode: rootless' <<< "$plan"
check grep -q 'rust' <<< "$plan"
for args in '--profile' '--mode' '--mode invalid --dry-run' '--profile nonsense --dry-run' '--components bad --profile custom --dry-run'; do
    rc=0
    # Deliberate fixture word splitting for fixed argument cases, no external input.
    # shellcheck disable=SC2086
    bash "$REPO_DIR/fresh-install.sh" $args >/dev/null 2>&1 || rc=$?
    check test "$rc" -eq 2
done
back="$(printf 'B\n' | CYBERVPS_INTERACTIVE=1 bash "$REPO_DIR/fresh-install.sh" 2>&1)"
check grep -q 'Returned to dashboard' <<< "$back"
cancel="$(printf '1\n1\nn\n' | CYBERVPS_INTERACTIVE=1 bash "$REPO_DIR/fresh-install.sh" 2>&1)"
check grep -q 'Selected profile: minimal' <<< "$cancel"
check grep -q 'Installation cancelled' <<< "$cancel"
rc=0
bash "$REPO_DIR/fresh-install.sh" --profile minimal --mode rootless </dev/null >/dev/null 2>&1 || rc=$?
check test "$rc" -eq 2
check test -z "$(find "$HOME" -mindepth 1 -print -quit)"
printf 'Fresh install CLI: %s passed, 0 failed.\n' "$passed"
