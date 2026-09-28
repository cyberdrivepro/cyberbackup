#!/usr/bin/env bash
set -euo pipefail
REPO_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
source "$REPO_DIR/lib/cyberroot.sh"
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
export HOME=$fixture/home
mkdir -p "$HOME" "$fixture/bin"
export CYBERROOT_BIN=$fixture/bin/cyberroot
if cyberroot_cli list >"$fixture/out" 2>&1; then echo 'missing optional runtime unexpectedly succeeded' >&2; exit 1; else [[ $? == 3 ]]; fi
cat >"$CYBERROOT_BIN" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    --version) echo 'cyberroot 0.1.1' ;;
    api-version) echo "${MOCK_API:-1}" ;;
    exec) printf '%s\n' "$@" > "$MOCK_ARGS"; exit 17 ;;
    list) echo '{"api_version":1,"guests":[]}' ;;
    *) exit 2 ;;
esac
MOCK
chmod +x "$CYBERROOT_BIN"
cyberroot_cli list >"$fixture/out"
export MOCK_API=2
if cyberroot_cli list >"$fixture/out" 2>&1; then exit 1; else [[ $? == 3 ]]; fi
export MOCK_API=1 MOCK_ARGS=$fixture/args
if cyberroot_cli exec demo -- printf '%s' 'two words' >"$fixture/out" 2>&1; then exit 1; else [[ $? == 17 ]]; fi
[[ $(tail -n 1 "$MOCK_ARGS") == 'two words' ]]
if cyberroot_cli start demo >"$fixture/out" 2>&1; then exit 1; else [[ $? == 3 ]]; fi
if cyberroot_install_release '' '' >"$fixture/out" 2>&1; then exit 1; else [[ $? == 6 ]]; fi
printf 'PASS: CyberRoot optional absence, API mismatch, argv and exit propagation, unsupported start, release pins\n'
