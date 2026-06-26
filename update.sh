#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
nvcfg="$script_dir/.nvchecker.toml"
vcache="$script_dir/.version_cache.json"

require_command() {
  local command_name=$1
  local install_hint=$2

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required. %s\n' "$command_name" "$install_hint" >&2
    exit 1
  fi
}

nvchecker_version() {
  local output=$1
  local name=$2

  jq -er --arg name "$name" '
    select(.logger_name == "nvchecker.core" and .name == $name) | .version
  ' <<<"$output"
}

cache_value() {
  local section=$1
  local key=$2

  [[ -f $vcache ]] || return 0
  jq -r --arg section "$section" --arg key "$key" '.[$section][$key] // empty' "$vcache"
}

save_cache() {
  jq -n \
    --arg llama_cpp_version "$llama_cpp_version" \
    --arg llama_cpp_sha256sum "$llama_cpp_sha256sum" \
    --arg ggml_version "$ggml_version" \
    --arg ggml_sha256sum "$ggml_sha256sum" \
    --arg stable_diffusion_cpp_tag "$stable_diffusion_cpp_tag" \
    --arg stable_diffusion_cpp_version "$stable_diffusion_cpp_version" \
    --arg stable_diffusion_cpp_sha256sum "$stable_diffusion_cpp_sha256sum" \
    --arg sdcpp_webui_commit "$sdcpp_webui_commit" \
    --arg sdcpp_webui_sha256sum "$sdcpp_webui_sha256sum" \
    '{
      llama_cpp: {
        version: $llama_cpp_version,
        sha256sum: $llama_cpp_sha256sum
      },
      ggml: {
        version: $ggml_version,
        sha256sum: $ggml_sha256sum
      },
      stable_diffusion_cpp: {
        tag: $stable_diffusion_cpp_tag,
        version: $stable_diffusion_cpp_version,
        sha256sum: $stable_diffusion_cpp_sha256sum
      },
      sdcpp_webui: {
        commit: $sdcpp_webui_commit,
        sha256sum: $sdcpp_webui_sha256sum
      }
    }' >"$vcache"
}

sha256_url() {
  local url=$1

  curl -LfsS "$url" | sha256sum | cut -d ' ' -f 1
}

replace_var() {
  local file=$1
  local name=$2
  local value=$3

  perl -0pi -e "s/^\Q$name\E=.*$/$name=$value/m" "$file"
}

pkgbuild_value() {
  local file=$1
  local name=$2

  bash --noprofile --norc -c '
    source "$1"
    printf "%s\n" "${!2-}"
  ' bash "$file" "$name"
}

require_command nvchecker "Install it with: sudo pacman -S nvchecker"
require_command git "Install it with: sudo pacman -S git"
require_command curl "Install it with: sudo pacman -S curl"
require_command sha256sum "Install coreutils."
require_command jq "Install it with: sudo pacman -S jq"
require_command perl "Install it with: sudo pacman -S perl"

printf 'Checking upstream versions with %s\n' "$nvcfg"
nvchecker_output=$(nvchecker -c "$nvcfg" --logger json)

llama_cpp_version=$(nvchecker_version "$nvchecker_output" "llama.cpp")
llama_cpp_version=${llama_cpp_version#b}
stable_diffusion_cpp_tag=$(nvchecker_version "$nvchecker_output" "stable-diffusion.cpp")
ggml_version=$(nvchecker_version "$nvchecker_output" "ggml")
ggml_version=${ggml_version#v}

if [[ $stable_diffusion_cpp_tag =~ ^master-([0-9]+)-[0-9a-f]+$ ]]; then
  stable_diffusion_cpp_version=${BASH_REMATCH[1]}
else
  printf 'Error: unexpected stable-diffusion.cpp tag: %s\n' "$stable_diffusion_cpp_tag" >&2
  exit 1
fi

if [[ ! $ggml_version =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  printf 'Error: unexpected ggml version: %s\n' "$ggml_version" >&2
  exit 1
fi

sdcpp_webui_commit=$(git ls-remote https://github.com/leejet/sdcpp-webui.git refs/heads/master | cut -f 1)

printf 'Found llama.cpp b%s, ggml %s, stable-diffusion.cpp %s, sdcpp-webui %s\n' \
  "$llama_cpp_version" "$ggml_version" "$stable_diffusion_cpp_tag" "$sdcpp_webui_commit"

any_updated=0

llama_cpp_cached_version=$(cache_value llama_cpp version)
llama_cpp_cached_sha256sum=$(cache_value llama_cpp sha256sum)
llama_cpp_updated=0
if [[ $llama_cpp_cached_version == "$llama_cpp_version" && -n $llama_cpp_cached_sha256sum ]]; then
  printf 'Skipping llama.cpp b%s: version unchanged\n' "$llama_cpp_version"
  llama_cpp_sha256sum=$llama_cpp_cached_sha256sum
else
  printf 'Downloading llama.cpp b%s source to compute sha256\n' "$llama_cpp_version"
  llama_cpp_sha256sum=$(sha256_url "https://github.com/ggml-org/llama.cpp/archive/refs/tags/b${llama_cpp_version}.tar.gz")
  llama_cpp_updated=1
  any_updated=1
fi

ggml_cached_version=$(cache_value ggml version)
ggml_cached_sha256sum=$(cache_value ggml sha256sum)
ggml_updated=0
if [[ $ggml_cached_version == "$ggml_version" && -n $ggml_cached_sha256sum ]]; then
  printf 'Skipping ggml %s: version unchanged\n' "$ggml_version"
  ggml_sha256sum=$ggml_cached_sha256sum
else
  printf 'Downloading ggml %s source to compute sha256\n' "$ggml_version"
  ggml_sha256sum=$(sha256_url "https://github.com/ggml-org/ggml/archive/refs/tags/v${ggml_version}.tar.gz")
  ggml_updated=1
  any_updated=1
fi

stable_diffusion_cpp_cached_tag=$(cache_value stable_diffusion_cpp tag)
stable_diffusion_cpp_cached_sha256sum=$(cache_value stable_diffusion_cpp sha256sum)
stable_diffusion_cpp_updated=0
if [[ $stable_diffusion_cpp_cached_tag == "$stable_diffusion_cpp_tag" && -n $stable_diffusion_cpp_cached_sha256sum ]]; then
  printf 'Skipping stable-diffusion.cpp %s: version unchanged\n' "$stable_diffusion_cpp_tag"
  stable_diffusion_cpp_sha256sum=$stable_diffusion_cpp_cached_sha256sum
else
  printf 'Downloading stable-diffusion.cpp %s source to compute sha256\n' "$stable_diffusion_cpp_tag"
  stable_diffusion_cpp_sha256sum=$(sha256_url "https://github.com/leejet/stable-diffusion.cpp/archive/refs/tags/${stable_diffusion_cpp_tag}.tar.gz")
  stable_diffusion_cpp_updated=1
  any_updated=1
fi

sdcpp_webui_cached_commit=$(cache_value sdcpp_webui commit)
sdcpp_webui_cached_sha256sum=$(cache_value sdcpp_webui sha256sum)
sdcpp_webui_updated=0
if [[ $sdcpp_webui_cached_commit == "$sdcpp_webui_commit" && -n $sdcpp_webui_cached_sha256sum ]]; then
  printf 'Skipping sdcpp-webui %s: commit unchanged\n' "$sdcpp_webui_commit"
  sdcpp_webui_sha256sum=$sdcpp_webui_cached_sha256sum
else
  printf 'Downloading sdcpp-webui %s source to compute sha256\n' "$sdcpp_webui_commit"
  sdcpp_webui_sha256sum=$(sha256_url "https://github.com/leejet/sdcpp-webui/archive/${sdcpp_webui_commit}.tar.gz")
  sdcpp_webui_updated=1
  any_updated=1
fi

if (( ! any_updated )); then
  printf 'No version updates found. Skipping cache and PKGBUILD updates.\n'
  exit 0
fi

save_cache
printf 'Saved version cache to %s\n' "$vcache"

shopt -s globstar nullglob
pkgbuilds=("$script_dir"/**/PKGBUILD)
printf 'Updating %d PKGBUILD files\n' "${#pkgbuilds[@]}"

for pkgbuild in "${pkgbuilds[@]}"; do
  printf 'Updating %s\n' "$pkgbuild"
  old_pkgver=$(pkgbuild_value "$pkgbuild" pkgver)
  old_content=$(<"$pkgbuild")

  if (( llama_cpp_updated )); then
    replace_var "$pkgbuild" _llama_cpp_version "$llama_cpp_version"
    replace_var "$pkgbuild" _llama_cpp_sha256sum "$llama_cpp_sha256sum"
  fi

  if (( ggml_updated )); then
    replace_var "$pkgbuild" _ggml_version "$ggml_version"
    replace_var "$pkgbuild" _ggml_sha256sum "$ggml_sha256sum"
  fi

  if (( stable_diffusion_cpp_updated )); then
    replace_var "$pkgbuild" _stable_diffusion_cpp_tag "$stable_diffusion_cpp_tag"
    replace_var "$pkgbuild" _stable_diffusion_cpp_version "$stable_diffusion_cpp_version"
    replace_var "$pkgbuild" _stable_diffusion_cpp_sha256sum "$stable_diffusion_cpp_sha256sum"
  fi

  if (( sdcpp_webui_updated )); then
    replace_var "$pkgbuild" _sdcpp_webui_commit "$sdcpp_webui_commit"
    replace_var "$pkgbuild" _sdcpp_webui_sha256sum "$sdcpp_webui_sha256sum"
  fi

  new_pkgver=$(pkgbuild_value "$pkgbuild" pkgver)
  new_content=$(<"$pkgbuild")

  if [[ $old_pkgver != "$new_pkgver" ]]; then
    replace_var "$pkgbuild" pkgrel 1
    printf '  Reset pkgrel to 1: pkgver changed from %s to %s\n' "$old_pkgver" "$new_pkgver"
  elif [[ $old_content != "$new_content" ]]; then
    old_pkgrel=$(pkgbuild_value "$pkgbuild" pkgrel)
    new_pkgrel=$((old_pkgrel + 1))
    replace_var "$pkgbuild" pkgrel "$new_pkgrel"
    printf '  Bumped pkgrel to %s: dependency version changed but pkgver unchanged\n' "$new_pkgrel"
  fi
done

printf 'Done. Regenerate .SRCINFO in each AUR package directory before publishing.\n'
