#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app="$PWD/build/Radio Dial.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
arch="$(uname -m)"
swiftc -O -target "$arch-apple-macosx14.0" Sources/*.swift -o "$app/Contents/MacOS/Radio Dial"
cp Info.plist "$app/Contents/Info.plist"
cp recognize.py "$app/Contents/Resources/recognize.py"
if [[ -f RadioDial.icns ]]; then cp RadioDial.icns "$app/Contents/Resources/RadioDial.icns"; fi
codesign --force --sign - "$app"
printf '%s\n' "$app"
