import AVFoundation
import CoreAudio
import Foundation

public protocol MeetingRecorderDelegate: AnyObject {
    func meetingRecorder(_ recorder: MeetingRecorder, didAdd segment: TranscriptSegment)
    func meetingRecorder(_ recorder: MeetingRecorder, micLevel: Float, systemLevel: Float)
    func meetingRecorder(_ recorder: MeetingRecorder, didFail error: Error)
}

/// One meeting: microphone (you) and system audio (everyone else) captured side by side,
/// each streamed through its own LiveTranscriber, segments written to the note as they
/// arrive, audio kept as WAV. Everything the delegate hears is on the main thread.
///
/// The recording is the product and the live transcript is a view of it, so:
/// - audio goes to disk as it arrives through a `WAVWriter` whose header stays valid, so a
///   crash costs at most the last second instead of the whole meeting;
/// - each track is kept on the note's clock: a slow start, a stall or a device switch is
///   filled with silence, so "You" and "Others" line up to the half second in any editor
///   and in the transcript;
/// - a source that stops delivering is restarted (the mic when the input device changes,
///   the tap when the output device changes, either when nothing has arrived for 3 s), and
///   one failing source never takes the other down with it;
/// - a second session on the same note appends to its audio instead of overwriting it.
/// Every gap, restart and failure is also written to the note's events.log.
public final class MeetingRecorder {
    public weak var delegate: MeetingRecorderDelegate?
    public private(set) var note: MeetingNote
    public private(set) var isRecording = false
    /// Zero of the note's clock: this session's start, minus whatever was recorded before.
    public private(set) var startedAt: Date?

    /// A source is stale when nothing has arrived for this long.
    public var staleAfter: TimeInterval = 3

    public enum Source: String { case mic, system }

    private final class Track {
        let source: Source
        let transcriber: LiveTranscriber
        var writer: WAVWriter?
        var wanted = false
        var lastChunkAt: Date?
        var sawFirstChunk = false
        var fedThisSession = 0
        var restartAt: Date?
        var restartReason = ""
        var lastRestartAt: Date?
        var backoff: TimeInterval = 2
        var failing = false
        var writeFailing = false
        init(_ source: Source, _ transcriber: LiveTranscriber) { self.source = source; self.transcriber = transcriber }
    }

    private var mic = Recorder()
    /// Microphones whose start or stop never returned, kept alive so a late return is harmless.
    private var hungMics: [Recorder] = []
    private var systemTap: SystemAudioTap?
    private let tracks: [Source: Track]
    /// All per-track state, file writes and restarts happen here, in order.
    private let ioQueue = DispatchQueue(label: "linflow.meeting.io", qos: .userInitiated)
    private var micLevel: Float = 0
    private var systemLevel: Float = 0
    private var levelTimer: DispatchSourceTimer?
    private var watchdog: DispatchSourceTimer?
    private var clockStart = Date()
    private var sessionStart = Date()
    private var deviceListener: AudioObjectPropertyListenerBlock?
    /// Keeps the Mac from idle-sleeping mid-meeting, for exactly as long as it records.
    private var awake: NSObjectProtocol?
    private static let deviceSelectors: [AudioObjectPropertySelector] = [kAudioHardwarePropertyDefaultSystemOutputDevice, kAudioHardwarePropertyDefaultOutputDevice]

    public init(note: MeetingNote, engine: @escaping () -> SpeechEngine?, options: @escaping () -> TranscriptionOptions, glossary: [String]) {
        self.note = note
        tracks = [
            .mic: Track(.mic, LiveTranscriber(speaker: "You", engine: engine, options: options, glossary: glossary)),
            .system: Track(.system, LiveTranscriber(speaker: "Others", engine: engine, options: options, glossary: glossary)),
        ]
        wire(mic)
    }

    private func wire(_ r: Recorder) {
        r.keepsSamples = false
        r.onLevel = { [weak self] l in self?.micLevel = max(l, (self?.micLevel ?? 0) * 0.8) }
        r.onChunk = { [weak self] chunk in self?.receive(chunk, .mic) }
        r.onConfigurationChange = { [weak self] in self?.scheduleRestart(.mic, reason: "the input device changed", after: 0.5) }
    }

    private static func unwire(_ r: Recorder) {
        r.onChunk = nil; r.onLevel = nil; r.onConfigurationChange = nil
    }

    public var elapsed: TimeInterval { startedAt.map { Date().timeIntervalSince($0) } ?? note.durationSeconds }

    /// Starts every source asked for. Throws only if none of them could start; a source that
    /// fails while the other works is reported to the delegate and retried by the watchdog.
    public func start(useMicrophone: Bool, useSystemAudio: Bool, keepAudio: Bool) throws {
        guard !isRecording else { return }
        guard useMicrophone || useSystemAudio else { return }
        // Re-read the note first: the window may have renamed it since we were handed a copy,
        // and its duration is where the clock resumes if it was recorded before.
        note = NotesStore.load(note.id) ?? note
        let noteID = note.id
        let previous = max(0, note.durationSeconds)
        sessionStart = Date()
        clockStart = sessionStart.addingTimeInterval(-previous)
        startedAt = clockStart
        for t in tracks.values {
            t.transcriber.timeOffset = previous
            t.transcriber.onSegment = { [weak self] segment in
                guard let self else { return }
                NotesStore.appendSegment(segment, to: noteID)
                self.delegate?.meetingRecorder(self, didAdd: segment)
            }
        }
        if keepAudio {
            try FileManager.default.createDirectory(at: NotesStore.folder(for: noteID), withIntermediateDirectories: true)
            checkFreeSpace()
        }
        isRecording = true   // before the sources start, or their first chunks are dropped
        var started: [Source] = [], failed: [(Source, Error)] = []
        ioQueue.sync {
            for source in [Source.system, .mic] where source == .system ? useSystemAudio : useMicrophone {
                let track = tracks[source]!
                track.wanted = true
                if keepAudio {
                    do { track.writer = try WAVWriter(url: NotesStore.audioURL(noteID, source: source.rawValue), append: true) }
                    catch { Log.error("meeting: could not open \(source.rawValue) audio file: \(error.localizedDescription)"); failed.append((source, error)) }
                }
                do { try startSource(source); started.append(source) }
                catch { failed.append((source, error)); track.restartAt = Date().addingTimeInterval(track.backoff); track.restartReason = "retrying after: \(error.localizedDescription)" }
            }
        }
        if started.isEmpty {
            isRecording = false
            ioQueue.sync { stopSources(); closeWriters() }
            throw failed.first?.1 ?? RecorderError.noInputDevice
        }
        awake = ProcessInfo.processInfo.beginActivity(options: .userInitiated, reason: "Lin Flow is recording a meeting")
        note.usedMicrophone = useMicrophone
        note.usedSystemAudio = useSystemAudio
        NotesStore.save(note)
        NotesStore.appendEvent(previous > 0 ? "recording resumed at \(Int(previous)) s (mic=\(useMicrophone), system=\(useSystemAudio))"
                                            : "recording started (mic=\(useMicrophone), system=\(useSystemAudio), audio kept=\(keepAudio))", to: noteID)
        for (source, error) in failed { report(tracks[source]!, error) }
        if useMicrophone {
            // Voice Isolation cut John's side of the 10-06 Teams note to 55 words (MicMode).
            NotesStore.appendEvent(MicMode.summary, to: noteID)
            if MicMode.isolating {
                DispatchQueue.main.async { NotificationCenter.default.post(name: MicMode.isolatingMeeting, object: self) }
            }
        }

        installDeviceListener()
        let timer = DispatchSource.makeTimerSource(queue: .main)
        timer.schedule(deadline: .now() + 0.1, repeating: 0.1)
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            self.delegate?.meetingRecorder(self, micLevel: self.micLevel, systemLevel: self.systemLevel)
        }
        timer.resume()
        levelTimer = timer
        let dog = DispatchSource.makeTimerSource(queue: ioQueue)
        dog.schedule(deadline: .now() + 1, repeating: 1)
        dog.setEventHandler { [weak self] in self?.tick() }
        dog.resume()
        watchdog = dog
        Log.info("meeting note \(noteID) recording (mic=\(useMicrophone), system=\(useSystemAudio), resumed at \(Int(previous)) s)")
    }

    /// Stops capture, flushes the last segments, finalizes files and metadata.
    public func stop(completion: (() -> Void)? = nil) {
        guard isRecording else { completion?(); return }
        isRecording = false
        if let awake { ProcessInfo.processInfo.endActivity(awake); self.awake = nil }
        levelTimer?.cancel(); levelTimer = nil
        watchdog?.cancel(); watchdog = nil
        removeDeviceListener()
        ioQueue.sync { stopSources() }   // every chunk already queued is written before this returns
        var current = NotesStore.load(note.id) ?? note   // keep a title typed during the meeting
        current.endedAt = Date()
        current.durationSeconds = startedAt.map { Date().timeIntervalSince($0) } ?? 0
        note = current
        NotesStore.save(note)
        NotesStore.appendEvent("recording stopped at \(Int(note.durationSeconds)) s", to: note.id)
        let group = DispatchGroup()
        for t in tracks.values { group.enter(); t.transcriber.finish { group.leave() } }
        group.notify(queue: .main) { [weak self] in
            guard let self else { completion?(); return }
            self.ioQueue.sync { self.closeWriters() }
            Log.info("meeting note stopped after \(Int(self.note.durationSeconds))s")
            completion?()
        }
    }

    // MARK: sources (ioQueue)

    private func startSource(_ source: Source) throws {
        switch source {
        case .mic:
            try startMic()
        case .system:
            systemTap?.stop()
            let tap = SystemAudioTap()
            tap.onLevel = { [weak self] l in self?.systemLevel = max(l, (self?.systemLevel ?? 0) * 0.8) }
            tap.onChunk = { [weak self] chunk in self?.receive(chunk, .system) }
            try tap.start()
            systemTap = tap
        }
    }

    /// On 10-07 three device switches in 16 s, as AirPods came out, left AVAudioEngine hung
    /// inside the HAL. That call ran on this queue, so the whole recorder froze: no audio written,
    /// no watchdog, no log, for seven minutes until the lid closed. The microphone is now started
    /// and stopped off this queue, and one that hangs costs a Recorder, never the meeting.
    private func startMic() throws {
        final class Outcome { var error: Error?; var abandoned = false }
        let r = mic, outcome = Outcome(), done = DispatchSemaphore(value: 0)
        let lock = NSLock()
        DispatchQueue.global(qos: .userInitiated).async {
            var failure: Error?
            do { try r.start() } catch { failure = error }
            lock.lock(); outcome.error = failure; let late = outcome.abandoned; lock.unlock()
            if late, failure == nil { _ = r.stop() }
            done.signal()
        }
        guard done.wait(timeout: .now() + 4) == .success else {
            lock.lock(); outcome.abandoned = true; lock.unlock()
            Self.unwire(r)
            hungMics.append(r)
            mic = Recorder()
            wire(mic)
            Log.error("meeting: the microphone did not start within 4 s; it is left behind and a fresh one is tried later")
            throw NSError(domain: "LinFlow.Meeting", code: 4, userInfo: [NSLocalizedDescriptionKey: "the microphone did not start within 4 s"])
        }
        lock.lock(); let failure = outcome.error; lock.unlock()
        if let failure { throw failure }
    }

    /// Swaps in a fresh microphone and stops the old one off this queue, without waiting.
    private func retireMic() {
        let old = mic
        Self.unwire(old)
        mic = Recorder()
        wire(mic)
        guard old.isRecording else { return }
        DispatchQueue.global(qos: .userInitiated).async { _ = old.stop() }
    }

    private func stopSources() {
        retireMic()
        systemTap?.stop(); systemTap = nil
        for t in tracks.values { t.wanted = false }
    }

    private func closeWriters() {
        for t in tracks.values {
            if let w = t.writer {
                do { try w.close() } catch { Log.error("meeting: closing \(t.source.rawValue) audio: \(error.localizedDescription)") }
                t.writer = nil
            }
        }
    }

    private func receive(_ chunk: [Float], _ source: Source) {
        let now = Date()
        ioQueue.async { [weak self] in self?.handle(chunk, source, at: now) }
    }

    /// Zeros to insert before a chunk so the track catches up with the clock. Normal delivery
    /// jitter is tens of milliseconds and must never pad; the first chunk of a session is pure
    /// start-up latency, so it aligns more tightly.
    public static func shortfall(expected: Int, have: Int, first: Bool) -> Int {
        let threshold = Int((first ? 0.1 : 0.5) * AudioIO.sampleRate)
        let deficit = expected - have
        return deficit > threshold ? deficit : 0
    }

    private func handle(_ chunk: [Float], _ source: Source, at now: Date) {
        guard isRecording, let track = tracks[source], track.wanted else { return }
        if let r = track.lastRestartAt, now.timeIntervalSince(r) > 30 { track.backoff = 2 }
        if track.failing { track.failing = false; Log.info("meeting: \(source.rawValue) audio is back") ; NotesStore.appendEvent("\(source.rawValue) audio is back", to: note.id) }
        let first = !track.sawFirstChunk
        track.sawFirstChunk = true
        track.lastChunkAt = now
        track.restartAt = nil

        // The transcriber runs on this session's clock (its timeOffset carries the rest).
        let expectedSession = Int(now.timeIntervalSince(sessionStart) * AudioIO.sampleRate)
        let padT = Self.shortfall(expected: expectedSession, have: track.fedThisSession + chunk.count, first: first)
        if padT > 0 { feedSilence(padT, to: track) }
        track.transcriber.feed(chunk)
        track.fedThisSession += chunk.count

        // The file runs on the note's clock, so a resumed session lands after the earlier audio.
        var padF = 0
        if let w = track.writer {
            let expectedTotal = Int(now.timeIntervalSince(clockStart) * AudioIO.sampleRate)
            padF = Self.shortfall(expected: expectedTotal, have: w.frames + chunk.count, first: first)
            do {
                var left = padF
                while left > 0 { let n = min(left, Int(AudioIO.sampleRate)); try w.append([Float](repeating: 0, count: n)); left -= n }
                try w.append(chunk)
                if track.writeFailing { track.writeFailing = false; Log.info("meeting: writing \(source.rawValue) audio again") }
            } catch {
                if !track.writeFailing {
                    track.writeFailing = true
                    Log.error("meeting: writing \(source.rawValue) audio failed: \(error.localizedDescription)")
                    NotesStore.appendEvent("could not write \(source.rawValue) audio: \(error.localizedDescription)", to: note.id)
                    report(track, NSError(domain: "LinFlow.Meeting", code: 2, userInfo: [NSLocalizedDescriptionKey:
                        "Could not write the meeting audio (\(error.localizedDescription)). Check the free space on this disk; the transcript keeps going."]))
                }
            }
        }
        let gap = Double(max(padT, padF)) / AudioIO.sampleRate
        if first {
            if gap > 0 { Log.info(String(format: "meeting: %@ delivered its first audio %.2f s after start; aligned with silence", source.rawValue, gap)) }
        } else if gap >= 0.5 {
            Log.info(String(format: "meeting: filled a %.1f s gap in %@ with silence", gap, source.rawValue))
            NotesStore.appendEvent(String(format: "[%@] %.1f s gap in %@ filled with silence", stamp(now), gap, source.rawValue), to: note.id)
        }
    }

    private func feedSilence(_ samples: Int, to track: Track) {
        var left = samples
        while left > 0 {
            let n = min(left, Int(AudioIO.sampleRate))
            track.transcriber.feed([Float](repeating: 0, count: n))
            track.fedThisSession += n
            left -= n
        }
    }

    // MARK: watchdog (ioQueue)

    private func tick() {
        guard isRecording else { return }
        let now = Date()
        for track in tracks.values where track.wanted {
            if let due = track.restartAt, now >= due {
                restart(track, reason: track.restartReason)
                continue
            }
            let last = track.lastChunkAt ?? track.lastRestartAt ?? sessionStart
            if now.timeIntervalSince(last) > staleAfter, now >= (track.lastRestartAt ?? .distantPast).addingTimeInterval(track.backoff) {
                restart(track, reason: String(format: "no audio for %.0f s", now.timeIntervalSince(last)))
                track.backoff = min(track.backoff * 2, 60)
            }
        }
    }

    private func scheduleRestart(_ source: Source, reason: String, after: TimeInterval) {
        ioQueue.async { [weak self] in
            guard let self, self.isRecording, let track = self.tracks[source], track.wanted else { return }
            let at = Date().addingTimeInterval(after)
            track.restartAt = track.restartAt.map { min($0, at) } ?? at
            track.restartReason = reason
        }
    }

    private func restart(_ track: Track, reason: String) {
        guard isRecording else { return }
        track.restartAt = nil
        track.lastRestartAt = Date()
        Log.info("meeting: restarting \(track.source.rawValue) (\(reason))")
        NotesStore.appendEvent("[\(stamp(Date()))] restarting \(track.source.rawValue): \(reason)", to: note.id)
        if track.source == .mic { retireMic() }
        do {
            try startSource(track.source)
        } catch {
            Log.error("meeting: \(track.source.rawValue) restart failed: \(error.localizedDescription)")
            if !track.failing {
                track.failing = true
                let what = track.source == .mic ? "The microphone stopped" : "System audio stopped"
                let other = tracks.values.contains { $0.wanted && $0.source != track.source } ? " The other track keeps recording." : ""
                report(track, NSError(domain: "LinFlow.Meeting", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    "\(what) (\(error.localizedDescription)). Lin Flow keeps trying every few seconds.\(other)"]))
            }
        }
    }

    private func report(_ track: Track, _ error: Error) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.meetingRecorder(self, didFail: error)
        }
    }

    private func stamp(_ date: Date) -> String {
        let s = Int(date.timeIntervalSince(clockStart))
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    // MARK: device changes

    private func installDeviceListener() {
        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            self?.scheduleRestart(.system, reason: "the output device changed", after: 0.7)
        }
        var ok = true
        for selector in Self.deviceSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, block) != noErr { ok = false }
        }
        if ok { deviceListener = block } else { Log.error("meeting: could not watch the output device; the watchdog still covers it") }
    }

    private func removeDeviceListener() {
        guard let block = deviceListener else { return }
        for selector in Self.deviceSelectors {
            var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &address, ioQueue, block)
        }
        deviceListener = nil
    }

    /// 16 kHz mono 16-bit is about 230 MB an hour for two tracks. Under half a gigabyte the
    /// meeting is warned about before it starts, while there is still time to make room.
    private func checkFreeSpace() {
        guard let values = try? NotesStore.notesDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]),
              let free = values.volumeAvailableCapacityForImportantUsage, free < 500_000_000 else { return }
        let mb = free / 1_000_000
        Log.error("meeting: only \(mb) MB free for the recording")
        report(tracks[.mic]!, NSError(domain: "LinFlow.Meeting", code: 3, userInfo: [NSLocalizedDescriptionKey:
            "Only \(mb) MB free on this disk. A meeting needs about 230 MB an hour; make room or the recording will stop short."]))
    }
}
