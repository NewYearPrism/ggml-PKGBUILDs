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

  perl -ne '
    BEGIN { $name = shift @ARGV }
    if (/"logger_name": "nvchecker\.core"/ && /"name": "\Q$name\E"/ && /"version": "([^"]+)"/) {
      print $1;
      exit;
    }
  ' "$name" <<<"$output"
}

cache_value() {
  local section=$1
  local key=$2

  [[ -f $vcache ]] || return 0
  SECTION=$section KEY=$key perl -0ne '
    my $section = $ENV{SECTION};
    my $key = $ENV{KEY};
    if (/"\Q$section\E"\s*:\s*\{.*?"\Q$key\E"\s*:\s*"([^"]*)"/s) {
      print $1;
    }
  ' "$vcache"
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

require_command nvchecker "Install it with: sudo pacman -S nvchecker"
require_command git "Install it with: sudo pacman -S git"
require_command curl "Install it with: sudo pacman -S curl"
require_command sha256sum "Install coreutils."
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

if [[ $ggml_version =~ ^([0-9]+)\.([0-9]+)\.([0-9]+)$ ]]; then
  ggml_next_version="${BASH_REMATCH[1]}.${BASH_REMATCH[2]}.$((BASH_REMATCH[3] + 1))"
else
  printf 'Error: unexpected ggml version: %s\n' "$ggml_version" >&2
  exit 1
fi

sdcpp_webui_commit=$(git ls-remote https://github.com/leejet/sdcpp-webui.git refs/heads/master | cut -f 1)

printf 'Found llama.cpp b%s, ggml %s, ggml upper bound %s, stable-diffusion.cpp %s, sdcpp-webui %s\n' \
  "$llama_cpp_version" "$ggml_version" "$ggml_next_version" "$stable_diffusion_cpp_tag" "$sdcpp_webui_commit"

llama_cpp_cached_version=$(cache_value llama_cpp version)
llama_cpp_cached_sha256sum=$(cache_value llama_cpp sha256sum)
if [[ $llama_cpp_cached_version != "$llama_cpp_version" || -z $llama_cpp_cached_sha256sum ]]; then
  printf 'Downloading llama.cpp b%s source to compute sha256\n' "$llama_cpp_version"
  llama_cpp_sha256sum=$(sha256_url "https://github.com/ggml-org/llama.cpp/archive/refs/tags/b${llama_cpp_version}.tar.gz")
else
  printf 'Using cached llama.cpp b%s sha256\n' "$llama_cpp_version"
  llama_cpp_sha256sum=$llama_cpp_cached_sha256sum
fi

stable_diffusion_cpp_cached_tag=$(cache_value stable_diffusion_cpp tag)
stable_diffusion_cpp_cached_sha256sum=$(cache_value stable_diffusion_cpp sha256sum)
if [[ $stable_diffusion_cpp_cached_tag != "$stable_diffusion_cpp_tag" || -z $stable_diffusion_cpp_cached_sha256sum ]]; then
  printf 'Downloading stable-diffusion.cpp %s source to compute sha256\n' "$stable_diffusion_cpp_tag"
  stable_diffusion_cpp_sha256sum=$(sha256_url "https://github.com/leejet/stable-diffusion.cpp/archive/refs/tags/${stable_diffusion_cpp_tag}.tar.gz")
else
  printf 'Using cached stable-diffusion.cpp %s sha256\n' "$stable_diffusion_cpp_tag"
  stable_diffusion_cpp_sha256sum=$stable_diffusion_cpp_cached_sha256sum
fi

sdcpp_webui_cached_commit=$(cache_value sdcpp_webui commit)
sdcpp_webui_cached_sha256sum=$(cache_value sdcpp_webui sha256sum)
if [[ $sdcpp_webui_cached_commit != "$sdcpp_webui_commit" || -z $sdcpp_webui_cached_sha256sum ]]; then
  printf 'Downloading sdcpp-webui %s source to compute sha256\n' "$sdcpp_webui_commit"
  sdcpp_webui_sha256sum=$(sha256_url "https://github.com/leejet/sdcpp-webui/archive/${sdcpp_webui_commit}.tar.gz")
else
  printf 'Using cached sdcpp-webui %s sha256\n' "$sdcpp_webui_commit"
  sdcpp_webui_sha256sum=$sdcpp_webui_cached_sha256sum
fi

cat >"$vcache" <<EOF
{
  "llama_cpp": {
    "version": "$llama_cpp_version",
    "sha256sum": "$llama_cpp_sha256sum"
  },
  "stable_diffusion_cpp": {
    "tag": "$stable_diffusion_cpp_tag",
    "version": "$stable_diffusion_cpp_version",
    "sha256sum": "$stable_diffusion_cpp_sha256sum"
  },
  "sdcpp_webui": {
    "commit": "$sdcpp_webui_commit",
    "sha256sum": "$sdcpp_webui_sha256sum"
  }
}
EOF
printf 'Saved version cache to %s\n' "$vcache"

shopt -s globstar nullglob
pkgbuilds=("$script_dir"/**/PKGBUILD)
printf 'Updating %d PKGBUILD files\n' "${#pkgbuilds[@]}"

for pkgbuild in "${pkgbuilds[@]}"; do
  printf 'Updating %s\n' "$pkgbuild"
  replace_var "$pkgbuild" _llama_cpp_version "$llama_cpp_version"
  replace_var "$pkgbuild" _ggml_version "$ggml_version"
  replace_var "$pkgbuild" _ggml_next_version "$ggml_next_version"
  replace_var "$pkgbuild" _llama_cpp_sha256sum "$llama_cpp_sha256sum"
  replace_var "$pkgbuild" _stable_diffusion_cpp_tag "$stable_diffusion_cpp_tag"
  replace_var "$pkgbuild" _stable_diffusion_cpp_version "$stable_diffusion_cpp_version"
  replace_var "$pkgbuild" _stable_diffusion_cpp_sha256sum "$stable_diffusion_cpp_sha256sum"
  replace_var "$pkgbuild" _sdcpp_webui_commit "$sdcpp_webui_commit"
  replace_var "$pkgbuild" _sdcpp_webui_sha256sum "$sdcpp_webui_sha256sum"
done

printf 'Done. Regenerate .SRCINFO in each AUR package directory before publishing.\n'
