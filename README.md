<div align="center">
  <img src="https://readme-typing-svg.demolab.com/?font=VT323&size=70&duration=5000&pause=8000&color=39FF14&background=000000&center=false&vCenter=true&width=1000&height=80&lines=BEST+RADIO+player+on+macOS" />
</div>

# Radio DIAL

Radio DIAL is a macOS app for listening to internet radio and podcasts. It includes an FM receiver theme, live audio visualizers, recording and scheduling, a sleep timer, alarms, and song identification.

## Install on Mac

Paste this line into Terminal on macOS 14 or later. It works on Apple silicon and Intel Macs.

```sh
curl -fsSL https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/latest/download/install.sh | /bin/bash
```

The installer puts Radio DIAL in `~/Applications` and downloads a [standalone FFmpeg decoder](https://github.com/eugeneware/ffmpeg-static/releases/tag/b6.1.1) if needed for playback. Open it from that folder or run `open "$HOME/Applications/Radio Dial.app"`. You can also [download the app ZIP](https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/latest) and provide your own FFmpeg. The app is locally signed and has not been notarized by Apple.

## Build and run

Run `./build.sh` with the macOS Command Line Tools installed. It builds and locally signs `build/Radio Dial.app` for the current Mac. Use `./build.sh --universal` to build for Apple silicon and Intel. For a source build, install FFmpeg with Homebrew or set `FFMPEG_PATH`.

Song identification can use the optional recognition environment. Install it with the two commands below. Without it, the app tries ShazamKit, which requires catalog access in the app’s signing configuration.

```sh
python3.12 -m venv "$HOME/Library/Application Support/Radio Dial/Recognition"
"$HOME/Library/Application Support/Radio Dial/Recognition/bin/python" -m pip install shazamio==0.8.1 truststore==0.10.4
```

## Using it

- Select a station to play it. Right-click rows for stream tests, favorites, podcast downloads and other actions.
- Use the record button to choose MP3, WAV, FLAC or Ogg, with optional splitting when the stream supplies new track metadata.
- Use the top-right menu for the sleep timer, alarms, scheduled recording, playlists, equalizer presets, themes, stream status and settings.
- Choose the FR-01 Receiver theme for a tuning dial, country selection, and four presets drawn from your favorite stations.
- Keep the app running and the Mac awake for scheduled actions. Radio Dial does not wake a sleeping Mac.
- Last.fm and Discord require your own service credentials or application ID in Settings.
- Settings and downloaded podcasts live under `~/Library/Application Support/Radio Dial`. The default recording folder is `~/Music/Radio Dial`.
