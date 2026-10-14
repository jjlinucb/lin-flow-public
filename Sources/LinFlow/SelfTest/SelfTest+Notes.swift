import Foundation
import LinFlowCore

extension SelfTest {
    /// Meeting notes: summaries, running notes, and the full pass over a saved recording.
    static func notes() {
        // Who spoke, by voice (10-08). A line whose voice disagrees with its track moves, or goes when
        // the other track already holds the same words then.
        func line(_ id: String, _ speaker: String, _ text: String, at t: Double) -> TranscriptSegment {
            TranscriptSegment(id: id, start: t, end: t + 3, speaker: speaker, text: text)
        }
        let shared = [line("copy", "You", "the pass file is ordered by shot", at: 10), line("call", "Others", "the pass file is ordered by shot", at: 10.5),
                    line("mine", "You", "can you push it to the branch", at: 20), line("relay", "Others", "can you push it to the branch", at: 20.5),
                    line("stray", "You", "we print patterns on paper", at: 30), line("back", "Others", "I will email Mike today then", at: 40),
                    line("short", "You", "okay", at: 50)]
        let voiced = VoiceID.relabel(shared, scores: ["copy": 0.1, "call": 0.15, "mine": 0.8, "relay": 0.7, "stray": 0.2, "back": 0.75], slack: 1.5)
        expect(voiced.segments.map { "\($0.id):\($0.speaker)" } == ["call:Others", "mine:You", "stray:Others", "back:You", "short:You"]
               && voiced.dropped == 2 && voiced.moved == 2,
               "voices: each line kept once, under the speaker whose voice it is")
        expect(VoiceID.relabel(shared, scores: ["copy": 0.45], slack: 1.5).segments.count == shared.count, "voices: an unsure score leaves the track's label")
        expect(VoiceID.relabel(shared, scores: ["back": 0.75], slack: 1.5, callLag: 0.5).segments.first { $0.id == "back" }?.start == 39.5,
               "voices: a call line that was John's goes back to when he said it")
        expect(NoteTranscriber.dropEcho([shared[2], shared[3]], keep: ["mine"]).count == 2 && NoteTranscriber.dropEcho([shared[2], shared[3]]).count == 1,
               "voices: a line the voice says is John's is not taken for echo")

        // Old meetings go to the Trash after 14 days (10-08), never one still open or busy.
        let day = 86_400.0, now = Date()
        func meeting(_ id: String, age: Double, ended: Bool = true) -> MeetingNote {
            var n = MeetingNote(id: id, title: id, createdAt: now.addingTimeInterval(-age * day))
            if ended { n.endedAt = n.createdAt.addingTimeInterval(1800) }
            return n
        }
        let pile = [meeting("old", age: 15), meeting("new", age: 13), meeting("open", age: 30, ended: false), meeting("busy", age: 40)]
        expect(NotesStore.expired(pile, now: now, busy: ["busy"]).map(\.id) == ["old"], "auto delete: only an ended meeting past 14 days, not busy")
        // The call is over (10-07): every call app seen while recording left the microphone.
        expect(CallWatch.callAppName("com.google.Chrome.helper") == "Chrome", "call over: Chrome's helper counts as Chrome")
        expect(CallWatch.callAppName("com.microsoft.teams2") == "Teams", "call over: Teams is a call app")
        expect(CallWatch.callAppName("com.electron.wispr-flow") == nil && CallWatch.callAppName("com.johnlin.linflow") == nil,
               "call over: dictation apps are not calls")
        var call = CallWatch()
        var got: [CallWatch.Event] = []
        for t in stride(from: 0.0, through: 60, by: 2) { got += call.observe(at: t, micUsers: ["com.google.Chrome.helper"], quietFor: 1) }
        expect(got.isEmpty, "call over: nothing while the call holds the mic")
        got = call.observe(at: 62, micUsers: [], quietFor: 1) + call.observe(at: 64, micUsers: [], quietFor: 1)
        expect(got.isEmpty, "call over: a few seconds off the mic is a device switch, not the end")
        got = call.observe(at: 66, micUsers: [], quietFor: 1) + call.observe(at: 68, micUsers: [], quietFor: 1)
        expect(got == [.callEnded(name: "Chrome")], "call over: six seconds off the mic ends the call, once")
        got = call.observe(at: 70, micUsers: ["com.google.Chrome.helper"], quietFor: 1)
        expect(got == [.callBack], "call over: the call taking the mic again says so")
        var room = CallWatch()
        got = room.observe(at: 0, micUsers: [], quietFor: 30) + room.observe(at: 400, micUsers: [], quietFor: 300)
        expect(got == [.longSilence(minutes: 5)], "call over: no call app, five quiet minutes")
        got = room.observe(at: 402, micUsers: [], quietFor: 302) + room.observe(at: 404, micUsers: [], quietFor: 2)
        expect(got == [.speechBack], "call over: speech after the silence says so, once")
        var waiting = CallWatch()
        got = waiting.observe(at: 0, micUsers: ["us.zoom.xos"], quietFor: 30) + waiting.observe(at: 600, micUsers: ["us.zoom.xos"], quietFor: 600)
        expect(got.isEmpty, "call over: a silent waiting room with Zoom on the mic is not the end")
        // A call started (10-02): a call app on the mic for 8 s is offered once.
        var offer = CallOffer()
        var offers: [String] = []
        for t in stride(from: 0.0, through: 6, by: 3) { offers += [offer.observe(at: t, micUsers: ["us.zoom.xos"], recording: false)].compactMap { $0 } }
        expect(offers.isEmpty, "call offer: not in the first few seconds, a sound check")
        for t in stride(from: 9.0, through: 60, by: 3) { offers += [offer.observe(at: t, micUsers: ["us.zoom.xos"], recording: false)].compactMap { $0 } }
        expect(offers == ["Zoom"], "call offer: once, after 8 s on the mic")
        offers = [offer.observe(at: 63, micUsers: [], recording: false), offer.observe(at: 72, micUsers: ["us.zoom.xos"], recording: false),
                  offer.observe(at: 81, micUsers: ["us.zoom.xos"], recording: false)].compactMap { $0 }
        expect(offers.isEmpty, "call offer: a device switch is the same call, not offered again")
        offers = [offer.observe(at: 90, micUsers: [], recording: false), offer.observe(at: 96, micUsers: [], recording: false),
                  offer.observe(at: 100, micUsers: ["us.zoom.xos"], recording: false), offer.observe(at: 109, micUsers: ["us.zoom.xos"], recording: false)].compactMap { $0 }
        expect(offers == ["Zoom"], "call offer: a new call after the last one ended is offered")
        var both = CallOffer()
        offers = [both.observe(at: 0, micUsers: ["us.zoom.xos"], recording: false), both.observe(at: 3, micUsers: ["us.zoom.xos", "com.google.Chrome.helper"], recording: false),
                  both.observe(at: 12, micUsers: ["us.zoom.xos", "com.google.Chrome.helper"], recording: false)].compactMap { $0 }
        expect(offers == ["Zoom"], "call offer: the longest-running call app first")
        expect(both.observe(at: 15, micUsers: ["us.zoom.xos", "com.google.Chrome.helper"], recording: false) == "Chrome",
               "call offer: each app once, so a call that starts while another app sits on the mic is still offered")
        var recorded = CallOffer()
        offers = [recorded.observe(at: 0, micUsers: ["com.microsoft.teams2"], recording: true), recorded.observe(at: 30, micUsers: ["com.microsoft.teams2"], recording: true),
                  recorded.observe(at: 33, micUsers: ["com.microsoft.teams2"], recording: false)].compactMap { $0 }
        expect(offers.isEmpty, "call offer: not while recording, nor for that call once the note stops")
        var dictating = CallOffer()
        offers = [dictating.observe(at: 0, micUsers: ["com.electron.wispr-flow"], recording: false), dictating.observe(at: 30, micUsers: ["com.electron.wispr-flow", "pid:123"], recording: false)].compactMap { $0 }
        expect(offers.isEmpty, "call offer: a dictation app on the mic is not a call")
        expect(TranscriptSegment(start: 65, end: 70, speaker: "You", text: "x").timestampLabel, "1:05", "timestamp label")

        // Asking Claude about a meeting (ClaudeClient, MeetingQuestions). No request leaves the Mac here.
        do {
            let r = ClaudeClient.request(key: "test-key", system: "sys", user: "hello")
            let body = (try? JSONSerialization.jsonObject(with: r.httpBody ?? Data())) as? [String: Any] ?? [:]
            expect(body["model"] as? String ?? "", "claude-opus-5-5", "claude: the model")
            expect((body["output_config"] as? [String: Any])?["effort"] as? String ?? "", "low", "claude: low effort for questions mid-call")
            expect(body["fallbacks"] as? String == "default" && r.value(forHTTPHeaderField: "anthropic-beta") == "server-side-fallback-2026-07-01",
                   "claude: a declined answer falls back, with the header that form needs")
            expect(r.value(forHTTPHeaderField: "x-api-key") == "test-key" && body["thinking"] == nil, "claude: the key goes in its header, and thinking is left on")
            let ok = #"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":" Two points. "}],"stop_reason":"end_turn"}"#
            expect((try? ClaudeClient.parse(status: 200, data: Data(ok.utf8))) ?? "", "Two points.", "claude: text blocks only, trimmed")
            let refused = #"{"content":[],"stop_reason":"refusal"}"#
            expect((try? ClaudeClient.parse(status: 200, data: Data(refused.utf8))) == nil, "claude: a refusal is an error, not an empty answer")
            let bad = #"{"type":"error","error":{"type":"authentication_error","message":"invalid x-api-key"}}"#
            do { _ = try ClaudeClient.parse(status: 401, data: Data(bad.utf8)); expect(false, "claude: a 401 throws") }
            catch { expect(error.localizedDescription.contains("invalid x-api-key"), "claude: the API's own message reaches John") }
            let prompt = MeetingQuestions.prompt(title: "Standup", transcript: "[0:05] Others: Ship Friday.", notes: "  ",
                                                 earlier: [.init(question: "Who ships?", answer: "Others.")], question: "When?")
            expect(prompt.contains("[0:05] Others: Ship Friday.") && prompt.contains("John: Who ships?") && prompt.hasSuffix("John asks: When?"),
                   "claude: the question carries the transcript and the conversation so far")
            expect(!prompt.contains("John's notes"), "claude: empty notes are left out")
            let id = "selftest-questions-\(UUID().uuidString)"
            try? FileManager.default.createDirectory(at: NotesStore.folder(for: id), withIntermediateDirectories: true)
            MeetingQuestions.save([.init(question: "q", answer: "a")], for: id)
            expect(MeetingQuestions.load(id).map(\.answer) == ["a"], "claude: questions are saved with the note")
            try? FileManager.default.removeItem(at: NotesStore.folder(for: id))
        }

        // The microphone hearing the speakers (2026-10-02): the echo goes, John's own words stay.
        do {
            func seg(_ who: String, _ a: Double, _ b: Double, _ t: String) -> TranscriptSegment { TranscriptSegment(start: a, end: b, speaker: who, text: t) }
            let talk = [
                seg("Others", 394, 404, "So those are usually the 2 groups that are most likely to get a foodborne illness."),
                seg("You", 395, 404, "So those are the usually the 2 groups that are most likely to get a foodborne illness."),
                seg("You", 405, 408, "Okay, got it."),
                seg("You", 420, 426, "Can you send the slides to everyone after this?"),
                seg("Others", 427, 430, "Yes, I will send the slides."),
                seg("You", 500, 504, "the 2 groups most likely to get a foodborne illness"),
                seg("Others", 600, 614, "I think the main thing is the temperature, and that is what we check first every time"),
                seg("You", 605, 607, "I think that is right"),
            ]
            let kept = NoteTranscriber.dropEcho(talk).map(\.text)
            expect(!kept.contains(talk[1].text), "echo: the speakers heard by the mic go")
            expect(kept.contains(talk[0].text), "echo: the other side's own copy stays")
            expect(kept.contains(talk[2].text), "echo: John's short reply stays")
            expect(kept.contains(talk[3].text), "echo: John's question stays, though the answer shares words")
            expect(kept.contains(talk[5].text), "echo: John repeating it later is not an echo")
            expect(kept.contains(talk[7].text), "echo: common words said over someone are not an echo")
            expect(NoteTranscriber.dropEcho(talk.filter { $0.speaker == "You" }).count == 5, "echo: a note with no other side keeps everything")
        }
        expect(TranscriptSegment(start: 3725, end: 3730, speaker: "You", text: "x").timestampLabel, "1:02:05", "timestamp label hours")
        let parts = AppleIntelligenceSummarizer.split((1...50).map { "[0:\($0)] You: line number \($0) with some words in it" }.joined(separator: "\n"), maxCharacters: 400)
        expect(parts.count > 1 && parts.allSatisfy { $0.count <= 400 } && parts.joined(separator: "\n").split(separator: "\n").count == 50, "summarizer split keeps lines")
        let lines = (1...50).map { "[0:\($0)] You: line number \($0) with some words in it" }
        let recent = AppleIntelligenceSummarizer.tail(lines.joined(separator: "\n"), maxCharacters: 400)
        expect(recent.count <= 400 && recent.hasSuffix(lines[49]) && lines.contains(String(recent.split(separator: "\n")[0])),
               "recap reads the most recent whole lines that fit")
        expect(AppleIntelligenceSummarizer.tail("short", maxCharacters: 400), "short", "recap: a short transcript is read whole")

        // Merging the notes the model takes on each part of a meeting: two parts as the schema
        // hands them back once tidied, the second repeating a point of the first in lower case.
        let notesA: [NotesMerge.Section: [String]] = [
            .summary: ["Launch date is March 14, retail price 189 dollars.", "Press embargo lifts March 12 at 6 AM Eastern."],
            .actions: ["Marcus ships forty units to the press list by February 20.", "Priya sends the exec readout."],
            .questions: ["Does Matter certification slip to April?"]]
        let notesB: [NotesMerge.Section: [String]] = [
            .summary: ["launch date is March 14, retail price 189 dollars", "Dark mode ships in 3.1."],
            .decisions: ["Influencer kits go to 25 creators."]]
        let merged = NotesMerge.merge([notesA, notesB])
        expect((merged[.summary] ?? []).count == 3, "notes merge: repeat dropped case-insensitively (\((merged[.summary] ?? []).count))")
        expect(NotesMerge.render(merged), "## Summary\n* Launch date is March 14, retail price 189 dollars.\n* Press embargo lifts March 12 at 6 AM Eastern.\n* Dark mode ships in 3.1.\n\n## Decisions\n* Influencer kits go to 25 creators.\n\n## Action items\n* Marcus ships forty units to the press list by February 20.\n* Priya sends the exec readout.\n\n## Open questions\n* Does Matter certification slip to April?", "notes render")
        expect(NotesMerge.render([:]), "## Summary\n* None\n\n## Decisions\n* None\n\n## Action items\n* None\n\n## Open questions\n* None", "notes render empty")
        expect(NotesMerge.tidy(["* Ship 40 units.", " **Priya** owns the list. ", "None", "", "No decisions were made."]).joined(separator: "|"), "Ship 40 units.|Priya owns the list.", "notes tidy")
        expect(NotesMerge.tidy(["You: The build is stable. Good, next.", "Last items. The party is at Pier 27 on March 14.", "Mr. Lee will send it.", "Others: Fine by me."]).joined(separator: "|"), "The build is stable.|The party is at Pier 27 on March 14.|Mr. Lee will send it.|Fine by me.", "notes tidy: speaker labels and scraps")
        let refiled = NotesMerge.refile([.summary: ["Boot time is 10 seconds."], .questions: ["Android parity is at 90 percent.", "Do we announce the Matter date?", "Whether Costco gets the two-pack is undecided."]])
        expect((refiled[.questions] ?? []).joined(separator: "|"), "Do we announce the Matter date?|Whether Costco gets the two-pack is undecided.", "notes refile: questions kept")
        expect((refiled[.summary] ?? []).joined(separator: "|"), "Boot time is 10 seconds.|Android parity is at 90 percent.", "notes refile: fact moved to key points")
        let near = NotesMerge.merge([[.actions: ["Finance wants weekly sell through numbers from Best Buy starting March 21."]], [.actions: ["Finance: weekly sell-through numbers from Best Buy starting March 21.", "Dana freezes firmware on March 27."]]])
        expect((near[.actions] ?? []).joined(separator: "|"), "Finance: weekly sell-through numbers from Best Buy starting March 21.|Dana freezes firmware on March 27.", "notes merge: near repeat keeps the shorter phrasing")
        expect(NotesMerge.render([.summary: ["Launch date March 14", "Price is 189 dollars.", "She asked \"why now?\""]]).split(separator: "\n").prefix(4).joined(separator: "|"), "## Summary|* Launch date March 14.|* Price is 189 dollars.|* She asked \"why now?\"", "notes render: punctuation added once")

        // Speech regions for the full pass over a saved track (frames of 100 ms).
        do {
            func levels(_ n: Int, base: Float = 0, _ bursts: [(Range<Int>, Float)]) -> [Float] {
                var l = [Float](repeating: base, count: n)
                for (r, v) in bursts { for i in r { l[i] = v } }
                return l
            }
            let fs = 1600
            let two = NoteTranscriber.regions(levels: levels(600, [(50..<80, 0.05), (200..<230, 0.05)]), totalSamples: 600 * fs)
            expect(two.count == 2, "regions: two stretches 12 s apart are two regions")
            expect(two.first == NoteTranscriber.Region(start: 47 * fs, end: 83 * fs), "regions: padded 0.3 s each side")
            let one = NoteTranscriber.regions(levels: levels(600, [(50..<80, 0.05), (90..<120, 0.05)]), totalSamples: 600 * fs)
            expect(one.count == 1 && one[0].end == 123 * fs, "regions: a 1 s gap merges the neighbours for context")
            var long = levels(600, [(0..<500, 0.05)])
            long[200] = 0.02
            let split = NoteTranscriber.regions(levels: long, totalSamples: 600 * fs)
            expect(split.count == 3, "regions: 50 s of talk becomes three pieces under 28 s")
            expect(split.count == 3 && split[0].end == 200 * fs && split[1].start == 200 * fs, "regions: the first cut lands on the quietest frame")
            expect(split.allSatisfy { $0.end - $0.start <= 280 * fs }, "regions: no piece over 28 s")
            expect(NoteTranscriber.regions(levels: levels(600, [(300..<303, 0.05)]), totalSamples: 600 * fs).isEmpty, "regions: a 0.3 s click is not a segment")
            let hum = NoteTranscriber.regions(levels: levels(600, base: 0.01, [(100..<150, 0.05)]), totalSamples: 600 * fs)
            expect(hum.count == 1 && hum[0].start == 97 * fs, "regions: a constant hum raises the floor instead of becoming speech")
            var samples = [Float](repeating: 0, count: 32_800)   // 2.05 s
            for i in 16_000..<32_800 { samples[i] = 0.5 }
            let lv = NoteTranscriber.levels(read: { Array(samples[$0..<min(samples.count, $0 + $1)]) }, totalSamples: samples.count)
            expect(lv.count == 21, "levels: 2.05 s gives 20 frames and a half-frame tail")
            expect(lv.count == 21 && abs(lv[15] - 0.5) < 1e-6 && lv[3] == 0, "levels: RMS per 100 ms frame")
        }

        // Running notes: which stretch a pass reads, when it is due, how it is written down.
        do {
            func seg(_ id: String, _ start: Double, _ words: Int) -> TranscriptSegment {
                TranscriptSegment(id: id, start: start, end: start + 5, speaker: "Others", text: Array(repeating: "word", count: words).joined(separator: " "))
            }
            let segs = [seg("c", 30, 10), seg("a", 10, 10), seg("b", 20, 10), seg("d", 40, 10), seg("e", 50, 10)]
            let fresh = RunningNotes.window(segs, processed: ["a", "b"])
            expect(fresh.map(\.id) == ["c", "d", "e"], "running notes: window is the unnoted segments in time order")
            expect(RunningNotes.window(segs, processed: [], maxWords: 25).map(\.id) == ["a", "b"], "running notes: the word budget stops between segments")
            expect(RunningNotes.window(segs, processed: [], maxWords: 3).count == 1, "running notes: a budget too small for one segment still reads one")
            expect(RunningNotes.wordCount(fresh) == 30, "running notes: word count over the window")
            expect(RunningNotes.isDue(newWords: 50, sinceLast: 61, final: false), "running notes: due after a minute with enough new words")
            expect(!RunningNotes.isDue(newWords: 50, sinceLast: 30, final: false), "running notes: not due within the minute")
            expect(!RunningNotes.isDue(newWords: 20, sinceLast: 120, final: false), "running notes: not due on small talk")
            expect(RunningNotes.isDue(newWords: 20, sinceLast: 0, final: true), "running notes: the final pass takes a shorter stretch")
            expect(!RunningNotes.isDue(newWords: 5, sinceLast: 0, final: true), "running notes: but not a few words")
            expect(RunningNotes.format(["Ship the batch Friday.", "Ask Dana for the figures."], at: 725), "- [12:05] Ship the batch Friday.\n- [12:05] Ask Dana for the figures.\n", "running notes: bullets stamped with the stretch's start")
            expect(RunningNotes.format([], at: 725), "", "running notes: nothing written for an empty pass")
            let md = (1...12).map { "- [0:0\($0 % 10)] Note number \($0)." }.joined(separator: "\n") + "\n"
            let recent = RunningNotes.recent(md, count: 8)
            expect(recent.count == 8 && recent.first == "Note number 5." && recent.last == "Note number 12.", "running notes: the last eight bullets, stamps removed, as context")
            let kept = RunningNotes.dropRepeats(["Ship the batch Friday", "Budget is 40k.", "budget is 40K"], previous: ["Ship the batch Friday."])
            expect(kept == ["Budget is 40k."], "running notes: a repeat of an earlier bullet or of itself is dropped")
            expect(RunningNotes.dropRepeats(["David J. Lamb overviewing business questions"], previous: ["David J. Lamb will overview business questions."]).isEmpty,
                   "running notes: the same note in new words is a repeat")
            expect(RunningNotes.worthKeeping("Name: Ted") == nil, "running notes: a labeled name is not a note")
            expect(RunningNotes.worthKeeping("I got one.") == nil, "running notes: a fragment is not a note")
            expect(RunningNotes.worthKeeping("Task: send the OTA draft to Ted tomorrow") == "Send the OTA draft to Ted tomorrow", "running notes: a label is stripped, the sentence kept")
            expect(RunningNotes.worthKeeping("National security due diligence responses are due today.") == "National security due diligence responses are due today.", "running notes: a real sentence is kept as is")
            let stretch = "[3:00] Others: Document review extends to Wednesday for everyone, and the pilot budget is $40,000. We will open 2 engineering roles in October. Dana owns the vendor contract."
            expect(RunningNotes.filter(["Question: profit pool and equipment", "Document review extends to Wednesday for everyone.", "document review extends to wednesday for everyone"], previous: [], transcript: stretch) == ["Document review extends to Wednesday for everyone."],
                   "running notes: filter drops fragments and in-batch repeats")
            expect(!RunningNotes.grounded("The deadline is Friday, October 18th.", in: stretch), "running notes: an invented date is not grounded")
            expect(!RunningNotes.grounded("Five deals were done the week before.", in: stretch), "running notes: an invented count is not grounded")
            expect(RunningNotes.grounded("The budget is 40,000 dollars.", in: stretch), "running notes: a number said with a currency sign is grounded")
            expect(RunningNotes.grounded("Two engineering roles open in October.", in: stretch), "running notes: a spelled number matches its digits")
            expect(RunningNotes.grounded("Dana owns the vendor contract.", in: stretch), "running notes: a name that was said is grounded")
            expect(!RunningNotes.grounded("The contract is owned by Marc.", in: stretch), "running notes: a name that was not said is not")
            expect(RunningNotes.grounded("Review runs to Wednesday, as You noted.", in: stretch), "running notes: You and Others are not names to check")
            expect(!RunningNotes.grounded("Anna agreed to help with the paperwork review.", in: stretch), "running notes: a sentence opening with a name nobody said is not grounded")
        }
    }
}
