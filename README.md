# Zorin Personal Setup

This interactive script applies selected personal settings on Zorin OS. It is intended for reinstallations and can be safely run again.

## Usage

Start the setup:

```sh
bash setup-zorin.sh
```

Select the features to configure in the first screen. Everything starts unchecked; existing settings for unselected features remain unchanged. If you select audio input or output, a second screen lists the available PipeWire profiles and marks currently active choices.

The script shows a summary and asks for confirmation before applying changes. You can cancel at any selection screen.

Run the same flow without applying changes:

```sh
bash setup-zorin.sh --dry-run
```

The script does not require `sudo`. Missing GNOME extensions are downloaded from extensions.gnome.org. When run from the VS Code Flatpak terminal, it uses `flatpak-spawn --host`; from a regular terminal, it runs commands directly on the host.

## Features

- **macOS-style top bar:** keeps the GNOME top bar and configures the Zorin dock at the bottom, centered and dynamic; hides **System Menu** and **Date Menu** from the dock.
- **Windows-style screenshot shortcut:** keeps `Print Screen` and maps `Super+Shift+S` to the screenshot interface.
- **Clipboard history:** installs Clipboard Indicator with `Super+V`, a 25-item history, favorites-only disk caching, and image caching disabled.
- **Spotlight-style search:** installs Search Light with `Super+Space`, opens on the monitor under the pointer, and shows an icon in the top bar.
- **Limit audio devices:** lists input and output profiles separately. Selected profiles are kept; unselected profiles on those cards are disabled. You can choose at most one profile per direction for each audio device. The script preserves the unselected direction when a compatible combined profile exists; otherwise, it stops before making changes.

The **Windows-style screenshot shortcut** and **Spotlight-style search** are independent options. Search Light also moves the keyboard-layout switch shortcut to `Super+Alt+Space`, freeing `Super+Space`.

Audio devices are discovered by PipeWire device and profile names, not volatile device IDs. GNOME extensions are downloaded for the detected GNOME Shell version.

## Backups and Extensions

Before applying changes, the script saves GNOME Shell settings, keyboard shortcuts, and the current PipeWire status under `~/.local/state/zorin-setup/backups/`. This is a local backup; copy both this directory and the setup script elsewhere if you need them after a clean reinstall.

Add future preferences as separate options in the first selection screen, and apply them only when selected. The script does not install Android integration or system packages. Logging out and back in may be required after installing new GNOME extensions.