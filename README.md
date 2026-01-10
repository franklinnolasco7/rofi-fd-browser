# rofi-fd-browser

A rofi file browser using fd with background caching and frecency-based history.

## Screenshots

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/110e7411-e837-4605-b2d6-eb31fd9dd718" />
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/1ed26f22-e5fb-4473-8c9e-2e5c021066c3" />

## Requirements

- `rofi`
- `fd`
- `bash`

## Install
```bash
cp rofi-fd-browser.sh ~/.config/rofi/scripts/
chmod +x ~/.config/rofi/scripts/rofi-fd-browser.sh
```

## Usage

Add to your `hyprland.conf`:
```bash
$fd_browser = $HOME/.config/rofi/scripts/rofi-fd-browser.sh
bind = $mainMod, F, exec, $fd_browser
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

# Cache TTL in seconds (default: 30)
export FD_CACHE_TTL=30
```

## How it works

- Scans files with `fd` and caches results
- Auto-refreshes cache in background
- Tracks opened files and ranks by frecency (frequency + recency)
- Opens files with default application

Cache files are stored in `$XDG_CACHE_HOME` or `~/.cache`.
