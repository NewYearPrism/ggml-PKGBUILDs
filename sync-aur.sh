#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
aur_root=${AUR_ROOT:-$HOME/aur}

require_command() {
  local command_name=$1
  local install_hint=$2

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required. %s\n' "$command_name" "$install_hint" >&2
    exit 1
  fi
}

should_skip() {
  local path=$1
  local name
  name=$(basename -- "$path")

  [[ -d $path ]] && return 0

  case $name in
    .SRCINFO|.SRCINFO.*|*.pkg.tar|*.pkg.tar.*|*.src.tar.gz|*.tar.gz|*.tar.zst|*.log)
      return 0
      ;;
  esac

  return 1
}

srcinfo_value() {
  local key=$1
  local line

  while IFS= read -r line; do
    line=${line#${line%%[![:space:]]*}}
    if [[ $line == "$key = "* ]]; then
      printf '%s\n' "${line#"$key = "}"
      return 0
    fi
  done
}

require_command makepkg "Install pacman/base-devel first."
require_command git "Install it with: sudo pacman -S git"

mkdir -p -- "$aur_root"

shopt -s nullglob
package_pkgbuilds=("$script_dir"/*/PKGBUILD)
if ((${#package_pkgbuilds[@]} == 0)); then
  printf 'Error: no PKGBUILD files found under %s\n' "$script_dir" >&2
  exit 1
fi

for pkgbuild in "${package_pkgbuilds[@]}"; do
  package_dir=$(dirname -- "$pkgbuild")
  pkgname=$(basename -- "$package_dir")
  aur_dir="$aur_root/$pkgname"
  copied_files=()

  printf '\n==> Syncing %s to %s\n' "$pkgname" "$aur_dir"
  mkdir -p -- "$aur_dir"

  if [[ ! -d $aur_dir/.git ]]; then
    printf '  Initializing git repository\n'
    git -C "$aur_dir" init
  fi

  for file in "$package_dir"/*; do
    if should_skip "$file"; then
      continue
    fi

    name=$(basename -- "$file")
    cp -f -- "$file" "$aur_dir/$name"
    copied_files+=("$name")
    printf '  Copied %s\n' "$name"
  done

  srcinfo=$(cd -- "$aur_dir" && makepkg --printsrcinfo)
  printf '%s\n' "$srcinfo" >"$aur_dir/.SRCINFO"
  printf '  Generated .SRCINFO\n'

  git -C "$aur_dir" add -- "${copied_files[@]}" .SRCINFO

  staged=$(git -C "$aur_dir" diff --cached --name-only)
  if [[ -z $staged ]]; then
    printf '  No changes to commit\n'
    continue
  fi

  pkgver=$(srcinfo_value pkgver <<<"$srcinfo")
  pkgrel=$(srcinfo_value pkgrel <<<"$srcinfo")
  commit_message="Update to ${pkgver}-${pkgrel}"

  git -C "$aur_dir" commit -m "$commit_message"
  printf '  Committed: %s\n' "$commit_message"
done

printf '\n==> Done. Review and push individual AUR repositories when ready.\n'
