#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app="$PWD/build/Radio Dial.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
arch="$(uname -m)"
if [[ ${1:-} == --universal ]]; then
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macosx14.0" Sources/*.swift -o "$scratch/$arch"
    done
    lipo -create "$scratch/arm64" "$scratch/x86_64" -output "$app/Contents/MacOS/Radio Dial"
else
    swiftc -O -target "$arch-apple-macosx14.0" Sources/*.swift -o "$app/Contents/MacOS/Radio Dial"
fi
cp Info.plist "$app/Contents/Info.plist"
cp recognize.py "$app/Contents/Resources/recognize.py"
if [[ -f RadioDial.icns ]]; then cp RadioDial.icns "$app/Contents/Resources/RadioDial.icns"; fi
codesign --force --sign - "$app"
printf '%s\n' "$app"
