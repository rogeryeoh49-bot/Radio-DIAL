#!/bin/bash
set -euo pipefail

install_radio_dial() (
    if [[ "$(/usr/bin/uname -s)" != Darwin ]]; then
        echo "Radio DIAL requires macOS 14 or later." >&2
        return 1
    fi
    version=$(/usr/bin/sw_vers -productVersion)
    if (( ${version%%.*} < 14 )); then
        echo "Radio DIAL requires macOS 14 or later." >&2
        return 1
    fi

    release="https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/download/v1.0.0"
    applications="$HOME/Applications"
    app="$applications/Radio Dial.app"
    tools="$HOME/Library/Application Support/Radio Dial/Tools"

    if [[ -e "$app" || -L "$app" ]]; then
        bundle_id=$(/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null || true)
        if [[ -L "$app" || "$bundle_id" != org.radiodial.macos ]]; then
            echo "Cannot replace the existing item at $app." >&2
            return 1
        fi
    fi

    /bin/mkdir -p "$applications"
    scratch=$(/usr/bin/mktemp -d "$applications/.radiodial-install.XXXXXXXX")
    # Keep the previous bundle recoverable if the replacement fails.
    trap 'if [[ -e "$scratch/previous.app" && ! -e "$app" ]]; then
        /bin/mv "$scratch/previous.app" "$app" || { echo "Previous app saved at $scratch/previous.app" >&2; exit 1; }
    fi
    /bin/rm -rf "$scratch"' EXIT

    echo "Downloading Radio DIAL…"
    /usr/bin/curl -fsSL --retry 2 -o "$scratch/Radio-Dial-macOS.zip" "$release/Radio-Dial-macOS.zip"
    /usr/bin/curl -fsSL --retry 2 -o "$scratch/Radio-Dial-macOS.zip.sha256" "$release/Radio-Dial-macOS.zip.sha256"
    (
        cd "$scratch"
        /usr/bin/shasum -a 256 -c Radio-Dial-macOS.zip.sha256
        /usr/bin/ditto -x -k Radio-Dial-macOS.zip .
    )
    /usr/bin/codesign --verify --deep --strict "$scratch/Radio Dial.app"

    if [[ ! -x /opt/homebrew/bin/ffmpeg && ! -x /usr/local/bin/ffmpeg && ! -x "$tools/ffmpeg" ]]; then
        if [[ "$(/usr/sbin/sysctl -n hw.optional.arm64 2>/dev/null || true)" == 1 ]]; then
            asset=ffmpeg-darwin-arm64.gz
            hash=8923876afa8db5585022d7860ec7e589af192f441c56793971276d450ed3bbfa
        else
            asset=ffmpeg-darwin-x64.gz
            hash=929b375c1182d956c51f7ac25e0b2b0411fb01f6f407aa15c9758efeb4242106
        fi
        echo "Downloading the FFmpeg audio decoder…"
        /usr/bin/curl -fsSL --retry 2 -o "$scratch/$asset" "https://github.com/eugeneware/ffmpeg-static/releases/download/b6.1.1/$asset"
        actual=$(/usr/bin/shasum -a 256 < "$scratch/$asset")
        if [[ "${actual%% *}" != "$hash" ]]; then
            echo "FFmpeg download failed checksum verification." >&2
            return 1
        fi
        /usr/bin/gunzip -c "$scratch/$asset" > "$scratch/ffmpeg"
        /bin/mkdir -p "$tools"
        /usr/bin/install -m 755 "$scratch/ffmpeg" "$tools/ffmpeg"
    fi

    if [[ -e "$app" ]]; then
        /bin/mv "$app" "$scratch/previous.app"
    fi
    /bin/mv "$scratch/Radio Dial.app" "$app"
    /bin/rm -rf "$scratch"
    trap - EXIT
    printf 'Installed Radio DIAL in %s.\nOpen it with: open "%s"\n' "$applications" "$app"
)

install_radio_dial
