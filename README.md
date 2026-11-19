<div align="center">
  <img src="https://readme-typing-svg.demolab.com/?font=VT323&size=70&duration=5000&pause=8000&color=39FF14&background=000000&center=false&vCenter=true&width=1000&height=80&lines=BEST+RADIO+player+on+macOS" />
</div>

# Radio DIAL

Radio DIAL is a macOS app for listening to internet radio and podcasts worldwide. It includes different themes, live audio visualizers, recording and scheduling, a sleep timer, alarms, and song/lyrics identification. 

**ALL FREE**. It is impossible to find a pure radio player that doesn't ask you to spend money. At least, I've never found one on either iOS or macOS. Yes, so I made a pure radio player to give you access to completely free radio worldwide. Full of features to fit any needs.

## What’s new in 2.1

- FR-01 adds US market selection and AM/FM station data from FCC records, with saved stream matching and fallback.
- Cover Flow can show FCC frequencies for matched US call signs, with a country selector and refined artwork presentation.
- Automatic song identification can retry when stations do not provide usable song metadata. An optional recognition setup is described below.
- Check for updates from the Radio Dial menu, or let the app check automatically. Existing installations can use the install command once to get the Sparkle updater.
- FR-01 searches FCC records within 45 km of each selected market; this is an approximation, not verified reception coverage. Stations still play through internet streams.

## Install on Mac

Paste this line into Terminal on macOS 14 or later. It works on Apple silicon and Intel Macs.

```sh
curl -fsSL https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/latest/download/install.sh | /bin/bash
```

The installer puts Radio DIAL in `~/Applications` and downloads a [standalone FFmpeg decoder](https://github.com/eugeneware/ffmpeg-static/releases/tag/b6.1.1) if needed for playback. Open it from that folder or run `open "$HOME/Applications/Radio Dial.app"`. You can also [download the app ZIP](https://github.com/rogeryeoh49-bot/Radio-DIAL/releases/latest) and provide your own FFmpeg. The app is locally signed and has not been notarized by Apple.

### If macOS blocks the app

Radio DIAL is not notarized by Apple, so macOS may show a security warning on first launch. If you downloaded Radio DIAL from this repository and want to open it, run:

```sh
xattr -dr com.apple.quarantine "$HOME/Applications/Radio Dial.app"
```

This removes macOS’s quarantine attribute from that copy of the app. If you installed it somewhere else, replace the path with the location of your Radio Dial.app. Then open the app again.

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
- Choose the FR-01 Receiver theme for AM/FM tuning, a US city selector, and four presets drawn from your favorite stations.
- Keep the app running and the Mac awake for scheduled actions. Radio Dial does not wake a sleeping Mac.
- Last.fm and Discord require your own service credentials or application ID in Settings.
- Settings and downloaded podcasts live under `~/Library/Application Support/Radio Dial`. The default recording folder is `~/Music/Radio Dial`.



### I also hope that anyone interested can join me in making this software better, ##
  
contribute different gorgeous themes or any other things, and help turn it into the No. 1 free radio player someday. 
  
## Contact me at: [rogeryeoh49@gmail.com](mailto:rogeryeoh49@gmail.com) ##

### Sparkle update releases

Radio Dial uses Sparkle for update checks. The General settings option controls automatic download and installation; automatic checks remain enabled when it is off. Before distributing the first Sparkle-enabled version, publish `appcast.xml` on the repository's `main` branch. Existing installations need to install that version once before they can receive Sparkle updates.

For every later release, increment both `CFBundleShortVersionString` and the numeric `CFBundleVersion` in `Info.plist`. Write release notes as an HTML fragment, then run `./prepare-update.sh path/to/notes.html`. Upload the generated ZIP to the matching GitHub release and publish the generated `appcast.xml` to `main` only after the ZIP is available. The Sparkle signing key is stored in the macOS Keychain under account `org.radiodial.macos`; preserve a secure backup of this private key. Never commit it to the repository. Build and test the update from an older installed Sparkle-enabled release before announcing it.
