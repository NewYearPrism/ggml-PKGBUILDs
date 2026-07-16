# PKGBUILDs for ggml, llama.cpp and stable-diffusion.cpp
[ggml](https://github.com/ggml-org/ggml) |
[llama.cpp](https://github.com/ggml-org/llama.cpp) |
[stable-diffusion.cpp](https://github.com/leejet/stable-diffusion.cpp)

This project aims to integrate ggml ecosystem into Arch Linux package system in a flexable, bloatless way.

## Usage

### Stable series (from standalone [ggml](https://github.com/ggml-org/ggml) releases)

```
# Run in unprivileged environment
makepkg -iD ggml-core
makepkg -iD ggml-cpu-backend      # Required by llama.cpp
makepkg -iD llama.cpp-system
makepkg -iD ggml-cuda-backend     # for NVIDIA GPUs
makepkg -iD ggml-hip-backend      # for AMD GPUs
```

### Bleeding-edge series (from [llama.cpp](https://github.com/ggml-org/llama.cpp) embedded ggml)

The `-llama.cpp` suffixed packages use the more frequently updated ggml bundled
inside the llama.cpp repository. They are drop-in replacements for the stable
series and conflict with them — install one series or the other, not both.

```
makepkg -iD ggml-core-llama.cpp
makepkg -iD ggml-cpu-backend-llama.cpp
makepkg -iD ggml-cuda-backend-llama.cpp     # for NVIDIA GPUs
makepkg -iD ggml-hip-backend-llama.cpp      # for AMD GPUs
makepkg -iD ggml-vulkan-backend-llama.cpp
```

## Compile Options

Here are some notable environment variables can be set before compilation.

- ```GGML_ALL_CPU_VARIANTS=off``` for *ggml-cpu-backend*
  - Builds only one shared library of CPU computation, rather than having a dozen of file for every CPU generation.
- ```CUDA_TARGETS=<arch>``` for *ggml-cuda-backend*
  - *\<arch\>* can be *native*, *89* or [any architectures](https://cmake.org/cmake/help/latest/prop_tgt/CUDA_ARCHITECTURES.html). *native* is good for personal use.
  - See [
CUDA GPU Compute Capability](https://developer.nvidia.com/cuda/gpus).
- ```AMDGPU_TARGETS=<arch>``` for *ggml-hip-backend*
  - *\<arch\>* can be *";"* (an empty list, acts like *native* for CUDA) or [other architectures](https://cmake.org/cmake/help/latest/prop_tgt/HIP_ARCHITECTURES.html).
  - See [(ROCm) GPU hardware specifications](https://rocm.docs.amd.com/en/latest/reference/gpu-arch-specs.html).

## Patches Explanation

This project applies a few patches into original ggml.

- ```ggml-core/ggml-h-ggml-max-name-128.patch```
  - Forbid any adjustment to the size of some array, avoiding potential ABI inconsistency.
  - Meet stable-diffusion.cpp's compiling requirement.
  - If it does harm to performance, please tell me.
- ```ggml-*-backend/ggml-use-system-base.patch```
  - Help reuse system ggml's headers and shared libraries.