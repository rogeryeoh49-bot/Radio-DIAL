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
universal=0
debug=0
usage_url="${RADIO_DIAL_USAGE_URL-https://radio-dial-usage.rogeryeoh49.workers.dev/v1/playback}"
for option in "$@"; do
    case "$option" in
        --universal) universal=1 ;;
        --debug) debug=1 ;;
        *) print -u2 -- "Unknown build option: $option"; exit 2 ;;
    esac
done
if (( debug )); then
    flags+=(-Onone -g -D DEBUG)
else
    flags+=(-O)
    if [[ -n $usage_url && ! $usage_url =~ '^https://[^/?#@[:space:]]+(/[^?#[:space:]]*)?$' ]]; then
        print -u2 -- "RADIO_DIAL_USAGE_URL must be an HTTPS endpoint without credentials, query, or fragment."
        exit 2
    fi
fi
scratch="$(mktemp -d)"
trap 'rm -rf "$scratch"' EXIT
icon="$scratch/RadioDial.icon"
mkdir -p "$icon/Assets" "$scratch/compiled-icon"
cp Resources/AppIcon/Appearance.json "$icon/icon.json"
iconutil --convert iconset --output "$scratch/light.iconset" RadioDial.icns
iconutil --convert iconset --output "$scratch/dark.iconset" Resources/AppIcon/RadioDial-Dark.icns
# Strip the legacy icon's surrounding padding before Icon Composer adds the system mask.
sips --cropToHeightWidth 836 836 --cropOffset 93 94 \
    "$scratch/light.iconset/icon_512x512@2x.png" --out "$icon/Assets/Light.png" >/dev/null
sips --cropToHeightWidth 836 836 --cropOffset 93 94 \
    "$scratch/dark.iconset/icon_512x512@2x.png" --out "$icon/Assets/Dark.png" >/dev/null
sips --resampleHeightWidth 1024 1024 "$icon/Assets/Light.png" "$icon/Assets/Dark.png" >/dev/null
xcrun actool --compile "$scratch/compiled-icon" --platform macosx --minimum-deployment-target 14.0 \
    --app-icon RadioDial --output-partial-info-plist "$scratch/icon-info.plist" "$icon"

if (( universal )); then
    for arch in arm64 x86_64; do
        swiftc -target "$arch-apple-macosx14.0" Sources/*.swift "${flags[@]}" -o "$scratch/$arch"
    done
    lipo -create "$scratch/arm64" "$scratch/x86_64" -output "$app/Contents/MacOS/Radio Dial"
else
    swiftc -target "$arch-apple-macosx14.0" Sources/*.swift "${flags[@]}" -o "$app/Contents/MacOS/Radio Dial"
fi
cp Info.plist "$app/Contents/Info.plist"
if (( ! debug )) && [[ -n $usage_url ]]; then
    /usr/bin/plutil -insert RadioDialUsageStatisticsURL -string "$usage_url" "$app/Contents/Info.plist"
fi
cp recognize.py "$app/Contents/Resources/recognize.py"
cp Resources/VI-radio-selection.wav "$app/Contents/Resources/VI-radio-selection.wav"
cp Resources/SelfRadio.png "$app/Contents/Resources/SelfRadio.png"
cp "$scratch/compiled-icon/Assets.car" "$app/Contents/Resources/Assets.car"
cp Resources/Punctum-Regular.ttf Resources/Punctum-OFL.txt Resources/BarlowCondensed-Regular.ttf Resources/BarlowCondensed-SemiBold.ttf Resources/Barlow-Regular.ttf Resources/Barlow-OFL.txt "$app/Contents/Resources/"
cp RadioDial.icns "$app/Contents/Resources/RadioDial.icns"
cp Resources/AppIcon/RadioDial-Dark.icns "$app/Contents/Resources/RadioDial-Dark.icns"
codesign --force --deep --sign - "$app"
printf '%s\n' "$app"
