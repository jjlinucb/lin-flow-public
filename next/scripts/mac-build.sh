#!/usr/bin/env bash
# Builds the Mac's Lin Flow: Next as a cut-over build, named "Lin Flow", on the "Lin Flow" data
# folder and Fn, signed with the "Lin Flow" identity so the Accessibility and Input Monitoring
# grants carry over from the last build. The Mac has run Next this way since 2026-10-23
# (rebuild/architecture.md). A plain `npx tauri build` makes "Lin Flow Next" on the empty
# "Lin Flow Next" folder and Right Option instead.
#
#   bash next/scripts/mac-build.sh             # build and sign only
#   bash next/scripts/mac-build.sh --install   # then put it in /Applications as Lin Flow.app
#
# --install interrupts John's dictation, so only when he asks. It refuses while Lin Flow is
# running (quit it from its menu bar icon) and refuses to replace anything in /Applications that
# is not Next, such as the Swift app, which is moved to the Trash by hand if ever it comes back.
# The bundle keeps Next's identifier, com.johnlin.linflow.next, which is what the grants are for.
set -euo pipefail
install=0
[[ "${1:-}" == "--install" ]] && install=1

cd "$(dirname "$0")/../app"
npm ci --silent
LINFLOW_APP_FOLDER="Lin Flow" npx tauri build --bundles app --config '{"productName":"Lin Flow"}'
app="$(cd ../target/release/bundle/macos && pwd)/Lin Flow.app"
# First time on a computer: the keychain asks to use the key. Always Allow.
codesign --force --deep --sign "Lin Flow" --identifier com.johnlin.linflow.next "$app"
codesign --verify "$app"
echo "Built and signed: $app"
[[ $install == 1 ]] || exit 0

dest="/Applications/Lin Flow.app"
if pgrep -f "Lin Flow.app/Contents/MacOS/lin-flow-next|Lin Flow Next.app/Contents/MacOS/lin-flow-next" > /dev/null; then
    echo "Lin Flow is running. Quit it from its menu bar icon, then run this again." >&2
    exit 1
fi
if [[ -d "$dest" ]]; then
    id=$(defaults read "$dest/Contents/Info.plist" CFBundleIdentifier 2>/dev/null || true)
    if [[ "$id" != "com.johnlin.linflow.next" ]]; then
        echo "$dest is $id, not Next. Not replacing it." >&2
        exit 1
    fi
fi
# Copied beside it and checked first, so a failed copy never leaves him without an app.
ditto "$app" "$dest.new"
codesign --verify "$dest.new"
rm -rf "$dest"
mv "$dest.new" "$dest"
open "$dest"
echo "Installed and opened: $dest"
