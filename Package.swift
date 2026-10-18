// swift-tools-version:5.10
// Lin Flow — native macOS dictation app on whisper.cpp.
//
// Build with scripts/build_app.sh. With only the Command Line Tools it pins an
// SDK and the legacy build system, because a plain `swift build` fails on CLT 27;
// with Xcode.app installed it uses Xcode and needs neither.
//
// There is no test target: the Command Line Tools ship neither XCTest nor
// swift-testing. `LinFlow selftest` runs the unit checks instead.
//
// whisper.cpp itself comes from Homebrew (`brew install whisper-cpp`), which
// ships libwhisper + libggml prebuilt with the Metal backend. We link against
// the version-stable /opt/homebrew/opt/... symlinks so `brew upgrade` doesn't
// break the binary as long as the library major versions stay put.
//
// Homebrew renamed the formula to `whisper.cpp` at 1.9.5 (October 2026). A fresh install
// has only /opt/homebrew/opt/whisper.cpp, while a Mac that upgraded from whisper-cpp may
// still have only the old name. The manifest links whichever exists, the new name first.
// CI went red on 10-14 on runner images that installed the new name.
import Foundation
import PackageDescription

let brew = "/opt/homebrew"
let whisperLib = ["\(brew)/opt/whisper.cpp/lib", "\(brew)/opt/whisper-cpp/lib"]
    .first { FileManager.default.fileExists(atPath: $0) } ?? "\(brew)/opt/whisper.cpp/lib"
let brewLibDirs = [whisperLib, "\(brew)/opt/ggml/lib"]

let package = Package(
    name: "LinFlow",
    // Homebrew's whisper.cpp and ggml are built for macOS 26, and the summaries, running
    // notes and transforms need Apple Intelligence, which starts there too.
    platforms: [.macOS("26.0")],
    targets: [
        // C shim over Homebrew's whisper.h / ggml-backend.h.
        .systemLibrary(
            name: "CWhisper",
            path: "Sources/CWhisper"
        ),
        // Everything that doesn't need a window: engine, recorder, cleanup,
        // text injection, hotkey, settings, model downloads.
        .target(
            name: "LinFlowCore",
            dependencies: ["CWhisper"],
            path: "Sources/LinFlowCore",
            linkerSettings: [
                .unsafeFlags(brewLibDirs.map { "-L\($0)" }),
                .linkedLibrary("whisper"),
                .linkedLibrary("parakeet"),
                .linkedLibrary("ggml"),
                .linkedLibrary("ggml-base"),
            ]
        ),
        // The menu bar app + CLI entry point.
        .executableTarget(
            name: "LinFlow",
            dependencies: ["LinFlowCore"],
            path: "Sources/LinFlow"
        ),
    ],
    swiftLanguageVersions: [.v5]
)
