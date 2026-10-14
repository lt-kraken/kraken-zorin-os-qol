# Zorin Personal Setup

A native GTK4/libadwaita desktop app for optional desktop tools and reusable personal setup profiles on Zorin OS. Changes are staged for review, and a snapshot is created before they are applied.

## Run

```sh
bash app/run.sh
```

The launcher builds with Rust in the GNOME 49 SDK and starts the binary on the host desktop so it can access the current GNOME session. It may offer to install the SDK for your user. No `sudo` is used. Rust stable must be installed with rustup.

To build manually:

```sh
. "$HOME/.cargo/env"
cd app
cargo test
cargo build --release
```

The GNOME SDK is needed for GTK development files. `app/run.sh` provides the SDK build path.

## Features

- **Profiles:** save, replace, stage, and delete personal selections for Clipboard Indicator, Search Light, the Focus shortcut, and clipboard history cleanup. Staging never applies a profile; use **Apply changes** to review and confirm it.
- **Shortcuts:** optionally install Clipboard Indicator and Search Light GNOME Shell extensions and configure a Focus mode toggle shortcut.
- **Workflow:** temporarily prevent automatic sleep for 30 minutes, 1 hour, or 2 hours. The request expires automatically, can be stopped early, and is released when the app closes. Install or launch LocalSend for iPhone file transfers.
- **Privacy:** clear Clipboard Indicator history at login. Clipboard Indicator is an optional third-party extension; its history may contain sensitive content.
- **Backups:** create snapshots, automatically back up before Apply, and restore a selected snapshot. New snapshots contain this tool's managed desktop preferences and saved profiles. Older snapshots remain restorable, including their prior audio-profile data; installed applications are not removed during restore.

Settings and profiles are changed on the user account only. Profiles are stored in `~/.config/zorin-personal-setup/profiles.json`; snapshots are stored in `~/.local/state/zorin-setup/backups/`. Temporary keep-awake uses `systemd-inhibit` and does not alter persistent power settings.

The app intentionally does not duplicate Zorin/GNOME controls for Night Light, appearance, sound, screenshots, window tiling, workspaces, screen locking, or startup applications.

## Project Layout

- `app/` contains the Rust GTK4/libadwaita application and backend.
- `app/run.sh` builds and launches the desktop app through the GNOME SDK.
- `setup-zorin.sh` is the earlier shell-based setup tool retained as a reference while the native app is developed.

The app is under active development. Review the staged changes before applying them, and keep a copy of `~/.local/state/zorin-setup/backups/` outside the computer if you need it after a clean reinstall.
