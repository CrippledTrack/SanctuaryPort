#!/usr/bin/env bash
# Builds the native macOS executables (x86_64; Apple silicon runs them under Rosetta 2) into
# out/macos: sanctuary-probe and sanctuary-gpu-capabilities, with the dylibs they load in
# out/macos/lib. Run packaging/macos/deps.sh first. docs/macos.md describes the setup.
set -euo pipefail
cd -- "$(dirname -- "$0")/../.."
deps=$PWD/out/macos-deps
[[ -f $deps/.done-mimalloc && -f $deps/.done-ffmpeg ]] || { echo "Run packaging/macos/deps.sh first." >&2; exit 1; }
for tool in cmake ninja pkg-config glslang; do
    command -v "$tool" >/dev/null || { echo "Need $tool (Homebrew)." >&2; exit 1; }
done
if [[ ! -f gpu/third_party/fsr-vulkan/CMakeLists.txt || ! -f gpu/third_party/imgui/imgui.h ||
      ! -f gpu/third_party/xbyak/xbyak/xbyak.h ]]; then
    git submodule update --init --recursive
fi
for patch in gpu/patches/fsr-vulkan/*.patch; do
    if ! git -C gpu/third_party/fsr-vulkan apply --reverse --check "$PWD/$patch" 2>/dev/null; then
        git -C gpu/third_party/fsr-vulkan apply "$PWD/$patch"
    fi
done
# x86_64 libraries from out/macos-deps only; header-only packages from Homebrew (headers do not
# depend on the CPU). Homebrew's own (arm64) libraries must not be found.
export PKG_CONFIG_LIBDIR=$deps/lib/pkgconfig PKG_CONFIG_PATH=
brew=$(brew --prefix)
headers="$brew/opt/boost;$brew/opt/robin-map;$brew/opt/vulkan-headers"
build=out/macos/build
if [[ ! -f $build/build.ninja ]]; then
    cmake -S gpu -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=RelWithDebInfo -DSANCTUARY_PGO=off \
        -DSANCTUARY_LTO="${SANCTUARY_LTO:-OFF}" -DCMAKE_OSX_ARCHITECTURES=x86_64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=14.0 -DCMAKE_PREFIX_PATH="$deps;$headers" \
        -DCMAKE_FIND_FRAMEWORK=LAST -DCMAKE_DISABLE_FIND_PACKAGE_miniz=ON -DVulkan_INCLUDE_DIR="$brew/opt/vulkan-headers/include" \
        -DVulkan_LIBRARY="$deps/lib/libvulkan.1.dylib" > out/macos-configure.log 2>&1 \
        || { tail -40 out/macos-configure.log >&2; exit 1; }
fi
if ! ninja -C "$build" sanctuary-probe sanctuary-gpu-capabilities > out/macos-build.log 2>&1; then
    grep -v '^\[' out/macos-build.log | grep -E "error|Error" -A3 | head -60 >&2
    echo 'macOS build failed (full log: out/macos-build.log)' >&2; exit 1
fi
mkdir -p out/macos/lib
cp "$build/sanctuary-probe" "$build/sanctuary-gpu-capabilities" out/macos/
cp -a "$deps"/lib/*.dylib out/macos/lib/
echo "Built $PWD/out/macos/sanctuary-probe"
