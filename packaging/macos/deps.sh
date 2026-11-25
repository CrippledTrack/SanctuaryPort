#!/usr/bin/env bash
# Builds the x86_64 libraries the native macOS build links into out/macos-deps (macOS on Apple
# silicon runs the build under Rosetta 2; see docs/macos.md). Versions match the Windows build's
# MSYS2 packages. Header-only dependencies (Boost, robin-map, Vulkan headers) come from Homebrew:
# headers do not depend on the CPU.
#   bash packaging/macos/deps.sh
# Needs: Xcode command line tools (clang), cmake, ninja, pkg-config, curl, Homebrew's boost,
# robin-map and vulkan-headers. Sources are downloaded once into out/macos-deps-src.
set -euo pipefail
cd -- "$(dirname -- "$0")/../.."
prefix=$PWD/out/macos-deps
src=$PWD/out/macos-deps-src
mkdir -p "$prefix" "$src"
export MACOSX_DEPLOYMENT_TARGET=${MACOSX_DEPLOYMENT_TARGET:-14.0}
# Only this prefix: Homebrew's arm64 libraries must never be picked up.
export PKG_CONFIG_LIBDIR=$prefix/lib/pkgconfig
export PKG_CONFIG_PATH=
cmake_common=(-G Ninja -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=x86_64
              -DCMAKE_INSTALL_PREFIX="$prefix" -DCMAKE_PREFIX_PATH="$prefix"
              -DCMAKE_FIND_FRAMEWORK=LAST -DCMAKE_INSTALL_NAME_DIR=@rpath)

fetch() { # url file
    [[ -f $src/$2 ]] || curl -sSfL -o "$src/$2" "$1"
}
done_stamp() { [[ -f $prefix/.done-$1 ]]; }
mark_done() { touch "$prefix/.done-$1"; }
cmake_build() { # name source-dir [cmake args...]
    local name=$1 dir=$2; shift 2
    rm -rf "$src/build-$name" # no stale cache from an earlier attempt
    cmake -S "$dir" -B "$src/build-$name" "${cmake_common[@]}" "$@" > "$src/$name.log" 2>&1
    ninja -C "$src/build-$name" install >> "$src/$name.log" 2>&1 || { tail -30 "$src/$name.log"; exit 1; }
    mark_done "$name"; echo "built $name"
}

if ! done_stamp fmt; then
    fetch https://github.com/fmtlib/fmt/releases/download/12.2.1/fmt-12.2.1.zip fmt-12.2.1.zip
    rm -rf "$src/fmt-12.2.1" && (cd "$src" && unzip -q fmt-12.2.1.zip)
    cmake_build fmt "$src/fmt-12.2.1" -DFMT_TEST=OFF -DFMT_DOC=OFF -DBUILD_SHARED_LIBS=OFF
fi
if ! done_stamp xxhash; then
    fetch https://github.com/Cyan4973/xxHash/archive/refs/tags/v0.8.4.tar.gz xxhash-0.8.4.tar.gz
    rm -rf "$src/xxHash-0.8.4" && tar -xzf "$src/xxhash-0.8.4.tar.gz" -C "$src"
    cmake_build xxhash "$src/xxHash-0.8.4/build/cmake" -DXXHASH_BUILD_XXHSUM=OFF -DBUILD_SHARED_LIBS=OFF
fi
if ! done_stamp zydis; then
    fetch https://github.com/zyantific/zydis/archive/refs/tags/v4.1.1.tar.gz zydis-4.1.1.tar.gz
    fetch https://github.com/zyantific/zycore-c/archive/refs/tags/v1.5.2.tar.gz zycore-1.5.2.tar.gz
    rm -rf "$src/zydis-4.1.1" && tar -xzf "$src/zydis-4.1.1.tar.gz" -C "$src"
    # The tag archive leaves the zycore submodule empty.
    rm -rf "$src/zydis-4.1.1/dependencies/zycore" && mkdir -p "$src/zydis-4.1.1/dependencies"
    tar -xzf "$src/zycore-1.5.2.tar.gz" -C "$src/zydis-4.1.1/dependencies"
    mv "$src/zydis-4.1.1/dependencies/zycore-c-1.5.2" "$src/zydis-4.1.1/dependencies/zycore"
    # Zycore is also installed on its own: Zydis's package looks Zycore up when it is used, and
    # must find this x86_64 one (not Homebrew's arm64 Zycore).
    cmake_build zycore "$src/zydis-4.1.1/dependencies/zycore" -DZYCORE_BUILD_SHARED_LIB=OFF
    cmake_build zydis "$src/zydis-4.1.1" -DZYDIS_BUILD_TOOLS=OFF -DZYDIS_BUILD_EXAMPLES=OFF \
        -DZYDIS_BUILD_SHARED_LIB=OFF -DZYDIS_BUILD_DOXYGEN=OFF
fi
if ! done_stamp sdl3; then
    fetch https://github.com/libsdl-org/SDL/releases/download/release-3.4.20/SDL3-3.4.20.tar.gz SDL3-3.4.20.tar.gz
    rm -rf "$src/SDL3-3.4.20" && tar -xzf "$src/SDL3-3.4.20.tar.gz" -C "$src"
    # Shared: a static SDL3 would need its frameworks spelled out wherever it is linked.
    cmake_build sdl3 "$src/SDL3-3.4.20" -DSDL_SHARED=ON -DSDL_STATIC=OFF -DSDL_TEST_LIBRARY=OFF \
        -DSDL_EXAMPLES=OFF
fi
if ! done_stamp vulkan-loader; then
    fetch https://github.com/KhronosGroup/Vulkan-Loader/archive/refs/tags/v1.4.363.tar.gz vulkan-loader-1.4.363.tar.gz
    rm -rf "$src/Vulkan-Loader-1.4.363" && tar -xzf "$src/vulkan-loader-1.4.363.tar.gz" -C "$src"
    cmake_build vulkan-loader "$src/Vulkan-Loader-1.4.363" -DBUILD_TESTS=OFF \
        -DVulkanHeaders_DIR="$(brew --prefix vulkan-headers)/share/cmake/VulkanHeaders"
fi
if ! done_stamp mimalloc; then
    # The process's malloc, confined to a region below 1 TiB (src/macos_heap.c): the game packs
    # pointers into 40 bits, and host heap objects (threads, TLS, sync objects) reach it.
    # MI_OSX_ZONE: mimalloc becomes the default malloc zone, for system libraries too.
    fetch https://github.com/microsoft/mimalloc/archive/refs/tags/v2.2.4.tar.gz mimalloc-2.2.4.tar.gz
    rm -rf "$src/mimalloc-2.2.4" && tar -xzf "$src/mimalloc-2.2.4.tar.gz" -C "$src"
    cmake_build mimalloc "$src/mimalloc-2.2.4" -DMI_OVERRIDE=ON -DMI_OSX_ZONE=ON -DMI_OSX_INTERPOSE=OFF \
        -DMI_BUILD_SHARED=OFF -DMI_BUILD_STATIC=ON -DMI_BUILD_OBJECT=ON -DMI_BUILD_TESTS=OFF \
        -DMI_INSTALL_TOPLEVEL=ON
fi
if [[ ! -f $prefix/include/vma/vk_mem_alloc.h ]]; then
    # Header-only VulkanMemoryAllocator 3.5.0 (as MSYS2 ships it for Windows; Homebrew has none).
    mkdir -p "$prefix/include/vma"
    if [[ -f out/win/root/clang64/include/vma/vk_mem_alloc.h ]]; then
        cp out/win/root/clang64/include/vma/vk_mem_alloc.h "$prefix/include/vma/"
    else
        curl -sSfL -o "$prefix/include/vma/vk_mem_alloc.h" \
            https://raw.githubusercontent.com/GPUOpen-LibrariesAndSDKs/VulkanMemoryAllocator/v3.5.0/include/vk_mem_alloc.h
    fi
fi
if ! done_stamp ffmpeg; then
    fetch https://ffmpeg.org/releases/ffmpeg-9.1.tar.xz ffmpeg-9.1.tar.xz
    rm -rf "$src/ffmpeg-9.1" && tar -xJf "$src/ffmpeg-9.1.tar.xz" -C "$src"
    # No nasm here: --disable-x86asm (slower video decode, nothing else). Shared, with @rpath names.
    (cd "$src/ffmpeg-9.1" && ./configure --prefix="$prefix" --enable-cross-compile --arch=x86_64 \
        --target-os=darwin --cc="clang -arch x86_64" --cxx="clang++ -arch x86_64" \
        --extra-ldflags="-arch x86_64" --disable-x86asm --disable-programs --disable-doc \
        --enable-shared --disable-static --install-name-dir=@rpath \
        --pkg-config-flags="" > "$src/ffmpeg.log" 2>&1) || { tail -30 "$src/ffmpeg.log"; exit 1; }
    make -C "$src/ffmpeg-9.1" -j"$(sysctl -n hw.ncpu)" install >> "$src/ffmpeg.log" 2>&1 \
        || { tail -30 "$src/ffmpeg.log"; exit 1; }
    mark_done ffmpeg; echo "built ffmpeg"
fi
echo "x86_64 dependencies in $prefix"
