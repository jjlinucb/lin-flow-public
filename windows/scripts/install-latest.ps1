# Install the newest Lin Flow from the share onto this Windows machine.
#
#   powershell -ExecutionPolicy Bypass -File \\fileserver\share\lin-flow\install-latest.ps1
#
# release.ps1 copies this file to the root of the share, so the machine being installed onto
# needs nothing but the share. It fetches the zip, extracts it locally and hands over to the
# package's own install.ps1, which does the .NET runtime, the model and the shortcut.
#
# It installs locally rather than running from the share on purpose. The package is only 13 MB,
# so this is not about speed: it is that the share is not always there. Lin Flow starts at login
# and sits in the tray all day, and an app whose exe disappears when the VPN drops or the machine
# is off the network is worse than a copy that is occasionally a version behind.
#
# A running Lin Flow is closed only for the swap. Until 2026-09-25 this script closed it first,
# then fetched, unpacked and ran setup, and each install on DESK-01 kept it down for close to a
# minute. The fetch was never the slow part: PowerShell's script log put the close, the fetch, the
# unpack and the copy at 2.7 s together. The time went to the new build's first run. The virus
# scanner on these machines holds up a binary it has not seen the first time it runs, measured at
# 11 to 12 s a file, and remembers the verdict by the file's contents rather than its path. About
# six files change per release, and setup's doctor was the first thing to run them, with Lin Flow
# already closed. So the new build now runs doctor from the staging folder while the old copy is
# still up. That is also the check that it works on this machine at all. Only then is the old copy
# closed, the files swapped and Lin Flow started again, with setup after it. LinFlow.exe itself can
# be run only by starting it, and a second copy finds the running one and raises its window, so
# the scanner's first look at it still falls inside the swap. It is new each release only because
# the build stamps the commit into every binary: windows/NOTES.md (2026-09-25) has the fix.

param(
    # The UNC path, not R:. Northwind maps the same share to different letters on different
    # machines - it is R: on the laptop - so a drive letter here would work on exactly one
    # machine, which is the one that does not need this script.
    [string]$Share = '\\fileserver\share\lin-flow',
    [string]$To = (Join-Path $env:LOCALAPPDATA 'Programs\Lin Flow'),
    [string]$Release = 'latest',
    # Install even when the new build fails its check here. Lin Flow is closed first, and setup,
    # which fetches a missing runtime or model, runs before it is started again.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# Seconds since the start, beside each step, so a slow install says which step was slow.
$clock = [Diagnostics.Stopwatch]::StartNew()
function Step([string]$what, [string]$color = 'Cyan') {
    Write-Host ('{0,6:F1} s  {1}' -f $clock.Elapsed.TotalSeconds, $what) -ForegroundColor $color
}

# Refuse to install from inside another app's filesystem container.
# The same check sits at the top of install.ps1 and install-latest.ps1, and the two copies
# must match: each script has to stand alone (install-latest.ps1 is one file on a share).
#
# Some desktop apps are packaged (MSIX), and a terminal opened inside one - the Claude app's is
# the case that bit - does not see the real %APPDATA% and %LOCALAPPDATA%. Writes there are
# silently redirected into that app's private LocalCache. Everything then looks fine from inside
# the terminal: the model downloads, doctor passes, the app even runs if launched from there.
# But Lin Flow started the normal way - the desktop shortcut, the taskbar pin, the Startup
# folder - reads the real folders, finds no model and no settings, and sits at "no model" on the
# default key.
#
# That happened on the laptop, LAPTOP-02, and went unnoticed for five days, because every Lin Flow
# launched during that time was launched from inside the same container. Found 2026-09-23 when
# John started it from the taskbar and it would not dictate.
#
# Package identity is not a usable test: that terminal reported none (GetCurrentPackageFullName
# returned APPMODEL_ERROR_NO_PACKAGE) while its AppData was plainly redirected. So this tests the
# failure itself. Write a marker through %APPDATA% and look for it in every package's LocalCache.
# Outside a container it lands only in the real folder.

function Assert-RealAppData {
    $tag = [guid]::NewGuid().ToString('N').Substring(0, 8)
    $probe = Join-Path $env:APPDATA "linflow-vprobe-$tag.txt"
    try { 'x' | Set-Content $probe -Encoding ascii -ErrorAction Stop } catch { return }
    $hit = Get-ChildItem "$env:LOCALAPPDATA\Packages\*\LocalCache\Roaming\linflow-vprobe-$tag.txt" `
        -ErrorAction SilentlyContinue | Select-Object -First 1
    Remove-Item $probe -Force -ErrorAction SilentlyContinue
    if (-not $hit) { return }

    $package = ($hit.FullName -split '\\Packages\\', 2)[1].Split('\')[0]
    Write-Host ""
    Write-Host "Stopped: this terminal is running inside another app's container ($package)." -ForegroundColor Red
    Write-Host ""
    Write-Host "Anything installed from here - Lin Flow itself, the 669 MB speech model, your settings -"
    Write-Host "would land in that app's private copy of AppData. Lin Flow started from the desktop"
    Write-Host "shortcut, the taskbar or at login would not see any of it, and would sit at 'no model'."
    Write-Host ""
    Write-Host "Run this again from an ordinary PowerShell window instead:" -ForegroundColor Yellow
    Write-Host "  Start menu -> type 'PowerShell' -> Windows PowerShell"
    Write-Host ""
    exit 2
}

# Every LINFLOW_ variable is a switch for test copies: another data folder, canned audio, no
# paste, replayed Ollama answers. Doctor and setup run in this shell, and they must look at John's
# own data folder. Lin Flow itself is started through Explorer, so it never sees them.
function Clear-TestSwitches {
    foreach ($switch in @(Get-ChildItem Env:LINFLOW_* -ErrorAction SilentlyContinue)) {
        Write-Host "Ignoring $($switch.Name), which is for test copies." -ForegroundColor Yellow
        Remove-Item "Env:$($switch.Name)"
    }
}

# Copies the zip into $stage and unpacks it there. Returns the folder holding the app.
function Get-Package([string]$zip, [string]$stage) {
    Copy-Item $zip $stage -Force
    # Expand-Archive's progress bar made the unpack 2.5 times slower here, 1.0 s against 0.4 s. It
    # is a module's function, which only the global preference reaches.
    $progress = $global:ProgressPreference
    $global:ProgressPreference = 'SilentlyContinue'
    try { Expand-Archive (Join-Path $stage (Split-Path $zip -Leaf)) $stage -Force }
    finally { $global:ProgressPreference = $progress }

    # The zip holds one folder, LinFlow. Take what is inside it rather than the folder itself,
    # so the install folder does not end up with a LinFlow\LinFlow inside it.
    $payload = Join-Path $stage 'LinFlow'
    if (-not (Test-Path $payload)) { throw "The zip did not contain a LinFlow folder" }
    # The three this script runs. The staged doctor checks the rest against the build's own list.
    foreach ($must in 'LinFlow.exe', 'linflow-cli.exe', 'install.ps1') {
        if (-not (Test-Path (Join-Path $payload $must))) { throw "$must is missing from the package" }
    }
    $payload
}

# The Lin Flow running in this login session, if any: the one this script closes and starts again.
function Get-RunningLinFlow {
    $session = (Get-Process -Id $PID).SessionId
    @(Get-Process LinFlow -ErrorAction SilentlyContinue | Where-Object { $_.SessionId -eq $session })
}

# Why Lin Flow should not be closed and replaced right now, or $null. While it runs, a meeting note
# with no end is one it is recording: it closes every other one as it starts, and the copy started
# again would close that one too, with the rest of the meeting never recorded. And a Lin Flow
# program this script does not close, such as the tray's console meeting note or a copy in another
# session, holds the files the swap replaces, so the swap would fail halfway with Lin Flow closed.
function Get-Blocker([string]$to, [bool]$running) {
    if ($running) {
        foreach ($json in @(Get-ChildItem (Join-Path $env:APPDATA 'Lin Flow\notes\*\note.json') -ErrorAction SilentlyContinue)) {
            try { $note = Get-Content $json.FullName -Raw | ConvertFrom-Json } catch { continue }
            if (-not $note.endedAt) { return "Lin Flow is recording a meeting note ($($json.Directory.Name))" }
        }
    }
    $installed = [IO.Path]::GetFullPath($to).TrimEnd('\')
    $closing = @(Get-RunningLinFlow | ForEach-Object { $_.Id })
    foreach ($p in @(Get-Process LinFlow, linflow-cli -ErrorAction SilentlyContinue)) {
        if ($closing -notcontains $p.Id -and $p.Path -and (Split-Path $p.Path -Parent).TrimEnd('\') -eq $installed) {
            return "$($p.Name).exe (pid $($p.Id)) is running from $to and holds its files"
        }
    }
    $null
}

function Exit-IfBusy([string]$to, [bool]$running) {
    $why = Get-Blocker $to $running
    if (-not $why) { return }
    Step "Stopped: $why. Nothing was changed. Run this again once that is over." 'Red'
    # 3, not 1: scripts/fleet.sh reads it as "wait and try again", where 1 is a failed install.
    exit 3
}

# Runs the new build's doctor from the staging folder: its runtimes are there (the CLI needs the
# same two as the app), its native DLLs load, its struct layouts read back sane and a model is
# installed. What doctor printed is shown only when it fails.
function Test-Package([string]$payload) {
    # The runtime the app will get: install.ps1 points DOTNET_ROOT at the per-user one for good
    # whenever it exists, so the same rule here.
    $dotnetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
    if (Test-Path (Join-Path $dotnetRoot 'dotnet.exe')) { $env:DOTNET_ROOT = $dotnetRoot }
    # ggml writes its load lines to stderr, which 'Stop' would turn into a fatal error.
    $ErrorActionPreference = 'Continue'
    # A doctor that cannot start at all, blocked or not a program, throws past 'Continue' to the
    # caller's try, and sets no exit code, so one left over from an earlier command would read as
    # a pass. Either way it is a build that did not pass.
    $global:LASTEXITCODE = $null
    try { $said = & (Join-Path $payload 'linflow-cli.exe') doctor 2>&1 | ForEach-Object { "$_" } }
    catch { Write-Host "    $_"; return $false }
    if ($LASTEXITCODE -eq 0) { return $true }
    $said | ForEach-Object { Write-Host "    $_" }
    $false
}

# Closes the running copy and waits until it has gone. Until then it holds its own exe and DLLs
# open, and a new copy started too soon finds it, hands over and quits.
function Stop-LinFlow($processes) {
    $processes | Stop-Process -Force -ErrorAction SilentlyContinue
    $processes | Wait-Process -Timeout 15 -ErrorAction SilentlyContinue
    if (@($processes | Where-Object { -not $_.HasExited })) { throw "Lin Flow was still running 15 s after it was closed" }
}

# Copies the new build over the installed one. Get-Blocker has already looked for anything else
# holding the folder, but a failed copy leaves Lin Flow down and half replaced, so it gets a few
# more tries before it counts.
function Install-Files([string]$payload, [string]$to) {
    New-Item -ItemType Directory -Path $to -Force | Out-Null
    for ($try = 1; ; $try++) {
        try { Copy-Item (Join-Path $payload '*') $to -Recurse -Force; return }
        catch { if ($try -ge 5) { throw }; Start-Sleep -Seconds 1 }
    }
}

# Starts it the way the taskbar pin does, through Explorer: as the desktop user, not as an elevated
# window would, and with the desktop's environment rather than this shell's.
function Start-LinFlow([string]$to) {
    Start-Process explorer.exe -ArgumentList ('"{0}"' -f (Join-Path $to 'LinFlow.exe'))
}

# Waits for Lin Flow to log that it is ready, and returns the time it logged, or $null once
# $seconds have gone by. The log keeps every earlier start, so only a "ready" dated after $after
# counts. The line is LinFlow.Core's Log.Info("ready"), from LinFlow.App's Program.cs.
function Wait-Ready([string]$log, [datetime]$after, [int]$seconds) {
    $deadline = (Get-Date).AddSeconds($seconds)
    do {
        if (Test-Path $log) {
            # The log is never trimmed, and the new copy writes a handful of lines before "ready".
            foreach ($line in @(Get-Content $log -Tail 200)) {
                if ($line -match '^\[lin-flow (\d{4}-\d\d-\d\d \d\d:\d\d:\d\d\.\d{3})\] ready$') {
                    $at = [datetime]::ParseExact($Matches[1], 'yyyy-MM-dd HH:mm:ss.fff',
                                                 [Globalization.CultureInfo]::InvariantCulture)
                    if ($at -gt $after) { return $at }
                }
            }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    $null
}

function Install-Latest {
    Assert-RealAppData
    Clear-TestSwitches

    $from = Join-Path (Join-Path $Share 'releases') $Release
    if (-not (Test-Path $from)) {
        Write-Host "No release at $from" -ForegroundColor Red
        $all = Join-Path $Share 'releases'
        if (Test-Path $all) {
            Write-Host "`nWhat is on the share:"
            Get-ChildItem $all -Directory | Sort-Object Name -Descending | Select-Object -First 10 Name | Format-Table -HideTableHeaders
        }
        exit 1
    }

    $zip = Get-ChildItem $from -Filter '*.zip' | Select-Object -First 1
    if (-not $zip) { throw "No zip in $from" }

    if (Test-Path (Join-Path $from 'RELEASE.txt')) {
        Write-Host (Get-Content (Join-Path $from 'RELEASE.txt') -Raw) -ForegroundColor Cyan
    }

    $log = Join-Path $env:APPDATA 'Lin Flow\app.log'
    $running = @()
    $startBeforeSetup = $false
    $tmp = Join-Path $env:TEMP ("linflow-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Path $tmp -Force | Out-Null
    try {
        # 1. Everything that can happen with the old copy still up.
        $payload = Get-Package $zip.FullName $tmp
        Step "fetched and unpacked $($zip.Name) ($([math]::Round($zip.Length / 1MB, 1)) MB)"

        $running = @(Get-RunningLinFlow)
        Exit-IfBusy $To ($running.Count -gt 0)
        if ($running) {
            Write-Host "Lin Flow is running. It stays up while the new build is checked, then closes for about 15 s while its files are replaced." -ForegroundColor Yellow
            $installed = [IO.Path]::GetFullPath($To).TrimEnd('\')
            $elsewhere = @($running | Where-Object { $_.Path -and (Split-Path $_.Path -Parent).TrimEnd('\') -ne $installed })
            foreach ($p in $elsewhere) {
                Write-Host "  That copy runs from $($p.Path). The one started again is the new one in $To;" -ForegroundColor Yellow
                Write-Host "  a shortcut to the old one still opens the old one." -ForegroundColor Yellow
            }
            Write-Host "Checking the new build here. Its first run can take a minute, since the virus scanner checks each new file then..." -ForegroundColor Cyan
            if (Test-Package $payload) {
                $startBeforeSetup = $true
                Step 'the new build passed doctor' 'Green'
            } elseif ($Force) {
                Step 'the new build did not pass doctor. -Force: installing it anyway, with setup before Lin Flow starts again' 'Yellow'
            } else {
                Step 'the new build did not pass doctor here. Nothing was changed, and Lin Flow is still running.' 'Red'
                Write-Host "To install it anyway, run this again with -Force. Lin Flow then closes, and setup, which" -ForegroundColor Yellow
                Write-Host "fetches a missing runtime or model, runs before it is started again." -ForegroundColor Yellow
                exit 1
            }

            # 2. The swap: the only part with Lin Flow down. The check can take minutes, so look
            # again, at what would stop the close and at which copy is running now.
            Exit-IfBusy $To $true
            Stop-LinFlow @(Get-RunningLinFlow)
            $closed = Get-Date
            Step 'closed Lin Flow'
        }
        try { Install-Files $payload $To }
        catch {
            if ($running) { Write-Host "Lin Flow is closed, and $To may be half replaced. Run this again once nothing holds it." -ForegroundColor Red }
            throw
        }
        Step "installed to $To" 'Green'
        if ($startBeforeSetup) {
            Start-LinFlow $To
            Step 'started Lin Flow again' 'Green'
        }
    } finally {
        Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    # 3. Hand over to the package's own setup: runtime, model, shortcut. It is interactive by
    # design - it asks before installing the .NET runtime - so it runs here rather than being
    # duplicated. With a build that passed doctor, Lin Flow is already starting while it runs.
    Write-Host "`nRunning setup..." -ForegroundColor Cyan
    try {
        & (Join-Path $To 'install.ps1')
        Step 'setup done'
    } finally {
        # After -Force, Lin Flow is started even when setup fails, so that it can say what is missing.
        if ($running -and -not $startBeforeSetup) {
            Start-LinFlow $To
            Step 'started Lin Flow again' 'Green'
        }
    }

    if ($running) {
        Write-Host "Lin Flow has been started again already, so there is no need to open it from the desktop." -ForegroundColor Cyan
        $ready = Wait-Ready $log $closed 120
        if ($ready) {
            Step ("Lin Flow is ready. It was down {0:F1} s, from {1:HH:mm:ss.f} to {2:HH:mm:ss.f}." -f
                  ($ready - $closed).TotalSeconds, $closed, $ready) 'Green'
        } else {
            Step "Lin Flow was started again but has not said ready in 120 s. Its log is $log" 'Yellow'
        }
    }
}

# Dot-sourced by probes\installer-probe.ps1, which runs these steps against stand-ins so that no
# test closes the Lin Flow John is dictating with. Run, it installs.
if ($MyInvocation.InvocationName -ne '.') { Install-Latest }
