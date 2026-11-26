<div align="center">
  <img src="https://readme-typing-svg.demolab.com/?font=VT323&size=70&duration=5000&pause=8000&color=39FF14&background=000000&center=false&vCenter=true&width=1000&height=80&lines=BEST+RADIO+player+on+macOS" />
</div>

# Radio DIAL

A free macOS player for internet radio and podcasts from around the world.

[Download latest release](https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/latest) · [Release notes](https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/tag/v2.2.0)

## What you can do

- **Switch stations from any app.** Hold **Option + Q** to open VI radio, a GTA VI-inspired station selector. Browse your favorites and choose whether to play immediately or confirm first.
- **Listen your way.** Switch between receiver-inspired themes and Cover Flow, use live visualizers, and customize keyboard shortcuts.
- **Record and schedule.** Save radio as MP3, WAV, FLAC, or Ogg, download podcast episodes, and set recording schedules, alarms, or a sleep timer. Keep the Mac awake and the app running for scheduled actions.
- **Find what’s playing.** Identify songs and look up lyrics.

## Install on Mac

Requires **macOS 14 or later** and supports **Apple silicon and Intel**. The Terminal installer puts the app in `~/Applications` and fetches FFmpeg if needed.

```sh
curl -fsSL https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/latest/download/install.sh | /bin/bash
```

You can also get the app ZIP from [GitHub Releases](https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/latest) and provide your own FFmpeg. If you already have a Sparkle-enabled build, use **Radio Dial → Check for Updates…**.

<details>
<summary>First-launch warning</summary>

The app uses a local signature, so macOS may show a warning on first launch. For a copy you downloaded from this repository and installed in the default location, the command below clears the quarantine attribute for that copy. Adjust the path for other locations.

```sh
xattr -dr com.apple.quarantine "$HOME/Applications/Radio Dial.app"
```

</details>

## In development

Preview these features on the [`main` branch](https://github.com/rogeryeoh49-bot/Radio-DIAL/tree/main).

- **Guided tour.** Learn station search, themes, Cover Flow, and the VI radio shortcut. Replay it from **Help → Getting Started…**.
- **Self Radio.** Show music from other apps inside Radio DIAL, including track information and artwork from Apple Music or Spotify when available. System audio detection requires macOS 14.2+ and System Audio Recording permission. [How it works](SELF_RADIO.md)
- **VI radio backdrop.** Adjust blur strength and darkness independently in **Settings → VI radio**.

## Contributing

Themes and other contributions are welcome. [Open an issue](https://github.com/rogeryeoh49-bot/Radio-DIAL/issues) or [email me](mailto:rogeryeoh49@gmail.com).

<details>
<summary>Build and release notes for contributors</summary>

### Build from source

Install the macOS Command Line Tools and FFmpeg, or set `FFMPEG_PATH`. Run `./build.sh` to build and locally sign `build/Radio Dial.app`. Use `./build.sh --universal` for Apple silicon and Intel.

Song identification supports an optional Python 3.12 environment. Without it, Radio DIAL tries ShazamKit, which requires catalog access in the signing configuration.

```sh
python3.12 -m venv "$HOME/Library/Application Support/Radio Dial/Recognition"
"$HOME/Library/Application Support/Radio Dial/Recognition/bin/python" -m pip install shazamio==0.8.1 truststore==0.10.4
```

### Publish a Sparkle update

Increment both `CFBundleShortVersionString` and `CFBundleVersion` in `Info.plist`. Run `./prepare-update.sh path/to/notes.html`, upload the generated ZIP to the matching GitHub release, then publish the generated `appcast.xml` to `main`. Test the update from an older Sparkle-enabled build. Keep a secure backup of the Sparkle signing key from Keychain and keep it out of the repository.

</details>
