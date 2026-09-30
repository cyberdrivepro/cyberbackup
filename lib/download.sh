#!/usr/bin/env bash
# Verified HTTPS downloads. This library deliberately has no sourcing side effects.
[ -n "${_CYBERVPS_DOWNLOAD_SH_LOADED:-}" ] && return 0
_CYBERVPS_DOWNLOAD_SH_LOADED=1

cyber_download_digest() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | awk '{print $1}'
    elif command -v shasum >/dev/null 2>&1; then
        shasum -a 256 "$1" | awk '{print $1}'
    elif command -v openssl >/dev/null 2>&1; then
        openssl dgst -sha256 "$1" | awk '{print $NF}'
    else
        printf 'Download verification requires sha256sum, shasum or openssl.\n' >&2
        return 7
    fi
}

cyber_download_url_valid() {
    # Never accept credentials in the authority or a TLS downgrade.
    local authority="${1#https://}"
    authority="${authority%%/*}"
    [[ "$1" == https://* && -n "$authority" && "$authority" != *'@'* && "$1" != *$'\n'* && "$1" != *$'\r'* ]]
}

_cyber_download_wget() {
    local url="$1" output="$2" family="$3" headers="$4" rc redirects=0 next
    local -a args=()
    case "$family" in ipv4) args+=(-4) ;; ipv6) args+=(-6) ;; esac
    # Follow redirects ourselves: wget's --https-only does not constrain all redirects.
    while [ "$redirects" -lt 8 ]; do
        cyber_download_url_valid "$url" || return 4
        rc=0
        wget -q --server-response --max-redirect=0 --tries=1 \
            --timeout="${CYBERVPS_DOWNLOAD_TIMEOUT:-60}" \
            --connect-timeout="${CYBERVPS_DOWNLOAD_CONNECT_TIMEOUT:-10}" \
            --user-agent='CyberVPS-Downloader/1' "${args[@]}" -O "$output" "$url" 2>"$headers" || rc=$?
        [ "$rc" -ne 0 ] || return 0
        next="$(awk 'tolower($1)=="location:" {sub(/^[[:space:]]*[Ll]ocation:[[:space:]]*/, ""); sub(/\r$/, ""); sub(/[[:space:]]+\[following\]$/, ""); print; exit}' "$headers")"
        [ -n "$next" ] || return 4
        if [[ "$next" == /* && "$next" != //* ]]; then
            local authority="${url#https://}"
            url="https://${authority%%/*}$next"
        else
            url="$next"
        fi
        redirects=$((redirects + 1))
    done
    return 4
}

# cyber_download URL DEST [SHA256] [TRUSTED_MIRROR_URL ...]
# Mirrors are explicit caller-owned upstream URLs; none are discovered automatically.
# Existing destinations survive all failures. Resume is opt-in and needs a digest.
cyber_download() (
    set -o pipefail
    local url="${1:-}" dest="${2:-}" expected="${3:-}"
    [ "$#" -ge 2 ] && [ -n "$dest" ] || return 2
    shift 2
    [ "$#" -eq 0 ] || shift
    local -a urls=("$url" "$@") clients=() profiles=(auto ipv4 http1 ipv6)
    local retries="${CYBERVPS_DOWNLOAD_RETRIES:-2}" timeout="${CYBERVPS_DOWNLOAD_TIMEOUT:-60}"
    local connect="${CYBERVPS_DOWNLOAD_CONNECT_TIMEOUT:-10}" backoff="${CYBERVPS_DOWNLOAD_BACKOFF:-1}"
    [[ "$retries" =~ ^[1-9][0-9]?$ && "$timeout" =~ ^[1-9][0-9]*$ && "$connect" =~ ^[1-9][0-9]*$ && "$backoff" =~ ^[0-9]+$ ]] || return 2
    [[ -z "$expected" || "$expected" =~ ^[[:xdigit:]]{64}$ ]] || return 2
    expected="${expected,,}"
    for url in "${urls[@]}"; do cyber_download_url_valid "$url" || { printf 'Only credential-free HTTPS download URLs are allowed.\n' >&2; return 2; }; done
    command -v curl >/dev/null 2>&1 && clients+=(curl)
    command -v wget >/dev/null 2>&1 && clients+=(wget)
    [ "${#clients[@]}" -gt 0 ] || { printf 'Download requires curl or wget.\n' >&2; return 7; }
    [ "${CYBERVPS_READ_ONLY:-0}" != 1 ] || return 3
    mkdir -p -- "$(dirname "$dest")" || return 8
    local part headers provenance
    part="$(mktemp "${dest}.part.XXXXXX")" || return 8
    headers="${part}.headers"
    provenance="${part}.source"
    trap 'rm -f -- "$part" "$headers" "$provenance"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    local client profile attempt rc actual delay integrity_failure=0
    for url in "${urls[@]}"; do
        for client in "${clients[@]}"; do
            for profile in "${profiles[@]}"; do
                [ "$client:$profile" != wget:http1 ] || continue
                : > "$part"
                for ((attempt=1; attempt<=retries; attempt++)); do
                    rc=0
                    if [ "$client" = curl ]; then
                        local -a args=()
                        case "$profile" in ipv4) args+=(-4) ;; ipv6) args+=(-6) ;; http1) args+=(--http1.1) ;; esac
                        if [ "$attempt" -gt 1 ] && [ -n "$expected" ] && [ "${CYBERVPS_DOWNLOAD_RESUME:-0}" = 1 ] && [ -s "$part" ]; then args+=(--continue-at -); else : > "$part"; fi
                        curl --fail --silent --show-error --location --proto '=https' --proto-redir '=https' \
                            --connect-timeout "$connect" --max-time "$timeout" --retry 0 \
                            --user-agent 'CyberVPS-Downloader/1' "${args[@]}" --output "$part" "$url" 2>"$headers" || rc=$?
                    else
                        _cyber_download_wget "$url" "$part" "$profile" "$headers" || rc=$?
                    fi
                    if [ "$rc" -eq 0 ] && [ -s "$part" ]; then
                        actual="$(cyber_download_digest "$part")" || return 7
                        if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
                            integrity_failure=1
                            printf 'SHA256 mismatch; rejected downloaded artifact.\n' >&2
                            : > "$part"
                            break
                        fi
                        # Query parameters can contain secrets; exclude them from provenance.
                        printf 'source\t%s\nsha256\t%s\nintegrity\t%s\n' "${url%%\?*}" "$actual" "$([ -n "$expected" ] && printf verified || printf digest-only)" > "$provenance" || return 8
                        mv -f -- "$part" "$dest" || return 8
                        mv -f -- "$provenance" "${dest}.source" || return 8
                        return 0
                    fi
                    if [ "$rc" -eq 22 ] || grep -q -i -E '(404 Not Found|HTTP/[0-9.]+ 404)' "$headers" 2>/dev/null; then
                        log_debug "Resource at $url returned HTTP 404 (Not Found); skipping remaining retries for this URL."
                        break 3
                    fi
                    printf 'Download attempt failed (%s/%s, attempt %s, code %s).\n' "$client" "$profile" "$attempt" "$rc" >&2
                    if [ "$attempt" -lt "$retries" ]; then
                        delay=$((backoff * (1 << (attempt > 5 ? 5 : attempt - 1))))
                        [ "$delay" -le 30 ] || delay=30
                        sleep "$delay"
                    fi
                done
            done
        done
    done
    [ "$integrity_failure" -eq 0 ] || return 9
    return 4
)
