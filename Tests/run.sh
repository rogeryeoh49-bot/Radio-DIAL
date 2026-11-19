#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_tmp=$(mktemp -d "${TMPDIR:-/tmp}/radiodial-tests.XXXXXXXX")
trap 'rm -rf "$task_tmp"' EXIT
swiftc Sources/TrackMetadata.swift Tests/TrackMetadataTests.swift -o "$task_tmp/metadata"
"$task_tmp/metadata"
swiftc Sources/ReleaseVersion.swift Tests/ReleaseVersionTests.swift -o "$task_tmp/version"
"$task_tmp/version"
swiftc Sources/Catalog.swift Sources/RadioMarkets.swift Tests/MarketMatchingTests.swift -o "$task_tmp/market"
"$task_tmp/market"

swiftc Sources/VISelectionTone.swift Tests/VISelectionToneTests.swift -o "$task_tmp/selection-tone"
"$task_tmp/selection-tone"
swiftc Sources/KeyboardShortcuts.swift Tests/KeyboardShortcutsTests.swift -o "$task_tmp/shortcuts"
"$task_tmp/shortcuts"
