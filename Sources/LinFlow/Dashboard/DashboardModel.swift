import AppKit
import AVFoundation
import Combine
import LinFlowCore
import UniformTypeIdentifiers

/// State behind the main window. Everything here runs on the main thread;
/// the core layer already delivers its callbacks there.
final class DashboardModel: NSObject, ObservableObject, MeetingRecorderDelegate, AVAudioPlayerDelegate {
    enum Section: String, CaseIterable, Identifiable {
        case dictation = "Dictation", notetaker = "Notetaker", dictionary = "Dictionary", snippets = "Snippets",
             style = "Style", transforms = "Transforms", settings = "Settings"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .dictation: return "mic"
            case .notetaker: return "note.text"
            case .dictionary: return "character.book.closed"
            case .snippets: return "scissors"
            case .style: return "textformat"
            case .transforms: return "wand.and.stars"
            case .settings: return "gearshape"
            }
        }
    }

    let controller: DictationController
    @Published var section: Section = .dictation
    /// Settings' Record button is listening for a new talk key. See DashboardModel+Hotkey.
    @Published var recordingHotkey = false
    var hotkeyMonitor: Any?
    var hotkeyRecorder = HotkeyRecorder()
    var hotkeyTimeout: DispatchWorkItem?

    // MARK: dictation
    @Published private(set) var entries: [HistoryEntry] = []   // newest first
    @Published var search = ""
    @Published private(set) var stats = HistoryStats()
    /// Every computer's totals, once sync.env is set up and the first read is back. TotalsSync.
    @Published private(set) var combined: CombinedTotals?
    @Published private(set) var syncStatus = SyncStatus.off
    @Published private(set) var playingID: String?
    @Published private(set) var retryingID: String?
    @Published private(set) var rewritingID: String?
    private var player: AVAudioPlayer?

    // MARK: snippets
    @Published private(set) var snippets: [Snippet] = []

    // MARK: transforms
    @Published private(set) var transforms: [Transform] = []
    @Published var selectedTransformID: String?
    @Published var tryInput = ""
    @Published private(set) var tryOutput = ""
    @Published private(set) var trying = false
    @Published private(set) var tryElapsed: Double = 0
    private var transformSaveWork: DispatchWorkItem?

    // MARK: dictionary
    @Published private(set) var terms: [String] = []
    @Published private(set) var replacements: [Replacement] = []
    @Published private(set) var pendingCorrections: [Replacement] = []
    /// "Learned: X to Y", shown for a moment after an edit teaches something.
    @Published var learnedNote: String?
    @Published var editingEntryID: String?

    // MARK: notetaker
    @Published private(set) var notes: [MeetingNote] = []
    @Published var selectedNoteID: String? {
        didSet {
            guard oldValue != selectedNoteID else { return }
            if !syncingNoteSelection {
                syncingNoteSelection = true
                selectedNoteIDs = selectedNoteID.map { [$0] } ?? []
                syncingNoteSelection = false
            }
            loadSelectedNote()
        }
    }

    /// What the meetings list actually binds to, so several can be deleted at once.
    /// `selectedNoteID` stays the one the detail pane shows, and is nil while more than
    /// one row is selected. The flag keeps the two from bouncing off each other: without
    /// it, selecting a second row clears `selectedNoteID`, whose own didSet would then
    /// throw away the very selection the user just made.
    @Published var selectedNoteIDs: Set<String> = [] {
        didSet {
            guard oldValue != selectedNoteIDs, !syncingNoteSelection else { return }
            syncingNoteSelection = true
            selectedNoteID = selectedNoteIDs.count == 1 ? selectedNoteIDs.first : nil
            syncingNoteSelection = false
        }
    }

    private var syncingNoteSelection = false
    @Published private(set) var segments: [TranscriptSegment] = []
    @Published var notesText = "" { didSet { scheduleNotesSave() } }
    @Published private(set) var summary = ""
    @Published private(set) var isRecording = false
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var micLevel: Float = 0
    @Published private(set) var systemLevel: Float = 0
    @Published private(set) var summarizing = false
    @Published private(set) var summaryProgress = ""
    /// Running notes: a few bullets a minute while a meeting records (see RunningNotes).
    @Published private(set) var runningNotes = ""
    /// Questions John asked Claude about the selected note, and the answers (`questions.json`).
    @Published private(set) var questions: [MeetingQuestions.Turn] = []
    @Published private(set) var asking = false
    let claudeReady = ClaudeClient.isConfigured
    @Published private(set) var takingNotes = false
    /// Why running notes are off for this meeting, if they are (no Apple Intelligence).
    @Published private(set) var runningNotesStatus: String?
    private var notedSegmentIDs: Set<String> = []
    private var runningNotesTimer: Timer?
    private var lastNotesPassAt = Date()
    private var runningNotesNoteID: String?
    /// A transcript is being rewritten from a note's saved audio (see NoteTranscriber).
    @Published private(set) var transcribing = false
    @Published private(set) var transcribeProgress = ""
    @Published private(set) var transcribingNoteID: String?
    private var transcribeQueue: [String] = []
    private var transcribeWaits = 0
    private let transcribeWork = DispatchQueue(label: "linflow.notes.transcribe", qos: .utility)
    /// A note's audio being saved as one file (see AudioExport), and how far it has got.
    @Published private(set) var exportingNoteID: String?
    @Published private(set) var exportProgress = 0.0
    private let exportWork = DispatchQueue(label: "linflow.notes.export", qos: .userInitiated)
    private var renameFiles: [String: DispatchWorkItem] = [:]
    @Published var errorMessage: String?
    @Published var useMicrophone = Settings.shared.meetingUsesMicrophone { didSet { Settings.shared.meetingUsesMicrophone = useMicrophone } }
    @Published var useSystemAudio = Settings.shared.meetingUsesSystemAudio { didSet { Settings.shared.meetingUsesSystemAudio = useSystemAudio } }
    private var recorder: MeetingRecorder?
    private var callWatch = CallWatch()
    private var callTimer: Timer?
    private var cleanupTimer: Timer?
    private var lastSpeechAt = Date()
    private var stopAt: Date?
    private var stopReason = ""
    private var micQueryRunning = false
    /// What held the microphone at the last poll, so the log says only when it changes. John,
    /// 10-12: a Teams call neither offered a note nor ended one, and nothing said what was seen.
    private var lastMicUsers: [String]?
    /// Core Audio is asked here, never on the main thread: on 10-07 a device switch hung a
    /// microphone start inside the HAL for good.
    private let callQueue = DispatchQueue(label: "linflow.callwatch", qos: .utility)
    /// Posted on the main thread with "title", "detail" and "seconds": a toast whose click keeps
    /// the note recording.
    static let callOver = Notification.Name("LinFlow.Meeting.callOver")
    /// Posted on the main thread when that toast no longer applies.
    static let callOverCleared = Notification.Name("LinFlow.Meeting.callOverCleared")
    /// Posted on the main thread with "title" and "detail" once a note stopped by itself.
    static let stoppedByItself = Notification.Name("LinFlow.Meeting.stoppedByItself")
    /// Posted on the main thread with "name" when a call app has started a call and nothing records it.
    static let callStarted = Notification.Name("LinFlow.Meeting.callStarted")
    private var callOffer = CallOffer()
    private var offerTimer: Timer?
    private var offerQueryRunning = false
    private var elapsedTimer: Timer?
    private var notesSaveWork: DispatchWorkItem?
    private var pendingNotesSave: (id: String, text: String)?
    private var loadingNote = false
    private var observers: [NSObjectProtocol] = []

    init(controller: DictationController) {
        self.controller = controller
        super.init()
        reloadHistory()
        reloadDictionary()
        reloadNotes()
        reloadSnippets()
        reloadTransforms()
        let nc = NotificationCenter.default
        observers.append(nc.addObserver(forName: History.didChange, object: nil, queue: .main) { [weak self] _ in self?.reloadHistory() })
        observers.append(nc.addObserver(forName: TotalsSync.didChange, object: nil, queue: .main) { [weak self] _ in self?.refreshTotals() })
        observers.append(nc.addObserver(forName: Glossary.didChange, object: nil, queue: .main) { [weak self] _ in self?.reloadDictionary() })
        observers.append(nc.addObserver(forName: CorrectionLearning.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.pendingCorrections = CorrectionLearning.pending()
        })
        observers.append(nc.addObserver(forName: Snippets.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadSnippets()
        })
        observers.append(nc.addObserver(forName: Transforms.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.reloadTransforms()
        })
        observers.append(nc.addObserver(forName: NotesStore.didChange, object: nil, queue: .main) { [weak self] _ in self?.reloadNotes() })
        // Never from a test instance: it must not offer to record John's own calls.
        let env = ProcessInfo.processInfo.environment
        if env["LINFLOW_TEST_AUDIO"] == nil && env["LINFLOW_NO_PASTE"] == nil {
            offerTimer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in self?.tickCallOffer() }
        }
        // A setting changed from the menu bar menu shows up here too.
        observers.append(nc.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in self?.objectWillChange.send() })
        // A meeting the last run never stopped gets closed from what is on disk, then its
        // transcript is rebuilt from the audio once the speech model is up.
        for note in NotesStore.recoverUnfinished() where NotesStore.hasAudio(note.id) { transcribeFromAudio(note.id) }
        clearOldMeetings()
        // The speaker model and John's voiceprint, for telling voices apart in a shared room.
        DispatchQueue.global(qos: .utility).async {
            if let why = VoiceID.prepare() { Log.info("voices: not ready, \(why)") }
        }
        cleanupTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.clearOldMeetings() }
    }

    /// Meetings past NotesStore.keepDays go to the Trash, at launch and every hour after, since the
    /// app stays up for days. One recording, being transcribed, saved as audio or open waits.
    func clearOldMeetings() {
        let busy = Set([recorder?.note.id, transcribingNoteID, exportingNoteID, selectedNoteID].compactMap { $0 } + transcribeQueue)
        let moved = NotesStore.trashExpired(busy: busy)
        if let id = selectedNoteID, moved.contains(where: { $0.id == id }) { selectedNoteID = nil }
    }

    deinit {
        offerTimer?.invalidate()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
    }

    // MARK: - Dictation

    func reloadHistory() {
        let all = History.all()
        entries = all.reversed()
        stats = History.stats(all)
        refreshTotals()
    }

    // MARK: shared totals

    /// This Mac's part comes from `entries`, so a dictation made a second ago is already counted;
    /// the other computers' come from the last read.
    func refreshTotals() {
        combined = TotalsSync.shared.combined(localHistory: entries)
        syncStatus = TotalsSync.shared.currentStatus
    }

    func syncNow() {
        TotalsSync.shared.requestPush()
        TotalsSync.shared.requestPull()
    }

    /// The shared totals, once another computer is in them. Until then the tiles are this Mac's.
    var sharedTotals: CombinedTotals? {
        guard let c = combined, c.computers > 1 || (c.computers == 1 && c.here == nil) else { return nil }
        return c
    }

    var totalWords: Int { sharedTotals?.words ?? stats.totalWords }
    var streakDays: Int { sharedTotals?.streakDays ?? stats.streakDays }

    /// The line under the tiles when they count more than this Mac.
    var totalsCaption: String? {
        guard let c = sharedTotals else { return nil }
        return "On \(c.computers == 1 ? "1 computer" : "\(c.computers) computers"): \(c.breakdown())."
    }

    var syncStatusText: String {
        let s = syncStatus
        guard s.on else { return "Off" }
        let name = s.device ?? "this Mac"
        if let error = s.error { return "On as \(name). The last try failed: \(error)" }
        guard let last = s.lastSync else { return "On as \(name). Waiting for the first sync." }
        return "On as \(name). Synced at \(DateFormatter.localizedString(from: last, dateStyle: .none, timeStyle: .short))."
    }

    var filteredEntries: [HistoryEntry] {
        let q = search.trimmingCharacters(in: .whitespaces).lowercased()
        return q.isEmpty ? entries : entries.filter { $0.text.lowercased().contains(q) || $0.raw.lowercased().contains(q) }
    }

    /// (day label, entries) newest day first.
    var groupedEntries: [(String, [HistoryEntry])] {
        let cal = Calendar.current
        var order: [Date] = []
        var buckets: [Date: [HistoryEntry]] = [:]
        for e in filteredEntries {
            let day = cal.startOfDay(for: e.timestamp)
            if buckets[day] == nil { order.append(day) }
            buckets[day, default: []].append(e)
        }
        let df = DateFormatter(); df.dateFormat = "EEEE, MMM d"
        return order.map { day in
            let label = cal.isDateInToday(day) ? "Today" : cal.isDateInYesterday(day) ? "Yesterday" : df.string(from: day)
            return (label, buckets[day] ?? [])
        }
    }

    func copy(_ entry: HistoryEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.text, forType: .string)
    }

    func delete(_ entry: HistoryEntry) {
        if playingID == entry.id { stopPlayback() }
        History.delete(id: entry.id)
    }

    func hasAudio(_ entry: HistoryEntry) -> Bool { History.audioURL(for: entry) != nil }

    func togglePlayback(_ entry: HistoryEntry) {
        if playingID == entry.id { stopPlayback(); return }
        guard let url = History.audioURL(for: entry) else { return }
        stopPlayback()
        do {
            let p = try AVAudioPlayer(contentsOf: url)
            p.delegate = self
            p.play()
            player = p
            playingID = entry.id
        } catch {
            errorMessage = "Couldn't play that recording: \(error.localizedDescription)"
        }
    }

    func stopPlayback() {
        player?.stop(); player = nil; playingID = nil
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        DispatchQueue.main.async { self.playingID = nil; self.player = nil }
    }

    func retry(_ entry: HistoryEntry) {
        guard retryingID == nil else { return }
        retryingID = entry.id
        controller.retranscribe(entry) { [weak self] result in
            self?.retryingID = nil
            if case .failure(let e) = result { self?.errorMessage = e.localizedDescription }
        }
    }

    /// Put the text back the way it was before the transform.
    func undoTransform(_ entry: HistoryEntry) {
        guard let original = entry.original else { return }
        var e = entry
        e.text = original; e.original = nil; e.transform = nil
        History.update(e)
    }

    /// Rewrite a past dictation with a transform (the untouched text is kept for Undo).
    func apply(_ transform: Transform, to entry: HistoryEntry) {
        guard rewritingID == nil else { return }
        let (rewriter, why) = RewriterFactory.best()
        guard let rewriter else { errorMessage = why; return }
        rewritingID = entry.id
        errorMessage = nil
        let source = entry.original ?? entry.text
        Task { @MainActor [weak self] in
            defer { self?.rewritingID = nil }
            do {
                let out = TextCleaner.applyStyle(try await rewriter.rewrite(source, using: transform))
                var e = entry
                e.original = source; e.text = out; e.transform = transform.name
                History.update(e)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: - Snippets

    func reloadSnippets() { snippets = Snippets.load() }

    /// Adds, or updates when `id` names an existing snippet. False when the trigger is empty
    /// or already used by another snippet.
    @discardableResult
    func saveSnippet(id: String?, trigger: String, text: String) -> Bool {
        let t = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        let body = text.trimmingCharacters(in: .newlines)
        guard !t.isEmpty, !body.isEmpty else { return false }
        if snippets.contains(where: { $0.trigger.lowercased() == t.lowercased() && $0.id != id }) {
            errorMessage = "There is already a snippet for “\(t)”."
            return false
        }
        var list = snippets
        if let id, let i = list.firstIndex(where: { $0.id == id }) {
            list[i].trigger = t; list[i].text = body
        } else {
            list.append(Snippet(trigger: t, text: body))
        }
        snippets = list
        Snippets.save(list)
        return true
    }

    func removeSnippet(_ snippet: Snippet) {
        snippets.removeAll { $0.id == snippet.id }
        Snippets.save(snippets)
    }

    // MARK: - Transforms

    func reloadTransforms() {
        transforms = Transforms.load()
        if let id = selectedTransformID, !transforms.contains(where: { $0.id == id }) { selectedTransformID = nil }
        if selectedTransformID == nil { selectedTransformID = transforms.first?.id }
    }

    var selectedTransform: Transform? { transforms.first { $0.id == selectedTransformID } }

    func addTransform() {
        let t = Transform(name: "New transform", instructions: "")
        transforms.append(t)
        Transforms.save(transforms)
        selectedTransformID = t.id
        section = .transforms
    }

    /// Edits arrive per keystroke; the file is written a moment after they stop.
    func updateTransform(_ transform: Transform) {
        guard let i = transforms.firstIndex(where: { $0.id == transform.id }), transforms[i] != transform else { return }
        transforms[i] = transform
        transformSaveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            Transforms.save(self.transforms)
        }
        transformSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    func removeTransform(_ transform: Transform) {
        transforms.removeAll { $0.id == transform.id }
        var table = Settings.shared.appTransforms
        for (app, id) in table where id == transform.id { table[app] = nil }
        Settings.shared.appTransforms = table
        Transforms.save(transforms)
        if selectedTransformID == transform.id { selectedTransformID = transforms.first?.id }
        settingChanged()
    }

    var missingBuiltIns: Bool { Transforms.defaults.contains { d in !transforms.contains { $0.id == d.id } } }

    func restoreBuiltInTransforms() {
        transforms = Transforms.restoringDefaults(transforms)
        Transforms.save(transforms)
    }

    func tryTransform() {
        guard !trying, let transform = selectedTransform else { return }
        let input = tryInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !input.isEmpty else { return }
        let (rewriter, why) = RewriterFactory.best()
        guard let rewriter else { errorMessage = why; return }
        trying = true
        errorMessage = nil
        let t0 = Date()
        Task { @MainActor [weak self] in
            defer { self?.trying = false }
            do {
                let out = TextCleaner.applyStyle(try await rewriter.rewrite(input, using: transform))
                self?.tryOutput = out
                self?.tryElapsed = Date().timeIntervalSince(t0)
            } catch {
                self?.errorMessage = error.localizedDescription
            }
        }
    }

    // MARK: per-app rules

    struct AppRule: Identifiable {
        let bundleID: String
        let transformID: String
        var id: String { bundleID }
    }

    /// The per-app table, sorted by app name.
    var appRules: [AppRule] {
        Settings.shared.appTransforms.map { AppRule(bundleID: $0.key, transformID: $0.value) }
            .sorted { appName($0.bundleID).localizedCaseInsensitiveCompare(appName($1.bundleID)) == .orderedAscending }
    }

    func setTransform(_ transformID: String?, forApp bundleID: String) {
        var table = Settings.shared.appTransforms
        table[bundleID] = transformID
        Settings.shared.appTransforms = table
        settingChanged()
    }

    /// Apps with a window the user could be dictating into, minus Lin Flow itself.
    var runningApps: [(bundleID: String, name: String)] {
        let taken = Set(Settings.shared.appTransforms.keys)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .compactMap { app in app.bundleIdentifier.map { ($0, app.localizedName ?? $0) } }
            .filter { !taken.contains($0.0) }
            .sorted { $0.1.localizedCaseInsensitiveCompare($1.1) == .orderedAscending }
    }

    func chooseAppForRule(transformID: String) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.message = "Choose the app whose dictations get this transform."
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier else { return }
            self?.setTransform(transformID, forApp: id)
        }
    }

    func appName(_ bundleID: String) -> String {
        if let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID }), let n = app.localizedName { return n }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        return bundleID
    }

    func appIcon(_ bundleID: String) -> NSImage {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSImage(systemSymbolName: "app.dashed", accessibilityDescription: nil) ?? NSImage()
    }

    var cleanupLevel: CleanupLevel {
        get { Settings.shared.cleanupLevel }
        set { Settings.shared.cleanupLevel = newValue; settingChanged() }
    }

    // MARK: - Dictionary

    func reloadDictionary() {
        terms = Glossary.load()
        replacements = Glossary.loadReplacements()
        pendingCorrections = CorrectionLearning.pending()
    }

    /// Save an edit to a dictation and let it teach the dictionary.
    func saveEdit(_ entry: HistoryEntry, to newText: String) {
        editingEntryID = nil
        let text = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != entry.text else { return }
        var e = entry
        let wrote = entry.text
        e.text = text
        History.update(e)
        let outcome = controller.learn(wrote: wrote, now: text)
        if let first = outcome.added.first {
            learnedNote = "Learned: “\(first.from)” now becomes “\(first.to)”."
        } else if let first = outcome.suggested.first {
            learnedNote = "Suggested: “\(first.from)” to “\(first.to)”. Confirm it under Dictionary."
        }
        if learnedNote != nil { clearLearnedNoteSoon() }
    }

    private func clearLearnedNoteSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in self?.learnedNote = nil }
    }

    func acceptCorrection(_ r: Replacement) {
        CorrectionLearning.accept(r)
    }

    func dismissCorrection(_ r: Replacement) { CorrectionLearning.dismiss(r) }

    var learnMode: LearnMode {
        get { Settings.shared.learnCorrections }
        set { Settings.shared.learnCorrections = newValue; settingChanged() }
    }

    func addTerm(_ term: String) {
        let t = term.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, !terms.contains(t) else { return }
        Glossary.saveTerms(terms + [t])
    }

    func removeTerm(_ term: String) {
        Glossary.saveTerms(terms.filter { $0 != term })
    }

    // Both of these read the file again before writing it. `replacements` is only refreshed
    // by Glossary.didChange, which the app posts for its own writes and never for John's:
    // he edits replacements.txt in a text editor with Lin Flow running. Saving from the
    // cached array then rewrote the whole file from a list that had never seen those lines,
    // deleting them silently -- one click on a trash icon could take five hand-added rules
    // with it.
    func addReplacement(from: String, to: String) {
        let f = from.trimmingCharacters(in: .whitespaces), t = to.trimmingCharacters(in: .whitespaces)
        guard !f.isEmpty, !t.isEmpty else { return }
        var list = Glossary.loadReplacements().filter { $0.from.lowercased() != f.lowercased() }
        list.append(Replacement(from: f, to: t))
        Glossary.saveReplacements(list)
    }

    func removeReplacement(_ r: Replacement) {
        Glossary.saveReplacements(Glossary.loadReplacements().filter { $0.id != r.id })
    }

    // MARK: - Notetaker

    func reloadNotes() {
        notes = NotesStore.list()
        if let id = selectedNoteID, !notes.contains(where: { $0.id == id }) { selectedNoteID = notes.first?.id }
    }

    var selectedNote: MeetingNote? { notes.first { $0.id == selectedNoteID } }

    /// The note being recorded, which need not be the one on screen.
    var recordingNoteID: String? { recorder?.note.id }

    func newNote(_ kind: String = "Meeting") {
        let df = DateFormatter(); df.dateFormat = "MMM d, h:mm a"
        let note = NotesStore.create(title: "\(kind) \(df.string(from: Date()))")
        reloadNotes()
        selectedNoteID = note.id
        section = .notetaker
    }

    /// Saves a title as it is typed. The audio files saved from the note follow once typing pauses.
    func rename(_ title: String, id: String) {
        guard var note = NotesStore.load(id) ?? notes.first(where: { $0.id == id }) else { return }
        let t = title.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty, t != note.title else { return }
        note.title = t
        if let i = notes.firstIndex(where: { $0.id == note.id }) { notes[i] = note }
        NotesStore.save(note)
        if note.audioExports?.isEmpty == false { followTitle(id) }
    }

    /// Renames a note's saved audio files to its title, a second after the last change.
    private func followTitle(_ id: String) {
        renameFiles[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in
            self?.renameFiles[id] = nil
            guard var n = NotesStore.load(id), let exports = n.audioExports else { return }
            let moved = NotesStore.followTitle(exports, to: n.title)
            guard moved != exports else { return }
            n.audioExports = moved
            NotesStore.save(n)
            Log.info("notes: \(id) saved audio renamed to follow the title: \(moved.map { URL(fileURLWithPath: $0.path).lastPathComponent })")
        }
        renameFiles[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func deleteSelectedNote() { deleteNotes(selectedNoteIDs.isEmpty ? Set([selectedNoteID].compactMap { $0 }) : selectedNoteIDs) }

    func deleteNotes(_ ids: Set<String>) {
        guard !ids.isEmpty else { return }
        if let recording = recorder?.note.id, ids.contains(recording) { stopRecording() }   // deleting another note leaves the meeting running
        for id in ids { NotesStore.delete(id) }
        syncingNoteSelection = true
        selectedNoteIDs = []
        syncingNoteSelection = false
        selectedNoteID = nil
        reloadNotes()
    }

    /// Right-clicking a row inside a multiple selection deletes the whole selection, the
    /// way the Finder does; right-clicking outside one deletes just that row.
    func deleteFromRow(_ id: String) {
        deleteNotes(selectedNoteIDs.count > 1 && selectedNoteIDs.contains(id) ? selectedNoteIDs : [id])
    }

    func deleteRowLabel(for id: String) -> String {
        selectedNoteIDs.count > 1 && selectedNoteIDs.contains(id) ? "Delete \(selectedNoteIDs.count) Meetings" : "Delete Meeting"
    }

    private func loadSelectedNote() {
        flushPendingNotesSave()   // the previous note's last edit, if it is still debounced
        loadingNote = true
        defer { loadingNote = false }
        errorMessage = nil
        guard let id = selectedNoteID else { segments = []; notesText = ""; summary = ""; return }
        segments = NotesStore.transcript(id)
        notesText = NotesStore.notesText(id)
        summary = NotesStore.summary(id) ?? ""
        runningNotes = NotesStore.runningNotes(id)
        questions = MeetingQuestions.load(id)
        elapsed = recorder?.note.id == id ? (recorder?.elapsed ?? 0) : (selectedNote?.durationSeconds ?? 0)
    }

    private func scheduleNotesSave() {
        guard !loadingNote, let id = selectedNoteID else { return }
        notesSaveWork?.cancel()
        pendingNotesSave = (id, notesText)
        let work = DispatchWorkItem { [weak self] in
            guard let self, let p = self.pendingNotesSave else { return }
            NotesStore.saveNotesText(p.text, for: p.id)
            self.pendingNotesSave = nil
        }
        notesSaveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }

    /// Write a debounced notes edit now (on a note switch or quit).
    private func flushPendingNotesSave() {
        notesSaveWork?.cancel(); notesSaveWork = nil
        if let p = pendingNotesSave { NotesStore.saveNotesText(p.text, for: p.id); pendingNotesSave = nil }
    }

    func toggleRecording() { isRecording ? stopRecording() : startRecording() }

    func startRecording() {
        guard !isRecording else { return }
        if selectedNote == nil { newNote() }
        guard let note = selectedNote else { return }
        guard controller.engine != nil else { errorMessage = "The speech model is still loading."; return }
        guard useMicrophone || useSystemAudio else { errorMessage = "Turn on the microphone, system audio, or both."; return }
        errorMessage = nil
        let r = MeetingRecorder(note: note, engine: { [controller] in controller.engine },
                                options: { [controller] in controller.currentOptions() }, glossary: controller.glossary)
        r.delegate = self
        do {
            try r.start(useMicrophone: useMicrophone, useSystemAudio: useSystemAudio, keepAudio: Settings.shared.keepMeetingAudio)
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        recorder = r
        isRecording = true
        elapsed = 0
        elapsedTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            guard let self, let r = self.recorder, self.selectedNoteID == r.note.id else { return }
            self.elapsed = r.elapsed
        }
        beginRunningNotes(for: note.id)
        beginCallWatch()
        reloadNotes()
    }

    // MARK: a call started

    private func tickCallOffer() {
        // While a note records, tickCallWatch asks Core Audio and passes the answer on.
        guard Settings.shared.offerToRecordCalls, !isRecording, !offerQueryRunning else { return }
        offerQueryRunning = true
        let now = ProcessInfo.processInfo.systemUptime
        callQueue.async { [weak self] in
            let users = CallWatch.micUsers()
            DispatchQueue.main.async {
                guard let self else { return }
                self.offerQueryRunning = false
                // A note that started meanwhile writes its own first line to its events.log.
                if !self.isRecording { self.logMicUsers(users, nil) }
                guard let name = self.callOffer.observe(at: now, micUsers: users, recording: self.isRecording) else { return }
                Log.info("meeting: \(name) is on the microphone, offering a note")
                NotificationCenter.default.post(name: Self.callStarted, object: self, userInfo: ["name": name])
            }
        }
    }

    /// The offer's click: a new note for this call, recording now. Never into the note that
    /// happens to be selected.
    func recordCall(_ name: String) {
        guard !isRecording else { return }
        newNote("\(name) call")
        let id = selectedNoteID
        startRecording()
        if let r = recorder {
            NotesStore.appendEvent("[0:00] started from the offer: \(name) was on the microphone", to: r.note.id)
        } else if let id {
            // The engine still loading, or both sources off: the window says why, and no empty note stays behind.
            NotesStore.delete(id)
            selectedNoteID = nil
            reloadNotes()
        }
    }

    // MARK: the call is over

    private func beginCallWatch() {
        callWatch = CallWatch()
        lastSpeechAt = Date()
        stopAt = nil
        lastMicUsers = nil
        callTimer?.invalidate()
        callTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.tickCallWatch() }
    }

    private func endCallWatch() {
        callTimer?.invalidate(); callTimer = nil
        if stopAt != nil { NotificationCenter.default.post(name: Self.callOverCleared, object: self) }
        stopAt = nil
    }

    private func tickCallWatch() {
        guard let r = recorder else { return }
        if let at = stopAt, Date() >= at {
            let reason = stopReason
            NotesStore.appendEvent("[\(Self.clock(r.elapsed))] stopped by itself: \(reason)", to: r.note.id)
            Log.info("meeting: stopped by itself, \(reason)")
            stopAt = nil
            stopRecording()
            NotificationCenter.default.post(name: Self.stoppedByItself, object: self, userInfo: [
                "title": "Recording stopped", "detail": "\(reason.prefix(1).uppercased() + reason.dropFirst()). The note is saved and its transcript is being rebuilt."])
            return
        }
        guard !micQueryRunning else { return }
        micQueryRunning = true
        let quiet = Date().timeIntervalSince(lastSpeechAt)
        let now = ProcessInfo.processInfo.systemUptime
        callQueue.async { [weak self] in
            let users = CallWatch.micUsers()
            DispatchQueue.main.async {
                guard let self else { return }
                self.micQueryRunning = false
                guard let current = self.recorder, current === r else { return }
                self.logMicUsers(users, r)
                _ = self.callOffer.observe(at: now, micUsers: users, recording: true)
                for event in self.callWatch.observe(at: now, micUsers: users, quietFor: quiet) { self.handle(event, r) }
            }
        }
    }

    /// One line whenever the set of processes on the microphone changes, each with the call app it
    /// counts as, to the app log and, while a note records, to its events.log.
    private func logMicUsers(_ users: [String], _ r: MeetingRecorder?) {
        let now = Array(Set(users)).sorted()
        guard now != lastMicUsers else { return }
        lastMicUsers = now
        let list = now.isEmpty ? "nothing" : now.map { "\($0) (\(CallWatch.callAppName($0) ?? "not a call app"))" }.joined(separator: ", ")
        Log.info("meeting: on the microphone: \(list)")
        if let r { NotesStore.appendEvent("[\(Self.clock(r.elapsed))] on the microphone: \(list)", to: r.note.id) }
    }

    private func handle(_ event: CallWatch.Event, _ r: MeetingRecorder) {
        switch event {
        case .callEnded(let name):
            countDown(60, reason: "\(name) let go of the microphone, so the call looks over", r,
                      title: "The call looks over", detail: "\(name) stopped using the microphone.")
        case .longSilence(let minutes):
            countDown(120, reason: "nobody spoke for \(minutes) minutes", r,
                      title: "Nobody has spoken for \(minutes) minutes", detail: "The meeting may be over.")
        case .callBack, .speechBack:
            guard stopAt != nil else { return }
            let why = event == .callBack ? "the call took the microphone again" : "someone spoke"
            NotesStore.appendEvent("[\(Self.clock(r.elapsed))] kept recording: \(why)", to: r.note.id)
            Log.info("meeting: kept recording, \(why)")
            stopAt = nil
            NotificationCenter.default.post(name: Self.callOverCleared, object: self)
        }
    }

    private func countDown(_ seconds: TimeInterval, reason: String, _ r: MeetingRecorder, title: String, detail: String) {
        let at = Date().addingTimeInterval(seconds)
        if let earlier = stopAt, earlier < at { return }
        stopAt = at
        stopReason = reason
        let time = DateFormatter.localizedString(from: at, dateStyle: .none, timeStyle: .short)
        NotesStore.appendEvent("[\(Self.clock(r.elapsed))] \(reason): stopping at \(time) unless John keeps it going", to: r.note.id)
        Log.info("meeting: \(reason), stopping in \(Int(seconds)) s")
        NotificationCenter.default.post(name: Self.callOver, object: self, userInfo: [
            "title": title, "detail": "\(detail) Recording stops at \(time). Click to keep recording.", "seconds": seconds])
    }

    /// The toast's click: this call or this silence will not stop the note. A new one still can.
    func keepRecording() {
        guard let r = recorder, stopAt != nil else { return }
        stopAt = nil
        NotesStore.appendEvent("[\(Self.clock(r.elapsed))] kept recording: John clicked", to: r.note.id)
        Log.info("meeting: kept recording, John clicked")
    }

    private static func clock(_ seconds: TimeInterval) -> String {
        let s = Int(seconds)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: running notes

    /// Starts the once-a-minute pass over what has been said since the last one. Anything
    /// already in the transcript (a note being recorded a second time) counts as noted.
    private func beginRunningNotes(for id: String) {
        runningNotesStatus = nil
        guard Settings.shared.runningNotes else { return }
        let (summarizer, why) = SummarizerFactory.best()
        guard summarizer != nil else {
            runningNotesStatus = why.map { "Running notes are off: \($0)" }
            Log.info("running notes unavailable: \(why ?? "no summarizer")")
            return
        }
        runningNotesNoteID = id
        notedSegmentIDs = Set(NotesStore.transcript(id).map(\.id))
        lastNotesPassAt = Date()
        runningNotesTimer?.invalidate()
        runningNotesTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in self?.tickRunningNotes() }
    }

    private func tickRunningNotes() {
        guard let id = runningNotesNoteID, recorder?.note.id == id, !takingNotes, !summarizing else { return }
        let fresh = RunningNotes.window(NotesStore.transcript(id), processed: notedSegmentIDs)
        guard RunningNotes.isDue(newWords: RunningNotes.wordCount(fresh), sinceLast: Date().timeIntervalSince(lastNotesPassAt), final: false) else { return }
        takeRunningNotes(for: id, final: false)
    }

    /// One pass: the newest unnoted stretch and the last few bullets go to the model, whatever
    /// comes back is stamped and appended to running-notes.md. `final` drains the backlog after
    /// the meeting ends, in as many passes as it takes.
    private func takeRunningNotes(for id: String, final: Bool, completion: (() -> Void)? = nil) {
        guard !takingNotes else { completion?(); return }
        let (summarizer, _) = SummarizerFactory.best()
        guard let summarizer else { completion?(); return }
        let title = NotesStore.load(id)?.title ?? "Meeting"
        takingNotes = true
        Task { @MainActor [weak self] in
            defer { self?.takingNotes = false; completion?() }
            var passes = 0
            while let self, passes < (final ? 6 : 1) {
                let fresh = RunningNotes.window(NotesStore.transcript(id), processed: self.notedSegmentIDs)
                let words = RunningNotes.wordCount(fresh)
                guard !fresh.isEmpty, final ? words >= RunningNotes.finalMinimumWords : true else { break }
                passes += 1
                let previous = RunningNotes.recent(NotesStore.runningNotes(id))
                let t0 = Date()
                do {
                    let bullets = try await summarizer.runningNotes(previous: previous, transcript: NotesStore.transcriptText(fresh), title: title)
                    self.notedSegmentIDs.formUnion(fresh.map(\.id))
                    self.lastNotesPassAt = Date()
                    let block = RunningNotes.format(bullets, at: fresh[0].start)
                    NotesStore.appendRunningNotes(block, to: id)
                    if self.selectedNoteID == id { self.runningNotes += block }
                    Log.info(String(format: "running notes: %d words in, %d bullet(s) out, %.1f s%@", words, bullets.count, Date().timeIntervalSince(t0), final ? " (final)" : ""))
                } catch {
                    // Leave the stretch unnoted; the next pass picks it up with what follows.
                    Log.error("running notes: \(error.localizedDescription)")
                    self.lastNotesPassAt = Date()
                    break
                }
            }
        }
    }

    /// The last pass, then `completion`, which starts re-transcription. The order matters: the
    /// two once ran together, and the rebuilt segments, which carry new ids, were noted twice.
    private func endRunningNotes(for id: String, completion: @escaping () -> Void) {
        runningNotesTimer?.invalidate(); runningNotesTimer = nil
        guard runningNotesNoteID == id else { completion(); return }
        runningNotesNoteID = nil
        takeRunningNotes(for: id, final: true, completion: completion)
    }

    func stopRecording() {
        guard let r = recorder else { return }
        elapsedTimer?.invalidate(); elapsedTimer = nil
        endCallWatch()
        r.stop { [weak self] in
            guard let self else { return }
            self.reloadNotes()
            if self.selectedNoteID == r.note.id { self.elapsed = r.note.durationSeconds }
            // The last running-notes pass reads the live transcript; only then is the transcript
            // rebuilt from the audio, or its new segments would read as unnoted and be noted again.
            self.endRunningNotes(for: r.note.id) { [weak self] in
                guard let self, Settings.shared.keepMeetingAudio, Settings.shared.transcribeAfterMeeting, NotesStore.hasAudio(r.note.id) else { return }
                self.transcribeFromAudio(r.note.id)
            }
        }
        recorder = nil
        isRecording = false
        micLevel = 0; systemLevel = 0
    }

    func meetingRecorder(_ recorder: MeetingRecorder, didAdd segment: TranscriptSegment) {
        lastSpeechAt = Date()
        guard recorder.note.id == selectedNoteID else { return }
        segments.append(segment)
        segments.sort { $0.start < $1.start }
    }

    func meetingRecorder(_ recorder: MeetingRecorder, micLevel: Float, systemLevel: Float) {
        self.micLevel = micLevel; self.systemLevel = systemLevel
    }

    func meetingRecorder(_ recorder: MeetingRecorder, didFail error: Error) {
        errorMessage = error.localizedDescription
    }

    // MARK: transcript from the saved audio

    func hasAudio(_ id: String) -> Bool { NotesStore.hasAudio(id) }

    /// Rewrites a note's transcript from its saved audio, one note at a time, on a background
    /// queue. Runs on its own after every meeting; the menu offers it again for any note with
    /// audio, which is how a better model later improves an old meeting.
    func transcribeFromAudio(_ id: String? = nil) {
        guard let id = id ?? selectedNoteID else { return }
        if recorder?.note.id == id { errorMessage = "Stop the recording first."; return }
        guard NotesStore.hasAudio(id) else { errorMessage = "This meeting has no saved audio to transcribe."; return }
        if transcribing {
            if transcribingNoteID != id, !transcribeQueue.contains(id) { transcribeQueue.append(id) }
            return
        }
        transcribing = true
        transcribingNoteID = id
        transcribeWaits = 0
        runTranscribe(id)
    }

    private func runTranscribe(_ id: String) {
        guard let engine = controller.engine else {
            // The model loads for a few seconds after launch; a recovered note waits for it.
            transcribeWaits += 1
            transcribeProgress = "Waiting for the speech model…"
            if transcribeWaits > 90 { finishTranscribe(id, error: NSError(domain: "LinFlow.Notes", code: 4, userInfo: [NSLocalizedDescriptionKey: "The speech model did not load, so the transcript was not rebuilt from the audio."])); return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.transcribing, self.transcribingNoteID == id else { return }
                self.runTranscribe(id)
            }
            return
        }
        transcribeProgress = "Reading the recording…"
        let options = controller.currentOptions()
        let glossary = controller.glossary
        let t0 = Date()
        transcribeWork.async { [weak self] in
            do {
                var voiceLine: String?
                let segments = try NoteTranscriber.transcribe(noteID: id, engine: engine, options: options, glossary: glossary, progress: { p in
                    DispatchQueue.main.async { self?.transcribeProgress = p }
                }, voices: { voiceLine = $0 })
                if let voiceLine { NotesStore.appendEvent(voiceLine, to: id) }
                NotesStore.replaceTranscript(segments, for: id, model: engine.displayName)
                Log.info(String(format: "notes: %@ transcribed from audio: %d segments in %.1f s", id, segments.count, Date().timeIntervalSince(t0)))
                DispatchQueue.main.async { self?.finishTranscribe(id, error: nil) }
            } catch {
                Log.error("notes: transcribing \(id) from audio: \(error.localizedDescription)")
                DispatchQueue.main.async { self?.finishTranscribe(id, error: error) }
            }
        }
    }

    private func finishTranscribe(_ id: String, error: Error?) {
        transcribing = false
        transcribingNoteID = nil
        transcribeProgress = ""
        if let error { errorMessage = error.localizedDescription }
        if selectedNoteID == id { segments = NotesStore.transcript(id) }
        reloadNotes()
        if !transcribeQueue.isEmpty { transcribeFromAudio(transcribeQueue.removeFirst()) }
    }

    var elapsedLabel: String {
        let s = Int(elapsed)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    func summarize() { runSummary(kind: .meeting, segments: segments) }

    /// Sends one question about the selected note to Claude, with the transcript so far, John's
    /// notes and the questions before it. The answer is saved with the note.
    func ask(_ question: String) {
        let q = question.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !asking, let note = selectedNote else { return }
        guard let client = ClaudeClient() else { errorMessage = ClaudeClient.Failure.noKey.localizedDescription; return }
        asking = true
        errorMessage = nil
        let noteID = note.id
        let prompt = MeetingQuestions.prompt(title: note.title, transcript: NotesStore.transcriptText(segments),
                                             notes: notesText, earlier: questions, question: q)
        Task { @MainActor [weak self] in
            do {
                let answer = try await client.ask(system: MeetingQuestions.system, user: prompt)
                var turns = MeetingQuestions.load(noteID)
                turns.append(MeetingQuestions.Turn(question: q, answer: answer))
                MeetingQuestions.save(turns, for: noteID)
                if self?.selectedNoteID == noteID { self?.questions = turns }
            } catch {
                Log.error("ask: \(error.localizedDescription)")
                self?.errorMessage = error.localizedDescription
            }
            self?.asking = false
        }
    }

    func recap(lastMinutes: Double = 5) {
        let latest = segments.last?.end ?? 0
        let cutoff = latest - lastMinutes * 60
        runSummary(kind: .recap, segments: segments.filter { $0.end >= cutoff }, minutes: lastMinutes)
    }

    private func runSummary(kind: SummaryKind, segments: [TranscriptSegment], minutes: Double = 0) {
        guard !summarizing, let note = selectedNote else { return }
        let (summarizer, why) = SummarizerFactory.forSummaries()
        guard let summarizer else { errorMessage = why; return }
        guard !segments.isEmpty else { errorMessage = "Nothing to summarize yet."; return }
        summarizing = true
        summaryProgress = "Starting…"
        errorMessage = nil
        let transcript = NotesStore.transcriptText(segments)
        let title = note.title
        let noteID = note.id
        Task { @MainActor [weak self] in
            do {
                let text = try await summarizer.summarize(transcript: transcript, title: title, kind: kind) { p in
                    DispatchQueue.main.async { self?.summaryProgress = p }
                }
                guard let self else { return }
                if kind == .meeting {
                    NotesStore.saveSummary(text, for: noteID)
                    if var n = NotesStore.load(noteID) { n.summaryModel = summarizer.name; NotesStore.save(n) }
                }
                // Only paint the result if that note is still the one on screen.
                if self.selectedNoteID == noteID {
                    if kind == .recap {
                        let previous = self.summary.hasPrefix("**Recap") ? "" : self.summary
                        self.summary = "**Recap of the last \(Int(minutes)) minutes**\n\n\(text)" + (previous.isEmpty ? "" : "\n\n---\n\n" + previous)
                    } else {
                        self.summary = text
                    }
                }
                self.summarizing = false
                self.summaryProgress = ""
            } catch {
                self?.errorMessage = error.localizedDescription
                self?.summarizing = false
                self?.summaryProgress = ""
            }
        }
    }

    /// Write anything still debounced and close an open meeting cleanly. Called on quit,
    /// on the main thread; pumps the run loop until the recorder has flushed its files.
    func prepareForQuit() {
        flushPendingNotesSave()
        guard let r = recorder else { return }
        elapsedTimer?.invalidate(); elapsedTimer = nil
        runningNotesTimer?.invalidate(); runningNotesTimer = nil   // no final pass on quit: the audio and the transcript are saved
        let done = DispatchSemaphore(value: 0)
        r.stop { done.signal() }
        recorder = nil
        isRecording = false
        let deadline = Date().addingTimeInterval(8)
        while done.wait(timeout: .now()) == .timedOut, Date() < deadline {
            RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        }
    }

    func copyMarkdown() {
        guard let note = selectedNote else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(NotesStore.markdown(for: note), forType: .string)
    }

    func saveMarkdown() {
        guard let note = selectedNote else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = NotesStore.fileName(note.title, ext: "md")
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            try? NotesStore.markdown(for: note).write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// MP3, or AAC on a Mac without LAME.
    var audioFormat: AudioExport.Format { AudioExport.preferredFormat }

    /// Both sides of the meeting as one file, wherever John picks, then shown in Finder.
    func saveAudio() {
        guard let note = selectedNote else { return }
        if recorder?.note.id == note.id { errorMessage = "Stop the recording first."; return }
        guard NotesStore.hasAudio(note.id) else { errorMessage = "This meeting has no saved audio."; return }
        guard exportingNoteID == nil else { return }
        let format = audioFormat
        let panel = NSSavePanel()
        panel.allowedContentTypes = [format == .mp3 ? .mp3 : .mpeg4Audio]
        panel.nameFieldStringValue = NotesStore.fileName(note.title, ext: format.rawValue)
        panel.canCreateDirectories = true
        panel.begin { [weak self] response in
            guard response == .OK, let url = panel.url, let self, self.exportingNoteID == nil else { return }
            self.exportingNoteID = note.id
            self.exportProgress = 0
            let t0 = Date()
            self.exportWork.async {
                do {
                    let r = try AudioExport.export(noteID: note.id, title: note.title, to: url, format: format) { p in
                        DispatchQueue.main.async { self.exportProgress = p }
                    }
                    let size = ((try? FileManager.default.attributesOfItem(atPath: url.path)[.size]) as? Int) ?? 0
                    Log.info(String(format: "notes: %@ audio saved as %@, %.0f s, %.1f MB, mic %+.1f dB, system %@, %@, in %.1f s",
                                    note.id, format.rawValue, r.seconds, Double(size) / 1e6, r.gains["mic"] ?? 0,
                                    r.gains["system"].map { String(format: "%+.1f dB", $0) } ?? "left out", r.coupling.rawValue,
                                    Date().timeIntervalSince(t0)))
                    DispatchQueue.main.async {
                        self.exportingNoteID = nil
                        if var n = NotesStore.load(note.id) {
                            n.audioExports = (n.audioExports ?? []).filter { $0.path != url.path } + [AudioExportRecord(path: url.path, title: note.title)]
                            NotesStore.save(n)
                            if n.title != note.title { self.followTitle(n.id) }   // renamed while it saved
                        }
                        NSWorkspace.shared.activateFileViewerSelecting([url])
                    }
                } catch {
                    Log.error("notes: saving the audio of \(note.id): \(error.localizedDescription)")
                    DispatchQueue.main.async {
                        self.exportingNoteID = nil
                        self.errorMessage = "The audio was not saved: \(error.localizedDescription)"
                    }
                }
            }
        }
    }

    func revealNoteFolder() {
        guard let id = selectedNoteID else { return }
        NSWorkspace.shared.activateFileViewerSelecting([NotesStore.folder(for: id)])
    }

    // MARK: - Settings bindings

    func settingChanged() {
        objectWillChange.send()
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
}
