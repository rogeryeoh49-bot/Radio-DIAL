# Radio DIAL

Radio DIAL is a macOS app for listening to internet radio and podcasts. It includes an FM receiver theme, live audio visualizers, recording and scheduling, a sleep timer, alarms, and song identification.

## Build and run

Run `./build.sh` with the macOS Command Line Tools installed. It builds and locally signs `build/Radio Dial.app` for the current Mac. Requires macOS 14 or later. The player looks for FFmpeg in Homebrew’s default locations or at `FFMPEG_PATH`.

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
