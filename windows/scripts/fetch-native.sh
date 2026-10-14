#!/usr/bin/env bash
# The whisper.cpp v1.9.1 Windows binaries: parakeet.dll, ggml*.dll and the per-CPU backends.
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p native
URL=https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-bin-x64.zip
[ -f native/whisper-bin-x64.zip ] || curl -sSL -o native/whisper-bin-x64.zip "$URL"
(cd native && unzip -o -q whisper-bin-x64.zip)
echo "native/Release ready: $(ls native/Release/*.dll | wc -l | tr -d ' ') dlls"
