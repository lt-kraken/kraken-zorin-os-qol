#!/usr/bin/env bash
set -euo pipefail

schema='org.gnome.desktop.notifications'
key='show-banners'

if [[ "$(gsettings get "$schema" "$key")" == true ]]; then
  gsettings set "$schema" "$key" false
  notify-send 'Focus mode enabled' 'Notification banners are paused.' 2>/dev/null || true
else
  gsettings set "$schema" "$key" true
  notify-send 'Focus mode disabled' 'Notification banners are enabled.' 2>/dev/null || true
fi