const script_dir = path self .;
const nvcfg = path self .nvchecker.toml;
const vcache = path self .version_cache.json;
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
touch $vcache;
let cached = open $vcache;
let llama_cpp_cached = $cached | get --optional llama_cpp;
let llama_cpp_entry = if ($llama_cpp_cached | get --optional version) != $llama_cpp_version {
    let llama_src_url = $"https://github.com/ggml-org/llama.cpp/archive/refs/tags/b($llama_cpp_version).tar.gz";
    let sha256 = http get $llama_src_url | hash sha256;
    {"version": $llama_cpp_version, "sha256sum": $sha256}
} else {
    $llama_cpp_cached
};
let stable_diffusion_cpp_cached = $cached | get --optional stable_diffusion_cpp;
let stable_diffusion_cpp_entry = if ($stable_diffusion_cpp_cached | get --optional tag) != $stable_diffusion_cpp_tag {
    let stable_diffusion_cpp_src_url = $"https://github.com/leejet/stable-diffusion.cpp/archive/refs/tags/($stable_diffusion_cpp_tag).tar.gz";
    let stable_diffusion_cpp_sha256sum = http get $stable_diffusion_cpp_src_url | hash sha256;
    {"tag": $stable_diffusion_cpp_tag, "version": $stable_diffusion_cpp_version, "sha256sum": $stable_diffusion_cpp_sha256sum}
} else {
    $stable_diffusion_cpp_cached
};
{
    "llama_cpp": $llama_cpp_entry,
    "stable_diffusion_cpp": $stable_diffusion_cpp_entry,
} | to json | save --force $vcache;
let sha256sum = $llama_cpp_entry | get sha256sum;
let stable_diffusion_cpp_sha256sum = $stable_diffusion_cpp_entry | get sha256sum;
let templates = glob $"($script_dir)/**/PKGBUILD.in";
for tmpl in $templates {
    let pkgbuild = ($tmpl | str replace --regex '\.in$' '');
    open $tmpl
    | str replace @LLAMA_CPP_VERSION@ $llama_cpp_version
    | str replace @GGML_VERSION@ $ggml_version
    | str replace @SHA256SUM@ $sha256sum
    | str replace @STABLE_DIFFUSION_CPP_TAG@ $stable_diffusion_cpp_tag
    | str replace @STABLE_DIFFUSION_CPP_VERSION@ $stable_diffusion_cpp_version
    | str replace @STABLE_DIFFUSION_CPP_SHA256SUM@ $stable_diffusion_cpp_sha256sum
    | save --force $pkgbuild;
}
