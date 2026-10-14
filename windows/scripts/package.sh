#!/usr/bin/env bash
# Builds the Windows zip. Runs on the Mac: .NET builds Windows Desktop apps anywhere as long as
# EnableWindowsTargeting is set (see Directory.Build.props). Only *running* them needs Windows.
set -euo pipefail
cd "$(dirname "$0")/.."
export DOTNET_ROOT="${DOTNET_ROOT:-$HOME/.dotnet}"
export PATH="$DOTNET_ROOT:$PATH"
export DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1

OUT=dist/LinFlow
rm -rf dist && mkdir -p "$OUT"

# Each project publishes to its own folder first. Publishing two projects straight into one
# shared -o directory drops one of the exes.
for proj in LinFlow.App LinFlow.Cli; do
    dotnet publish "$proj/$proj.csproj" -c Release -r win-x64 --self-contained false \
        -o "dist/stage-$proj" >/dev/null
    cp -R "dist/stage-$proj/." "$OUT/"
done
rm -rf dist/stage-*

if [ ! -d native/Release ]; then
    echo "native/Release missing - run scripts/fetch-native.sh first" >&2; exit 1
fi
cp native/Release/parakeet.dll native/Release/ggml.dll native/Release/ggml-base.dll "$OUT/"
cp native/Release/ggml-cpu*.dll "$OUT/"
# The shortcut install.ps1 makes points its icon at this file rather than at the exe. The exe
# carries the same icon, but Windows caches a shortcut's icon by source path, so pointing at a
# path it has not seen is what makes a changed icon actually appear.
cp LinFlow.App/lin-flow.ico "$OUT/"
cp README-WINDOWS.md "$OUT/README.txt"
cp scripts/install.ps1 "$OUT/"

test -f "$OUT/LinFlow.exe"      || { echo "LinFlow.exe missing"      >&2; exit 1; }
test -f "$OUT/linflow-cli.exe"  || { echo "linflow-cli.exe missing"  >&2; exit 1; }
test -f "$OUT/parakeet.dll"     || { echo "parakeet.dll missing"     >&2; exit 1; }

(cd dist && zip -qr "LinFlow-windows-x64.zip" LinFlow)
echo "dist/LinFlow-windows-x64.zip  $(du -h dist/LinFlow-windows-x64.zip | cut -f1)"
