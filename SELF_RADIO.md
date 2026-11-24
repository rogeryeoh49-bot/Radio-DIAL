# Self Radio

Self Radio is a virtual System Audio station. It observes sound produced by other applications on the current default output, never microphone input. It does not replay or save captured audio, and never changes system volume or the default output device.

## Playback handoff

Enable **Settings → General → Self Radio → Automatically switch to Self Radio**. External audio stops Radio Dial's stream and selects Self Radio. Starting a Radio Dial station first pauses other players and waits for external sound to stop. Selecting Self Radio again resumes the previously paused Music/Spotify queue; a guarded system media Play command is a best-effort fallback for supported browser players. Self Radio’s play/pause button controls the external source. If a player cannot be paused, Radio Dial reports that and leaves the external audio alone instead of layering a station over it.

Detection measures actual output samples, including when the Mac's master volume is muted. Opening a music application alone does not activate Self Radio. Status text is Now Playing, Not Playing, or Muted. An active non-music application can appear as Safari Playing (or its actual application name). The detector uses an approximately -52 dBFS activation threshold held for 250 ms, -62 dBFS release threshold, and 1.5 seconds of silence before deactivation.

## Permissions and compatibility

System audio activity requires **macOS 14.2+** and **System Audio Recording** permission. Other Radio Dial functionality retains its macOS 14.0 minimum. A failed or denied monitor never reports playing. Since macOS can deliver silent buffers when permission is unavailable, Settings includes a status, Retry detection and Privacy Settings link. Local development builds may require quitting/reopening after a permission or signing change.

Music and Spotify use their AppleScript dictionaries for explicit pause commands. Optional song information uses those same dictionaries; Automation access may be requested separately. Metadata refreshes query running players. The welcome screen checks Automation for the selected music app while it is running. Its Check button can launch that app to verify access without starting playback. No microphone permission, Homebrew package or external command-line application is needed.

The optional global-pause compatibility fallback uses runtime-resolved private MediaRemote symbols, `MRMediaRemoteGetNowPlayingApplicationPID` and `MRMediaRemoteSendCommand` (explicit Pause and guarded Play, never Play/Pause toggle). It never targets Radio Dial itself, and Play is sent only to the remembered external player. This is **not a supported public Apple API**; macOS may change or restrict it. Missing symbols, missing player identity or a timeout fail closed. Browsers and other players only respond when macOS exposes them as the current media player. Arbitrary sound-producing applications are not universally pausable. Actual activity detection remains independent, using public Core Audio APIs.

## Metadata and artwork

Supported metadata adapters are Apple Music and Spotify. A playing state and non-silent process audio on the current route are required. Music players take priority over other simultaneously audible applications. Up to eight bounded per-application monitors validate app attribution; unrecognized or unmonitored sources remain generic rather than being guessed. If metadata is unavailable or an application denies Automation access, Self Radio keeps its fixed logo. Browser audio has no general song-metadata adapter.

Music artwork comes from the current track's `raw data` artwork property. Spotify artwork uses the artwork URL returned by Spotify. Availability varies with the player, track and permissions. Artwork is cached separately from audio; only image files are temporarily cached. Silence clears displayed song information and restores the fixed station logo.

The supplied GTA V SVG is preserved as `Resources/SelfRadio-original.svg`. Its actual cubic-path bounds are approximately (-0.000004, -0.0000004)–(915.286275, 915.725703), matching the original viewBox to rounding precision. `SelfRadio-square.svg` centers that complete artwork on a 915.72569-square pure black canvas without cropping or stretching. The bundled 2048×2048 PNG is included both as a resource URL and in a native asset catalog compiled by `actool`. Original logo: [user-specified GTA Wiki SVG](https://static.wikia.nocookie.net/gtawiki/images/1/10/SelfRadio-GTAV-Logo.svg/revision/latest?cb=20160917180231). GTA/Self Radio artwork belongs to its original owners; it is not Radio Dial's application icon.

## Components

- `SystemAudioActivity.swift`: level hysteresis and debounce, with no retained sample buffers.
- `SystemAudioDetector.swift`: private process tap, self-process exclusion, aggregate-device lifecycle, default-output listener and output-process identification. Audio samples are reduced to a scalar and discarded.
- `ExternalMediaMetadata.swift`: serialized Music/Spotify metadata and pause adapters.
- `SystemMediaControl.swift`: isolated optional MediaRemote pause compatibility adapter.
- `SelfRadio.swift`: virtual station activity, metadata lifecycle and image-only caching.
- `DialState.swift`: shared source/playback handoff and prevention of recording or Shazam of Self Radio.
- `Catalog.swift`, `CoverFlow.swift`, `GTARadioOverlay.swift`, `RadioDial.swift`, `NowPlaying.swift`, `Panels.swift`, `RadioReceiver.swift`: existing station UI integration and settings. Self Radio does not publish another application's track as Radio Dial's macOS Now Playing session.
- `Info.plist`, `build.sh`, `Resources/Assets.xcassets`: privacy descriptions and packaged artwork.
- `Tests/SystemAudioActivityTests.swift`, `Tests/SelfRadioArtworkTests.swift`: silence, transient, hysteresis, stop debounce, virtual-source serialization, image dimensions and black-corner checks.

## Verification

Live verification on this Mac confirmed Apple Music start → automatic Self Radio, real song metadata and album artwork, and station selection → Music paused. A generated browser-audio fixture also triggered Self Radio without stale song information. The embedded browser did not expose itself as the system media player, so global pause correctly reported unsupported continuing audio rather than starting an overlapping station. Spotify was not tested live; default-output replacement was not exercised live. The final build also verified Music stays paused during a playing radio stream, and selecting Self Radio resumes the same Music song and restores its metadata through the per-application monitor.

Run `./Tests/run.sh` and `./build.sh --universal` using an Xcode toolchain compatible with the selected SDK. Live player, permission and output-device checks require macOS; a passing level-gate test is not evidence that every third-party player supports global pause or provides artwork.

### Cover Flow playback and artwork transitions

Cover Flow animates playback focus independently of asynchronous source restoration, including Self Radio's stopped-to-playing transition and fade back to idle. Automatic switches into Self Radio use the same animated centering path. The five-second dwell enlargement is preserved.

Artwork file writes, thumbnail decoding and HDR rendering run outside the UI thread. Local Music artwork is decoded into a shared Cover Flow/VI radio cache before its URL is published, and album changes use a short image transition. Metadata refreshes keep valid artwork when another app starts/stops sound and skip unchanged UI publications. `Tests/CoverFlowArtworkTests.swift` checks local 1200px decoding, shared prepared images and center-out preloading order.
