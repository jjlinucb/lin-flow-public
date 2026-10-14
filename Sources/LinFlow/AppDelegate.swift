import AppKit
import LinFlowCore
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate, DictationControllerDelegate {
    private let controller = DictationController()
    private var statusItem: NSStatusItem!
    private let menu = NSMenu()
    private var hud: HUDPanel?
    private var activity: NSObjectProtocol?
    private var lastEntry: HistoryEntry?
    private var state: DictationState = .loading("model")
    private var signalSources: [DispatchSourceSignal] = []
    private lazy var dashboardModel = DashboardModel(controller: controller)
    private lazy var dashboard = DashboardWindowController(model: dashboardModel)
    private var settingsObserver: NSObjectProtocol?
    private var learnObserver: NSObjectProtocol?
    private var declineObserver: NSObjectProtocol?
    private var silenceObserver: NSObjectProtocol?
    private var stuckObserver: NSObjectProtocol?
    private var totalsObserver: NSObjectProtocol?
    private var dictionaryObservers: [NSObjectProtocol] = []
    private var dictionaryTimer: Timer?
    private var toast: ToastPanel?
    private var isolationObserver: NSObjectProtocol?
    private var loudRoomObserver: NSObjectProtocol?
    private var callObservers: [NSObjectProtocol] = []
    /// Whether the toast up now is the call-over one, so clearing it never hides another.
    private var callToastUp = false

    private var runningFromBundle: Bool { Bundle.main.bundleURL.pathExtension == "app" }

    // MARK: launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        Log.setupFile()
        Log.info("starting pid \(getpid()) as \(Bundle.main.bundleIdentifier ?? "bare executable"), whisper.cpp \(WhisperEngine.libraryVersion)")
        Log.info(MicMode.summary)
        applyActivationPolicy()
        installMainMenu()
        // App Nap would throttle the hotkey's thread and every timer, so hold an activity for
        // the app's whole life -- the kind that still lets the Mac idle-sleep. `.userInitiated`
        // also disables idle sleep, and with it Lin Flow kept the Mac awake for as long as it
        // ran: 28 hours at a stretch in `pmset -g assertions`. A meeting holds its own while it records.
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep, reason: "Lin Flow dictation")

        menu.delegate = self
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.menu = menu
        statusItem.button?.toolTip = "Lin Flow"
        applyStatusIcon()

        if Settings.shared.showHUD { showHUD() }

        controller.delegate = self
        if !HotkeyMonitor.checkAccessibility(prompt: true) {
            Log.info("accessibility not granted yet; the system prompt should be up")
        }
        installSignalHandlers()
        settingsObserver = NotificationCenter.default.addObserver(forName: Settings.didChange, object: nil, queue: .main) { [weak self] _ in
            self?.applySettings()
        }
        learnObserver = NotificationCenter.default.addObserver(forName: CorrectionLearning.didLearn, object: nil, queue: .main) { [weak self] note in
            guard let outcome = note.userInfo?["outcome"] as? CorrectionLearning.Outcome else { return }
            self?.announce(outcome)
        }
        declineObserver = NotificationCenter.default.addObserver(forName: CorrectionLearning.didDecline, object: nil, queue: .main) { [weak self] note in
            guard let from = note.userInfo?["from"] as? String,
                  let to = note.userInfo?["to"] as? String else { return }
            self?.offer(from: from, to: to)
        }
        silenceObserver = NotificationCenter.default.addObserver(forName: DictationController.microphoneSilent, object: nil, queue: .main) { [weak self] note in
            let device = note.userInfo?["device"] as? String ?? "the microphone"
            let seconds = note.userInfo?["seconds"] as? Double ?? 0
            self?.showToast("No sound from \(device)",
                            String(format: "%.1f s of pure silence, so nothing was typed. Click to check the input in Sound settings.", seconds),
                            seconds: 10, warning: true) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
            }
        }
        loudRoomObserver = NotificationCenter.default.addObserver(forName: DictationController.loudRoom, object: nil, queue: .main) { [weak self] _ in
            self?.showToast("It's loud here for the Mac's mic",
                            "Background voices are drowning out yours. AirPods or a headset will hear you much better. Click to switch the input in Sound settings.",
                            seconds: 10, warning: true) {
                if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { NSWorkspace.shared.open(url) }
            }
        }
        isolationObserver = NotificationCenter.default.addObserver(forName: MicMode.isolatingMeeting, object: nil, queue: .main) { [weak self] _ in
            self?.showToast("Voice Isolation is on for Lin Flow",
                            "It keeps only a voice close to the Mac's mic, so with AirPods in your side of the meeting is lost. Click and choose Standard.",
                            seconds: 30, warning: true) { MicMode.showSwitcher() }
        }
        callObservers = [
            NotificationCenter.default.addObserver(forName: DashboardModel.callOver, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let info = note.userInfo ?? [:]
                self.showToast(info["title"] as? String ?? "The call looks over", info["detail"] as? String ?? "",
                               seconds: info["seconds"] as? TimeInterval ?? 60, warning: true) { [weak self] in
                    self?.callToastUp = false
                    self?.dashboardModel.keepRecording()
                }
                self.callToastUp = true
            },
            NotificationCenter.default.addObserver(forName: DashboardModel.callOverCleared, object: nil, queue: .main) { [weak self] _ in
                guard let self, self.callToastUp else { return }
                self.callToastUp = false
                self.toast?.hide()
            },
            NotificationCenter.default.addObserver(forName: DashboardModel.callStarted, object: nil, queue: .main) { [weak self] note in
                guard let name = note.userInfo?["name"] as? String else { return }
                self?.offerToRecord(name)
            },
            NotificationCenter.default.addObserver(forName: DashboardModel.stoppedByItself, object: nil, queue: .main) { [weak self] note in
                let info = note.userInfo ?? [:]
                self?.showToast(info["title"] as? String ?? "Recording stopped", info["detail"] as? String ?? "", seconds: 12) {
                    self?.openDashboard(.notetaker)
                }
            },
        ]
        stuckObserver = NotificationCenter.default.addObserver(forName: DictationController.audioStuck, object: nil, queue: .main) { [weak self] _ in
            self?.showToast("The Mac's audio is stuck",
                            "Nothing on the Mac can hear the microphone. Click to restart the audio: Terminal opens and asks for your Mac password.",
                            seconds: 20, warning: true) {
                do {
                    NSWorkspace.shared.open(try AudioRepair.writeScript(in: FileManager.default.temporaryDirectory))
                } catch {
                    Log.error("audio repair: \(error.localizedDescription)")
                }
            }
        }
        controller.start()
        // The model is created now rather than with the window, so a meeting the last run
        // never stopped (crash, force quit, dead battery) is closed from what is on disk and
        // its transcript rebuilt from the audio at launch, whether or not the window opens.
        _ = dashboardModel

        let env = ProcessInfo.processInfo.environment
        // Shared word totals (TotalsSync.swift), a no-op until sync.env exists. Each saved, edited
        // or deleted dictation sends its own day, and the first push after a launch sends every
        // day, which is how a Mac set up today backfills. Not from a test instance: a test run
        // must leave no trace.
        if env["LINFLOW_TEST_AUDIO"] == nil && env["LINFLOW_NO_PASTE"] == nil {
            totalsObserver = NotificationCenter.default.addObserver(forName: History.didChange, object: nil, queue: .main) { _ in
                TotalsSync.shared.requestPush()
            }
            TotalsSync.shared.requestPush()
            // The shared dictionary (DictionarySync.swift), also a no-op until sync.env exists:
            // at launch, after each dictation, after each change to vocab.txt or replacements.txt
            // the app makes itself, and every ten minutes for hand edits and other computers.
            for name in [History.didChange, Glossary.didChange] {
                dictionaryObservers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                    DictionarySync.shared.request()
                })
            }
            dictionaryTimer = Timer.scheduledTimer(withTimeInterval: DictionarySync.interval, repeats: true) { _ in
                DictionarySync.shared.request()
            }
            DictionarySync.shared.request()
        }
        if env["LINFLOW_OPEN_DASHBOARD"] != nil || Settings.shared.openWindowAtLaunch {
            let section = DashboardModel.Section(rawValue: (env["LINFLOW_SECTION"] ?? "").capitalized)
            dashboard.show(section: section)
        }
    }

    /// Re-apply anything the Settings tab can change that lives outside the window.
    private func applySettings() {
        applyActivationPolicy()
        if Settings.shared.showHUD, hud == nil { showHUD() }
        if !Settings.shared.showHUD, let h = hud { h.rememberPosition(); h.orderOut(nil); hud = nil }
    }

    func openDashboard(_ section: DashboardModel.Section? = nil) { dashboard.show(section: section) }

    /// `kill`, logout and Ctrl+C in a dev run all become a normal quit, so
    /// the pill position is saved and the model is released like any other exit.
    private func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler { NSApp.terminate(nil) }
            source.resume()
            signalSources.append(source)
        }
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Log.info("quitting")
        hud?.rememberPosition()
        dashboardModel.prepareForQuit()   // finish an open meeting note and its files first
        controller.stop()          // tap off, mic off, model freed (waits for an in-flight dictation)
        UserDefaults.standard.synchronize()
        History.flush()
        Log.flush()
        // Homebrew's ggml Metal backend trips an assertion inside its own C++
        // static destructors when the process exits normally
        // (ggml_metal_rsets_free via __cxa_finalize), and macOS files that as a
        // crash even though we were quitting. Everything of ours is flushed and
        // freed above, so end the process without running those destructors.
        _exit(0)
    }

    /// Dock icon on: a regular app, so the Dock shows the L icon with the
    /// running dot. Off: menu-bar-only accessory (pill + mic icon still show).
    private func applyActivationPolicy() {
        NSApp.setActivationPolicy(Settings.shared.showInDock ? .regular : .accessory)
    }

    /// A regular app owns the menu bar while it's frontmost (after a Dock
    /// click, say); give it a real app menu instead of an empty one.
    private func installMainMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Lin Flow", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Open Lin Flow Window", action: #selector(openWindowAction), keyEquivalent: "o").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Lin Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Standard Edit menu so copy/paste/select-all shortcuts work inside the window.
        let editItem = NSMenuItem(); main.addItem(editItem)
        let edit = NSMenu(title: "Edit"); editItem.submenu = edit
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window"); windowItem.submenu = windowMenu
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        NSApp.mainMenu = main
    }

    /// Clicking the Dock icon: bring the window back (and the pill, if it's on).
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if hud == nil, Settings.shared.showHUD { showHUD() }
        hud?.show()
        dashboard.show()
        return false
    }

    /// Right-click on the Dock icon: the same menu as the menu bar item.
    func applicationDockMenu(_ sender: NSApplication) -> NSMenu? {
        let dock = NSMenu()
        populate(dock)
        return dock
    }

    /// Says on screen what an edit just taught Lin Flow. The window is usually shut and the
    /// dictation went into some other app, so this is the only place the rule is ever seen.
    private func announce(_ outcome: CorrectionLearning.Outcome) {
        guard let lines = LearnToast.lines(for: outcome) else { return }
        showToast(lines.title, lines.detail) { [weak self] in self?.openDashboard(.dictionary) }
    }

    /// An edit Lin Flow saw and would not learn on its own. Offering it is the whole point:
    /// a misheard name is phonetically far from what was said by definition, so the filters can
    /// never accept one, and until now those simply vanished. Clicking adds it.
    private func offer(from: String, to: String) {
        let lines = LearnToast.declined(from: from, to: to)
        // Longer than a plain notice: this one asks for a decision.
        showToast(lines.title, lines.detail, seconds: 12) { [weak self] in
            CorrectionLearning.accept(Replacement(from: from, to: to, learned: true))
            Log.info("added by hand from the toast: \(from) => \(to)")
            self?.showToast("Added: “\(from)” → “\(to)”", "Used from now on. Click to change it in the Dictionary.") {
                self?.openDashboard(.dictionary)
            }
        }
    }

    /// A call started and nothing records it. A toast already up, such as a correction to
    /// confirm or a warning, keeps its turn and the offer waits for it, up to half a minute.
    private func offerToRecord(_ name: String, tries: Int = 0) {
        guard !dashboardModel.isRecording else { return }
        if toast?.isVisible == true, tries < 6 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.offerToRecord(name, tries: tries + 1) }
            return
        }
        showToast("\(name) is using the microphone", "Looks like a call. Click to record it as a meeting note.", seconds: 20) { [weak self] in
            guard let self else { return }
            self.dashboardModel.recordCall(name)
            self.openDashboard(.notetaker)
        }
    }

    private func showToast(_ title: String, _ detail: String, seconds: TimeInterval = 6, near spot: NSRect? = nil,
                           warning: Bool = false, onClick: @escaping () -> Void) {
        callToastUp = false
        let panel = toast ?? ToastPanel()
        toast = panel
        panel.show(title: title, detail: detail, above: spot ?? hud?.frame, for: seconds, warning: warning, onClick: onClick)
    }

    private func showHUD() {
        let hud = HUDPanel(pressBegan: { [weak self] in self?.controller.pressBegan() },
                           pressEnded: { [weak self] in self?.controller.pressEnded() },
                           hide: { [weak self] in self?.hidePill() },
                           menu: { [weak self] in self?.menu ?? NSMenu() })
        hud.apply(state: state)
        hud.show()
        self.hud = hud
    }

    /// The pill's X. It used to quit the whole app in one click from a pill that sits over the
    /// menu bar, and on 09-21 Lin Flow went down twice with a clean quit, for 3 hours and then 18.
    /// Quitting is in the menu; the X only puts the pill away, and says where it went.
    private func hidePill() {
        guard let pill = hud else { return }
        let spot = pill.frame
        Settings.shared.showHUD = false
        pill.rememberPosition(); pill.orderOut(nil); hud = nil
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
        showToast("Pill hidden", "Dictation still works. Click here to bring it back, or use Show Floating Pill in the menu bar menu.",
                  near: spot) { [weak self] in
            Settings.shared.showHUD = true
            self?.showHUD()
            NotificationCenter.default.post(name: Settings.didChange, object: nil)
        }
    }

    // MARK: DictationControllerDelegate (main thread)

    func dictation(_ controller: DictationController, didChange state: DictationState) {
        self.state = state
        hud?.apply(state: state)
        applyStatusIcon()
    }

    func dictation(_ controller: DictationController, audioLevel: Float) {
        hud?.apply(level: audioLevel)
    }

    func dictation(_ controller: DictationController, didFinish entry: HistoryEntry) {
        lastEntry = entry
    }

    private func applyStatusIcon() {
        guard let button = statusItem.button else { return }
        let (symbol, tint): (String, NSColor?) = {
            switch state {
            case .loading, .downloading: return ("hourglass", nil)
            case .idle: return ("mic", nil)
            case .recording: return ("mic.fill", .systemRed)
            case .transcribing: return ("waveform", .systemOrange)
            case .rewriting: return ("wand.and.stars", .systemOrange)
            case .error: return ("exclamationmark.triangle", .systemRed)
            }
        }()
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: state.label)
        image?.isTemplate = true
        button.image = image
        button.contentTintColor = tint
    }

    // MARK: menu

    func menuNeedsUpdate(_ menu: NSMenu) { populate(menu) }

    private func populate(_ menu: NSMenu) {
        menu.removeAllItems()
        let s = Settings.shared

        menu.addItem(withTitle: "Open Lin Flow Window", action: #selector(openWindowAction), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Meeting Note", action: #selector(newMeetingNoteAction), keyEquivalent: "").target = self
        menu.addItem(.separator())
        let status = NSMenuItem(title: statusLine(), action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        let hint = NSMenuItem(title: "Hold \(s.hotkey.label) to dictate, release to paste", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if let e = lastEntry {
            let last = NSMenuItem(title: String(format: "Last: %.1fs of speech in %.2fs", e.audioSeconds, e.inferenceSeconds), action: nil, keyEquivalent: "")
            last.isEnabled = false
            menu.addItem(last)
        }
        menu.addItem(.separator())

        // Model
        let modelMenu = NSMenu()
        for url in ModelCatalog.installedModelURLs() {
            let id = ModelCatalog.idFromURL(url)
            let info = ModelCatalog.info(for: id)
            let kind = EngineFactory.kind(for: url).displayName
            let item = NSMenuItem(title: "\(kind) · \(id)" + (info.map { "  –  \($0.note)" } ?? ""), action: #selector(pickModel(_:)), keyEquivalent: "")
            item.representedObject = id
            item.target = self
            item.state = id == s.modelID ? .on : .off
            modelMenu.addItem(item)
        }
        let downloadable = ModelCatalog.known.filter { ModelCatalog.locate($0.id) == nil }
        if !downloadable.isEmpty {
            modelMenu.addItem(.separator())
            for m in downloadable {
                let item = NSMenuItem(title: "\(m.engine.displayName) · \(m.id)  –  download \(m.sizeMB) MB", action: #selector(pickModel(_:)), keyEquivalent: "")
                item.representedObject = m.id
                item.target = self
                modelMenu.addItem(item)
            }
        }
        modelMenu.addItem(.separator())
        modelMenu.addItem(withTitle: "Open Models Folder", action: #selector(openModelsFolder), keyEquivalent: "").target = self
        let modelItem = NSMenuItem(title: "Model", action: nil, keyEquivalent: "")
        modelItem.submenu = modelMenu
        menu.addItem(modelItem)

        // Hotkey
        let hotkeyMenu = NSMenu()
        for k in Hotkey.presets.contains(s.hotkey) ? Hotkey.presets : Hotkey.presets + [s.hotkey] {
            let item = NSMenuItem(title: k.label, action: #selector(pickHotkey(_:)), keyEquivalent: "")
            item.representedObject = k.rawValue
            item.target = self
            item.state = k == s.hotkey ? .on : .off
            hotkeyMenu.addItem(item)
        }
        hotkeyMenu.addItem(.separator())
        hotkeyMenu.addItem(withTitle: "Record Another Key…", action: #selector(openSettings), keyEquivalent: "").target = self
        let hotkeyItem = NSMenuItem(title: "Hold to Talk Key", action: nil, keyEquivalent: "")
        hotkeyItem.submenu = hotkeyMenu
        menu.addItem(hotkeyItem)

        // Language (Whisper multilingual models only)
        let langMenu = NSMenu()
        let languages: [(String, String)] = [("en", "English"), ("auto", "Auto-detect"), ("km", "Khmer"), ("zh", "Chinese"),
                                             ("es", "Spanish"), ("fr", "French"), ("de", "German"), ("ja", "Japanese"), ("ko", "Korean")]
        let multilingual = controller.engine?.isMultilingual ?? true
        let isWhisper = (controller.engine?.kind ?? .whisper) == .whisper
        for (code, name) in languages {
            let item = NSMenuItem(title: name, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.representedObject = code
            item.target = self
            item.state = code == s.language ? .on : .off
            item.isEnabled = multilingual && isWhisper
            langMenu.addItem(item)
        }
        let langItem = NSMenuItem(title: "Language", action: nil, keyEquivalent: "")
        langItem.submenu = langMenu
        menu.addItem(langItem)
        menu.addItem(.separator())

        // A submenu, not a toggle: the toggle turned Medium into None, and None back into Light.
        let cleanupMenu = NSMenu()
        for level in CleanupLevel.allCases {
            let item = NSMenuItem(title: level.label, action: #selector(pickCleanup(_:)), keyEquivalent: "")
            item.representedObject = level.rawValue
            item.target = self
            item.state = level == s.cleanupLevel ? .on : .off
            cleanupMenu.addItem(item)
        }
        let cleanupItem = NSMenuItem(title: "Cleanup", action: nil, keyEquivalent: "")
        cleanupItem.submenu = cleanupMenu
        menu.addItem(cleanupItem)
        addToggle(menu, "Spoken Commands (“new line”, “question mark”)", s.spokenCommands, #selector(toggleSpokenCommands))
        addToggle(menu, "Sounds", s.sounds, #selector(toggleSounds))
        addToggle(menu, "Show Floating Pill", s.showHUD, #selector(toggleHUD))
        addToggle(menu, "Show in Dock", s.showInDock, #selector(toggleDock))
        if runningFromBundle {
            addToggle(menu, "Launch at Login", SMAppService.mainApp.status == .enabled, #selector(toggleLaunchAtLogin))
        }
        menu.addItem(.separator())

        // Recent dictations
        let recent = History.recent(10)
        let recentMenu = NSMenu()
        if recent.isEmpty {
            let none = NSMenuItem(title: "No dictations yet", action: nil, keyEquivalent: ""); none.isEnabled = false
            recentMenu.addItem(none)
        }
        for e in recent {
            var title = e.text.replacingOccurrences(of: "\n", with: " ")
            if title.count > 70 { title = String(title.prefix(70)) + "…" }
            let item = NSMenuItem(title: title, action: #selector(copyEntry(_:)), keyEquivalent: "")
            item.representedObject = e.text
            item.target = self
            item.toolTip = "Click to copy"
            recentMenu.addItem(item)
        }
        let recentItem = NSMenuItem(title: "Recent Dictations (click to copy)", action: nil, keyEquivalent: "")
        recentItem.submenu = recentMenu
        menu.addItem(recentItem)
        menu.addItem(withTitle: "Dictionary…", action: #selector(openDictionary), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Log", action: #selector(openLog), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Lin Flow", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }

    private func statusLine() -> String {
        switch state {
        case .idle:
            if let e = controller.engine { return "Ready · \(e.displayName)" }
            return "Ready"
        default:
            return state.label
        }
    }

    private func addToggle(_ menu: NSMenu, _ title: String, _ on: Bool, _ action: Selector) {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.state = on ? .on : .off
        menu.addItem(item)
    }

    // MARK: actions

    @objc private func openWindowAction() { dashboard.show() }

    @objc private func newMeetingNoteAction() {
        dashboard.show(section: .notetaker)
        dashboardModel.newNote()
    }

    @objc private func pickModel(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String else { return }
        controller.loadModel(id: id)
    }

    @objc private func pickHotkey(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let k = Hotkey(rawValue: raw) else { return }
        controller.setHotkey(k)
    }

    @objc private func pickLanguage(_ sender: NSMenuItem) {
        guard let code = sender.representedObject as? String else { return }
        Settings.shared.language = code
    }

    @objc private func pickCleanup(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let level = CleanupLevel(rawValue: raw) else { return }
        Settings.shared.cleanupLevel = level
        NotificationCenter.default.post(name: Settings.didChange, object: nil)
    }
    @objc private func toggleSpokenCommands() { Settings.shared.spokenCommands.toggle() }
    @objc private func toggleSounds() { Settings.shared.sounds.toggle() }

    @objc private func toggleDock() {
        Settings.shared.showInDock.toggle()
        applyActivationPolicy()
    }

    @objc private func toggleHUD() {
        Settings.shared.showHUD.toggle()
        if Settings.shared.showHUD { showHUD() } else { hud?.rememberPosition(); hud?.orderOut(nil); hud = nil }
    }

    @objc private func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch {
            Log.error("launch at login: \(error.localizedDescription)")
        }
    }

    @objc private func copyEntry(_ sender: NSMenuItem) {
        guard let text = sender.representedObject as? String else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    @objc private func openModelsFolder() {
        try? FileManager.default.createDirectory(at: ModelCatalog.modelsDir, withIntermediateDirectories: true)
        NSWorkspace.shared.open(ModelCatalog.modelsDir)
    }

    @objc private func openDictionary() { dashboard.show(section: .dictionary) }

    @objc private func openSettings() { dashboard.show(section: .settings) }

    @objc private func openLog() { NSWorkspace.shared.open(Log.defaultFileURL) }
}
