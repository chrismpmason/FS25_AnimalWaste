# build.ps1
# Zip the mod and drop the result into the FS25 mods folder so the game
# picks it up on next launch.
#
# Run from anywhere:
#   powershell -ExecutionPolicy Bypass -File .\build.ps1
# Or, if you've allowed local scripts:
#   .\build.ps1
#
# IMPORTANT: this uses the .NET ZipArchive API directly so we can write
# forward-slash entry names. PowerShell's built-in Compress-Archive writes
# backslash entries on Windows, which violates the ZIP spec and which
# FS25's resource loader cannot read.

[CmdletBinding()]
param(
    [string]$ModName = 'FS25_AnimalWaste',
    [string]$ModsDir = "$env:USERPROFILE\Documents\My Games\FarmingSimulator2025\mods"
)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$zipName = "$ModName.zip"
$localZip = Join-Path $root $zipName
$targetZip = Join-Path $ModsDir $zipName

# Files and folders to include. Anything else (build.ps1, README, the zip
# itself, .git, etc.) is excluded.
$includePaths = @(
    'modDesc.xml',
    'icon_animalWaste.dds',
    'icon_animalWaste.png',
    'scripts',
    'i18n',
    'gui'
)

# Collect (entryName, sourcePath) pairs, recursing into folders.
$entries = @()
foreach ($p in $includePaths) {
    $full = Join-Path $root $p
    if (-not (Test-Path -LiteralPath $full)) {
        Write-Warning "Skipping missing path: $p"
        continue
    }
    $item = Get-Item -LiteralPath $full
    if ($item.PSIsContainer) {
        Get-ChildItem -LiteralPath $full -Recurse -File | ForEach-Object {
            $rel = $_.FullName.Substring($root.Length).TrimStart('\','/') -replace '\\','/'
            $entries += [pscustomobject]@{ Entry = $rel; Source = $_.FullName }
        }
    } else {
        $entries += [pscustomobject]@{ Entry = $p -replace '\\','/'; Source = $item.FullName }
    }
}

if ($entries.Count -eq 0) {
    throw "Nothing to zip. Are you running this from the mod root?"
}

if (Test-Path -LiteralPath $localZip) {
    Remove-Item -LiteralPath $localZip -Force
}

Write-Host "Zipping $($entries.Count) file(s) -> $localZip"

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$stream = [System.IO.File]::Open($localZip, [System.IO.FileMode]::Create)
try {
    $archive = New-Object System.IO.Compression.ZipArchive(
        $stream, [System.IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($e in $entries) {
            # CreateEntryFromFile preserves the entry name we pass exactly,
            # so as long as we pass forward slashes the archive is spec-compliant.
            [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
                $archive, $e.Source, $e.Entry,
                [System.IO.Compression.CompressionLevel]::Optimal) | Out-Null
        }
    } finally {
        $archive.Dispose()
    }
} finally {
    $stream.Dispose()
}

if (-not (Test-Path -LiteralPath $ModsDir)) {
    throw "Mods folder not found: $ModsDir"
}

Write-Host "Copying to $targetZip"
Copy-Item -LiteralPath $localZip -Destination $targetZip -Force

$size = (Get-Item -LiteralPath $targetZip).Length
Write-Host ("Done. {0} ({1:N0} bytes) installed." -f $zipName, $size)
