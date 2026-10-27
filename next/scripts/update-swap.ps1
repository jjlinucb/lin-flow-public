# The swap behind Update in the Windows app's Settings (next/core/src/update.rs, which carries this
# file in the app). Lin Flow Next writes it to TEMP, starts it with Windows PowerShell and quits.
# It waits for the app to be gone, unpacks the zip beside the install folder, checks the new copy
# runs, swaps the two folders, and opens Lin Flow Next again. A failure keeps the old copy and
# opens that. Each step is logged to lin-flow-next-update.log in TEMP. CI runs it on a made-up
# install in the windows job.
param([string]$Zip, [string]$Dest, [int]$ProcId)
$ErrorActionPreference = 'Stop'
$log = Join-Path $env:TEMP 'lin-flow-next-update.log'
function Say($t) { Add-Content $log "$(Get-Date -Format s) $t" }
$new = "$Dest.new"; $old = "$Dest.old"
try {
    Say "waiting for Lin Flow Next ($ProcId) to quit"
    Wait-Process -Id $ProcId -Timeout 60 -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 1
    Remove-Item -Recurse -Force $new, $old -ErrorAction SilentlyContinue
    Expand-Archive $Zip $new -Force
    $inner = Join-Path $new 'lin-flow-next-windows'
    if (Test-Path (Join-Path $inner 'lin-flow-next.exe')) {
        Get-ChildItem $inner | Move-Item -Destination $new
        Remove-Item $inner
    }
    if (-not (Test-Path (Join-Path $new 'lin-flow-next.exe'))) { throw 'the zip has no lin-flow-next.exe' }
    & (Join-Path $new 'linflow.exe') version | ForEach-Object { Say $_ }
    if ($LASTEXITCODE -ne 0) { throw 'the new copy did not start' }
    Move-Item $Dest $old
    Move-Item $new $Dest
    Remove-Item -Recurse -Force $old -ErrorAction SilentlyContinue
    Say "updated $Dest"
} catch {
    Say "update failed: $_"
    if (-not (Test-Path $Dest) -and (Test-Path $old)) { Move-Item $old $Dest }
}
Remove-Item $Zip -ErrorAction SilentlyContinue
Start-Process (Join-Path $Dest 'lin-flow-next.exe')
