# rofi-fd-browser

A rofi file browser using fd with real-time inotify caching and frecency-based history.

## Screenshots

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/f987ed49-447b-4534-b160-9dc314425062" />
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/b5e6e99c-d82f-4e73-9724-010a0cdab5bf" />
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/2b73e730-6432-4ee6-9847-4d222baf0291" />

## Requirements

- `rofi`
- `fd`
- `bash`
- `inotify-tools`

## Install

```bash
cp rofi-fd-browser.sh ~/.config/rofi/scripts/
cp rofi-fd-daemon.sh ~/.config/rofi/scripts/
chmod +x ~/.config/rofi/scripts/rofi-fd-browser.sh
chmod +x ~/.config/rofi/scripts/rofi-fd-daemon.sh

mkdir -p ~/.config/systemd/user
cp rofi-fd-daemon.service ~/.config/systemd/user/

systemctl --user daemon-reload
systemctl --user enable --now rofi-fd-daemon.service
```

## Usage

Add to your `hyprland.conf`:

```bash
$fd_browser = $HOME/.config/rofi/scripts/rofi-fd-browser.sh
bind = $mainMod, F, exec, $fd_browser
```

Manage daemon:

```bash
systemctl --user status rofi-fd-daemon.service
systemctl --user restart rofi-fd-daemon.service
```

## Config

Environment variables:

```bash
# Search path (default: $HOME)
export ROFI_FD_SEARCH_ROOT="$HOME"

# Rofi theme
export ROFI_FD_BROWSER_THEME="$HOME/.config/rofi/config.rasi"

# Prompt
export ROFI_FD_BROWSER_PROMPT=" "

# Display width (default: 80)
export ROFI_FD_DISPLAY_WIDTH=80

# Full rebuild interval in seconds (default: 3600)
export ROFI_FD_FULL_REBUILD_INTERVAL=3600

# Show refresh button (default: false)
export ROFI_FD_SHOW_REFRESH_BUTTON=false
```

## How it works

- Background daemon watches filesystem with inotify
- Cache updates in real-time as files change
- Tracks opened files and ranks by frecency (frequency + recency)
- Opens files with default application

Cache files are stored in `$XDG_CACHE_HOME` or `~/.cache`.
