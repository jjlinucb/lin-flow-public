#!/bin/bash
# Build Lin Flow and assemble dist/Lin Flow.app.
#
#   scripts/build_app.sh            release build -> dist/Lin Flow.app
#   scripts/build_app.sh --debug    debug build
#   scripts/build_app.sh --install  also replace /Applications/Lin Flow.app and reopen it
#   scripts/build_app.sh --adhoc    ad-hoc signature (no keychain prompt; permissions won't persist across rebuilds)
#   scripts/build_app.sh --selftest run the selftest on the new binary first; a failure stops
#                                   everything, so a build that fails it is never installed
#
# --require-identity  stop before building unless the keychain has the "Lin Flow" identity. An
#                     ad-hoc build loses the Accessibility and microphone grants, so a background
#                     update (scripts/fleet.sh) keeps the old app rather than install one. Exits 4.
#
# --install will not quit Lin Flow while it records a meeting note, and with
# LINFLOW_INSTALL_IDLE_SECONDS=N it also waits for N seconds without keyboard or mouse input. Either
# one exits 3 with nothing installed. scripts/fleet.sh relies on both, since a build takes minutes
# and those checks have to hold at the moment the app quits, not before the build began.
#
# Needs `brew install whisper-cpp` and either Xcode.app, which is used when it is ready, or
# the Command Line Tools with a macOS 26 SDK.
#
# Signing: if the keychain has a code-signing identity named "Lin Flow"
# (a self-signed cert made in Keychain Access), the bundle is signed with it.
# That identity is what the Accessibility / Microphone grants are tied to,
# so a rebuild keeps them. Without it we fall back to ad-hoc signing, which
# means re-granting permissions after every rebuild.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG=release
INSTALL=0
ADHOC=0
SELFTEST=0
REQUIRE_IDENTITY=0
for arg in "$@"; do
    case "$arg" in
        --debug) CONFIG=debug ;;
        --install) INSTALL=1 ;;
        --adhoc) ADHOC=1 ;;
        --selftest) SELFTEST=1 ;;
        --require-identity) REQUIRE_IDENTITY=1 ;;
        *) echo "unknown option: $arg" >&2; exit 2 ;;
    esac
done

if [ "$REQUIRE_IDENTITY" = 1 ]; then
    if [ "$ADHOC" = 1 ]; then echo "--require-identity and --adhoc contradict each other" >&2; exit 2; fi
    if ! security find-identity -v -p codesigning 2>/dev/null | grep -q '"Lin Flow"'; then
        echo "No \"Lin Flow\" signing identity in the keychain, so nothing was built or installed: an ad-hoc app would lose its Accessibility and microphone grants." >&2
        exit 4
    fi
fi

# Homebrew renamed the formula to whisper.cpp at 1.9.5; an older install keeps whisper-cpp.
if [ ! -f /opt/homebrew/opt/whisper.cpp/lib/libwhisper.dylib ] && [ ! -f /opt/homebrew/opt/whisper-cpp/lib/libwhisper.dylib ]; then
    echo "whisper.cpp not found. Run: brew install whisper-cpp" >&2
    exit 1
fi

# Xcode.app, when it is installed and its license accepted, needs none of what follows: its
# toolchain has the SwiftUI macro plugins and the default build system works. GitHub's
# runners build with plain `swift build` for that reason.
BUILD_FLAGS=()
XCODE_DEV=/Applications/Xcode.app/Contents/Developer
if [ -d "$XCODE_DEV" ] && DEVELOPER_DIR="$XCODE_DEV" xcrun swift --version >/dev/null 2>&1; then
    export DEVELOPER_DIR="$XCODE_DEV"
    echo "==> building with Xcode ($XCODE_DEV)"
else
    [ -d "$XCODE_DEV" ] && echo "!!  Xcode.app is installed but not ready (accept its license once: sudo xcodebuild -license accept); using the Command Line Tools" >&2
    # Command Line Tools 27 broke this target two ways. The default build system (XCBuild)
    # cannot even initialize without Xcode.app ("Unknown error parsing property list"), and the
    # macOS 27 SDK turns SwiftUI's @State into a macro whose plugin only Xcode ships, so every
    # view fails with "SwiftUIMacros.StateMacro could not be found". Pin the newest installed SDK
    # that still has @State as a property wrapper, and use the legacy build system, which
    # SwiftPM now warns it will remove. Installing Xcode.app is the way off both.
    for candidate in MacOSX26.5.sdk MacOSX26.sdk; do
        SDK_PATH="/Library/Developer/CommandLineTools/SDKs/$candidate"
        if [ -d "$SDK_PATH" ]; then
            BUILD_FLAGS=(--build-system native -Xswiftc -sdk -Xswiftc "$SDK_PATH")
            echo "==> Command Line Tools: pinning $candidate and the legacy build system"
            break
        fi
    done
    [ ${#BUILD_FLAGS[@]} -gt 0 ] || { echo "!!  no macOS 26 SDK found; install Xcode.app, or this target will not compile" >&2; BUILD_FLAGS=(--build-system native); }
fi

echo "==> swift build -c $CONFIG"
# set -e stops here on a failed compile, which matters: the previous binary is still in
# .build and must not be packaged as if it were this one.
# ${arr[@]+...}: macOS's bash 3.2 calls an empty array unbound under set -u.
swift build ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} -c "$CONFIG"
BIN=".build/$CONFIG/LinFlow"
[ -x "$BIN" ] || { echo "build produced no binary at $BIN" >&2; exit 1; }

# Before anything is packaged, so a binary that fails its checks never replaces the one John
# dictates with. scripts/fleet.sh passes this on every update. The selftest points itself at a
# temp data folder and its own defaults domain, never his.
if [ "$SELFTEST" = 1 ]; then
    echo "==> selftest"
    "$BIN" selftest || { echo "selftest failed, so nothing was packaged or installed" >&2; exit 1; }
fi

APP="dist/Lin Flow.app"
echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/LinFlow"
cp assets/Info.plist "$APP/Contents/Info.plist"
cp assets/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
printf 'APPL????' > "$APP/Contents/PkgInfo"
# Stamp the build so `Get Info` tells builds apart.
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(date +%Y%m%d.%H%M)" "$APP/Contents/Info.plist"
# And with the commit it was built from, which scripts/fleet.sh reads back to tell whether this
# Mac runs the newest app. The Windows build carries its commit in its version the same way.
# A tree with uncommitted changes is marked, since no commit reproduces it.
if COMMIT=$(git rev-parse HEAD 2>/dev/null); then
    git diff --quiet HEAD -- 2>/dev/null || COMMIT="$COMMIT-dirty"
    /usr/libexec/PlistBuddy -c "Add :LinFlowCommit string $COMMIT" "$APP/Contents/Info.plist"
fi

IDENTITY="-"
if [ "$ADHOC" = 0 ] && security find-identity -v -p codesigning 2>/dev/null | grep -q '"Lin Flow"'; then
    IDENTITY="Lin Flow"
    echo "==> codesign with the \"Lin Flow\" identity (first time: click Always Allow in the keychain prompt)"
elif [ "$REQUIRE_IDENTITY" = 1 ]; then
    echo "The \"Lin Flow\" signing identity went missing during the build, so nothing was installed." >&2
    exit 4
else
    echo "==> codesign ad-hoc"
fi
codesign --force --deep --sign "$IDENTITY" --identifier com.johnlin.linflow "$APP"
codesign --verify --verbose=1 "$APP"
codesign -d -r- "$APP" 2>&1 | grep designated || true

if [ "$INSTALL" = 1 ]; then
    DEST="/Applications/Lin Flow.app"
    echo "==> installing to /Applications"
    # Only the installed app, matched on its exact command line. `pkill -x LinFlow` also killed
    # every CLI run in progress, which shares the process name, and the app stayed down until
    # somebody opened it again. SIGTERM goes through the app's own quit, which finishes an open
    # meeting note and frees the model, so give it time rather than force it.
    RUNNING=$(pgrep -xf "$DEST/Contents/MacOS/LinFlow" || true)
    if [ -n "$RUNNING" ]; then
        # While it runs, a note with no end is the one it is recording. Quitting would end it
        # mid-meeting. The same test as fleet.sh and install-latest.ps1.
        for json in "${LINFLOW_DATA_DIR:-$HOME/Library/Application Support/Lin Flow}"/notes/*/note.json; do
            [ -f "$json" ] || continue
            if ! grep -Eq '"endedAt"[[:space:]]*:[[:space:]]*[^[:space:]n]' "$json"; then
                echo "Lin Flow is recording a meeting note ($(basename "$(dirname "$json")")), so nothing was installed. Run this again once it has ended: $APP is built." >&2
                exit 3
            fi
        done
        if [ -n "${LINFLOW_INSTALL_IDLE_SECONDS:-}" ]; then
            IDLE=$(ioreg -c IOHIDSystem | awk '/HIDIdleTime/ { print int($NF / 1000000000); exit }')
            if ! [[ "$IDLE" =~ ^[0-9]+$ ]] || [ "$IDLE" -lt "$LINFLOW_INSTALL_IDLE_SECONDS" ]; then
                echo "This Mac was in use ${IDLE:-?} s ago, so nothing was installed: $APP is built." >&2
                exit 3
            fi
        fi
        echo "    quitting the installed Lin Flow (pid $RUNNING)"
        kill -TERM $RUNNING
        for _ in $(seq 1 60); do kill -0 $RUNNING 2>/dev/null || break; sleep 0.25; done
        if kill -0 $RUNNING 2>/dev/null; then
            echo "Lin Flow did not quit within 15 s, so nothing was installed. Quit it from its menu and run this again." >&2
            exit 1
        fi
    fi
    rm -rf "$DEST"
    cp -R "$APP" "$DEST"
    open "$DEST"
    echo "    installed and reopened"
else
    echo
    echo "Done: $APP"
    echo "Install with:  scripts/build_app.sh --install   (or drag it into /Applications)"
fi
