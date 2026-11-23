# sync-catalog.ps1
# Compatible with Windows PowerShell 5.1 and PowerShell 7+
# Maintains a single catalog.json in sync with all subfolders inside ./midi:
# - Keeps existing entries and custom titles/tags intact
# - Adds any newly discovered .mid / .midi files from all folders
# - Removes entries whose files no longer exist on disk

param(
    [string]$MidiRoot = "midi",
    [string]$OutFile  = "catalog.json"
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path -Path $MidiRoot)) {
    Write-Error "MIDI folder '$MidiRoot' not found in: $(Get-Location)"
}

$resolvedRoot = (Resolve-Path -Path $MidiRoot).Path.TrimEnd('\', '/')
$baseDir      = (Get-Location).Path.TrimEnd('\', '/')
$outPath      = Join-Path $baseDir $OutFile

function Get-RelPath($fromDir, $toPath) {
    $fromNorm = $fromDir.TrimEnd('\', '/') + '\'
    $toNorm   = $toPath
    if ($toNorm.StartsWith($fromNorm, [System.StringComparison]::OrdinalIgnoreCase)) {
        return ($toNorm.Substring($fromNorm.Length) -replace '\\', '/').TrimStart('./')
    }
    $fromUri = New-Object System.Uri($fromNorm)
    $toUri   = New-Object System.Uri($toNorm)
    return ([System.Uri]::UnescapeDataString($fromUri.MakeRelativeUri($toUri).ToString()) -replace '\\', '/').TrimStart('./')
}

# 1. Index existing catalog.json entries by normalized relative path
$existingByPath = @{}
$orderedExistingPaths = New-Object System.Collections.Generic.List[string]

if (Test-Path -Path $outPath) {
    $rawJson = Get-Content -Path $outPath -Raw -Encoding UTF8
    if (-not [string]::IsNullOrWhiteSpace($rawJson)) {
        $parsed = $rawJson | ConvertFrom-Json
        $items  = if ($parsed -is [System.Array]) { $parsed } elseif ($null -ne $parsed) { @($parsed) } else { @() }

        foreach ($item in $items) {
            if ($item.path) {
                $norm = ($item.path -replace '\\', '/').TrimStart('./')
                $key  = $norm.ToLowerInvariant()
                if (-not $existingByPath.ContainsKey($key)) {
                    $existingByPath[$key] = $item
                    $orderedExistingPaths.Add($key)
                }
            }
        }
    }
}

# 2. Scan all .mid / .midi files currently on disk under ./midi
$diskFiles = Get-ChildItem -Path $resolvedRoot -Recurse -File |
    Where-Object { $_.Extension -in @(".mid", ".midi") } |
    Sort-Object FullName

$diskByKey = @{}
$orderedDiskKeys = New-Object System.Collections.Generic.List[string]

foreach ($file in $diskFiles) {
    $relPath = Get-RelPath $baseDir $file.FullName
    $key     = $relPath.ToLowerInvariant()
    if (-not $diskByKey.ContainsKey($key)) {
        $diskByKey[$key] = @{ File = $file; RelPath = $relPath }
        $orderedDiskKeys.Add($key)
    }
}

# 3. Keep valid existing entries in their original order, then append newly found files
$finalEntries = New-Object System.Collections.Generic.List[object]
$keptCount    = 0
$addedCount   = 0
$removedCount = 0

foreach ($key in $orderedExistingPaths) {
    if ($diskByKey.ContainsKey($key)) {
        $entry = $existingByPath[$key]
        $entry.path = $diskByKey[$key].RelPath
        $finalEntries.Add($entry)
        $keptCount++
    } else {
        $removedCount++
    }
}

foreach ($key in $orderedDiskKeys) {
    if ($existingByPath.ContainsKey($key)) {
        continue
    }

    $file      = $diskByKey[$key].File
    $relPath   = $diskByKey[$key].RelPath
    $relToMidi = Get-RelPath $resolvedRoot $file.FullName
    $parts     = $relToMidi -split '/'
    $category  = if ($parts.Length -gt 1) { $parts[0] } else { "Classical MIDI" }

    $rawName = [System.IO.Path]::GetFileNameWithoutExtension($file.Name)
    $title   = (($rawName -replace '_', ' ') -replace '\s+', ' ').Trim()
    $tag     = ""

    if ($title -match '^(BWV\s*\d+[a-zA-Z0-9]*)\s*[-–—:.]?\s*(.+)$') {
        $tag   = ($matches[1] -replace '\s+', ' ').Trim().ToUpper()
        $title = $matches[2].Trim()
    } elseif ($title -match '^(\d{1,4})\s*[-–—:.]?\s*(.+)$') {
        $num = $matches[1].TrimStart('0')
        if ([string]::IsNullOrEmpty($num)) { $num = "0" }
        $tag   = "NO. $num"
        $title = $matches[2].Trim()
    } else {
        $tag = ($category -split '\s+')[0].ToUpper()
    }

    $finalEntries.Add([PSCustomObject]@{
        bwv      = $tag
        title    = $title
        category = $category
        path     = $relPath
    })
    $addedCount++
}

# 4. Write updated catalog.json in UTF-8 (no BOM)
$json = $finalEntries | ConvertTo-Json -Depth 4
[System.IO.File]::WriteAllText($outPath, $json, [System.Text.UTF8Encoding]::new($false))

$catCount = ($finalEntries | Select-Object -ExpandProperty category -Unique).Count
Write-Host "Synced $OutFile -> Kept: $keptCount | Added: $addedCount | Removed: $removedCount | Total: $($finalEntries.Count) tracks across $catCount categories." -ForegroundColor Green