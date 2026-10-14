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
SELECTED_FEATURES=()
SELECTED_AUDIO_INPUTS=()
SELECTED_AUDIO_OUTPUTS=()
MENU_TAGS=()
MENU_LABELS=()
MENU_STATUSES=()
AUDIO_ENDPOINT_COUNTER=0
declare -A AUDIO_DEVICE_BY_TAG=()
declare -A AUDIO_TOKEN_BY_TAG=()
declare -A AUDIO_LABEL_BY_TAG=()
declare -A SELECTED_INPUT_BY_DEVICE=()
declare -A SELECTED_OUTPUT_BY_DEVICE=()

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

  printf '\n%s\n%s\nDeze wijzigingen toepassen? [j/N] ' "$title" "$message" >&2
  read -r answer </dev/tty || return 1
  [[ "$answer" == [jJ] || "$answer" == [jJ][aA] ]]
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

feature_selected() {
  local feature=$1
  local selected

  for selected in "${SELECTED_FEATURES[@]}"; do
    [[ "$selected" == "$feature" ]] && return 0
  done
  return 1
}

set_gsetting() {
  local schema=$1
  local key=$2
  local value=$3

  if ! host gsettings list-keys "$schema" >/dev/null 2>&1; then
    warn "GSettings-schema ontbreekt: $schema; $key overgeslagen."
    return
  fi
  if ! host gsettings list-keys "$schema" | host grep -Fxq "$key"; then
    warn "Instelling ontbreekt in $schema: $key; overgeslagen."
    return
  fi

  info "Instellen: $schema $key"
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
    warn "Kan $schema $key niet lezen; overgeslagen."
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
    warn "Kan JSON-instelling $schema $key niet verwerken; overgeslagen."
    return
  }

  set_gsetting "$schema" "$key" "$updated"
}

backup_current_settings() {
  local host_home
  local timestamp
  local backup_dir

  host_home=$(host printenv HOME)
  timestamp=$(host date -u +%Y%m%dT%H%M%SZ)
  backup_dir="$host_home/.local/state/zorin-setup/backups/$timestamp"

  host mkdir -p "$backup_dir"
  if host_has dconf; then
    host dconf dump /org/gnome/shell/ > "$backup_dir/gnome-shell.dconf"
    host dconf dump /org/gnome/desktop/wm/keybindings/ > \
      "$backup_dir/window-keybindings.dconf"
  else
    warn 'dconf ontbreekt; GNOME-instellingen worden niet vooraf geback-upt.'
  fi
  if host_has wpctl; then
    host wpctl status -n > "$backup_dir/audio-status.txt"
  fi

  info "Voorafgaande instellingen geback-upt naar $backup_dir"
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
    info "Extensie is al aanwezig en ondersteunt GNOME $shell_major: $uuid"
    return
  fi

  if [[ "$DRY_RUN" == true ]]; then
    info "Zou de GNOME-extensie installeren: $uuid"
    return
  fi

  api_response=$(host curl -fLsSG --max-time 45 \
    --data-urlencode "uuid=$uuid" \
    --data-urlencode "shell_version=$shell_major" \
    'https://extensions.gnome.org/extension-info/') || \
    fail "Kon compatibele extensie-informatie niet ophalen: $uuid"

  download_url=$(printf '%s' "$api_response" | host python3 -c '
import json
import sys

data = json.load(sys.stdin)
shell_major = sys.argv[1]
if shell_major not in data.get("shell_version_map", {}):
    raise SystemExit("Geen versie voor deze GNOME Shell-release")
print(data["download_url"])
' "$shell_major") || fail "Geen GNOME-$shell_major-versie gevonden voor $uuid"

  host_home=$(host printenv HOME)
  host mkdir -p "$host_home/.cache/zorin-setup/extensions"
  archive="$host_home/.cache/zorin-setup/extensions/$uuid.zip"
  host curl -fLsS --max-time 60 \
    "https://extensions.gnome.org$download_url" -o "$archive" || \
    fail "Kon extensie niet downloaden: $uuid"
  host gnome-extensions install --force "$archive" || \
    fail "Kon extensie niet installeren: $uuid"
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

  info "Inschakelen bij de volgende GNOME-sessie: $uuid"
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
    info "Zou extensie-instelling instellen: $schema $key"
    return
  fi

  host_home=$(host printenv HOME)
  extension_dir="$host_home/.local/share/gnome-shell/extensions/$uuid"
  if ! host test -f "$extension_dir/schemas/gschemas.compiled"; then
    warn "Extensieschema ontbreekt voor $uuid; $key overgeslagen."
    return
  fi
  available_keys=$(host gsettings --schemadir "$extension_dir/schemas" \
    list-keys "$schema" 2>/dev/null) || {
    warn "Extensieschema niet leesbaar voor $uuid; $key overgeslagen."
    return
  }
  if ! printf '%s\n' "$available_keys" | host grep -Fxq "$key"; then
    warn "Instelling $key bestaat niet in $uuid; overgeslagen."
    return
  fi

  info "Instellen: $schema $key"
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
  local -a features=(topbar audio-output audio-input shortcuts clipboard spotlight)
  local -a labels=(
    'macOS-achtige bovenbalk en Zorin-dock'
    'Audio-uitvoerapparaten beperken'
    'Audio-invoerapparaten beperken'
    'Windows-achtige screenshottoets (Super+Shift+S)'
    'Klembordgeschiedenis (Super+V)'
    'Spotlight-achtige zoekfunctie (Super+Spatie)'
  )

  MENU_TAGS=("${features[@]}")
  MENU_LABELS=("${labels[@]}")
  MENU_STATUSES=(OFF OFF OFF OFF OFF OFF)
  show_checklist 'Zorin-instellingen' \
    'Vink aan wat je wilt configureren. Bestaande instellingen van niet-aangevinkte onderdelen blijven ongewijzigd.' || \
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
    warn 'PipeWire-hulpmiddelen ontbreken; de audio-keuze is niet beschikbaar.'
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
    warn "Geen ondersteunde audio-$direction-profielen gevonden."
    return 1
  fi

  if [[ "$direction" == output ]]; then
    label='Vink de uitvoerprofielen aan die je wilt behouden. Niet-aangevinkte profielen worden uitgeschakeld.'
  else
    label='Vink de microfoonprofielen aan die je wilt behouden. Niet-aangevinkte profielen worden uitgeschakeld.'
  fi
  if [[ "$direction" == output ]]; then
    show_checklist 'Audio-uitgangen beperken' "$label" || return 1
  else
    show_checklist 'Audio-ingangen beperken' "$label" || return 1
  fi

  while IFS= read -r tag; do
    [[ -n "$tag" ]] || continue
    device_id=${AUDIO_DEVICE_BY_TAG[$tag]}
    token=${AUDIO_TOKEN_BY_TAG[$tag]}
    if [[ -n "${selected_by_device[$device_id]:-}" ]]; then
      show_message 'Kies één profiel per geluidskaart' \
        "${AUDIO_LABEL_BY_TAG[$tag]} en een andere geselecteerde optie horen bij dezelfde geluidskaart. Kies per kaart hoogstens één $direction-profiel."
      return 1
    fi
    selected_by_device[$device_id]=$tag
    tokens_by_device[$device_id]=$token
    selected_tags+=("$tag")
  done <<< "$CHECKLIST_RESULT"

  if (( ${#selected_tags[@]} == 0 )); then
    show_message 'Geen audioapparaat geselecteerd' \
      "Er moet minstens één $direction actief blijven. Er worden geen audio-profielen gewijzigd."
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
      warn "Geen profiel gevonden om de selectie voor '$description' veilig toe te passen. Er is niets gewijzigd."
      return 1
    fi
    profile_index=$(profile_index_for_name "$device_id" "$target_profile")
    if [[ -z "$profile_index" ]]; then
      warn "Profiel '$target_profile' is niet beschikbaar op '$description'. Er is niets gewijzigd."
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
      warn "Profiel '$target_profile' is niet meer beschikbaar op apparaat $device_id."
      return 1
    fi
    if [[ "$DRY_RUN" == true ]]; then
      info "Zou audio-profiel instellen: ${AUDIO_PLAN_DESCRIPTIONS[index]} -> $target_profile"
    else
      info "Audio-profiel: ${AUDIO_PLAN_DESCRIPTIONS[index]} -> $target_profile"
      host wpctl set-profile "$device_id" "$profile_index"
    fi
  done
}

print_selection_summary() {
  local feature
  local tag
  local summary=''

  for feature in "${SELECTED_FEATURES[@]}"; do
    case "$feature" in
      topbar) summary+=$'\n- macOS-achtige bovenbalk en Zorin-dock' ;;
      audio-output) summary+=$'\n- Audio-uitgangen beperken' ;;
      audio-input) summary+=$'\n- Audio-ingangen beperken' ;;
      shortcuts) summary+=$'\n- Windows-achtige screenshottoetsen' ;;
      clipboard) summary+=$'\n- Klembordgeschiedenis' ;;
      spotlight) summary+=$'\n- Spotlight-achtige zoekfunctie' ;;
    esac
  done

  if feature_selected audio-output; then
    summary+=$'\n\nTe behouden uitgangen:'
    for tag in "${SELECTED_AUDIO_OUTPUTS[@]}"; do
      summary+=$'\n- '
      summary+=${AUDIO_LABEL_BY_TAG[$tag]}
    done
  fi
  if feature_selected audio-input; then
    summary+=$'\n\nTe behouden ingangen:'
    for tag in "${SELECTED_AUDIO_INPUTS[@]}"; do
      summary+=$'\n- '
      summary+=${AUDIO_LABEL_BY_TAG[$tag]}
    done
  fi

  printf '%s' "$summary"
}

apply_selected_features() {
  local shell_version
  local shell_major

  shell_version=$(host gnome-shell --version | host awk '{print $3}')
  shell_major=${shell_version%%.*}

  if feature_selected clipboard; then
    install_extension_if_needed "$CLIPBOARD_UUID" "$shell_major"
    enable_extension "$CLIPBOARD_UUID"
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator history-size 25
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator cache-only-favorites true
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator cache-images false
    set_extension_gsetting "$CLIPBOARD_UUID" \
      org.gnome.shell.extensions.clipboard-indicator toggle-menu "['<Super>v']"
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

  host_has gsettings || fail 'gsettings ontbreekt op het systeem.'
  host_has python3 || fail 'python3 ontbreekt op het systeem.'

  os_id=$(host sh -c '. /etc/os-release; printf "%s" "$ID"')
  [[ "$os_id" == zorin ]] || fail 'Dit script is bedoeld voor Zorin OS.'
  shell_version=$(host gnome-shell --version | host awk '{print $3}')
  shell_major=${shell_version%%.*}
  [[ "$shell_major" =~ ^[0-9]+$ ]] || fail 'GNOME-versie kon niet worden bepaald.'

  if ! select_features; then
    info 'Installatie geannuleerd; er zijn geen instellingen gewijzigd.'
    exit 0
  fi
  if (( ${#SELECTED_FEATURES[@]} == 0 )); then
    info 'Geen onderdelen geselecteerd; er zijn geen instellingen gewijzigd.'
    exit 0
  fi

  if feature_selected audio-output && ! select_audio_endpoints output; then
    info 'Audio-uitvoerkeuze afgebroken; er zijn geen instellingen gewijzigd.'
    exit 0
  fi
  if feature_selected audio-input && ! select_audio_endpoints input; then
    info 'Audio-invoerkeuze afgebroken; er zijn geen instellingen gewijzigd.'
    exit 0
  fi
  if feature_selected audio-output || feature_selected audio-input; then
    build_audio_plan || exit 1
  fi

  summary=$(print_selection_summary)
  if [[ "$DRY_RUN" == true ]]; then
    info "Controlemodus: Zorin OS, GNOME $shell_version; er worden geen wijzigingen opgeslagen."
    if ! ask_confirmation 'Geselecteerde wijzigingen controleren' "$summary"; then
      info 'Controle geannuleerd; er zijn geen instellingen gewijzigd.'
      exit 0
    fi
    apply_selected_features
    info 'Controle voltooid; er zijn geen instellingen gewijzigd.'
    exit 0
  fi

  if ! ask_confirmation 'Zorin-instellingen bevestigen' "$summary"; then
    info 'Installatie geannuleerd; er zijn geen instellingen gewijzigd.'
    exit 0
  fi

  info "Configuratie toepassen op Zorin OS met GNOME $shell_version"
  backup_current_settings
  if feature_selected topbar || feature_selected clipboard || feature_selected spotlight; then
    host_has gnome-extensions || fail 'gnome-extensions ontbreekt op het systeem.'
  fi
  if feature_selected clipboard || feature_selected spotlight; then
    host_has curl || fail 'curl ontbreekt; extensies kunnen niet worden gedownload.'
  fi
  apply_selected_features

  if [[ "$RELOGIN_REQUIRED" == true ]]; then
    info 'Meld je af en weer aan om nieuw geïnstalleerde extensies te laden.'
  else
    info 'Klaar. Herstart GNOME of meld je opnieuw aan als een extensie nog niet actief is.'
  fi
}

main "$@"