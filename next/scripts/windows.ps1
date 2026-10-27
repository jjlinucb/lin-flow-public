# Lin Flow on a Windows computer, from this repo. Run it once per computer; after that, Update in
# Settings brings each new build (WINDOWS.md).
#
#   powershell -ExecutionPolicy Bypass -File next\scripts\windows.ps1          # CI's build of main
#   powershell -ExecutionPolicy Bypass -File next\scripts\windows.ps1 -Source  # build it here
#   powershell -ExecutionPolicy Bypass -File next\scripts\windows.ps1 -Zip <path to lin-flow-windows.zip>
#
# The first two pull main first. The default takes the build CI made from the newest green run on
# main (`windows-app` in .github/workflows/next.yml), so the computer needs only git and an
# authenticated `gh`. -Source builds it here instead, which needs Node, Rust and the MSVC Build
# Tools. -Zip installs a zip already on the computer, such as the release's.
#
# Either way it runs `linflow doctor` from the new copy before it replaces anything, and refuses
# while Lin Flow is running: quit it from its tray icon first. It installs to
# %LOCALAPPDATA%\Programs\Lin Flow, on the data in %APPDATA%\Lin Flow.
#
# The first time on a computer that ran Lin Flow Next beside the C# app, it also cuts over: the
# C# app's folders, if any are left, are renamed "... (C# app)", never deleted, and
# %APPDATA%\Lin Flow Next becomes %APPDATA%\Lin Flow, keeping its history, dictionary, settings
# (the talk key among them) and sync.env. The Start menu and Startup shortcuts become "Lin Flow".

param(
    [switch]$Source,
    [string]$Zip,
    [string]$To = (Join-Path $env:LOCALAPPDATA 'Programs\Lin Flow'),
    [string]$Repo = 'jjlinucb/lin-flow-public'
)

$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path

if (Get-Process -Name 'lin-flow', 'lin-flow-next' -ErrorAction SilentlyContinue) {
    throw 'Lin Flow is running. Quit it from its tray icon, then run this again.'
}
if (Get-Process -Name 'LinFlow*' -ErrorAction SilentlyContinue) {
    throw 'The C# Lin Flow is running. Quit it from its tray icon, then run this again.'
}

$stage = Join-Path $env:TEMP "lin-flow-$PID"
New-Item -ItemType Directory -Force (Join-Path $stage 'native') | Out-Null

if ($Zip) {
    Expand-Archive $Zip $stage -Force
    foreach ($folder in 'lin-flow-windows', 'lin-flow-next-windows') {
        $inner = Join-Path $stage $folder
        if (Test-Path $inner) { Get-ChildItem $inner | Move-Item -Destination $stage -Force; Remove-Item $inner }
    }
} else {
    git -C $root pull --ff-only
    if ($LASTEXITCODE -ne 0) { throw 'git pull failed.' }
}

if ($Source) {
    npm --prefix (Join-Path $root 'next\app') ci
    if ($LASTEXITCODE -ne 0) { throw 'npm ci failed.' }
    # The same build CI makes: a cut-over build named Lin Flow, with the window inside it.
    $env:LINFLOW_APP_FOLDER = 'Lin Flow'
    Push-Location (Join-Path $root 'next\app')
    try {
        npx tauri build --no-bundle --config src-tauri/tauri.windows-lin-flow.json
        if ($LASTEXITCODE -ne 0) { throw 'tauri build failed. Are the MSVC Build Tools installed?' }
        cargo build --release -p linflow-cli
        if ($LASTEXITCODE -ne 0) { throw 'cargo build of linflow failed.' }
    } finally { Pop-Location }
    Copy-Item (Join-Path $root 'next\target\release\lin-flow-next.exe') (Join-Path $stage 'lin-flow.exe')
    Copy-Item (Join-Path $root 'next\target\release\linflow.exe') $stage
    # whisper.cpp's DLLs, the same v1.9.1 release CI puts beside its build.
    $wz = Join-Path $stage 'whisper-bin-x64.zip'
    Invoke-WebRequest 'https://github.com/ggml-org/whisper.cpp/releases/download/v1.9.1/whisper-bin-x64.zip' -OutFile $wz
    Expand-Archive $wz (Join-Path $stage 'whisper') -Force
    Copy-Item (Join-Path $stage 'whisper\Release\*.dll') (Join-Path $stage 'native')
    Remove-Item -Recurse -Force $wz, (Join-Path $stage 'whisper')
} elseif (-not $Zip) {
    $run = gh run list -R $Repo --workflow next --branch main --status success --limit 1 --json databaseId -q '.[0].databaseId'
    if ($LASTEXITCODE -ne 0) { throw 'gh could not list the runs. Is gh installed and signed in (gh auth login)?' }
    if (-not $run) { throw "No green run of the next workflow on main. Run it by hand: gh workflow run next -R $Repo --ref main" }
    gh run download $run -R $Repo -n lin-flow-windows -D $stage
    if ($LASTEXITCODE -ne 0) { throw "Run $run kept no Windows build. Builds last 30 days; run the workflow by hand for a new one." }
}

if (-not (Test-Path (Join-Path $stage 'lin-flow.exe'))) { throw "No lin-flow.exe in $stage. Is this a Lin Flow build from 2026-10-27 or later?" }

# The cut-over, once per computer. Renames only; nothing is deleted.
$data = Join-Path $env:APPDATA 'Lin Flow'
$nextData = Join-Path $env:APPDATA 'Lin Flow Next'
if (Test-Path $nextData) {
    if (Test-Path $data) {
        Rename-Item $data 'Lin Flow (C# app)'
        Write-Host "The C# app's data is now $env:APPDATA\Lin Flow (C# app)."
    }
    Rename-Item $nextData 'Lin Flow'
    Write-Host "Lin Flow Next's data is now $data."
}
if ((Test-Path $To) -and -not (Test-Path (Join-Path $To 'lin-flow.exe'))) {
    Rename-Item $To 'Lin Flow (C# app)'
    Write-Host "The C# app's install is now $(Split-Path $To)\Lin Flow (C# app)."
}

# The check on this computer, from the new copy, before anything is replaced.
& (Join-Path $stage 'linflow.exe') doctor
if ($LASTEXITCODE -ne 0) { Write-Warning 'doctor found problems above. Installing anyway; fix them before dictating.' }

New-Item -ItemType Directory -Force $To | Out-Null
Copy-Item -Recurse -Force (Join-Path $stage '*') $To
Remove-Item -Recurse -Force $stage
$exe = Join-Path $To 'lin-flow.exe'

# Shortcuts named Lin Flow in the Start menu and Startup, and none left for Lin Flow Next.
$programs = [Environment]::GetFolderPath('Programs')
$startup = [Environment]::GetFolderPath('Startup')
$shell = New-Object -ComObject WScript.Shell
foreach ($dir in $programs, $startup, [Environment]::GetFolderPath('Desktop')) {
    Remove-Item (Join-Path $dir 'Lin Flow Next.lnk') -ErrorAction SilentlyContinue
}
foreach ($dir in $programs, $startup) {
    $lnk = $shell.CreateShortcut((Join-Path $dir 'Lin Flow.lnk'))
    $lnk.TargetPath = $exe
    $lnk.WorkingDirectory = $To
    $lnk.Description = 'Lin Flow'
    $lnk.Save()
}

$old = Join-Path $env:LOCALAPPDATA 'Programs\Lin Flow Next'
if (Test-Path $old) { Write-Host "The old install at $old is no longer used. Delete it once Lin Flow works." }
Write-Host "Installed to $To. Start it from the Start menu, or: & '$exe'"
Write-Host 'A taskbar pin of Lin Flow Next points at the old copy: unpin it and pin Lin Flow.'
