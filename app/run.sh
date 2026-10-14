#!/usr/bin/env bash
set -Eeuo pipefail

readonly sdk='org.gnome.Sdk//49'
readonly app_dir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly binary="$app_dir/target/release/zorin-personal-setup"

host_flatpak() {
  if [[ -n "${FLATPAK_ID:-}" ]] && command -v flatpak-spawn >/dev/null 2>&1; then
    flatpak-spawn --host flatpak "$@"
  else
    flatpak "$@"
  fi
}

if ! host_flatpak info --user "$sdk" >/dev/null 2>&1 && \
  ! host_flatpak info --system "$sdk" >/dev/null 2>&1; then
  printf 'The GNOME SDK is required. Install it for this user? [y/N] '
  read -r answer
  [[ "$answer" == [yY] || "$answer" == [yY][eE][sS] ]] || exit 1
  if ! host_flatpak remotes --user --columns=name | grep -Fxq flathub; then
    host_flatpak remote-add --user --if-not-exists flathub \
      https://flathub.org/repo/flathub.flatpakrepo
  fi
  host_flatpak install --user --noninteractive --assumeyes flathub "$sdk"
fi

if [[ ! -f "$HOME/.cargo/env" ]]; then
  printf 'Rust is required. Install the stable toolchain from https://rustup.rs/ and run this launcher again.\n' >&2
  exit 1
fi

host_flatpak run \
  --filesystem="$HOME" \
  --share=network \
  --command=sh "$sdk" -c '
    . "$HOME/.cargo/env"
    cd "$1"
    cargo build --release
  ' sh "$app_dir"

if [[ -n "${FLATPAK_ID:-}" ]] && command -v flatpak-spawn >/dev/null 2>&1; then
  exec flatpak-spawn --host env -u FLATPAK_ID "$binary"
fi
exec "$binary"
