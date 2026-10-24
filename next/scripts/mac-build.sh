#!/usr/bin/env bash
# Builds the Mac's Lin Flow Next: a cut-over build on the "Lin Flow" folder and Fn, signed with the
# "Lin Flow" identity so the Accessibility and Input Monitoring grants carry over from the last
# build. The Mac has run Next this way since 2026-10-23 (rebuild/architecture.md). A plain
# `npx tauri build` makes a build on the empty "Lin Flow Next" folder and Right Option instead.
#
#   bash next/scripts/mac-build.sh
#
# It builds only. Installing means quitting the running Next from its tray and opening the new
# `next/target/release/bundle/macos/Lin Flow Next.app`, which is John's call.
set -euo pipefail
cd "$(dirname "$0")/../app"
npm ci --silent
LINFLOW_APP_FOLDER="Lin Flow" npx tauri build --bundles app
app="../target/release/bundle/macos/Lin Flow Next.app"
# First time on a computer: the keychain asks to use the key. Always Allow.
codesign --force --deep --sign "Lin Flow" --identifier com.johnlin.linflow.next "$app"
codesign --verify "$app"
echo "Built and signed: $(cd "$(dirname "$app")" && pwd)/$(basename "$app")"
