#!/bin/bash

set -uo pipefail

SEARCH_ROOT="${ROFI_FD_SEARCH_ROOT:-$HOME}"
ROFI_THEME_PATH="${ROFI_FD_BROWSER_THEME:-$HOME/.config/rofi/config.rasi}"
PROMPT_LABEL="${ROFI_FD_BROWSER_PROMPT:- }"
HISTORY_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/rofi-fd-browser-history"
HISTORY_LIMIT=100

FD_CACHE_DIR="${XDG_CACHE_HOME:-$HOME/.cache}"
FD_CACHE_FILE="${FD_CACHE_DIR}/rofi-fd-browser-cache"
FD_CACHE_STAMP="${FD_CACHE_DIR}/rofi-fd-browser-cache.stamp"
FD_CACHE_LOCK="${FD_CACHE_DIR}/rofi-fd-browser-cache.lock"

NPROC_COUNT=$(nproc 2>/dev/null || echo 1)
FD_THREADS=$(( NPROC_COUNT * 2 ))

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

REFRESH_ICON="view-refresh-symbolic"
HISTORY_ICON="document-open-recent-symbolic"

mkdir -p "$FD_CACHE_DIR"
[[ ! -f "$HISTORY_FILE" ]] && touch "$HISTORY_FILE"

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
    local app="${ROFI_FD_NOTIFY_APP:-Rofi FD Browser}"
    local icon="${ROFI_FD_NOTIFY_ICON:-view-refresh-symbolic}"
    local title="Cache Refresh"
    local body="Cache refresh <span color='#a6e3a1'>[COMPLETE]</span>"
    notify-send -a "$app" -i "$icon" "$title" "$body"
}

refresh_fd_cache() {
    local notify="${1:-false}"
    with_cache_lock _refresh_fd_cache_body
    if [[ "$notify" == "true" ]]; then
        notify_cache_refresh
    fi
}

initialize_cache_if_needed() {
    if [[ ! -f "$FD_CACHE_FILE" ]] || [[ ! -s "$FD_CACHE_FILE" ]]; then
        refresh_fd_cache false
    fi
}

update_history() {
    local file="$1"
    local now=$(date +%s)
    local tmp_file=$(mktemp)

    declare -A counts
    declare -A last_times

    if [[ -s "$HISTORY_FILE" ]]; then
        while IFS='|' read -r path count last_time; do
            [[ -z "$path" ]] && continue

            if [[ -n "${counts[$path]:-}" ]]; then
                counts[$path]=$(( counts[$path] + count ))
                if (( last_time > ${last_times[$path]} )); then
                    last_times[$path]=$last_time
                fi
            else
                counts[$path]=$count
                last_times[$path]=$last_time
            fi
        done < "$HISTORY_FILE"
    fi

    if [[ -n "${counts[$file]:-}" ]]; then
        counts[$file]=$(( counts[$file] + 1 ))
        last_times[$file]=$now
    else
        counts[$file]=1
        last_times[$file]=$now
    fi

    for path in "${!counts[@]}"; do
        local count=${counts[$path]}
        local last_time=${last_times[$path]}
        local age=$(( (now - last_time) / 86400 + 1 ))
        (( age < 1 )) && age=1
        local score=$(( (count * 1000000) / age ))
        printf '%012d|%s|%d|%d\n' "$score" "$path" "$count" "$last_time"
    done | sort -t'|' -k1,1nr | head -n "$HISTORY_LIMIT" | cut -d'|' -f2- > "$tmp_file"

    mv "$tmp_file" "$HISTORY_FILE"
}

get_history_files() {
    local now=$(date +%s)
    [[ ! -s "$HISTORY_FILE" ]] && return

    local max_display=${ROFI_FD_DISPLAY_WIDTH:-80}

    awk -v now="$now" -v max_display="$max_display" -v home="$HOME" -v limit="$HISTORY_LIMIT" '
        function shorten_middle(text, max_len,   keep, front, back) {
            if (max_len <= 0 || length(text) <= max_len) return text;
            keep = max_len - 3;
            if (keep < 1) keep = 1;
            front = int((keep + 1) / 2);
            back = keep - front;
            if (back < 1) back = 1;
            return substr(text, 1, front) "..." substr(text, length(text) - back + 1);
        }

        function format_display(path,   base, dir, sep, available, dir_display) {
            sep = " — ";
            base = path;
            sub(/^.*\//, "", base);

            dir = path;
            sub(/\/[^/]*$/, "", dir);
            if (dir == path) dir = "";
            if (dir != "" && home != "" && index(dir, home) == 1) {
                dir = "~" substr(dir, length(home) + 1);
            }

            if (dir == "") return base;

            if (max_display <= 0) max_display = 80;
            available = max_display - length(base) - length(sep);

            if (available <= 0) return base;

            dir_display = dir;
            if (length(dir_display) > available) {
                dir_display = shorten_middle(dir_display, available);
            }

            return base sep dir_display;
        }

        BEGIN { FS = "|"; }

        {
            path = $1; count = $2; last_time = $3;
            if (path == "") next;

            if (system("[ -f \"" path "\" ]") != 0) next;

            age = int((now - last_time) / 86400 + 1);
            if (age < 1) age = 1;
            score = int((count * 1000000) / age);

            printf "%012d|%s\n", score, path;
        }
    ' "$HISTORY_FILE" | sort -t'|' -k1,1nr | head -n "$HISTORY_LIMIT" | awk -F'|' -v max_display="$max_display" -v home="$HOME" -v history_icon="$HISTORY_ICON" '
        function shorten_middle(text, max_len,   keep, front, back) {
            if (max_len <= 0 || length(text) <= max_len) return text;
            keep = max_len - 3;
            if (keep < 1) keep = 1;
            front = int((keep + 1) / 2);
            back = keep - front;
            if (back < 1) back = 1;
            return substr(text, 1, front) "..." substr(text, length(text) - back + 1);
        }

        function format_display(path,   base, dir, sep, available, dir_display) {
            sep = " — ";
            base = path;
            sub(/^.*\//, "", base);

            dir = path;
            sub(/\/[^/]*$/, "", dir);
            if (dir == path) dir = "";
            if (dir != "" && home != "" && index(dir, home) == 1) {
                dir = "~" substr(dir, length(home) + 1);
            }

            if (dir == "") return base;

            if (max_display <= 0) max_display = 80;
            available = max_display - length(base) - length(sep);

            if (available <= 0) return base;

            dir_display = dir;
            if (length(dir_display) > available) {
                dir_display = shorten_middle(dir_display, available);
            }

            return base sep dir_display;
        }

        {
            path = $2;
            display = format_display(path);
            printf "%s\x00icon\x1f%s\x1fdisplay\x1f%s\n", path, history_icon, display;
        }
    '
}

get_cache_entries() {
    [[ ! -s "$FD_CACHE_FILE" ]] && return

    local max_display=${ROFI_FD_DISPLAY_WIDTH:-80}

    awk -v max_display="$max_display" -v home="$HOME" '
        function shorten_middle(text, max_len,   keep, front, back) {
            if (max_len <= 0 || length(text) <= max_len) return text;
            keep = max_len - 3;
            if (keep < 1) keep = 1;
            front = int((keep + 1) / 2);
            back = keep - front;
            if (back < 1) back = 1;
            return substr(text, 1, front) "..." substr(text, length(text) - back + 1);
        }

        function format_display(path,   base, dir, sep, available, dir_display) {
            sep = " — ";
            base = path;
            sub(/^.*\//, "", base);

            dir = path;
            sub(/\/[^/]*$/, "", dir);
            if (dir == path) dir = "";
            if (dir != "" && home != "" && index(dir, home) == 1) {
                dir = "~" substr(dir, length(home) + 1);
            }

            if (dir == "") return base;

            if (max_display <= 0) max_display = 80;
            available = max_display - length(base) - length(sep);

            if (available <= 0) return base;

            dir_display = dir;
            if (length(dir_display) > available) {
                dir_display = shorten_middle(dir_display, available);
            }

            return base sep dir_display;
        }

        {
            path = $0;
            if (path == "") next;
            display = format_display(path);
            printf "%s\x00display\x1f%s\n", path, display;
        }
    ' "$FD_CACHE_FILE"
}

open_with_preferred_app() {
    local file="$1"

    if [[ ! -f "$file" ]]; then
        printf 'File not found: %s\n' "$file" >&2
        return 1
    fi

    local mimetype=""
    if command -v file >/dev/null 2>&1; then
        mimetype=$(file --mime-type -b "$file" 2>/dev/null)
    fi

    if [[ -n "$mimetype" ]] && command -v xdg-mime >/dev/null 2>&1; then
        local desktop_id=$(xdg-mime query default "$mimetype" 2>/dev/null)

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
    local rofi_args=(-dmenu -i -p "$PROMPT_LABEL" -theme "$ROFI_THEME_PATH")

    if [[ "${ROFI_FD_DISABLE_ELLIPSIZE:-true}" == true ]]; then
        rofi_args+=(-theme-str 'element-text, element-text-selected, element-text-active { ellipsize: "none"; }')
    fi

    rofi_args+=(-show-icons)

    {
        printf 'Force Refresh Cache\x00icon\x1f%s\n' "$REFRESH_ICON"

        if [[ -s "$HISTORY_FILE" ]]; then
            get_history_files
        fi

        if [[ -s "$FD_CACHE_FILE" ]]; then
            get_cache_entries
        fi
    } | rofi "${rofi_args[@]}"
}

initialize_cache_if_needed

if [[ -z "${ROFI_RETV:-}" ]]; then
    case "${1:-}" in
        --refresh)
            refresh_fd_cache true
            exit $?
            ;;
    esac
fi

choice=$(show_rofi)
choice=${choice%%$'\n'}

[[ -z "$choice" ]] && exit 0

if [[ "$choice" == "Force Refresh Cache" ]]; then
    refresh_fd_cache true
    exec "$0"
fi

file="${choice/#\~/$HOME}"

if [[ -f "$file" ]]; then
    update_history "$file" &
    open_with_preferred_app "$file"
fi

exit 0
