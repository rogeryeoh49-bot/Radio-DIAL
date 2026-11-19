#!/bin/zsh
set -eu
cd -- "${0:A:h}"
version=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Info.plist)
tag="v${version}"
notes=${1:-}
if [[ -z "$notes" || ! -f "$notes" ]]; then
    print -u2 'Usage: ./prepare-update.sh path/to/release-notes.html (HTML fragment)'
    exit 1
fi
./build.sh --universal
out="$PWD/build/update-$tag"
mkdir -p "$out"
cp appcast.xml "$out/appcast.xml"
ditto -c -k --sequesterRsrc --keepParent "build/Radio Dial.app" "$out/Radio-Dial-macOS.zip"
cp "$notes" "$out/Radio-Dial-macOS.html"
build/sparkle/bin/generate_appcast --account org.radiodial.macos --maximum-deltas 0 --embed-release-notes --download-url-prefix "https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/download/$tag/" "$out"
print "Prepared: $out/Radio-Dial-macOS.zip and $out/appcast.xml"
print "Upload the ZIP to GitHub Release $tag, then publish the generated appcast.xml to the main branch."
