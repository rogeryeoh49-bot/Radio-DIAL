#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/radiodial-tests.XXXXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc Sources/TrackMetadata.swift Sources/PlaylistMetadata.swift Sources/Catalog.swift Sources/USStationArtwork.swift Tests/TrackMetadataTests.swift -o "$task_tmp/metadata"
"$task_tmp/metadata"
swiftc Sources/ReleaseVersion.swift Tests/ReleaseVersionTests.swift -o "$task_tmp/version"
"$task_tmp/version"
swiftc Sources/Catalog.swift Sources/USStationArtwork.swift Sources/RadioMarkets.swift Tests/MarketMatchingTests.swift -o "$task_tmp/market"
"$task_tmp/market"

swiftc Sources/VISelectionTone.swift Tests/VISelectionToneTests.swift -o "$task_tmp/selection-tone"
"$task_tmp/selection-tone"
swiftc Sources/KeyboardShortcuts.swift Tests/KeyboardShortcutsTests.swift -o "$task_tmp/shortcuts"
"$task_tmp/shortcuts"
swiftc Sources/VIRadioBackdrop.swift Tests/VIRadioBackdropTests.swift -o "$task_tmp/backdrop"
"$task_tmp/backdrop"
swiftc Sources/SystemAudioActivity.swift Tests/SystemAudioActivityTests.swift -o "$task_tmp/system-audio"
"$task_tmp/system-audio"
swiftc Sources/Catalog.swift Sources/USStationArtwork.swift Tests/SelfRadioArtworkTests.swift -o "$task_tmp/self-radio-artwork"
"$task_tmp/self-radio-artwork"
swiftc Sources/Catalog.swift Sources/USStationArtwork.swift Sources/CoverFlowArtwork.swift Tests/CoverFlowArtworkTests.swift -o "$task_tmp/cover-flow-artwork"
"$task_tmp/cover-flow-artwork"
