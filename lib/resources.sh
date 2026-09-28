#!/usr/bin/env bash
# Effective cgroup limits, host-visible resources, and selected writable mount.
[ -n "${_CYBERVPS_RESOURCES_SH_LOADED:-}" ] && return 0
_CYBERVPS_RESOURCES_SH_LOADED=1

_resource_positive_number() { [[ "${1:-}" =~ ^[0-9]+([.][0-9]+)?$ ]] && awk -v n="$1" 'BEGIN {exit !(n>0)}'; }
_resource_min() { awk -v a="$1" -v b="$2" 'BEGIN {n=(a<b?a:b); if(n>0 && n<0.01) printf "%.6f", n; else printf "%.2f", n}'; }

_resource_cpuset_count() {
    awk -v value="$1" 'BEGIN {
        n=split(value, parts, ","); count=0;
        for(i=1;i<=n;i++) {
            if(parts[i] !~ /^[0-9]+(-[0-9]+)?$/) exit 1;
            split(parts[i], r, "-");
            if(r[2] != "" && r[2]<r[1]) exit 1;
            count+=(r[2]=="" ? 1 : r[2]-r[1]+1);
        }
        if(count>0) print count; else exit 1;
    }'
}

# Resolve /proc/self/cgroup through mountinfo, including non-root cgroup mounts.
_resource_cgroup_dir() {
    local controller="$1" proc="${CYBERVPS_PROC_ROOT:-/proc}"
    local sys="${CYBERVPS_CGROUP_ROOT:-/sys/fs/cgroup}" group mount_root mount_path
    group="$(awk -F: -v c="$controller" '(c=="v2" && $1=="0") || (c!="v2" && (","$2",") ~ (","c",")) {print $3; exit}' "$proc/self/cgroup" 2>/dev/null)" || group=''
    [[ "$group" = /* && "$group" != *'/../'* && "$group" != */.. ]] || group=/
    if [ -n "${CYBERVPS_CGROUP_ROOT:-}" ]; then
        mount_path="$sys"
        [ "$controller" != v2 ] && mount_path="$sys/$controller"
        [ -d "$mount_path$group" ] && mount_path="$mount_path$group"
        printf '%s\n' "${mount_path%/}"
        return
    fi
    local record
    record="$(awk -v c="$controller" '{for(i=7;i<=NF;i++) if($i=="-") {
        if((c=="v2" && $(i+1)=="cgroup2") || (c!="v2" && $(i+1)=="cgroup" && (","$(i+3)",") ~ (","c","))) {print $4, $5; exit}
    }}' "$proc/self/mountinfo" 2>/dev/null)" || record=''
    read -r mount_root mount_path <<< "$record"
    if [ -n "$mount_path" ]; then
        mount_path="${mount_path//\\040/ }"
        if [ "$mount_root" = / ]; then
            mount_path="$mount_path$group"
        elif [[ "$group" = "$mount_root"* ]]; then
            mount_path="$mount_path${group#"$mount_root"}"
        fi
    else
        mount_path="$sys"
        [ "$controller" != v2 ] && mount_path="$sys/$controller"
        [ -d "$mount_path$group" ] && mount_path="$mount_path$group"
    fi
    printf '%s\n' "${mount_path%/}"
}

_resource_read() { [ -r "$1" ] && head -n 1 "$1" 2>/dev/null; }

_resource_memory_limit() {
    local limit="$1" current="${2:-}" available
    if _resource_positive_number "$limit" && awk -v n="$limit" 'BEGIN {exit !(n < 1152921504606846976)}'; then
        if [ "$CYBER_RAM_TOTAL_BYTES" = unknown ] || awk -v a="$limit" -v b="$CYBER_RAM_TOTAL_BYTES" 'BEGIN {exit !(a<b)}'; then
            CYBER_RAM_TOTAL_BYTES="$limit"
            CYBER_RESOURCE_SOURCE=cgroup
        fi
        if [[ "$current" =~ ^[0-9]+$ ]]; then
            available="$(awk -v l="$limit" -v c="$current" 'BEGIN {printf "%.0f", (l>c?l-c:0)}')"
            if [ "$CYBER_RAM_AVAIL_BYTES" = unknown ] || awk -v a="$available" -v b="$CYBER_RAM_AVAIL_BYTES" 'BEGIN {exit !(a<b)}'; then
                CYBER_RAM_AVAIL_BYTES="$available"
            fi
        fi
    fi
    return 0
}

_resource_walk_limits() {
    local dir="$1" kind="$2" limit current quota period cpus high
    # Stop at the cgroup mount, or the explicit fixture root. Never inspect host ancestors.
    while [ -d "$dir" ]; do
        case "$kind" in
            v2)
                limit="$(_resource_read "$dir/memory.max" || true)"
                current="$(_resource_read "$dir/memory.current" || true)"
                _resource_memory_limit "$limit" "$current"
                high="$(_resource_read "$dir/memory.high" || true)"
                if _resource_positive_number "$high"; then
                    if [ "$CYBER_RAM_HIGH_BYTES" = unknown ] || awk -v a="$high" -v b="$CYBER_RAM_HIGH_BYTES" 'BEGIN {exit !(a<b)}'; then CYBER_RAM_HIGH_BYTES="$high"; fi
                fi
                read -r quota period <<< "$(_resource_read "$dir/cpu.max" || true)"
                cpus="$(_resource_read "$dir/cpuset.cpus.effective" || true)"
                ;;
            memory)
                limit="$(_resource_read "$dir/memory.limit_in_bytes" || true)"
                current="$(_resource_read "$dir/memory.usage_in_bytes" || true)"
                _resource_memory_limit "$limit" "$current"
                quota='' period='' cpus=''
                ;;
            cpu)
                quota="$(_resource_read "$dir/cpu.cfs_quota_us" || true)"
                period="$(_resource_read "$dir/cpu.cfs_period_us" || true)"
                cpus=''
                ;;
            cpuset)
                cpus="$(_resource_read "$dir/cpuset.cpus" || true)"
                quota='' period=''
                ;;
        esac
        if _resource_positive_number "$quota" && _resource_positive_number "$period"; then
            CYBER_NPROC="$(_resource_min "$CYBER_NPROC" "$(awk -v q="$quota" -v p="$period" 'BEGIN {printf "%.6f", q/p}')")"
            CYBER_RESOURCE_SOURCE=cgroup
        fi
        if [ -n "$cpus" ] && cpus="$(_resource_cpuset_count "$cpus")"; then
            CYBER_NPROC="$(_resource_min "$CYBER_NPROC" "$cpus")"
        fi
        [ "$dir" = "${CYBERVPS_CGROUP_ROOT:-/sys/fs/cgroup}" ] && break
        # A parent lacking this controller is outside its hierarchy.
        dir="${dir%/*}"
        case "$kind" in
            v2) [ -f "$dir/cgroup.controllers" ] || [ -f "$dir/memory.max" ] || [ -f "$dir/cpu.max" ] || break ;;
            memory) [ -f "$dir/memory.limit_in_bytes" ] || break ;;
            cpu) [ -f "$dir/cpu.cfs_quota_us" ] || break ;;
            cpuset) [ -f "$dir/cpuset.cpus" ] || break ;;
        esac
    done
    return 0
}

detect_resources() {
    local proc="${CYBERVPS_PROC_ROOT:-/proc}" mem avail dir
    CYBER_HOST_NPROC="$(getconf _NPROCESSORS_ONLN 2>/dev/null || printf 1)"
    _resource_positive_number "$CYBER_HOST_NPROC" || CYBER_HOST_NPROC=1
    if [ -r "$proc/cpuinfo" ]; then
        local visible
        visible="$(grep -c '^processor' "$proc/cpuinfo" || true)"
        _resource_positive_number "$visible" && CYBER_HOST_NPROC="$visible"
    fi
    CYBER_NPROC="$(nproc 2>/dev/null || printf '%s' "$CYBER_HOST_NPROC")"
    _resource_positive_number "$CYBER_NPROC" || CYBER_NPROC="$CYBER_HOST_NPROC"
    CYBER_NPROC="$(_resource_min "$CYBER_NPROC" "$CYBER_HOST_NPROC")"
    CYBER_RESOURCE_SOURCE=host-visible
    CYBER_CGROUP_VERSION=none
    CYBER_RAM_TOTAL_BYTES=unknown CYBER_RAM_AVAIL_BYTES=unknown CYBER_RAM_HIGH_BYTES=unknown
    CYBER_HOST_RAM_TOTAL_MB=unknown
    if [ -r "$proc/meminfo" ]; then
        mem="$(awk '/^MemTotal:/ {printf "%.0f", $2*1024}' "$proc/meminfo")"
        avail="$(awk '/^MemAvailable:/ {printf "%.0f", $2*1024}' "$proc/meminfo")"
        if _resource_positive_number "$mem"; then
            CYBER_RAM_TOTAL_BYTES="$mem"
            CYBER_HOST_RAM_TOTAL_MB="$(awk -v n="$mem" 'BEGIN {printf "%.0f", int(n/1048576)}')"
        fi
        [[ "$avail" =~ ^[0-9]+$ ]] && CYBER_RAM_AVAIL_BYTES="$avail"
    fi
    dir="$(_resource_cgroup_dir v2)"
    if [ -f "$dir/cgroup.controllers" ] || [ -f "$dir/memory.max" ] || [ -f "$dir/cpu.max" ]; then
        CYBER_CGROUP_VERSION=2
        _resource_walk_limits "$dir" v2
    else
        local controller
        for controller in memory cpu cpuset; do
            dir="$(_resource_cgroup_dir "$controller")"
            if [ -d "$dir" ]; then
                CYBER_CGROUP_VERSION=1
                _resource_walk_limits "$dir" "$controller"
            fi
        done
    fi
    if [ "$CYBER_RAM_TOTAL_BYTES" != unknown ]; then
        if [ "$CYBER_RAM_AVAIL_BYTES" != unknown ]; then
            CYBER_RAM_AVAIL_BYTES="$(_resource_min "$CYBER_RAM_TOTAL_BYTES" "$CYBER_RAM_AVAIL_BYTES")"
        fi
        CYBER_RAM_TOTAL_MB="$(awk -v n="$CYBER_RAM_TOTAL_BYTES" 'BEGIN {printf "%.0f", int(n/1048576)}')"
    else CYBER_RAM_TOTAL_MB=unknown; fi
    if [ "$CYBER_RAM_AVAIL_BYTES" != unknown ]; then
        CYBER_RAM_AVAIL_MB="$(awk -v n="$CYBER_RAM_AVAIL_BYTES" 'BEGIN {printf "%.0f", int(n/1048576)}')"
    else CYBER_RAM_AVAIL_MB=unknown; fi
    detect_disk_resources
}

detect_disk_resources() {
    local target="${CYBER_HOME:-$HOME}" proc="${CYBERVPS_PROC_ROOT:-/proc}"
    CYBER_DISK_FREE_MB=unknown CYBER_DISK_WRITABLE=false CYBER_DISK_FSTYPE=unknown
    CYBER_DISK_MOUNT=unknown CYBER_DISK_PERSISTENCE=UNKNOWN
    if [ -d "$target" ] && [ -w "$target" ]; then
        CYBER_DISK_WRITABLE=true
        CYBER_DISK_FREE_MB="$(df -Pk "$target" 2>/dev/null | awk 'END {if ($4 ~ /^[0-9]+$/) printf "%.0f", int($4/1024); else print "unknown"}')"
    fi
    if [ -r "$proc/self/mountinfo" ]; then
        local record
        record="$(awk -v t="$target" '{m=$5; gsub(/\\040/, " ", m); if(m=="/" || t==m || index(t,m"/")==1) {
            if(length(m)>longest) {longest=length(m); mount=m; for(i=7;i<=NF;i++) if($i=="-") type=$(i+1)}
        }} END {if(longest) print type "|" mount}' "$proc/self/mountinfo")"
        if [ -n "$record" ]; then CYBER_DISK_FSTYPE="${record%%|*}"; CYBER_DISK_MOUNT="${record#*|}"; fi
    fi
    return 0
}

print_mount_summary() {
    local proc="${CYBERVPS_PROC_ROOT:-/proc}"
    [ -r "$proc/self/mountinfo" ] || { printf '%s\n' 'Mount topology: UNKNOWN'; return 0; }
    awk '{for(i=7;i<=NF;i++) if($i=="-") {
        kind=($4!="/" ? "bind/subtree" : $(i+1));
        printf "%s\t%s\t%s\tpersistence=UNKNOWN\n", $5,kind,$6;
    }}' "$proc/self/mountinfo"
}
