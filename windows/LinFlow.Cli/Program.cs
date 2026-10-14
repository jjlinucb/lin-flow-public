using System.Diagnostics;
using System.Reflection;
using LinFlow.Core;
using LinFlow.Engine;

namespace LinFlow.Cli;

/// The console front end, and deliberately the first thing to run on a new machine.
///
/// The whole Windows port was written and compiled on a Mac, so nothing Windows-specific had
/// ever executed before it reached John's laptop. `linflow doctor` is the answer to that: it
/// checks the native DLLs load, the hand-written P/Invoke struct layouts read back sane values,
/// and the model is present and complete - in a console, where a failure is a printed message
/// instead of a tray app that silently does nothing.
public static class Program
{
    public static int Main(string[] args)
    {
        Log.EchoToConsole = true;
        if (args.Length == 0) { Usage(); return 1; }

        try
        {
            return args[0] switch
            {
                "doctor" => Doctor(),
                "meeting" => Meeting(args),
                "notes" => Notes(),
                "notes-transcribe" => NotesTranscribe(args),
                "notes-repair" => NotesRepair(args),
                "clean" => Clean(args),
                "transcribe" => Transcribe(args),
                "bench" => Bench(args),
                "mic-test" => MicTest(),
                "learn-test" => LearnTest(args),
                "focus-test" => FocusTest(args),
                "models" => Models(),
                "download" => Download(args),
                "version" => Version(),
                _ => Usage(),
            };
        }
        catch (DllNotFoundException e)
        {
            Console.Error.WriteLine($"\nA native DLL is missing: {e.Message}");
            Console.Error.WriteLine("Run scripts\\fetch-native.ps1, or copy the whisper.cpp DLLs next to this exe.");
            return 2;
        }
        catch (Exception e)
        {
            Console.Error.WriteLine($"\n{e.GetType().Name}: {e.Message}");
            return 2;
        }
    }

    private static int Usage()
    {
        Console.WriteLine("""
            linflow <command>

              doctor                 check the native DLLs, the struct layouts and the models
              clean "<text>"         run the cleanup pipeline (no audio, no model)
              transcribe <file.wav>  transcribe a 16 kHz wav
              meeting [--title "..."] [--no-mic] [--no-system] [--no-live] [--no-notes] [--no-transcribe]
                                     record a meeting note (you + what the PC plays), with running notes
                                     and a summary from Ollama when it is installed; Enter or Ctrl+C stops it
              notes                  list the meeting notes
              notes-transcribe <note id|folder|wav> [--save]
                                     transcribe a note's saved audio whole (--save rewrites its transcript)
              notes-repair [<wav>]   fix a WAV cut short by a crash, or close every unfinished note
              bench <file.wav> [--threads N]
                                     warmed timings for the installed models
              mic-test               record one second from the default input and say what came back
              learn-test "<wrote>" "<now>" [--apply]
                                     what an edit would teach the dictionary (--apply adds it)
              focus-test [--wait N]  whether the app in front lets its text field be read back, which
                                     learning from an edit needs; N seconds to click into a field first
              models                 list known models and which are installed
              download <model-id>    fetch a model into %APPDATA%\\Lin Flow\\models
              version                versions and paths
            """);
        return 1;
    }

    private static int Version()
    {
        Console.WriteLine($"Lin Flow {Assembly.GetExecutingAssembly().GetName().Version}");
        Console.WriteLine($"data dir  {Paths.DataDir}");
        Console.WriteLine($"models    {Paths.ModelsDir}");
        Console.WriteLine($"exe dir   {AppContext.BaseDirectory}");
        return 0;
    }

    private static int Doctor()
    {
        var ok = true;
        Console.WriteLine($"Lin Flow doctor\n  exe dir   {AppContext.BaseDirectory}\n  data dir  {Paths.DataDir}\n");

        Console.WriteLine("native DLLs beside the exe:");
        string[] needed = { "parakeet.dll", "ggml.dll", "ggml-base.dll", "ggml-cpu.dll" };
        foreach (var dll in needed)
        {
            var p = Path.Combine(AppContext.BaseDirectory, dll);
            var found = File.Exists(p);
            var label = dll;
            // ggml-cpu ships per-architecture (ggml-cpu-haswell.dll and friends); any one will do.
            // Print what was actually matched rather than the canonical name: nothing on disk is
            // literally called ggml-cpu.dll, and a green line naming a file that is not there is
            // the opposite of what doctor exists to do.
            if (!found && dll == "ggml-cpu.dll")
            {
                var variants = Directory.GetFiles(AppContext.BaseDirectory, "ggml-cpu*.dll");
                found = variants.Length > 0;
                if (found)
                    label = $"ggml-cpu*.dll ({variants.Length} found, using {Path.GetFileName(variants[0])})";
            }
            Console.WriteLine($"  {(found ? "ok  " : "MISSING")}  {label}");
            if (!found) ok = false;
        }
        if (!ok)
        {
            Console.WriteLine("\n  -> run scripts\\fetch-native.ps1 to download them from the whisper.cpp v1.9.1 release.");
            return 2;
        }

        Console.WriteLine("\nloading ggml backends...");
        try
        {
            ParakeetEngine.EnsureBackendsLoaded();
            Console.WriteLine($"  ok    {ParakeetEngine.SelfCheck()}");
            if (ParakeetEngine.SelfCheck().StartsWith("NATIVE STRUCT")) ok = false;
        }
        catch (Exception e)
        {
            Console.WriteLine($"  FAILED  {e.GetType().Name}: {e.Message}");
            return 2;
        }

        Console.WriteLine("\nmodels:");
        foreach (var m in ModelCatalog.Known)
        {
            var installed = ModelCatalog.IsInstalled(m);
            var usable = ModelCatalog.IsUsable(m);
            // An installed Whisper model used to print "ok" and count as a pass, so doctor
            // exited 0 on a machine where the tray app could load nothing at all - and
            // install.ps1, which only downloads when doctor fails, then skipped the download.
            var tag = !installed ? "missing" : usable ? "ok     " : "present";
            var note = installed && !usable ? "   (Whisper; this build binds Parakeet only)" : "";
            Console.WriteLine($"  {tag}  {m.Id}  ({m.SizeMB} MB){note}");
        }
        if (ModelCatalog.FirstUsable() is null)
        {
            Console.WriteLine($"\n  -> linflow download {ModelCatalog.DefaultModelId}");
            ok = false;
        }

        // A machine with no microphone passes every other check and then cannot dictate, so
        // doctor says it plainly. Not fatal: the CLI transcribes files without one.
        Console.WriteLine("\nmicrophone:");
        var mic = Recorder.DescribeDefaultInput();
        Console.WriteLine($"  {(mic is null ? "MISSING  no input device; dictation will not work until one is connected" : "ok       " + mic)}");

        // The meeting notetaker also records what the machine plays (the other side of a call)
        // through WASAPI loopback on the default output device.
        Console.WriteLine("\nsystem audio (for meeting notes):");
        var render = MeetingRecorder.DescribeDefaultOutput();
        Console.WriteLine($"  {(render is null ? "MISSING  no output device; a meeting note records the microphone only" : "ok       " + render)}");

        // Running notes and the meeting summary come from a local model behind Ollama. Not fatal:
        // without it a meeting still records and transcribes, it just takes no notes.
        Console.WriteLine("\nnotes model (for running notes and summaries):");
        var (host, notesModel) = NoteWriterSettings.Load();
        var ollamaProblem = new OllamaClient(host, notesModel).CheckAsync().GetAwaiter().GetResult();
        Console.WriteLine($"  {(ollamaProblem is null ? $"ok       Ollama at {host}, {notesModel}" : "MISSING  " + ollamaProblem)}");

        Console.WriteLine($"\ndictionary:\n  {Glossary.Load().Count} glossary terms, {Glossary.LoadReplacements().Count} corrections");
        Console.WriteLine(ok ? "\nAll good. Try:  linflow transcribe test.wav" : "\nSomething above needs fixing.");
        return ok ? 0 : 2;
    }

    private static bool Flag(string[] args, string name) => args.Skip(1).Contains(name, StringComparer.OrdinalIgnoreCase);

    private static string? Option(string[] args, string name)
    {
        var i = Array.FindIndex(args, a => a.Equals(name, StringComparison.OrdinalIgnoreCase));
        return i >= 0 && i + 1 < args.Length ? args[i + 1] : null;
    }

    private static string? Positional(string[] args)
    {
        for (var i = 1; i < args.Length; i++)
        {
            if (args[i].StartsWith("--", StringComparison.Ordinal)) { if (args[i] == "--title") i++; continue; }
            return args[i];
        }
        return null;
    }

    /// The meeting notetaker, console edition: the microphone as "You" and what the machine plays
    /// as "Others", live lines as people speak, and when it ends a transcript rebuilt from the
    /// saved audio. Enter or Ctrl+C stops it cleanly. The audio is written as it arrives with a
    /// header that stays valid, so even a crash here leaves a note that `notes-repair` and
    /// `notes-transcribe` turn into text. Nothing here needs the tray app to be running.
    private static int Meeting(string[] args)
    {
        var title = Option(args, "--title") ?? $"Meeting {DateTime.Now:MMM d, h:mm tt}";
        var useMic = !Flag(args, "--no-mic");
        var useSystem = !Flag(args, "--no-system");
        var live = !Flag(args, "--no-live");
        var full = !Flag(args, "--no-transcribe");
        var wantNotes = !Flag(args, "--no-notes");
        if (!useMic && !useSystem) { Console.Error.WriteLine("nothing to record: --no-mic and --no-system together"); return 1; }

        Glossary.SeedIfMissing();
        var store = new NotesStore();
        foreach (var n in store.RecoverUnfinished())
            Console.WriteLine($"closed a note an earlier run never stopped: \"{n.Title}\" ({(int)n.DurationSeconds} s). To get its text: linflow notes-transcribe {n.Id} --save");
        var cleaner = new TextCleaner(Glossary.Load(), Glossary.LoadReplacements()) { SpokenCommands = false };
        var engine = live || full ? OpenDefaultEngine() : null;
        var note = store.Create(title);
        using var recorder = new MeetingRecorder(store, note, () => live ? engine : null, cleaner);
        recorder.SegmentAdded += s => Console.WriteLine($"[{s.TimestampLabel}] {s.Speaker}: {s.Text}");
        recorder.Failed += m => Console.Error.WriteLine($"! {m}");

        // Running notes: a few bullets a minute from a local model, the way the Mac does it with
        // Apple Intelligence. Never a reason not to record: without Ollama the meeting still
        // records and transcribes.
        OllamaClient? writer = null;
        RunningNotesTaker? taker = null;
        if (wantNotes && live)
        {
            var (host, notesModel) = NoteWriterSettings.Load();
            var candidate = new OllamaClient(host, notesModel);
            var problem = candidate.CheckAsync().GetAwaiter().GetResult();
            if (problem is null) writer = candidate;
            else Console.WriteLine($"running notes are off this meeting: {problem}");
        }
        if (writer is not null)
        {
            taker = new RunningNotesTaker(store, note.Id, writer, title);
            taker.NotesAdded += block => { foreach (var line in block.TrimEnd().Split('\n')) Console.WriteLine($"    \u270e {line}"); };
            taker.Failed += m => Console.Error.WriteLine($"! notes: {m}");
        }

        recorder.Start(useMic, useSystem, keepAudio: true);
        taker?.Start();
        Console.WriteLine($"recording \"{title}\" (mic={useMic}, system={useSystem}, notes={(taker is not null ? writer!.Name : "off")})");
        Console.WriteLine($"  -> {store.Folder(note.Id)}");
        Console.WriteLine("press Enter or Ctrl+C to stop\n");

        using var stop = new ManualResetEventSlim();
        Console.CancelKeyPress += (_, e) => { e.Cancel = true; stop.Set(); };
        var reader = new Thread(() => { try { Console.ReadLine(); } catch (Exception) { } stop.Set(); }) { IsBackground = true };
        reader.Start();
        stop.Wait();

        Console.WriteLine("\nstopping...");
        recorder.Stop();
        var saved = store.Load(note.Id) ?? note;
        Console.WriteLine($"saved {(int)saved.DurationSeconds} s of audio to {store.Folder(note.Id)}");
        if (taker is not null)
        {
            taker.StopAsync().GetAwaiter().GetResult();   // the last stretch gets its bullets
            taker.Dispose();
        }
        if (full && engine is not null)
        {
            Console.WriteLine("transcribing the recording whole...");
            var segments = NoteTranscriber.TranscribeNote(store, note.Id, engine, cleaner, p => Console.Write($"\r  {p}    "));
            Console.WriteLine();
            store.ReplaceTranscript(segments, note.Id, NoteTranscriber.DisplayName(engine));
            var words = segments.Sum(s => s.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length);
            Console.WriteLine($"{segments.Count} segments, {words} words -> transcript.jsonl (the live one is kept as transcript-live.jsonl)");
        }
        if (writer is not null)
        {
            // The final notes: the running notes carry the whole meeting in condensed form, and the
            // last stretch of transcript covers what the final pass may have missed.
            Console.WriteLine("writing the summary...");
            try
            {
                var all = store.Transcript(note.Id);
                var last = all.Where(s => s.End >= (all.Count > 0 ? all[^1].End : 0) - 180).ToList();
                var summary = writer.SummaryAsync(store.RunningNotes(note.Id), NotesStore.TranscriptText(last), title).GetAwaiter().GetResult();
                if (summary.Length > 0)
                {
                    store.SaveSummary(summary, note.Id);
                    saved.SummaryModel = writer.Name;
                    store.Save(saved);
                    Console.WriteLine("\n" + summary + "\n");
                }
            }
            catch (Exception e) { Console.Error.WriteLine($"! summary: {e.Message}"); }
        }
        File.WriteAllText(Path.Combine(store.Folder(note.Id), "note.md"), store.Markdown(saved));
        Console.WriteLine($"note.md written in {store.Folder(note.Id)}");
        engine?.Dispose();
        return 0;
    }

    private static int Notes()
    {
        var store = new NotesStore();
        var notes = store.List();
        if (notes.Count == 0) { Console.WriteLine($"no meeting notes yet in {store.Root}"); return 0; }
        foreach (var n in notes)
        {
            var flags = (n.TranscribedFromAudioAt is null ? "live transcript" : "transcript from audio")
                        + (n.Recovered == true ? ", recovered" : "") + (n.EndedAt is null ? ", UNFINISHED" : "");
            Console.WriteLine($"  {n.Id}  {NotesStore.Parse(n.CreatedAt).ToLocalTime():yyyy-MM-dd HH:mm}  {(int)(n.DurationSeconds / 60),3} min  {n.Title}  [{flags}]");
        }
        return 0;
    }

    /// The full pass NoteTranscriber runs after a meeting, from the command line. A note id or
    /// its folder transcribes every saved track and merges them; a lone audio file is treated as
    /// "You". Nothing is written unless --save is given, and even then the live transcript is
    /// kept as transcript-live.jsonl.
    private static int NotesTranscribe(string[] args)
    {
        var target = Positional(args);
        if (target is null) { Console.Error.WriteLine("notes-transcribe needs a note id, a note folder or a wav file"); return 1; }
        var store = new NotesStore();
        var cleaner = new TextCleaner(Glossary.Load(), Glossary.LoadReplacements()) { SpokenCommands = false };
        using var engine = OpenDefaultEngine();
        var sw = Stopwatch.StartNew();
        Action<string> progress = p => Console.Error.Write($"\r  {p}    ");
        List<TranscriptSegment> segments;
        string? noteId = null;
        if (File.Exists(target))
        {
            segments = NoteTranscriber.TranscribeFile(target, "You", engine, cleaner, progress);
        }
        else
        {
            noteId = Directory.Exists(target) ? Path.GetFileName(Path.TrimEndingDirectorySeparator(target)) : target;
            segments = NoteTranscriber.TranscribeNote(store, noteId, engine, cleaner, progress);
        }
        Console.Error.WriteLine();
        foreach (var s in segments) Console.WriteLine($"[{s.TimestampLabel} -> {s.End:F1}s] {s.Speaker}: {s.Text}");
        var words = segments.Sum(s => s.Text.Split(' ', StringSplitOptions.RemoveEmptyEntries).Length);
        if (Flag(args, "--save") && noteId is not null)
        {
            store.ReplaceTranscript(segments, noteId, NoteTranscriber.DisplayName(engine));
            Console.Error.WriteLine("saved as transcript.jsonl (live transcript kept as transcript-live.jsonl)");
        }
        Console.Error.WriteLine($"{segments.Count} segment(s), {words} words, {sw.Elapsed.TotalSeconds:F1}s [{NoteTranscriber.DisplayName(engine)}]");
        return 0;
    }

    /// With a file: repair that WAV's header from its size and print its duration. Without: close
    /// every note the app never stopped, the way `meeting` does before it starts.
    private static int NotesRepair(string[] args)
    {
        var target = Positional(args);
        if (target is not null)
        {
            var before = WavWriter.Duration(target) ?? 0;
            var changed = WavWriter.RepairHeader(target);
            var after = WavWriter.Duration(target) ?? 0;
            Console.WriteLine($"{Path.GetFileName(target)}: {(changed ? "repaired" : "already consistent")} (header said {before:F1} s, file holds {after:F1} s)");
            return 0;
        }
        var recovered = new NotesStore().RecoverUnfinished();
        if (recovered.Count == 0) Console.WriteLine("no unfinished notes");
        foreach (var n in recovered) Console.WriteLine($"recovered {n.Id} \"{n.Title}\": {(int)n.DurationSeconds} s");
        return 0;
    }

    private static int Clean(string[] args)
    {
        if (args.Length < 2) { Console.Error.WriteLine("clean needs some text"); return 1; }
        Log.EchoToConsole = false;
        Console.WriteLine(new TextCleaner().Clean(args[1]));
        return 0;
    }

    private static ParakeetEngine OpenDefaultEngine()
    {
        var model = ModelCatalog.FirstUsable();
        if (model is null)
        {
            // Keep the two cases apart: "you have nothing" and "you have the wrong kind" send
            // the reader somewhere different.
            var other = ModelCatalog.Known.FirstOrDefault(ModelCatalog.IsInstalled);
            throw new InvalidOperationException(other is null
                ? $"no model installed. Run: linflow download {ModelCatalog.DefaultModelId}"
                : $"{other.Id} is a Whisper model; this build binds Parakeet only. " +
                  $"Run: linflow download {ModelCatalog.DefaultModelId}");
        }
        return new ParakeetEngine(ModelCatalog.PathFor(model));
    }

    private static int Transcribe(string[] args)
    {
        if (args.Length < 2) { Console.Error.WriteLine("transcribe needs a wav file"); return 1; }
        var samples = AudioIO.ReadWav(args[1]);
        using var engine = OpenDefaultEngine();
        var r = engine.Transcribe(samples);
        var cleaned = new TextCleaner().Clean(r.Text);
        Console.WriteLine($"\naudio {r.AudioSeconds:F1}s -> {r.InferenceSeconds:F2}s " +
                          $"({r.AudioSeconds / Math.Max(r.InferenceSeconds, 0.001):F0}x realtime)");
        Console.WriteLine($"\nraw:     {r.Text}");
        Console.WriteLine($"cleaned: {cleaned}");
        return 0;
    }

    private static int Bench(string[] args)
    {
        if (args.Length < 2) { Console.Error.WriteLine("bench needs a wav file"); return 1; }
        var samples = AudioIO.ReadWav(args[1]);
        var at = Array.IndexOf(args, "--threads");
        var threads = at > 0 && at + 1 < args.Length && int.TryParse(args[at + 1], out var n)
            ? n : ParakeetEngine.DefaultThreads;
        using var engine = OpenDefaultEngine();
        Console.WriteLine($"loaded in {engine.LoadSeconds:F2}s; {samples.Length / (double)AudioIO.SampleRate:F1}s of audio, {threads} threads\n");
        engine.Transcribe(samples, threads);        // warm
        var times = new List<double>();
        for (var i = 0; i < 3; i++)
        {
            var sw = Stopwatch.StartNew();
            engine.Transcribe(samples, threads);
            times.Add(sw.Elapsed.TotalSeconds);
            Console.WriteLine($"  run {i + 1}: {times[^1]:F3}s");
        }
        Console.WriteLine($"\nbest {times.Min():F3}s  median {times.OrderBy(t => t).ElementAt(1):F3}s");
        return 0;
    }

    /// The Mac's `mic-test`: one second from the default input, opened the way a dictation opens
    /// it, then which device it was, how long its first audio took, and whether it sent anything.
    /// The last line is Windows-only: how long Stop() kept the caller waiting, and how long the
    /// device then took to close behind it - the 0.3 s a dictation used to spend before it could
    /// start transcribing.
    private static int MicTest()
    {
        var recorder = new Recorder();
        try { recorder.Start(); }
        catch (Exception e) { Console.Error.WriteLine(e.Message); return 1; }
        Thread.Sleep(1000);
        var stopping = Stopwatch.StartNew();
        var samples = recorder.Stop();
        var stopped = stopping.Elapsed.TotalSeconds;
        recorder.Closed.Wait(TimeSpan.FromSeconds(5));

        if (recorder.LastTake is { } take) Console.WriteLine(take.Describe("asking"));
        Console.WriteLine($"{samples.Length / (double)AudioIO.SampleRate:F2}s of audio, peak {AudioIO.Peak(samples):F4}");
        Console.WriteLine(Microphone.IsDead(samples, AudioIO.SampleRate)
            ? "dead: pure digital silence, the device is sending nothing" : "live");
        Console.WriteLine($"stop returned in {stopped:F3}s; closing the device then took {recorder.CloseSeconds ?? double.NaN:F3}s");
        return 0;
    }

    /// What an edit would teach the dictionary: the Mac's learn-test. A dry run unless --apply,
    /// which runs it through the learning setting into the real dictionary.
    private static int LearnTest(string[] args)
    {
        if (args.Length < 3)
        {
            Console.Error.WriteLine("learn-test needs the text as pasted and the text as it reads now");
            return 1;
        }
        Log.EchoToConsole = false;
        var wrote = args[1];
        var now = args[2];
        var scored = LearnedCorrections.Scored(wrote, now, Glossary.LoadReplacements());
        if (scored.Count == 0)
        {
            if (CorrectionLearning.LonePair(wrote, now) is { } pair)
                Console.WriteLine(CorrectionLearning.WorthShowing(pair.From, pair.To)
                    ? $"{pair.From} => {pair.To}   [neither tier took it; offered on screen, added by a click]"
                    : $"{pair.From} => {pair.To}   [neither tier took it, and it is not worth a pop-up: logged only]");
            else
                Console.WriteLine("nothing to learn from that edit");
        }
        foreach (var s in scored)
            Console.WriteLine($"{s.Replacement.From} => {s.Replacement.To}"
                + (s.Confidence == LearnedCorrections.Confidence.Suggest ? "   [offered only; needs a click in the Dictionary]" : ""));
        if (!args.Contains("--apply"))
        {
            Console.Error.WriteLine("[dry run; pass --apply to add these to the dictionary]");
            return 0;
        }
        var mode = LearnSettings.Load();
        var outcome = CorrectionLearning.Handle(wrote, now, mode);
        Console.Error.WriteLine($"[mode {LearnSettings.Name(mode)}: added {outcome.Added.Count}, suggested {outcome.Suggested.Count}]");
        return 0;
    }

    /// Whether the app in front lets its text field be read, which learning from an edit in
    /// place depends on: the Mac's focus-test. Run from a terminal, the terminal is the app in
    /// front, so --wait gives time to click into the field that matters first.
    private static int FocusTest(string[] args)
    {
        var i = Array.IndexOf(args, "--wait");
        var wait = i > 0 && i + 1 < args.Length && double.TryParse(args[i + 1], out var w) ? w : 0;
        if (wait > 0)
        {
            Console.WriteLine($"click into a text field; looking in {wait:0.#}s");
            Thread.Sleep(TimeSpan.FromSeconds(wait));
        }
        var reader = FieldReader.TryCreate(out var why);
        if (reader is null)
        {
            Console.Error.WriteLine(why);
            return 1;
        }
        var (pid, app) = FieldReader.ForegroundApp();
        Console.WriteLine($"app in front: {app} (pid {pid})");
        // Chromium builds its tree once something asks for it, and not at once: asked cold,
        // Chrome answers with its window's bare pane, which has no text. So keep looking until
        // the focused element has some, the way the readback's early looks do.
        var looked = 0.0;
        var seen = false;
        foreach (var at in new[] { 0.0, 0.6, 1.5, 3.0, 5.0 })
        {
            Thread.Sleep(TimeSpan.FromSeconds(at - looked));
            looked = at;
            using var found = reader.Focused();
            if (found is null) continue;
            seen = true;
            var text = reader.Text(found);
            var owner = reader.ProcessId(found) is { } o && o != pid ? $", in pid {o}" : "";
            Console.WriteLine($"after {(int)(at * 1000)}ms: {reader.Describe(found)}{owner}: "
                + (text is null ? "no readable text" : $"{text.Length} characters"));
            if (text is null) continue;
            Console.WriteLine("readable: yes, an edit in this field can be learned");
            return 0;
        }
        Console.WriteLine(seen
            ? "no readable text after 5s: an app that hides its text, or more than 200,000 characters"
            : "no focused element after 5s, or it is a password field: an edit in this app cannot be learned");
        return 0;
    }

    private static int Models()
    {
        foreach (var m in ModelCatalog.Known)
            Console.WriteLine($"  {(ModelCatalog.IsUsable(m) ? "[installed]" : ModelCatalog.IsInstalled(m) ? "[present]  " : "           ")} " +
                              $"{m.Id,-30} {m.SizeMB,5} MB  {m.Note}");
        return 0;
    }

    private static int Download(string[] args)
    {
        var id = args.Length > 1 ? args[1] : ModelCatalog.DefaultModelId;
        var m = ModelCatalog.Find(id);
        if (m is null) { Console.Error.WriteLine($"unknown model {id}"); return 1; }
        if (ModelCatalog.IsInstalled(m)) { Console.WriteLine($"{m.Id} is already installed"); return 0; }

        Console.WriteLine($"downloading {m.FileName} ({m.SizeMB} MB) to {Paths.ModelsDir}");
        var last = -1;
        var progress = new Progress<double>(f =>
        {
            var pct = (int)(f * 100);
            if (pct == last) return;
            last = pct;
            Console.Write($"\r  {pct,3}%");
        });
        ModelCatalog.DownloadAsync(m, progress).GetAwaiter().GetResult();
        Console.WriteLine("\n  done");
        return 0;
    }
}
