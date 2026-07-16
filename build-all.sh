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

packages_llamacpp=(
  ggml-cpu-backend-llama.cpp
  ggml-cuda-backend-llama.cpp
  ggml-hip-backend-llama.cpp
  ggml-vulkan-backend-llama.cpp
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

printf '\n==> Building and installing ggml-core-llama.cpp\n'
cd -- "$root_dir/ggml-core-llama.cpp"
mapfile -t ggml_llamacpp_package_files < <(makepkg --packagelist)
makepkg "${makepkg_args[@]}"

if ((${#ggml_llamacpp_package_files[@]} == 0)); then
  printf 'error: makepkg --packagelist returned no ggml-core-llama.cpp package files\n' >&2
  exit 1
fi

sudo pacman -U --needed "${ggml_llamacpp_package_files[@]}"

for package_dir in "${packages_llamacpp[@]}"; do
  build_package "$package_dir"
done

printf '\n==> Done. Built ggml-core, ggml-core-llama.cpp and all dependent packages. Only ggml-core variants were installed.\n'
