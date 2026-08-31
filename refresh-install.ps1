#requires -Version 5.1
<#
.SYNOPSIS
    Refreshes the stable pi-os install under %LOCALAPPDATA%\pi-os.

.DESCRIPTION
    Wraps the three-step recipe from README ("Install / refresh the stable
    build"):
      1. npm run build            (repo node-harness -> dist/)
      2. dotnet publish           (host + node-harness/dist -> %LOCALAPPDATA%\pi-os)
      3. npm ci --omit=dev        (installed harness runtime deps)

    Step 3 is skipped when the installed node_modules is present and the
    published package-lock.json matches the repo one. Pass -ForceDeps to
    always re-provision.

.EXAMPLE
    .\refresh-install.ps1
    .\refresh-install.ps1 -ForceDeps
#>
[CmdletBinding()]
param(
    [switch]$ForceDeps
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

$repoRoot = $PSScriptRoot
$harnessDir = Join-Path $repoRoot 'node-harness'
$hostProject = Join-Path $repoRoot 'host-dotnet\WindowsHarness.Host\WindowsHarness.Host.csproj'
$installDir = Join-Path $env:LOCALAPPDATA 'pi-os'
$installedHarness = Join-Path $installDir 'node-harness'

function Invoke-Checked {
    param([string]$Name)
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE"
    }
}

Write-Host "== 1/3 building node harness ==" -ForegroundColor Cyan
Push-Location $harnessDir
try {
    npm run build
    Invoke-Checked 'npm run build'
}
finally {
    Pop-Location
}

Write-Host "== 2/3 publishing host to $installDir ==" -ForegroundColor Cyan
# Snapshot the currently installed lockfile BEFORE publish overwrites it,
# so we can tell whether dependencies need re-provisioning.
$installedLockBefore = $null
$installedLockPath = Join-Path $installedHarness 'package-lock.json'
if (Test-Path $installedLockPath) {
    $installedLockBefore = [System.IO.File]::ReadAllText($installedLockPath)
}

dotnet publish $hostProject -c Release -r win-x64 --self-contained false -o $installDir
Invoke-Checked 'dotnet publish'

Write-Host "== 3/3 provisioning installed harness dependencies ==" -ForegroundColor Cyan
$repoLock = [System.IO.File]::ReadAllText((Join-Path $harnessDir 'package-lock.json'))
$depsCurrent = ($null -ne $installedLockBefore) -and ($installedLockBefore -eq $repoLock) -and
    (Test-Path (Join-Path $installedHarness 'node_modules'))

if ($ForceDeps) {
    Write-Host '-ForceDeps given; running npm ci regardless.'
    $needDeps = $true
}
else {
    $needDeps = -not $depsCurrent
}

if ($needDeps) {
    Push-Location $installedHarness
    try {
        npm ci --omit=dev --no-audit --no-fund
        Invoke-Checked 'npm ci'
    }
    finally {
        Pop-Location
    }
}
else {
    Write-Host 'Dependencies already current; skipping npm ci.'
}

Write-Host "`nDone. Stable install refreshed at $installDir" -ForegroundColor Green
Write-Host 'If the host was running while files were replaced, restart it (tray Exit or relaunch the desktop shortcut).'
