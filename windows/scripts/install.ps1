# Lin Flow - first-run setup on Windows.
#   Right-click this file -> "Run with PowerShell", or:  powershell -ExecutionPolicy Bypass -File install.ps1
# Installs nothing system-wide and never asks for admin.

$ErrorActionPreference = 'Stop'

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
Assert-RealAppData
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
Write-Host "Lin Flow setup" -ForegroundColor Cyan

# 1. The .NET 8 runtime. The app is framework-dependent so the zip stays small enough to email;
#    this is the one prerequisite, and it installs per-user without admin.
#
#    Two traps here, both hit on a real Windows 11 machine on 2026-09-16:
#
#      a) `-Runtime windowsdesktop` installs ONLY the Microsoft.WindowsDesktop.App shared
#         framework. It does not install Microsoft.NETCore.App and it does not lay down the
#         dotnet host, so a check that looks for WindowsDesktop alone passes while nothing can
#         actually start. Both runtimes have to be installed.
#
#      b) A per-user runtime under %LOCALAPPDATA% is invisible to the apphost. LinFlow.exe looks
#         at DOTNET_ROOT, then HKLM's InstallLocation, then C:\Program Files\dotnet. With none of
#         them set it shows the .NET "missing runtime" dialog and never reaches its own code, so
#         app.log stays empty and the whole thing reads as a silent hang. DOTNET_ROOT has to be
#         persisted at user scope, not merely exported for this session.
$dotnetRoot = Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet'
$dotnetExe = Join-Path $dotnetRoot 'dotnet.exe'

function Test-DotnetRuntimes($exe) {
    if (-not (Test-Path $exe)) {
        $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
        if (-not $cmd) { return $false }
        $exe = $cmd.Source
    }
    $r = & $exe --list-runtimes 2>$null
    return (($r -match 'Microsoft\.WindowsDesktop\.App 8\.') -and ($r -match 'Microsoft\.NETCore\.App 8\.'))
}

if (-not (Test-DotnetRuntimes $dotnetExe)) {
    Write-Host "`nThe .NET 8 runtime is not installed (or only half of it is)." -ForegroundColor Yellow
    $answer = Read-Host "Install it now, just for your user account (no admin needed)? [Y/n]"
    if ($answer -eq '' -or $answer -match '^[Yy]') {
        $script = Join-Path $env:TEMP 'dotnet-install.ps1'
        Invoke-WebRequest -Uri 'https://dot.net/v1/dotnet-install.ps1' -OutFile $script -UseBasicParsing
        # Desktop framework for WinForms, base runtime for Microsoft.NETCore.App and dotnet.exe.
        & $script -Channel 8.0 -Runtime windowsdesktop -InstallDir $dotnetRoot -NoPath
        & $script -Channel 8.0 -Runtime dotnet -InstallDir $dotnetRoot -NoPath
        Write-Host "Runtime installed." -ForegroundColor Green
    } else {
        Write-Host "Skipped. Lin Flow will not start until it is installed." -ForegroundColor Yellow
    }
} else {
    Write-Host "  .NET 8 runtime: found" -ForegroundColor Green
}

# Point the apphost at the per-user runtime, permanently. Without this, double-clicking
# LinFlow.exe fails with the "missing runtime" dialog even though the runtime is installed.
if (Test-Path $dotnetExe) {
    if ([Environment]::GetEnvironmentVariable('DOTNET_ROOT', 'User') -ne $dotnetRoot) {
        [Environment]::SetEnvironmentVariable('DOTNET_ROOT', $dotnetRoot, 'User')
        Write-Host "  DOTNET_ROOT set for your user account." -ForegroundColor Green
    }
    $env:DOTNET_ROOT = $dotnetRoot
    $env:PATH = "$dotnetRoot;$env:PATH"
}

# 2. Check the native layer before anything else. This is the part that was written on a Mac
#    and never executed on Windows until now, so it gets checked first and loudly.
Write-Host "`nChecking the native speech engine..." -ForegroundColor Cyan
& (Join-Path $here 'linflow-cli.exe') doctor
$doctor = $LASTEXITCODE

# 3. The model. 638 MB, which is why it is not in the zip.
if ($doctor -ne 0) {
    Write-Host "`nDownloading the speech model (about 640 MB, one time)..." -ForegroundColor Cyan
    & (Join-Path $here 'linflow-cli.exe') download parakeet-tdt-0.6b-v3-q8_0
    & (Join-Path $here 'linflow-cli.exe') doctor
}

# 4. A desktop shortcut, so there is something to right-click and pin to the taskbar. Windows 11
# files a new tray icon behind the overflow chevron, so the tray is not a way in that can be
# relied on, and Windows blocks pinning from a script - only John can do that, from this shortcut.
# The icon points at lin-flow.ico rather than at the exe, which carries the same icon: Windows
# caches a shortcut's icon by source path, so a path it has not seen is what makes it appear.
try {
    $lnk = Join-Path ([Environment]::GetFolderPath('Desktop')) 'Lin Flow.lnk'
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($lnk)
    $shortcut.TargetPath = Join-Path $here 'LinFlow.exe'
    $shortcut.WorkingDirectory = $here
    $shortcut.Description = 'Lin Flow - hold the hotkey to dictate'
    $icon = Join-Path $here 'lin-flow.ico'
    if (Test-Path $icon) { $shortcut.IconLocation = "$icon,0" }
    $shortcut.Save()
    Write-Host "Desktop shortcut: $lnk"
} catch {
    Write-Host "Could not make the desktop shortcut: $($_.Exception.Message)" -ForegroundColor Yellow
}

Write-Host @"

Done. To use it:
  1. Double-click Lin Flow on the desktop. The tray icon turns green when the model is loaded.
  2. Hold LEFT CTRL + LEFT ALT together, talk, let go. The cleaned text is pasted where your cursor is.
     Another key or a chord: Settings in the window, or the "hotkey" key in settings.json.
  3. Double-click the tray icon, or run Lin Flow again, to open the window: your dictations,
     the dictionary, the meeting notetaker and the settings.

To put it on the taskbar: right-click the desktop shortcut and choose Pin to taskbar.
To start it at login, copy that shortcut into:
  shell:startup   (paste that into the Run box)
"@ -ForegroundColor Green
