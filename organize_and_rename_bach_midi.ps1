param(
    [string]$RepoPath = "D:\github\meghalaya-philharmonic-society",
    [bool]$DryRun = $true
)

Set-Location $RepoPath
$midiRoot = Join-Path $RepoPath "midi"
if (-not (Test-Path $midiRoot)) {
    Write-Error "Folder not found: $midiRoot"
    exit 1
}

function Decode-TextSmart([byte[]]$bytes) {
    if (-not $bytes -or $bytes.Length -eq 0) { return "" }
    $utf8 = [System.Text.Encoding]::UTF8.GetString($bytes)
    if ($utf8 -notmatch [char]0xFFFD) { return $utf8 }
    try {
        return [System.Text.Encoding]::GetEncoding(932).GetString($bytes)
    } catch {
        return $utf8
    }
}

function Sanitize-FileName([string]$raw) {
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $clean = ($raw -replace "[$invalid]", '') -replace '[^\w\s-]', '' -replace '\s+', '_'
    $clean = ($clean -replace '_+', '_').Trim('_')
    if ($clean.Length -gt 105) { $clean = $clean.Substring(0, 105).Trim('_') }
    return $clean
}

$allDirs = Get-ChildItem -Path $midiRoot -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending
foreach ($dir in $allDirs) {
    $parent = $dir.Parent
    if ($parent -and ($dir.Name -ieq $parent.Name)) {
        $children = Get-ChildItem -Path $dir.FullName -Force
        foreach ($child in $children) {
            $dest = Join-Path $parent.FullName $child.Name
            if (-not (Test-Path $dest)) {
                if ($DryRun) {
                    Write-Host "[FLATTEN PREVIEW] $($child.FullName) --> $dest" -ForegroundColor DarkCyan
                } else {
                    Move-Item -Path $child.FullName -Destination $dest
                }
            }
        }
        if (-not $DryRun) {
            if ((Get-ChildItem -Path $dir.FullName -Force | Measure-Object).Count -eq 0) {
                Remove-Item -Path $dir.FullName -Force
            }
        }
    }
}

$linkMap = @{}
$docFiles = Get-ChildItem -Path $midiRoot -Recurse -Include *.html,*.htm,*.txt
foreach ($doc in $docFiles) {
    $bytes = [System.IO.File]::ReadAllBytes($doc.FullName)
    $decoded = Decode-TextSmart $bytes
    if (-not $decoded) { continue }

    if ($doc.Extension -ieq ".html" -or $doc.Extension -ieq ".htm") {
        $pattern = '(?is)<a[^>]+href=["'']([^"''#]+\.midi?)["''][^>]*>(.*?)</a>([^<\r\n]*)'
        foreach ($m in [regex]::Matches($decoded, $pattern)) {
            $href = [System.Uri]::UnescapeDataString($m.Groups[1].Value.Trim())
            try {
                $targetFull = [System.IO.Path]::GetFullPath((Join-Path $doc.DirectoryName $href))
            } catch { continue }

            $desc = (($m.Groups[2].Value + " " + $m.Groups[3].Value) -replace '<[^>]+>', ' ') -replace '\s+', ' '
            $desc = [System.Net.WebUtility]::HtmlDecode($desc).Trim(' ', '-', ':', '|', ',', '.')
            if ($desc) { $linkMap[$targetFull] = $desc }
        }
    }
}

$midiFiles = Get-ChildItem -Path $midiRoot -Recurse -Include *.mid,*.midi | Sort-Object FullName
$catalog = @()

foreach ($mid in $midiFiles) {
    $relFromMidi = $mid.FullName.Substring($midiRoot.Length + 1)
    $parts = $relFromMidi -split '[\\/]'

    $mainCat = if ($parts.Length -ge 2) {
        ($parts[0] -replace '^J\.\s*S\.\s*Bach\s*-\s*', '').Trim()
    } else {
        "General Repertoire"
    }
    $subCat = if ($parts.Length -ge 3) {
        ($parts[1..($parts.Length - 2)] -join ' / ')
    } else {
        ""
    }

    $stem = $mid.BaseName
    $bwv = "BWV --"
    $movSuffix = ""
    $descText = ""

    if ($linkMap.ContainsKey($mid.FullName)) {
        $descText = $linkMap[$mid.FullName]
    }

    $folderTxt = Join-Path $mid.DirectoryName ($mid.Directory.Name + ".txt")
    $txtHeader = ""
    if (Test-Path $folderTxt) {
        $txtContent = Decode-TextSmart ([System.IO.File]::ReadAllBytes($folderTxt))
        $lines = $txtContent -split "(\r?\n)"
        foreach ($line in $lines) {
            $trimmed = $line.Trim()
            if ($trimmed -ne "" -and $trimmed -ne "`r" -and $trimmed -ne "`n") {
                $txtHeader = $trimmed
                break
            }
        }
    }

    if ($stem -match '^ca0*(\d+)(?:[_-](\d+))?$' -or $mid.Directory.Name -match '^ca0*(\d+)$') {
        $cantataNum = [int]$matches[1]
        $bwv = "BWV $cantataNum"
        if ($stem -match '[_-](\d+)$') {
            $movSuffix = "Mvt_$($matches[1])"
        }
    } elseif ($descText -match '(BWV[\s_-]*(?:Anh[\s_-]*)?\d+[a-z]?)') {
        $bwv = ($matches[1] -replace '[_-]+', ' ').ToUpper().Trim()
    } elseif ($stem -match '(?:bwv)?0*(\d+[a-z]?)') {
        $bwv = "BWV " + $matches[1].ToUpper()
    }

    $titleParts = @()
    if ($descText) { $titleParts += $descText }
    if ($txtHeader -and ($titleParts -notcontains $txtHeader)) { $titleParts += $txtHeader }
    if ($titleParts.Count -eq 0) {
        $cleanedStem = ($stem -replace 'BWV[\s_-]*(?:Anh[\s_-]*)?\d+[a-z]?[\s_-]*', '').Replace('-', ' ').Replace('_', ' ').Trim()
        if (-not $cleanedStem) { $cleanedStem = $stem }
        $titleParts += $cleanedStem
    }
    $displayTitle = ($titleParts -join " - ")

    $nameCore = if ($bwv -ne "BWV --") {
        $bwvToken = ($bwv -replace '\s+', '_')
        if ($movSuffix) { "${bwvToken}_${movSuffix}_${stem}" } else { "${bwvToken}_${displayTitle}" }
    } else {
        $displayTitle
    }

    $safeBase = Sanitize-FileName $nameCore
    if (-not $safeBase) { $safeBase = Sanitize-FileName $stem }

    $newFull = Join-Path $mid.DirectoryName ($safeBase + $mid.Extension.ToLower())
    $counter = 2
    while ((Test-Path $newFull) -and ($newFull -ne $mid.FullName)) {
        $newFull = Join-Path $mid.DirectoryName ("{0}_{1}{2}" -f $safeBase, $counter, $mid.Extension.ToLower())
        $counter++
    }

    if ($DryRun) {
        if ($newFull -ne $mid.FullName) {
            Write-Host "[RENAME PREVIEW] $($mid.Name) --> $([System.IO.Path]::GetFileName($newFull))" -ForegroundColor Cyan
        }
    } else {
        if ($newFull -ne $mid.FullName) {
            Rename-Item -Path $mid.FullName -NewName ([System.IO.Path]::GetFileName($newFull))
        }
    }

    $finalPath = if ($DryRun) { $mid.FullName } else { $newFull }
    $finalRel = $finalPath.Substring($RepoPath.Length + 1).Replace('\', '/')

    $catalog += [PSCustomObject]@{
        bwv         = $bwv
        title       = $displayTitle
        category    = $mainCat
        subcategory = $subCat
        path        = $finalRel
    }
}

if (-not $DryRun) {
    $catalog | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $RepoPath "catalog.json") -Encoding UTF8
    Write-Host "Completed! Processed $($catalog.Count) MIDI files and updated catalog.json." -ForegroundColor Green
} else {
    Write-Host "Dry run complete for $($catalog.Count) MIDI files. Run with -DryRun:`$false to apply folder cleanup, file renames, and catalog.json." -ForegroundColor Yellow
}

