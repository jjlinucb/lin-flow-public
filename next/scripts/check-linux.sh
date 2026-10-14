#!/bin/bash
# Lints the workspace for Linux from the Mac, as CI's Linux job does, minus the app, which needs
# WebKitGTK there. Nothing is linked: openssl-sys only reads Homebrew's headers, through clang.
# Needs `rustup target add x86_64-unknown-linux-gnu` once.
set -euo pipefail
cd "$(dirname "$0")/.."
export PATH=/opt/homebrew/opt/rustup/bin:$HOME/.cargo/bin:$PATH
export OPENSSL_DIR=/opt/homebrew/opt/openssl@3 CC_x86_64_unknown_linux_gnu=clang PKG_CONFIG_ALLOW_CROSS=1
cargo clippy --workspace --exclude lin-flow-next --all-targets --target x86_64-unknown-linux-gnu "$@" -- -D warnings
