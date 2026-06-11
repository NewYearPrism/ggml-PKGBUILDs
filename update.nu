#!/usr/bin/env nu

const script_dir = path self .;
const nvcfg = path self .nvchecker.toml;
const vcache = path self .version_cache.json;
if ((which nvchecker | length) == 0) {
    print "Error: nvchecker is required. Install it with: sudo pacman -S nvchecker";
    exit 1;
}
print $"Checking upstream versions with ($nvcfg)";
let versions = nvchecker -c $nvcfg --logger json 
| lines
| each {from json} 
| where logger_name == "nvchecker.core"
| select name version 
| transpose --header-row ;
let llama_cpp_version = $versions | get "llama.cpp" | get 0 | str replace "b" "";
let stable_diffusion_cpp_tag = $versions | get "stable-diffusion.cpp" | get 0;
let stable_diffusion_cpp_version = $stable_diffusion_cpp_tag | parse --regex 'master-(?P<version>\d+)-[0-9a-f]+' | get version | get 0;
let ggml_version = $versions | get "ggml" | get 0 | str replace "v" "";
let ggml_version_parts = $ggml_version | parse --regex '^(?P<major>\d+)\.(?P<minor>\d+)\.(?P<patch>\d+)$' | get 0;
let ggml_next_version = $"($ggml_version_parts.major).($ggml_version_parts.minor).(($ggml_version_parts.patch | into int) + 1)";
let sdcpp_webui_commit = git ls-remote https://github.com/leejet/sdcpp-webui.git refs/heads/master | split row (char tab) | get 0;
print $"Found llama.cpp b($llama_cpp_version), ggml ($ggml_version), ggml upper bound ($ggml_next_version), stable-diffusion.cpp ($stable_diffusion_cpp_tag), sdcpp-webui ($sdcpp_webui_commit)";
let cached = if ($vcache | path exists) { open $vcache } else { {} };
let llama_cpp_cached = $cached | get --optional llama_cpp;
let llama_cpp_entry = if ($llama_cpp_cached | get --optional version) != $llama_cpp_version {
    print $"Downloading llama.cpp b($llama_cpp_version) source to compute sha256";
    let llama_src_url = $"https://github.com/ggml-org/llama.cpp/archive/refs/tags/b($llama_cpp_version).tar.gz";
    let sha256 = http get $llama_src_url | hash sha256;
    {"version": $llama_cpp_version, "sha256sum": $sha256}
} else {
    print $"Using cached llama.cpp b($llama_cpp_version) sha256";
    $llama_cpp_cached
};
let stable_diffusion_cpp_cached = $cached | get --optional stable_diffusion_cpp;
let stable_diffusion_cpp_entry = if ($stable_diffusion_cpp_cached | get --optional tag) != $stable_diffusion_cpp_tag {
    print $"Downloading stable-diffusion.cpp ($stable_diffusion_cpp_tag) source to compute sha256";
    let stable_diffusion_cpp_src_url = $"https://github.com/leejet/stable-diffusion.cpp/archive/refs/tags/($stable_diffusion_cpp_tag).tar.gz";
    let stable_diffusion_cpp_sha256sum = http get $stable_diffusion_cpp_src_url | hash sha256;
    {"tag": $stable_diffusion_cpp_tag, "version": $stable_diffusion_cpp_version, "sha256sum": $stable_diffusion_cpp_sha256sum}
} else {
    print $"Using cached stable-diffusion.cpp ($stable_diffusion_cpp_tag) sha256";
    $stable_diffusion_cpp_cached
};
let sdcpp_webui_cached = $cached | get --optional sdcpp_webui;
let sdcpp_webui_entry = if ($sdcpp_webui_cached | get --optional commit) != $sdcpp_webui_commit {
    print $"Downloading sdcpp-webui ($sdcpp_webui_commit) source to compute sha256";
    let sdcpp_webui_src_url = $"https://github.com/leejet/sdcpp-webui/archive/($sdcpp_webui_commit).tar.gz";
    let sdcpp_webui_sha256sum = http get $sdcpp_webui_src_url | hash sha256;
    {"commit": $sdcpp_webui_commit, "sha256sum": $sdcpp_webui_sha256sum}
} else {
    print $"Using cached sdcpp-webui ($sdcpp_webui_commit) sha256";
    $sdcpp_webui_cached
};
{
    "llama_cpp": $llama_cpp_entry,
    "stable_diffusion_cpp": $stable_diffusion_cpp_entry,
    "sdcpp_webui": $sdcpp_webui_entry,
} | to json | save --force $vcache;
print $"Saved version cache to ($vcache)";
let sha256sum = $llama_cpp_entry | get sha256sum;
let stable_diffusion_cpp_sha256sum = $stable_diffusion_cpp_entry | get sha256sum;
let sdcpp_webui_sha256sum = $sdcpp_webui_entry | get sha256sum;
let pkgbuilds = glob $"($script_dir)/**/PKGBUILD";
print $"Updating ($pkgbuilds | length) PKGBUILD files";
for pkgbuild in $pkgbuilds {
    print $"Updating ($pkgbuild)";
    open $pkgbuild
    | str replace --regex '(?m)^_llama_cpp_version=.*$' $"_llama_cpp_version=($llama_cpp_version)"
    | str replace --regex '(?m)^_ggml_version=.*$' $"_ggml_version=($ggml_version)"
    | str replace --regex '(?m)^_ggml_next_version=.*$' $"_ggml_next_version=($ggml_next_version)"
    | str replace --regex '(?m)^_llama_cpp_sha256sum=.*$' $"_llama_cpp_sha256sum=($sha256sum)"
    | str replace --regex '(?m)^_stable_diffusion_cpp_tag=.*$' $"_stable_diffusion_cpp_tag=($stable_diffusion_cpp_tag)"
    | str replace --regex '(?m)^_stable_diffusion_cpp_version=.*$' $"_stable_diffusion_cpp_version=($stable_diffusion_cpp_version)"
    | str replace --regex '(?m)^_stable_diffusion_cpp_sha256sum=.*$' $"_stable_diffusion_cpp_sha256sum=($stable_diffusion_cpp_sha256sum)"
    | str replace --regex '(?m)^_sdcpp_webui_commit=.*$' $"_sdcpp_webui_commit=($sdcpp_webui_commit)"
    | str replace --regex '(?m)^_sdcpp_webui_sha256sum=.*$' $"_sdcpp_webui_sha256sum=($sdcpp_webui_sha256sum)"
    | save --force $pkgbuild;
}
print "Done. Regenerate .SRCINFO in each AUR package directory before publishing.";
