# LinguaPi Corpus Downloader (Windows / PowerShell 5.1+)
#
# Downloads public-domain texts for offline use:
#   - Project Gutenberg  (Latin-script languages: es, de, pt, it, fr, ja)
#   - Wikisource         (Indian-script languages: hi, kn, te)
#
# Usage:
#   .\scripts\download-corpus.ps1                          # all languages
#   .\scripts\download-corpus.ps1 Spanish German           # specific languages
#   .\scripts\download-corpus.ps1 -BooksPerLang 50         # more books
#   .\scripts\download-corpus.ps1 -Force Spanish           # re-download

#Requires -Version 5.1
[CmdletBinding()]
param(
    [Parameter(ValueFromRemainingArguments)]
    [string[]]$Languages = @(),

    [int]$BooksPerLang = 10,
    [string]$CorpusDir = "",
    [double]$Delay = 0.5,
    [switch]$Force
)

$ErrorActionPreference = "Stop"

# Handle env-var defaults (PS 5.1 has no ternary operator)
if ($env:BOOKS_PER_LANG) { $BooksPerLang = [int]$env:BOOKS_PER_LANG }
if ($env:CORPUS_DIR) {
    $CorpusDir = $env:CORPUS_DIR
} elseif (-not $CorpusDir) {
    $CorpusDir = Join-Path $env:USERPROFILE ".linguapi\corpus"
}

$GutendexBase = "https://gutendex.com/books"

$LangCodes = @{
    Spanish    = "es";  German     = "de";  Portuguese = "pt"
    Italian    = "it";  Kannada    = "kn";  Telugu     = "te"
}

# Source routing: Gutenberg has very poor coverage for Indian-script languages
$LangSource = @{
    Spanish    = "gutenberg";  German     = "gutenberg";  Portuguese = "gutenberg"
    Italian    = "gutenberg";  Kannada    = "wikisource";  Telugu     = "wikisource"
}

function Write-Info  ([string]$msg) { Write-Host "  >> $msg" -ForegroundColor Cyan }
function Write-Ok    ([string]$msg) { Write-Host "  OK $msg" -ForegroundColor Green }
function Write-Warn  ([string]$msg) { Write-Host "  !! $msg" -ForegroundColor Yellow }
function Fail        ([string]$msg) { Write-Host "ERROR: $msg" -ForegroundColor Red; exit 1 }

# ── Project Gutenberg ─────────────────────────────────────────────────────────

function Get-GutenbergBookList {
    param([object]$Data)
    $books = @()
    foreach ($book in $Data.results) {
        $url = $null
        foreach ($key in ($book.formats.PSObject.Properties.Name | Sort-Object)) {
            if ($key.StartsWith("text/plain")) {
                $val = $book.formats.$key
                if (-not $val.EndsWith(".zip")) { $url = $val; break }
            }
        }
        if ($url) {
            $books += [PSCustomObject]@{
                Id    = $book.id
                Title = ($book.title -replace "\t", " ")
                Url   = $url
            }
        }
    }
    return $books
}

function Sync-GutenbergLanguage {
    param([string]$LangName)
    $code    = $LangCodes[$LangName]
    $langDir = Join-Path $CorpusDir $code
    New-Item -ItemType Directory -Path $langDir -Force | Out-Null

    $existing = @(Get-ChildItem $langDir -Filter "pg*.txt" -ErrorAction SilentlyContinue).Count
    $need     = $BooksPerLang - $existing
    if ($need -le 0) { Write-Ok "$LangName already has $existing Gutenberg books."; return }

    Write-Host ""
    Write-Host "  $LangName ($code -- Gutenberg)  need $need more, have $existing" -ForegroundColor White

    $page1Url = $GutendexBase + "/?languages=" + $code + "&mime_type=text%2Fplain&page=1"
    try { $firstPage = Invoke-RestMethod -Uri $page1Url }
    catch { Write-Warn "Cannot reach gutendex for $LangName : $_"; return }

    if ($firstPage.count -eq 0) {
        Write-Warn "gutendex returned 0 books for $LangName -- skipping."
        return
    }

    $totalPages = [math]::Ceiling($firstPage.count / 32)
    $downloaded = 0; $skipped = 0; $failed = 0; $page = 1

    while ($downloaded -lt $need -and $page -le [math]::Min($totalPages, 30)) {
        $pageData = if ($page -eq 1) { $firstPage } else {
            $pageUrl = $GutendexBase + "/?languages=" + $code + "&mime_type=text%2Fplain&page=" + $page
            try { Invoke-RestMethod -Uri $pageUrl }
            catch { $page++; continue }
        }

        foreach ($book in (Get-GutenbergBookList $pageData)) {
            if ($downloaded -ge $need) { break }
            $fp = Join-Path $langDir ("pg" + $book.Id + ".txt")
            if ((Test-Path $fp) -and (Get-Item $fp).Length -gt 0) { $skipped++; continue }

            $title = if ($book.Title.Length -gt 55) { $book.Title.Substring(0,55) + "..." } else { $book.Title }
            Write-Host ("    [{0}/{1}] {2} ..." -f ($existing+$downloaded+1), $BooksPerLang, $title) -NoNewline
            try {
                Invoke-WebRequest -Uri $book.Url -OutFile $fp -UseBasicParsing -TimeoutSec 60
                if ((Get-Item $fp).Length -eq 0) { throw "empty" }
                $kb = [math]::Round((Get-Item $fp).Length / 1024)
                Write-Host (" done ($kb KB)") -ForegroundColor Green
                $downloaded++
                Start-Sleep -Milliseconds ([int]($Delay * 1000))
            } catch {
                if (Test-Path $fp) { Remove-Item $fp -Force -ErrorAction SilentlyContinue }
                Write-Host " failed" -ForegroundColor Red
                $failed++
            }
        }
        $page++
    }

    $totalNow = @(Get-ChildItem $langDir -Filter "pg*.txt" -ErrorAction SilentlyContinue).Count
    Write-Host ("    $downloaded downloaded, $skipped skipped, $failed failed  ->  $totalNow total") -ForegroundColor Cyan
}

# ── Wikisource ────────────────────────────────────────────────────────────────

# Strip basic wiki markup, returning plain text
function Remove-Wikitext {
    param([string]$Raw)
    $text = $Raw
    $text = [regex]::Replace($text, '(?s)<ref[^>]*>.*?</ref>', '')
    $text = [regex]::Replace($text, '\{\{[^}]*\}\}', '')
    $text = [regex]::Replace($text, '(?i)\[\[(?:File|Image|Category):[^\]]*\]\]', '')
    $text = [regex]::Replace($text, '\[\[(?:[^|\]]*\|)?([^\]]+)\]\]', '$1')
    $text = [regex]::Replace($text, '\[https?://\S+ ([^\]]+)\]', '$1')
    $text = [regex]::Replace($text, '\[https?://\S+\]', '')
    $text = [regex]::Replace($text, '<[^>]+>', '')
    $text = [regex]::Replace($text, '(?m)={2,}[^=]+=+', '')
    $text = [regex]::Replace($text, "'{2,}", '')
    $text = [regex]::Replace($text, '(?m)^\|.*$', '')
    $text = [regex]::Replace($text, '\n{3,}', "`n`n")
    return $text.Trim()
}

function Sync-WikisourceLanguage {
    param([string]$LangName)
    $code    = $LangCodes[$LangName]
    $langDir = Join-Path $CorpusDir $code
    $apiBase = "https://$code.wikisource.org/w/api.php"
    New-Item -ItemType Directory -Path $langDir -Force | Out-Null

    $existing = @(Get-ChildItem $langDir -Filter "ws_*.txt" -ErrorAction SilentlyContinue).Count
    $need     = $BooksPerLang - $existing
    if ($need -le 0) { Write-Ok "$LangName already has $existing Wikisource texts."; return }

    Write-Host ""
    Write-Host ("  {0} ({1} / Wikisource)  need {2} more, have {3}" -f $LangName, $code, $need, $existing) -ForegroundColor White

    $downloaded  = 0
    $attempts    = 0
    $maxAttempts = $need * 8

    while ($downloaded -lt $need -and $attempts -lt $maxAttempts) {
        # Get a batch of random page IDs
        $randomUrl = $apiBase + "?action=query&list=random&rnnamespace=0&rnlimit=20&format=json"
        try { $randomData = Invoke-RestMethod -Uri $randomUrl }
        catch { $attempts++; continue }

        foreach ($randomPage in $randomData.query.random) {
            if ($downloaded -ge $need) { break }
            $attempts++

            # Sanitise title for a filename
            $safe = $randomPage.title -replace '[/\\:*?"<>|]', '_' -replace '\s+', '_'
            $fp   = Join-Path $langDir ("ws_" + $safe + ".txt")
            if ((Test-Path $fp) -and (Get-Item $fp -ErrorAction SilentlyContinue).Length -gt 0) { continue }

            $title = $randomPage.title
            $displayTitle = if ($title.Length -gt 55) { $title.Substring(0,55) + "..." } else { $title }
            Write-Host ("    [{0}/{1}] {2} ..." -f ($existing+$downloaded+1), $BooksPerLang, $displayTitle) -NoNewline

            # Fetch raw wikitext via revisions API
            $revUrl = $apiBase + "?action=query&pageids=" + $randomPage.id + "&prop=revisions&rvprop=content&rvslots=main&format=json"
            try {
                $revData = Invoke-RestMethod -Uri $revUrl
                $rawText = ""
                foreach ($p in $revData.query.pages.PSObject.Properties.Value) {
                    $slot = $p.revisions[0].slots.main
                    if ($slot) { $rawText = $slot.'*'; break }
                }
            } catch { Write-Host " failed (fetch)" -ForegroundColor Red; continue }

            if (-not $rawText) { Write-Host " skip (no content)" -ForegroundColor DarkGray; continue }

            $cleaned = Remove-Wikitext $rawText

            if ($cleaned.Length -gt 300) {
                $cleaned | Out-File $fp -Encoding utf8
                Write-Host (" done ($($cleaned.Length) chars)") -ForegroundColor Green
                $downloaded++
                Start-Sleep -Milliseconds ([int]($Delay * 1000))
            } else {
                Write-Host " skip (too short)" -ForegroundColor DarkGray
            }
        }
    }

    $totalNow = @(Get-ChildItem $langDir -Filter "ws_*.txt" -ErrorAction SilentlyContinue).Count
    Write-Host ("    $downloaded downloaded ($attempts attempts)  ->  $totalNow total") -ForegroundColor Cyan
}

# ── Main ─────────────────────────────────────────────────────────────────────

$langsToRun = @()
if ($Languages.Count -gt 0) {
    foreach ($name in $Languages) {
        if ($LangCodes.ContainsKey($name)) { $langsToRun += $name }
        else { Write-Warn "Unknown language '$name'. Supported: $($LangCodes.Keys -join ', ')" }
    }
} else {
    $langsToRun = @($LangCodes.Keys)
}
if ($langsToRun.Count -eq 0) { Fail "No valid languages to process." }

Write-Host ""
Write-Host "LinguaPi Corpus Downloader" -ForegroundColor White
Write-Host "  Corpus dir     : $CorpusDir"
Write-Host "  Books/language : $BooksPerLang"
Write-Host "  Languages      : $($langsToRun -join ', ')"
Write-Host ""
Write-Host "  Sources:"
foreach ($lang in $langsToRun) {
    Write-Host ("    {0,-14} {1}" -f $lang, $LangSource[$lang])
}

if ($Force) {
    Write-Warn "-Force: removing existing corpus files."
    foreach ($name in $langsToRun) {
        $dir = Join-Path $CorpusDir $LangCodes[$name]
        if (Test-Path $dir) {
            Get-ChildItem $dir -Filter "*.txt" | Remove-Item -Force -ErrorAction SilentlyContinue
        }
    }
}

New-Item -ItemType Directory -Path $CorpusDir -Force | Out-Null

foreach ($lang in $langsToRun) {
    if ($LangSource[$lang] -eq "wikisource") { Sync-WikisourceLanguage $lang }
    else                                      { Sync-GutenbergLanguage  $lang }
}

Write-Host ""
Write-Host "Corpus sync complete. Restart LinguaPi to use local files." -ForegroundColor Green
Write-Host "  Location: $CorpusDir"
Write-Host ""
Write-Host "Text counts by language:"
foreach ($lang in $langsToRun) {
    $dir   = Join-Path $CorpusDir $LangCodes[$lang]
    $count = if (Test-Path $dir) { @(Get-ChildItem $dir -Filter "*.txt" -ErrorAction SilentlyContinue).Count } else { 0 }
    Write-Host ("  {0,-14} {1} texts  ({2})" -f ($lang + ":"), $count, $LangSource[$lang])
}
