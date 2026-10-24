# Lin Flow Next on a Windows computer, from this repo.
#
#   powershell -ExecutionPolicy Bypass -File next\scripts\windows.ps1          # CI's build of main
#   powershell -ExecutionPolicy Bypass -File next\scripts\windows.ps1 -Source  # build it here
#
# Both pull main first. The default takes the build CI made from the newest green run on main
# (`windows-app` in .github/workflows/next.yml), so the computer needs only git and an
# authenticated `gh`. -Source builds it here instead, which needs Node, Rust and the MSVC Build
# Tools.
#
# Either way it runs `linflow doctor` from the new copy before it replaces anything, and refuses
# while Lin Flow Next is running: quit it from its tray icon first. It installs to
# %LOCALAPPDATA%\Programs\Lin Flow Next. The data stays in %APPDATA%\Lin Flow Next, beside the
# C# app's, and Right Alt stays its talk key until cut-over.

param(
    [switch]$Source,
    [string]$To = (Join-Path $env:LOCALAPPDATA 'Programs\Lin Flow Next'),
    [string]$Repo = 'jjlinucb/lin-flow-public'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if (Get-Process -Name 'lin-flow-next' -ErrorAction SilentlyContinue) {
    throw 'Lin Flow Next is running. Quit it from its tray icon, then run this again.'
}

git -C $root pull --ff-only
if ($LASTEXITCODE -ne 0) { throw 'git pull failed.' }

$stage = Join-Path $env:TEMP "lin-flow-next-$PID"
New-Item -ItemType Directory -Force (Join-Path $stage 'native') | Out-Null

if ($Source) {
    Push-Location (Join-Path $root 'next\app')
    npm ci; if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    npm run build; if ($LASTEXITCODE -ne 0) { throw 'The window did not build.' }
    Pop-Location
    Push-Location (Join-Path $root 'next')
    cargo build --release -p lin-flow-next -p linflow-cli
    if ($LASTEXITCODE -ne 0) { throw 'cargo build failed. Are the MSVC Build Tools installed?' }
    Pop-Location
    Copy-Item (Join-Path $root 'next\target\release\lin-flow-next.exe'), (Join-Path $root 'next\target\release\linflow.exe') $stage
    # whisper.cpp's DLLs, the same v1.9.1 release CI puts beside its build.
    $zip = Join-Path $stage 'whisper-bin-x64.zip'
    Invoke-WebRequest 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-bin-x64.zip' -OutFile $zip
    Expand-Archive $zip (Join-Path $stage 'whisper') -Force
    Copy-Item (Join-Path $stage 'whisper\Release\*.dll') (Join-Path $stage 'native')
    Remove-Item -Recurse -Force $zip, (Join-Path $stage 'whisper')
} else {
    $run = gh run list -R $Repo --workflow next --branch main --status success --limit 1 --json databaseId -q '.[0].databaseId'
    if (-not $run) { throw "No green run of the next workflow on main. Run it by hand: gh workflow run next -R $Repo --ref main" }
    gh run download $run -R $Repo -n lin-flow-next-windows -D $stage
    if ($LASTEXITCODE -ne 0) { throw "Run $run kept no Windows build. Builds last 30 days; run the workflow by hand for a new one." }
}

# The check on this computer, from the new copy, before anything is replaced.
& (Join-Path $stage 'linflow.exe') doctor
if ($LASTEXITCODE -ne 0) { Write-Warning 'doctor found problems above. Installing anyway; fix them before dictating.' }

New-Item -ItemType Directory -Force $To | Out-Null
Copy-Item -Recurse -Force (Join-Path $stage '*') $To
Remove-Item -Recurse -Force $stage
Write-Host "Installed to $To. Start it with: & '$To\lin-flow-next.exe'"
