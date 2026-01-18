# rofi-fd-browser

A rofi file browser using fd with background caching and frecency-based history.

## Screenshots

<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/8c42060d-51ed-4448-b4fe-e2e1f50ae82a" />
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/f765a4ff-d70b-40ab-9f2a-9a68a78c21f4" />
<img width="1920" height="1080" alt="image" src="https://github.com/user-attachments/assets/5fd83551-cf88-4c4f-a66a-cc5d85420c80" />

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
