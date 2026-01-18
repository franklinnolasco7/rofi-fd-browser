#!/bin/bash

set -uo pipefail

SEARCH_ROOT="${ROFI_FD_SEARCH_ROOT:-$HOME}"
FD_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
FD_CACHE_FILE="${FD_CACHE_DIR}/rofi-fd-browser-cache"
FD_CACHE_STAMP="${FD_CACHE_DIR}/rofi-fd-browser-cache.stamp"
FD_CACHE_LOCK="${FD_CACHE_DIR}/rofi-fd-browser-cache.lock"
DAEMON_PID_FILE="${FD_CACHE_DIR}/rofi-fd-daemon.pid"
DAEMON_LOG_FILE="${FD_CACHE_DIR}/rofi-fd-daemon.log"

NPROC_COUNT=$(nproc 2>/dev/null || echo 1)
FD_THREADS=$(( NPROC_COUNT * 2 ))

FULL_REBUILD_INTERVAL=${ROFI_FD_FULL_REBUILD_INTERVAL:-3600}

FD_EXCLUDES_HOME=(
    '.git'
    'node_modules'
    '.cargo'
    '.npm'
    '.cache'
    '.mozilla'
    '.local/share/Trash'
    '.Trash*'
    '.vscode'
    '__pycache__'
)

FD_EXCLUDES_SYSTEM=(
    '/proc'
    '/sys'
    '/dev'
    '/run'
    '/tmp'
    '/var/tmp'
    '/var/cache'
    '/var/log'
    '/boot'
    '/lost+found'
    '.snapshots'
)

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" >> "$DAEMON_LOG_FILE"
}

check_dependencies() {
    local missing=()

    if ! command -v inotifywait >/dev/null 2>&1; then
        missing+=("inotify-tools")
    fi

    if ! command -v fd >/dev/null 2>&1; then
        missing+=("fd" "fd-find")
    fi

    if (( ${#missing[@]} > 0 )); then
        log "ERROR: Missing dependencies: ${missing[*]}"
        echo "ERROR: Missing dependencies: ${missing[*]}" >&2
        echo "Please install: ${missing[*]}" >&2
        exit 1
    fi
}

mkdir -p "$FD_CACHE_DIR"

with_cache_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$FD_CACHE_LOCK" || return 1
        if ! flock -w 1 9; then
            exec 9>&-
            return 1
        fi
        "$@"
        local status=$?
        flock -u 9
        exec 9>&-
        return $status
    else
        "$@"
    fi
}

get_excludes() {
    local -n arr=$1
    if [[ "$SEARCH_ROOT" == "/" ]]; then
        arr=("${FD_EXCLUDES_HOME[@]}" "${FD_EXCLUDES_SYSTEM[@]}")
    else
        arr=("${FD_EXCLUDES_HOME[@]}")
    fi
}

build_fd_excludes() {
    local excludes=()
    get_excludes excludes

    local exclude
    for exclude in "${excludes[@]}"; do
        printf -- '--exclude %q ' "$exclude"
    done
}

build_inotify_excludes() {
    local excludes=()
    get_excludes excludes

    local exclude
    for exclude in "${excludes[@]}"; do
        printf -- '--exclude %q ' "$exclude"
    done
}

rebuild_cache() {
    log "Starting full cache rebuild..."
    local tmp_file="${FD_CACHE_FILE}.tmp"

    local fd_excludes=$(build_fd_excludes)

    if eval "fd . --color never --hidden --type file --absolute-path --threads $FD_THREADS $fd_excludes $(printf %q "$SEARCH_ROOT")" 2>/dev/null | sort -u > "$tmp_file"; then
        if with_cache_lock mv "$tmp_file" "$FD_CACHE_FILE"; then
            touch "$FD_CACHE_STAMP"
            log "Cache rebuild complete ($(wc -l < "$FD_CACHE_FILE") files)"
            return 0
        fi
    fi

    rm -f "$tmp_file"
    log "ERROR: Cache rebuild failed"
    return 1
}

add_to_cache() {
    local file="$1"

    if grep -Fxq "$file" "$FD_CACHE_FILE" 2>/dev/null; then
        return 0
    fi

    if with_cache_lock bash -c "echo '$file' >> '$FD_CACHE_FILE'"; then
        touch "$FD_CACHE_STAMP"
        log "Added: $file"
    fi
}

remove_from_cache() {
    local file="$1"
    local tmp_file="${FD_CACHE_FILE}.remove.tmp"

    if with_cache_lock grep -Fxv "$file" "$FD_CACHE_FILE" 2>/dev/null > "$tmp_file"; then
        mv "$tmp_file" "$FD_CACHE_FILE"
        touch "$FD_CACHE_STAMP"
        log "Removed: $file"
    else
        rm -f "$tmp_file"
    fi
}

should_exclude() {
    local path="$1"
    local excludes=()
    get_excludes excludes

    local exclude
    for exclude in "${excludes[@]}"; do
        if [[ "$path" == *"/$exclude"* ]] || [[ "$path" == *"/$exclude" ]]; then
            return 0
        fi
    done

    return 1
}

process_event() {
    local event="$1"
    local path="$2"
    local file="$3"

    local full_path="$path$file"

    if should_exclude "$full_path"; then
        return
    fi

    case "$event" in
        CREATE|MOVED_TO)
            if [[ -f "$full_path" ]]; then
                add_to_cache "$full_path"
            fi
            ;;
        DELETE|MOVED_FROM)
            remove_from_cache "$full_path"
            ;;
        MODIFY)
            if [[ -f "$full_path" ]]; then
                add_to_cache "$full_path"
            fi
            ;;
    esac
}

cleanup() {
    log "Daemon shutting down (PID: $$)..."
    rm -f "$DAEMON_PID_FILE"
    exit 0
}

trap cleanup SIGTERM SIGINT

start_daemon() {
    check_dependencies

    if [[ -f "$DAEMON_PID_FILE" ]]; then
        local old_pid=$(cat "$DAEMON_PID_FILE")
        if kill -0 "$old_pid" 2>/dev/null; then
            log "ERROR: Daemon already running (PID: $old_pid)"
            echo "Daemon already running (PID: $old_pid)" >&2
            exit 1
        else
            rm -f "$DAEMON_PID_FILE"
        fi
    fi

    echo $ > "$DAEMON_PID_FILE"

    log "Daemon started (PID: $)"
    log "Watching: $SEARCH_ROOT"

    if [[ ! -f "$FD_CACHE_FILE" ]] || [[ ! -s "$FD_CACHE_FILE" ]]; then
        rebuild_cache
    else
        log "Using existing cache ($(wc -l < "$FD_CACHE_FILE") files)"
    fi

    local last_full_rebuild=$(date +%s)
    local inotify_excludes=$(build_inotify_excludes)

    log "Starting inotify watcher..."

    eval "stdbuf -oL inotifywait -m -r -q \
        --format '%e %w %f' \
        -e create,delete,moved_to,moved_from \
        $inotify_excludes \
        $(printf %q "$SEARCH_ROOT")" 2>/dev/null | \
    while IFS= read -r line; do
        read -r event path file <<< "$line"
        process_event "$event" "$path" "$file"

        local now=$(date +%s)
        if (( now - last_full_rebuild > FULL_REBUILD_INTERVAL )); then
            log "Performing scheduled full rebuild..."
            rebuild_cache
            last_full_rebuild=$now
        fi
    done
}

stop_daemon() {
    if [[ ! -f "$DAEMON_PID_FILE" ]]; then
        echo "Daemon is not running" >&2
        return 1
    fi

    local pid=$(cat "$DAEMON_PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        log "Stopping daemon (PID: $pid)..."
        kill "$pid"

        local count=0
        while kill -0 "$pid" 2>/dev/null && (( count < 10 )); do
            sleep 0.5
            ((count++))
        done

        if kill -0 "$pid" 2>/dev/null; then
            log "Force killing daemon (PID: $pid)..."
            kill -9 "$pid"
        fi

        rm -f "$DAEMON_PID_FILE"
        log "Daemon stopped"
        echo "Daemon stopped"
    else
        rm -f "$DAEMON_PID_FILE"
        echo "Daemon was not running (stale PID file removed)"
    fi
}

status_daemon() {
    if [[ ! -f "$DAEMON_PID_FILE" ]]; then
        echo "Daemon is not running"
        return 1
    fi

    local pid=$(cat "$DAEMON_PID_FILE")

    if kill -0 "$pid" 2>/dev/null; then
        echo "Daemon is running (PID: $pid)"
        echo "Cache file: $FD_CACHE_FILE"
        if [[ -f "$FD_CACHE_FILE" ]]; then
            echo "Cache entries: $(wc -l < "$FD_CACHE_FILE")"
            echo "Last updated: $(stat -c %y "$FD_CACHE_STAMP" 2>/dev/null || echo "unknown")"
        fi
        return 0
    else
        echo "Daemon is not running (stale PID file found)"
        rm -f "$DAEMON_PID_FILE"
        return 1
    fi
}

case "${1:-start}" in
    start)
        start_daemon
        ;;
    stop)
        stop_daemon
        ;;
    restart)
        stop_daemon
        sleep 1
        start_daemon
        ;;
    status)
        status_daemon
        ;;
    rebuild)
        rebuild_cache
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status|rebuild}" >&2
        exit 1
        ;;
esac
