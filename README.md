# dotfiles

Personal dotfiles for a Linux desktop setup built around Hyprland, Waybar, and Alacritty, plus shell and Vim configuration and package lists.

## What is in here

- `dot_bashrc`, `dot_zshrc`, `dot_vimrc` — shell and Vim configuration
- `dot_vim/colors/` — Vim colour schemes
- `dot_config/hypr/` — Hyprland configuration (including a templated `hyprland.lua.tmpl`)
- `dot_config/waybar/` — Waybar configuration and styling (`config.tmpl`, `style.css`)
- `dot_config/alacritty/` — Alacritty terminal configuration (`private_alacritty.toml.tmpl`)
- `dot_local/bin/executable_bt-reconnect.sh` — Bluetooth reconnect helper script
- `package-lists/shared.txt` — packages shared across machines
- `package-lists/desktop-only.txt` — packages for desktop machines only

## Layout note

Files use a `dot_` prefix for files that live in the home directory, and a `.tmpl` suffix for templated configuration. That means these files are not ready to copy verbatim into `$HOME` — `dot_` files need renaming (for example, `dot_bashrc` becomes `.bashrc`) and `.tmpl` files need rendering first.

There is no install script in this repo. Review a file before applying it to your own setup, especially the Hyprland and Waybar templates, which are written for this machine setup.
