import AppKit
import Combine
import CoreText
import SwiftUI

@main
enum RadioDialApp {
    @MainActor static func main() {
        for name in ["Punctum-Regular", "BarlowCondensed-Regular", "BarlowCondensed-SemiBold", "Barlow-Regular"] {
            if let font = Bundle.main.url(forResource: name, withExtension: "ttf") {
                CTFontManagerRegisterFontsForURL(font as CFURL, .process, nil)
            }
        }
        let app = NSApplication.shared
        let lightIcon = Bundle.main.url(forResource: "RadioDial", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        let darkIcon = Bundle.main.url(forResource: "RadioDial-Dark", withExtension: "icns").flatMap { NSImage(contentsOf: $0) }
        let iconAppearance = app.observe(\.effectiveAppearance, options: [.initial, .new]) { _, change in
            Task { @MainActor in
                let appearance = change.newValue ?? app.effectiveAppearance
                let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                if let icon = dark ? darkIcon : lightIcon { app.applicationIconImage = icon }
            }
        }
        let delegate = DialDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime((delegate, iconAppearance)) { app.run() }
    }
}

private struct DialWindow: View {
    @ObservedObject var dial: DialState
    let openSettings: () -> Void
    let advanceTutorial: () -> Void
    let endTutorial: () -> Void
    let panelDismissed: () -> Void
    @StateObject private var coverFlowArtwork = CoverFlowArtwork()
    @State private var stationQuery = ""
    @State private var podcastQuery = ""
    @State private var countrySelection = CountrySelection.all
    @State private var coverFlowCountryHovered = false
    @State private var genre = ""
    @State private var bitrate = 0
    @State private var sort = "clickcount"
    @State private var activeFavoriteType = 0
    @State private var filesTab = 0
    @State private var clearHistory = false
    @State private var showReceiverLibrary = false
    @State private var showEQPresets = false
    @State private var seeking = false
    @State private var seekValue = 0.0
    @State private var fullFrame: NSRect?
    @State private var window: NSWindow?
    @State private var coverFlowSupportsHDR = false
    private enum CountrySelection: Hashable {
        case all
        case pinned(String)
        case directory(String)

        var code: String {
            switch self {
            case .all: return ""
            case .pinned(let code), .directory(let code): return code
            }
        }
    }

    private static let pinnedCountries = [
        Catalog.Country(name: "US", iso_3166_1: "US"),
        Catalog.Country(name: "UK", iso_3166_1: "GB"),
        Catalog.Country(name: "France", iso_3166_1: "FR")
    ]

    var palette: DialPalette { DialPalette(dial.prefs.theme) }

    var body: some View {
        Group {
            if dial.prefs.theme == RadioReceiverStyle.name && !dial.mini {
                RadioReceiver(dial: dial, country: receiverCountry, tools: receiverTools)
            } else if dial.prefs.theme == "Cover Flow" && !dial.mini {
                CoverFlow(dial: dial, artwork: coverFlowArtwork, country: coverFlowCountry, library: stationLibraryButton, options: optionsMenu,
                          keyboardEnabled: !showReceiverLibrary && dial.pane == nil,
                          supportsHDR: coverFlowSupportsHDR)
            } else {
                standardLayout
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            if dial.gettingStartedStep == .coverFlow {
                GettingStartedHint(step: .coverFlow, text: "Swipe or use ← and → to browse covers. Press Space to play the centered station.",
                                   advance: advanceTutorial, skip: endTutorial)
                    .padding(12)
            }
        }
        .frame(minWidth: dial.mini ? 480 : 840, minHeight: dial.mini ? 250 : 620)
        .background(WindowReader { window = $0; updateCoverFlowDisplay($0) })
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didChangeScreenNotification)) { note in
            if let changedWindow = note.object as? NSWindow, changedWindow === window {
                updateCoverFlowDisplay(changedWindow)
            }
        }
        .background(LinearGradient(colors: [palette.base, palette.base.opacity(0.93)], startPoint: .bottom, endPoint: .top))
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .preferredColorScheme(palette.light ? .light : .dark)
        .sheet(item: $dial.pane, onDismiss: panelDismissed) { pane in
            PanelBody(dial: dial, pane: pane, advanceTutorial: advanceTutorial, endTutorial: endTutorial)
                .padding(24)
                .frame(width: pane == .lyrics ? 620 : 540)
                .background {
                    if pane == .theme {
                        PanelBody(dial: dial, pane: pane).themeWindowBackground
                    }
                }
                .foregroundStyle(pane == .theme ? palette.text : .primary)
                .tint(palette.accent)
                .preferredColorScheme(palette.light ? .light : .dark)
        }
        .onChange(of: dial.gettingStartedStep) { old, step in
            if step == .stations {
                showReceiverLibrary = dial.prefs.theme == "Cover Flow" || dial.prefs.theme == RadioReceiverStyle.name
            } else if old == .stations {
                showReceiverLibrary = false
            }
        }
        .onChange(of: dial.mini) { _, mini in
            guard let window else { return }
            if mini {
                fullFrame = window.frame
                window.contentMinSize = NSSize(width: 480, height: 250)
                let compact = NSRect(x: window.frame.minX, y: window.frame.maxY - 300, width: 540, height: 300)
                DispatchQueue.main.async { window.setFrame(compact, display: true, animate: true) }
            } else if let fullFrame {
                window.contentMinSize = NSSize(width: 840, height: 620)
                DispatchQueue.main.async { window.setFrame(fullFrame, display: true, animate: true) }
            }
        }
        .onChange(of: dial.prefs.theme) { _, theme in
            if theme == RadioReceiverStyle.name { dial.section = .radio }
        }
        .onAppear { applyDefaultCountry() }
        .onChange(of: dial.prefs.defaultRadioCountry) { _, _ in applyDefaultCountry() }
        .onChange(of: countrySelection.code) { _, _ in search() }
        .onChange(of: genre) { _, _ in search() }
        .onChange(of: bitrate) { _, _ in search() }
        .onChange(of: sort) { _, _ in search() }
    }

    private func applyDefaultCountry() {
        let code = dial.prefs.defaultRadioCountry ?? ""
        if code.isEmpty { countrySelection = .all }
        else if Self.pinnedCountries.contains(where: { $0.id == code }) { countrySelection = .pinned(code) }
        else { countrySelection = .directory(code) }
    }

    private func updateCoverFlowDisplay(_ window: NSWindow) {
        coverFlowSupportsHDR = (window.screen?.maximumPotentialExtendedDynamicRangeColorComponentValue ?? 1) > 1
    }

    private var standardLayout: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: dial.mini ? 9 : 16) {
                display
                controls
                if !dial.mini { library }
            }
            .padding(dial.mini ? 11 : 18)
            .background(palette.panel, in: RoundedRectangle(cornerRadius: 15))
            .overlay { RoundedRectangle(cornerRadius: 15).strokeBorder(.white.opacity(0.08)) }
            .padding(.horizontal, dial.mini ? 11 : 18)
            .padding(.bottom, 12)
            footer
        }
    }

    private var receiverCountry: some View {
        countryMenu(resetFilters: true) { name in
            Text(countrySelection == .all ? "Country" : name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(width: 98, height: 42)
        .modifier(ReceiverKeyFace(active: true))
    }

    private var coverFlowCountry: some View {
        countryMenu(resetFilters: true) { name in
            Text(name)
                .font(.custom("Punctum-Regular", size: 18))
                .lineLimit(1)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .background {
            Capsule()
                .fill(.white.opacity(coverFlowCountryHovered ? 0.16 : 0))
                .padding(.horizontal, -7)
                .padding(.vertical, -4)
        }
        .contentShape(Capsule())
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) { coverFlowCountryHovered = hovering }
        }
    }

    private var stationLibraryButton: some View {
        Button { showReceiverLibrary.toggle() } label: { Image(systemName: "list.bullet") }
            .help("Station library").accessibilityLabel("Station library")
            .gettingStartedHighlight(dial.gettingStartedStep == .stations && !showReceiverLibrary)
            .popover(isPresented: $showReceiverLibrary, arrowEdge: .bottom) {
                library.padding(14).frame(width: 820, height: 390)
                    .foregroundStyle(palette.text)
                    .background(palette.panel)
            }
    }

    private var receiverTools: some View {
        HStack(spacing: 12) {
            stationLibraryButton
            Button {
                if let source = dial.source { dial.favorite(source) }
            } label: { Image(systemName: dial.isFavorite ? "star.fill" : "star") }
                .help(dial.isFavorite ? "Remove favorite" : "Add favorite")
                .accessibilityLabel(dial.isFavorite ? "Remove favorite" : "Add favorite")
                .disabled(dial.source?.isRadio != true)
            Button { dial.pane = .lyrics } label: { Image(systemName: "music.note") }
                .help("Song and Lyrics").accessibilityLabel("Song and Lyrics")
            optionsMenu
            Button { dial.mini.toggle() } label: { Image(systemName: "pip.enter") }
                .help("Mini player").accessibilityLabel("Mini player")
        }
        .buttonStyle(.borderless)
        .tint(Color(rgb: 0x343B38))
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 18) {
            Text("RADIO DIAL")
                .font(.system(size: dial.mini ? 20 : 27, weight: .black, design: .serif))
                .tracking(2)
                .accessibilityAddTraits(.isHeader)
            if !dial.mini {
                Label(dial.stationCount.map { "\($0.formatted())+ stations" } ?? "Internet radio", systemImage: "radio")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced)).foregroundStyle(palette.accent)
            }
            Spacer()
            optionsMenu
            Button { dial.mini.toggle() } label: {
                Image(systemName: dial.mini ? "arrow.up.left.and.arrow.down.right" : "pip.enter")
            }
            .help(dial.mini ? "Full player" : "Mini player")
            .accessibilityLabel(dial.mini ? "Full player" : "Mini player")
        }
        .padding(.horizontal, 21)
        .padding(.vertical, dial.mini ? 8 : 14)
    }

    private var optionsMenu: some View {
        Menu {
            Button("Open Stream…") { dial.pane = .custom }
            Divider()
            Button("Sleep Timer…") { dial.pane = .sleep }
            Button("Alarms…") { dial.pane = .alarms }
            Button("Scheduled Recordings…") { dial.pane = .scheduled }
            Divider()
            Button("Playlists…") { dial.pane = .playlist }
            Button("Equalizer Presets…") { dial.pane = .presets }
            Button("Stream Monitor…") { dial.pane = .stream }
            Button("Themes…") { dial.pane = .theme }
            Button("Settings…", action: openSettings)
            Divider()
            Button("About Radio Dial") { dial.pane = .about }
        } label: {
            Label("Menu", systemImage: "line.3.horizontal").labelStyle(.iconOnly)
        }
        .fixedSize()
        .help("Menu").accessibilityLabel("Options")
    }

    private var display: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                Circle()
                    .fill(dial.playback == .playing ? palette.signal : dial.playback == .connecting ? .orange : palette.secondary)
                    .frame(width: 8, height: 8)
                    .shadow(color: dial.playback == .playing ? palette.signal : .clear, radius: 5)
                Text(dial.source?.title ?? "Tune in")
                    .font(.system(size: dial.mini ? 17 : 21, weight: .bold, design: .rounded))
                    .foregroundStyle(palette.signal)
                    .lineLimit(1)
                Spacer()
                if let start = dial.recordStart {
                    TimelineView(.periodic(from: start, by: 1)) { context in
                        Label(timeLabel(context.date.timeIntervalSince(start)), systemImage: "record.circle").foregroundStyle(.red)
                            .font(.system(.caption, design: .monospaced).bold())
                    }
                }
                if !dial.sleepRemaining.isEmpty {
                    Label(dial.sleepRemaining, systemImage: "moon").font(.system(.caption, design: .monospaced)).foregroundStyle(palette.accent)
                }
            }
            HStack(spacing: 10) {
                Text(dial.track.isEmpty ? dial.source?.subtitle.nonempty ?? "LIVE RADIO  /  PODCASTS" : dial.track)
                    .font(.system(.caption, design: .monospaced)).foregroundStyle(palette.secondary).lineLimit(1)
                Spacer(minLength: 0)
                if !dial.track.isEmpty, dial.playback != .stopped, let url = dial.appleMusicURL {
                    AppleMusicButton(url: url, color: palette.accent)
                }
            }
            HStack(alignment: .bottom, spacing: 13) {
                Artwork(url: dial.art, icon: dial.source?.episode == true ? "waveform" : "radio", palette: palette)
                    .id(dial.art)
                    .frame(width: dial.mini ? 55 : 105, height: dial.mini ? 55 : 105)
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Visualization").font(.caption).foregroundStyle(palette.secondary)
                        Picker("Visualization", selection: $dial.prefs.visualizer) {
                            ForEach(Scope.modes, id: \.self) { Text($0) }
                        }
                        .labelsHidden().fixedSize()
                        Spacer()
                        Text("STEREO  ·  44.1 kHz").font(.system(size: 9, weight: .medium, design: .monospaced)).foregroundStyle(palette.secondary)
                    }
                    Scope(meter: dial.meter, mode: dial.prefs.visualizer, palette: palette)
                }
            }
            .frame(height: dial.mini ? 63 : 110)
            if dial.length > 0 && dial.source?.isRadio == false {
                HStack {
                    Text(timeLabel(dial.elapsed))
                    Slider(value: Binding(get: { seeking ? seekValue : min(dial.elapsed, dial.length) }, set: { seekValue = $0 }),
                           in: 0...max(1, dial.length), onEditingChanged: { editing in
                        if editing { seekValue = min(dial.elapsed, dial.length) }
                        else { dial.seek(seekValue) }
                        seeking = editing
                    })
                    .accessibilityLabel("Playback position")
                    Text(timeLabel(dial.length))
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(palette.secondary)
            }
        }
        .padding(dial.mini ? 10 : 15)
        .background(palette.displayBackground, in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.07)) }
    }

    private var controls: some View {
        HStack(spacing: dial.mini ? 8 : 11) {
            round("Stop", "stop.fill", tint: palette.secondary) { dial.stop() }
            round(dial.playback == .playing ? "Pause" : dial.playback == .connecting ? "Cancel connection" : "Play",
                  dial.playback == .playing ? "pause.fill" : dial.playback == .connecting ? "ellipsis" : "play.fill", tint: palette.signal, active: true) { dial.togglePlayback() }
            round(dial.recording ? "Stop Recording" : "Record", "record.circle", tint: dial.recording ? .red : palette.secondary, active: dial.recording) { dial.toggleRecording() }
            round(dial.isFavorite ? "Remove Favorite" : "Add Favorite", dial.isFavorite ? "star.fill" : "star", tint: dial.isFavorite ? .orange : palette.secondary, active: dial.isFavorite) {
                if let source = dial.source { dial.favorite(source) }
            }
            round("Station Info", "info", tint: palette.secondary) { dial.pane = .info }
            round("Song and Lyrics", "music.note", tint: palette.secondary) { dial.pane = .lyrics }
            Spacer(minLength: 2)
            if !dial.mini {
                Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 49)
                eqButton
                ForEach(DialState.EQBand.allCases, id: \.self) { band in
                    DialKnob(label: band.rawValue, value: dial.gain(for: band), range: -12...12, neutral: 0,
                             tint: dial.isEQEnabled ? eqTint(band) : palette.secondary) { dial.setGain(band, $0) }
                        .disabled(!dial.isEQEnabled)
                        .opacity(dial.isEQEnabled ? 1 : 0.55)
                }
                Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 49)
            }
            DialKnob(label: "VOL", value: dial.prefs.volume, range: 0...100, neutral: 80, tint: palette.signal) { dial.setVolume($0) }
                .contextMenu { Button("Mute / Unmute") { dial.toggleMute() } }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, dial.mini ? 0 : 2)
    }

    private var eqButton: some View {
        let enabled = dial.isEQEnabled
        return roundButton("EQ", tint: palette.signal, active: enabled) {
            if !enabled { dial.setEQEnabled(true) }
            showEQPresets.toggle()
        } label: {
            Text("EQ").font(.system(size: 12, weight: .bold, design: .monospaced))
        }
        .accessibilityValue(enabled ? "On, \(dial.prefs.preset)" : "Off")
        .popover(isPresented: $showEQPresets, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("EQ Presets").font(.headline)
                    Spacer()
                    Button("Turn EQ Off") {
                        dial.setEQEnabled(false)
                        showEQPresets = false
                    }
                }
                ScrollView {
                    LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 4) {
                        ForEach(dial.eqPresetNames, id: \.self) { name in
                            let selected = dial.prefs.preset == name
                            Button {
                                dial.applyPreset(name)
                                showEQPresets = false
                            } label: {
                                HStack(spacing: 6) {
                                    Text(name).lineLimit(1)
                                    Spacer(minLength: 0)
                                    if selected { Image(systemName: "checkmark") }
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 5)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .background(selected ? palette.signal.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 5))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityAddTraits(selected ? [.isSelected] : [])
                        }
                    }
                }
                .frame(height: 244)
            }
            .padding(12)
            .frame(width: 300)
        }
    }

    private func eqTint(_ band: DialState.EQBand) -> Color {
        switch band {
        case .low: return .orange
        case .mid: return palette.signal
        case .high: return Color(rgb: 0x47A4FF)
        }
    }

    private func round(_ title: String, _ icon: String, tint: Color, active: Bool = false, action: @escaping () -> Void) -> some View {
        roundButton(title, tint: tint, active: active, action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
        }
    }

    private func roundButton<Label: View>(_ title: String, tint: Color, active: Bool, action: @escaping () -> Void,
                                          @ViewBuilder label: () -> Label) -> some View {
        Button(action: action) {
            label()
                .frame(width: dial.mini ? 32 : 40, height: dial.mini ? 32 : 40)
                .foregroundStyle(active ? (palette.light ? Color.white : palette.displayBackground) : tint)
                .background(LinearGradient(colors: active ? [tint.opacity(palette.light ? 0.95 : 0.9), tint.opacity(palette.light ? 0.75 : 0.65)] : [.white.opacity(0.08), .black.opacity(0.08)],
                                           startPoint: .top, endPoint: .bottom), in: Circle())
                .overlay { Circle().strokeBorder(active ? tint : .white.opacity(0.10)) }
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private var library: some View {
        VStack(spacing: 0) {
            if dial.gettingStartedStep == .stations {
                GettingStartedHint(step: .stations, text: "Search for a station by name or choose a country.",
                                   advance: advanceTutorial, skip: endTutorial)
                    .padding(.bottom, 8)
            }
            HStack(spacing: 7) {
                ForEach(DialState.Section.allCases, id: \.self) { item in
                    Button { dial.section = item } label: {
                        Label(item.rawValue.uppercased(), systemImage: sectionIcon(item))
                            .font(.system(size: 11, weight: .bold, design: .serif))
                            .padding(.horizontal, 15).padding(.vertical, 9)
                            .background(dial.section == item ? palette.inset : .clear, in: UnevenRoundedRectangle(topLeadingRadius: 6, topTrailingRadius: 6))
                            .foregroundStyle(dial.section == item ? palette.text : palette.accent)
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(dial.section == item ? .isSelected : [])
                }
            }
            VStack(alignment: .leading, spacing: 10) {
                switch dial.section {
                case .radio: radio
                case .podcasts: podcast
                case .favorites: favorites
                case .history: history
                case .recordings: files
                }
            }
            .padding(11)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(palette.inset, in: RoundedRectangle(cornerRadius: 7))
            .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(palette.line) }
        }
    }

    private func sectionIcon(_ item: DialState.Section) -> String {
        switch item {
        case .radio: return "radio"
        case .podcasts: return "mic"
        case .favorites: return "star"
        case .history: return "clock"
        case .recordings: return "opticaldisc"
        }
    }

    private var radio: some View {
        Group {
            HStack(spacing: 7) {
                countryPicker
                Picker("Genre", selection: $genre) {
                    Text("All Genres").tag("")
                    ForEach(dial.tags, id: \.self) { Text($0.capitalized).tag($0) }
                }.labelsHidden().frame(maxWidth: 130)
                Picker("Bitrate", selection: $bitrate) {
                    Text("All Qualities").tag(0)
                    ForEach([64, 128, 192, 256, 320], id: \.self) { Text("\($0)+ kbps").tag($0) }
                }.labelsHidden().frame(maxWidth: 115)
                Menu {
                    Button("Most Played") { sort = "clickcount" }
                    Button("Most Voted") { sort = "votes" }
                    Button("Alphabetical") { sort = "name" }
                    Button("Highest Bitrate") { sort = "bitrate" }
                } label: { Image(systemName: "arrow.up.arrow.down") }.fixedSize().help("Sort Stations")
                TextField("Search stations…", text: $stationQuery).onSubmit { search() }
                    .gettingStartedHighlight(dial.gettingStartedStep == .stations)
                Button("Search") { search() }.buttonStyle(.borderedProminent)
            }
            if !dial.radioError.isEmpty { Text(dial.radioError).font(.caption).foregroundStyle(.orange) }
            table(dial.stations, empty: dial.busy ? "Loading stations…" : "No stations found.", more: dial.more,
                  pinned: .selfRadio) {
                dial.open($0)
            }
        }
    }

    private var countryPicker: some View {
        countryMenu { name in
            Text(name).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: 165)
    }

    private func countryMenu<Title: View>(resetFilters: Bool = false, @ViewBuilder title: (String) -> Title) -> some View {
        let countries = dial.countries.map { country in
            Self.pinnedCountries.first { $0.id == country.id } ?? country
        }.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }

        let name = (Self.pinnedCountries + countries).first { $0.id == countrySelection.code }?.name ?? (countrySelection.code.isEmpty ? "All Countries" : countrySelection.code)
        return Menu {
            ForEach(Self.pinnedCountries) { country in
                countryOption(country.name, selection: .pinned(country.id), resetFilters: resetFilters)
            }
            Divider()
            countryOption("All Countries", selection: .all, resetFilters: resetFilters)
            ForEach(countries.filter { country in !Self.pinnedCountries.contains(where: { $0.id == country.id }) }) { country in
                countryOption(country.name, selection: .directory(country.id), resetFilters: resetFilters)
            }
        } label: {
            title(name)
        }
        .menuOrder(.fixed)
        .accessibilityLabel("Country")
        .accessibilityValue(name)
        .help(name)
    }

    private func countryOption(_ name: String, selection: CountrySelection, resetFilters: Bool) -> some View {
        Button {
            countrySelection = selection
            if resetFilters { resetReceiverFilters() }
        } label: {
            if countrySelection.code == selection.code {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private func resetReceiverFilters() {
        stationQuery = ""
        genre = ""
        bitrate = 0
        search()
    }

    private func search(append: Bool = false) {
        dial.searchStations(name: stationQuery.trimmingCharacters(in: .whitespacesAndNewlines),
                            country: countrySelection.code, tag: genre, min: bitrate, sort: sort, append: append)
    }

    private var podcast: some View {
        Group {
            HStack {
                if let selected = dial.selectedPodcast {
                    Button { dial.backToPodcasts() } label: { Label("Back", systemImage: "chevron.left") }
                    Text(selected.title).font(.headline).lineLimit(1)
                    Spacer()
                    Button { dial.favorite(selected) } label: { Image(systemName: dial.prefs.favorites.contains(selected) ? "star.fill" : "star") }
                        .help("Favorite Podcast")
                } else {
                    TextField("Search podcasts…", text: $podcastQuery).onSubmit { dial.searchPodcasts(podcastQuery) }
                    Button("Search") { dial.searchPodcasts(podcastQuery) }.buttonStyle(.borderedProminent)
                }
            }
            table(dial.selectedPodcast == nil ? dial.podcasts : dial.episodes,
                  empty: dial.podcastBusy ? "Loading podcasts…" : dial.podcastError.nonempty ?? "Search the podcast catalog.") { dial.open($0) }
        }
    }

    private var favorites: some View {
        Group {
            HStack {
                Picker("Favorite Type", selection: $activeFavoriteType) {
                    Text("Radio").tag(0)
                    Text("Podcasts").tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 200)
                Spacer()
                Button("Import / Export") { dial.pane = .playlist }
            }
            table(dial.prefs.favorites.filter { activeFavoriteType == 0 ? $0.isStation : !$0.isStation }, empty: "No favorites here yet.") { dial.open($0) }
        }
    }

    private var history: some View {
        Group {
            HStack {
                Text("Recently played").font(.headline)
                Spacer()
                Button("Clear History…") { clearHistory = true }.disabled(dial.prefs.history.isEmpty)
            }
            .confirmationDialog("Clear listening history?", isPresented: $clearHistory) {
                Button("Clear History", role: .destructive) { dial.prefs.history.removeAll() }
            }
            ScrollView {
                if dial.prefs.history.isEmpty { emptyState("No listening history yet.") }
                LazyVStack(spacing: 1) {
                    ForEach(dial.prefs.history) { visit in
                        row(visit.source, hint: visit.date.formatted(date: .abbreviated, time: .shortened)) { dial.open(visit.source) }
                            .contextMenu {
                                Button("Remove from History") { dial.prefs.history.removeAll { $0.id == visit.id } }
                            }
                    }
                }
            }.background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        }
    }

    private var files: some View {
        Group {
            HStack {
                Picker("Local Media", selection: $filesTab) {
                    Text("Recordings").tag(0)
                    Text("Downloaded Podcasts").tag(1)
                }.pickerStyle(.segmented).labelsHidden().frame(width: 285)
                Spacer()
                Button("Refresh") { dial.refreshFiles() }
                Button("Open Folder") { dial.openFolder(filesTab == 0 ? dial.prefs.capture.folder : dial.downloadFolder) }
            }
            table(filesTab == 0 ? dial.recordings : dial.downloads, empty: filesTab == 0 ? "Record a station using the red Record control." : "Download an episode from its context menu.") { dial.open($0) }
        }
    }

    private func table(_ items: [Source], empty: String, more: Bool = false, pinned: Source? = nil,
                       action: @escaping (Source) -> Void) -> some View {
        VStack(spacing: 0) {
            if let pinned {
                row(pinned, hint: pinned.isSelfRadio ? dial.selfRadio.displayDetail : "") { action(pinned) }
                    .contextMenu { rowMenu(pinned) }
                Divider()
            }
            ScrollView {
                if items.isEmpty { emptyState(empty) }
                LazyVStack(spacing: 1) {
                    ForEach(items) { item in
                        row(item, hint: item.subtitle.nonempty ?? item.tags) { action(item) }
                            .contextMenu { rowMenu(item) }
                    }
                    if more { Button(dial.busy ? "Loading…" : "Load More") { search(append: true) }.disabled(dial.busy).padding(8) }
                }
            }
        }
        .background(.black.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
        .overlay { RoundedRectangle(cornerRadius: 5).strokeBorder(palette.line.opacity(0.55)) }
    }

    private func emptyState(_ value: String) -> some View {
        Text(value).foregroundStyle(palette.secondary).font(.callout)
            .frame(maxWidth: .infinity, minHeight: 82)
    }

    private func row(_ item: Source, hint: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: dial.source?.id == item.id && dial.playback == .playing ? "waveform" : item.isSelfRadio ? "speaker.wave.2" : item.feed != nil ? "mic" : item.isRadio ? "radio" : "play.circle")
                    .frame(width: 19).foregroundStyle(dial.source?.id == item.id ? palette.signal : palette.accent)
                Text(item.title).font(.system(size: 13, weight: .medium, design: .serif)).lineLimit(1)
                if item.isSelfRadio { Text(dial.selfRadio.displayStatus).font(.caption).foregroundStyle(palette.secondary) }
                if item.bitrate > 0 {
                    Text("\(item.bitrate) kbps").font(.system(size: 10, weight: .medium, design: .monospaced))
                        .padding(.horizontal, 5).padding(.vertical, 2).background(palette.accent.opacity(0.12), in: Capsule())
                }
                if !hint.isEmpty { Text(hint).font(.caption).foregroundStyle(palette.secondary).lineLimit(1) }
                Spacer(minLength: 6)
                if !item.country.isEmpty { Text(item.country.replacingOccurrences(of: "_", with: " ")).font(.caption).foregroundStyle(palette.secondary).lineLimit(1) }
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .semibold)).foregroundStyle(palette.secondary)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(dial.source?.id == item.id ? palette.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private func rowMenu(_ item: Source) -> some View {
        Button(item.feed == nil ? "Play" : "Show Episodes") { dial.open(item) }
        if item.url.isFileURL {
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([item.url]) }
        } else {
            Button(dial.prefs.favorites.contains(where: { $0.id == item.id }) ? "Remove Favorite" : "Add Favorite") { dial.favorite(item) }
            if dial.section == .favorites {
                Button("Move Up") { dial.moveFavorite(item, by: -1) }
                Button("Move Down") { dial.moveFavorite(item, by: 1) }
            }
            if item.episode { Button("Download Episode") { dial.download(item) } }
            if item.isRadio {
                Button("Test Stream") { dial.test(item) }
                if UUID(uuidString: item.id) != nil { Button("Vote on Radio Browser") { dial.vote(item) } }
            }
            if let site = item.website { Button("Open Website") { NSWorkspace.shared.open(site) } }
            Button("Copy URL") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(item.url.absoluteString, forType: .string) }
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Circle().fill(dial.playback == .playing ? palette.signal : palette.accent).frame(width: 5, height: 5)
            Text(dial.status).lineLimit(1).help(dial.status)
            Spacer()
            if let source = dial.source, !source.codec.isEmpty {
                Text(source.codec + (source.bitrate > 0 ? "  •  \(source.bitrate) kbps" : ""))
            }
            Text("1.0").foregroundStyle(palette.secondary)
        }
        .font(.system(size: 10, weight: .medium, design: .monospaced))
        .foregroundStyle(palette.accent)
        .padding(.horizontal, 16).padding(.vertical, 7)
        .background(palette.inset)
    }
}

struct AppleMusicButton: View {
    let url: URL
    let color: Color
    @State private var hovered = false

    var body: some View {
        Button { NSWorkspace.shared.open(url) } label: {
            (Text("open in  ").fontWeight(.semibold) + Text("music").fontWeight(.black))
                .font(.system(size: 11))
                .foregroundStyle(color.opacity(hovered ? 1 : 0.85))
                .padding(.horizontal, 9)
                .padding(.vertical, 5)
                .background(color.opacity(hovered ? 0.18 : 0.09), in: Capsule())
                .overlay(Capsule().strokeBorder(color.opacity(hovered ? 0.38 : 0.2)))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .onHover { hovered = $0 }
        .accessibilityLabel("Open in Apple Music")
        .help("Open this song in Apple Music")
    }
}

struct Artwork: View {
    var url: URL?
    var icon: String
    var palette: DialPalette
    @State private var loaded: (url: URL, image: CGImage)?

    var body: some View {
        Group {
            if let url, let image = CoverFlowArtwork.preparedImage(for: url) ?? (loaded?.url == url ? loaded?.image : nil) {
                Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fit)
            } else {
                ZStack {
                    LinearGradient(colors: [palette.panel, palette.inset], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(palette.accent)
                }
            }
        }
        .task(id: url) {
            guard let url, let image = await CoverFlowArtwork.load(url), !Task.isCancelled else { return }
            loaded = (url, image)
        }
        .clipShape(.rect(cornerRadius: 8))
        .overlay { RoundedRectangle(cornerRadius: 8).strokeBorder(palette.line) }
    }
}

private struct WindowReader: NSViewRepresentable {
    let receive: (NSWindow) -> Void
    func makeNSView(context: Context) -> Reader {
        let reader = Reader()
        reader.receive = receive
        return reader
    }
    func updateNSView(_ view: Reader, context: Context) {}
    final class Reader: NSView {
        var receive: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { DispatchQueue.main.async { self.receive?(window) } }
        }
    }
}

extension String {
    var nonempty: String? { isEmpty ? nil : self }
}

func timeLabel(_ value: Double) -> String {
    let seconds = max(0, Int(value))
    if seconds >= 3600 { return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60) }
    return String(format: "%d:%02d", seconds / 60, seconds % 60)
}

@MainActor
private final class DialDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var dial: DialState?
    private var keyMonitor: Any?
    private var player: DialState?
    private var nowPlaying: NowPlaying?
    private var window: NSWindow?
    private var settingsWindow: NSWindow?
    private var gettingStartedWindow: NSWindow?
    private var statusItem: NSStatusItem?
    private var preferenceObserver: AnyCancellable?
    private let updates = UpdateController.shared
    private var viPreferences: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DialState()
        player = model
        nowPlaying = NowPlaying(dial: model)
        dial = model
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 760)
        let size = NSSize(width: min(980, screen.width - 28), height: min(720, screen.height - 36))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Radio Dial"
        window.identifier = NSUserInterfaceItemIdentifier("radio-dial-main")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 840, height: 620)
        window.contentView = NSHostingView(rootView: DialWindow(
            dial: model,
            openSettings: { [weak self] in self?.showSettings() },
            advanceTutorial: { [weak self] in self?.advanceTutorial() },
            endTutorial: { [weak self] in self?.endTutorial() },
            panelDismissed: { [weak self] in self?.tutorialPanelDismissed() }))
        window.center()
        self.window = window
        installMenus()
        preferenceObserver = model.$prefs.map(\.keepInMenuBar).removeDuplicates().sink { [weak self] visible in
            self?.configureStatusItem(visible)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.bootstrap()
        updates.start()
        VIRadioController.shared.configure(model)
        VIRadioController.shared.onTutorialShortcut = { [weak self] in self?.showVIRadio() }
        viPreferences = model.$prefs.sink { [weak self] _ in
            DispatchQueue.main.async {
                VIRadioController.shared.configure(model)
                model.configureSelfRadio()
                self?.updatePlaybackShortcuts()
            }
        }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, !VIRadioController.shared.visible, !VIShortcutRecorder.isRecording,
                  let dial = self.dial, event.window?.attachedSheet == nil else { return event }
            if let eventWindow = event.window,
               eventWindow === self.settingsWindow || eventWindow === self.gettingStartedWindow { return event }
            if dial.gettingStartedStep == .viRadio, dial.prefs.viEnabled != false {
                let shortcut = dial.prefs.viShortcut ?? VIShortcut()
                if shortcut.keyCode == UInt32(event.keyCode), shortcut.modifiers == VIShortcut.modifiers(from: event) {
                    if !event.isARepeat { self.showVIRadio() }
                    return nil
                }
            }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if event.keyCode == 3, event.modifierFlags.contains(.function), modifiers.isEmpty,
               event.window === self.window {
                self.window?.toggleFullScreen(nil)
                return nil
            }
            if let action = AppShortcutAction.allCases.first(where: {
                let key = $0.binding(in: dial.prefs.shortcuts)
                return key.keyCode == UInt32(event.keyCode) && key.modifiers == VIShortcut.modifiers(from: event)
            }) {
                if modifiers.isEmpty && event.window?.firstResponder is NSTextView { return event }
                if action == .playPause, dial.prefs.theme == "Cover Flow", !dial.mini { return event }
                if event.isARepeat && ![AppShortcutAction.volumeUp, .volumeDown].contains(action) { return nil }
                switch action {
                case .playPause: dial.togglePlayback()
                case .stop: dial.stop()
                case .record: dial.toggleRecording()
                case .volumeUp: dial.setVolume(dial.prefs.volume + 5)
                case .volumeDown: dial.setVolume(dial.prefs.volume - 5)
                case .mute: dial.toggleMute()
                case .mini: dial.mini.toggle()
                }
                return nil
            }
            return event
        }
        if model.shouldShowGettingStarted {
            if model.prefs.gettingStartedCompleted == nil { model.prefs.gettingStartedCompleted = false }
            showGettingStarted()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        showPlayer()
        return true
    }

    private func installMenus() {
        let root = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(item("About Radio Dial", #selector(showAbout)))
        appMenu.addItem(item("Check for Updates…", #selector(checkForUpdates), "u"))
        appMenu.addItem(item("Settings…", #selector(showSettings), ","))
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Radio Dial", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Radio Dial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        root.addItem(appItem)
        let fileItem = NSMenuItem()
        let fileMenu = NSMenu(title: "File")
        fileMenu.addItem(item("Open Stream…", #selector(showStream), "o"))
        fileMenu.addItem(item("Import Playlist…", #selector(importPlaylist)))
        fileMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        fileItem.submenu = fileMenu
        root.addItem(fileItem)
        let playbackItem = NSMenuItem()
        let playbackMenu = NSMenu(title: "Playback")
        playbackMenu.addItem(item("Play / Pause", #selector(playPause)))
        playbackMenu.addItem(item("Stop", #selector(stop), "."))
        playbackMenu.addItem(item("Start / Stop Recording", #selector(record), "R"))
        playbackMenu.addItem(item("Mini Player", #selector(mini), "I"))
        playbackMenu.addItem(item("Volume Up", #selector(volumeUp)))
        playbackMenu.addItem(item("Volume Down", #selector(volumeDown)))
        playbackMenu.addItem(item("Mute / Unmute", #selector(mute)))
        playbackItem.submenu = playbackMenu
        root.addItem(playbackItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        root.insertItem(editItem, at: 2)
        let viewItem = NSMenuItem()
        let viewMenu = NSMenu(title: "View")
        let fullscreen = NSMenuItem(title: "Enter Full Screen", action: #selector(NSWindow.toggleFullScreen(_:)), keyEquivalent: "f")
        fullscreen.keyEquivalentModifierMask = [.control, .command]
        viewMenu.addItem(fullscreen)
        viewMenu.addItem(item("Show GTA Radio Selector — " + (dial?.prefs.viShortcut ?? VIShortcut()).label, #selector(showVIRadio)))
        viewItem.submenu = viewMenu
        root.insertItem(viewItem, at: 3)
        let windowItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowMenu.addItem(.separator())
        windowMenu.addItem(withTitle: "Bring All to Front", action: #selector(NSApplication.arrangeInFront(_:)), keyEquivalent: "")
        windowItem.submenu = windowMenu
        root.addItem(windowItem)
        let helpItem = NSMenuItem()
        let helpMenu = NSMenu(title: "Help")
        helpMenu.addItem(item("Getting Started…", #selector(showGettingStarted)))
        helpItem.submenu = helpMenu
        root.addItem(helpItem)
        NSApp.mainMenu = root
        NSApp.windowsMenu = windowMenu
        NSApp.helpMenu = helpMenu
        updatePlaybackShortcuts()
    }

    private func updatePlaybackShortcuts() {
        guard let dial else { return }
        let actions: [Selector: AppShortcutAction] = [#selector(playPause): .playPause, #selector(stop): .stop,
            #selector(record): .record, #selector(volumeUp): .volumeUp, #selector(volumeDown): .volumeDown,
            #selector(mute): .mute, #selector(mini): .mini]
        for menu in NSApp.mainMenu?.items.compactMap(\.submenu) ?? [] {
            for item in menu.items {
                guard let selector = item.action, let action = actions[selector] else { continue }
                let key = action.binding(in: dial.prefs.shortcuts)
                item.keyEquivalent = key.menuKey
                item.keyEquivalentModifierMask = key.eventModifiers
            }
        }
    }

    private func configureStatusItem(_ enabled: Bool) {
        if !enabled {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        guard statusItem == nil else { return }
        let status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "radio", accessibilityDescription: "Radio Dial")
        let menu = NSMenu()
        menu.addItem(item("Show Radio Dial", #selector(showPlayer)))
        menu.addItem(item("Play / Pause", #selector(playPause)))
        menu.addItem(item("Stop", #selector(stop)))
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Radio Dial", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "")
        status.menu = menu
        statusItem = status
    }

    private func item(_ title: String, _ action: Selector, _ key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = self
        return item
    }

    @objc private func showVIRadio() {
        if dial?.gettingStartedStep == .viRadio {
            if VIRadioController.shared.visible { VIRadioController.shared.beginTutorialPractice() }
            else { showVIRadioPractice() }
        } else {
            VIRadioController.shared.show()
        }
    }

    private func showVIRadioPractice(waitForShortcut: Bool = false) {
        guard !VIRadioController.shared.visible else { return }
        VIRadioController.shared.show(waitForShortcut: waitForShortcut, guideCompletion: { [weak self] in
            guard self?.dial?.gettingStartedStep == .viRadio else { return }
            self?.advanceTutorial()
        })
    }
    @objc private func showPlayer() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showAbout() { showPlayer(); dial?.pane = .about }
    @objc private func checkForUpdates() { showPlayer(); updates.check() }

    @objc private func showGettingStarted() {
        guard let dial, dial.gettingStartedStep == nil else { return }
        if gettingStartedWindow == nil {
            let size = NSSize(width: 475, height: 365)
            let tutorial = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                                    styleMask: [.titled, .closable],
                                    backing: .buffered, defer: false)
            tutorial.title = "Getting Started"
            tutorial.identifier = NSUserInterfaceItemIdentifier("radio-dial-getting-started")
            tutorial.appearance = NSAppearance(named: .darkAqua)
            tutorial.isReleasedWhenClosed = false
            tutorial.delegate = self
            tutorial.contentView = NSHostingView(rootView: GettingStarted(
                selfRadio: dial.selfRadio,
                musicApp: dial.prefs.selfRadioMusicApp ?? .music,
                prepareAudio: { [weak dial] in try? dial?.audio.prepareSystemAudioMonitoring() },
                start: { [weak self] in self?.startTutorial() },
                skip: { [weak self] in self?.gettingStartedWindow?.close() }
            ).frame(width: size.width, height: size.height))
            tutorial.center()
            gettingStartedWindow = tutorial
        }
        gettingStartedWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func startTutorial() {
        guard let dial else { return }
        dial.pane = nil
        dial.mini = false
        dial.section = .radio
        dial.gettingStartedStep = .stations
        gettingStartedWindow?.close()
        showPlayer()
    }

    private func advanceTutorial() {
        guard let dial else { return }
        switch dial.gettingStartedStep {
        case .stations:
            dial.gettingStartedStep = .themes
            dial.pane = .theme
        case .themes:
            dial.gettingStartedStep = dial.prefs.theme == "Cover Flow" ? .coverFlow : .viRadio
            dial.pane = nil
        case .coverFlow:
            dial.gettingStartedStep = .viRadio
            showVIRadioPractice(waitForShortcut: true)
        case .viRadio:
            dial.gettingStartedStep = .selfRadio
            showSettings()
        case .selfRadio:
            endTutorial()
        case nil:
            break
        }
    }

    private func tutorialPanelDismissed() {
        if dial?.gettingStartedStep == .themes { endTutorial() }
        else if dial?.gettingStartedStep == .viRadio { showVIRadioPractice(waitForShortcut: true) }
    }

    private func endTutorial() {
        guard let dial else { return }
        let previousStep = dial.gettingStartedStep
        dial.gettingStartedStep = nil
        if previousStep == .themes, dial.pane == .theme { dial.pane = nil }
        if dial.prefs.gettingStartedCompleted != true { dial.prefs.gettingStartedCompleted = true }
    }

    @objc private func showSettings() {
        guard let dial else { return }
        if settingsWindow == nil {
            let screen = window?.screen ?? NSScreen.main
            let height = min(680, (screen?.visibleFrame.height ?? 760) - 50)
            let settings = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 640, height: height),
                                    styleMask: [.titled, .closable, .miniaturizable, .resizable],
                                    backing: .buffered, defer: false)
            settings.title = "Radio Dial Settings"
            settings.identifier = NSUserInterfaceItemIdentifier("radio-dial-settings")
            settings.isReleasedWhenClosed = false
            settings.delegate = self
            settings.contentView = NSHostingView(rootView: RadioDialSettings(
                dial: dial,
                startTutorial: { [weak self] in self?.showGettingStarted() },
                finishTutorial: { [weak self] in self?.endTutorial() }))
            settings.contentMinSize = NSSize(width: 520, height: 350)
            settings.center()
            settingsWindow = settings
        }
        settingsWindow?.deminiaturize(nil)
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow else { return }
        if closing === settingsWindow {
            self.settingsWindow = nil
            if dial?.gettingStartedStep == .selfRadio { endTutorial() }
        }
        if closing === gettingStartedWindow {
            gettingStartedWindow = nil
            if dial?.gettingStartedStep == nil { endTutorial() }
        }
    }

    @objc private func showStream() { showPlayer(); dial?.pane = .custom }
    @objc private func importPlaylist() { showPlayer(); dial?.importList() }
    @objc private func volumeUp() { dial?.setVolume((dial?.prefs.volume ?? 0) + 5) }
    @objc private func volumeDown() { dial?.setVolume((dial?.prefs.volume ?? 0) - 5) }
    @objc private func mute() { dial?.toggleMute() }
    @objc private func playPause() { dial?.togglePlayback() }
    @objc private func stop() { dial?.stop() }
    @objc private func record() { showPlayer(); dial?.toggleRecording() }
    @objc private func mini() { showPlayer(); dial?.mini.toggle() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let dial else { return .terminateNow }
        VIRadioController.shared.shutdown()
        dial.selfRadio.shutdown()
        viPreferences?.cancel()
        dial.stop()
        dial.flushPendingPreferences()
        nowPlaying?.tearDown()
        dial.audio.afterRecordingsSaved { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
