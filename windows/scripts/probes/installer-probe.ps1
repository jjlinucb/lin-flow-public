# Tests install-latest.ps1 on a machine where John is dictating, without touching his Lin Flow.
#
#   powershell -ExecutionPolicy Bypass -File windows\scripts\probes\installer-probe.ps1 -Scratch <new folder>
#
# The installer closes the running Lin Flow, replaces it and starts it again, and none of that can
# be tried for real while he is using it. So this runs the installer's own code with four of its
# steps replaced: the container check, finding the running copy, the pre-flight doctor and
# starting Lin Flow. The fetch, the unpack, the checks on the package, the close, the swap, where
# setup falls in the order and the wait for "ready" are the installer's. What stands in:
#
# - The share is a folder in -Scratch holding a copy of a real release. Its install.ps1 is a stub
#   that notes when it ran: the real setup would point John's desktop shortcut at the scratch copy.
# - Lin Flow is ping.exe, copied into the scratch install folder as LinFlowStandIn.exe and run
#   hidden. Like the app it holds its own exe open while it runs, and the package carries a file
#   of that name, so a swap made before the close would fail.
# - Its "ready" is a line written into a scratch app.log 1.5 s after it starts. The log already
#   holds an old "ready", which the wait must not take for the new one.
#
# Then the real Test-Package, Install-Files and Wait-Ready are checked on their own, the first
# against the release's own doctor with LINFLOW_DATA_DIR inside -Scratch. Nothing here starts
# LinFlow.exe: a second copy would find John's and raise its window.
param(
    [Parameter(Mandatory)][string]$Scratch,
    [string]$ReleaseFolder = '\\fileserver\share\lin-flow\releases\latest'
)
$ErrorActionPreference = 'Stop'
$global:ProgressPreference = 'SilentlyContinue'
$installer = Join-Path (Split-Path -Parent $PSScriptRoot) 'install-latest.ps1'
New-Item -ItemType Directory -Path $Scratch -Force | Out-Null
$Scratch = (Resolve-Path $Scratch).Path
$failures = 0

function Check([bool]$ok, [string]$what) {
    if ($ok) { Write-Host "  ok    $what" -ForegroundColor Green }
    else { Write-Host "  FAIL  $what" -ForegroundColor Red; $script:failures++ }
}
function Stop-StandIns {
    Get-Process LinFlowStandIn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Milliseconds 300
}
function Hash([string]$path) { (Get-FileHash $path).Hash }
# A case that throws must not leave its stand-ins running.
$cli = $null
trap {
    Get-Process LinFlowStandIn -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    if ($cli) { $cli | Stop-Process -Force -ErrorAction SilentlyContinue }
    break
}

$errors = $null
$tree = [Management.Automation.Language.Parser]::ParseFile($installer, [ref]$null, [ref]$errors)
Check (-not $errors) "install-latest.ps1 parses$(if ($errors) { ': ' + ($errors -join '; ') })"

# The container check is stubbed out below, and both scripts must carry the same copy of it.
function Get-FunctionText($ast, [string]$name) {
    $f = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    if ($f) { $f.Extent.Text -replace "`r`n", "`n" }
}
$setupTree = [Management.Automation.Language.Parser]::ParseFile((Join-Path (Split-Path -Parent $PSScriptRoot) 'install.ps1'), [ref]$null, [ref]$null)
$mine = Get-FunctionText $tree 'Assert-RealAppData'
Check ($mine -and $mine -eq (Get-FunctionText $setupTree 'Assert-RealAppData')) "its container check matches install.ps1's"

# The cases replace four of the installer's functions by name. Were one of those names to drift,
# the installer's own would run against John's Lin Flow, so stop before any case instead.
$flow = $tree.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Install-Latest' }, $true)
$calls = @(if ($flow) { $flow.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true) | ForEach-Object { $_.GetCommandName() } })
$drifted = @('Assert-RealAppData', 'Get-RunningLinFlow', 'Test-Package', 'Start-LinFlow' | Where-Object { -not (Get-FunctionText $tree $_) -or $calls -notcontains $_ })
Check (-not $drifted) "the four steps the cases replace are still the installer's$(if ($drifted) { ', but not ' + ($drifted -join ', ') })"
if ($drifted) { Write-Host 'Stopped before any case, since one would reach the real Lin Flow.' -ForegroundColor Red; exit 1 }

# The real release, unpacked once.
$base = Join-Path $Scratch 'release'
Expand-Archive (Get-ChildItem $ReleaseFolder -Filter '*.zip' | Select-Object -First 1).FullName $base -Force
$ping = Join-Path $env:WINDIR 'System32\PING.EXE'
Stop-StandIns

# One process per case: the installer ends with exit when it refuses, which would end this too.
$runner = Join-Path $Scratch 'runner.ps1'
@'
param([string]$Installer, [string]$Case, [string]$Preflight, [switch]$Force)
$env:APPDATA = Join-Path $Case 'appdata'
$env:TEMP = Join-Path $Case 'temp'
. $Installer -Share (Join-Path $Case 'share') -To (Join-Path $Case 'to') -Force:$Force
function Note([string]$what) { $what | Add-Content (Join-Path $Case 'events.txt') }
function Assert-RealAppData { }
function Get-RunningLinFlow { @(Get-Process LinFlowStandIn -ErrorAction SilentlyContinue) }
function Test-Package([string]$payload) { Note 'preflight'; $Preflight -eq 'pass' }
function Start-LinFlow([string]$to) {
    $p = Start-Process (Join-Path $to 'LinFlowStandIn.exe') -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru
    Note "start $($p.Id)"
    Start-Job -ArgumentList (Join-Path $env:APPDATA 'Lin Flow\app.log') -ScriptBlock {
        param($log)
        Start-Sleep -Milliseconds 1500
        '[lin-flow {0:yyyy-MM-dd HH:mm:ss.fff}] ready' -f (Get-Date) | Add-Content $log
    } | Out-Null
}
Install-Latest
'@ | Set-Content $runner -Encoding ascii

# Builds a case: a share with a release made from $base, an installed "old build" whose stand-in
# is running when -Running is set, and a scratch app.log. $shape changes the package first.
function New-Case([string]$name, [scriptblock]$shape = {}, [switch]$Running, [switch]$FlatZip) {
    $case = Join-Path $Scratch $name
    $latest = Join-Path $case 'share\releases\latest'
    $pkg = Join-Path $case 'pkg'
    foreach ($d in $latest, $pkg, (Join-Path $case 'to'), (Join-Path $case 'temp'), (Join-Path $case 'appdata\Lin Flow')) {
        New-Item -ItemType Directory -Path $d -Force | Out-Null
    }
    Copy-Item (Join-Path $base 'LinFlow') $pkg -Recurse
    $app = Join-Path $pkg 'LinFlow'
    "'setup' | Add-Content (Join-Path (Split-Path `$env:APPDATA) 'events.txt')" | Set-Content (Join-Path $app 'install.ps1') -Encoding ascii
    Copy-Item $ping (Join-Path $app 'LinFlowStandIn.exe')
    & $shape $app
    $zip = Join-Path $latest 'LinFlow-windows-x64.zip'
    if ($FlatZip) { Compress-Archive -Path (Join-Path $app '*') -DestinationPath $zip }
    else { Compress-Archive -Path $app -DestinationPath $zip }
    'Lin Flow for Windows (a probe release)' | Set-Content (Join-Path $latest 'RELEASE.txt')

    $to = Join-Path $case 'to'
    'old build' | Set-Content (Join-Path $to 'LinFlow.dll')
    Copy-Item $ping (Join-Path $to 'LinFlowStandIn.exe')
    # The old copy's own "ready", seconds before the close.
    '[lin-flow {0:yyyy-MM-dd HH:mm:ss.fff}] ready' -f (Get-Date) | Set-Content (Join-Path $case 'appdata\Lin Flow\app.log')
    $old = $null
    if ($Running) {
        $old = Start-Process (Join-Path $to 'LinFlowStandIn.exe') -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru
    }
    [pscustomobject]@{ Dir = $case; To = $to; Old = $old }
}

function Invoke-Case($case, [string]$preflight, [switch]$Force) {
    $ErrorActionPreference = 'Continue'
    $args2 = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $runner, '-Installer', $installer,
               '-Case', $case.Dir, '-Preflight', $preflight)
    if ($Force) { $args2 += '-Force' }
    $out = & powershell.exe @args2 2>&1 | ForEach-Object { "$_" }
    $code = $LASTEXITCODE
    $out | Set-Content (Join-Path $case.Dir 'out.txt')
    $eventsFile = Join-Path $case.Dir 'events.txt'
    $events = @(if (Test-Path $eventsFile) { Get-Content $eventsFile })
    [pscustomobject]@{ Code = $code; Out = ($out -join "`n"); Events = $events }
}

function Test-Replaced($case) { (Hash (Join-Path $case.To 'LinFlow.dll')) -eq (Hash (Join-Path $base 'LinFlow\LinFlow.dll')) }
function Test-OldBuild($case) { "$(Get-Content (Join-Path $case.To 'LinFlow.dll') -Raw)".Trim() -eq 'old build' }
function Test-StagingGone($case) { -not (Get-ChildItem (Join-Path $case.Dir 'temp') -Filter 'linflow-*' -ErrorAction SilentlyContinue) }
function Get-StartedPid($r) { $s = $r.Events | Where-Object { $_ -like 'start *' } | Select-Object -First 1; if ($s) { [int]($s -split ' ')[1] } }

Write-Host "`nupgrade: Lin Flow running, the new build passes"
$c = New-Case 'upgrade' -Running
$env:LINFLOW_NO_PASTE = '1'; $env:LINFLOW_OLLAMA_TEST = '1'
$r = Invoke-Case $c 'pass'
Remove-Item Env:LINFLOW_NO_PASTE, Env:LINFLOW_OLLAMA_TEST
Check ($r.Code -eq 0) "exit 0 (got $($r.Code))"
Check ($r.Out -match 'Ignoring LINFLOW_NO_PASTE' -and $r.Out -match 'Ignoring LINFLOW_OLLAMA_TEST') 'it dropped the test switches the shell had set'
Check (($r.Events -join ',') -eq "preflight,start $(Get-StartedPid $r),setup") "checked, then started, then setup ($($r.Events -join ', '))"
Check ($c.Old.HasExited) 'the old copy was closed'
$new = Get-StartedPid $r
Check ($new -and (Get-Process -Id $new -ErrorAction SilentlyContinue)) "the new copy is running (pid $new)"
Check (Test-Replaced $c) 'the install folder holds the new build'
Check ($r.Out -match 'Lin Flow is ready\. It was down \d+\.\d s') 'it reported the downtime from the new "ready", not the old one'
Check (Test-StagingGone $c) 'the staging folder is gone'
Stop-StandIns

Write-Host "`na zip with no LinFlow folder"
$c = New-Case 'flat-zip' -Running -FlatZip
$r = Invoke-Case $c 'pass'
Check ($r.Code -ne 0) "refused (exit $($r.Code))"
Check ($r.Out -match 'did not contain a LinFlow folder') 'said why'
Check (-not $c.Old.HasExited) 'Lin Flow was left running'
Check (Test-OldBuild $c) 'the installed build is untouched'
Check ($r.Events.Count -eq 0) "nothing else ran ($($r.Events -join ', '))"
Check (Test-StagingGone $c) 'the staging folder is gone'
Stop-StandIns

Write-Host "`na package without LinFlow.exe"
$c = New-Case 'no-exe' -Running -shape { param($app) Remove-Item (Join-Path $app 'LinFlow.exe') }
$r = Invoke-Case $c 'pass'
Check ($r.Code -ne 0) "refused (exit $($r.Code))"
Check ($r.Out -match 'LinFlow\.exe is missing from the package') 'said why'
Check (-not $c.Old.HasExited) 'Lin Flow was left running'
Check (Test-OldBuild $c) 'the installed build is untouched'
Check (Test-StagingGone $c) 'the staging folder is gone'
Stop-StandIns

Write-Host "`nthe new build fails doctor"
$c = New-Case 'doctor-fails' -Running
$r = Invoke-Case $c 'fail'
Check ($r.Code -eq 1) "refused (exit $($r.Code))"
Check ($r.Out -match 'Nothing was changed' -and $r.Out -match '-Force') 'said nothing changed, and how to install anyway'
Check (-not $c.Old.HasExited) 'Lin Flow was left running'
Check (Test-OldBuild $c) 'the installed build is untouched'
Check (($r.Events -join ',') -eq 'preflight') "only the check ran ($($r.Events -join ', '))"
Check (Test-StagingGone $c) 'the staging folder is gone'
Stop-StandIns

Write-Host "`nthe new build fails doctor, with -Force"
$c = New-Case 'doctor-fails-force' -Running
$r = Invoke-Case $c 'fail' -Force
Check ($r.Code -eq 0) "exit 0 (got $($r.Code))"
Check (($r.Events -join ',') -eq "preflight,setup,start $(Get-StartedPid $r)") "setup ran before the start ($($r.Events -join ', '))"
Check ($c.Old.HasExited) 'the old copy was closed'
Check (Test-Replaced $c) 'the install folder holds the new build'
Check ($r.Out -match 'Lin Flow is ready\. It was down \d+\.\d s') 'it waited for the new "ready"'
Check (Test-StagingGone $c) 'the staging folder is gone'
Stop-StandIns

Write-Host "`nsetup fails after -Force"
$c = New-Case 'setup-fails-force' -Running -shape {
    param($app)
    "'setup' | Add-Content (Join-Path (Split-Path `$env:APPDATA) 'events.txt'); throw 'setup failed on purpose'" | Set-Content (Join-Path $app 'install.ps1') -Encoding ascii
}
$r = Invoke-Case $c 'fail' -Force
Check ($r.Code -ne 0) "failed (exit $($r.Code))"
Check (($r.Events -join ',') -eq "preflight,setup,start $(Get-StartedPid $r)") "Lin Flow was started again anyway ($($r.Events -join ', '))"
$new = Get-StartedPid $r
Check ($new -and (Get-Process -Id $new -ErrorAction SilentlyContinue)) "the new copy is running (pid $new)"
Stop-StandIns

Write-Host "`na meeting note being recorded"
$c = New-Case 'recording' -Running
$note = Join-Path $c.Dir 'appdata\Lin Flow\notes\2026-09-25-probe'
New-Item -ItemType Directory -Path $note -Force | Out-Null
'{"id":"2026-09-25-probe","title":"Probe meeting","createdAt":"2026-09-25T19:00:00Z","endedAt":null}' | Set-Content (Join-Path $note 'note.json')
$r = Invoke-Case $c 'pass'
Check ($r.Code -eq 1) "refused (exit $($r.Code))"
Check ($r.Out -match 'recording a meeting note') 'said why'
Check (-not $c.Old.HasExited) 'Lin Flow was left running'
Check (Test-OldBuild $c) 'the installed build is untouched'
Check ($r.Events.Count -eq 0) "nothing else ran ($($r.Events -join ', '))"
Check (Test-StagingGone $c) 'the staging folder is gone'
Stop-StandIns

Write-Host "`nlinflow-cli.exe running from the install folder"
$c = New-Case 'cli-holds' -Running
Copy-Item $ping (Join-Path $c.To 'linflow-cli.exe')
$cli = Start-Process (Join-Path $c.To 'linflow-cli.exe') -ArgumentList '-t', '127.0.0.1' -WindowStyle Hidden -PassThru
$r = Invoke-Case $c 'pass'
Check ($r.Code -eq 1) "refused (exit $($r.Code))"
Check ($r.Out -match 'linflow-cli\.exe \(pid \d+\) is running from') 'said why'
Check (-not $c.Old.HasExited) 'Lin Flow was left running'
Check (Test-OldBuild $c) 'the installed build is untouched'
Check ($r.Events.Count -eq 0) "nothing else ran ($($r.Events -join ', '))"
$cli | Stop-Process -Force -ErrorAction SilentlyContinue
Stop-StandIns

Write-Host "`na first install: nothing running"
$c = New-Case 'first-install'
$r = Invoke-Case $c 'pass'
Check ($r.Code -eq 0) "exit 0 (got $($r.Code))"
Check (($r.Events -join ',') -eq 'setup') "only setup ran, and nothing was started ($($r.Events -join ', '))"
Check (Test-Replaced $c) 'the install folder holds the new build'
Check (-not (Get-Process LinFlowStandIn -ErrorAction SilentlyContinue)) 'no copy was started'
Check (Test-StagingGone $c) 'the staging folder is gone'
Stop-StandIns

# The real functions, on their own. A child scope, so the installer's parameters and functions
# stay out of this script's.
& {
    . $installer

    Write-Host "`nTest-Package: the release's own doctor"
    $data = Join-Path $Scratch 'data-with-model'
    $models = Join-Path $data 'models'
    New-Item -ItemType Directory -Path $models -Force | Out-Null
    # doctor checks the model by size only. A sparse file of that size costs no disk.
    $model = Join-Path $models 'ggml-parakeet-tdt-0.6b-v3-q8_0.bin'
    [IO.File]::Create($model).Close()
    & fsutil sparse setflag $model | Out-Null
    $f = [IO.File]::Open($model, 'Open'); $f.SetLength(700MB); $f.Close()
    $env:LINFLOW_DATA_DIR = $data
    Check (Test-Package (Join-Path $base 'LinFlow')) 'passes with a model in place'
    $env:LINFLOW_DATA_DIR = Join-Path $Scratch 'data-empty'
    New-Item -ItemType Directory -Path $env:LINFLOW_DATA_DIR -Force | Out-Null
    Write-Host '  (doctor''s complaint follows, as the installer would show it)'
    Check (-not (Test-Package (Join-Path $base 'LinFlow'))) 'fails with no model'
    Remove-Item Env:LINFLOW_DATA_DIR
    $broken = Join-Path $Scratch 'broken-cli'
    New-Item -ItemType Directory -Path $broken -Force | Out-Null
    'not a program' | Set-Content (Join-Path $broken 'linflow-cli.exe')
    Write-Host '  (PowerShell''s complaint that it cannot start follows)'
    $global:LASTEXITCODE = 0
    $passed = 'threw'
    try { $passed = Test-Package $broken } catch { }
    Check ($passed -eq $false) "fails when doctor cannot start, called inside a try as the installer calls it, after a command that exited 0 (got $passed)"

    Write-Host "`nInstall-Files: a file held open during the swap"
    foreach ($hold in 2, 12) {
        $to = Join-Path $Scratch "held-$hold"
        New-Item -ItemType Directory -Path $to -Force | Out-Null
        'old build' | Set-Content (Join-Path $to 'LinFlow.dll')
        $marker = Join-Path $to 'held.txt'
        $job = Start-Job -ArgumentList (Join-Path $to 'LinFlow.dll'), $hold, $marker -ScriptBlock {
            param($path, $seconds, $marker)
            $s = [IO.File]::Open($path, 'Open', 'ReadWrite', 'None')
            'held' | Set-Content $marker
            Start-Sleep -Seconds $seconds
            $s.Close()
        }
        while (-not (Test-Path $marker)) { Start-Sleep -Milliseconds 100 }
        $sw = [Diagnostics.Stopwatch]::StartNew()
        $threw = $false
        try { Install-Files (Join-Path $base 'LinFlow') $to } catch { $threw = $true }
        if ($hold -eq 2) {
            Check (-not $threw -and $sw.Elapsed.TotalSeconds -ge 1) ("held 2 s: copied on a later try, after {0:F1} s" -f $sw.Elapsed.TotalSeconds)
            Check ((Hash (Join-Path $to 'LinFlow.dll')) -eq (Hash (Join-Path $base 'LinFlow\LinFlow.dll'))) 'held 2 s: the new file is in place'
        } else {
            Check $threw ("held 12 s: gave up with an error after {0:F1} s" -f $sw.Elapsed.TotalSeconds)
        }
        $job | Wait-Job | Remove-Job
    }

    Write-Host "`nWait-Ready"
    $log = Join-Path $Scratch 'ready-test.log'
    '[lin-flow {0:yyyy-MM-dd HH:mm:ss.fff}] ready' -f (Get-Date) | Set-Content $log
    $before = Get-Date
    $job = Start-Job -ArgumentList $log -ScriptBlock {
        param($log)
        Start-Sleep -Seconds 1
        '[lin-flow {0:yyyy-MM-dd HH:mm:ss.fff}] Lin Flow starting' -f (Get-Date) | Add-Content $log
        '[lin-flow {0:yyyy-MM-dd HH:mm:ss.fff}] ready' -f (Get-Date) | Add-Content $log
    }
    $at = Wait-Ready $log $before 20
    Check ($at -and $at -gt $before) "found the new ready line, not the one before it ($(if ($at) { $at.ToString('HH:mm:ss.fff') } else { 'none' }))"
    $job | Wait-Job | Remove-Job
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $none = Wait-Ready $log (Get-Date) 2
    Check ($null -eq $none -and $sw.Elapsed.TotalSeconds -ge 2) ("no new line: gave up after {0:F1} s" -f $sw.Elapsed.TotalSeconds)

    # The same on a line the app's own Log wrote: doctor's, into data-with-model above.
    $real = @(Get-Content (Join-Path $data 'app.log') -ErrorAction SilentlyContinue) | Select-Object -First 1
    $realLog = Join-Path $Scratch 'real-line.log'
    ("$real" -replace '\] .*$', '] ready') | Set-Content $realLog
    Check ($real -and (Wait-Ready $realLog ([datetime]::MinValue) 1)) "reads the time in a line the app's Log wrote ($real)"
}

Stop-StandIns
Write-Host ''
if ($failures) { Write-Host "$failures FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All checks passed.' -ForegroundColor Green
