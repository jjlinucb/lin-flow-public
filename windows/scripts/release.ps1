# Build Lin Flow on this machine and publish it to the share, so the other Windows machine can
# install it without a toolchain.
#
#   powershell -ExecutionPolicy Bypass -File windows\scripts\release.ps1
#
# This is package.sh's sibling. package.sh runs on the Mac and produces the same zip; this one
# runs on Windows and also puts it somewhere. **The two file lists have to stay in step** - if
# you add something to the package, add it to both.
#
# Why PowerShell rather than reusing package.sh here: Git Bash on Windows ships no `zip`, so the
# one step that matters would fail anyway, and Compress-Archive is already installed.
#
# A release is named for the commit it came from. A dirty tree still publishes - refusing would
# just mean copying files by hand instead - but it is labeled, because a build nobody can
# reproduce from a commit is worth knowing about before it is the one on the other machine.

param(
    # The UNC path, not R:. Northwind maps the same share to different letters on different
    # machines, so a drive letter that is right here is not right anywhere else - and the whole
    # point of this script is that another machine reads what it writes.
    [string]$Share = '\\fileserver\share\lin-flow',
    [switch]$KeepStaging
)

$ErrorActionPreference = 'Stop'
$repo = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)   # ...\lin-flow
$win = Join-Path $repo 'windows'

# --- the SDK. Not on PATH on either of John's machines; see the memory note.
$dotnetRoot = if ($env:DOTNET_ROOT) { $env:DOTNET_ROOT } else { Join-Path $env:LOCALAPPDATA 'Microsoft\dotnet' }
$dotnet = Join-Path $dotnetRoot 'dotnet.exe'
if (-not (Test-Path $dotnet)) {
    $cmd = Get-Command dotnet -ErrorAction SilentlyContinue
    if (-not $cmd) { throw "No .NET SDK found. Looked in $dotnetRoot and on PATH." }
    $dotnet = $cmd.Source
}
$env:DOTNET_ROOT = Split-Path -Parent $dotnet
$env:DOTNET_CLI_TELEMETRY_OPTOUT = 1
$env:DOTNET_NOLOGO = 1

# --- what we are shipping
Push-Location $repo
$sha = (& git rev-parse --short HEAD).Trim()
$dirty = [bool](& git status --porcelain)
$branch = (& git rev-parse --abbrev-ref HEAD).Trim()
Pop-Location
$stamp = (Get-Date -Format 'yyyy-MM-dd')
$name = "$stamp-$sha" + $(if ($dirty) { '-dirty' } else { '' })

Write-Host "Lin Flow release $name" -ForegroundColor Cyan
if ($dirty) { Write-Host "  working tree is dirty - this build is not reproducible from $sha" -ForegroundColor Yellow }

# --- tests first. A release that ships a red suite is worse than no release, because the other
#     machine has no way to tell.
Write-Host "`nTests..." -ForegroundColor Cyan
& $dotnet test (Join-Path $win 'LinFlow.sln') -c Release --nologo 2>&1 | Select-Object -Last 3
if ($LASTEXITCODE -ne 0) { throw "Tests failed - nothing published." }

# --- publish. Each project goes to its own folder first: publishing two into one -o drops an exe.
$out = Join-Path $win 'dist\LinFlow'
if (Test-Path (Join-Path $win 'dist')) { Remove-Item (Join-Path $win 'dist') -Recurse -Force }
New-Item -ItemType Directory -Path $out -Force | Out-Null

foreach ($proj in @('LinFlow.App', 'LinFlow.Cli')) {
    $stage = Join-Path $win "dist\stage-$proj"
    & $dotnet publish (Join-Path $win "$proj\$proj.csproj") -c Release -r win-x64 `
        --self-contained false -o $stage --nologo | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "publish failed for $proj" }
    Copy-Item "$stage\*" $out -Recurse -Force
}
if (-not $KeepStaging) { Get-ChildItem (Join-Path $win 'dist') -Directory -Filter 'stage-*' | Remove-Item -Recurse -Force }

# --- the native engine, the icon, the readme and the installer (same list as package.sh)
$native = Join-Path $win 'native\Release'
if (-not (Test-Path $native)) { throw "$native missing - run scripts/fetch-native.sh first" }
Copy-Item (Join-Path $native 'parakeet.dll'), (Join-Path $native 'ggml.dll'), (Join-Path $native 'ggml-base.dll') $out -Force
Copy-Item (Join-Path $native 'ggml-cpu*.dll') $out -Force
# install.ps1's shortcut points its icon at this file rather than at the exe, which carries the
# same icon: Windows caches a shortcut's icon by source path, so a path it has not seen is what
# makes a changed icon actually appear.
Copy-Item (Join-Path $win 'LinFlow.App\lin-flow.ico') $out -Force
Copy-Item (Join-Path $win 'README-WINDOWS.md') (Join-Path $out 'README.txt') -Force
Copy-Item (Join-Path $PSScriptRoot 'install.ps1') $out -Force

foreach ($must in @('LinFlow.exe', 'linflow-cli.exe', 'parakeet.dll', 'install.ps1', 'lin-flow.ico')) {
    if (-not (Test-Path (Join-Path $out $must))) { throw "$must missing from the package" }
}
if (-not (Get-ChildItem $out -Filter 'ggml-cpu*.dll')) { throw "no ggml-cpu*.dll in the package" }

# --- zip it
$zip = Join-Path $win 'dist\LinFlow-windows-x64.zip'
Compress-Archive -Path $out -DestinationPath $zip -Force
$mb = [math]::Round((Get-Item $zip).Length / 1MB, 1)
Write-Host "`nPackaged: $zip  ($mb MB)" -ForegroundColor Green

# --- publish to the share
if (-not (Test-Path $Share)) { New-Item -ItemType Directory -Path $Share -Force | Out-Null }
$releases = Join-Path $Share 'releases'
$dest = Join-Path $releases $name
if (Test-Path $dest) { Remove-Item $dest -Recurse -Force }
New-Item -ItemType Directory -Path $dest -Force | Out-Null
Copy-Item $zip $dest -Force

$notes = @"
Lin Flow for Windows
  built    $(Get-Date -Format 'yyyy-MM-dd HH:mm') on $env:COMPUTERNAME
  commit   $sha on $branch$(if ($dirty) { '  (WORKING TREE WAS DIRTY - not reproducible from this commit)' })
  package  $mb MB, framework-dependent (needs the .NET 8 runtime, which install.ps1 fetches)
  model    NOT included - 669 MB. install.ps1 downloads it on first run.

To install on another Windows machine:
  1. Copy LinFlow-windows-x64.zip off the share and extract it. Install it locally rather than
     running it from the share: Lin Flow starts at login and sits in the tray all day, and an
     app whose exe disappears when the VPN drops is worse than one that is a version behind.
  2. Right-click install.ps1 -> Run with PowerShell.
  3. It installs the .NET 8 runtime per-user if missing, downloads the model, and makes a
     desktop shortcut. No admin at any point.

Or from any Windows machine that can see the share, in one step:
  powershell -ExecutionPolicy Bypass -File $Share\install-latest.ps1
"@
$notes | Set-Content (Join-Path $dest 'RELEASE.txt') -Encoding utf8

# --- refresh `latest`. A copy rather than a link: SMB symlinks need a privilege the account may
#     not have, and a junction to a UNC path does not work at all.
$latest = Join-Path $releases 'latest'
if (Test-Path $latest) { Remove-Item $latest -Recurse -Force }
New-Item -ItemType Directory -Path $latest -Force | Out-Null
Copy-Item (Join-Path $dest '*') $latest -Recurse -Force

# --- the one-step installer lives at the root of the share, so the machine being installed onto
#     needs nothing but the share. It is tracked in the repo; this is its only copy on R:.
Copy-Item (Join-Path $PSScriptRoot 'install-latest.ps1') (Join-Path $Share 'install-latest.ps1') -Force

Write-Host "Published: $dest" -ForegroundColor Green
Write-Host "           $latest" -ForegroundColor Green
Write-Host "`nOn the other machine:  powershell -ExecutionPolicy Bypass -File $Share\install-latest.ps1"
