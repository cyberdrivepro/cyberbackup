#!/usr/bin/env bash
# Deterministic transfer fixtures; no actual network traffic.
set -Eeuo pipefail
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_TMP="$(mktemp -d)"
trap 'rm -rf "$TEST_TMP"' EXIT
# shellcheck source=lib/download.sh
source "$REPO_DIR/lib/download.sh"
export CYBERVPS_DOWNLOAD_RETRIES=1 CYBERVPS_DOWNLOAD_BACKOFF=0
unset CYBERVPS_READ_ONLY
passed=0
check() { if "$@"; then passed=$((passed + 1)); else printf 'FAIL: %s\n' "$*" >&2; exit 1; fi; }
printf 'verified payload\n' > "$TEST_TMP/payload"
expected="$(cyber_download_digest "$TEST_TMP/payload")"
fixture_mode=mirror
curl() {
    printf '%s\n' "$*" >> "$TEST_TMP/curl-args"
    local output='' url='' argument
    while [ "$#" -gt 0 ]; do
        argument="$1"; shift
        case "$argument" in --output) output="$1"; shift ;; https://*) url="$argument" ;; esac
    done
    case "$fixture_mode" in
        mirror) [[ "$url" == https://good.example/* ]] || return 56 ;;
        mismatch) printf corrupted > "$output"; return 0 ;;
        wget|downgrade) return 56 ;;
        ipv4) [[ "$(tail -1 "$TEST_TMP/curl-args")" == *' -4 '* ]] || return 56 ;;
    esac
    cp "$TEST_TMP/payload" "$output"
}
wget() {
    local output='' argument
    printf '%s\n' "$*" >> "$TEST_TMP/wget-args"
    while [ "$#" -gt 0 ]; do
        argument="$1"; shift
        case "$argument" in -O) output="$1"; shift ;; esac
    done
    if [ "$fixture_mode" = downgrade ]; then printf '  Location: http://insecure.example/artifact\n' >&2; return 8; fi
    [ "$fixture_mode" = wget ] || return 4
    cp "$TEST_TMP/payload" "$output"
}
cyber_download https://bad.example/artifact "$TEST_TMP/result" "$expected" https://good.example/artifact 2>"$TEST_TMP/errors"
check cmp -s "$TEST_TMP/payload" "$TEST_TMP/result"
check grep -q 'source.*https://good.example/artifact' "$TEST_TMP/result.source"
check grep -q -- '--proto =https --proto-redir =https' "$TEST_TMP/curl-args"
check test -z "$(find "$TEST_TMP" -name '*.part.*' -print -quit)"
fixture_mode=mismatch
rc=0; cyber_download https://good.example/artifact "$TEST_TMP/result" "$expected" 2>/dev/null || rc=$?
check test "$rc" -eq 9
check cmp -s "$TEST_TMP/payload" "$TEST_TMP/result"
check test -z "$(find "$TEST_TMP" -name '*.part.*' -print -quit)"
fixture_mode=wget
cyber_download https://good.example/artifact "$TEST_TMP/wget-result" "$expected" 2>/dev/null
check cmp -s "$TEST_TMP/payload" "$TEST_TMP/wget-result"
fixture_mode=ipv4
cyber_download https://good.example/artifact "$TEST_TMP/v4-result" "$expected" 2>/dev/null
check cmp -s "$TEST_TMP/payload" "$TEST_TMP/v4-result"
fixture_mode=downgrade
rc=0; cyber_download https://good.example/artifact "$TEST_TMP/insecure" "$expected" 2>/dev/null || rc=$?
check test "$rc" -eq 4
check test ! -e "$TEST_TMP/insecure"
for url in http://bad.example/artifact https://user:secret@bad.example/file; do
    rc=0; cyber_download "$url" "$TEST_TMP/rejected" 2>/dev/null || rc=$?
    check test "$rc" -eq 2
done
rc=0; cyber_download https://good.example/artifact "$TEST_TMP/rejected" invalid 2>/dev/null || rc=$?
check test "$rc" -eq 2
printf 'Downloader: %s passed, 0 failed.\n' "$passed"
