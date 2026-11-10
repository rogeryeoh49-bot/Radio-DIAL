import AppKit
import ServiceManagement
import SwiftUI

struct PanelBody: View {
    @ObservedObject var dial: DialState
    let pane: DialState.Pane
    @Environment(\.dismiss) private var dismiss
    @State private var minutes = 30
    @State private var title = ""
    @State private var address = ""
    @State private var query = ""
    @State private var secret = ""
    @State private var message = ""
    @State private var launching = SMAppService.mainApp.status == .enabled

    var body: some View {
        VStack(alignment: .leading, spacing: 15) {
            HStack {
                Text(heading).font(.title2.bold())
                Spacer()
                Button { dismiss() } label: { Image(systemName: "xmark.circle.fill").font(.title3) }
                    .buttonStyle(.plain).foregroundStyle(.secondary).accessibilityLabel("Close")
            }
            switch pane {
            case .capture: capture
            case .scheduled: ScheduleEditor(dial: dial, mode: .recording)
            case .alarms: ScheduleEditor(dial: dial, mode: .alarm)
            case .sleep: sleep
            case .lyrics: LyricsView(dial: dial)
            case .info: sourceInfo
            case .settings: settings
            case .theme: themes
            case .playlist: playlists
            case .presets: presets
            case .about: about
            case .stream: stream
            case .custom: custom
            }
        }
    }

    private var heading: String {
        switch pane {
        case .capture: return "Recording settings"
        case .scheduled: return "Scheduled recordings"
        case .alarms: return "Radio alarms"
        case .sleep: return "Sleep timer"
        case .lyrics: return "Song & Lyrics"
        case .info: return "Source information"
        case .settings: return "Settings"
        case .theme: return "Themes"
        case .playlist: return "Playlists"
        case .presets: return "Equalizer presets"
        case .about: return "About Radio Dial"
        case .stream: return "Stream monitor"
        case .custom: return "Open a stream"
        }
    }

    private var capture: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(dial.source?.title ?? "").foregroundStyle(.secondary)
            RecordingFields(dial: dial)
            HStack {
                Spacer()
                Button("Start Recording") { dial.startRecording(); dismiss() }.buttonStyle(.borderedProminent)
            }
        }
    }

    private var sleep: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Stop playback after a set time.").foregroundStyle(.secondary)
            HStack {
                ForEach([15, 30, 45, 60, 90, 120], id: \.self) { value in
                    Button("\(value) min") { minutes = value }
                }
            }
            Stepper("\(minutes) minutes", value: $minutes, in: 1...360)
            if let end = dial.sleepEnd {
                Text("Stops at \(end.formatted(date: .omitted, time: .shortened)) · \(dial.sleepRemaining) remaining")
                    .foregroundStyle(.secondary)
                Button("Cancel Active Timer") { dial.sleep(minutes: 0) }
            }
            Button("Start Timer") { dial.sleep(minutes: minutes); dismiss() }.buttonStyle(.borderedProminent)
        }
    }

    private var sourceInfo: some View {
        Group {
            if let source = dial.source {
                HStack(alignment: .top, spacing: 14) {
                    Artwork(url: dial.art, icon: "radio", palette: DialPalette(dial.prefs.theme)).frame(width: 78, height: 78)
                    VStack(alignment: .leading, spacing: 7) {
                        Text(source.title).font(.headline)
                        Text([source.country, source.codec, source.bitrate > 0 ? "\(source.bitrate) kbps" : "", source.tags].filter { !$0.isEmpty }.joined(separator: "  •  "))
                            .foregroundStyle(.secondary).textSelection(.enabled)
                        Text(source.url.absoluteString).font(.caption.monospaced()).textSelection(.enabled)
                        if source.isRadio, UUID(uuidString: source.id) != nil { Text("\(source.votes) directory votes").font(.caption) }
                        HStack {
                            if let website = source.website { Link("Website", destination: website) }
                            if !source.url.isFileURL { Button("Test Stream") { dial.test(source) } }
                            if source.isRadio, UUID(uuidString: source.id) != nil { Button("Vote") { dial.vote(source) } }
                        }
                    }
                }
            } else { Text("Choose a station or episode first.").foregroundStyle(.secondary) }
            Text(dial.status).foregroundStyle(.secondary).font(.caption)
        }
    }

    private var settings: some View {
        TabView {
            VStack(alignment: .leading, spacing: 12) {
                Toggle("Resume last source on launch", isOn: $dial.prefs.resumeOnLaunch)
                Toggle("Show player in the menu bar", isOn: $dial.prefs.keepInMenuBar)
                Toggle("Open at login", isOn: $launching)
                    .onChange(of: launching) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                        } catch { message = error.localizedDescription }
                    }
                Toggle("Identify music automatically when stations provide no track title", isOn: $dial.prefs.automaticRecognition)
                Text("Identification sends a short sample of the playing stream to the recognition service.").font(.caption).foregroundStyle(.secondary)
                HStack {
                    Text("Balance")
                    Slider(value: Binding(get: { dial.prefs.balance }, set: { dial.setBalance($0) }), in: -100...100)
                    Button("Center") { dial.setBalance(0) }
                }
                HStack {
                    Text("Podcast store")
                    TextField("US", text: $dial.prefs.podcastCountry).frame(width: 70)
                    Text("Two-letter country code").foregroundStyle(.secondary).font(.caption)
                }
                Spacer()
            }.padding(14).tabItem { Text("General") }
            VStack(alignment: .leading, spacing: 12) {
                Picker("Stream buffer", selection: $dial.prefs.profile) {
                    ForEach(["Low latency", "Balanced", "Stable"], id: \.self) { Text($0) }
                }
                TextField("HTTP proxy, e.g. http://127.0.0.1:8080", text: $dial.prefs.proxy)
                Text("Applies to new stream connections. Directory and podcast search use macOS network settings.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(14).tabItem { Text("Network") }
            VStack(alignment: .leading, spacing: 9) {
                HStack {
                    TextField("API key", text: $dial.prefs.lastFMKey)
                    SecureField("Shared secret", text: $secret)
                }
                HStack {
                    Button("Authorize Last.fm") {
                        Task {
                            do {
                                try await dial.links.beginAuth(key: dial.prefs.lastFMKey, secret: secret)
                                secret = ""
                                message = "Approve access in your browser, then click Complete Authorization."
                            } catch { message = error.localizedDescription }
                        }
                    }.disabled(dial.prefs.lastFMKey.isEmpty || secret.isEmpty)
                    Button("Complete Authorization") {
                        Task {
                            do {
                                dial.prefs.lastFMUser = try await dial.links.finishAuth(key: dial.prefs.lastFMKey)
                                dial.prefs.lastFMEnabled = true
                                message = "Connected as \(dial.prefs.lastFMUser)"
                            } catch { message = error.localizedDescription }
                        }
                    }
                }
                if !dial.prefs.lastFMUser.isEmpty {
                    Toggle("Scrobble as \(dial.prefs.lastFMUser)", isOn: $dial.prefs.lastFMEnabled)
                    Button("Disconnect Last.fm") {
                        dial.links.disconnect()
                        dial.prefs.lastFMEnabled = false
                        dial.prefs.lastFMUser = ""
                    }
                }
                Divider()
                TextField("Discord application ID", text: $dial.prefs.discordID)
                Text("Rich Presence requires the Discord desktop app and your application ID.").font(.caption).foregroundStyle(.secondary)
                Spacer()
            }.padding(14).tabItem { Text("Integrations") }
            VStack(alignment: .leading, spacing: 10) {
                Text("Space    Play / Pause")
                Text("⌘.       Stop")
                Text("⇧⌘R      Record")
                Text("⌘↑ / ⌘↓  Volume")
                Text("⇧⌘M      Mute")
                Text("⇧⌘I      Mini player")
                Spacer()
            }.font(.system(.callout, design: .monospaced)).padding(14).tabItem { Text("Shortcuts") }
        }
        .frame(height: 249)
        .overlay(alignment: .bottom) {
            if !message.isEmpty { Text(message).font(.caption).foregroundStyle(.secondary).padding(.bottom, 7) }
        }
    }

    private var themes: some View {
        VStack(alignment: .leading, spacing: 12) {
            Button {
                dial.prefs.theme = RadioReceiverStyle.name
                dismiss()
            } label: {
                HStack(spacing: 14) {
                    ReceiverThemePreview().frame(width: 176, height: 82)
                    VStack(alignment: .leading, spacing: 5) {
                        Text(RadioReceiverStyle.name).font(.headline)
                        Text("Brushed metal receiver with a tuning scale and station presets")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    if dial.prefs.theme == RadioReceiverStyle.name {
                        Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint)
                    }
                }
                .padding(10)
                .background(.quaternary.opacity(0.6), in: RoundedRectangle(cornerRadius: 10))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(RadioReceiverStyle.name)

            themeSwatches
        }
    }

    private var themeSwatches: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 3), spacing: 9) {
            ForEach(DialPalette.themes, id: \.self) { name in
                let swatch = DialPalette(name)
                Button { dial.prefs.theme = name } label: {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 4) {
                            ForEach([swatch.base, swatch.inset, swatch.accent, swatch.signal], id: \.self) { color in
                                Circle().fill(color).frame(width: 11, height: 11)
                            }
                            Spacer()
                            if name == dial.prefs.theme { Image(systemName: "checkmark.circle.fill").foregroundStyle(swatch.signal) }
                        }
                        Text(name).font(.caption.bold()).foregroundStyle(swatch.text)
                    }
                    .padding(9)
                    .background(swatch.panel, in: RoundedRectangle(cornerRadius: 7))
                    .overlay { RoundedRectangle(cornerRadius: 7).strokeBorder(swatch.line) }
                }.buttonStyle(.plain)
            }
        }
    }

    private var playlists: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Import radio streams into Favorites, or export your radio favorites as a playlist.").foregroundStyle(.secondary)
            HStack {
                Button("Import M3U / PLS…") { dial.importList() }
                Button("Export M3U…") { dial.exportList("m3u") }
                Button("Export PLS…") { dial.exportList("pls") }
            }
            Text(dial.status).font(.caption).foregroundStyle(.secondary)
        }
    }

    private var presets: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Load preset", selection: Binding(get: { dial.prefs.preset }, set: { dial.applyPreset($0) })) {
                Text("Custom").tag("Custom")
                ForEach(Array(Set(DialState.presets.keys).union(dial.prefs.customEQ.keys)).sorted(), id: \.self) { Text($0).tag($0) }
            }
            HStack {
                TextField("New preset name", text: $title)
                Button("Save Current EQ") {
                    let label = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    dial.prefs.customEQ[label] = dial.prefs.eq
                    dial.prefs.preset = label
                    title = ""
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || title == "Custom" || DialState.presets[title] != nil)
                if dial.prefs.customEQ[dial.prefs.preset] != nil {
                    Button("Delete") {
                        dial.prefs.customEQ.removeValue(forKey: dial.prefs.preset)
                        dial.prefs.preset = "Custom"
                    }
                }
            }
            Text("Drag the five knobs on the player to adjust the sound. Double-click a knob to reset it.").font(.caption).foregroundStyle(.secondary)
        }
    }

    private var stream: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(dial.source?.title ?? "No stream selected").font(.headline)
            LabeledContent("Status", value: dial.status)
            LabeledContent("Codec", value: dial.source?.codec.nonempty ?? "Unknown")
            LabeledContent("Advertised bitrate", value: dial.source.map { $0.bitrate > 0 ? "\($0.bitrate) kbps" : "Unknown" } ?? "Unknown")
            LabeledContent("Time to first audio", value: dial.streamLatency.map { String(format: "%.2fs", $0) } ?? "—")
            LabeledContent("Playback position", value: timeLabel(dial.elapsed))
            LabeledContent("Buffer profile", value: dial.prefs.profile)
            if let source = dial.source, !source.url.isFileURL { Button("Test Stream") { dial.test(source) } }
        }
    }

    private var custom: some View {
        VStack(alignment: .leading, spacing: 12) {
            TextField("Stream URL", text: $address)
            TextField("Name (optional)", text: $title)
            Button("Play Stream") { dial.openStream(address, name: title); dismiss() }
                .buttonStyle(.borderedProminent).disabled(Catalog.webURL(address) == nil)
        }
    }

    private var about: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Radio Dial 1.0 · Apple silicon").font(.headline)
            Text("An independent internet radio and podcast player for macOS.")
            HStack {
                Link("Radio Browser", destination: URL(string: "https://www.radio-browser.info")!)
                Link("LRCLIB", destination: URL(string: "https://lrclib.net")!)
                Link("FFmpeg", destination: URL(string: "https://ffmpeg.org")!)
            }
            Text(AudioTools.ffmpeg.map { "Decoder: \($0.path)" } ?? DialError.missingDecoder.localizedDescription)
                .font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
        }
    }
}

private struct RecordingFields: View {
    @ObservedObject var dial: DialState
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack {
                Picker("Format", selection: $dial.prefs.capture.format) {
                    ForEach(["mp3", "wav", "flac", "ogg"], id: \.self) { Text($0.uppercased()) }
                }
                if ["mp3", "ogg"].contains(dial.prefs.capture.format) {
                    Picker("Bitrate", selection: $dial.prefs.capture.bitrate) {
                        ForEach([96, 128, 160, 192, 256, 320], id: \.self) { Text("\($0) kbps").tag($0) }
                    }
                }
            }
            Toggle("Split into files when the song title changes", isOn: $dial.prefs.capture.split)
            HStack {
                TextField("Filename prefix", text: $dial.prefs.capture.prefix)
                TextField("Artist tag", text: $dial.prefs.capture.artist)
                TextField("Album tag", text: $dial.prefs.capture.album)
            }
            HStack {
                Text(dial.prefs.capture.folder.path).font(.caption.monospaced()).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Spacer()
                Button("Choose Folder…") { dial.chooseFolder() }
            }
        }
    }
}

private struct ScheduleEditor: View {
    @ObservedObject var dial: DialState
    let mode: TimedAction.Mode
    @State private var name = ""
    @State private var station = ""
    @State private var date = Date().addingTimeInterval(120)
    @State private var rule = TimedAction.Repeat.once
    @State private var duration = 30
    @State private var days: Set<Int> = []
    @State private var editing: UUID?

    private var candidates: [Source] {
        var ids: Set<String> = []
        let candidates = [dial.source].compactMap { $0 } + dial.prefs.favorites + dial.prefs.actions.map(\.source) + dial.stations
        return candidates.filter { $0.isRadio && ids.insert($0.id).inserted }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("Radio Dial needs to be running when a task is due.").font(.caption).foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 5) {
                    ForEach(dial.prefs.actions.filter { $0.mode == mode }) { item in
                        HStack {
                            Toggle("", isOn: Binding(get: {
                                dial.prefs.actions.first { $0.id == item.id }?.enabled ?? false
                            }, set: { enabled in
                                if let index = dial.prefs.actions.firstIndex(where: { $0.id == item.id }) { dial.prefs.actions[index].enabled = enabled }
                            })).labelsHidden().accessibilityLabel("Enable \(item.name)")
                            VStack(alignment: .leading) {
                                Text(item.name).font(.headline)
                                Text("\(item.source.title)  ·  \(item.repeatRule.rawValue)  ·  \(item.date.formatted(date: item.repeatRule == .once ? .abbreviated : .omitted, time: .shortened))")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Edit") { edit(item) }
                            Button(role: .destructive) {
                                dial.prefs.actions.removeAll { $0.id == item.id }
                                if editing == item.id { reset() }
                            } label: { Image(systemName: "trash") }.help("Delete scheduled task")
                        }
                        .padding(6)
                    }
                    if !dial.prefs.actions.contains(where: { $0.mode == mode }) {
                        Text("No scheduled tasks.").foregroundStyle(.secondary).padding(9)
                    }
                }
            }.frame(maxHeight: 145)
            Divider()
            TextField("Name", text: $name)
            Picker("Station", selection: $station) {
                Text("Select a station").tag("")
                ForEach(candidates) { Text($0.title).tag($0.id) }
            }
            HStack {
                DatePicker("Starts", selection: $date, displayedComponents: [.date, .hourAndMinute])
                Picker("Repeat", selection: $rule) {
                    ForEach(TimedAction.Repeat.allCases, id: \.self) { Text($0.rawValue) }
                }
            }
            if rule == .custom {
                HStack {
                    ForEach(1...7, id: \.self) { day in
                        Toggle(Calendar.current.shortWeekdaySymbols[day - 1], isOn: Binding(get: { days.contains(day) }, set: { selected in
                            if selected { days.insert(day) } else { days.remove(day) }
                        })).toggleStyle(.button)
                    }
                }
            }
            if mode == .recording {
                Stepper("Duration: \(duration) min", value: $duration, in: 1...1440)
                DisclosureGroup("Recording format and folder") { RecordingFields(dial: dial).padding(.top, 8) }
            }
            HStack {
                if editing != nil { Button("Cancel Edit") { reset() } }
                Spacer()
                Button(editing == nil ? "Add" : "Save Changes") { save() }
                    .buttonStyle(.borderedProminent).disabled(station.isEmpty || (rule == .custom && days.isEmpty))
            }
        }
        .onAppear { station = dial.source?.isRadio == true ? dial.source?.id ?? "" : "" }
    }

    private func edit(_ item: TimedAction) {
        name = item.name
        station = item.source.id
        date = item.date
        rule = item.repeatRule
        duration = item.duration
        days = item.days
        editing = item.id
    }

    private func reset() {
        name = ""; rule = .once; date = Date().addingTimeInterval(120); duration = 30; days = []; editing = nil
    }

    private func save() {
        guard let selected = candidates.first(where: { $0.id == station }) else { return }
        let rounded = Calendar.current.dateInterval(of: .minute, for: date)?.start ?? date
        let item = TimedAction(id: editing ?? UUID(), mode: mode, name: name.nonempty ?? selected.title,
                               source: selected, date: rounded, repeatRule: rule, duration: duration, days: days)
        if let index = dial.prefs.actions.firstIndex(where: { $0.id == editing }) { dial.prefs.actions[index] = item }
        else { dial.prefs.actions.append(item) }
        reset()
    }
}

private struct LyricsView: View {
    @ObservedObject var dial: DialState
    @State private var query = ""
    @State private var shift = 0.0
    private var lines: [LyricLine] {
        guard let value = dial.lyrics?.syncedLyrics else { return [] }
        return value.components(separatedBy: .newlines).compactMap { line in
            guard let end = line.firstIndex(of: "]"), line.first == "[" else { return nil }
            let time = line[line.index(after: line.startIndex)..<end].split(separator: ":").compactMap { Double($0) }
            guard time.count == 2 else { return nil }
            return LyricLine(time: time[0] * 60 + time[1], text: line[line.index(after: end)...].trimmingCharacters(in: .whitespaces))
        }.sorted { $0.time < $1.time }
    }
    private var active: Int? { lines.lastIndex { $0.time <= dial.currentLyricTime + shift } }

    var body: some View {
        VStack(alignment: .leading, spacing: 11) {
            HStack {
                TextField("Artist and song title", text: $query).onSubmit { dial.findLyrics(query) }
                Button("Find Lyrics") { dial.findLyrics(query) }.buttonStyle(.borderedProminent)
                Button(dial.finding ? "Identifying…" : "Identify") { dial.identify() }.disabled(dial.finding)
                    .help("Send a short sample of the playing stream for song identification.")
            }
            if let result = dial.lyrics { Text("\(result.trackName)  ·  \(result.artistName)").font(.headline) }
            if !dial.lyricStatus.isEmpty { Text(dial.lyricStatus).foregroundStyle(.secondary) }
            if dial.lyrics == nil && dial.lyricStatus.isEmpty {
                Text("Search by title, or identify the song playing on the current station.").foregroundStyle(.secondary)
            }
            ScrollViewReader { proxy in
                ScrollView {
                    if !lines.isEmpty {
                        LazyVStack(alignment: .leading, spacing: 6) {
                            ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
                                if !line.text.isEmpty {
                                    Text(line.text)
                                        .font(index == active ? .body.bold() : .body)
                                        .foregroundStyle(index == active ? Color.accentColor : .secondary)
                                        .id(index)
                                }
                            }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    } else if let lyrics = dial.lyrics?.plainLyrics {
                        Text(lyrics).frame(maxWidth: .infinity, alignment: .leading)
                    }
                }.textSelection(.enabled).frame(height: 285)
                    .onChange(of: active) { _, index in
                        if let index { withAnimation { proxy.scrollTo(index, anchor: .center) } }
                    }
            }
            HStack {
                if !lines.isEmpty { Stepper("Lyric offset: \(Int(shift))s", value: $shift, in: -120...120) }
                Spacer()
                if let text = dial.lyrics?.plainLyrics ?? dial.lyrics?.syncedLyrics {
                    Button("Copy Lyrics") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(text, forType: .string) }
                }
            }
        }
        .onAppear {
            query = dial.track
            if !query.isEmpty, dial.lyrics == nil { dial.findLyrics(query) }
        }
        .onChange(of: dial.track) { _, title in query = title; shift = 0 }
    }
}

private struct LyricLine {
    var time: Double
    var text: String
}
