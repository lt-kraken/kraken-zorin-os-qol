#!/usr/bin/env bash
set -Eeuo pipefail

readonly CLIPBOARD_UUID='clipboard-indicator@tudmotu.com'
readonly SEARCH_UUID='search-light@icedman.github.com'
readonly TASKBAR_UUID='zorin-taskbar@zorinos.com'
readonly GNOME_SHELL_SCHEMA='org.gnome.shell'
readonly SHELL_KEYBINDINGS_SCHEMA='org.gnome.shell.keybindings'
readonly TASKBAR_SCHEMA='org.gnome.shell.extensions.zorin-taskbar'

DRY_RUN=false
RELOGIN_REQUIRED=false
BACKUP_DIR=''
SELECTED_BACKUP=''
SELECTED_FEATURES=()
SELECTED_AUDIO_INPUTS=()
SELECTED_AUDIO_OUTPUTS=()
SELECTED_STARTUP_APPS=()
SELECTED_DOCK_POSITION=''
SELECTED_DOCK_SIZE=''
SELECTED_LOCK_DELAY=''
MENU_TAGS=()
MENU_LABELS=()
MENU_STATUSES=()
RADIOLIST_RESULT=''
AUDIO_ENDPOINT_COUNTER=0
declare -A AUDIO_DEVICE_BY_TAG=()
declare -A AUDIO_TOKEN_BY_TAG=()
declare -A AUDIO_LABEL_BY_TAG=()
declare -A SELECTED_INPUT_BY_DEVICE=()
declare -A SELECTED_OUTPUT_BY_DEVICE=()
declare -A STARTUP_APP_BY_TAG=()
declare -A STARTUP_NAME_BY_TAG=()
declare -A STARTUP_LABEL_BY_TAG=()
declare -A SELECTED_FILE_SETTINGS=()

readonly MANAGED_DCONF_PATHS=(
  /org/gnome/shell/
  /org/gnome/desktop/wm/keybindings/
  /org/gnome/settings-daemon/plugins/media-keys/
  /org/gnome/settings-daemon/plugins/color/
  /org/gnome/desktop/screensaver/
  /org/gnome/desktop/session/
  /org/gnome/desktop/notifications/
  /org/gnome/nautilus/preferences/
  /org/gnome/shell/extensions/zorin-taskbar/
  /org/gnome/shell/extensions/zorin-tiling-shell/
  /org/gnome/shell/extensions/clipboard-indicator/
  /org/gnome/shell/extensions/search-light/
)

usage() {
  printf 'Usage: %s [--dry-run]\n' "${0##*/}"
}

case "${1:-}" in
  '') ;;
  --dry-run) DRY_RUN=true ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

HOST_PREFIX=()
if [[ -n "${FLATPAK_ID:-}" ]] && command -v flatpak-spawn >/dev/null 2>&1; then
  HOST_PREFIX=(flatpak-spawn --host)
fi

host() {
  if [[ "${HOST_PREFIX[0]:-}" == flatpak-spawn && "${1:-}" == whiptail ]]; then
    shift
    flatpak-spawn --env="TERM=${TERM:-xterm-256color}" --host whiptail "$@"
    return
  fi
  "${HOST_PREFIX[@]}" "$@"
}

info() {
  printf '==> %s\n' "$*"
}

warn() {
  printf 'Warning: %s\n' "$*" >&2
}

fail() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

host_has() {
  host sh -c 'command -v "$1" >/dev/null 2>&1' sh "$1"
}

show_message() {
  local title=$1
  local message=$2

  if host_has whiptail && [[ -t 0 && -t 1 ]]; then
    host whiptail --title "$title" --msgbox "$message" 12 76
  else
    printf '\n%s\n%s\n' "$title" "$message" >&2
  fi
}

ask_confirmation() {
  local title=$1
  local message=$2
  local answer

  if host_has whiptail && [[ -t 0 && -t 1 ]]; then
    host whiptail --title "$title" --yesno "$message" 12 76
    return
  fi

  printf '\n%s\n%s\nApply these changes? [y/N] ' "$title" "$message" >&2
  read -r answer </dev/tty || return 1
  [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]]
}

show_checklist() {
  local title=$1
  local message=$2
  local answer
  local -a options=()
  local -a chosen=()

  if (( ${#MENU_TAGS[@]} == 0 )); then
    return 1
  fi

  for (( index = 0; index < ${#MENU_TAGS[@]}; index++ )); do
    options+=("${MENU_TAGS[index]}" "${MENU_LABELS[index]}" "${MENU_STATUSES[index]}")
  done

  if host_has whiptail && [[ -t 0 && -t 1 ]]; then
    answer=$(host whiptail --separate-output --title "$title" --checklist \
      "$message" 22 88 14 "${options[@]}" 3>&1 1>&2 2>&3) || return 1
    CHECKLIST_RESULT=$answer
    return 0
  fi

  printf '\n%s\n%s\n' "$title" "$message" >&2
  for (( index = 0; index < ${#MENU_TAGS[@]}; index++ )); do
    local status=' '
    [[ "${MENU_STATUSES[index]}" == ON ]] && status='X'
    printf '  %2d. [%s] %s\n' "$((index + 1))" "$status" \
      "${MENU_LABELS[index]}" >&2
  done
  printf 'Enter numbers to select (comma-separated), blank to keep shown defaults, or q to cancel: ' >&2
  read -r answer </dev/tty || return 1
  [[ "$answer" != q && "$answer" != Q ]] || return 1

  if [[ -n "$answer" ]]; then
    local -a indices=()
    IFS=',' read -r -a indices <<< "$answer"
    for index in "${indices[@]}"; do
      index=${index//[[:space:]]/}
      if [[ "$index" =~ ^[0-9]+$ ]] && (( index >= 1 && index <= ${#MENU_TAGS[@]} )); then
        chosen+=("${MENU_TAGS[index - 1]}")
      fi
    done
    CHECKLIST_RESULT=$(printf '%s\n' "${chosen[@]}")
  else
    for (( index = 0; index < ${#MENU_TAGS[@]}; index++ )); do
      [[ "${MENU_STATUSES[index]}" == ON ]] && chosen+=("${MENU_TAGS[index]}")
    done
    CHECKLIST_RESULT=$(printf '%s\n' "${chosen[@]}")
  fi
}

show_radiolist() {
  local title=$1
  local message=$2
  local answer
  local -a options=()

  if (( ${#MENU_TAGS[@]} == 0 )); then
    return 1
  fi
  for (( index = 0; index < ${#MENU_TAGS[@]}; index++ )); do
    options+=("${MENU_TAGS[index]}" "${MENU_LABELS[index]}" "${MENU_STATUSES[index]}")
  done

  if host_has whiptail && [[ -t 0 && -t 1 ]]; then
    answer=$(host whiptail --title "$title" --radiolist \
      "$message" 20 88 12 "${options[@]}" 3>&1 1>&2 2>&3) || return 1
    RADIOLIST_RESULT=$answer
    return 0
  fi

  printf '\n%s\n%s\n' "$title" "$message" >&2
  for (( index = 0; index < ${#MENU_TAGS[@]}; index++ )); do
    printf '  %2d. %s%s\n' "$((index + 1))" \
      "${MENU_LABELS[index]}" \
      "$([[ ${MENU_STATUSES[index]} == ON ]] && printf ' (current)')" >&2
  done
  printf 'Choose an option number, or q to cancel: ' >&2
  read -r answer </dev/tty || return 1
  [[ "$answer" != q && "$answer" != Q ]] || return 1
  [[ "$answer" =~ ^[0-9]+$ ]] && \
    (( answer >= 1 && answer <= ${#MENU_TAGS[@]} )) || return 1
  RADIOLIST_RESULT=${MENU_TAGS[answer - 1]}
}

feature_selected() {
  local feature=$1
  local selected

  for selected in "${SELECTED_FEATURES[@]}"; do
    [[ "$selected" == "$feature" ]] && return 0
  done
  return 1
}

choose_boolean_setting() {
  local schema=$1
  local key=$2
  local label=$3
  local current

  current=$(host gsettings get "$schema" "$key") || return 1
  MENU_TAGS=(true false)
  MENU_LABELS=(Enabled Disabled)
  if [[ "$current" == true ]]; then
    MENU_STATUSES=(ON OFF)
  else
    MENU_STATUSES=(OFF ON)
  fi
  show_radiolist "$label" 'Choose the setting to use.' || return 1
  SELECTED_FILE_SETTINGS["$schema:$key"]=$RADIOLIST_RESULT
}

select_file_preferences() {
  local current
  local selected_click

  choose_boolean_setting org.gnome.nautilus.preferences show-hidden-files \
    'Show hidden files' || return 1
  choose_boolean_setting org.gnome.nautilus.preferences always-use-location-entry \
    'Always show the location entry' || return 1

  current=$(host gsettings get org.gnome.nautilus.preferences click-policy)
  current=${current//\'/}
  MENU_TAGS=(double single)
  MENU_LABELS=('Double-click to open' 'Single-click to open')
  if [[ "$current" == single ]]; then
    MENU_STATUSES=(OFF ON)
  else
    MENU_STATUSES=(ON OFF)
  fi
  show_radiolist 'Folder click behavior' 'Choose how folders and files open.' || return 1
  selected_click=$RADIOLIST_RESULT
  SELECTED_FILE_SETTINGS[org.gnome.nautilus.preferences:click-policy]=$selected_click
}

select_dock_preferences() {
  local current_position
  local current_size

  current_position=$(host gsettings get "$TASKBAR_SCHEMA" panel-position)
  current_position=${current_position//\'/}
  MENU_TAGS=(BOTTOM LEFT RIGHT TOP)
  MENU_LABELS=('Bottom' 'Left' 'Right' 'Top')
  MENU_STATUSES=(OFF OFF OFF OFF)
  for (( index = 0; index < ${#MENU_TAGS[@]}; index++ )); do
    [[ "${MENU_TAGS[index]}" == "$current_position" ]] && MENU_STATUSES[index]=ON
  done
  show_radiolist 'Dock position' 'Choose where the Zorin dock appears.' || return 1
  SELECTED_DOCK_POSITION=$RADIOLIST_RESULT

  current_size=$(host gsettings get "$TASKBAR_SCHEMA" panel-size)
  MENU_TAGS=(32 40 48 56 64)
  MENU_LABELS=('Compact (32 px)' 'Small (40 px)' 'Medium (48 px)' 'Large (56 px)' 'Extra large (64 px)')
  MENU_STATUSES=(OFF OFF OFF OFF OFF)
  for (( index = 0; index < ${#MENU_TAGS[@]}; index++ )); do
    [[ "${MENU_TAGS[index]}" == "$current_size" ]] && MENU_STATUSES[index]=ON
  done
  show_radiolist 'Dock size' 'Choose the icon and panel size.' || return 1
  SELECTED_DOCK_SIZE=$RADIOLIST_RESULT
}

select_lock_screen_options() {
  local current_delay

  current_delay=$(host gsettings get org.gnome.desktop.session idle-delay)
  current_delay=${current_delay//[^0-9]/}
  MENU_TAGS=(300 600 900 1800)
  MENU_LABELS=('5 minutes' '10 minutes' '15 minutes' '30 minutes')
  MENU_STATUSES=(OFF OFF OFF OFF)
  for (( index = 0; index < ${#MENU_TAGS[@]}; index++ )); do
    [[ "${MENU_TAGS[index]}" == "$current_delay" ]] && MENU_STATUSES[index]=ON
  done
  show_radiolist 'Automatic screen lock' \
    'Choose the idle time before the screen locks. The lock delay is immediate after the screen turns off.' || return 1
  SELECTED_LOCK_DELAY=$RADIOLIST_RESULT
}

startup_app_catalog() {
  host python3 -c '
import configparser
import os
import sys

home = os.path.expanduser("~")
data_home = os.environ.get("XDG_DATA_HOME", os.path.join(home, ".local/share"))
data_dirs = os.environ.get("XDG_DATA_DIRS", "/usr/local/share:/usr/share").split(":")
roots = [
    os.path.join(data_home, "applications"),
    os.path.join(home, ".local/share/flatpak/exports/share/applications"),
    os.path.join(home, ".local/share/applications"),
    *[os.path.join(path, "applications") for path in data_dirs],
    "/var/lib/flatpak/exports/share/applications",
    "/var/lib/snapd/desktop/applications",
]
apps = {}
for root in roots:
    if not os.path.isdir(root):
        continue
    for current, directories, files in os.walk(root):
        directories.sort()
        for filename in sorted(files):
            if not filename.endswith(".desktop"):
                continue
            path = os.path.join(current, filename)
            app_id = filename
            if app_id in apps:
                continue
            parser = configparser.ConfigParser(interpolation=None, strict=False)
            parser.optionxform = str
            try:
                parser.read(path, encoding="utf-8")
                entry = parser["Desktop Entry"]
            except (OSError, KeyError, configparser.Error):
                continue
            if entry.get("Type") != "Application" or not entry.get("Exec"):
                continue
            if entry.get("NoDisplay", "false").lower() == "true":
                continue
            if entry.get("Hidden", "false").lower() == "true":
                continue
            name = entry.get("Name", app_id.removesuffix(".desktop"))
            autostart = os.path.join(home, ".config/autostart", app_id)
            active = "ON" if os.path.lexists(autostart) else "OFF"
            apps[app_id] = (name.replace("\t", " "), path, active)

for app_id, (name, path, active) in sorted(apps.items(), key=lambda item: item[1][0].casefold()):
    print("\t".join((app_id, name, path, active)))
'
}

select_startup_apps() {
  local app_id
  local name
  local path
  local active
  local tag
  local -a selected=()

  MENU_TAGS=()
  MENU_LABELS=()
  MENU_STATUSES=()
  STARTUP_APP_BY_TAG=()
  STARTUP_NAME_BY_TAG=()
  STARTUP_LABEL_BY_TAG=()
  while IFS=$'\t' read -r app_id name path active; do
    [[ -n "$app_id" ]] || continue
    tag="startup_${#MENU_TAGS[@]}"
    MENU_TAGS+=("$tag")
    MENU_LABELS+=("$name")
    MENU_STATUSES+=("$active")
    STARTUP_APP_BY_TAG["$tag"]=$path
    STARTUP_NAME_BY_TAG["$tag"]=$app_id
    STARTUP_LABEL_BY_TAG["$tag"]=$name
  done < <(startup_app_catalog)

  if (( ${#MENU_TAGS[@]} == 0 )); then
    show_message 'No desktop apps found' 'No launchable desktop applications were discovered.'
    return 1
  fi
  show_checklist 'Startup applications' \
    'Select apps to add to your user startup list. Existing entries are preserved.' || return 1
  SELECTED_STARTUP_APPS=()
  while IFS= read -r tag; do
    [[ -n "$tag" ]] && SELECTED_STARTUP_APPS+=("$tag")
  done <<< "$CHECKLIST_RESULT"
}

set_gsetting() {
  local schema=$1
  local key=$2
  local value=$3

  if ! host gsettings list-keys "$schema" >/dev/null 2>&1; then
    warn "GSettings schema is missing: $schema; skipping $key."
    return
  fi
  if ! host gsettings list-keys "$schema" | host grep -Fxq "$key"; then
    warn "Setting is missing from $schema: $key; skipping $key."
    return
  fi

  info "Setting $schema $key"
  if [[ "$DRY_RUN" == false ]]; then
    host gsettings set "$schema" "$key" "$value"
  fi
}

transform_json_setting() {
  local schema=$1
  local key=$2
  local operation=$3
  local current
  local updated

  current=$(host gsettings get "$schema" "$key") || {
    warn "Could not read $schema $key; skipping it."
    return
  }

  updated=$(printf '%s\n' "$current" | host python3 -c '
import ast
import json
import sys

operation = sys.argv[1]
data = json.loads(ast.literal_eval(sys.stdin.read()))

if operation == "hide-taskbar-menus":
    for elements in data.values():
        if isinstance(elements, list):
            for element in elements:
                if element.get("element") in {"systemMenu", "dateMenu"}:
                    element["visible"] = False
elif operation == "dynamic-taskbar-length":
    if isinstance(data, dict):
        for monitor in data:
            data[monitor] = -1
elif operation == "center-taskbar":
    if isinstance(data, dict):
        for monitor in data:
            data[monitor] = "MIDDLE"
else:
    raise SystemExit("Unknown JSON-setting operation")

value = json.dumps(data, separators=(",", ":"))
print("\x27" + value + "\x27")
' "$operation") || {
    warn "Could not process JSON setting $schema $key; skipping it."
    return
  }

  set_gsetting "$schema" "$key" "$updated"
}

backup_current_settings() {
  local host_home
  local timestamp
  local path
  local backup_name

  host_home=$(host printenv HOME)
  timestamp=$(host date -u +%Y%m%dT%H%M%SZ)
  BACKUP_DIR="$host_home/.local/state/zorin-setup/backups/$timestamp"

  host mkdir -p "$BACKUP_DIR"
  if host_has dconf; then
    : > "$BACKUP_DIR/dconf-paths.txt"
    for path in "${MANAGED_DCONF_PATHS[@]}"; do
      backup_name=${path#/}
      backup_name=${backup_name//\//_}
      host dconf dump "$path" > "$BACKUP_DIR/$backup_name.dconf"
      printf '%s\n' "$path" >> "$BACKUP_DIR/dconf-paths.txt"
    done
  else
    warn 'dconf is missing; GNOME settings will not be backed up.'
  fi
  if host_has wpctl; then
    host wpctl status -n > "$BACKUP_DIR/audio-status.txt"
    if host_has pw-dump && host_has pw-cli; then
      audio_devices_snapshot > "$BACKUP_DIR/audio-profiles.tsv"
    fi
  fi
  if host test -f "$host_home/.local/state/zorin-setup/startup-managed.tsv"; then
    host cp "$host_home/.local/state/zorin-setup/startup-managed.tsv" \
      "$BACKUP_DIR/startup-managed.tsv"
  fi

  info "Managed settings backed up to $BACKUP_DIR"
}

select_restore_backup() {
  local host_home
  local backup_root
  local backup_name
  local -a backups=()

  host_home=$(host printenv HOME)
  backup_root="$host_home/.local/state/zorin-setup/backups"
  while IFS= read -r backup_name; do
    [[ -n "$backup_name" ]] && backups+=("$backup_name")
  done < <(host find "$backup_root" -mindepth 1 -maxdepth 1 -type d \
    -printf '%f\n' 2>/dev/null | host sort -r)

  if (( ${#backups[@]} == 0 )); then
    show_message 'No setup backups found' \
      'Run and confirm a setup first. Its pre-change snapshot will appear here.'
    return 1
  fi

  MENU_TAGS=()
  MENU_LABELS=()
  MENU_STATUSES=()
  for backup_name in "${backups[@]}"; do
    MENU_TAGS+=("$backup_name")
    MENU_LABELS+=("$backup_name")
    if (( ${#MENU_TAGS[@]} == 1 )); then
      MENU_STATUSES+=(ON)
    else
      MENU_STATUSES+=(OFF)
    fi
  done
  show_radiolist 'Restore a setup backup' \
    'Choose a timestamped snapshot of the managed settings.' || return 1
  SELECTED_BACKUP="$backup_root/$RADIOLIST_RESULT"
}

restore_backup() {
  local backup_dir=$1
  local host_home
  local path
  local backup_name
  local app_id
  local app_path
  local destination
  local startup_manifest
  local startup_content=''

  host_home=$(host printenv HOME)
  if ! host test -d "$backup_dir"; then
    warn "Backup directory not found: $backup_dir"
    return 1
  fi

  if host test -f "$backup_dir/dconf-paths.txt"; then
    while IFS= read -r path; do
      [[ -n "$path" ]] || continue
      backup_name=${path#/}
      backup_name=${backup_name//\//_}
      info "Restoring settings under $path"
      if [[ "$DRY_RUN" == false ]]; then
        host dconf reset -f "$path"
        host dconf load "$path" < "$backup_dir/$backup_name.dconf"
      fi
    done < "$backup_dir/dconf-paths.txt"
  else
    if host test -f "$backup_dir/gnome-shell.dconf"; then
      info 'Restoring legacy GNOME Shell settings.'
      if [[ "$DRY_RUN" == false ]]; then
        host dconf load /org/gnome/shell/ < "$backup_dir/gnome-shell.dconf"
      fi
    fi
    if host test -f "$backup_dir/window-keybindings.dconf"; then
      info 'Restoring legacy window-manager shortcuts.'
      if [[ "$DRY_RUN" == false ]]; then
        host dconf load /org/gnome/desktop/wm/keybindings/ < \
          "$backup_dir/window-keybindings.dconf"
      fi
    fi
  fi

  if host test -f "$backup_dir/audio-profiles.tsv"; then
    while IFS=$'\t' read -r path backup_name; do
      [[ -n "$path" && -n "$backup_name" ]] || continue
      local device_id
      local profile_index
      device_id=$(device_id_for_description "$path")
      if [[ -z "$device_id" ]]; then
        warn "Audio device not found during restore: $path"
        continue
      fi
      profile_index=$(profile_index_for_name "$device_id" "$backup_name")
      if [[ -z "$profile_index" ]]; then
        warn "Audio profile '$backup_name' is unavailable on '$path'."
        continue
      fi
      info "Restoring audio profile: $path -> $backup_name"
      if [[ "$DRY_RUN" == false ]]; then
        host wpctl set-profile "$device_id" "$profile_index"
      fi
    done < "$backup_dir/audio-profiles.tsv"
  fi

  startup_manifest="$host_home/.local/state/zorin-setup/startup-managed.tsv"
  if host test -f "$startup_manifest"; then
    while IFS=$'\t' read -r app_id app_path; do
      [[ -n "$app_id" && -n "$app_path" ]] || continue
      destination="$host_home/.config/autostart/$app_id"
      if host test -L "$destination" && \
        [[ "$(host readlink "$destination")" == "$app_path" ]]; then
        info "Would remove setup-managed startup app: $app_id"
        if [[ "$DRY_RUN" == false ]]; then
          host rm "$destination"
        fi
      fi
    done < "$startup_manifest"
  fi
  if host test -f "$backup_dir/startup-managed.tsv"; then
    while IFS=$'\t' read -r app_id app_path; do
      [[ -n "$app_id" && -n "$app_path" ]] || continue
      destination="$host_home/.config/autostart/$app_id"
      if ! host test -e "$destination" && ! host test -L "$destination"; then
        info "Would restore startup app: $app_id"
        if [[ "$DRY_RUN" == false ]]; then
          host mkdir -p "$host_home/.config/autostart"
          host ln -s "$app_path" "$destination"
        fi
      else
        warn "Startup entry already exists and will be preserved: $app_id"
      fi
      startup_content+="$app_id"$'\t'"$app_path"$'\n'
    done < "$backup_dir/startup-managed.tsv"
    if [[ "$DRY_RUN" == false ]]; then
      printf '%s' "$startup_content" | host install -D -m 600 /dev/stdin "$startup_manifest"
    fi
  elif [[ "$DRY_RUN" == false ]]; then
    host rm -f "$startup_manifest"
  fi

  if [[ "$DRY_RUN" == false ]]; then
    info 'Managed settings restored. Locally installed apps are not removed.'
  fi
}

extension_supports_shell() {
  local metadata_file=$1
  local shell_major=$2

  host python3 -c '
import json
import sys

with open(sys.argv[1], encoding="utf-8") as metadata_file:
    metadata = json.load(metadata_file)
raise SystemExit(0 if sys.argv[2] in metadata.get("shell-version", []) else 1)
' "$metadata_file" "$shell_major"
}

install_extension_if_needed() {
  local uuid=$1
  local shell_major=$2
  local host_home
  local extension_dir
  local metadata_file
  local api_response
  local download_url
  local archive

  host_home=$(host printenv HOME)
  extension_dir="$host_home/.local/share/gnome-shell/extensions/$uuid"
  metadata_file="$extension_dir/metadata.json"

  if host test -f "$metadata_file" && \
    extension_supports_shell "$metadata_file" "$shell_major"; then
    info "Extension is already installed and supports GNOME $shell_major: $uuid"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "Would install GNOME extension: $uuid"
    return
  fi

  api_response=$(host curl -fLsSG --max-time 45 \
    --data-urlencode "uuid=$uuid" \
    --data-urlencode "shell_version=$shell_major" \
    'https://extensions.gnome.org/extension-info/') || \
    fail "Could not retrieve compatible extension metadata: $uuid"

  download_url=$(printf '%s' "$api_response" | host python3 -c '
import json
import sys

data = json.load(sys.stdin)
shell_major = sys.argv[1]
if shell_major not in data.get("shell_version_map", {}):
  raise SystemExit("No version is available for this GNOME Shell release")
print(data["download_url"])
' "$shell_major") || fail "No GNOME $shell_major version found for $uuid"

  host_home=$(host printenv HOME)
  host mkdir -p "$host_home/.cache/zorin-setup/extensions"
  archive="$host_home/.cache/zorin-setup/extensions/$uuid.zip"
  host curl -fLsS --max-time 60 \
    "https://extensions.gnome.org$download_url" -o "$archive" || \
    fail "Could not download extension: $uuid"
  host gnome-extensions install --force "$archive" || \
    fail "Could not install extension: $uuid"
  RELOGIN_REQUIRED=true
}

enable_extension() {
  local uuid=$1
  local current
  local updated

  current=$(host gsettings get "$GNOME_SHELL_SCHEMA" enabled-extensions)
  updated=$(printf '%s\n%s\n' "$current" "$uuid" | host python3 -c '
import ast
import sys

extensions = ast.literal_eval(sys.stdin.readline())
uuid = sys.stdin.readline().strip()
if uuid not in extensions:
    extensions.append(uuid)
print("[" + ", ".join(repr(extension) for extension in extensions) + "]")
')

  info "Enable in the next GNOME session: $uuid"
  if [[ "$DRY_RUN" == false ]]; then
    host gsettings set "$GNOME_SHELL_SCHEMA" enabled-extensions "$updated"
  fi
}

set_extension_gsetting() {
  local uuid=$1
  local schema=$2
  local key=$3
  local value=$4
  local host_home
  local extension_dir
  local available_keys

  if [[ "$DRY_RUN" == true ]]; then
    info "Would set extension setting: $schema $key"
    return
  fi

  host_home=$(host printenv HOME)
  extension_dir="$host_home/.local/share/gnome-shell/extensions/$uuid"
  if ! host test -f "$extension_dir/schemas/gschemas.compiled"; then
    warn "Extension schema is missing for $uuid; skipping $key."
    return
  fi
  available_keys=$(host gsettings --schemadir "$extension_dir/schemas" \
    list-keys "$schema" 2>/dev/null) || {
    warn "Could not read extension schema for $uuid; skipping $key."
    return
  }
  if ! printf '%s\n' "$available_keys" | host grep -Fxq "$key"; then
    warn "Setting $key does not exist in $uuid; skipping it."
    return
  fi

  info "Setting $schema $key"
  host gsettings --schemadir "$extension_dir/schemas" \
    set "$schema" "$key" "$value"
}

audio_catalog() {
  local direction=$1

  host pw-dump | host python3 -c '
import json
import re
import subprocess
import sys

direction = sys.argv[1]
prefix = direction + ":"
objects = json.load(sys.stdin)

def profile_blocks(text):
    blocks = re.split(r"(?=  Object: size \d+, type Spa:Pod:Object:Param:Profile)", text)
    profiles = []
    for block in blocks:
        name_match = re.search(r"Profile:name.*?\n\s+String \"([^\"]+)\"", block, re.S)
        if not name_match:
            continue
        name = name_match.group(1)
        available_match = re.search(r"ParamAvailability:(yes|no|unknown)", block)
        availability = available_match.group(1) if available_match else "unknown"
        if availability == "no":
            continue
        profiles.append(name)
    return profiles

def friendly(token):
    name = token.split(":", 1)[1]
    if direction == "output":
        if name == "analog-stereo":
            return "Analog Stereo Output"
        if name == "iec958-stereo":
            return "Digital Output (S/PDIF)"
        match = re.fullmatch(r"hdmi-stereo-extra(\d+)", name)
        if name == "hdmi-stereo":
            return "HDMI/DisplayPort Output 1"
        if match:
            return f"HDMI/DisplayPort Output {int(match.group(1)) + 1}"
        return name.replace("-", " ").title() + " Output"
    if name == "analog-stereo":
        return "Microphone (Analog Stereo)"
    if name == "mono-fallback":
        return "Microphone (Mono)"
    if name == "iec958-stereo":
        return "Digital Input (S/PDIF)"
    return name.replace("-", " ").title() + " Input"

for obj in objects:
    if obj.get("type") != "PipeWire:Interface:Device":
        continue
    props = obj.get("info", {}).get("props", {})
    if props.get("media.class") != "Audio/Device":
        continue
    device_id = obj["id"]
    description = props.get("device.description", props.get("device.name", str(device_id)))
    enum_result = subprocess.run(
        ["pw-cli", "enum-params", str(device_id), "EnumProfile"],
        capture_output=True, text=True, check=False)
    profiles = profile_blocks(enum_result.stdout)
    current_result = subprocess.run(
        ["pw-cli", "enum-params", str(device_id), "Profile"],
        capture_output=True, text=True, check=False)
    current_match = re.search(r"Profile:name.*?\n\s+String \"([^\"]+)\"", current_result.stdout, re.S)
    current_profile = current_match.group(1).split("+") if current_match else []

    endpoints = {}
    for profile in profiles:
        for token in profile.split("+"):
            if token.startswith(prefix):
                endpoints.setdefault(token, None)

    for token in sorted(endpoints):
        active = "ON" if token in current_profile else "OFF"
        print("\t".join((str(device_id), description, token,
                         description + " - " + friendly(token), active)))
' "$direction"
}

current_profile_name() {
  local device_id=$1

  host pw-cli enum-params "$device_id" Profile | host awk '
    /Profile:name/ { getline; name = $2; gsub(/"/, "", name) }
    /Profile:description/ { getline; print name; exit }
  '
}

audio_devices_snapshot() {
  host pw-dump | host python3 -c '
import json
import sys

for obj in json.load(sys.stdin):
    if obj.get("type") != "PipeWire:Interface:Device":
        continue
    props = obj.get("info", {}).get("props", {})
    if props.get("media.class") == "Audio/Device":
        print(str(obj["id"]) + "\t" + props.get("device.description", props.get("device.name", "")))
' | while IFS=$'\t' read -r device_id description; do
    [[ -n "$device_id" && -n "$description" ]] || continue
    printf '%s\t%s\n' "$description" "$(current_profile_name "$device_id")"
  done
}

profile_index_for_name() {
  local device_id=$1
  local profile_name=$2

  host pw-cli enum-params "$device_id" EnumProfile | host awk \
    -v wanted="$profile_name" '
      /Profile:index/ { getline; index_value = $2 }
      /Profile:name/ {
        getline
        name = $2
        gsub(/"/, "", name)
        if (name == wanted) {
          print index_value
          exit
        }
      }
    '
}

profile_for_tokens() {
  local device_id=$1
  local output_token=$2
  local input_token=$3

  host pw-cli enum-params "$device_id" EnumProfile | host python3 -c '
import re
import sys

output_token, input_token = sys.argv[1:]
text = sys.stdin.read()
blocks = re.split(r"(?=  Object: size \d+, type Spa:Pod:Object:Param:Profile)", text)
matches = []
for block in blocks:
    name_match = re.search(r"Profile:name.*?\n\s+String \"([^\"]+)\"", block, re.S)
    if not name_match:
        continue
    name = name_match.group(1)
    availability_match = re.search(r"ParamAvailability:(yes|no|unknown)", block)
    availability = availability_match.group(1) if availability_match else "unknown"
    if availability == "no":
        continue
    if name == "off":
        outputs = inputs = None
    else:
        parts = name.split("+")
        outputs = next((part for part in parts if part.startswith("output:")), None)
        inputs = next((part for part in parts if part.startswith("input:")), None)
    if outputs == (output_token or None) and inputs == (input_token or None):
        matches.append((availability != "yes", name))
if matches:
    print(sorted(matches)[0][1])
' "$output_token" "$input_token"
}

select_features() {
  local feature
  local -a features=(
    topbar audio-output audio-input shortcuts clipboard spotlight focus night-light
    localsend files window-tiling lock-screen clipboard-privacy startup-apps
    dock-preferences restore
  )
  local -a labels=(
    'macOS-style top bar and Zorin dock'
    'Limit audio output devices'
    'Limit audio input devices'
    'Windows-style screenshot shortcut (Super+Shift+S)'
    'Clipboard history (Super+V)'
    'Spotlight-style search (Super+Space)'
    'Focus mode toggle (Super+Shift+F)'
    'Night Light schedule'
    'LocalSend for iPhone file sharing'
    'Files preferences'
    'Window tiling and workspaces'
    'Lock screen and idle timeout'
    'Clipboard privacy (clear on login)'
    'Add startup applications'
    'Dock position and size'
    'Restore a previous setup backup'
  )

  MENU_TAGS=("${features[@]}")
  MENU_LABELS=("${labels[@]}")
  MENU_STATUSES=()
  for feature in "${features[@]}"; do
    MENU_STATUSES+=(OFF)
  done
  show_checklist 'Zorin Personal Setup' \
    'Select the features to configure. Unselected features will be left unchanged.' || \
    return 1

  SELECTED_FEATURES=()
  while IFS= read -r feature; do
    [[ -n "$feature" ]] && SELECTED_FEATURES+=("$feature")
  done <<< "$CHECKLIST_RESULT"
}

select_audio_endpoints() {
  local direction=$1
  local line
  local device_id
  local description
  local token
  local label
  local active
  local tag
  local -a selected_tags=()
  local -A selected_by_device=()
  local -A tokens_by_device=()

  if ! host_has wpctl || ! host_has pw-cli || ! host_has pw-dump || \
    ! host_has python3; then
    warn 'PipeWire tools are missing; audio selection is unavailable.'
    return 1
  fi

  MENU_TAGS=()
  MENU_LABELS=()
  MENU_STATUSES=()
  while IFS=$'\t' read -r device_id description token label active; do
    [[ -n "$device_id" ]] || continue
    tag="endpoint_${AUDIO_ENDPOINT_COUNTER}"
    ((AUDIO_ENDPOINT_COUNTER += 1))
    MENU_TAGS+=("$tag")
    MENU_LABELS+=("$label")
    MENU_STATUSES+=("$active")
    AUDIO_DEVICE_BY_TAG["$tag"]=$device_id
    AUDIO_TOKEN_BY_TAG["$tag"]=$token
    AUDIO_LABEL_BY_TAG["$tag"]=$label
  done < <(audio_catalog "$direction")

  if (( ${#MENU_TAGS[@]} == 0 )); then
    warn "No supported audio $direction profiles were found."
    return 1
  fi

  if [[ "$direction" == output ]]; then
    label='Select the output profiles to keep. Unselected profiles will be disabled.'
  else
    label='Select the input profiles to keep. Unselected profiles will be disabled.'
  fi
  if [[ "$direction" == output ]]; then
    show_checklist 'Limit Audio Outputs' "$label" || return 1
  else
    show_checklist 'Limit Audio Inputs' "$label" || return 1
  fi

  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    device_id=${AUDIO_DEVICE_BY_TAG[$tag]}
    token=${AUDIO_TOKEN_BY_TAG[$tag]}
    if [[ -n "${selected_by_device[$device_id]:-}" ]]; then
      show_message 'Choose one profile per audio device' \
        "${AUDIO_LABEL_BY_TAG[$tag]} and another selected option belong to the same audio device. Choose at most one $direction profile per device."
      return 1
    fi
    selected_by_device[$device_id]=$tag
    tokens_by_device[$device_id]=$token
    selected_tags+=("$tag")
  done <<< "$CHECKLIST_RESULT"

  if (( ${#selected_tags[@]} == 0 )); then
    show_message 'No audio device selected' \
      "At least one $direction must remain enabled. No audio profiles will be changed."
    return 1
  fi

  if [[ "$direction" == output ]]; then
    SELECTED_AUDIO_OUTPUTS=("${selected_tags[@]}")
    SELECTED_OUTPUT_BY_DEVICE=()
    for device_id in "${!tokens_by_device[@]}"; do
      SELECTED_OUTPUT_BY_DEVICE[$device_id]=${tokens_by_device[$device_id]}
    done
  else
    SELECTED_AUDIO_INPUTS=("${selected_tags[@]}")
    SELECTED_INPUT_BY_DEVICE=()
    for device_id in "${!tokens_by_device[@]}"; do
      SELECTED_INPUT_BY_DEVICE[$device_id]=${tokens_by_device[$device_id]}
    done
  fi
}

build_audio_plan() {
  local device_id
  local description
  local output_token
  local input_token
  local target_profile
  local current_profile
  local profile_index

  AUDIO_PLAN_IDS=()
  AUDIO_PLAN_DESCRIPTIONS=()
  AUDIO_PLAN_PROFILES=()
  AUDIO_PLAN_PROFILE_INDICES=()

  while IFS=$'\t' read -r device_id description; do
    [[ -n "$device_id" ]] || continue
    current_profile=$(current_profile_name "$device_id")
    output_token=''
    input_token=''

    if feature_selected audio-output; then
      output_token=${SELECTED_OUTPUT_BY_DEVICE[$device_id]:-}
    else
      for component in ${current_profile//+/ }; do
        [[ "$component" == output:* ]] && output_token=$component
      done
    fi
    if feature_selected audio-input; then
      input_token=${SELECTED_INPUT_BY_DEVICE[$device_id]:-}
    else
      for component in ${current_profile//+/ }; do
        [[ "$component" == input:* ]] && input_token=$component
      done
    fi

    target_profile=$(profile_for_tokens "$device_id" "$output_token" "$input_token")
    if [[ -z "$target_profile" ]]; then
      warn "Could not find a profile to safely apply the selection for '$description'. Nothing was changed."
      return 1
    fi
    profile_index=$(profile_index_for_name "$device_id" "$target_profile")
    if [[ -z "$profile_index" ]]; then
      warn "Profile '$target_profile' is unavailable on '$description'. Nothing was changed."
      return 1
    fi

    AUDIO_PLAN_IDS+=("$device_id")
    AUDIO_PLAN_DESCRIPTIONS+=("$description")
    AUDIO_PLAN_PROFILES+=("$target_profile")
    AUDIO_PLAN_PROFILE_INDICES+=("$profile_index")
  done < <(host pw-dump | host python3 -c '
import json
import sys

for obj in json.load(sys.stdin):
    if obj.get("type") != "PipeWire:Interface:Device":
        continue
    props = obj.get("info", {}).get("props", {})
    if props.get("media.class") == "Audio/Device":
        print(str(obj["id"]) + "\t" + props.get("device.description", props.get("device.name", str(obj["id"]))))
')
}

apply_audio_plan() {
  local index
  local device_id
  local target_profile
  local profile_index

  for (( index = 0; index < ${#AUDIO_PLAN_IDS[@]}; index++ )); do
    device_id=${AUDIO_PLAN_IDS[index]}
    target_profile=${AUDIO_PLAN_PROFILES[index]}
    profile_index=${AUDIO_PLAN_PROFILE_INDICES[index]}
    if [[ -z "$profile_index" ]]; then
      warn "Profile '$target_profile' is no longer available on device $device_id."
      return 1
    fi
    if [[ "$DRY_RUN" == true ]]; then
      info "Would set audio profile: ${AUDIO_PLAN_DESCRIPTIONS[index]} -> $target_profile"
    else
      info "Audio profile: ${AUDIO_PLAN_DESCRIPTIONS[index]} -> $target_profile"
      host wpctl set-profile "$device_id" "$profile_index"
    fi
  done
}

apply_startup_apps() {
  local host_home
  local config_dir
  local manifest
  local app_id
  local app_path
  local destination
  local old_path
  local tag
  local content=''
  local -A selected_ids=()
  local -A previously_managed=()

  host_home=$(host printenv HOME)
  config_dir="$host_home/.config/autostart"
  manifest="$host_home/.local/state/zorin-setup/startup-managed.tsv"
  for tag in "${SELECTED_STARTUP_APPS[@]}"; do
    selected_ids["${STARTUP_NAME_BY_TAG[$tag]}"]=1
  done

  if [[ "$DRY_RUN" == true ]]; then
    for tag in "${SELECTED_STARTUP_APPS[@]}"; do
      info "Would add startup app: ${STARTUP_LABEL_BY_TAG[$tag]}"
    done
    return
  fi

  if host test -f "$manifest"; then
    while IFS=$'\t' read -r app_id old_path; do
      [[ -n "$app_id" && -n "$old_path" ]] || continue
      previously_managed["$app_id"]=$old_path
      if [[ -z "${selected_ids[$app_id]:-}" ]]; then
        destination="$config_dir/$app_id"
        if host test -L "$destination" && \
          [[ "$(host readlink "$destination")" == "$old_path" ]]; then
          host rm "$destination"
          info "Removed setup-managed startup app: $app_id"
        fi
      fi
    done < "$manifest"
  fi

  for tag in "${SELECTED_STARTUP_APPS[@]}"; do
    app_id=${STARTUP_NAME_BY_TAG[$tag]}
    app_path=${STARTUP_APP_BY_TAG[$tag]}
    destination="$config_dir/$app_id"
    if host test -e "$destination" && ! host test -L "$destination"; then
      warn "Existing startup entry was left unchanged: $app_id"
      continue
    fi
    if host test -L "$destination" && \
      [[ "$(host readlink "$destination")" != "$app_path" ]]; then
      warn "Existing startup link was left unchanged: $app_id"
      continue
    fi
    if ! host test -e "$destination" && ! host test -L "$destination"; then
      host mkdir -p "$config_dir"
      host ln -s "$app_path" "$destination"
      info "Added startup app: ${STARTUP_LABEL_BY_TAG[$tag]}"
      content+="$app_id"$'\t'"$app_path"$'\n'
    elif [[ "${previously_managed[$app_id]:-}" == "$app_path" ]] && \
      host test -L "$destination" && \
      [[ "$(host readlink "$destination")" == "$app_path" ]]; then
      content+="$app_id"$'\t'"$app_path"$'\n'
    fi
  done

  if [[ "$DRY_RUN" == false ]]; then
    printf '%s' "$content" | host install -D -m 600 /dev/stdin "$manifest"
  fi
}

setup_focus_shortcut() {
  local host_home
  local script_dir
  local helper_source
  local helper_target
  local shortcut_path='/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/zorin-focus-toggle/'
  local current
  local updated
  local binding='<Super><Shift>f'

  host_home=$(host printenv HOME)
  script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
  helper_source="$script_dir/toggle-focus-mode.sh"
  helper_target="$host_home/.local/bin/zorin-toggle-focus"
  if ! host test -f "$helper_source"; then
    warn "Focus toggle helper not found: $helper_source"
    return
  fi
  info "Install Focus mode toggle at $helper_target ($binding)"
  if [[ "$DRY_RUN" == true ]]; then
    return
  fi

  host install -D -m 755 "$helper_source" "$helper_target"
  current=$(host gsettings get org.gnome.settings-daemon.plugins.media-keys \
    custom-keybindings)
  updated=$(printf '%s\n%s\n' "$current" "$shortcut_path" | host python3 -c '
import ast
import sys

paths = ast.literal_eval(sys.stdin.readline())
path = sys.stdin.readline().strip()
if path not in paths:
    paths.append(path)
print("[" + ", ".join(repr(item) for item in paths) + "]")
')
  host gsettings set org.gnome.settings-daemon.plugins.media-keys \
    custom-keybindings "$updated"
  host gsettings --path="$shortcut_path" \
    set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding name \
    "'Focus mode'"
  host gsettings --path="$shortcut_path" \
    set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding command \
    "'$helper_target'"
  host gsettings --path="$shortcut_path" \
    set org.gnome.settings-daemon.plugins.media-keys.custom-keybinding binding \
    "'$binding'"
}

install_localsend() {
  if ! host_has flatpak; then
    warn 'Flatpak is not installed; skipping LocalSend.'
    return
  fi
  if host flatpak info --user org.localsend.localsend_app >/dev/null 2>&1 || \
    host flatpak info --system org.localsend.localsend_app >/dev/null 2>&1; then
    info 'LocalSend is already installed.'
    return
  fi
  info 'Install LocalSend as a per-user Flatpak.'
  if [[ "$DRY_RUN" == true ]]; then
    return
  fi
  if ! host flatpak remotes --columns=name | host grep -Fxq flathub; then
    host flatpak remote-add --user --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo
  fi
  host flatpak install --user --noninteractive --assumeyes \
    flathub org.localsend.localsend_app
}

print_selection_summary() {
  local feature
  local tag
  local summary=''

  for feature in "${SELECTED_FEATURES[@]}"; do
    case "$feature" in
      topbar) summary+=$'\n- macOS-style top bar and Zorin dock' ;;
      audio-output) summary+=$'\n- Limit audio outputs' ;;
      audio-input) summary+=$'\n- Limit audio inputs' ;;
      shortcuts) summary+=$'\n- Windows-style screenshot shortcuts' ;;
      clipboard) summary+=$'\n- Clipboard history' ;;
      spotlight) summary+=$'\n- Spotlight-style search' ;;
      focus) summary+=$'\n- Focus mode toggle (Super+Shift+F)' ;;
      night-light) summary+=$'\n- Night Light with automatic schedule' ;;
      localsend) summary+=$'\n- Install LocalSend for this user' ;;
      files) summary+=$'\n- Files preferences' ;;
      window-tiling) summary+=$'\n- Zorin window tiling shortcuts' ;;
      lock-screen) summary+=$'\n- Lock screen and idle timeout' ;;
      clipboard-privacy) summary+=$'\n- Clear clipboard history at login' ;;
      startup-apps) summary+=$'\n- Add selected startup applications' ;;
      dock-preferences) summary+=$'\n- Dock position and size' ;;
    esac
  done

  if feature_selected audio-output; then
    summary+=$'\n\nOutputs to keep:'
    for tag in "${SELECTED_AUDIO_OUTPUTS[@]}"; do
      summary+=$'\n- '
      summary+=${AUDIO_LABEL_BY_TAG[$tag]}
    done
  fi
  if feature_selected audio-input; then
    summary+=$'\n\nInputs to keep:'
    for tag in "${SELECTED_AUDIO_INPUTS[@]}"; do
      summary+=$'\n- '
      summary+=${AUDIO_LABEL_BY_TAG[$tag]}
    done
  fi
  if feature_selected files; then
    summary+=$'\n\nFiles preferences:'
    for setting in \
      org.gnome.nautilus.preferences:show-hidden-files \
      org.gnome.nautilus.preferences:always-use-location-entry \
      org.gnome.nautilus.preferences:click-policy; do
      summary+=$'\n- '
      summary+="$setting = ${SELECTED_FILE_SETTINGS[$setting]}"
    done
  fi
  if feature_selected dock-preferences; then
    summary+=$'\n\nDock: '
    summary+="$SELECTED_DOCK_POSITION, $SELECTED_DOCK_SIZE px"
  fi
  if feature_selected lock-screen; then
    summary+=$'\n\nLock after inactivity: '
    summary+="$((SELECTED_LOCK_DELAY / 60)) minutes"
  fi
  if feature_selected startup-apps; then
    summary+=$'\n\nStartup apps to enable:'
    for tag in "${SELECTED_STARTUP_APPS[@]}"; do
      summary+=$'\n- '
      summary+=${STARTUP_LABEL_BY_TAG[$tag]}
    done
    if (( ${#SELECTED_STARTUP_APPS[@]} == 0 )); then
      summary+=$'\n- None (remove only setup-managed startup links)'
    fi
  fi
  printf '%s' "$summary"
}

apply_selected_features() {
  local shell_version
  local shell_major

  shell_version=$(host gnome-shell --version | host awk '{print $3}')
  shell_major=${shell_version%%.*}

  if feature_selected clipboard || feature_selected clipboard-privacy; then
    install_extension_if_needed "$CLIPBOARD_UUID" "$shell_major"
    enable_extension "$CLIPBOARD_UUID"
  fi

  if feature_selected clipboard; then
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator history-size 25
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator cache-only-favorites true
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator cache-images false
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator toggle-menu "['<Super>v']"
  fi

  if feature_selected clipboard-privacy; then
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator cache-only-favorites true
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator cache-images false
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator clear-on-boot true
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator show-private-mode true
  fi

  if feature_selected spotlight; then
    install_extension_if_needed "$SEARCH_UUID" "$shell_major"
    enable_extension "$SEARCH_UUID"
    set_extension_gsetting "$SEARCH_UUID" \
      org.gnome.shell.extensions.search-light shortcut-search "['<Super>space']"
    set_extension_gsetting "$SEARCH_UUID" \
      org.gnome.shell.extensions.search-light popup-at-cursor-monitor true
    set_extension_gsetting "$SEARCH_UUID" \
      org.gnome.shell.extensions.search-light show-panel-icon true
    set_gsetting org.gnome.desktop.wm.keybindings switch-input-source \
      "['<Super><Alt>space', 'XF86Keyboard']"
  fi

  if feature_selected focus; then
    setup_focus_shortcut
  fi

  if feature_selected night-light; then
    set_gsetting org.gnome.settings-daemon.plugins.color night-light-schedule-automatic true
    set_gsetting org.gnome.settings-daemon.plugins.color night-light-enabled true
  fi

  if feature_selected localsend; then
    install_localsend
  fi

  if feature_selected files; then
    set_gsetting org.gnome.nautilus.preferences show-hidden-files \
      "${SELECTED_FILE_SETTINGS[org.gnome.nautilus.preferences:show-hidden-files]}"
    set_gsetting org.gnome.nautilus.preferences always-use-location-entry \
      "${SELECTED_FILE_SETTINGS[org.gnome.nautilus.preferences:always-use-location-entry]}"
    set_gsetting org.gnome.nautilus.preferences click-policy \
      "'${SELECTED_FILE_SETTINGS[org.gnome.nautilus.preferences:click-policy]}'"
  fi

  if feature_selected window-tiling; then
    set_gsetting org.gnome.shell.extensions.zorin-tiling-shell enable-tiling-system true
    set_gsetting org.gnome.shell.extensions.zorin-tiling-shell enable-move-keybindings true
    set_gsetting org.gnome.mutter dynamic-workspaces true
  fi

  if feature_selected lock-screen; then
    set_gsetting org.gnome.desktop.screensaver lock-enabled true
    set_gsetting org.gnome.desktop.screensaver lock-delay 'uint32 0'
    set_gsetting org.gnome.desktop.session idle-delay "uint32 $SELECTED_LOCK_DELAY"
  fi

  if feature_selected clipboard-privacy; then
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator clear-on-boot true
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator show-private-mode true
  fi

  if feature_selected startup-apps; then
    apply_startup_apps
  fi

  if feature_selected dock-preferences; then
    enable_extension "$TASKBAR_UUID"
    set_gsetting "$TASKBAR_SCHEMA" panel-position "'$SELECTED_DOCK_POSITION'"
    set_gsetting "$TASKBAR_SCHEMA" panel-size "$SELECTED_DOCK_SIZE"
  fi

  if feature_selected topbar; then
    enable_extension "$TASKBAR_UUID"
    set_gsetting "$TASKBAR_SCHEMA" stockgs-keep-top-panel true
    set_gsetting "$TASKBAR_SCHEMA" panel-position "'BOTTOM'"
    transform_json_setting "$TASKBAR_SCHEMA" panel-lengths dynamic-taskbar-length
    transform_json_setting "$TASKBAR_SCHEMA" panel-anchors center-taskbar
    transform_json_setting "$TASKBAR_SCHEMA" panel-element-positions hide-taskbar-menus
  fi

  if feature_selected shortcuts; then
    set_gsetting "$SHELL_KEYBINDINGS_SCHEMA" show-screenshot-ui \
      "['Print', '<Super><Shift>s']"
    set_gsetting "$SHELL_KEYBINDINGS_SCHEMA" toggle-message-tray "['<Super>m']"
  fi

  if feature_selected audio-output || feature_selected audio-input; then
    apply_audio_plan
  fi
}

main() {
  local os_id
  local shell_version
  local shell_major
  local summary

  host_has gsettings || fail 'gsettings is required.'
  host_has python3 || fail 'python3 is required.'

  os_id=$(host sh -c '. /etc/os-release; printf "%s" "$ID"')
  [[ "$os_id" == zorin ]] || fail 'This script is intended for Zorin OS.'
  shell_version=$(host gnome-shell --version | host awk '{print $3}')
  shell_major=${shell_version%%.*}
  [[ "$shell_major" =~ ^[0-9]+$ ]] || fail 'Could not determine the GNOME version.'

  if ! select_features; then
    info 'Setup cancelled; no settings were changed.'
    exit 0
  fi
  if (( ${#SELECTED_FEATURES[@]} == 0 )); then
    info 'No features selected; no settings were changed.'
    exit 0
  fi

  if feature_selected restore; then
    if (( ${#SELECTED_FEATURES[@]} != 1 )); then
      show_message 'Restore must be selected alone' \
        'Choose Restore a previous setup backup by itself, then run the setup again for other features.'
      exit 0
    fi
    if ! select_restore_backup; then
      info 'Backup selection cancelled; no settings were changed.'
      exit 0
    fi
    summary="Restore managed settings from ${SELECTED_BACKUP##*/}. Locally installed apps will not be removed."
    if ! ask_confirmation 'Confirm settings restore' "$summary"; then
      info 'Restore cancelled; no settings were changed.'
      exit 0
    fi
    if [[ "$DRY_RUN" == false ]]; then
      backup_current_settings
    else
      info 'Dry run: no changes will be saved.'
    fi
    restore_backup "$SELECTED_BACKUP"
    if [[ "$DRY_RUN" == true ]]; then
      info 'Dry run complete; no settings were changed.'
    fi
    exit 0
  fi

  if feature_selected audio-output && ! select_audio_endpoints output; then
    info 'Audio output selection cancelled; no settings were changed.'
    exit 0
  fi
  if feature_selected audio-input && ! select_audio_endpoints input; then
    info 'Audio input selection cancelled; no settings were changed.'
    exit 0
  fi
  if feature_selected audio-output || feature_selected audio-input; then
    build_audio_plan || exit 1
  fi
  if feature_selected files && ! select_file_preferences; then
    info 'Files preference selection cancelled; no settings were changed.'
    exit 0
  fi
  if feature_selected dock-preferences && ! select_dock_preferences; then
    info 'Dock preference selection cancelled; no settings were changed.'
    exit 0
  fi
  if feature_selected lock-screen && ! select_lock_screen_options; then
    info 'Lock screen selection cancelled; no settings were changed.'
    exit 0
  fi
  if feature_selected startup-apps && ! select_startup_apps; then
    info 'Startup app selection cancelled; no settings were changed.'
    exit 0
  fi

  summary=$(print_selection_summary)
  if [[ "$DRY_RUN" == true ]]; then
    info "Dry run: Zorin OS, GNOME $shell_version; no changes will be saved."
    if ! ask_confirmation 'Review selected changes' "$summary"; then
      info 'Review cancelled; no settings were changed.'
      exit 0
    fi
    apply_selected_features
    info 'Dry run complete; no settings were changed.'
    exit 0
  fi

  if ! ask_confirmation 'Confirm Zorin setup' "$summary"; then
    info 'Setup cancelled; no settings were changed.'
    exit 0
  fi

  info "Applying configuration to Zorin OS with GNOME $shell_version"
  backup_current_settings
  if feature_selected topbar || feature_selected clipboard || feature_selected spotlight || \
    feature_selected window-tiling || feature_selected dock-preferences; then
    host_has gnome-extensions || fail 'gnome-extensions is required.'
  fi
  if feature_selected clipboard || feature_selected clipboard-privacy || feature_selected spotlight; then
    host_has curl || fail 'curl is required to download GNOME extensions.'
  fi
  apply_selected_features

  if [[ "$RELOGIN_REQUIRED" == true ]]; then
    info 'Log out and back in to load newly installed extensions.'
  else
    info 'Done. Restart GNOME or log back in if an extension is not active yet.'
  fi
}

main "$@"