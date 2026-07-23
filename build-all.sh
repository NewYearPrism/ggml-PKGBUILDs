#!/usr/bin/env bash
set -euo pipefail

root_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

chroot_dir=${CHROOT_DIR:-$HOME/chroot}
makepkg_args=(--needed --clean)
failed_packages=()

# Environment variables forwarded into the chroot build.
# makechrootpkg does not natively pass custom environment variables into the
# chroot, so they are written to a temporary profile.d script and bind-mounted
# into /etc/profile.d/ where /etc/profile sources it during the build.
env_vars=(
  NO_PROXY
  HTTP_PROXY
  HTTPS_PROXY
  GGML_BUILD_EXTRA_ARGS
  GGML_CPU_ALL_VARIANTS
  GGML_CPU_BUILD_EXTRA_ARGS
  CUDA_TARGETS
  GGML_CUDA_BUILD_EXTRA_ARGS
  AMDGPU_TARGETS
  GGML_HIP_BUILD_EXTRA_ARGS
  GGML_VULKAN_BUILD_EXTRA_ARGS
  LLAMA_CPP_BUILD_EXTRA_ARGS
  STABLE_DIFFUSION_CPP_BUILD_EXTRA_ARGS
)

packages=(
  ggml-cpu-backend
  ggml-cuda-backend
  ggml-hip-backend
  ggml-vulkan-backend
)

packages_llamacpp=(
  ggml-cpu-backend-llama.cpp
  ggml-cuda-backend-llama.cpp
  ggml-hip-backend-llama.cpp
  ggml-vulkan-backend-llama.cpp
)

packages_apps=(
  stable-diffusion.cpp-system
)

require_command() {
  local command_name=$1
  local install_hint=$2

  if ! command -v "$command_name" >/dev/null 2>&1; then
    printf 'Error: %s is required. %s\n' "$command_name" "$install_hint" >&2
    exit 1
  fi
}

require_command makechrootpkg "Install it with: sudo pacman -S devtools"
require_command mkarchroot "Install it with: sudo pacman -S devtools"
require_command makepkg "Install pacman/base-devel first."

env_file=
cleanup() {
  [[ -n $env_file && -f $env_file ]] && rm -f "$env_file"
}
trap cleanup EXIT

# Build a profile.d script exporting caller-defined environment variables.
# Returns non-zero if no relevant variables are set.
create_env_file() {
  local var value
  local lines=()

  for var in "${env_vars[@]}"; do
    value=${!var:-}
    if [[ -n $value ]]; then
      lines+=("export $var=${value@Q}")
    fi
  done

  if ((${#lines[@]} == 0)); then
    return 1
  fi

  env_file=$(mktemp /tmp/ggml-build-env.XXXXXX.sh)
  printf '%s\n' "${lines[@]}" >"$env_file"
  chmod 644 "$env_file"
}

chroot_args=(-c -r "$chroot_dir")
if create_env_file; then
  chroot_args+=(-D "$env_file:/etc/profile.d/zz-ggml-build-env.sh")
  printf '==> Forwarding build environment variables into chroot\n'
  for var in "${env_vars[@]}"; do
    value=${!var:-}
    [[ -n $value ]] && printf '    %s=%s\n' "$var" "$value"
  done
fi

build_package() {
  local package_dir=$1
  shift
  local -a extra_args=("$@")

  printf '\n==> Building %s\n' "$package_dir"
  cd -- "$root_dir/$package_dir"
  if makechrootpkg "${chroot_args[@]}" "${extra_args[@]}" -- "${makepkg_args[@]}"; then
    return 0
  fi
  local rc=$?
  printf '\n==> WARNING: building %s failed (exit %s), continuing with remaining packages\n' "$package_dir" "$rc" >&2
  failed_packages+=("$package_dir")
  return 0
}

# Build a core package and populate install_args with -I flags for dependents.
# Returns non-zero on failure so the caller can skip dependents that require it.
build_core() {
  local package_dir=$1
  local pkg

  printf '\n==> Building %s\n' "$package_dir"
  cd -- "$root_dir/$package_dir"
  if ! mapfile -t package_files < <(makepkg --packagelist); then
    printf '\n==> WARNING: makepkg --packagelist failed for %s, skipping its dependents\n' "$package_dir" >&2
    failed_packages+=("$package_dir")
    return 1
  fi

  if ((${#package_files[@]} == 0)); then
    printf '\n==> WARNING: makepkg --packagelist returned no %s package files, skipping its dependents\n' "$package_dir" >&2
    failed_packages+=("$package_dir")
    return 1
  fi

  if ! makechrootpkg "${chroot_args[@]}" -- "${makepkg_args[@]}"; then
    printf '\n==> WARNING: building %s failed, skipping its dependents\n' "$package_dir" >&2
    failed_packages+=("$package_dir")
    return 1
  fi

  install_args=()
  for pkg in "${package_files[@]}"; do
    install_args+=(-I "$pkg")
  done
  return 0
}

# Ensure the chroot root exists.
if [[ ! -d $chroot_dir/root ]]; then
  printf '==> Creating chroot at %s\n' "$chroot_dir/root"
  mkdir -p -- "$chroot_dir"
  mkarchroot -C /usr/share/devtools/pacman.conf.d/extra.conf -M /usr/share/devtools/makepkg.conf.d/x86_64.conf "$chroot_dir/root" base-devel
fi

# --- Libraries: stable series (standalone ggml releases) ---

stable_install_args=()
if build_core ggml-core; then
  stable_install_args=("${install_args[@]}")
  for package_dir in "${packages[@]}"; do
    build_package "$package_dir" "${stable_install_args[@]}"
  done
else
  printf '\n==> Skipping stable-series backends due to ggml-core failure\n'
fi

# --- Libraries: bleeding-edge series (llama.cpp embedded ggml) ---

llamacpp_install_args=()
if build_core ggml-core-llama.cpp; then
  llamacpp_install_args=("${install_args[@]}")
  for package_dir in "${packages_llamacpp[@]}"; do
    build_package "$package_dir" "${llamacpp_install_args[@]}"
  done
else
  printf '\n==> Skipping llama.cpp-series backends due to ggml-core-llama.cpp failure\n'
fi

# --- Applications (built last) ---

# stable-diffusion.cpp-system: depends on stable ggml-core only.
for package_dir in "${packages_apps[@]}"; do
  if ((${#stable_install_args[@]} > 0)); then
    build_package "$package_dir" "${stable_install_args[@]}"
  else
    printf '\n==> Skipping %s: ggml-core was not built\n' "$package_dir"
    failed_packages+=("$package_dir")
  fi
done

# llama.cpp-system: build once against each ggml-core variant. When stable
# ggml lags behind llama.cpp, the ggml-core build fails but the
# ggml-core-llama.cpp build (which embeds a matching ggml) still succeeds.
build_llamacpp_system() {
  local label=$1
  shift
  local -a core_args=("$@")

  if ((${#core_args[@]} == 0)); then
    printf '\n==> Skipping llama.cpp-system (%s): core not built\n' "$label"
    failed_packages+=("llama.cpp-system ($label)")
    return 0
  fi

  printf '\n==> Building llama.cpp-system (%s)\n' "$label"
  cd -- "$root_dir/llama.cpp-system"
  if makechrootpkg "${chroot_args[@]}" "${core_args[@]}" -- "${makepkg_args[@]}"; then
    return 0
  fi
  local rc=$?
  printf '\n==> WARNING: building llama.cpp-system (%s) failed (exit %s)\n' "$label" "$rc" >&2
  failed_packages+=("llama.cpp-system ($label)")
}

build_llamacpp_system 'ggml-core' "${stable_install_args[@]}"
build_llamacpp_system 'ggml-core-llama.cpp' "${llamacpp_install_args[@]}"

if ((${#failed_packages[@]} > 0)); then
  printf '\n==> Done with failures. Failed packages:\n' >&2
  for pkg in "${failed_packages[@]}"; do
    printf '    %s\n' "$pkg" >&2
  done
  exit 1
fi

printf '\n==> Done. Built ggml-core, ggml-core-llama.cpp, all backends and applications in chroot.\n'
