# OpenAgents CLI installer for Windows PowerShell.
# https://openagents.com/install.ps1
#
# Usage:
#   irm https://openagents.com/install.ps1 | iex
#
# Optional:
#   $env:OPENAGENTS_CHANNEL = 'stable'
#   $env:OPENAGENTS_VERSION = '0.1.1'
#   $env:OPENAGENTS_BIN_DIR = "$env:USERPROFILE\.openagents\bin"
#
# Do not `exit` from this file. `irm | iex` runs in the reader's PowerShell,
# and `exit` closes that window. Throw instead.
#
# The homepage used to print `curl … | sh`. PowerShell has no `sh`, and its
# `curl` is Invoke-WebRequest, which does not accept `-fsSL`.

$ErrorActionPreference = 'Stop'

$BaseUrl = 'https://openagents.com/releases'
$Channel = if ($env:OPENAGENTS_CHANNEL) { $env:OPENAGENTS_CHANNEL } else { 'stable' }
$HomeDir = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
$DownloadDir = Join-Path $HomeDir '.openagents\downloads'
$BinDir = if ($env:OPENAGENTS_BIN_DIR) { $env:OPENAGENTS_BIN_DIR } else { Join-Path $HomeDir '.openagents\bin' }

function Test-OpenAgentsVersion([string]$Value) {
    return $Value -match '^[0-9]+\.[0-9]+\.[0-9]+(-[A-Za-z0-9._]+)?$'
}

$Version = $env:OPENAGENTS_VERSION
if (-not $Version) {
    try {
        $Version = (Invoke-RestMethod -Uri "$BaseUrl/$Channel").ToString().Trim()
    } catch {
        throw "Could not resolve the '$Channel' channel from $BaseUrl/$Channel."
    }
}

if (-not (Test-OpenAgentsVersion $Version)) {
    throw "Invalid version format: $Version (expected X.Y.Z or X.Y.Z-suffix)"
}

# Only windows-x86_64 is published. Windows on ARM runs that build.
$Platform = 'windows-x86_64'
$ArtifactUrl = "$BaseUrl/openagents-$Version-$Platform"
$SumsName = "openagents-$Version-$Platform.exe"

New-Item -ItemType Directory -Force -Path $DownloadDir, $BinDir | Out-Null

$Tmp = Join-Path $DownloadDir "openagents-$Platform.exe.tmp"
$Dest = Join-Path $DownloadDir "openagents-$Platform.exe"

Write-Host "Installing OpenAgents CLI v$Version ($Platform)..."

try {
    Invoke-WebRequest -Uri $ArtifactUrl -OutFile $Tmp -UseBasicParsing
} catch {
    if (Test-Path $Tmp) { Remove-Item -Force $Tmp }
    throw "Could not download $ArtifactUrl. No local fallback is used: an installer must install what it says it did."
}

$SumsTmp = "$Tmp.sums"
try {
    Invoke-WebRequest -Uri "$BaseUrl/SHA256SUMS-$Version" -OutFile $SumsTmp -UseBasicParsing
} catch {
    Remove-Item -Force $Tmp, $SumsTmp -ErrorAction SilentlyContinue
    throw "Could not download SHA256SUMS-$Version; refusing to install unverified bytes."
}

$Expected = $null
Get-Content $SumsTmp | ForEach-Object {
    $parts = $_ -split '\s+', 2
    if ($parts.Count -eq 2 -and ($parts[1] -eq $SumsName -or $parts[1] -eq "*$SumsName")) {
        $Expected = $parts[0].ToLowerInvariant()
    }
}

if (-not $Expected) {
    Remove-Item -Force $Tmp, $SumsTmp -ErrorAction SilentlyContinue
    throw "SHA256SUMS-$Version names no entry for $SumsName; refusing to install."
}

$Actual = (Get-FileHash -Algorithm SHA256 -Path $Tmp).Hash.ToLowerInvariant()
if ($Actual -ne $Expected) {
    Remove-Item -Force $Tmp, $SumsTmp -ErrorAction SilentlyContinue
    throw "Checksum mismatch for $SumsName.`n  expected $Expected`n  actual   $Actual"
}

# Historical releases ship only the CLI. A missing sums entry skips the
# local inference door instead of failing the install.
$ApiSumsName = "openagents-coder-api-$Version-$Platform.exe"
$ApiExpected = $null
Get-Content $SumsTmp | ForEach-Object {
    $parts = $_ -split '\s+', 2
    if ($parts.Count -eq 2 -and ($parts[1] -eq $ApiSumsName -or $parts[1] -eq "*$ApiSumsName")) {
        $ApiExpected = $parts[0].ToLowerInvariant()
    }
}

Remove-Item -Force $SumsTmp
Move-Item -Force $Tmp $Dest
Write-Host "  Verified sha256 $Actual."

foreach ($Name in @('openagents', 'coder', 'oa')) {
    Copy-Item -Force $Dest (Join-Path $BinDir "$Name.exe")
}

if ($ApiExpected) {
    $ApiUrl = "$BaseUrl/openagents-coder-api-$Version-$Platform"
    $ApiTmp = Join-Path $DownloadDir "openagents-coder-api-$Platform.exe.tmp"
    $ApiDest = Join-Path $DownloadDir "openagents-coder-api-$Platform.exe"
    Write-Host "Installing the local Coder inference door..."
    try {
        Invoke-WebRequest -Uri $ApiUrl -OutFile $ApiTmp -UseBasicParsing
    } catch {
        if (Test-Path $ApiTmp) { Remove-Item -Force $ApiTmp }
        throw "Could not download $ApiUrl. No local fallback is used: an installer must install what it says it did."
    }
    $ApiActual = (Get-FileHash -Algorithm SHA256 -Path $ApiTmp).Hash.ToLowerInvariant()
    if ($ApiActual -ne $ApiExpected) {
        Remove-Item -Force $ApiTmp -ErrorAction SilentlyContinue
        throw "Checksum mismatch for $ApiSumsName.`n  expected $ApiExpected`n  actual   $ApiActual"
    }
    Move-Item -Force $ApiTmp $ApiDest
    Copy-Item -Force $ApiDest (Join-Path $BinDir 'openagents-coder-api.exe')
    Write-Host "  Verified sha256 $ApiActual."
}

$UserPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if (-not $UserPath) { $UserPath = '' }
$PathParts = $UserPath -split ';' | Where-Object { $_ -ne '' }
if ($PathParts -notcontains $BinDir) {
    $NewPath = if ($UserPath) { "$BinDir;$UserPath" } else { $BinDir }
    [Environment]::SetEnvironmentVariable('Path', $NewPath, 'User')
    Write-Host "  Added $BinDir to your user PATH."
}
if ($env:Path -notlike "*$BinDir*") {
    $env:Path = "$BinDir;$env:Path"
}

Write-Host ""
Write-Host "OpenAgents v$Version installed."

$Coder = Join-Path $BinDir 'coder.exe'

# Do not launch Coder inside an existing session. A nested TUI enables
# mouse tracking, then the outer session kills it, and the terminal
# keeps emitting CSI mouse reports as text.
if ($env:OPENAGENTS_INSTALL_NO_LAUNCH) {
    Write-Host "Coder is already running in this terminal; not launching another session."
    Write-Host "The installed binary is $Coder"
} elseif ([Environment]::UserInteractive -and -not [Console]::IsOutputRedirected) {
    Write-Host "Loading Coder..."
    & $Coder
} else {
    Write-Host "Open a new terminal, then run: openagents --version"
}
