#!/bin/bash
# Checks that the whole workspace compiles for Windows, from the Mac. No C is built for the
# target; the app's resource step gets an empty stand-in (fake-rc.sh), since only a check runs.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
export RC_x86_64_pc_windows_msvc="$PWD/scripts/fake-rc.sh"
cargo check --workspace --target x86_64-pc-windows-msvc "$@"
