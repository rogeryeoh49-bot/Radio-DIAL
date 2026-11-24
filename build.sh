#!/bin/zsh
set -eu
cd -- "${0:A:h}"
app="$PWD/build/Radio Dial.app"
sparkle="$PWD/build/sparkle"
if [[ ! -d "$sparkle/Sparkle.framework" ]]; then
    mkdir -p "$sparkle"
    curl -fL --retry 2 https://github.com/sparkle-project/Sparkle/releases/download/2.10.1/Sparkle-2.10.1.tar.xz -o "$sparkle/Sparkle.tar.xz"
    print '1a856d2a9edb8e628de88121d7be04cf0e2167f8641650b78fca00b14244cf27  '"$sparkle/Sparkle.tar.xz" | shasum -a 256 -c -
    tar -xJf "$sparkle/Sparkle.tar.xz" -C "$sparkle"
fi
mkdir -p "$app/Contents/Frameworks"
rm -rf "$app/Contents/Frameworks/Sparkle.framework"
ditto "$sparkle/Sparkle.framework" "$app/Contents/Frameworks/Sparkle.framework"
flags=(-F "$sparkle" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
arch="$(uname -m)"
if [[ ${1:-} == --universal ]]; then
    scratch="$(mktemp -d)"
    trap 'rm -rf "$scratch"' EXIT
    for arch in arm64 x86_64; do
        swiftc -O -target "$arch-apple-macosx14.0" Sources/*.swift "${flags[@]}" -o "$scratch/$arch"
    done
    lipo -create "$scratch/arm64" "$scratch/x86_64" -output "$app/Contents/MacOS/Radio Dial"
else
    swiftc -O -target "$arch-apple-macosx14.0" Sources/*.swift "${flags[@]}" -o "$app/Contents/MacOS/Radio Dial"
fi
cp Info.plist "$app/Contents/Info.plist"
cp recognize.py "$app/Contents/Resources/recognize.py"
cp Resources/VI-radio-selection.wav "$app/Contents/Resources/VI-radio-selection.wav"
cp Resources/SelfRadio.png "$app/Contents/Resources/SelfRadio.png"
xcrun actool Resources/Assets.xcassets --compile "$app/Contents/Resources" --platform macosx --minimum-deployment-target 14.0
cp Resources/Punctum-Regular.ttf Resources/Punctum-OFL.txt Resources/BarlowCondensed-Regular.ttf Resources/BarlowCondensed-SemiBold.ttf Resources/Barlow-Regular.ttf Resources/Barlow-OFL.txt "$app/Contents/Resources/"
if [[ -f RadioDial.icns ]]; then cp RadioDial.icns "$app/Contents/Resources/RadioDial.icns"; fi
cp Resources/AppIcon/RadioDial-Dark.icns "$app/Contents/Resources/RadioDial-Dark.icns"
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
