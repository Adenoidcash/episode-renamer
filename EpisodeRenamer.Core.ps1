# Episode Renamer - core logic (filename parsing, metadata lookup, naming scheme, rename/undo).
# Dot-sourced by EpisodeRenamer.ps1. Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

# All shared state is set up here so the GUI can re-create it inside its background runspace.
function Initialize-Core {
    Set-StrictMode -Off
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $script:AppVersion = '1.3.2'
    $script:RepoSlug = 'Adenoidcash/episode-renamer'
    $script:VideoExt = @('.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.ts', '.m2ts', '.webm', '.flv', '.mpg', '.mpeg')
    $script:SubExt = @('.srt', '.ass', '.ssa', '.sub', '.idx', '.vtt', '.sup')
    # Files that travel with a video when they share its name ("<video>.nfo", "<video>-thumb.jpg", "<video>.en.srt").
    $script:CompanionExt = @('.nfo', '.jpg', '.jpeg', '.png', '.tbn') + $script:SubExt
    # Settings + undo logs: %APPDATA%\EpisodeRenamer on Windows, ~/.config/episode-renamer on Linux,
    # or wherever EPISODE_RENAMER_CONFIG points (the Docker image uses /config).
    $script:AppDir = if ($env:EPISODE_RENAMER_CONFIG) { $env:EPISODE_RENAMER_CONFIG }
    elseif ($env:APPDATA) { Join-Path $env:APPDATA 'EpisodeRenamer' }
    else { Join-Path (Join-Path ([Environment]::GetFolderPath('UserProfile')) '.config') 'episode-renamer' }
    $script:Sep = [IO.Path]::DirectorySeparatorChar
    $script:DefaultScheme = '{show} - S{season:00}E{episode:00} - {title}'
    $script:TvdbToken = $null
    $script:LastTvmazeCall = [DateTime]::MinValue
    $script:LangCodes = 'en|eng|es|spa|fr|fre|fra|de|ger|deu|it|ita|pt|por|ja|jpn|ko|kor|zh|chi|zho|ru|rus|nl|dut|nld|sv|swe|no|nor|nb|da|dan|fi|fin|pl|pol|ar|ara|he|heb|tr|tur|hi|hin|cs|cze|ces|hu|hun|el|gre|ell|th|tha|vi|vie|id|ind|ro|rum|ron|uk|ukr'
    $script:JunkPattern = '(?i)\s*(?:[\[\(\{].*|\b(?:480p|576p|720p|1080p|2160p|4K|UHD|HDR|WEB(?:-?DL|-?Rip)?|BluRay|BDRip|BRRip|HDTV|DVDRip|x264|x265|H\s?26[45]|HEVC|AVC|AAC(?:\d(?:\s\d)?)?|DDP?(?:\d(?:\s\d)?)?|AC3|FLAC|Opus|10bit|8bit|NF|AMZN|CR|DSNP|HMAX|REPACK|PROPER|iNTERNAL|MULTi|MULTiSUBS|DUAL|DUALAUDIO|EXTENDED|UNRATED|REMASTERED|IMAX|HDR10|DoVi|Atmos|ITALIAN|FRENCH|TRUEFRENCH|VOSTFR|VFF|GERMAN|SPANISH|LATINO|CASTELLANO|JAPANESE|KOREAN|HINDI|RUSSIAN|DUBBED|SUBBED)\b.*)$'
}
Initialize-Core

# ---------------------------------------------------------------- settings

function Get-Settings {
    $path = Join-Path $script:AppDir 'settings.json'
    $s = [ordered]@{
        Scheme     = $script:DefaultScheme
        Source     = 'TVmaze'
        Order      = 'Aired'
        Language   = 'eng'
        MatchMode  = 'Auto'
        Numbering  = 'Auto'
        TitleMode  = 'File'
        RenameExtras = $true
        Recurse    = $false
        LastFolder = ''
        TvdbApiKey = ''
        TvdbPin    = ''
        TmdbKey    = ''
        SonarrUrl  = ''
        SonarrKey  = ''
        RadarrUrl  = ''
        RadarrKey  = ''
        PlexUrl    = ''
        PlexToken  = ''
        JellyfinUrl = ''
        JellyfinKey = ''
        ArrSync    = $true
        Theme      = 'System'
        OnlyChanges = $true
        TvRoot     = ''
        MovieRoot  = ''
        MovieFolders = $true
    }
    if (Test-Path -LiteralPath $path) {
        try {
            $j = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($k in @($s.Keys)) { if ($null -ne $j.$k) { $s[$k] = $j.$k } }
        } catch { }
    }
    $s
}

function Save-Settings($Settings) {
    [void][IO.Directory]::CreateDirectory($script:AppDir)
    $Settings | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $script:AppDir 'settings.json') -Encoding UTF8
}

# ---------------------------------------------------------------- http

function Invoke-Json {
    # -Raw returns the response text unparsed; a [string] $Body is sent exactly as given.
    param([string]$Url, [string]$Method = 'GET', $Body = $null, [hashtable]$Headers = @{}, [int]$MaxAttempts = 4, [switch]$AllowEmpty, [switch]$Raw)
    for ($attempt = 1; ; $attempt++) {
        # TVmaze allows ~20 calls per 10 seconds; space calls out so whole-library scans don't hit the limit.
        if ($Url -like 'https://api.tvmaze.com/*') {
            $wait = 550 - ([DateTime]::UtcNow - $script:LastTvmazeCall).TotalMilliseconds
            if ($wait -gt 0) { Start-Sleep -Milliseconds ([int]$wait) }
            $script:LastTvmazeCall = [DateTime]::UtcNow
        }
        $req = [Net.HttpWebRequest]::Create($Url)
        $req.Method = $Method
        $req.UserAgent = 'EpisodeRenamer/1.0'
        $req.Accept = 'application/json'
        $req.Timeout = 20000            # a stuck server shouldn't hang a library scan for minutes
        $req.ReadWriteTimeout = 20000
        foreach ($k in $Headers.Keys) { $req.Headers[$k] = $Headers[$k] }
        $resp = $null
        try {
            if ($Method -ne 'GET') {
                $payload = if ($Body -is [string]) { $Body } else { ConvertTo-Json -InputObject $Body -Compress -Depth 20 }
                $bytes = [Text.Encoding]::UTF8.GetBytes($payload)
                $req.ContentType = 'application/json'
                $req.ContentLength = $bytes.Length
                $rs = $req.GetRequestStream(); $rs.Write($bytes, 0, $bytes.Length); $rs.Close()
            }
            $resp = $req.GetResponse()
            $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
            $text = $reader.ReadToEnd()
            $reader.Close()
            if ($Raw) { return $text }
            if (-not $text.Trim()) { return $null }   # e.g. Plex/Jellyfin refresh calls answer with no body
            return ($text | ConvertFrom-Json)
        } catch [System.Net.WebException] {
            $eresp = $_.Exception.Response
            $code = if ($eresp) { [int]$eresp.StatusCode } else { 0 }
            # TVmaze rate-limits (429) and occasionally returns 502 or stalls; retry those a couple of times.
            if ($attempt -lt $MaxAttempts -and ($code -eq 429 -or $code -ge 500 -or $_.Exception.Status -eq 'Timeout')) { Start-Sleep -Seconds (2 * $attempt); continue }
            # Plain-language message; never dump the server's HTML error page into a dialog.
            $site = ([uri]$Url).Host
            $detail = ''
            if ($eresp) { try { $detail = (New-Object IO.StreamReader($eresp.GetResponseStream())).ReadToEnd().Trim() } catch { } }
            if ($detail.StartsWith('<') -or $detail.Length -gt 300) { $detail = '' }
            $msg = if ($code -eq 0) { "Couldn't connect to $site. The site may be down, or the internet connection is having trouble." }
            elseif ($code -ge 500) { "$site is having problems right now (error $code). Try again in a few minutes." }
            else { "$site returned error $code." + $(if ($detail) { " $detail" } else { '' }) }
            $ex = New-Object Exception($msg)
            $ex.Data['StatusCode'] = $code
            throw $ex
        } finally {
            if ($resp) { $resp.Close() }
        }
    }
}

# ---------------------------------------------------------------- TVmaze (free, no key)

# TVmaze's search fails (502) on some titles - "Arifureta: From Commonplace to World's Strongest" breaks on
# "World's Strongest" - and finds nothing for others. Fall back to shorter forms of the title and rank what
# comes back by how much of the full title each result shares.
function Search-TVmaze([string]$Query) {
    $lastError = $null
    $variants = @(Get-QueryVariants $Query)
    for ($i = 0; $i -lt $variants.Count; $i++) {
        try {
            $r = @(Search-TVmazeOnce $variants[$i])
        } catch {
            $code = $_.Exception.Data['StatusCode']
            if ($code -ge 500 -or $code -eq 0) { $lastError = $_.Exception; continue }
            throw
        }
        if ($r.Count -eq 0) { continue }
        if ($i -eq 0) { return $r }   # the full title worked; keep TVmaze's own ranking
        return @($r | Sort-Object @{ e = { Get-TitleSimilarity $_.Name $Query }; Descending = $true }, @{ e = { [array]::IndexOf($r, $_) } })
    }
    if ($lastError) { throw $lastError }
    @()
}

# "Arifureta - From Commonplace to World's Strongest" -> the full title, "Arifureta",
# the title without punctuation, its first two words, its first word.
function Get-QueryVariants([string]$Query) {
    $q = $Query.Trim()
    $plain = (($q -replace "['`]", '') -replace '[^\p{L}\p{N}]+', ' ').Trim()
    $words = @($plain -split ' ' | Where-Object { $_ })
    $list = @($q)
    if ($q -match '^(.+?)\s*(?:\s-\s|:)') { $list += $matches[1].Trim() }
    $list += $plain
    if ($words.Count -gt 2) { $list += ($words[0..1] -join ' ') }
    if ($words.Count -gt 1 -and $words[0].Length -ge 4) { $list += $words[0] }
    $seen = @{}
    foreach ($v in $list) { if ($v -and -not $seen.ContainsKey($v.ToLower())) { $seen[$v.ToLower()] = $true; $v } }
}

# Share of the query's words that appear in the name, minus a little for extra words in the name (0..1).
function Get-TitleSimilarity([string]$Name, [string]$Query) {
    $norm = { param($t) @((($t -replace "['`]", '').ToLower() -replace '[^\p{L}\p{N}]+', ' ').Trim() -split ' ' | Where-Object { $_ }) }
    $n = & $norm $Name
    $q = & $norm $Query
    if ($q.Count -eq 0 -or $n.Count -eq 0) { return 0 }
    $common = @($q | Where-Object { $n -contains $_ }).Count
    ($common / $q.Count) - 0.01 * [Math]::Max(0, $n.Count - $common)
}

function Search-TVmazeOnce([string]$Query) {
    $r = Invoke-Json "https://api.tvmaze.com/search/shows?q=$([uri]::EscapeDataString($Query))" -MaxAttempts 2
    foreach ($x in @($r)) {
        $s = $x.show
        $year = if ($s.premiered) { $s.premiered.Substring(0, 4) } else { '' }
        $net = if ($s.network) { $s.network.name } elseif ($s.webChannel) { $s.webChannel.name } else { '' }
        $extra = (@($s.type, $net, $s.language) | Where-Object { $_ }) -join ', '
        [pscustomobject]@{
            Source  = 'TVmaze'
            Id      = $s.id
            Name    = $s.name
            Year    = $year
            Display = "$($s.name) ($year)  [$extra]"
        }
    }
}

function Get-TVmazeEpisodes($Id, [string]$Order) {
    $raw = Invoke-Json "https://api.tvmaze.com/shows/$Id/episodes?specials=1"
    $eps = foreach ($e in @($raw)) {
        $isSpecial = ($e.type -ne 'regular') -or ($null -eq $e.number)
        [pscustomobject]@{
            Season        = if ($isSpecial) { 0 } else { [int]$e.season }
            Number        = if ($isSpecial) { $null } else { [int]$e.number }
            Absolute      = $null
            Title         = $e.name
            AirDate       = $e.airdate
            NumberGuessed = $isSpecial
        }
    }
    # TVmaze lists specials without a number. Give them a placeholder in air order so they can be looked up,
    # but NumberGuessed marks it: these must never end up in a file name (Plex/Sonarr number specials differently).
    $sp = 0
    foreach ($e in @($eps | Where-Object { $_.Season -eq 0 })) { $sp++; $e.Number = $sp }
    $eps = Complete-AbsoluteNumbers $eps
    if ($Order -eq 'Absolute') {
        foreach ($e in $eps) { if ($e.Absolute) { $e.Season = 1; $e.Number = $e.Absolute } }
    }
    $eps
}

# ---------------------------------------------------------------- TheTVDB v4 (needs API key)

function Connect-Tvdb([string]$ApiKey, [string]$Pin) {
    if ($script:TvdbToken) { return }
    if (-not $ApiKey) { throw 'TheTVDB needs an API key. Click "Settings..." and paste your key (get one at thetvdb.com/api-information).' }
    $body = @{ apikey = $ApiKey }
    if ($Pin) { $body.pin = $Pin }
    try {
        $r = Invoke-Json 'https://api4.thetvdb.com/v4/login' 'POST' $body
    } catch {
        if ($_.Exception.Data['StatusCode'] -eq 401) { throw 'TheTVDB rejected the API key / PIN. Check them in Settings.' }
        throw
    }
    $script:TvdbToken = $r.data.token
}

function Get-TvdbHeaders { @{ Authorization = "Bearer $script:TvdbToken" } }

function Search-Tvdb([string]$Query, [string]$Lang) {
    $r = Invoke-Json "https://api4.thetvdb.com/v4/search?type=series&query=$([uri]::EscapeDataString($Query))" -Headers (Get-TvdbHeaders)
    foreach ($s in @($r.data)) {
        $name = $s.name
        if ($Lang -and $s.translations -and $s.translations.$Lang) { $name = $s.translations.$Lang }
        $extra = (@($s.network, $s.country, $s.primary_language) | Where-Object { $_ }) -join ', '
        [pscustomobject]@{
            Source  = 'TheTVDB'
            Id      = $s.tvdb_id
            Name    = $name
            Year    = $s.year
            Display = "$name ($($s.year))  [$extra]  tvdb:$($s.tvdb_id)"
        }
    }
}

function Get-TvdbEpisodes($Id, [string]$Order, [string]$Lang) {
    $type = @{ Aired = 'default'; DVD = 'dvd'; Absolute = 'absolute' }[$Order]
    if (-not $type) { $type = 'default' }
    $fetch = {
        param($langPart)
        $all = @()
        $page = 0
        do {
            $r = Invoke-Json "https://api4.thetvdb.com/v4/series/$Id/episodes/$type$langPart`?page=$page" -Headers (Get-TvdbHeaders)
            $all += @($r.data.episodes)
            $page++
        } while ($r.links -and $r.links.next -and $page -lt 50)
        $all
    }
    $raw = $null
    if ($Lang) { try { $raw = & $fetch "/$Lang" } catch { $raw = $null } }
    if (-not $raw) { $raw = & $fetch '' }

    $eps = foreach ($e in @($raw)) {
        if ($null -eq $e) { continue }
        [pscustomobject]@{
            Season   = [int]$e.seasonNumber
            Number   = [int]$e.number
            Absolute = if ($e.absoluteNumber) { [int]$e.absoluteNumber } else { $null }
            Title    = if ($e.name) { $e.name } else { "Episode $($e.number)" }
            AirDate  = $e.aired
        }
    }
    Complete-AbsoluteNumbers $eps
}

# Fill in absolute numbers (running count of non-special episodes) when the source doesn't supply all of them.
function Complete-AbsoluteNumbers($Episodes) {
    $eps = @($Episodes | Sort-Object Season, Number)
    $regular = @($eps | Where-Object { $_.Season -gt 0 })
    if (@($regular | Where-Object { -not $_.Absolute }).Count -gt 0) {
        $i = 0
        foreach ($e in $regular) { $i++; $e.Absolute = $i }
    }
    $eps
}

# ---------------------------------------------------------------- filename parsing

# "www.UIndex.org - Fallout.2024.S02E04..." -> "Fallout.2024.S02E04..."
function Remove-SitePrefix([string]$Name) {
    $Name -replace '^(?i)\s*(?:www\.)?[a-z0-9-]+\.(?:org|com|net|to|cc|io|tv|me|info|xyz|ws|in|co|nu|se|ru|lol|club|site|top|biz|eu|uk)\s*[-:]\s*', ''
}

# Underscores, and dots that join words ("Fallout.2024.S02E04"), become spaces. Dots before a space or
# next to another dot are real punctuation and stay ("Luffy vs. Zoro", "Cat's in the Bag...").
function ConvertTo-SpacedName([string]$Name) {
    $s = $Name -replace '_+', ' '
    $s = $s -replace '(?<![.\s])\.(?=[^\s.])', ' '
    ($s -replace '\s{2,}', ' ').Trim()
}

function ConvertFrom-EpisodeFileName([string]$FileName) {
    $ext = [IO.Path]::GetExtension($FileName)
    $base = [IO.Path]::GetFileNameWithoutExtension($FileName)

    # Keep subtitle language tags (".en", ".eng.forced", ...) so they survive the rename.
    $suffix = ''
    if ($script:SubExt -contains $ext.ToLower()) {
        $m = [regex]::Match($base, "(?i)\.(?:$script:LangCodes)(?:[-_][a-z]{2,4})?(?:\.(?:forced|sdh|cc|hi|default))*$")
        if ($m.Success) { $suffix = $m.Value; $base = $base.Substring(0, $m.Index) }
    }

    # Drop leading [Group] / (tag) blocks. Underscores are always separators; dots only when the
    # name has no real spaces (scene style "Show.S01E01.Title"), so titles like "Men!." or "vs." survive.
    $s = $base
    $s = Remove-SitePrefix $s
    while ($s -match '^\s*(\[[^\]]*\]|\([^)]*\)|\{[^}]*\})\s*') { $s = $s.Substring($matches[0].Length) }
    $s = ConvertTo-SpacedName $s
    $s = ($s -replace '\s{2,}', ' ').Trim()

    $result = [pscustomobject]@{
        Kind      = 'None'      # SE (season+episode), Abs (single/absolute number), None
        Season    = $null
        Episodes  = @()
        ShowGuess = ''
        Title     = ''          # episode title already in the filename, if any
        Clean     = $s          # cleaned-up name, for matching files that have no episode number
        Ext       = $ext
        Suffix    = $suffix
    }

    $m = [regex]::Match($s, '(?i)\bS(\d{1,2})\s?E(\d{1,4})((?:\s?-?\s?E\d{1,4}|-\d{1,4}\b)*)')
    if (-not $m.Success) { $m = [regex]::Match($s, '(?i)\b(\d{1,2})x(\d{2,3})((?:-\d{2,3}\b|x\d{2,3})*)\b') }
    if ($m.Success) {
        $nums = @([int]$m.Groups[2].Value) + @([regex]::Matches($m.Groups[3].Value, '\d+') | ForEach-Object { [int]$_.Value })
        # "E01-E04" style ranges: expand to every episode in between.
        if ($nums.Count -eq 2 -and $m.Groups[3].Value -match '-' -and ($nums[1] - $nums[0]) -ge 2 -and ($nums[1] - $nums[0]) -le 10) {
            $nums = @($nums[0]..$nums[1])
        }
        $result.Kind = 'SE'
        $result.Season = [int]$m.Groups[1].Value
        $result.Episodes = $nums
    }
    if (-not $m.Success) {
        # "Black Clover 2nd Season - 01", "Show Season 2 - 05", "Show S2 - 05": a season word, then the episode.
        $m = [regex]::Match($s, '(?i)\b(?:(\d{1,2})(?:st|nd|rd|th)\s+season|season\s*(\d{1,2})|S(\d{1,2}))\b\s*[-:~]?\s*(?:E|EP|Episode)?\s*(\d{1,4})(?:v\d)?(?![\w)])')
        if ($m.Success) {
            $result.Kind = 'SE'
            $result.Season = [int](@($m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value) | Where-Object { $_ } | Select-Object -First 1)
            $result.Episodes = @([int]$m.Groups[4].Value)
        }
    }
    if (-not $m.Success) {
        $patterns = @(
            '(?i)\b(?:E|EP|Episode)\s?(\d{1,4})(?:v\d)?\b',
            '\s-\s(\d{1,4})(?:v\d)?(?!\w)',
            '(?<![\w(])(\d{1,4})(?:v\d)?(?![\w)])'
        )
        foreach ($p in $patterns) {
            foreach ($c in [regex]::Matches($s, $p)) {
                $v = $c.Groups[1].Value
                if ($v -match '^(19|20)\d\d$' -and $p -eq $patterns[2]) { continue }  # looks like a year
                $m = $c; break
            }
            if ($m.Success) { break }
        }
        if ($m -and $m.Success) {
            $result.Kind = 'Abs'
            $result.Episodes = @([int]$m.Groups[1].Value)
        }
    }

    if ($m -and $m.Success) {
        $guess = $s.Substring(0, $m.Index)
        $guess = $guess -replace '[\s\-]+$', ''
        $guess = $guess -replace '\s*\(?(19|20)\d\d\)?$', ''
        $result.ShowGuess = $guess.Trim()

        # Whatever follows the episode number, minus release junk, is the title.
        $rest = $s.Substring($m.Index + $m.Length)
        $rest = [regex]::Replace($rest, $script:JunkPattern, '')
        $t = (($rest -replace '^[\s\-:~|.]+', '') -replace '[\s\-:~|]+$', '').Trim()
        $result.Title = if ($t -match '[\p{L}\p{N}]') { $t } else { '' }   # "." or "-" alone isn't a title
    }
    $result
}


# "X:\Plex\Anime\One Piece (1999)\Season 02" -> 1999 (the innermost "(year)" in the path), otherwise $null.
function Get-YearHint([string]$Path) {
    $m = [regex]::Matches($Path, '\(((?:19|20)\d\d)\)')
    if ($m.Count -gt 0) { return [int]$m[$m.Count - 1].Groups[1].Value }
    $null
}

# Other files next to a video that share its name. Remainder is what follows the video's base name.
function Get-Companions([string]$VideoPath, [object[]]$DirFiles) {
    $base = [IO.Path]::GetFileNameWithoutExtension($VideoPath)
    foreach ($f in $DirFiles) {
        $name = $f.Name
        if ($name.Length -le $base.Length -or -not $name.StartsWith($base, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $rest = $name.Substring($base.Length)
        if ($rest[0] -ne '.' -and $rest[0] -ne '-') { continue }
        $ext = $f.Extension.ToLower()
        if ($script:CompanionExt -notcontains $ext) { continue }
        # "-thumb.jpg", ".en.srt", ".nfo" - but not "<video>.part2.mkv"-style names with more words in them.
        if ($rest -notmatch '^(?:-[A-Za-z]+|(?:\.[A-Za-z]{2,3}(?:[-_][A-Za-z]{2,4})?)?(?:\.(?:forced|sdh|cc|hi|default))*)\.[A-Za-z0-9]+$') { continue }
        [pscustomobject]@{ Path = $f.FullName; Remainder = $rest; Target = $null }
    }
}

# "Season 02" / "S2" folder -> 2, otherwise $null.
function Get-FolderSeason([string]$Dir) {
    $leaf = Split-Path $Dir -Leaf
    if ($leaf -match '^(?i)(?:season|series|s)[\s._-]*(\d{1,3})$') { return [int]$matches[1] }
    if ($leaf -match '^(?i)specials$') { return 0 }
    $null
}

# Show name from a folder like "One Piece\Season 02\" when the filename itself has none.
function Get-FolderShowGuess([string]$Dir) {
    $leaf = Split-Path $Dir -Leaf
    if ($leaf -match '^(?i)(season|series|s)\s*\d+$|^(?i)specials$') { $leaf = Split-Path (Split-Path $Dir -Parent) -Leaf }
    $leaf = $leaf -replace '[._]+', ' ' -replace '\s*\(?(19|20)\d\d\)?$', ''
    $leaf.Trim()
}

# ---------------------------------------------------------------- matching + naming

function Get-TitleWords([string]$Text) {
    @((($Text -replace "['`]", '').ToLower() -replace '[^\p{L}\p{N}]+', ' ').Trim() -split ' ' | Where-Object { $_ })
}

# Lookup tables for one episode list, built once and reused while the same list is passed in (a show
# with 600+ episodes and 150+ files would otherwise be scanned in full for every single file).
function Get-EpisodeIndex($Episodes) {
    if ($null -ne $script:EpIndexSource -and [object]::ReferenceEquals($Episodes, $script:EpIndexSource)) { return $script:EpIndex }
    $se = @{}; $abs = @{}; $seasons = @{}; $titles = New-Object System.Collections.Generic.List[object]
    foreach ($e in @($Episodes)) {
        $k = "$($e.Season)|$($e.Number)"
        if (-not $se.ContainsKey($k)) { $se[$k] = $e }
        if ($e.Absolute) { $a = [int]$e.Absolute; if (-not $abs.ContainsKey($a)) { $abs[$a] = $e } }
        $s = [int]$e.Season
        if (-not $seasons.ContainsKey($s)) { $seasons[$s] = New-Object System.Collections.Generic.List[object] }
        $seasons[$s].Add($e)
        if ($e.Title) { $w = @(Get-TitleWords $e.Title); if ($w.Count) { $titles.Add([pscustomobject]@{ E = $e; Key = ($w -join ' '); Words = $w }) } }
    }
    $script:EpIndexSource = $Episodes
    $script:EpIndex = @{ SE = $se; Abs = $abs; Seasons = $seasons; Titles = $titles.ToArray() }
    $script:EpIndex
}

# Match a file to an episode by its title ("Season 00\Balloons.mkv", "S00E108 - It's a SpongeBob Christmas").
# Exact title first; otherwise the closest title that shares at least 80% of its words with the file's.
function Find-EpisodeByTitle([string]$Text, $Index, $Season, [string]$ShowName) {
    $words = @(Get-TitleWords $Text)
    # Drop a leading show name ("SpongeBob SquarePants - Balloons" -> "balloons").
    $show = @(Get-TitleWords $ShowName)
    if ($show.Count -and $words.Count -gt $show.Count -and (($words[0..($show.Count - 1)]) -join ' ') -eq ($show -join ' ')) {
        $words = @($words[$show.Count..($words.Count - 1)])
    }
    if ($words.Count -eq 0) { return $null }
    $key = $words -join ' '
    $pool = @($Index.Titles | Where-Object { $null -eq $Season -or $_.E.Season -eq $Season })
    $exact = $pool | Where-Object { $_.Key -eq $key } | Select-Object -First 1
    if ($exact) { return $exact.E }
    $best = $null; $bestScore = 0
    foreach ($t in $pool) {
        $common = @($t.Words | Where-Object { $words -contains $_ }).Count
        $score = $common / [Math]::Max($t.Words.Count, $words.Count)
        if ($score -gt $bestScore) { $best = $t.E; $bestScore = $score }
    }
    if ($bestScore -ge 0.8) { return $best }
    $null
}

function Find-Episodes($Parsed, $Episodes, [string]$MatchMode, $FolderSeason = $null, [string]$ShowName = '') {
    $idx = Get-EpisodeIndex $Episodes

    # Specials (S00 / "Specials" / "Season 00" folder) and files with no number at all are matched by
    # title: special numbering differs between sources, and TVmaze doesn't number specials at all.
    $special = ($Parsed.Kind -eq 'SE' -and $Parsed.Season -eq 0) -or ($Parsed.Kind -ne 'SE' -and $FolderSeason -eq 0)
    if ($special -or $Parsed.Kind -eq 'None') {
        $text = if ($Parsed.Kind -eq 'None') { $Parsed.Clean } else { $Parsed.Title }
        $season = if ($special) { 0 } elseif ($null -ne $FolderSeason) { [int]$FolderSeason } else { $null }
        if ($text) {
            $m = Find-EpisodeByTitle $text $idx $season $ShowName
            if (-not $m -and $null -ne $season -and -not $special) { $m = Find-EpisodeByTitle $text $idx $null $ShowName }
            if ($m) { return @($m) }
        }
        if ($Parsed.Kind -eq 'None') { return @() }
        if ($special) {
            # No title to go on: trust "S00E05" only if the source really numbers its specials.
            $found = @(foreach ($n in $Parsed.Episodes) { $e = $idx.SE["0|$n"]; if ($e -and -not $e.NumberGuessed) { $e } })
            return $(if ($found.Count -eq $Parsed.Episodes.Count) { $found } else { @() })
        }
    }

    # A bare number inside a "Season 2" folder ("Season 2\Show - 01") usually means episode 1 of season 2,
    # unless it falls inside that season's absolute range ("Season 2\Show - 173" for a season that runs
    # 171-..., or One Piece "Season 02\0063") - then it's an absolute number and handled below.
    if ($MatchMode -eq 'Auto' -and $Parsed.Kind -eq 'Abs' -and $null -ne $FolderSeason -and $idx.Seasons.ContainsKey([int]$FolderSeason)) {
        $inSeason = $idx.Seasons[[int]$FolderSeason]
        $abs = @($inSeason | Where-Object { $_.Absolute } | ForEach-Object { [int]$_.Absolute })
        $first = $Parsed.Episodes[0]
        $looksAbsolute = $abs.Count -gt 0 -and $first -ge ($abs | Measure-Object -Minimum).Minimum -and $first -le ($abs | Measure-Object -Maximum).Maximum
        if (-not $looksAbsolute) {
            $found = @(@(foreach ($n in $Parsed.Episodes) { $idx.SE["$([int]$FolderSeason)|$n"] }) | Where-Object { $_ })
            if ($found.Count -eq $Parsed.Episodes.Count) { return $found }
        }
    }
    $useSE = ($MatchMode -eq 'SeasonEpisode') -or ($MatchMode -eq 'Auto' -and $Parsed.Kind -eq 'SE')
    if ($useSE) {
        if ($null -eq $Parsed.Season) { return @() }
        $found = @(@(foreach ($n in $Parsed.Episodes) { $idx.SE["$($Parsed.Season)|$n"] }) | Where-Object { $_ })
        # Anime is often numbered absolutely ("S01E063", or TheTVDB-style "S02E63" while TVmaze uses
        # year seasons); when the season/episode pair doesn't exist, fall back to the absolute number.
        if ($found.Count -eq 0 -and $MatchMode -eq 'Auto' -and $Parsed.Season -ne 0) {
            $found = @(@(foreach ($n in $Parsed.Episodes) { $idx.Abs[[int]$n] }) | Where-Object { $_ })
        }
        return $found
    }
    @(@(foreach ($n in $Parsed.Episodes) { $idx.Abs[[int]$n] }) | Where-Object { $_ })
}

# Decide the season/episode numbers and title that go into the new name.
#   Numbering: Auto   - source numbers, unless the source uses years as seasons (TVmaze anime) and the
#                       file or its "Season NN" folder gives a season; then use the file's numbers.
#              Source - always the source's numbers.   File - always the file's / folder's numbers.
#   TitleMode: File   - keep the title already in the filename, fall back to the source title.
#              Source - always the source title.
function Resolve-EpisodeInfo($Found, $Parsed, $FolderSeason, [string]$Numbering, [string]$TitleMode) {
    $found = @($Found)
    $fileSeason = if ($Parsed.Kind -eq 'SE') { $Parsed.Season } else { $FolderSeason }
    $yearSeasons = @($found | Where-Object { $_.Season -ge 1900 }).Count -gt 0
    $useFile = ($Numbering -eq 'File') -or ($Numbering -eq 'Auto' -and $yearSeasons -and $null -ne $fileSeason)
    $title = if ($TitleMode -eq 'File' -and $Parsed.Title) { $Parsed.Title } else { $null }
    # Keep the filename's title only if it looks like this episode's title - not a leftover tag ("iTALiAN").
    if ($title -and -not @($found | Where-Object { Test-TitleResembles $title $_.Title }).Count) { $title = $null }
    for ($i = 0; $i -lt $found.Count; $i++) {
        $e = $found[$i]
        $fileNumber = if ($Parsed.Kind -ne 'None') { $Parsed.Episodes[[Math]::Min($i, $Parsed.Episodes.Count - 1)] } else { $null }
        $number = if ($useFile) { $fileNumber } else { $e.Number }
        $season = if ($useFile -and $null -ne $fileSeason) { $fileSeason } else { $e.Season }
        # A placeholder number (TVmaze special) never goes into a name: keep the file's own, or flag it.
        if ($e.NumberGuessed) { $number = if ($Parsed.Kind -eq 'SE') { $fileNumber } else { $null }; $season = 0 }
        $useTitle = if ($title) { $title } else { $e.Title }
        # Same words as the official title, just different punctuation: use the official spelling.
        if ($title -and $e.Title -and ((Get-TitleWords $title) -join ' ') -eq ((Get-TitleWords $e.Title) -join ' ')) { $useTitle = $e.Title }
        [pscustomobject]@{
            Season      = $season
            Number      = $number
            Absolute    = $e.Absolute
            Title       = $useTitle
            AirDate     = $e.AirDate
            NeedsNumber = ($null -eq $number)
        }
    }
}

# Does a title from a filename plausibly name this episode? Releases word titles differently
# ("A Town that Welcomes Pirates..." vs "A Pirate-Loving Town..."), so one shared meaningful word is enough.
function Test-TitleResembles([string]$FileTitle, [string]$SourceTitle) {
    if (-not $SourceTitle) { return $true }
    $stop = @('the', 'a', 'an', 'and', 'of', 'to', 'in', 'on', 'at', 'for', 'is', 'part', 'episode')
    $f = @(Get-TitleWords $FileTitle | Where-Object { $stop -notcontains $_ })
    $s = @(Get-TitleWords $SourceTitle | Where-Object { $stop -notcontains $_ })
    if ($f.Count -eq 0 -or $s.Count -eq 0) { $f = @(Get-TitleWords $FileTitle); $s = @(Get-TitleWords $SourceTitle) }
    @($f | Where-Object { $s -contains $_ }).Count -gt 0
}

# Status text for a file whose special was found but can't be numbered from this source.
function Get-NeedsNumberText($Resolved, [string]$Source) {
    $t = @($Resolved)[0].Title
    "Special '$t' found, but $Source doesn't number specials - use TheTVDB or Sonarr as the TV source"
}

function Format-Num($Value, [string]$Spec) {
    if ($null -eq $Value -or "$Value" -eq '') { return '' }
    if ($Spec -match '^0+$') { return ([int]$Value).ToString('D' + $Spec.Length) }
    "$Value"
}

# Make metadata text safe to put inside a Windows file name.
function Get-SafeText([string]$Text) {
    if ($null -eq $Text) { return '' }
    $t = $Text -replace ':\s', ' - ' -replace ':', '-' -replace '[\\/]', '-' -replace '"', "'" -replace '[<>|?*]', '' -replace '[\x00-\x1f]', ''
    ($t -replace '\s{2,}', ' ').Trim()
}

function Get-TokenValue([string]$Key, [string]$Spec, $Ctx) {
    $eps = @($Ctx.Episodes)
    switch ($Key.ToLower()) {
        'show'     { return (Get-SafeText $Ctx.Show) }
        'season'   { return (Format-Num $eps[0].Season $Spec) }
        'episode'  {
            $v = Format-Num $eps[0].Number $Spec
            if ($eps.Count -gt 1) { $v += '-E' + (Format-Num $eps[-1].Number $Spec) }
            return $v
        }
        'absolute' {
            $v = Format-Num $eps[0].Absolute $Spec
            if ($eps.Count -gt 1 -and $eps[-1].Absolute) { $v += '-' + (Format-Num $eps[-1].Absolute $Spec) }
            return $v
        }
        'title'    { return (Get-SafeText ((@($eps | ForEach-Object { $_.Title } | Select-Object -Unique)) -join ' & ')) }
        'year'     { return "$($Ctx.Year)" }
        'airdate'  { return "$($eps[0].AirDate)" }
        'original' { return (Get-SafeText $Ctx.Original) }
    }
    $null
}

# Returns the new relative path (may include sub-folders if the scheme contains "\" or "/").
function Format-NewName([string]$Scheme, $Ctx, $Parsed) {
    $sb = New-Object Text.StringBuilder
    $last = 0
    foreach ($m in [regex]::Matches($Scheme, '\{(?<k>\w+)(?::(?<f>[^}]*))?\}')) {
        [void]$sb.Append($Scheme.Substring($last, $m.Index - $last))
        $v = Get-TokenValue $m.Groups['k'].Value $m.Groups['f'].Value $Ctx
        [void]$sb.Append($(if ($null -eq $v) { $m.Value } else { $v }))
        $last = $m.Index + $m.Length
    }
    [void]$sb.Append($Scheme.Substring($last))

    $parts = @($sb.ToString() -split '[\\/]' | ForEach-Object {
        (($_ -replace '[<>:"|?*\x00-\x1f]', '') -replace '\s{2,}', ' ').Trim()
    } | Where-Object { $_ })
    if ($parts.Count -eq 0) { return $null }
    for ($i = 0; $i -lt $parts.Count - 1; $i++) { $parts[$i] = $parts[$i].TrimEnd('. ') }
    ($parts -join $script:Sep) + $Parsed.Suffix + $Parsed.Ext
}

# ---------------------------------------------------------------- file operations + undo
# Every change is logged as { Kind; From; To } so a batch can be undone in reverse order:
#   File / Dir = moved From -> To,  MkDir = created To,  RmDir = removed the (empty) folder From.

function Move-PathSafe([string]$From, [string]$To, [bool]$IsDir, $Log) {
    # Create missing parent folders one level at a time so undo can remove exactly what we made.
    $missing = @()
    $p = Split-Path $To -Parent
    while ($p -and -not [IO.Directory]::Exists($p)) { $missing = @($p) + $missing; $p = Split-Path $p -Parent }
    foreach ($m in $missing) {
        [void][IO.Directory]::CreateDirectory($m)
        $Log.Add([pscustomobject]@{ Kind = 'MkDir'; From = $null; To = $m })
    }
    if ([string]::Equals($From, $To, [StringComparison]::OrdinalIgnoreCase)) {
        # Case-only change: go through a temporary name, Windows won't do it in one step.
        $tmp = $From.TrimEnd('\', '/') + '.renaming-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
        if ($IsDir) { [IO.Directory]::Move($From, $tmp); [IO.Directory]::Move($tmp, $To) }
        else { [IO.File]::Move($From, $tmp); [IO.File]::Move($tmp, $To) }
    } else {
        if ([IO.File]::Exists($To) -or [IO.Directory]::Exists($To)) { throw "Already exists: $To" }
        if ($IsDir) { [IO.Directory]::Move($From, $To) } else { [IO.File]::Move($From, $To) }
    }
    $Log.Add([pscustomobject]@{ Kind = $(if ($IsDir) { 'Dir' } else { 'File' }); From = $From; To = $To })
}

function Test-DirEmpty([string]$Dir) {
    -not [IO.Directory]::EnumerateFileSystemEntries($Dir).GetEnumerator().MoveNext()
}

function Invoke-FsOp($Op, $Log) {
    switch ($Op.Op) {
        'MoveFile' { Move-PathSafe $Op.From $Op.To $false $Log }
        'MoveDir' { Move-PathSafe $Op.From $Op.To $true $Log }
        'RmDirIfEmpty' {
            if ([IO.Directory]::Exists($Op.From) -and (Test-DirEmpty $Op.From)) {
                [IO.Directory]::Delete($Op.From)
                $Log.Add([pscustomobject]@{ Kind = 'RmDir'; From = $Op.From; To = $null })
            }
        }
        default { throw "Unknown operation $($Op.Op)" }
    }
}

function Save-UndoLog($Log) {
    if ($Log.Count -eq 0) { return }
    $undoDir = Join-Path $script:AppDir 'undo'
    [void][IO.Directory]::CreateDirectory($undoDir)
    ConvertTo-Json -InputObject $Log.ToArray() |
        Set-Content -LiteralPath (Join-Path $undoDir ((Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.json')) -Encoding UTF8
}

# Episodes tab: a flat list of { Source; Target } file renames.
function Invoke-RenamePlan($Plan) {
    $log = New-Object System.Collections.Generic.List[object]
    $results = foreach ($p in $Plan) {
        try {
            Move-PathSafe $p.Source $p.Target $false $log
            [pscustomobject]@{ Item = $p; Ok = $true; Error = $null }
        } catch {
            [pscustomobject]@{ Item = $p; Ok = $false; Error = $_.Exception.Message }
        }
    }
    Save-UndoLog $log
    @($results)
}

# Library tabs: run each plan's ops in order. A plan stops at its first failure, because later ops
# use paths that earlier ones (e.g. the show folder rename) were supposed to create.
function Invoke-LibraryPlans($Plans) {
    $log = New-Object System.Collections.Generic.List[object]
    $results = foreach ($plan in $Plans) {
        $done = 0
        $err = $null
        foreach ($op in $plan.Ops) {
            try { Invoke-FsOp $op $log; $done++ } catch { $err = $_.Exception.Message; break }
        }
        [pscustomobject]@{ Plan = $plan; Done = $done; Error = $err }
    }
    Save-UndoLog $log
    @($results)
}

function Undo-LastRename {
    $undoDir = Join-Path $script:AppDir 'undo'
    $file = Get-ChildItem -LiteralPath $undoDir -Filter '*.json' -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1
    if (-not $file) { throw 'Nothing to undo.' }
    $entries = Get-Content -LiteralPath $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    $entries = @($entries)
    [array]::Reverse($entries)
    $ok = 0
    $errors = @()
    $restored = New-Object System.Collections.Generic.List[object]
    foreach ($e in $entries) {
        $kind = if ($e.Kind) { $e.Kind } else { 'File' }   # logs from 1.1 have no Kind
        try {
            if ($kind -eq 'MkDir') {
                if ([IO.Directory]::Exists($e.To) -and (Test-DirEmpty $e.To)) { [IO.Directory]::Delete($e.To) }
            } elseif ($kind -eq 'RmDir') {
                [void][IO.Directory]::CreateDirectory($e.From)
            } else {
                $isDir = $kind -eq 'Dir'
                $exists = if ($isDir) { [IO.Directory]::Exists($e.To) } else { [IO.File]::Exists($e.To) }
                if (-not $exists) { throw "Missing: $($e.To)" }
                if ([string]::Equals($e.From, $e.To, [StringComparison]::OrdinalIgnoreCase)) {
                    $tmp = $e.To.TrimEnd('\', '/') + '.renaming-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                    if ($isDir) { [IO.Directory]::Move($e.To, $tmp); [IO.Directory]::Move($tmp, $e.From) }
                    else { [IO.File]::Move($e.To, $tmp); [IO.File]::Move($tmp, $e.From) }
                } else {
                    if ([IO.File]::Exists($e.From) -or [IO.Directory]::Exists($e.From)) { throw "Already exists: $($e.From)" }
                    [void][IO.Directory]::CreateDirectory((Split-Path $e.From -Parent))
                    if ($isDir) { [IO.Directory]::Move($e.To, $e.From) } else { [IO.File]::Move($e.To, $e.From) }
                }
                $ok++
                $restored.Add([pscustomobject]@{ Kind = $kind; From = $e.From; To = $e.To })
            }
        } catch {
            $errors += $_.Exception.Message
        }
    }
    Move-Item -LiteralPath $file.FullName -Destination ($file.FullName + '.undone') -Force
    [pscustomobject]@{ Restored = $ok; Errors = $errors; Entries = $restored.ToArray() }
}

# ---------------------------------------------------------------- library helpers

function New-Op([string]$Op, [string]$From, [string]$To) { [pscustomobject]@{ Op = $Op; From = $From; To = $To } }
function New-PlanRow([string]$Current, [string]$New, [string]$Status) { [pscustomobject]@{ Current = $Current; New = $New; Status = $Status } }
function Convert-Prefix([string]$Path, [string]$Old, [string]$New) { $New + $Path.Substring($Old.Length) }

function Get-ErrorText($ErrorRecord) { ($ErrorRecord.Exception.Message -split "`r?`n")[0] }

# "One.Piece.(1999)" / "[Group] Inception.2010.1080p.BluRay" -> Title "One Piece" / "Inception", Year 1999 / 2010.
function ConvertFrom-FolderTitle([string]$Name) {
    $s = $Name
    $s = Remove-SitePrefix $s
    while ($s -match '^\s*(\[[^\]]*\]|\{[^}]*\})\s*') { $s = $s.Substring($matches[0].Length) }
    $s = ConvertTo-SpacedName $s
    # The year is the last plausible 19xx/20xx that isn't the very start ("2001 A Space Odyssey 1968",
    # "Blade Runner 2049 (2017)" -> 1968 / 2017).
    $pick = $null
    $maxYear = (Get-Date).Year + 1
    foreach ($c in [regex]::Matches($s, '(?<!\d)[\(\[]?((?:19|20)\d\d)[\)\]]?(?!\d)')) {
        if ($c.Index -gt 0 -and [int]$c.Groups[1].Value -le $maxYear) { $pick = $c }
    }
    $year = $null
    if ($pick) { $year = [int]$pick.Groups[1].Value; $s = $s.Substring(0, $pick.Index) }
    else { $s = [regex]::Replace($s, $script:JunkPattern, '') }
    $s = (($s -replace '[\s\-\(\[\.,]+$', '') -replace '\s{2,}', ' ').Trim()
    [pscustomobject]@{ Title = $s; Year = $year }
}

function Select-BestMatch($Results, $Year) {
    $r = @($Results)
    if ($r.Count -eq 0) { return $null }
    if ($Year) {
        $m = $r | Where-Object { "$($_.Year)" -eq "$Year" } | Select-Object -First 1
        if ($m) { return $m }
    }
    $r[0]
}

# Searches the chosen TV source. If it's down (TVmaze has outages) or - for Sonarr - doesn't have the
# show, the other configured sources are tried: Sonarr, TVmaze, TheTVDB.
function Find-Shows([string]$Query, $Ctx, [string]$FolderLeaf = '') {
    $sources = New-Object System.Collections.Generic.List[string]
    $sources.Add($(if ($Ctx.Source) { $Ctx.Source } else { 'TVmaze' }))
    if ($Ctx.SonarrUrl -and $Ctx.SonarrKey) { $sources.Add('Sonarr') }
    $sources.Add('TVmaze')
    if ($Ctx.TvdbKey) { $sources.Add('TheTVDB') }
    $failed = @()
    foreach ($src in @($sources | Select-Object -Unique)) {
        try {
            $r = switch ($src) {
                'Sonarr'  { @(Search-Sonarr $Query $Ctx $FolderLeaf) }
                'TheTVDB' { Connect-Tvdb $Ctx.TvdbKey $Ctx.TvdbPin; @(Search-Tvdb $Query $Ctx.Lang) }
                default   { @(Search-TVmaze $Query) }
            }
            if (@($r).Count) { return @($r) }
        } catch {
            $code = $_.Exception.Data['StatusCode']
            # Only fall through on outages; a bad key etc. should be reported as-is.
            if ($null -ne $code -and $code -ne 0 -and $code -lt 500) { throw }
            $failed += "$src ($($_.Exception.Message))"
        }
    }
    if ($failed.Count) {
        $hint = if (-not ($Ctx.SonarrUrl -or $Ctx.TvdbKey)) { ' Connecting Sonarr or adding a TheTVDB key in Settings gives the app somewhere else to look when this happens.' } else { '' }
        throw "Couldn't search for '$Query': $($failed -join '; ').$hint"
    }
    @()
}

function Get-ShowEpisodes($Show, $Ctx) {
    switch ($Show.Source) {
        'Sonarr'  { return @(Get-SonarrEpisodes $Show.Id $Ctx) }
        'TheTVDB' { Connect-Tvdb $Ctx.TvdbKey $Ctx.TvdbPin; return @(Get-TvdbEpisodes $Show.Id $Ctx.Order $Ctx.Lang) }
    }
    @(Get-TVmazeEpisodes $Show.Id $Ctx.Order)
}

# ---------------------------------------------------------------- Sonarr / Radarr / Plex / Jellyfin
# Sonarr and Radarr track files by path. Renaming behind their back makes them show episodes as
# missing ("season incomplete") until they rescan, and a renamed show/movie folder leaves them
# pointing at a folder that no longer exists. When connected, the app updates their folder path and
# triggers a rescan after renaming. Using Sonarr as the TV source also means episodes are numbered
# exactly the way Sonarr expects (TheTVDB order), which matters most for anime.

function Get-ArrBase([string]$Url) {
    $u = $Url.Trim().TrimEnd('/')
    if ($u -and $u -notmatch '^https?://') { $u = "http://$u" }
    $u
}

function Invoke-Arr([string]$App, $Ctx, [string]$Path, [string]$Method = 'GET', $Body = $null, [switch]$Raw) {
    $url = if ($App -eq 'Sonarr') { $Ctx.SonarrUrl } else { $Ctx.RadarrUrl }
    $key = if ($App -eq 'Sonarr') { $Ctx.SonarrKey } else { $Ctx.RadarrKey }
    if (-not $url -or -not $key) { throw "$App isn't connected (Settings)." }
    try {
        Invoke-Json "$(Get-ArrBase $url)/api/v3/$Path" $Method $Body @{ 'X-Api-Key' = $key } -MaxAttempts 2 -Raw:$Raw
    } catch {
        if ($_.Exception.Data['StatusCode'] -eq 401) { throw "$App rejected the API key. Check it in Settings." }
        throw
    }
}

function Get-PathLeaf([string]$Path) { ($Path.TrimEnd('\', '/') -split '[\\/]')[-1] }

function ConvertTo-SonarrShow($s) {
    [pscustomobject]@{ Source = 'Sonarr'; Id = $s.id; Name = $s.title; Year = "$($s.year)"; Display = "$($s.title) ($($s.year))  [in Sonarr]"; Path = $s.path }
}

# Shows already in Sonarr: the one whose folder has this name first, then titles that match well.
function Search-Sonarr([string]$Query, $Ctx, [string]$FolderLeaf = '') {
    $all = @(Invoke-Arr 'Sonarr' $Ctx 'series')
    $byFolder = @($all | Where-Object { $FolderLeaf -and (Get-PathLeaf $_.path) -eq $FolderLeaf })
    $byTitle = @($all | Where-Object { $byFolder -notcontains $_ } | ForEach-Object {
            $score = [Math]::Max((Get-TitleSimilarity $_.title $Query), (Get-TitleSimilarity $Query $_.title))
            if ($score -ge 0.75) { [pscustomobject]@{ S = $_; Score = $score } }
        } | Sort-Object Score -Descending | ForEach-Object { $_.S })
    @($byFolder) + @($byTitle) | ForEach-Object { ConvertTo-SonarrShow $_ }
}

function Get-SonarrEpisodes($SeriesId, $Ctx) {
    $eps = foreach ($e in @(Invoke-Arr 'Sonarr' $Ctx "episode?seriesId=$SeriesId")) {
        [pscustomobject]@{
            Season   = [int]$e.seasonNumber
            Number   = [int]$e.episodeNumber
            Absolute = if ($e.absoluteEpisodeNumber) { [int]$e.absoluteEpisodeNumber } else { $null }
            Title    = if ($e.title) { $e.title } else { "Episode $($e.episodeNumber)" }
            AirDate  = $e.airDate
        }
    }
    Complete-AbsoluteNumbers $eps
}

# Movies through Radarr: films already in Radarr first, then Radarr's own lookup (no TMDB key needed).
function Search-Radarr([string]$Query, $Year, $Ctx, [string]$FolderLeaf = '') {
    $all = @(Invoke-Arr 'Radarr' $Ctx 'movie')
    $mine = @($all | Where-Object { ($FolderLeaf -and (Get-PathLeaf $_.path) -eq $FolderLeaf) -or ((Get-TitleSimilarity $_.title $Query) -ge 0.99 -and (-not $Year -or "$($_.year)" -eq "$Year")) })
    $found = if ($mine.Count) { $mine } else {
        $term = if ($Year) { "$Query $Year" } else { $Query }
        @(Invoke-Arr 'Radarr' $Ctx "movie/lookup?term=$([uri]::EscapeDataString($term))")
    }
    foreach ($m in $found) {
        $where = if ($m.id) { '  [in Radarr]' } else { '' }
        [pscustomobject]@{ Source = 'Radarr'; Id = $m.tmdbId; Name = $m.title; Year = "$($m.year)"; Display = "$($m.title) ($($m.year))$where" }
    }
}

# Swap the last folder of a path, keeping the other app's own separator (it may run on another OS).
function Set-PathLeaf([string]$Path, [string]$Leaf) {
    $trimmed = $Path.TrimEnd('\', '/')
    $i = [Math]::Max($trimmed.LastIndexOf('/'), $trimmed.LastIndexOf('\'))
    if ($i -lt 0) { return $Leaf }
    $trimmed.Substring(0, $i + 1) + $Leaf
}

# After a library rename: point Sonarr/Radarr at renamed folders, rescan, refresh Plex/Jellyfin.
# Returns one line per thing it did (or couldn't do); never throws.
function Sync-MediaApps($Done, $Ctx, [string]$Kind, [switch]$Quiet, [switch]$SkipServers) {
    $log = New-Object System.Collections.Generic.List[string]
    if ($Ctx.ArrSync -eq $false) { return @() }
    $seen = @{}
    $app = if ($Kind -eq 'Movie') { 'Radarr' } else { 'Sonarr' }
    $connected = if ($Kind -eq 'Movie') { $Ctx.RadarrUrl -and $Ctx.RadarrKey } else { $Ctx.SonarrUrl -and $Ctx.SonarrKey }
    if ($connected -and @($Done).Count) {
        try {
            $all = @(Invoke-Arr $app $Ctx $(if ($Kind -eq 'Movie') { 'movie' } else { 'series' }))
            foreach ($d in $Done) {
                $item = $all | Where-Object { (Get-PathLeaf $_.path) -eq $d.OldLeaf } | Select-Object -First 1
                if (-not $item -and $d.NewLeaf) { $item = $all | Where-Object { (Get-PathLeaf $_.path) -eq $d.NewLeaf } | Select-Object -First 1 }
                if (-not $item) { if (-not $Quiet) { $log.Add("${app}: '$($d.OldLeaf)' isn't in $app, nothing to update.") }; continue }
                if ($seen[$item.id] -and -not $d.NewLeaf) { continue }
                $seen[$item.id] = $true
                try {
                    if ($d.NewLeaf -and $d.NewLeaf -ne (Get-PathLeaf $item.path)) {
                        # Edit only "path" in the raw JSON and send the rest back byte-for-byte: a parse +
                        # re-serialize round trip in Windows PowerShell can mangle fields (alternate titles).
                        $res = if ($Kind -eq 'Movie') { 'movie' } else { 'series' }
                        $raw = Invoke-Arr $app $Ctx "$res/$($item.id)" -Raw
                        $oldJson = ConvertTo-Json -InputObject ([string]$item.path) -Compress
                        $newJson = ConvertTo-Json -InputObject (Set-PathLeaf $item.path $d.NewLeaf) -Compress
                        $pattern = '"path"\s*:\s*' + [regex]::Escape($oldJson)
                        if (-not [regex]::IsMatch($raw, $pattern)) { throw "couldn't find its folder path in $app's data" }
                        $updated = [regex]::Replace($raw, $pattern, ('"path":' + $newJson).Replace('$', '$$'))
                        [void](Invoke-Arr $app $Ctx "$res/$($item.id)?moveFiles=false" 'PUT' $updated)
                        $log.Add("${app}: '$($item.title)' now points at folder '$($d.NewLeaf)'.")
                    }
                    $cmd = if ($Kind -eq 'Movie') { @{ name = 'RescanMovie'; movieId = $item.id } } else { @{ name = 'RescanSeries'; seriesId = $item.id } }
                    [void](Invoke-Arr $app $Ctx 'command' 'POST' $cmd)
                    $log.Add("${app}: rescanning '$($item.title)'.")
                } catch { $log.Add("${app}: couldn't update '$($item.title)': $($_.Exception.Message)") }
            }
        } catch { $log.Add("${app}: $($_.Exception.Message)") }
    }
    if (-not $SkipServers) { foreach ($line in @(Update-MediaServers $Ctx $Kind)) { $log.Add($line) } }
    $log.ToArray()
}

# After an undo: point Sonarr/Radarr back at the original folders and rescan whatever was touched.
function Sync-AfterUndo($Undo, $Ctx) {
    if ($Ctx.ArrSync -eq $false) { return @() }
    $entries = New-Object System.Collections.Generic.List[object]
    $leaves = @{}
    foreach ($e in @($Undo.Entries)) {
        if ($e.Kind -eq 'Dir') { $entries.Add([pscustomobject]@{ OldLeaf = (Get-PathLeaf $e.To); NewLeaf = (Get-PathLeaf $e.From) }) }
        elseif ($e.Kind -eq 'File') {
            # The show/movie folder is the file's parent or grandparent (Season folder in between).
            $p = Split-Path $e.From -Parent
            foreach ($lvl in 1, 2) { if ($p) { $leaves[(Get-PathLeaf $p)] = $true; $p = Split-Path $p -Parent } }
        }
    }
    foreach ($l in $leaves.Keys) { $entries.Add([pscustomobject]@{ OldLeaf = $l; NewLeaf = '' }) }
    if ($entries.Count -eq 0) { return @() }
    $lines = @()
    if ($Ctx.SonarrUrl -and $Ctx.SonarrKey) { $lines += @(Sync-MediaApps $entries.ToArray() $Ctx 'TV' -Quiet -SkipServers) }
    if ($Ctx.RadarrUrl -and $Ctx.RadarrKey) { $lines += @(Sync-MediaApps $entries.ToArray() $Ctx 'Movie' -Quiet -SkipServers) }
    $lines += @(Update-MediaServers $Ctx 'TV')
    $lines += @(Update-MediaServers $Ctx 'Movie')
    @($lines | Where-Object { $_ })
}

# Which show/movie folders a finished library rename touched: { OldLeaf; NewLeaf } (NewLeaf '' = unchanged).
function Get-SyncEntries($Results) {
    foreach ($r in @($Results)) {
        if ($r.Error) { continue }
        $p = $r.Plan
        if ($p.Kind -eq 'Show') {
            [pscustomobject]@{ OldLeaf = (Split-Path $p.Dir -Leaf); NewLeaf = $p.NewName }
        } elseif ($p.NewName -match '[\\/]') {
            $newFolder = ($p.NewName -split '[\\/]')[0]
            $old = if ($p.Item.Type -eq 'Folder') { Split-Path $p.Item.Path -Leaf } else { $newFolder }
            [pscustomobject]@{ OldLeaf = $old; NewLeaf = $newFolder }
        }
    }
}

# Ask Plex / Jellyfin to rescan their libraries of this kind.
function Update-MediaServers($Ctx, [string]$Kind) {
    if ($Ctx.PlexUrl -and $Ctx.PlexToken) {
        try {
            $base = Get-ArrBase $Ctx.PlexUrl
            $h = @{ 'X-Plex-Token' = $Ctx.PlexToken }
            $want = if ($Kind -eq 'Movie') { 'movie' } else { 'show' }
            $secs = @((Invoke-Json "$base/library/sections" -Headers $h -MaxAttempts 2).MediaContainer.Directory | Where-Object { $_.type -eq $want })
            foreach ($s in $secs) { [void](Invoke-Json "$base/library/sections/$($s.key)/refresh" -Headers $h -MaxAttempts 1 -AllowEmpty) }
            "Plex: refreshing $($secs.Count) $want librar$(if ($secs.Count -eq 1) { 'y' } else { 'ies' })."
        } catch { "Plex: couldn't refresh ($($_.Exception.Message))" }
    }
    if ($Ctx.JellyfinUrl -and $Ctx.JellyfinKey) {
        try {
            [void](Invoke-Json "$(Get-ArrBase $Ctx.JellyfinUrl)/Library/Refresh" 'POST' $null @{ 'X-Emby-Token' = $Ctx.JellyfinKey } -MaxAttempts 1 -AllowEmpty)
            'Jellyfin: library scan started.'
        } catch { "Jellyfin: couldn't refresh ($($_.Exception.Message))" }
    }
}

# "Test" buttons in Settings.
function Test-MediaApp([string]$App, $Ctx) {
    switch ($App) {
        'Sonarr'   { $s = Invoke-Arr 'Sonarr' $Ctx 'system/status'; "Connected to Sonarr $($s.version)." }
        'Radarr'   { $s = Invoke-Arr 'Radarr' $Ctx 'system/status'; "Connected to Radarr $($s.version)." }
        'Plex'     { $s = Invoke-Json "$(Get-ArrBase $Ctx.PlexUrl)/identity" -Headers @{ 'X-Plex-Token' = $Ctx.PlexToken } -MaxAttempts 1; "Connected to Plex $($s.MediaContainer.version)." }
        'Jellyfin' { $s = Invoke-Json "$(Get-ArrBase $Ctx.JellyfinUrl)/System/Info" -Headers @{ 'X-Emby-Token' = $Ctx.JellyfinKey } -MaxAttempts 1; "Connected to Jellyfin $($s.Version)." }
    }
}

# ---------------------------------------------------------------- TV library planner

# A show folder has "Season NN" folders or video files directly inside it.
function Test-IsShowFolder([string]$Dir) {
    foreach ($k in @(Get-ChildItem -LiteralPath $Dir -ErrorAction SilentlyContinue)) {
        if ($k.PSIsContainer) { if ($null -ne (Get-FolderSeason $k.FullName)) { return $true } }
        elseif ($script:VideoExt -contains $k.Extension.ToLower()) { return $true }
    }
    $false
}

# The folder itself if it's a show, otherwise every show folder directly inside it.
function Get-TvShowFolders([string]$Root) {
    if (Test-IsShowFolder $Root) { return @($Root) }
    @(Get-ChildItem -LiteralPath $Root -Directory | Sort-Object Name | Where-Object { Test-IsShowFolder $_.FullName } | ForEach-Object { $_.FullName })
}

function Get-ShowPlan([string]$ShowDir, $Ctx, $ForcedShow) {
    $leaf = Split-Path $ShowDir -Leaf
    $ft = ConvertFrom-FolderTitle $leaf
    $plan = [pscustomobject]@{ Kind = 'Show'; Dir = $ShowDir; Label = $leaf; Query = $ft.Title; Year = $ft.Year
        Match = $null; Results = @(); NewName = ''; Ops = @(); Rows = @(); Status = '' }
    try {
        $eps = $null
        if ($ForcedShow) { $plan.Match = $ForcedShow }
        else {
            $plan.Results = @(Find-Shows $ft.Title $Ctx $leaf)
            $plan.Match = Select-BestMatch $plan.Results $ft.Year
            # "One Piece" with no year matches the anime and the live-action show; pick the one whose
            # episode list actually contains the files in the folder.
            $sameName = @($plan.Results | Where-Object { $_.Name -eq $ft.Title } | Select-Object -First 4)
            if (-not $ft.Year -and $sameName.Count -gt 1) {
                $parsed = @(Get-ShowFolderEpisodes $ShowDir)
                $best = -1
                foreach ($cand in $sameName) {
                    $candEps = Get-ShowEpisodes $cand $Ctx
                    $score = @($parsed | Where-Object { @(Find-Episodes $_ $candEps $Ctx.Match).Count -gt 0 }).Count
                    if ($score -gt $best) { $best = $score; $plan.Match = $cand; $eps = $candEps }
                }
            }
        }
        if (-not $plan.Match) { $plan.Status = 'Show not found - use "Change match..."'; return $plan }
        if (-not $eps) { $eps = Get-ShowEpisodes $plan.Match $Ctx }
        Add-ShowPlanOps $plan $eps $Ctx
    } catch {
        $plan.Status = 'Error: ' + (Get-ErrorText $_)
    }
    $plan
}

# Parsed names of the videos in a show folder and its direct sub-folders.
function Get-ShowFolderEpisodes([string]$ShowDir) {
    $dirs = @($ShowDir) + @(Get-ChildItem -LiteralPath $ShowDir -Directory | ForEach-Object { $_.FullName })
    foreach ($d in $dirs) {
        foreach ($f in @(Get-ChildItem -LiteralPath $d -File | Where-Object { $script:VideoExt -contains $_.Extension.ToLower() })) {
            ConvertFrom-EpisodeFileName $f.Name
        }
    }
}

function Get-PathAfterDirOps([string]$Path, [string]$Dir, [string]$ShowDir, [string]$NewShowDir, $DirTarget) {
    if ($DirTarget.ContainsKey($Dir)) { return Join-Path (Join-Path $NewShowDir $DirTarget[$Dir]) (Split-Path $Path -Leaf) }
    Convert-Prefix $Path $ShowDir $NewShowDir
}

# Where a planned destination is on disk *today* (before any folder renames), to detect name clashes.
function Get-OriginalPath([string]$Final, [string]$ShowDir, $DirTarget) {
    $season = Split-Path (Split-Path $Final -Parent) -Leaf
    $name = Split-Path $Final -Leaf
    foreach ($k in $DirTarget.Keys) { if ($DirTarget[$k] -eq $season) { return Join-Path $k $name } }
    $existing = Join-Path $ShowDir $season
    if ([IO.Directory]::Exists($existing) -and -not $DirTarget.ContainsKey($existing)) { return Join-Path $existing $name }
    $null
}

function Add-ShowPlanOps($Plan, $Episodes, $Ctx) {
    $showDir = $Plan.Dir
    $show = $Plan.Match
    $ops = New-Object System.Collections.Generic.List[object]
    $rows = New-Object System.Collections.Generic.List[object]
    $notes = @()

    # 1. Show folder -> "Name (Year)"
    $showName = Get-SafeText $show.Name
    $newLeaf = if ($show.Year) { "$showName ($($show.Year))" } else { $showName }
    $newShowDir = Join-Path (Split-Path $showDir -Parent) $newLeaf
    $renameShow = $newShowDir -cne $showDir
    if ($renameShow -and -not [string]::Equals($newShowDir, $showDir, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $newShowDir)) {
        $renameShow = $false
        $notes += "a folder named '$newLeaf' already exists"
    }
    if ($renameShow) { $ops.Add((New-Op 'MoveDir' $showDir $newShowDir)) } else { $newShowDir = $showDir }
    $Plan.NewName = if ($renameShow) { $newLeaf } else { '' }

    # 2. Work out where every episode (in the show folder or one level down) should end up.
    $leafScheme = @($Ctx.Scheme -split '[\\/]' | Where-Object { $_.Trim() })
    $leafScheme = if ($leafScheme.Count) { $leafScheme[-1] } else { $script:DefaultScheme }
    $subDirs = @(Get-ChildItem -LiteralPath $showDir -Directory | Sort-Object Name | ForEach-Object { $_.FullName })
    $entries = New-Object System.Collections.Generic.List[object]
    foreach ($dir in @($showDir) + $subDirs) {
        $files = @(Get-ChildItem -LiteralPath $dir -File)
        $vids = @($files | Where-Object { $script:VideoExt -contains $_.Extension.ToLower() } | Sort-Object Name)
        $subs = @($files | Where-Object { $script:SubExt -contains $_.Extension.ToLower() } | Sort-Object Name)
        $folderSeason = if ($dir -eq $showDir) { $null } else { Get-FolderSeason $dir }
        $claimed = @{}
        foreach ($f in @($vids) + @($subs)) {
            if ($claimed[$f.FullName]) { continue }
            $comps = @()
            if ($Ctx.Extras -and $script:VideoExt -contains $f.Extension.ToLower()) {
                $comps = @(Get-Companions $f.FullName $files | Where-Object { -not $claimed[$_.Path] })
                foreach ($c in $comps) { $claimed[$c.Path] = $true }
            }
            $rel = $f.FullName.Substring($showDir.Length).TrimStart('\', '/')
            $parsed = ConvertFrom-EpisodeFileName $f.Name
            $found = @(Find-Episodes $parsed $Episodes $Ctx.Match $folderSeason $show.Name)
            if ($found.Count -eq 0) {
                $why = if ($parsed.Kind -eq 'None') { "No episode number, and no $($show.Source) episode with that title" } else { "Not found on $($show.Source)" }
                $rows.Add((New-PlanRow $rel '' $why)); continue
            }
            $res = @(Resolve-EpisodeInfo $found $parsed $folderSeason $Ctx.Numbering $Ctx.TitleMode)
            if (@($res | Where-Object { $_.NeedsNumber }).Count) { $rows.Add((New-PlanRow $rel '' (Get-NeedsNumberText $res $show.Source))); continue }
            $season = $res[0].Season
            if ($season -ge 1900) {
                $rows.Add((New-PlanRow $rel '' "Season unknown - $($show.Source) numbers this show by year (put it in a Season folder or use TheTVDB)")); continue
            }
            $seasonFolder = if ($season -eq 0) { 'Specials' } else { 'Season {0:00}' -f $season }
            $name = Format-NewName $leafScheme @{ Show = $show.Name; Episodes = $res; Year = $show.Year; Original = [IO.Path]::GetFileNameWithoutExtension($f.Name) } $parsed
            if (-not $name) { $rows.Add((New-PlanRow $rel '' 'Scheme gives an empty name')); continue }
            $final = Join-Path (Join-Path $newShowDir $seasonFolder) $name
            $newBase = Join-Path (Split-Path $final -Parent) ([IO.Path]::GetFileNameWithoutExtension($final))
            foreach ($c in $comps) { $c.Target = $newBase + $c.Remainder }
            $entries.Add([pscustomobject]@{ Path = $f.FullName; Dir = $dir; Rel = $rel; Final = $final; SeasonFolder = $seasonFolder; Companions = $comps })
        }
    }

    # If none of the episodes are on this show, the match is probably wrong: don't touch the folder.
    if ($renameShow -and $entries.Count -eq 0 -and $rows.Count -gt 0) {
        $ops.Clear()
        $newShowDir = $showDir
        $Plan.NewName = ''
        $notes += 'no episodes matched this show - check the match'
    }

    # 3. Season folders -> "Season NN" (named after the season most of their episodes belong to).
    $existingLeaf = @{}
    foreach ($d in $subDirs) { $existingLeaf[(Split-Path $d -Leaf)] = $d }
    $dirTarget = @{}
    $claimedLeaf = @{}
    foreach ($d in $subDirs) {
        $mine = @($entries | Where-Object { $_.Dir -eq $d })
        if ($mine.Count -eq 0) { continue }
        $target = $mine | Group-Object SeasonFolder | Sort-Object Count -Descending | Select-Object -First 1 -ExpandProperty Name
        $leaf = Split-Path $d -Leaf
        if ($leaf -ceq $target) { $claimedLeaf[$target] = $true; continue }
        $other = $existingLeaf[$target]
        if (($other -and $other -ne $d) -or $claimedLeaf[$target]) { continue }   # merge into the existing folder via file moves
        $claimedLeaf[$target] = $true
        $dirTarget[$d] = $target
        $ops.Add((New-Op 'MoveDir' (Convert-Prefix $d $showDir $newShowDir) (Join-Path $newShowDir $target)))
        $rows.Add((New-PlanRow "$leaf$script:Sep" "$target$script:Sep" 'Rename folder'))
    }

    # 4. Episode files (and their extras) -> Season NN\<scheme>.
    $finals = @{}
    $moved = 0
    foreach ($e in $entries) {
        $cur = Get-PathAfterDirOps $e.Path $e.Dir $showDir $newShowDir $dirTarget
        $compMoves = @(foreach ($c in $e.Companions) {
                $cc = Get-PathAfterDirOps $c.Path $e.Dir $showDir $newShowDir $dirTarget
                if ($cc -cne $c.Target) { New-Op 'MoveFile' $cc $c.Target }
            })
        if ($cur -ceq $e.Final -and $compMoves.Count -eq 0) { continue }
        $newRel = $e.Final.Substring($newShowDir.Length).TrimStart('\', '/')
        if ($finals[$e.Final]) { $rows.Add((New-PlanRow $e.Rel $newRel 'Duplicate new name')); continue }
        $finals[$e.Final] = $true
        $orig = Get-OriginalPath $e.Final $showDir $dirTarget
        if ($cur -cne $e.Final -and $orig -and [IO.File]::Exists($orig) -and -not [string]::Equals($orig, $e.Path, [StringComparison]::OrdinalIgnoreCase)) {
            $rows.Add((New-PlanRow $e.Rel $newRel 'Name already taken')); continue
        }
        if ($cur -cne $e.Final) { $ops.Add((New-Op 'MoveFile' $cur $e.Final)) }
        foreach ($m in $compMoves) { $ops.Add($m) }
        $extra = if ($e.Companions.Count) { "   (+$($e.Companions.Count) extra)" } else { '' }
        $rows.Add((New-PlanRow ($e.Rel + $extra) $newRel 'Ready'))
        $moved++
    }

    # 5. Remove season folders that the moves left empty.
    if ($moved -gt 0) {
        foreach ($d in $subDirs) {
            if ($dirTarget.ContainsKey($d)) { continue }
            if (@($entries | Where-Object { $_.Dir -eq $d }).Count -eq 0) { continue }
            $ops.Add((New-Op 'RmDirIfEmpty' (Convert-Prefix $d $showDir $newShowDir) $null))
        }
    }

    $Plan.Ops = $ops.ToArray()
    $Plan.Rows = $rows.ToArray()
    Set-PlanStatus $Plan $notes
}

function Set-PlanStatus($Plan, $Notes) {
    $changes = @($Plan.Ops | Where-Object { $_.Op -ne 'RmDirIfEmpty' }).Count
    $skipped = @($Plan.Rows | Where-Object { $_.Status -notin @('Ready', 'Rename folder') }).Count
    $Plan.Status = if ($changes -eq 0) { 'Up to date' } else { "Ready ($changes change$(if ($changes -ne 1) { 's' }))" }
    if ($skipped) { $Plan.Status += ", $skipped skipped" }
    if (@($Notes).Count) { $Plan.Status += ' - ' + (@($Notes) -join '; ') }
}

# ---------------------------------------------------------------- movies

function Search-Tmdb([string]$Query, $Year, [string]$Key) {
    $base = "https://api.themoviedb.org/3/search/movie?include_adult=false&query=$([uri]::EscapeDataString($Query))"
    $headers = @{}
    # TMDB hands out a short v3 "API key" and a long v4 "read access token"; accept either.
    if ($Key.Length -gt 60) { $headers['Authorization'] = "Bearer $Key" } else { $base += "&api_key=$([uri]::EscapeDataString($Key))" }
    try {
        $r = $null
        if ($Year) { $r = Invoke-Json "$base&year=$Year" -Headers $headers }
        if (-not $r -or @($r.results).Count -eq 0) { $r = Invoke-Json $base -Headers $headers }
    } catch {
        if ($_.Exception.Data['StatusCode'] -eq 401) { throw 'TMDB rejected the API key. Check it in Settings.' }
        throw
    }
    foreach ($m in @($r.results)) {
        $y = if ($m.release_date -and $m.release_date.Length -ge 4) { $m.release_date.Substring(0, 4) } else { '' }
        $orig = if ($m.original_title -and $m.original_title -ne $m.title) { "  [$($m.original_title)]" } else { '' }
        [pscustomobject]@{ Source = 'TMDB'; Id = $m.id; Name = $m.title; Year = $y; Display = "$($m.title) ($y)$orig" }
    }
}

# Each movie is a loose video in the folder, or a sub-folder whose largest video is the movie.
# If the chosen folder is itself one movie's folder, that folder is the only item.
function Get-MovieItems([string]$Root) {
    $kids = @(Get-ChildItem -LiteralPath $Root | Sort-Object Name)
    $isVideo = { param($f) $script:VideoExt -contains $f.Extension.ToLower() -and $f.Name -notmatch '(?i)(^|[\s._-])sample([\s._-]|$)' }
    $loose = @($kids | Where-Object { -not $_.PSIsContainer -and (& $isVideo $_) })
    $items = New-Object System.Collections.Generic.List[object]
    foreach ($k in $kids | Where-Object { $_.PSIsContainer }) {
        $vids = @(Get-ChildItem -LiteralPath $k.FullName -File | Where-Object { & $isVideo $_ })
        if ($vids.Count -eq 0) { continue }
        $main = $vids | Sort-Object Length -Descending | Select-Object -First 1
        $items.Add([pscustomobject]@{ Type = 'Folder'; Path = $k.FullName; Main = $main.FullName; Root = $Root })
    }
    if ($items.Count -eq 0 -and $loose.Count -ge 1 -and (ConvertFrom-FolderTitle (Split-Path $Root -Leaf)).Year) {
        $main = $loose | Sort-Object Length -Descending | Select-Object -First 1
        return @([pscustomobject]@{ Type = 'Folder'; Path = $Root; Main = $main.FullName; Root = (Split-Path $Root -Parent) })
    }
    foreach ($f in $loose) { $items.Add([pscustomobject]@{ Type = 'File'; Path = $f.FullName; Main = $f.FullName; Root = $Root }) }
    @($items | Sort-Object { Split-Path $_.Path -Leaf })
}

function Get-MoviePlan($Item, $Ctx, $ForcedMovie) {
    $leaf = Split-Path $Item.Path -Leaf
    $fromFile = ConvertFrom-FolderTitle ([IO.Path]::GetFileNameWithoutExtension($Item.Main))
    $fromFolder = if ($Item.Type -eq 'Folder') { ConvertFrom-FolderTitle $leaf } else { $null }
    # Folder names are usually tidier than file names; prefer whichever has a year.
    $guess = if ($fromFolder -and $fromFolder.Year) { $fromFolder } elseif ($fromFile.Year) { $fromFile } elseif ($fromFolder -and $fromFolder.Title) { $fromFolder } else { $fromFile }
    $plan = [pscustomobject]@{ Kind = 'Movie'; Dir = $Item.Path; Item = $Item; Label = $leaf; Query = $guess.Title; Year = $guess.Year
        Match = $null; Results = @(); NewName = ''; Ops = @(); Rows = @(); Status = '' }
    $notes = @()
    try {
        if ($ForcedMovie) { $plan.Match = $ForcedMovie }
        else {
            # Radarr first (it also knows which folder each movie is in), then TMDB, then the filename.
            if ($Ctx.RadarrUrl -and $Ctx.RadarrKey) {
                try {
                    $folderLeaf = if ($Item.Type -eq 'Folder') { $leaf } else { '' }
                    $plan.Results = @(Search-Radarr $guess.Title $guess.Year $Ctx $folderLeaf)
                    $plan.Match = Select-BestMatch $plan.Results $guess.Year
                } catch { $notes += "Radarr lookup failed ($($_.Exception.Message))" }
            }
            if (-not $plan.Match -and $Ctx.TmdbKey) {
                $plan.Results = @(Search-Tmdb $guess.Title $guess.Year $Ctx.TmdbKey)
                $plan.Match = Select-BestMatch $plan.Results $guess.Year
            }
            if (-not $plan.Match -and ($Ctx.TmdbKey -or $Ctx.RadarrUrl)) { $notes += 'not found online, using the filename' }
        }
        if (-not $plan.Match) {
            if (-not $guess.Title) { $plan.Status = 'Could not read a title'; return $plan }
            $plan.Match = [pscustomobject]@{ Source = 'Filename'; Id = $null; Name = $guess.Title; Year = $guess.Year; Display = $guess.Title }
        }
        if (-not $plan.Match.Year) { $notes += 'no year found' }
        Add-MoviePlanOps $plan $Ctx
        Set-PlanStatus $plan $notes
    } catch {
        $plan.Status = 'Error: ' + (Get-ErrorText $_)
    }
    $plan
}

function Add-MoviePlanOps($Plan, $Ctx) {
    $item = $Plan.Item
    $m = $Plan.Match
    $name = Get-SafeText $m.Name
    $newLeaf = if ($m.Year) { "$name ($($m.Year))" } else { $name }
    $ext = [IO.Path]::GetExtension($item.Main)
    $mainDir = Split-Path $item.Main -Parent
    $comps = if ($Ctx.Extras) { @(Get-Companions $item.Main @(Get-ChildItem -LiteralPath $mainDir -File)) } else { @() }
    $ops = New-Object System.Collections.Generic.List[object]
    $rows = New-Object System.Collections.Generic.List[object]

    if ($item.Type -eq 'Folder') {
        # Rename the files inside first, then the folder itself.
        $newMain = Join-Path $item.Path ($newLeaf + $ext)
        if ($item.Main -cne $newMain) {
            if ([IO.File]::Exists($newMain) -and -not [string]::Equals($newMain, $item.Main, [StringComparison]::OrdinalIgnoreCase)) {
                $rows.Add((New-PlanRow (Split-Path $item.Main -Leaf) ($newLeaf + $ext) 'Name already taken'))
            } else {
                $ops.Add((New-Op 'MoveFile' $item.Main $newMain))
                foreach ($c in $comps) {
                    $ops.Add((New-Op 'MoveFile' $c.Path (Join-Path $item.Path ($newLeaf + $c.Remainder))))
                    $rows.Add((New-PlanRow ('+ ' + (Split-Path $c.Path -Leaf)) ($newLeaf + $c.Remainder) 'Ready'))
                }
            }
        }
        $newDir = Join-Path $item.Root $newLeaf
        $folderNew = $item.Path
        if ($newDir -cne $item.Path) {
            if (-not [string]::Equals($newDir, $item.Path, [StringComparison]::OrdinalIgnoreCase) -and (Test-Path -LiteralPath $newDir)) {
                $rows.Add((New-PlanRow "$(Split-Path $item.Path -Leaf)$script:Sep" "$newLeaf$script:Sep" 'Folder name taken'))
            } else {
                $ops.Add((New-Op 'MoveDir' $item.Path $newDir))
                $folderNew = $newDir
            }
        }
        $Plan.NewName = if ($ops.Count) { "$(Split-Path $folderNew -Leaf)$script:Sep$newLeaf$ext" } else { '' }
    } else {
        $destDir = if ($Ctx.MovieFolders) { Join-Path $item.Root $newLeaf } else { $item.Root }
        $newMain = Join-Path $destDir ($newLeaf + $ext)
        if ($newMain -cne $item.Main) {
            if ([IO.File]::Exists($newMain) -and -not [string]::Equals($newMain, $item.Main, [StringComparison]::OrdinalIgnoreCase)) {
                $rows.Add((New-PlanRow (Split-Path $item.Main -Leaf) $newMain.Substring($item.Root.Length).TrimStart('\', '/') 'Name already taken'))
            } elseif ([IO.File]::Exists($destDir)) {
                $rows.Add((New-PlanRow (Split-Path $item.Main -Leaf) '' "A file named '$newLeaf' is in the way"))
            } else {
                $ops.Add((New-Op 'MoveFile' $item.Main $newMain))
                foreach ($c in $comps) {
                    $t = Join-Path $destDir ($newLeaf + $c.Remainder)
                    $ops.Add((New-Op 'MoveFile' $c.Path $t))
                    $rows.Add((New-PlanRow ('+ ' + (Split-Path $c.Path -Leaf)) $t.Substring($item.Root.Length).TrimStart('\', '/') 'Ready'))
                }
                $Plan.NewName = $newMain.Substring($item.Root.Length).TrimStart('\', '/')
            }
        }
    }
    $Plan.Ops = $ops.ToArray()
    $Plan.Rows = $rows.ToArray()
}
