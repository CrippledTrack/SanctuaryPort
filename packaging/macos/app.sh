#!/usr/bin/env bash
# Builds dist/SanctuaryPort.app: the launcher (native arm64) with everything PLAY needs inside, so a
# player needs no Homebrew, Xcode tools or Python. Run on an Apple silicon Mac after
# packaging/macos/build.sh. The game's runtime is the x86_64 build, which runs under Rosetta 2.
#
#   Contents/MacOS/SanctuaryPort          the entry point (this script's ENTRY below): sets the
#                                         folders, then starts the launcher
#   Contents/MacOS/sanctuaryport-launcher the launcher (arm64)
#   Contents/Resources/port/              the port folder (SANCTUARY_PORT_DIR): run.sh, run.py,
#                                         scripts, patches, launcher, assets,
#       bin/                              sanctuary-probe, sanctuary-gpu-capabilities (x86_64)
#       bin/kosmickrisp/                  the x86_64 KosmicKrisp Vulkan driver, its ICD file and
#                                         licence (out/macos/kosmickrisp or SANCTUARY_KOSMICKRISP_DIR)
#       lib/                              SDL3, FFmpeg and the Vulkan loader (x86_64)
#       python/                           Python (python-build-standalone, arm64) with Pillow
# Saves, sanctuary.ini and the prepared game: ~/Library/Application Support/SanctuaryPort
# (SANCTUARY_DATA_DIR), as the AppImage uses ~/.local/share.
#
# The app is signed ad hoc: it runs on the Mac that built it; a downloaded copy needs
# `xattr -dr com.apple.quarantine SanctuaryPort.app` (or right-click > Open) until it is signed with
# a Developer ID and notarized.
#   bash packaging/macos/app.sh
set -euo pipefail
cd -- "$(dirname -- "$0")/../.."
root=$PWD
export PATH=/opt/homebrew/bin:$PATH

[[ $(uname -m) == arm64 ]] || { echo 'Build the app on an Apple silicon Mac.' >&2; exit 1; }
[[ -x out/macos/sanctuary-probe && -x out/macos/sanctuary-gpu-capabilities ]] ||
    { echo 'Build the runtime first: bash packaging/macos/build.sh' >&2; exit 1; }
deps=out/macos-deps/lib
kk=${SANCTUARY_KOSMICKRISP_DIR:-out/macos/kosmickrisp}
[[ -f $kk/libvulkan_kosmickrisp.dylib ]] ||
    { echo "No x86_64 KosmicKrisp in $kk (docs/macos.md; SANCTUARY_KOSMICKRISP_DIR)." >&2; exit 1; }
for tool in cargo codesign install_name_tool iconutil sips vtool curl; do
    command -v "$tool" >/dev/null || { echo "Need $tool." >&2; exit 1; }
done

PYTHON_VERSION=3.12.10 # as the Windows package (packaging/windows/fetch_python.py)
PYTHON_BUILD=20250409
PYTHON_URL=https://github.com/astral-sh/python-build-standalone/releases/download/$PYTHON_BUILD/cpython-$PYTHON_VERSION+$PYTHON_BUILD-aarch64-apple-darwin-install_only.tar.gz
# Pillow only: iced-x86 is for the ISA rewrite on CPUs without MOVBE/BMI1/LZCNT, and Rosetta 2
# reports them all (CPU: complete); its pinned 1.21.0 has no arm64 macOS wheel either.
WHEELS=(pillow)
MESA_LICENSE_URL=https://gitlab.freedesktop.org/mesa/mesa/-/raw/main/docs/license.rst
cache=out/macos-app-cache
mkdir -p "$cache"
fetch() { # url file
    [[ -s $cache/$2 ]] && return
    curl -sSfL -o "$cache/$2.part" "$1" || { echo "Download failed: $1" >&2; exit 1; }
    mv -f "$cache/$2.part" "$cache/$2"
}

version=$(sed -n 's/^version = "\(.*\)"/\1/p' launcher-rust/Cargo.toml | head -1)
echo "SanctuaryPort.app $version"

# The launcher, native arm64.
(cd launcher-rust && cargo build --release --quiet)
launcher=launcher-rust/target/release/sanctuaryport-launcher

app=dist/SanctuaryPort.app
rm -rf "$app"
contents=$app/Contents
port=$contents/Resources/port
mkdir -p "$contents/MacOS" "$port/bin" "$port/lib"

# The port folder: what run.sh and run.py read (packaging/default.nix installs the same).
cp run.sh run.py "$port/"
cp -R scripts patches launcher assets "$port/"
[[ -d fsr4_shaders ]] && cp -R fsr4_shaders "$port/"
find "$port" -name __pycache__ -type d -prune -exec rm -rf {} +

# The runtime (x86_64): binaries in bin/, their dylibs in lib/ (their rpath @executable_path/../lib).
# The build's absolute rpath to out/macos-deps is removed, so only the app's own copies load.
for exe in sanctuary-probe sanctuary-gpu-capabilities; do
    cp out/macos/$exe "$port/bin/"
    install_name_tool -delete_rpath "$root/$deps" "$port/bin/$exe" 2>/dev/null || true
done
# The dylibs the binaries load (and those load), by their install names.
needed() { otool -L "$1" | awk 'NR>1 && $1 ~ /^@rpath\// {sub("@rpath/","",$1); print $1}'; }
queue=($(needed "$port/bin/sanctuary-probe") $(needed "$port/bin/sanctuary-gpu-capabilities"))
while ((${#queue[@]})); do
    name=${queue[0]}; queue=("${queue[@]:1}")
    [[ -e $port/lib/$name ]] && continue
    source=$deps/$name; [[ -e $source ]] || source=out/macos/lib/$name
    [[ -e $source ]] || { echo "Missing dylib $name" >&2; exit 1; }
    cp -L "$source" "$port/lib/$name"
    chmod u+w "$port/lib/$name"
    for rpath in $(otool -l "$port/lib/$name" | awk '/LC_RPATH/{getline; getline; print $2}'); do
        [[ $rpath == /* ]] && install_name_tool -delete_rpath "$rpath" "$port/lib/$name"
    done
    queue+=($(needed "$port/lib/$name"))
done
# The Vulkan loader opens the driver itself (no link): it is not in the list above.
if [[ ! -e $port/lib/libvulkan.1.dylib ]]; then
    cp -L "$deps/libvulkan.1.dylib" "$port/lib/"
fi

# The Vulkan driver: the ICD file names the library relative to itself, which the loader allows.
mkdir -p "$port/bin/kosmickrisp"
cp "$kk/libvulkan_kosmickrisp.dylib" "$port/bin/kosmickrisp/"
chmod u+w "$port/bin/kosmickrisp/libvulkan_kosmickrisp.dylib"
install_name_tool -id @rpath/libvulkan_kosmickrisp.dylib "$port/bin/kosmickrisp/libvulkan_kosmickrisp.dylib"
api=$(sed -n 's/.*"api_version": *"\([^"]*\)".*/\1/p' "$kk/kosmickrisp_icd.x86_64.json")
cat > "$port/bin/kosmickrisp/kosmickrisp_icd.x86_64.json" <<EOF
{
    "ICD": {
        "api_version": "${api:-1.4.0}",
        "library_path": "./libvulkan_kosmickrisp.dylib"
    },
    "file_format_version": "1.0.1"
}
EOF
fetch "$MESA_LICENSE_URL" mesa-license.rst
cp "$cache/mesa-license.rst" "$port/bin/kosmickrisp/LICENSE-Mesa.rst"

# Python with the wheels run.py's scripts import.
fetch "$PYTHON_URL" "python-$PYTHON_VERSION-$PYTHON_BUILD-arm64.tar.gz"
tar -xzf "$cache/python-$PYTHON_VERSION-$PYTHON_BUILD-arm64.tar.gz" -C "$port" # python/
"$port/python/bin/python3" -m pip install --quiet --disable-pip-version-check --no-warn-script-location \
    --only-binary=:all: --cache-dir "$cache/pip" "${WHEELS[@]}"
"$port/python/bin/python3" -c 'import PIL'
find "$port/python" -name __pycache__ -type d -prune -exec rm -rf {} +

# The launcher and its entry point.
cp "$launcher" "$contents/MacOS/sanctuaryport-launcher"
cat > "$contents/MacOS/SanctuaryPort" <<'ENTRY'
#!/bin/bash
# SanctuaryPort.app's entry point (packaging/macos/app.sh): the port folder inside the app, the
# player's data in Application Support, the prebuilt runtime and the bundled Python, then the
# launcher. Arguments go to the launcher (--play, --game, --update, --data-dir).
set -euo pipefail
contents=$(cd -- "$(dirname -- "$0")/.." && pwd -P)
port=$contents/Resources/port
export SANCTUARY_PORT_DIR=$port
export SANCTUARY_DATA_DIR=${SANCTUARY_DATA_DIR:-$HOME/Library/Application Support/SanctuaryPort}
export SANCTUARY_PREBUILT=1
export PYTHON=$port/python/bin/python3
mkdir -p "$SANCTUARY_DATA_DIR"
cd -- "$port"
exec "$contents/MacOS/sanctuaryport-launcher" "$@"
ENTRY
chmod 755 "$contents/MacOS/SanctuaryPort"

# Icon from the launcher's PNG.
iconset=$cache/SanctuaryPort.iconset
rm -rf "$iconset"; mkdir -p "$iconset"
for size in 16 32 128 256 512; do
    sips -z $size $size launcher/sanctuary.png --out "$iconset/icon_${size}x${size}.png" >/dev/null
    sips -z $((size * 2)) $((size * 2)) launcher/sanctuary.png --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$contents/Resources/SanctuaryPort.icns"

# The oldest macOS every binary inside loads on (the driver is usually the newest).
minos=$(for f in "$contents/MacOS/sanctuaryport-launcher" "$port"/bin/sanctuary-* "$port"/bin/kosmickrisp/*.dylib "$port"/lib/*.dylib; do
    vtool -show-build "$f" 2>/dev/null | awk '$1 == "minos" {print $2}'
done | sort -t. -k1,1n -k2,2n -k3,3n | tail -1)
cat > "$contents/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>SanctuaryPort</string>
    <key>CFBundleDisplayName</key><string>SanctuaryPort</string>
    <key>CFBundleIdentifier</key><string>io.github.cadugimenes.sanctuaryport</string>
    <key>CFBundleVersion</key><string>$version</string>
    <key>CFBundleShortVersionString</key><string>$version</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleExecutable</key><string>SanctuaryPort</string>
    <key>CFBundleIconFile</key><string>SanctuaryPort</string>
    <key>LSMinimumSystemVersion</key><string>${minos:-14.0}</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>LSApplicationCategoryType</key><string>public.app-category.games</string>
    <key>NSHighResolutionCapable</key><true/>
</dict>
</plist>
EOF

# Ad-hoc signatures, inside out: every Mach-O file, then the app.
while IFS= read -r -d '' f; do
    if file -b "$f" | grep -q Mach-O; then codesign --force --sign - "$f" 2>/dev/null; fi
done < <(find "$contents/Resources" "$contents/MacOS" -type f -print0)
codesign --force --sign - "$app"
codesign --verify --strict "$app"
echo "Built $root/$app ($(du -sh "$app" | cut -f1); macOS $minos or later; Rosetta 2 for the game)"
