#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
makepkg_args=(--syncdep --needed --clean --force)

packages=(
  ggml-cpu-backend
  ggml-cuda-backend
  ggml-hip-backend
  ggml-vulkan-backend
  llama.cpp-system
  stable-diffusion.cpp-system
)

build_package() {
  local package_dir=$1

  printf '\n==> Building %s\n' "$package_dir"
  cd -- "$root_dir/$package_dir"
  makepkg "${makepkg_args[@]}"
}

printf '==> Building and installing ggml-core\n'
cd -- "$root_dir/ggml-core"
mapfile -t ggml_package_files < <(makepkg --packagelist)
makepkg "${makepkg_args[@]}"

if ((${#ggml_package_files[@]} == 0)); then
  printf 'error: makepkg --packagelist returned no ggml-core package files\n' >&2
  exit 1
fi

sudo pacman -U --needed "${ggml_package_files[@]}"

for package_dir in "${packages[@]}"; do
  build_package "$package_dir"
done

printf '\n==> Done. Built ggml-core and all dependent packages. Only ggml-core was installed.\n'
