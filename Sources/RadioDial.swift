import AppKit
import Combine
import SwiftUI

@main
enum RadioDialApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = DialDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        withExtendedLifetime(delegate) { app.run() }
    }
}

private struct DialWindow: View {
    @ObservedObject var dial: DialState
    @State private var stationQuery = ""
    @State private var podcastQuery = ""
    @State private var countrySelection = CountrySelection.all
    @State private var genre = ""
    @State private var bitrate = 0
    @State private var sort = "clickcount"
    @State private var activeFavoriteType = 0
    @State private var filesTab = 0
    @State private var clearHistory = false
    @State private var showReceiverLibrary = false
    @State private var seeking = false
    @State private var seekValue = 0.0
    @State private var fullFrame: NSRect?
    @State private var window: NSWindow?
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
        Catalog.Country(name: "USA", iso_3166_1: "US"),
        Catalog.Country(name: "UK", iso_3166_1: "GB"),
        Catalog.Country(name: "France", iso_3166_1: "FR")
    ]

    var palette: DialPalette { DialPalette(dial.prefs.theme) }

    var body: some View {
        Group {
            if dial.prefs.theme == RadioReceiverStyle.name && !dial.mini {
                RadioReceiver(dial: dial, country: receiverCountry, tools: receiverTools)
            } else {
                standardLayout
            }
        }
        .frame(minWidth: dial.mini ? 480 : 840, minHeight: dial.mini ? 250 : 620)
        .background(WindowReader { window = $0 })
        .background(LinearGradient(colors: [palette.base, palette.base.opacity(0.93)], startPoint: .bottom, endPoint: .top))
        .foregroundStyle(palette.text)
        .tint(palette.accent)
        .preferredColorScheme(palette.light ? .light : .dark)
        .sheet(item: $dial.pane) { pane in
            PanelBody(dial: dial, pane: pane)
                .padding(24)
                .frame(width: pane == .lyrics ? 620 : 540)
                .preferredColorScheme(palette.light ? .light : .dark)
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
            if theme == RadioReceiverStyle.name { resetReceiverFilters() }
        }
        .onChange(of: countrySelection.code) { _, _ in search() }
        .onChange(of: genre) { _, _ in search() }
        .onChange(of: bitrate) { _, _ in search() }
        .onChange(of: sort) { _, _ in search() }
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

    private var receiverTools: some View {
        HStack(spacing: 12) {
            Button { showReceiverLibrary.toggle() } label: { Image(systemName: "list.bullet") }
                .help("Station library").accessibilityLabel("Station library")
                .popover(isPresented: $showReceiverLibrary, arrowEdge: .bottom) {
                    library.padding(14).frame(width: 820, height: 390)
                        .foregroundStyle(palette.text)
                        .background(palette.panel)
                }
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
            Button("Settings…") { dial.pane = .settings }
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
            Text(dial.track.isEmpty ? dial.source?.subtitle.nonempty ?? "LIVE RADIO  /  PODCASTS" : dial.track)
                .font(.system(.caption, design: .monospaced)).foregroundStyle(palette.secondary).lineLimit(1)
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
        .background(palette.light ? palette.inset : Color(rgb: 0x11171B), in: RoundedRectangle(cornerRadius: 12))
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
                Picker("Equalizer Preset", selection: Binding(get: { dial.prefs.preset }, set: { dial.applyPreset($0) })) {
                    Text("Custom").tag("Custom")
                    ForEach(Array(Set(DialState.presets.keys).union(dial.prefs.customEQ.keys)).sorted(), id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden().frame(width: 112)
                ForEach(0..<5) { index in
                    let names = ["60", "250", "1K", "4K", "16K"]
                    let colors: [Color] = [Color(rgb: 0xFF6172), .orange, palette.signal, Color(rgb: 0x47A4FF), Color(rgb: 0xB781F0)]
                    DialKnob(label: names[index], value: dial.prefs.eq[index], range: -12...12, neutral: 0, tint: colors[index]) { dial.setGain(index, $0) }
                }
                Rectangle().fill(.white.opacity(0.09)).frame(width: 1, height: 49)
            }
            DialKnob(label: "VOL", value: dial.prefs.volume, range: 0...100, neutral: 80, tint: palette.signal) { dial.setVolume($0) }
                .contextMenu { Button("Mute / Unmute") { dial.toggleMute() } }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, dial.mini ? 0 : 2)
    }

    private func round(_ title: String, _ icon: String, tint: Color, active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15, weight: .semibold))
                .frame(width: dial.mini ? 32 : 40, height: dial.mini ? 32 : 40)
                .foregroundStyle(active ? Color.white : tint)
                .background(LinearGradient(colors: active ? [tint.opacity(0.78), tint.opacity(0.17)] : [.white.opacity(0.08), .black.opacity(0.08)],
                                           startPoint: .top, endPoint: .bottom), in: Circle())
                .overlay { Circle().strokeBorder(active ? tint : .white.opacity(0.10)) }
        }
        .buttonStyle(.plain).help(title).accessibilityLabel(title)
    }

    private var library: some View {
        VStack(spacing: 0) {
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
                Button("Search") { search() }.buttonStyle(.borderedProminent)
            }
            if !dial.radioError.isEmpty { Text(dial.radioError).font(.caption).foregroundStyle(.orange) }
            table(dial.stations, empty: dial.busy ? "Loading stations…" : "No stations found.", more: dial.more) {
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

        let name = (Self.pinnedCountries + countries).first { $0.id == countrySelection.code }?.name ?? "All Countries"
        return Menu {
            ForEach(Self.pinnedCountries) { country in
                countryOption(country.name, selection: .pinned(country.id), resetFilters: resetFilters)
            }
            Divider()
            countryOption("All Countries", selection: .all, resetFilters: resetFilters)
            ForEach(countries) { country in
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
            if countrySelection == selection {
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
            table(dial.prefs.favorites.filter { activeFavoriteType == 0 ? $0.isRadio : !$0.isRadio }, empty: "No favorites here yet.") { dial.open($0) }
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

    private func table(_ items: [Source], empty: String, more: Bool = false, action: @escaping (Source) -> Void) -> some View {
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
                Image(systemName: dial.source?.id == item.id && dial.playback == .playing ? "waveform" : item.feed != nil ? "mic" : item.isRadio ? "radio" : "play.circle")
                    .frame(width: 19).foregroundStyle(dial.source?.id == item.id ? palette.signal : palette.accent)
                Text(item.title).font(.system(size: 13, weight: .medium, design: .serif)).lineLimit(1)
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

struct Artwork: View {
    var url: URL?
    var icon: String
    var palette: DialPalette

    var body: some View {
        AsyncImage(url: url) { phase in
            if let image = phase.image { image.resizable().aspectRatio(contentMode: .fit) }
            else {
                ZStack {
                    LinearGradient(colors: [palette.panel, palette.inset], startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: icon).font(.system(size: 30, weight: .light)).foregroundStyle(palette.accent)
                }
            }
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
private final class DialDelegate: NSObject, NSApplicationDelegate {
    weak var dial: DialState?
    private var keyMonitor: Any?
    private var player: DialState?
    private var window: NSWindow?
    private var statusItem: NSStatusItem?
    private var preferenceObserver: AnyCancellable?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let model = DialState()
        player = model
        dial = model
        let screen = NSScreen.main?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1000, height: 760)
        let size = NSSize(width: min(980, screen.width - 28), height: min(720, screen.height - 36))
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Radio Dial"
        window.identifier = NSUserInterfaceItemIdentifier("radio-dial-main")
        window.isReleasedWhenClosed = false
        window.contentMinSize = NSSize(width: 840, height: 620)
        window.contentView = NSHostingView(rootView: DialWindow(dial: model))
        window.center()
        self.window = window
        installMenus()
        preferenceObserver = model.$prefs.map(\.keepInMenuBar).removeDuplicates().sink { [weak self] visible in
            self?.configureStatusItem(visible)
        }
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        model.bootstrap()
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let dial = self?.dial, event.window?.attachedSheet == nil else { return event }
            let modifiers = event.modifierFlags.intersection([.command, .shift, .option, .control])
            if modifiers.isEmpty && event.keyCode == 49 && !(event.window?.firstResponder is NSTextView) {
                dial.togglePlayback()
                return nil
            }
            if modifiers == .command {
                switch event.keyCode {
                case 31: dial.pane = .custom
                case 47: dial.stop()
                case 126: dial.setVolume(dial.prefs.volume + 5)
                case 125: dial.setVolume(dial.prefs.volume - 5)
                default: return event
                }
                return nil
            }
            if modifiers == [.command, .shift] {
                switch event.keyCode {
                case 15: dial.toggleRecording()
                case 46: dial.toggleMute()
                case 34: dial.mini.toggle()
                default: return event
                }
                return nil
            }
            return event
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
        NSApp.mainMenu = root
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

    @objc private func showPlayer() { window?.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true) }
    @objc private func showAbout() { showPlayer(); dial?.pane = .about }
    @objc private func showSettings() { showPlayer(); dial?.pane = .settings }
    @objc private func showStream() { showPlayer(); dial?.pane = .custom }
    @objc private func importPlaylist() { showPlayer(); dial?.importList() }
    @objc private func playPause() { dial?.togglePlayback() }
    @objc private func stop() { dial?.stop() }
    @objc private func record() { showPlayer(); dial?.toggleRecording() }
    @objc private func mini() { showPlayer(); dial?.mini.toggle() }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let dial else { return .terminateNow }
        dial.stop()
        dial.audio.afterRecordingsSaved { sender.reply(toApplicationShouldTerminate: true) }
        return .terminateLater
    }
}
