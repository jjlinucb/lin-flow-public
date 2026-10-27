# The swap behind Update in the Windows app's Settings (next/core/src/update.rs, which carries this
# file in the app). Lin Flow writes it to TEMP, starts it with Windows PowerShell and quits.
# It waits for the app to be gone, unpacks the zip beside the install folder, checks the new copy
# runs, swaps the two folders, and opens Lin Flow again. A failure keeps the old copy and
# opens that. Each step is logged to lin-flow-update.log in TEMP. CI runs it on a made-up
# install in the windows job. The app is lin-flow.exe from 2026-10-27; a zip with the older
# lin-flow-next.exe still swaps in, and whichever one the folder holds is opened.
param([string]$Zip, [string]$Dest, [int]$ProcId)
$ErrorActionPreference = 'Stop'
# The app starts this from its own folder (the shortcuts' Start in), and Windows won't move a folder
# a process stands in: the first Update on MBC253 failed "in use" (2026-10-27). Stand in TEMP,
# for the process itself as well as for PowerShell, whose Set-Location alone leaves the process there.
Set-Location $env:TEMP
[IO.Directory]::SetCurrentDirectory($env:TEMP)
$log = Join-Path $env:TEMP 'lin-flow-update.log'
function Say($t) { Add-Content $log "$(Get-Date -Format s) $t" }
function App($dir) {
    foreach ($name in 'lin-flow.exe', 'lin-flow-next.exe') {
        $p = Join-Path $dir $name
        if (Test-Path $p) { return $p }
    }
    return $null
}
$new = "$Dest.new"; $old = "$Dest.old"
try {
    Say "waiting for Lin Flow ($ProcId) to quit"
    Wait-Process -Id $ProcId -Timeout 60 -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force $new, $old -ErrorAction SilentlyContinue
    Expand-Archive $Zip $new -Force
    foreach ($folder in 'lin-flow-windows', 'lin-flow-next-windows') {
        $inner = Join-Path $new $folder
        if (App $inner) {
            Get-ChildItem $inner | Move-Item -Destination $new
            Remove-Item $inner
        }
    }
    if (-not (App $new)) { throw 'the zip has no lin-flow.exe' }
    & (Join-Path $new 'linflow.exe') version | ForEach-Object { Say $_ }
    if ($LASTEXITCODE -ne 0) { throw 'the new copy did not start' }
    # WebView2's helpers can hold the folder for a moment after the app quits.
    for ($i = 1; ; $i++) {
        try { Move-Item $Dest $old; break }
        catch { if ($i -ge 10) { throw }; Say "install folder in use, retry $i"; Start-Sleep -Seconds 1 }
    }
    Move-Item $new $Dest
    Remove-Item -Recurse -Force $old -ErrorAction SilentlyContinue
    Say "updated $Dest"
} catch {
    Say "update failed: $_"
    if (-not (Test-Path $Dest) -and (Test-Path $old)) { Move-Item $old $Dest }
}
Remove-Item $Zip -ErrorAction SilentlyContinue
Start-Process (App $Dest)
