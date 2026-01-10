#!/bin/bash

set -uo pipefail

SEARCH_ROOT="${ROFI_FD_SEARCH_ROOT:-$HOME}"
ROFI_THEME_PATH="${ROFI_FD_BROWSER_THEME:-$HOME/.config/rofi/config.rasi}"
PROMPT_LABEL="${ROFI_FD_BROWSER_PROMPT:- }"
HISTORY_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/rofi-fd-browser-history"
HISTORY_LIMIT=100

FD_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
FD_CACHE_FILE="${FD_CACHE_DIR}/rofi-fd-browser-cache"
FD_CACHE_STAMP="${FD_CACHE_DIR}/rofi-fd-browser-cache.stamp"
FD_CACHE_LOCK="${FD_CACHE_DIR}/rofi-fd-browser-cache.lock"
FD_FULL_STAMP="${FD_CACHE_DIR}/rofi-fd-browser-cache.fullstamp"

FD_CACHE_TTL="${FD_CACHE_TTL:-30}"
FD_INCREMENTAL_TTL="${FD_INCREMENTAL_TTL:-$FD_CACHE_TTL}"
FD_MAX_INCREMENTAL_DIRS="${FD_MAX_INCREMENTAL_DIRS:-512}"

if [[ -z "${FD_FULL_REFRESH_TTL:-}" ]]; then
    if (( FD_CACHE_TTL > 0 )); then
        FD_FULL_REFRESH_TTL=$(( FD_CACHE_TTL * 4 ))
    else
        FD_FULL_REFRESH_TTL=0
    fi
fi

FD_THREADS=$(( $(nproc) * 2 ))

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

SHOW_HISTORY_ICON=true
RECENT_ICON="document-open-recent-symbolic"
REFRESH_ICON="view-refresh"

mkdir -p "$FD_CACHE_DIR"
[[ ! -f "$HISTORY_FILE" ]] && touch "$HISTORY_FILE"
[[ ! -f "$FD_CACHE_FILE" ]] && : > "$FD_CACHE_FILE"

with_cache_lock() {
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$FD_CACHE_LOCK" || return 1
        if ! flock -n 9; then
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

fd_search() {
    local args=(fd . --color never --hidden --type file --absolute-path)
    if (( FD_THREADS > 0 )); then
        args+=(--threads "$FD_THREADS")
    fi

    local excludes=()
    get_excludes excludes

    local exclude
    for exclude in "${excludes[@]}"; do
        args+=(--exclude "$exclude")
    done
    args+=("$@")
    "${args[@]}"
}

collect_changed_dirs() {
    [[ ! -f "$FD_CACHE_STAMP" ]] && return

    local stamp_time
    stamp_time=$(stat -c %Y "$FD_CACHE_STAMP" 2>/dev/null || echo 0)
    (( stamp_time == 0 )) && return

    local now
    now=$(date +%s)
    local window=$(( now - stamp_time ))
    (( window < 1 )) && window=1

    local excludes=()
    get_excludes excludes

    local fd_args=(
        fd . "$SEARCH_ROOT"
        --color never
        --hidden
        --type file
        --absolute-path
        --changed-within "${window}s"
    )

    if (( FD_THREADS > 0 )); then
        fd_args+=(--threads "$FD_THREADS")
    fi

    local exclude
    for exclude in "${excludes[@]}"; do
        fd_args+=(--exclude "$exclude")
    done

    "${fd_args[@]}" 2>/dev/null | \
        while IFS= read -r file_path; do
            [[ -z "$file_path" ]] && continue
            local dir_path="${file_path%/*}"
            [[ -z "$dir_path" ]] && dir_path="$SEARCH_ROOT"
            [[ -d "$dir_path" ]] && printf '%s\0' "${dir_path%/}"
        done | \
        sort -zu | tr '\0' '\n'
}

_prune_cache_entries() {
    local dirs=()
    local dir
    for dir in "$@"; do
        [[ -n "$dir" ]] && dirs+=("${dir%/}")
    done

    [[ ! -s "$FD_CACHE_FILE" ]] && return 0

    local tmp_file="${FD_CACHE_FILE}.tmp"
    local changed=0

    while IFS= read -r path; do
        [[ -z "$path" ]] && continue

        local skip=false
        if ((${#dirs[@]})); then
            for dir in "${dirs[@]}"; do
                if [[ "$path" == "$dir" || "$path" == "$dir"/* ]]; then
                    skip=true
                    changed=1
                    break
                fi
            done
        fi

        if [[ "$skip" == true ]]; then
            continue
        fi

        if [[ ! -f "$path" ]]; then
            changed=1
            continue
        fi

        printf '%s\n' "$path"
    done < "$FD_CACHE_FILE" > "$tmp_file"

    if (( changed )); then
        mv "$tmp_file" "$FD_CACHE_FILE"
        touch "$FD_CACHE_STAMP"
    else
        rm -f "$tmp_file"
    fi

    return $changed
}

_refresh_fd_cache_body() {
    local tmp_file="${FD_CACHE_FILE}.tmp"

    if fd_search "$SEARCH_ROOT" 2>/dev/null | sort -u > "$tmp_file"; then
        mv "$tmp_file" "$FD_CACHE_FILE"
        touch "$FD_CACHE_STAMP"
    else
        rm -f "$tmp_file"
    fi
}

notify_cache_refresh() {
    command -v notify-send >/dev/null 2>&1 || return 0
    local mode="${1:-full}"
    local app="${ROFI_FD_NOTIFY_APP:-Rofi FD Browser}"
    local icon="${ROFI_FD_NOTIFY_ICON:-view-refresh-symbolic}"
    local title="Cache Refresh"
    local body
    case "$mode" in
        incremental)
            body="Cache refresh <span color='#89b4fa'>[INCREMENTAL]</span>"
            ;;
        *)
            body="Cache refresh <span color='#a6e3a1'>[COMPLETE]</span>"
            ;;
    esac
    notify-send -a "$app" -i "$icon" "$title" "$body"
}

refresh_fd_cache() {
    local mode="${1:-full}"
    local notify="${2:-false}"
    with_cache_lock _refresh_fd_cache_body
    if [[ "$notify" == "true" ]]; then
        notify_cache_refresh "$mode"
    fi
}

run_refresh_worker() {
    local mode="${1:-full}"
    local notify="${2:-false}"

    case "$mode" in
        incremental)
            incremental_refresh_fd_cache false || refresh_fd_cache full false
            ;;
        *)
            refresh_fd_cache "$mode" false
            ;;
    esac
}

refresh_fd_cache_async() {
    local mode="${1:-full}"
    local notify="${2:-false}"
    (
        if command -v nice >/dev/null 2>&1; then
            nice -n 10 run_refresh_worker "$mode" "$notify"
        else
            run_refresh_worker "$mode" "$notify"
        fi
    ) >/dev/null 2>&1 &
}

_update_cache_for_dirs() {
    local dirs=()
    local dir
    for dir in "$@"; do
        [[ -d "$dir" ]] || continue
        dirs+=("${dir%/}")
    done

    (( ${#dirs[@]} == 0 )) && return

    _prune_cache_entries "${dirs[@]}"

    local tmp_new="${FD_CACHE_FILE}.new"
    if ! fd_search "${dirs[@]}" 2>/dev/null | sort -u > "$tmp_new"; then
        rm -f "$tmp_new"
        return
    fi

    if [[ ! -s "$tmp_new" ]]; then
        rm -f "$tmp_new"
        return
    fi

    local tmp_merged="${FD_CACHE_FILE}.merged"
    if [[ -s "$FD_CACHE_FILE" ]]; then
        cat "$FD_CACHE_FILE" "$tmp_new" | sort -u > "$tmp_merged" && mv "$tmp_merged" "$FD_CACHE_FILE"
        rm -f "$tmp_merged"
    else
        mv "$tmp_new" "$FD_CACHE_FILE"
    fi

    rm -f "$tmp_new"
    touch "$FD_CACHE_STAMP"
}

incremental_refresh_fd_cache() {
    local notify="${1:-false}"

    if [[ ! -s "$FD_CACHE_FILE" || ! -f "$FD_CACHE_STAMP" ]]; then
        refresh_fd_cache full false
        return
    fi

    local dirs=()
    local overflow=false
    while IFS= read -r dir; do
        [[ -z "$dir" ]] && continue
        dirs+=("$dir")
        if (( ${#dirs[@]} >= FD_MAX_INCREMENTAL_DIRS )); then
            overflow=true
            break
        fi
    done < <(collect_changed_dirs)

    if [[ "$overflow" == true ]]; then
        refresh_fd_cache full false
        return
    fi

    if (( ${#dirs[@]} == 0 )); then
        with_cache_lock _prune_cache_entries >/dev/null 2>&1
        return
    fi

    with_cache_lock _update_cache_for_dirs "${dirs[@]}"
}

cache_age_seconds() {
    local target="$1"
    [[ ! -f "$target" ]] && { printf '%d\n' -1; return; }

    local mtime
    mtime=$(stat -c %Y "$target" 2>/dev/null || echo 0)

    (( mtime == 0 )) && { printf '%d\n' 0; return; }

    local now
    now=$(date +%s)
    printf '%d\n' $(( now - mtime ))
}

maybe_refresh_fd_cache() {
    local force_refresh=${1:-false}
    local has_cache=false

    [[ -s "$FD_CACHE_FILE" ]] && has_cache=true

    if [[ "$force_refresh" == true || "$has_cache" == false ]]; then
        refresh_fd_cache_async full false
        return 0
    fi

    local age
    age=$(cache_age_seconds "$FD_CACHE_FILE")

    if (( age < 0 )); then
        refresh_fd_cache_async full false
        return 0
    fi

    if (( FD_FULL_REFRESH_TTL > 0 )); then
        local full_age
        full_age=$(cache_age_seconds "$FD_FULL_STAMP")
        if (( full_age < 0 || full_age >= FD_FULL_REFRESH_TTL )); then
            refresh_fd_cache_async full false
            return 0
        fi
    fi

    if (( FD_INCREMENTAL_TTL <= 0 )); then
        refresh_fd_cache_async incremental false
        return 0
    fi

    if (( age >= FD_INCREMENTAL_TTL )); then
        refresh_fd_cache_async incremental false
    fi

    return 0
}

update_history() {
    local file="$1"
    local now
    now=$(date +%s)

    local tmp_scores
    tmp_scores=$(mktemp)
    local found=0

    if [[ -s "$HISTORY_FILE" ]]; then
        while IFS='|' read -r path count last_time; do
            [[ -z "$path" ]] && continue
            if [[ "$path" == "$file" ]]; then
                count=$((count + 1))
                last_time=$now
                found=1
            fi

            local age=$(( (now - last_time) / 86400 + 1 ))
            (( age < 1 )) && age=1
            local score=$(( (count * 1000000) / age ))
            printf '%012d|%s|%d|%d\n' "$score" "$path" "$count" "$last_time"
        done < "$HISTORY_FILE" > "$tmp_scores"
    else
        > "$tmp_scores"
    fi

    if (( !found )); then
        local score_new=$(( (1 * 1000000) ))
        printf '%012d|%s|1|%d\n' "$score_new" "$file" "$now" >> "$tmp_scores"
    fi

    local tmp_final
    tmp_final=$(mktemp)
    sort -t'|' -k1,1nr "$tmp_scores" | head -n "$HISTORY_LIMIT" | cut -d'|' -f2- > "$tmp_final"
    mv "$tmp_final" "$HISTORY_FILE"
    rm -f "$tmp_scores"
}

get_history_files() {
    local now
    now=$(date +%s)
    [[ ! -s "$HISTORY_FILE" ]] && return

    local tmp_sorted
    tmp_sorted=$(mktemp)

    while IFS='|' read -r path count last_time; do
        [[ -z "$path" ]] && continue
        local age=$(( (now - last_time) / 86400 + 1 ))
        (( age < 1 )) && age=1
        local score=$(( (count * 1000000) / age ))
        printf '%012d|%s\n' "$score" "$path"
    done < "$HISTORY_FILE" | sort -t'|' -k1,1nr > "$tmp_sorted"

    while IFS='|' read -r _ path; do
        [[ -z "$path" ]] && continue
        if [[ -f "$path" ]]; then
            local display_path="${path/#$HOME/\~}"
            if [[ "$SHOW_HISTORY_ICON" == true ]]; then
                printf '%s\x00icon\x1f%s\n' "$display_path" "$RECENT_ICON"
            else
                printf '%s\n' "$display_path"
            fi
        fi
    done < "$tmp_sorted"

    rm -f "$tmp_sorted"
}

open_with_preferred_app() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        printf 'File not found: %s\n' "$file" >&2
        return 1
    fi

    local mimetype=""
    if command -v file >/dev/null 2>&1; then
        mimetype=$(file --mime-type -b "$file" 2>/dev/null || printf '')
    fi

    if [[ -n "$mimetype" ]] && command -v xdg-mime >/dev/null 2>&1; then
        local desktop_id=""
        desktop_id=$(xdg-mime query default "$mimetype" 2>/dev/null || printf '')

        if [[ -n "$desktop_id" ]]; then
            local desktop_name="${desktop_id%.desktop}"

            if command -v gtk-launch >/dev/null 2>&1; then
                gtk-launch "$desktop_name" "$file" >/dev/null 2>&1 &
                return 0
            fi

            if command -v gio >/dev/null 2>&1; then
                GIO_LAUNCHED_DESKTOP_FILE="$desktop_id" gio open "$file" >/dev/null 2>&1 &
                return 0
            fi
        fi
    fi

    if command -v gio >/dev/null 2>&1; then
        gio open "$file" >/dev/null 2>&1 &
        return 0
    fi

    if command -v xdg-open >/dev/null 2>&1; then
        xdg-open "$file" >/dev/null 2>&1 &
        return 0
    fi

    if command -v open >/dev/null 2>&1; then
        open "$file" >/dev/null 2>&1 &
        return 0
    fi

    printf 'No opener found for %s\n' "$file" >&2
    return 1
}

show_rofi() {
    {
        declare -A seen=()

        if [[ "$SHOW_HISTORY_ICON" == true ]]; then
            printf 'Force Refresh Cache\x00icon\x1f%s\n' "$REFRESH_ICON"
        else
            printf 'Force Refresh Cache\n'
        fi

        if [[ -s "$HISTORY_FILE" ]]; then
            get_history_files
        fi

        if [[ -s "$FD_CACHE_FILE" ]]; then
            cat "$FD_CACHE_FILE"
        fi
    } | awk '!seen[$0]++' | rofi -dmenu -i -p "$PROMPT_LABEL" -theme "$ROFI_THEME_PATH" -show-icons
}

if [[ -z "${ROFI_RETV:-}" ]]; then
    case "${1:-}" in
        --refresh)
            refresh_fd_cache full true
            exit $?
            ;;
        --incremental)
            incremental_refresh_fd_cache true
            exit $?
            ;;
        --background-refresh)
            refresh_fd_cache_async full false
            exit 0
            ;;
        --background-incremental)
            refresh_fd_cache_async incremental false
            exit 0
            ;;
    esac
fi

maybe_refresh_fd_cache
choice=$(show_rofi)
choice=${choice%%$'\n'}

[[ -z "$choice" ]] && exit 0

if [[ "$choice" == "Force Refresh Cache" ]]; then
    refresh_fd_cache full true
    exec "$0"
fi

file="${choice/#\~/$HOME}"

if [[ -f "$file" ]]; then
    update_history "$file" &
    open_with_preferred_app "$file"
fi

exit 0
