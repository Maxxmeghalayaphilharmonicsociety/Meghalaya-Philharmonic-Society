param(
    [string]$RepoPath = "D:\github\meghalaya-philharmonic-society",
    [int]$DryRun = 0
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

# Japanese -> English classical music & Bach vocabulary map
$jpToEn = [ordered]@{
    "カンタータ"       = "Cantata"
    "教会カンタータ"   = "Church Cantata"
    "世俗カンタータ"   = "Secular Cantata"
    "コラール"         = "Chorale"
    "コラール前奏曲"   = "Chorale Prelude"
    "アリア"           = "Aria"
    "レチタティーヴォ" = "Recitative"
    "レチタティーボ"   = "Recitative"
    "シンフォニア"     = "Sinfonia"
    "前奏曲"           = "Prelude"
    "フーガ"           = "Fugue"
    "組曲"             = "Suite"
    "パルティータ"     = "Partita"
    "ソナタ"           = "Sonata"
    "協奏曲"           = "Concerto"
    "トッカータ"       = "Toccata"
    "幻想曲"           = "Fantasy"
    "変奏曲"           = "Variations"
    "二重奏"           = "Duet"
    "三重奏"           = "Trio"
    "合唱"             = "Chorus"
    "ソプラノ"         = "Soprano"
    "アルト"           = "Alto"
    "テノール"         = "Tenor"
    "バス"             = "Bass"
    "独唱"             = "Solo"
    "管弦楽"           = "Orchestra"
    "オーケストラ"     = "Orchestra"
    "チェロ"           = "Cello"
    "ヴァイオリン"     = "Violin"
    "フルート"         = "Flute"
    "オーボエ"         = "Oboe"
    "トランペット"     = "Trumpet"
    "オルガン"         = "Organ"
    "チェンバロ"       = "Harpsichord"
    "ピアノ"           = "Piano"
    "第1番"            = "No. 1"
    "第2番"            = "No. 2"
    "第3番"            = "No. 3"
    "第4番"            = "No. 4"
    "第5番"            = "No. 5"
    "第6番"            = "No. 6"
    "第7番"            = "No. 7"
    "第8番"            = "No. 8"
    "第9番"            = "No. 9"
    "第10番"           = "No. 10"
    "第1曲"            = "Mvt. 1"
    "第2曲"            = "Mvt. 2"
    "第3曲"            = "Mvt. 3"
    "第4曲"            = "Mvt. 4"
    "第5曲"            = "Mvt. 5"
    "第6曲"            = "Mvt. 6"
    "第7曲"            = "Mvt. 7"
    "第8曲"            = "Mvt. 8"
    "ト長調"           = "in G Major"
    "ニ短調"           = "in D Minor"
    "ハ長調"           = "in C Major"
    "イ短調"           = "in A Minor"
    "ヘ長調"           = "in F Major"
    "変ロ長調"         = "in B-flat Major"
    "変ホ長調"         = "in E-flat Major"
    "ホ短調"           = "in E Minor"
    "ロ短調"           = "in B Minor"
    "バッハ"           = "J.S. Bach"
}

function Convert-JapaneseToEnglish([string]$text) {
    if (-not $text) { return "" }
    $out = $text
    foreach ($key in $jpToEn.Keys) {
        $out = $out.Replace($key, " " + $jpToEn[$key] + " ")
    }
    # Remove any remaining Hiragana, Katakana, or CJK Kanji characters cleanly
    $out = $out -replace '[\u3040-\u309F\u30A0-\u30FF\u4E00-\u9FFF\uFF00-\uFFEF]', ' '
    $out = ($out -replace '\s+', ' ').Trim(' ', '-', '_', ':', '|', ',')
    return $out
}

function Sanitize-AsciiFileName([string]$raw) {
    $asciiOnly = $raw -replace '[^\x20-\x7E]', ' '
    $invalid = [System.IO.Path]::GetInvalidFileNameChars() -join ''
    $clean = ($asciiOnly -replace "[$invalid]", '') -replace '[^\w\s-]', '' -replace '\s+', '_'
    $clean = ($clean -replace '_+', '_').Trim('_')
    if ($clean.Length -gt 100) { $clean = $clean.Substring(0, 100).Trim('_') }
    return $clean
}

# Build HTML link description lookup
$linkMap = @{}
$docFiles = Get-ChildItem -Path $midiRoot -Recurse -Include *.html,*.htm
foreach ($doc in $docFiles) {
    $decoded = Decode-TextSmart ([System.IO.File]::ReadAllBytes($doc.FullName))
    if (-not $decoded) { continue }
    $pattern = '(?is)<a[^>]+href=["'']([^"''#]+\.midi?)["''][^>]*>(.*?)</a>([^<\r\n]*)'
    foreach ($m in [regex]::Matches($decoded, $pattern)) {
        $href = [System.Uri]::UnescapeDataString($m.Groups[1].Value.Trim())
        try {
            $targetFull = [System.IO.Path]::GetFullPath((Join-Path $doc.DirectoryName $href))
        } catch { continue }
        $desc = (($m.Groups[2].Value + " " + $m.Groups[3].Value) -replace '<[^>]+>', ' ') -replace '\s+', ' '
        $desc = Convert-JapaneseToEnglish ([System.Net.WebUtility]::HtmlDecode($desc))
        if ($desc) { $linkMap[$targetFull] = $desc }
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
    $mvtNum = ""
    $descText = ""

    if ($linkMap.ContainsKey($mid.FullName)) {
        $descText = $linkMap[$mid.FullName]
    }

    # Extract movement or BWV from ca001_01 or already-renamed BWV_1_Mvt_01_ca001_01
    if ($stem -match 'BWV[_\s-]*(\d+).*?Mvt[_\s-]*(\d+)') {
        $bwv = "BWV $([int]$matches[1])"
        $mvtNum = $matches[2]
    } elseif ($stem -match '^ca0*(\d+)(?:[_-](\d+))?$' -or $mid.Directory.Name -match '^ca0*(\d+)$') {
        $bwv = "BWV $([int]$matches[1])"
        if ($stem -match '[_-](\d+)$') { $mvtNum = $matches[1] }
    } elseif ($descText -match '(BWV[\s_-]*(?:Anh[\s_-]*)?\d+[a-z]?)') {
        $bwv = ($matches[1] -replace '[_-]+', ' ').ToUpper().Trim()
    } elseif ($stem -match '(?:bwv)?0*(\d+[a-z]?)') {
        $bwv = "BWV " + $matches[1].ToUpper()
    }

    # Check matching .txt file in folder and translate Japanese lines to English
    $folderTxt = Join-Path $mid.DirectoryName ($mid.Directory.Name + ".txt")
    $txtEnParts = @()
    if (Test-Path $folderTxt) {
        $txtRaw = Decode-TextSmart ([System.IO.File]::ReadAllBytes($folderTxt))
        foreach ($line in ($txtRaw -split "`r?`n")) {
            $enLine = Convert-JapaneseToEnglish $line
            if ($enLine -and ($enLine.Length -gt 2)) {
                $txtEnParts += $enLine
            }
        }
    }

    $titleParts = @()
    if ($descText) { $titleParts += $descText }
    if ($txtEnParts.Count -gt 0) {
        $titleParts += ($txtEnParts | Select-Object -First 2)
    }
    if ($mvtNum) {
        $titleParts += "Movement $([int]$mvtNum)"
    }
    if ($titleParts.Count -eq 0) {
        $titleParts += (Convert-JapaneseToEnglish $stem)
    }

    $displayTitle = ($titleParts -join " - ")
    if (-not $displayTitle) { $displayTitle = "Bach Movement" }

    $bwvSlug = if ($bwv -ne "BWV --") { ($bwv -replace '\s+', '_') + "_" } else { "" }
    $mvtSlug = if ($mvtNum) { "Mvt_$([int]$mvtNum)_" } else { "" }
    $cleanTitleSlug = Sanitize-AsciiFileName $displayTitle
    $safeBase = Sanitize-AsciiFileName "${bwvSlug}${mvtSlug}${cleanTitleSlug}"
    if (-not $safeBase) { $safeBase = "Bach_Piece" }

    $newFull = Join-Path $mid.DirectoryName ($safeBase + $mid.Extension.ToLower())
    $counter = 2
    while ((Test-Path $newFull) -and ($newFull -ne $mid.FullName)) {
        $newFull = Join-Path $mid.DirectoryName ("{0}_{1}{2}" -f $safeBase, $counter, $mid.Extension.ToLower())
        $counter++
    }

    if ($DryRun -eq 0) {
        if ($newFull -ne $mid.FullName) {
            Rename-Item -Path $mid.FullName -NewName ([System.IO.Path]::GetFileName($newFull))
        }
    } else {
        if ($newFull -ne $mid.FullName) {
            Write-Host "[PREVIEW] $($mid.Name) -> $([System.IO.Path]::GetFileName($newFull))" -ForegroundColor Cyan
        }
    }

    $finalPath = if ($DryRun -eq 0) { $newFull } else { $mid.FullName }
    $finalRel = $finalPath.Substring($RepoPath.Length + 1).Replace('\', '/')

    $catalog += [PSCustomObject]@{
        bwv         = $bwv
        title       = $displayTitle
        category    = $mainCat
        subcategory = $subCat
        path        = $finalRel
    }
}

if ($DryRun -eq 0) {
    $catalog | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $RepoPath "catalog.json") -Encoding UTF8
    Write-Host "Updated $($catalog.Count) MIDI entries in English and wrote catalog.json." -ForegroundColor Green
} else {
    Write-Host "Preview complete ($($catalog.Count) files). Run with -DryRun 0 to apply." -ForegroundColor Yellow
}