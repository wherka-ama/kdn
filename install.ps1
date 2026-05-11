# Copyright (C) 2026 Red Hat, Inc.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
# http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
#
# SPDX-License-Identifier: Apache-2.0

<#
.SYNOPSIS
    Installs kdn from GitHub Releases.

.DESCRIPTION
    Downloads and installs the kdn binary for Windows from
    https://github.com/openkaiden/kdn/releases

.PARAMETER BinDir
    Installation directory. Defaults to $env:USERPROFILE\.local\bin
    Can also be set via the BINSTALLER_BIN environment variable.

.PARAMETER Tag
    Release tag to install (e.g. "v0.14.0"). Defaults to "latest".

.PARAMETER Debug
    Enable verbose debug logging.

.PARAMETER Quiet
    Suppress all output except errors.

.PARAMETER DryRun
    Download and verify without actually installing.

.EXAMPLE
    irm https://github.com/openkaiden/kdn/releases/latest/download/install.ps1 | iex

.EXAMPLE
    .\install.ps1 -Tag v0.14.0 -BinDir C:\Tools
#>
param(
    [string]$BinDir = "",
    [string]$Tag    = "latest",
    [switch]$Debug,
    [switch]$Quiet,
    [switch]$DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---- Constants ----
$NAME   = "kdn"
$REPO   = "openkaiden/kdn"
$BINARY = "kdn.exe"

# ---- Logging ----
function Write-Log-Info([string]$msg) {
    if (-not $Quiet) { Write-Host "${REPO}: info  $msg" }
}
function Write-Log-Debug([string]$msg) {
    if ($Debug)      { Write-Host "${REPO}: debug $msg" }
}
function Write-Log-Err([string]$msg) {
    Write-Host "${REPO}: err   $msg" -ForegroundColor Red
}
function Write-Log-Crit([string]$msg) {
    Write-Host "${REPO}: crit  $msg" -ForegroundColor Red
}

# ---- Architecture detection ----
function Get-Arch {
    $arch = $env:PROCESSOR_ARCHITECTURE
    if ($env:BINSTALLER_ARCH) { $arch = $env:BINSTALLER_ARCH }
    switch ($arch) {
        "AMD64"   { return "amd64" }
        "ARM64"   { return "arm64" }
        "x86"     { Write-Log-Crit "32-bit Windows is not supported."; exit 1 }
        default   { Write-Log-Crit "Unknown architecture: $arch"; exit 1 }
    }
}

# ---- GitHub API: fetch release metadata (tag + asset digests) ----
function Resolve-Release([string]$tag) {
    $url = if ($tag -eq "latest") {
        Write-Log-Info "Checking GitHub for latest tag..."
        "https://api.github.com/repos/${REPO}/releases/latest"
    } else {
        "https://api.github.com/repos/${REPO}/releases/tags/${tag}"
    }
    try {
        $release = Invoke-RestMethod -Uri $url -Headers @{ "User-Agent" = "install.ps1" }
    } catch {
        Write-Log-Crit "Could not fetch release from GitHub: $_"
        exit 1
    }
    if (-not $release.tag_name) {
        Write-Log-Crit "Could not determine tag for ${REPO}"
        exit 1
    }
    return $release
}

# ---- Download a file with progress ----
function Download-File([string]$url, [string]$dest) {
    Write-Log-Info "Downloading $url"
    try {
        $prevPref = $ProgressPreference
        if ($Quiet) { $ProgressPreference = "SilentlyContinue" }
        Invoke-WebRequest -Uri $url -OutFile $dest -UseBasicParsing
        $ProgressPreference = $prevPref
    } catch {
        Write-Log-Crit "Download failed for ${url}: $_"
        exit 1
    }
}

# ---- Main ----
function Main {
    # Resolve installation directory
    if (-not $BinDir) {
        $BinDir = if ($env:BINSTALLER_BIN) { $env:BINSTALLER_BIN } `
                  else { Join-Path $env:USERPROFILE ".local\bin" }
    }

    $arch = Get-Arch
    Write-Log-Info "Detected platform: windows/$arch"

    $release     = Resolve-Release $Tag
    $resolvedTag = $release.tag_name
    $version     = $resolvedTag.TrimStart("v")
    Write-Log-Info "Resolved version: $version (tag: $resolvedTag)"

    $assetName   = "${NAME}_${version}_windows_${arch}.zip"
    $downloadUrl = "https://github.com/${REPO}/releases/download/${resolvedTag}/${assetName}"

    # Extract expected SHA256 from API response (digest field: "sha256:<hex>")
    $expectedHash = $null
    $asset = $release.assets | Where-Object { $_.name -eq $assetName }
    if ($asset -and $asset.digest -match "^sha256:(.+)$") {
        $expectedHash = $Matches[1].ToUpper()
        Write-Log-Debug "Expected checksum: $expectedHash"
    }

    # Create temp directory
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
    New-Item -ItemType Directory -Path $tmpDir | Out-Null
    Write-Log-Debug "Temp directory: $tmpDir"

    try {
        $zipPath = Join-Path $tmpDir $assetName
        Download-File $downloadUrl $zipPath

        # Verify checksum
        if ($expectedHash) {
            Write-Log-Info "Verifying checksum..."
            $actualHash = (Get-FileHash -LiteralPath $zipPath -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash) {
                Write-Log-Crit "Checksum verification failed for $assetName"
                Write-Log-Crit "Expected: $expectedHash"
                Write-Log-Crit "Got:      $actualHash"
                exit 1
            }
            Write-Log-Info "Checksum verification successful"
        } else {
            Write-Log-Info "No checksum available, skipping verification"
        }

        Write-Log-Info "Extracting $assetName..."
        Expand-Archive -LiteralPath $zipPath -DestinationPath $tmpDir -Force
        Write-Log-Debug "Extraction complete"

        $binaryPath = Join-Path $tmpDir $BINARY
        if (-not (Test-Path $binaryPath)) {
            Write-Log-Crit "Binary not found after extraction: $binaryPath"
            Write-Log-Debug "Contents of ${tmpDir}:"
            Get-ChildItem $tmpDir -Recurse | ForEach-Object { Write-Log-Debug "  $($_.FullName)" }
            exit 1
        }

        $installPath = Join-Path $BinDir $BINARY

        if ($DryRun) {
            Write-Log-Info "[DRY RUN] $BINARY dry-run installation succeeded! (Would install to: $installPath)"
        } else {
            if (-not (Test-Path $BinDir)) {
                Write-Log-Debug "Creating directory: $BinDir"
                New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
            }
            Write-Log-Info "Installing binary to $installPath"
            Copy-Item -Path $binaryPath -Destination $installPath -Force
            Write-Log-Info "$BINARY installation complete!"

            # Inform the user if BinDir is not on PATH
            $pathDirs = $env:PATH -split ";"
            if ($BinDir -notin $pathDirs) {
                Write-Host ""
                Write-Host "NOTE: $BinDir is not in your PATH." -ForegroundColor Yellow
                Write-Host "To add it permanently, run:" -ForegroundColor Yellow
                Write-Host "  [System.Environment]::SetEnvironmentVariable('PATH', `$env:PATH + ';$BinDir', 'User')" -ForegroundColor Cyan
            }
        }
    } finally {
        Write-Log-Debug "Cleaning up temp directory: $tmpDir"
        Remove-Item -Recurse -Force -Path $tmpDir -ErrorAction SilentlyContinue
    }
}

Main
