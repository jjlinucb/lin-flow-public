import LinFlowCore
import SwiftUI

/// SwiftUI has its own `Settings` scene type.
typealias AppSettings = LinFlowCore.Settings

struct DashboardView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        NavigationSplitView {
            List(DashboardModel.Section.allCases, selection: Binding(
                get: { Optional(model.section) },
                set: { if let s = $0 { model.section = s } }
            )) { s in
                Label(s.rawValue, systemImage: s.symbol).tag(s)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190, max: 240)
        } detail: {
            detail
        }
        .frame(minWidth: 900, minHeight: 560)
        .navigationTitle("Lin Flow")
        .navigationSubtitle(model.section.rawValue)
    }

    /// macOS 26 draws a glass zone over the top of the detail pane, and anything
    /// static that lands in it renders permanently blurred: on 2026-09-16, the day
    /// after John's Mac went to macOS 27, the Notetaker's "New" button and the
    /// Dictation stats were smudges he could not read. The scroll-edge and toolbar
    /// knobs (`scrollEdgeEffectHidden`, `scrollEdgeEffectStyle(.hard)`,
    /// `toolbarBackgroundVisibility(.hidden)`, `sceneBridgingOptions`) each leave the
    /// header blurred; only moving the content out of the zone fixes it.
    ///
    /// The zone ends in a hairline about 101 pt down, and 48 pt is measured against it,
    /// not guessed. 34 pt cleared the blur by 2 pt, which read as fixed in a screenshot
    /// and wrong in the window: the hairline cut straight through the top of the
    /// Notetaker's New button. Clearing the blur and clearing the line are two
    /// different bars, and this one has to meet the second.
    private var detail: some View { section.padding(.top, 48) }

    @ViewBuilder private var section: some View {
        switch model.section {
        case .dictation: DictationHistoryView(model: model)
        case .notetaker: NotetakerView(model: model)
        case .dictionary: DictionaryView(model: model)
        case .snippets: SnippetsView(model: model)
        case .style: StyleView(model: model)
        case .transforms: TransformsView(model: model)
        case .settings: SettingsView(model: model)
        }
    }
}

// MARK: - Dictation

struct DictationHistoryView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        VStack(spacing: 0) {
            // Total words and the streak count every computer once shared totals are on and
            // another computer is in them; words per minute stays this Mac's own.
            HStack(alignment: .firstTextBaseline, spacing: 28) {
                StatTile(value: DailyTotals.grouped(model.totalWords), label: "total words")
                StatTile(value: "\(model.stats.wordsPerMinute)", label: "words per minute")
                StatTile(value: "\(model.streakDays)", label: "day streak")
                Spacer()
                TextField("Search dictations", text: $model.search)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 260)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
            if let caption = model.totalsCaption {
                Text(caption)
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20).padding(.bottom, 10)
            }
            Divider()
            if model.filteredEntries.isEmpty {
                ContentUnavailableView(model.entries.isEmpty ? "No dictations yet" : "No matches",
                                       systemImage: "mic",
                                       description: Text(model.entries.isEmpty ? "Hold \(AppSettings.shared.hotkey.label) and talk. Everything you dictate shows up here." : "Nothing matches “\(model.search)”."))
            } else {
                List {
                    ForEach(model.groupedEntries, id: \.0) { day, items in
                        Section(day) {
                            ForEach(items) { entry in DictationRow(entry: entry, model: model) }
                        }
                    }
                }
                .listStyle(.inset)
            }
            if let note = model.learnedNote {
                HStack {
                    Image(systemName: "sparkles").foregroundStyle(Color.accentColor)
                    Text(note).font(.callout)
                    Spacer()
                    Button("Dictionary") { model.section = .dictionary }.buttonStyle(.borderless)
                    Button("Dismiss") { model.learnedNote = nil }.buttonStyle(.borderless)
                }
                .padding(10)
                .background(.quaternary)
            }
            if let err = model.errorMessage, model.section == .dictation {
                ErrorBar(text: err) { model.errorMessage = nil }
            }
        }
    }
}

struct StatTile: View {
    let value: String
    let label: String
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(value).font(.system(size: 26, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(label).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct DictationRow: View {
    let entry: HistoryEntry
    @ObservedObject var model: DashboardModel
    @State private var hovering = false
    @State private var draft = ""

    private static let time: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm a"; return f }()

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(Self.time.string(from: entry.timestamp))
                .font(.callout).monospacedDigit().foregroundStyle(.secondary)
                .frame(width: 66, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                if model.editingEntryID == entry.id {
                    TextField("", text: $draft, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit { model.saveEdit(entry, to: draft) }
                    HStack(spacing: 8) {
                        Text("Fix a misheard word and Lin Flow remembers it.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Cancel") { model.editingEntryID = nil }
                        Button("Save") { model.saveEdit(entry, to: draft) }.buttonStyle(.borderedProminent)
                    }
                    .controlSize(.small)
                } else {
                    Text(entry.text)
                        .textSelection(.enabled)
                }
                if let t = entry.transform {
                    HStack(spacing: 6) {
                        Image(systemName: "wand.and.stars")
                        Text("Rewritten as \(t)")
                        Button("Undo") { model.undoTransform(entry) }.buttonStyle(.link)
                    }
                    .font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 10) {
                if model.hasAudio(entry) {
                    Button { model.togglePlayback(entry) } label: {
                        Image(systemName: model.playingID == entry.id ? "stop.circle.fill" : "play.circle")
                    }.help(model.playingID == entry.id ? "Stop" : "Play the recording")
                }
                Button { model.copy(entry) } label: { Image(systemName: "doc.on.doc") }.help("Copy")
                Button { draft = entry.text; model.editingEntryID = entry.id } label: { Image(systemName: "pencil") }
                    .help("Edit the text, and teach the dictionary")
                if model.rewritingID == entry.id {
                    ProgressView().controlSize(.small)
                } else {
                    Menu {
                        ForEach(model.transforms) { t in Button(t.name) { model.apply(t, to: entry) } }
                    } label: { Image(systemName: "wand.and.stars") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).frame(width: 22)
                    .help("Rewrite with a transform").disabled(model.rewritingID != nil)
                }
                if model.hasAudio(entry) {
                    Button { model.retry(entry) } label: {
                        if model.retryingID == entry.id { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
                    }.help("Transcribe again with the current model").disabled(model.retryingID != nil)
                }
                Button(role: .destructive) { model.delete(entry) } label: { Image(systemName: "trash") }.help("Delete")
            }
            .buttonStyle(.borderless)
            .font(.system(size: 15))
            .opacity(hovering ? 1 : 0.55)
        }
        .padding(.vertical, 6)
        .onHover { hovering = $0 }
    }
}

struct ErrorBar: View {
    let text: String
    let dismiss: () -> Void
    var body: some View {
        HStack {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(text).font(.callout)
            Spacer()
            Button("Dismiss", action: dismiss).buttonStyle(.borderless)
        }
        .padding(10)
        .background(.quaternary)
    }
}

// MARK: - Dictionary

struct DictionaryView: View {
    @ObservedObject var model: DashboardModel
    @State private var newTerm = ""
    @State private var heard = ""
    @State private var meant = ""

    var body: some View {
        HStack(alignment: .top, spacing: 28) {
            VStack(alignment: .leading, spacing: 10) {
                Text("Words").font(.title3.weight(.semibold))
                Text("Names, products, jargon. Whisper is primed with these and the cleanup pass snaps near-misses to this exact spelling.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Add a word or name", text: $newTerm).textFieldStyle(.roundedBorder).onSubmit(addTerm)
                    Button("Add", action: addTerm).disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                List {
                    ForEach(model.terms, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button(role: .destructive) { model.removeTerm(term) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless).help("Remove")
                        }
                    }
                }
                .listStyle(.inset)
            }
            VStack(alignment: .leading, spacing: 10) {
                Text("Corrections").font(.title3.weight(.semibold))
                Text("When Lin Flow hears the left, it writes the right. Whole words, any capitalization.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack {
                    TextField("Heard as", text: $heard).textFieldStyle(.roundedBorder).onSubmit(addReplacement)
                    Image(systemName: "arrow.right").foregroundStyle(.secondary)
                    TextField("Should be", text: $meant).textFieldStyle(.roundedBorder).onSubmit(addReplacement)
                    Button("Add", action: addReplacement)
                        .disabled(heard.trimmingCharacters(in: .whitespaces).isEmpty || meant.trimmingCharacters(in: .whitespaces).isEmpty)
                }
                Picker("When you fix pasted text", selection: Binding(get: { model.learnMode }, set: { model.learnMode = $0 })) {
                    ForEach(LearnMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .pickerStyle(.menu)
                if !model.pendingCorrections.isEmpty {
                    Text("Suggested").font(.headline)
                    ForEach(model.pendingCorrections) { r in
                        HStack {
                            Text(r.from).foregroundStyle(.secondary)
                            Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                            Text(r.to)
                            Spacer()
                            Button("Add") { model.acceptCorrection(r) }
                            Button("No") { model.dismissCorrection(r) }
                        }
                        .controlSize(.small)
                    }
                    Divider()
                }
                if model.replacements.isEmpty {
                    ContentUnavailableView("No corrections yet", systemImage: "arrow.left.arrow.right",
                                           description: Text("Add one when a word keeps coming out wrong, for example “wisper flow” to “Wispr Flow”."))
                } else {
                    List {
                        ForEach(Glossary.displayOrder(model.replacements)) { r in
                            HStack {
                                Text(r.from).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                                Text(r.to)
                                if r.learned {
                                    Text("learned").font(.caption2).padding(.horizontal, 5).padding(.vertical, 1)
                                        .background(Capsule().fill(.quaternary))
                                        .help("Lin Flow added this from an edit you made")
                                }
                                Spacer()
                                Button(role: .destructive) { model.removeReplacement(r) } label: { Image(systemName: "trash") }
                                    .buttonStyle(.borderless).help("Remove")
                            }
                        }
                    }
                    .listStyle(.inset)
                }
            }
        }
        .padding(20)
    }

    private func addTerm() { model.addTerm(newTerm); newTerm = "" }
    private func addReplacement() { model.addReplacement(from: heard, to: meant); heard = ""; meant = "" }
}

// MARK: - Notetaker

struct NotetakerView: View {
    @ObservedObject var model: DashboardModel
    @State private var hovered: String?

    private static let date: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d, h:mm a"; return f }()

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Meetings").font(.headline)
                    Spacer()
                    if model.selectedNoteIDs.count > 1 {
                        Button(role: .destructive) { model.deleteSelectedNote() } label: {
                            Label("Delete \(model.selectedNoteIDs.count)", systemImage: "trash")
                        }
                        .help("Delete the selected meetings. They go to the Trash.")
                    }
                    Button { model.newNote() } label: { Label("New", systemImage: "plus") }
                }
                .padding(12)
                List(selection: $model.selectedNoteIDs) {
                    ForEach(model.notes) { note in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                HStack {
                                    Text(note.title).lineLimit(1)
                                    if model.isRecording, model.recordingNoteID == note.id {
                                        Circle().fill(.red).frame(width: 7, height: 7)
                                    }
                                }
                                Text(Self.date.string(from: note.createdAt) + (note.durationSeconds > 0 ? " · \(max(1, Int(note.durationSeconds / 60))) min" : ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            // Deleting a meeting used to mean opening it and finding the
                            // ellipsis menu. It is the row's own button now.
                            // Dimmed rather than hidden until hover, the way the dictation
                            // rows do it: a control nobody can see is the thing being
                            // complained about, and at opacity 0 it is not in the
                            // accessibility tree either.
                            Button { model.deleteNotes([note.id]) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .opacity(hovered == note.id ? 1 : 0.35)
                                .help("Delete this meeting. It goes to the Trash.")
                        }
                        .contentShape(Rectangle())
                        .onHover { hovered = $0 ? note.id : (hovered == note.id ? nil : hovered) }
                        .tag(note.id)
                        .contextMenu {
                            Button(model.deleteRowLabel(for: note.id), role: .destructive) { model.deleteFromRow(note.id) }
                        }
                    }
                }
                .listStyle(.inset)
                .onDeleteCommand { model.deleteSelectedNote() }
                Text("Meetings go to the Trash after \(NotesStore.keepDays) days.")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.vertical, 8)
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            if let note = model.selectedNote {
                NoteDetailView(model: model, note: note)
            } else if model.selectedNoteIDs.count > 1 {
                ContentUnavailableView("\(model.selectedNoteIDs.count) meetings selected", systemImage: "checklist",
                                       description: Text("Press Delete, or right-click the list, to remove them all. They go to the Trash."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView("No meeting selected", systemImage: "note.text",
                                       description: Text("Click New, then Start recording when the meeting begins."))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct NoteDetailView: View {
    @ObservedObject var model: DashboardModel
    let note: MeetingNote
    @State private var title = ""
    /// 0 = the summary, 1 = the running notes, once both exist.
    @State private var summaryTab = 0

    private var hasBoth: Bool { !model.summary.isEmpty && !model.runningNotes.isEmpty }
    private var showsRunningNotes: Bool { hasBoth ? summaryTab == 1 : (model.summary.isEmpty && !model.runningNotes.isEmpty) }

    /// This note is the one being recorded (another note may be recording instead).
    private var isThisRecording: Bool { model.isRecording && model.recordingNoteID == note.id }
    private var otherIsRecording: Bool { model.isRecording && !isThisRecording }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Title", text: $title)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onChange(of: title) { model.rename(title, id: note.id) }   // saved as typed, no Return needed
                Spacer()
                if model.exportingNoteID == note.id {
                    Text("Saving audio").font(.caption).foregroundStyle(.secondary)
                    ProgressView(value: model.exportProgress).frame(width: 80)
                }
                Menu {
                    Button("Copy as Markdown") { model.copyMarkdown() }
                    Button("Save as Markdown…") { model.saveMarkdown() }
                    Button("Save Audio as \(model.audioFormat.rawValue.uppercased())…") { model.saveAudio() }
                        .disabled(isThisRecording || model.exportingNoteID != nil || !model.hasAudio(note.id))
                        .help("Both sides of the meeting in one file, your voice leveled to match the call's.")
                    Button("Show Files in Finder") { model.revealNoteFolder() }
                    Divider()
                    Button("Transcribe Again from the Recording") { model.transcribeFromAudio(note.id) }
                        .disabled(isThisRecording || model.transcribing || !model.hasAudio(note.id))
                        .help("Rebuild the transcript from the saved audio with the current speech model. The live transcript is kept as transcript-live.jsonl.")
                    Divider()
                    Button("Delete Note", role: .destructive) { model.deleteSelectedNote() }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 28)
            }
            HStack(spacing: 14) {
                Button { model.toggleRecording() } label: {
                    Label(isThisRecording ? "Stop" : "Start recording", systemImage: isThisRecording ? "stop.circle.fill" : "record.circle")
                        .frame(minWidth: 130)
                }
                .buttonStyle(.borderedProminent)
                .tint(isThisRecording ? .red : .accentColor)
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(otherIsRecording || model.exportingNoteID == note.id)
                .help(otherIsRecording ? "Another meeting is recording. Stop it first." : "")
                .fixedSize()
                Toggle("Microphone", isOn: $model.useMicrophone).disabled(model.isRecording).fixedSize()
                Toggle("System audio", isOn: $model.useSystemAudio).disabled(model.isRecording).fixedSize()
                    .help("The other people on the call, captured from what your Mac is playing")
                Text(model.elapsedLabel).monospacedDigit().foregroundStyle(.secondary).fixedSize()
                Spacer(minLength: 8)
                if isThisRecording {
                    LevelMeter(label: "You", level: model.micLevel, color: .blue)
                    LevelMeter(label: "Others", level: model.systemLevel, color: .orange)
                }
            }
            .toggleStyle(.checkbox)
            if let err = model.errorMessage { ErrorBar(text: err) { model.errorMessage = nil } }

            HSplitView {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Transcript").font(.headline)
                        if model.transcribing, model.transcribingNoteID == note.id {
                            ProgressView().controlSize(.mini)
                            Text("From the recording: \(model.transcribeProgress)").font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if note.transcribedFromAudioAt != nil {
                            Text("from the recording").font(.caption).foregroundStyle(.secondary)
                                .help("Rebuilt from the saved audio after the meeting" + (note.transcriptModel.map { " (\($0))" } ?? ""))
                        } else if !model.segments.isEmpty, !isThisRecording {
                            Text("live").font(.caption).foregroundStyle(.secondary)
                                .help("What was transcribed during the meeting. Transcribe Again from the Recording (in the menu) rebuilds it from the audio.")
                        }
                        Spacer()
                        if !model.segments.isEmpty {
                            CopyTextButton(help: "Copy the whole transcript, with times and speakers") {
                                NotesStore.transcriptText(model.segments)
                            }
                            .controlSize(.small)
                        }
                    }
                    if model.segments.isEmpty {
                        ContentUnavailableView(isThisRecording ? "Listening…" : "No transcript yet", systemImage: "waveform",
                                               description: Text(isThisRecording ? "Lines appear a moment after each pause." : "Start recording to transcribe live."))
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        ScrollViewReader { proxy in
                            List(model.segments) { seg in
                                HStack(alignment: .top, spacing: 10) {
                                    Text(seg.timestampLabel).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                                        .frame(width: 44, alignment: .leading)
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(seg.speaker).font(.caption.weight(.semibold))
                                            .foregroundStyle(seg.speaker == "You" ? Color.blue : Color.orange)
                                        Text(seg.text).textSelection(.enabled)
                                    }
                                }
                                .id(seg.id)
                                .padding(.vertical, 2)
                            }
                            .listStyle(.inset)
                            .onChange(of: model.segments.count) {
                                if let last = model.segments.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                            }
                        }
                    }
                }
                .frame(minWidth: 240)

                VStack(alignment: .leading, spacing: 6) {
                    Text("My notes").font(.headline)
                    TextEditor(text: $model.notesText)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                        .frame(minHeight: 140)
                    HStack(spacing: 8) {
                        if hasBoth {
                            Picker("", selection: $summaryTab) {
                                Text("Summary").tag(0)
                                Text("Running notes").tag(1)
                            }
                            .pickerStyle(.segmented).labelsHidden().fixedSize()
                        } else {
                            Text(showsRunningNotes || (isThisRecording && model.runningNotesStatus == nil) ? "Running notes" : "Summary").font(.headline)
                        }
                        if model.summarizing {
                            ProgressView().controlSize(.small)
                            Text(model.summaryProgress).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        } else if model.takingNotes, model.recordingNoteID == note.id || !model.isRecording {
                            ProgressView().controlSize(.small)
                            Text("Taking notes…").font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        CopyTextButton(help: showsRunningNotes ? "Copy the running notes" : "Copy the summary") {
                            showsRunningNotes ? model.runningNotes : model.summary
                        }
                        .disabled((showsRunningNotes ? model.runningNotes : model.summary).isEmpty)
                        Button("Recap 5 min") { model.recap() }
                            .disabled(model.segments.isEmpty || model.summarizing)
                            .help("What did I miss? A few bullets on the last five minutes.")
                        Button("Summarize") { model.summarize() }
                            .disabled(model.segments.isEmpty || model.summarizing || model.isRecording || (model.transcribing && model.transcribingNoteID == note.id))
                            .help(model.transcribing && model.transcribingNoteID == note.id
                                  ? "Wait for the transcript from the recording; it is the one worth summarizing."
                                  : model.claudeReady
                                    ? "Summary, decisions, action items and open questions, written by Claude from the whole transcript."
                                    : "Summary, decisions, action items and open questions, written on this Mac by Apple Intelligence.")
                    }
                    .controlSize(.small)
                    ScrollViewReader { proxy in
                        ScrollView {
                            if showsRunningNotes {
                                SummaryMarkdown(text: model.runningNotes)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Color.clear.frame(height: 1).id("running-notes-end")
                            } else if !model.summary.isEmpty {
                                SummaryMarkdown(text: model.summary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            } else {
                                Text(isThisRecording
                                     ? (model.runningNotesStatus ?? "Notes appear here every minute or so while the meeting runs. Summarize once it ends.")
                                     : "Press Summarize to get the summary, decisions and action items.")
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .onChange(of: model.runningNotes.count) {
                            if showsRunningNotes { withAnimation { proxy.scrollTo("running-notes-end", anchor: .bottom) } }
                        }
                    }
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                    AskPanel(model: model, hasTranscript: !model.segments.isEmpty)
                }
                .frame(minWidth: 230)
            }
        }
        .padding(16)
        .onAppear { title = note.title }
        .onChange(of: note.id) { title = note.title; summaryTab = 0 }
    }

}

/// Ask Claude about the meeting, during it or after: three quick questions and a box for
/// anything else. Each answer stays with the note.
struct AskPanel: View {
    @ObservedObject var model: DashboardModel
    let hasTranscript: Bool
    @State private var draft = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Ask Claude").font(.headline)
                if model.asking {
                    ProgressView().controlSize(.small)
                    Text("Thinking…").font(.caption).foregroundStyle(.secondary)
                }
            }
            if !model.claudeReady {
                Text("Run scripts/setup-claude.sh once to save a Claude key, then reopen Lin Flow.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                HStack(spacing: 6) {
                    ForEach(MeetingQuestions.quick, id: \.label) { q in
                        Button(q.label) { model.ask(q.question) }
                            .disabled(model.asking || !hasTranscript)
                    }
                    CopyTextButton(help: "Copy the latest answer. Right-click an answer to copy that one.") {
                        model.questions.last?.answer ?? ""
                    }
                    .disabled(model.questions.isEmpty)
                }
                .controlSize(.small)
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 10) {
                            ForEach(Array(model.questions.enumerated()), id: \.offset) { i, turn in
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(turn.question).bold()
                                    SummaryMarkdown(text: turn.answer)
                                }
                                .id(i)
                                .contextMenu { Button("Copy") { CopyTextButton.copy(turn.answer) } }
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .frame(minHeight: 90)
                    .onChange(of: model.questions.count) {
                        withAnimation { proxy.scrollTo(model.questions.count - 1, anchor: .bottom) }
                    }
                }
                .padding(8)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                TextField("Ask about this meeting…", text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .disabled(model.asking)
                    .onSubmit {
                        model.ask(draft)
                        draft = ""
                    }
            }
        }
    }
}

/// "Copy text", then "Copied" for a moment. A pane drawn as one Text view per line can't be
/// drag-selected whole, so each one carries this. The text is built only on a click.
struct CopyTextButton: View {
    var help = "Copy all of it"
    let text: () -> String
    @State private var copied = false

    var body: some View {
        Button(copied ? "Copied" : "Copy text") {
            Self.copy(text())
            copied = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
        }
        .help(help)
    }

    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

/// Line-based rendering of the summarizer's Markdown: headings, bullets, rules, paragraphs.
struct SummaryMarkdown: View {
    let text: String

    enum Block { case heading(String), bullet(String), paragraph(String), rule }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                switch block {
                case .heading(let t):
                    Text(t).font(.headline).padding(.top, 6)
                case .bullet(let t):
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text("•").foregroundStyle(.secondary)
                        Text(inline(t))
                    }
                case .paragraph(let t):
                    Text(inline(t))
                case .rule:
                    Divider().padding(.vertical, 4)
                }
            }
        }
        .textSelection(.enabled)
    }

    private var blocks: [Block] {
        text.split(separator: "\n", omittingEmptySubsequences: true).map { raw in
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#") { return .heading(line.drop(while: { $0 == "#" }).trimmingCharacters(in: .whitespaces)) }
            if line.hasPrefix("* ") || line.hasPrefix("- ") || line.hasPrefix("• ") { return .bullet(String(line.dropFirst(2))) }
            if line == "---" { return .rule }
            return .paragraph(line)
        }
    }

    private func inline(_ s: String) -> AttributedString {
        (try? AttributedString(markdown: s, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
    }
}

struct LevelMeter: View {
    let label: String
    let level: Float
    let color: Color
    var body: some View {
        HStack(spacing: 6) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule().fill(color).frame(width: geo.size.width * CGFloat(min(1, level * 6)))
                }
            }
            .frame(width: 70, height: 8)
        }
    }
}

// MARK: - Settings

struct SettingsView: View {
    @ObservedObject var model: DashboardModel
    private var s: AppSettings { AppSettings.shared }

    var body: some View {
        Form {
            Section("Dictation") {
                LabeledContent("Hold to talk key") {
                    HStack {
                        if model.recordingHotkey {
                            Text("Press a key, keys or mouse button…").foregroundStyle(.secondary)
                            Button("Cancel") { model.finishRecordingHotkey(nil) }
                        } else {
                            Picker("", selection: binding(\.hotkey, apply: { model.controller.setHotkey($0) })) {
                                // A recorded key that is not a preset still shows, as itself.
                                ForEach(Hotkey.presets.contains(s.hotkey) ? Hotkey.presets : Hotkey.presets + [s.hotkey], id: \.self) {
                                    Text($0.label).tag($0)
                                }
                            }
                            .labelsHidden()
                            .fixedSize()
                            Button("Record…") { model.recordHotkey() }
                                .help("Press any key, combination or mouse button. Escape cancels.")
                        }
                    }
                }
                Picker("Model", selection: Binding(get: { s.modelID }, set: { model.controller.loadModel(id: $0); model.settingChanged() })) {
                    ForEach(ModelCatalog.installedModelURLs(), id: \.path) { url in
                        let id = ModelCatalog.idFromURL(url)
                        Text("\(EngineFactory.kind(for: url).displayName) · \(id)").tag(id)
                    }
                }
                Picker("Cleanup", selection: binding(\.cleanupLevel)) {
                    ForEach(CleanupLevel.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("None pastes the engine's words as-is. Light fixes fillers, dictionary spellings and punctuation instantly. Medium adds an on-device rewrite for clarity, about ten seconds per dictation. Details in Style.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Spoken commands (“new line”, “question mark”)", isOn: binding(\.spokenCommands))
                Toggle("Numbers as digits (“twenty two” becomes 22)", isOn: binding(\.numbersAsDigits))
                Toggle("Add a space after each dictation", isOn: binding(\.trailingSpace))
                Picker("When you fix pasted text", selection: binding(\.learnCorrections)) {
                    ForEach(LearnMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Lin Flow reads back the field it pasted into and turns a word you fix into a dictionary correction. Editing a dictation in the list here does the same, and works in every app.")
                    .font(.caption).foregroundStyle(.secondary)
                Stepper("Keep dictation audio for \(s.audioRetentionDays) days", value: binding(\.audioRetentionDays), in: 0...365, step: 5)
            }
            Section("Notetaker") {
                Toggle("Offer to record when a call starts", isOn: binding(\.offerToRecordCalls))
                    .help("When Zoom, Teams, a browser or another call app has used the microphone for a few seconds, a toast offers to record it. One offer per call.")
                Toggle("Keep meeting audio files", isOn: binding(\.keepMeetingAudio))
                Toggle("Transcribe the recording again when a meeting ends", isOn: binding(\.transcribeAfterMeeting))
                    .help("The live transcript is cut every 10 s to keep up. Once the meeting ends, the saved audio is transcribed whole and replaces it; the live one is kept as transcript-live.jsonl.")
                Toggle("Write running notes during a meeting", isOn: binding(\.runningNotes))
                    .help("Every minute or so, Apple Intelligence reads what was just said and adds a few bullets to the note. They are saved to running-notes.md as they are written.")
                Text("Transcripts, notes and summaries are always kept. Audio is optional and can be large: about 115 MB per hour per source.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Shared totals") {
                LabeledContent("Status") {
                    Text(model.syncStatusText)
                        .multilineTextAlignment(.trailing)
                        .textSelection(.enabled)
                }
                Button("Sync now") { model.syncNow() }
                    .help("Send this Mac's totals and read the other computers' now, rather than at the next dictation.")
                Text("Turned on, the Dictation total adds up every computer you dictate on. Only counts leave this Mac: a date, and the words, dictations and seconds of audio on it. What you said never does. A sync.env file in the data folder turns it on. The README shows what goes in it.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("App") {
                Toggle("Show floating pill", isOn: binding(\.showHUD))
                Toggle("Show in Dock", isOn: binding(\.showInDock))
                Toggle("Sounds", isOn: binding(\.sounds))
                Toggle("Open this window when Lin Flow starts", isOn: binding(\.openWindowAtLaunch))
                HStack {
                    Button("Open Data Folder") { NSWorkspace.shared.open(ModelCatalog.appSupportDir) }
                    Button("Open Log") { NSWorkspace.shared.open(Log.defaultFileURL) }
                }
                Text("Everything lives in ~/Library/Application Support/Lin Flow. Transcripts, audio and the dictionary never leave this Mac.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func binding<T>(_ keyPath: ReferenceWritableKeyPath<AppSettings, T>, apply: ((T) -> Void)? = nil) -> Binding<T> {
        Binding(get: { AppSettings.shared[keyPath: keyPath] },
                set: { AppSettings.shared[keyPath: keyPath] = $0; apply?($0); model.settingChanged() })
    }
}


// MARK: - Snippets

struct SnippetsView: View {
    @ObservedObject var model: DashboardModel
    @State private var editingID: String?
    @State private var trigger = ""
    @State private var text = ""

    private var canSave: Bool {
        !trigger.trimmingCharacters(in: .whitespaces).isEmpty && !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Snippets").font(.title3.weight(.semibold))
            Text("Say the trigger and Lin Flow pastes the saved text instead. “Insert” or “snippet” in front is optional: “insert my address”. Whole words, any capitalization.")
                .font(.callout).foregroundStyle(.secondary)
            GroupBox(editingID == nil ? "New snippet" : "Edit snippet") {
                VStack(alignment: .leading, spacing: 8) {
                    TextField("Trigger, for example “my address”", text: $trigger).textFieldStyle(.roundedBorder)
                    TextEditor(text: $text)
                        .font(.body)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                        .frame(minHeight: 70, maxHeight: 140)
                    HStack {
                        Text("The text can run to several lines.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if editingID != nil { Button("Cancel") { reset() } }
                        Button(editingID == nil ? "Add" : "Save") { save() }.buttonStyle(.borderedProminent).disabled(!canSave)
                    }
                }
                .padding(6)
            }
            if let err = model.errorMessage, model.section == .snippets { ErrorBar(text: err) { model.errorMessage = nil } }
            if model.snippets.isEmpty {
                ContentUnavailableView("No snippets yet", systemImage: "scissors",
                                       description: Text("Add your address, an email sign-off, or a prompt you dictate often."))
            } else {
                List {
                    ForEach(model.snippets) { s in
                        HStack(alignment: .top, spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(s.trigger).font(.headline)
                                Text(s.text).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                            }
                            Spacer()
                            Button { edit(s) } label: { Image(systemName: "pencil") }.help("Edit")
                            Button(role: .destructive) { model.removeSnippet(s); if editingID == s.id { reset() } } label: { Image(systemName: "trash") }.help("Delete")
                        }
                        .buttonStyle(.borderless)
                        .padding(.vertical, 4)
                    }
                }
                .listStyle(.inset)
            }
        }
        .padding(20)
    }

    private func edit(_ s: Snippet) { editingID = s.id; trigger = s.trigger; text = s.text }
    private func reset() { editingID = nil; trigger = ""; text = "" }
    private func save() { if model.saveSnippet(id: editingID, trigger: trigger, text: text) { reset() } }
}

// MARK: - Style

struct StyleView: View {
    @ObservedObject var model: DashboardModel

    static let sample = "hey joey, um, we still on for coffee or? I think we maybe should leave earlier to make it there in time there might be, uh, traffic. what are you thinking?"
    static let mediumSample = "Hey Joey, are we still on for coffee? We should leave earlier to make it in time, there might be traffic. What do you think?"

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Auto cleanup").font(.title3.weight(.semibold))
                Text("Applied to every dictation in every app. The text before a rewrite is kept: use Undo on a dictation to get it back.")
                    .font(.callout).foregroundStyle(.secondary)
                HStack(alignment: .top, spacing: 14) {
                    ForEach(CleanupLevel.allCases, id: \.self) { level in
                        LevelCard(level: level, selected: model.cleanupLevel == level, example: example(level)) { model.cleanupLevel = level }
                    }
                }
                if model.cleanupLevel == .medium, let why = RewriterFactory.best().1 {
                    ErrorBar(text: why) {}
                }
                Divider().padding(.vertical, 4)
                Text("By app").font(.title3.weight(.semibold))
                Text("Give an app its own transform, or none. Dictations into Claude Code or a terminal can come out as agent prompts while Slack stays as spoken. An app rule wins over the cleanup level.")
                    .font(.callout).foregroundStyle(.secondary)
                if model.appRules.isEmpty {
                    Text("No app rules yet.").foregroundStyle(.secondary)
                }
                ForEach(model.appRules) { rule in
                    HStack(spacing: 10) {
                        Image(nsImage: model.appIcon(rule.bundleID)).resizable().frame(width: 24, height: 24)
                        Text(model.appName(rule.bundleID))
                        Spacer()
                        Picker("", selection: Binding(get: { rule.transformID }, set: { model.setTransform($0, forApp: rule.bundleID) })) {
                            Text("No transform").tag(Transforms.none)
                            Divider()
                            ForEach(model.transforms) { t in Text(t.name).tag(t.id) }
                        }
                        .labelsHidden().frame(width: 200)
                        Button(role: .destructive) { model.setTransform(nil, forApp: rule.bundleID) } label: { Image(systemName: "trash") }
                            .buttonStyle(.borderless).help("Remove this rule")
                    }
                    .padding(.vertical, 2)
                }
                Menu {
                    ForEach(model.runningApps, id: \.bundleID) { app in
                        Button(app.name) { model.setTransform(Transforms.clarityID, forApp: app.bundleID) }
                    }
                    Divider()
                    Button("Choose an App…") { model.chooseAppForRule(transformID: Transforms.clarityID) }
                } label: { Label("Add App", systemImage: "plus") }
                .fixedSize()
                Text("New rules start with Clarity. Edit the transforms themselves under Transforms.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(20)
        }
    }

    private func example(_ level: CleanupLevel) -> String {
        switch level {
        case .none: return Self.sample
        case .light:
            var cleaner = TextCleaner(glossary: [], replacements: [])
            cleaner.spokenCommands = false
            return cleaner.clean(Self.sample)
        case .medium: return Self.mediumSample
        }
    }
}

struct LevelCard: View {
    let level: CleanupLevel
    let selected: Bool
    let example: String
    let action: () -> Void

    private var blurb: String {
        switch level {
        case .none: return "The engine's words exactly, mistakes included."
        case .light: return "Fillers, dictionary spellings, punctuation and capitalization. Instant."
        case .medium: return "Light, then Apple Intelligence rewrites for clarity and grammar on this Mac. About ten seconds per dictation."
        }
    }

    var body: some View {
        Button(action: action) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text(level.label).font(.title2.weight(.semibold))
                    Spacer()
                    if selected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
                }
                Text(blurb).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Text(example)
                    .font(.callout.italic())
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.5)))
            }
            .padding(14)
            .frame(maxWidth: .infinity, minHeight: 250, alignment: .topLeading)
            .background(RoundedRectangle(cornerRadius: 12).fill(.background))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? Color.accentColor : Color.secondary.opacity(0.25), lineWidth: selected ? 2 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Transforms

struct TransformsView: View {
    @ObservedObject var model: DashboardModel

    var body: some View {
        HSplitView {
            VStack(spacing: 0) {
                HStack {
                    Text("Transforms").font(.headline)
                    Spacer()
                    Button { model.addTransform() } label: { Label("New", systemImage: "plus") }
                }
                .padding(12)
                List(selection: $model.selectedTransformID) {
                    ForEach(model.transforms) { t in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(t.name).lineLimit(1)
                            if t.builtIn { Text("Built in").font(.caption).foregroundStyle(.secondary) }
                        }
                        .tag(t.id)
                    }
                }
                .listStyle(.inset)
                if model.missingBuiltIns {
                    Button("Restore built-ins") { model.restoreBuiltInTransforms() }.controlSize(.small).padding(8)
                }
            }
            .frame(minWidth: 200, idealWidth: 230, maxWidth: 300)

            if let t = model.selectedTransform {
                TransformDetailView(model: model, transform: t).id(t.id)
            } else {
                ContentUnavailableView("No transform selected", systemImage: "wand.and.stars",
                                       description: Text("Pick one on the left, or click New."))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

struct TransformDetailView: View {
    @ObservedObject var model: DashboardModel
    let transform: Transform
    @State private var name = ""
    @State private var instructions = ""

    private var usedIn: [String] {
        AppSettings.shared.appTransforms.filter { $0.value == transform.id }.keys.map { model.appName($0) }.sorted()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("Name", text: $name)
                    .textFieldStyle(.plain)
                    .font(.title2.weight(.semibold))
                    .onChange(of: name) { save() }
                Spacer()
                Menu {
                    Button("Delete Transform", role: .destructive) { model.removeTransform(transform) }
                } label: { Image(systemName: "ellipsis.circle") }
                .menuStyle(.borderlessButton).frame(width: 28)
            }
            Text("Instructions").font(.headline)
            Text("What the on-device model does with the dictation. It always keeps names, numbers and technical terms, keeps your language, and never answers the text itself.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $instructions)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                .frame(minHeight: 110, maxHeight: 180)
                .onChange(of: instructions) { save() }
            HStack(spacing: 6) {
                Text("Used in:").font(.callout.weight(.semibold))
                if transform.id == Transforms.clarityID, model.cleanupLevel == .medium {
                    Text("every app without its own rule (Medium cleanup)" + (usedIn.isEmpty ? "" : ", " + usedIn.joined(separator: ", "))).font(.callout)
                } else if usedIn.isEmpty {
                    Text("no app yet. Assign apps under Style.").font(.callout).foregroundStyle(.secondary)
                } else {
                    Text(usedIn.joined(separator: ", ")).font(.callout)
                }
            }
            if let err = model.errorMessage, model.section == .transforms { ErrorBar(text: err) { model.errorMessage = nil } }
            Divider()
            Text("Try it").font(.headline)
            TextEditor(text: $model.tryInput)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
                .frame(minHeight: 60, maxHeight: 110)
            HStack(spacing: 10) {
                Button("Run") { model.tryTransform() }
                    .disabled(model.trying || model.tryInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if model.trying { ProgressView().controlSize(.small) }
                else if model.tryElapsed > 0, !model.tryOutput.isEmpty { Text(String(format: "%.1f s", model.tryElapsed)).font(.caption).foregroundStyle(.secondary) }
                Spacer()
                if !model.tryOutput.isEmpty {
                    Button("Copy") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(model.tryOutput, forType: .string) }
                }
            }
            ScrollView {
                Text(model.tryOutput.isEmpty ? "The rewrite shows up here." : model.tryOutput)
                    .foregroundStyle(model.tryOutput.isEmpty ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(8)
            .frame(minHeight: 70)
            .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.5)))
        }
        .padding(16)
        .onAppear { name = transform.name; instructions = transform.instructions }
    }

    private func save() {
        var t = transform
        t.name = name.trimmingCharacters(in: .whitespaces).isEmpty ? transform.name : name
        t.instructions = instructions
        model.updateTransform(t)
    }
}
