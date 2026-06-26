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

require_command makepkg "Install pacman/base-devel first."
require_command git "Install it with: sudo pacman -S git"

repo_root=$(git -C "$script_dir" rev-parse --show-toplevel)
repo_status=$(git -C "$repo_root" status --porcelain=v1 --untracked-files=all)
if [[ -n $repo_status ]]; then
  printf 'Error: source repository has uncommitted changes. Commit or stash them before syncing AUR repositories.\n' >&2
  git -C "$repo_root" status --short >&2
  exit 1
fi

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

  commit_message=$(git -C "$repo_root" log -1 --format=%B -- "$pkgname/")

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

  git -C "$aur_dir" commit -F - <<<"$commit_message"
  printf '  Committed with source repository message: %s\n' "${commit_message%%$'\n'*}"
done

printf '\n==> Done. Review and push individual AUR repositories when ready.\n'
