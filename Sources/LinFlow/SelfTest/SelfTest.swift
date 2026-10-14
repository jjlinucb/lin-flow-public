import Foundation
import LinFlowCore

/// Unit checks for the pieces that don't need a microphone. Run with
/// `LinFlow selftest`; exits non-zero on the first failure count > 0.
enum SelfTest {
    private static var failures = 0
    private static var checks = 0

    static func expect(_ got: String, _ want: String, _ label: String = #line.description) {
        checks += 1
        if got != want {
            failures += 1
            print("FAIL [\(label)]\n   got:  \(got.debugDescription)\n   want: \(want.debugDescription)")
        }
    }

    static func expect(_ cond: Bool, _ label: String) {
        checks += 1
        if !cond { failures += 1; print("FAIL [\(label)]") }
    }

    /// Fixed inputs. No replacements: the checks run against these, never against whatever
    /// John's live dictionary happens to hold. `LinFlow selftest` also points the whole data
    /// folder at a temp directory before it gets here.
    static let glossary = ["John Lin", "Lin Flow", "Wispr Flow", "Parakeet", "whisper.cpp", "WORKBRAIN", "Claude", "Claude Code", "GitHub"]
    static let cleaner = TextCleaner(glossary: glossary, replacements: [])

    static func run() -> Int32 {
        expect(!ModelCatalog.appSupportDir.path.hasSuffix("Application Support/Lin Flow"),
               "selftest: reads a temp data folder, not the live one")
        expect(GlossaryMatcher.englishWords.count > 100_000,
               "selftest: the system word list loaded (the guards are inert without it)")
        cleanup()
        learning()
        notes()
        audio()
        app()
        hotkey()
        sync()
        dictionary()
        print(failures == 0 ? "selftest: \(checks) checks passed" : "selftest: \(failures) of \(checks) checks FAILED")
        return failures == 0 ? 0 : 1
    }
}
