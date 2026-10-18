# Episode Renamer - core logic (filename parsing, metadata lookup, naming scheme, rename/undo).
# Dot-sourced by EpisodeRenamer.ps1. Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

Set-StrictMode -Off
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

$script:VideoExt = @('.mkv', '.mp4', '.avi', '.m4v', '.mov', '.wmv', '.ts', '.m2ts', '.webm', '.flv', '.mpg', '.mpeg')
$script:SubExt = @('.srt', '.ass', '.ssa', '.sub', '.idx', '.vtt', '.sup')
$script:AppDir = Join-Path $env:APPDATA 'EpisodeRenamer'
$script:DefaultScheme = '{show} - S{season:00}E{episode:00} - {title}'
$script:TvdbToken = $null
$script:LangCodes = 'en|eng|es|spa|fr|fre|fra|de|ger|deu|it|ita|pt|por|ja|jpn|ko|kor|zh|chi|zho|ru|rus|nl|dut|nld|sv|swe|no|nor|nb|da|dan|fi|fin|pl|pol|ar|ara|he|heb|tr|tur|hi|hin|cs|cze|ces|hu|hun|el|gre|ell|th|tha|vi|vie|id|ind|ro|rum|ron|uk|ukr'

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
        Recurse    = $false
        LastFolder = ''
        TvdbApiKey = ''
        TvdbPin    = ''
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
    param([string]$Url, [string]$Method = 'GET', $Body = $null, [hashtable]$Headers = @{})
    for ($attempt = 1; ; $attempt++) {
        $wc = New-Object System.Net.WebClient
        $wc.Encoding = [Text.Encoding]::UTF8
        $wc.Headers['User-Agent'] = 'EpisodeRenamer/1.0'
        $wc.Headers['Accept'] = 'application/json'
        foreach ($k in $Headers.Keys) { $wc.Headers[$k] = $Headers[$k] }
        try {
            if ($Method -eq 'GET') {
                $text = $wc.DownloadString($Url)
            } else {
                $wc.Headers['Content-Type'] = 'application/json'
                $text = $wc.UploadString($Url, $Method, ($Body | ConvertTo-Json -Compress))
            }
            return ($text | ConvertFrom-Json)
        } catch [System.Net.WebException] {
            $resp = $_.Exception.Response
            $code = if ($resp) { [int]$resp.StatusCode } else { 0 }
            # TVmaze rate-limits (429) and occasionally returns 502; retry those a couple of times.
            if ($attempt -lt 4 -and ($code -eq 429 -or $code -ge 500)) { Start-Sleep -Seconds (2 * $attempt); continue }
            $detail = ''
            if ($resp) { try { $detail = (New-Object IO.StreamReader($resp.GetResponseStream())).ReadToEnd() } catch { } }
            $ex = New-Object Exception("Request failed ($code): $Url`n$($_.Exception.Message) $detail")
            $ex.Data['StatusCode'] = $code
            throw $ex
        } finally {
            $wc.Dispose()
        }
    }
}

# ---------------------------------------------------------------- TVmaze (free, no key)

function Search-TVmaze([string]$Query) {
    $r = Invoke-Json "https://api.tvmaze.com/search/shows?q=$([uri]::EscapeDataString($Query))"
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
            Season   = if ($isSpecial) { 0 } else { [int]$e.season }
            Number   = if ($isSpecial) { $null } else { [int]$e.number }
            Absolute = $null
            Title    = $e.name
            AirDate  = $e.airdate
        }
    }
    # TVmaze lists specials without a number; number them per show in air order so S00Exx can still match.
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
    while ($s -match '^\s*(\[[^\]]*\]|\([^)]*\)|\{[^}]*\})\s*') { $s = $s.Substring($matches[0].Length) }
    $s = $s -replace '_+', ' '
    if (([regex]::Matches($s, ' ')).Count -lt 2) { $s = $s -replace '\.+', ' ' }
    $s = ($s -replace '\s{2,}', ' ').Trim()

    $result = [pscustomobject]@{
        Kind      = 'None'      # SE (season+episode), Abs (single/absolute number), None
        Season    = $null
        Episodes  = @()
        ShowGuess = ''
        Title     = ''          # episode title already in the filename, if any
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
    } else {
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
        $result.Title = ($rest -replace '^[\s\-:~|]+', '').Trim()
    }
    $result
}

$script:JunkPattern = '(?i)\s*(?:[\[\(\{].*|\b(?:480p|576p|720p|1080p|2160p|4K|UHD|HDR|WEB(?:-?DL|-?Rip)?|BluRay|BDRip|BRRip|HDTV|DVDRip|x264|x265|H\s?26[45]|HEVC|AVC|AAC(?:\d(?:\s\d)?)?|DDP?(?:\d(?:\s\d)?)?|AC3|FLAC|Opus|10bit|8bit|NF|AMZN|CR|DSNP|HMAX|REPACK|PROPER|iNTERNAL|MULTi|DUAL)\b.*)$'

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

function Find-Episodes($Parsed, $Episodes, [string]$MatchMode) {
    if ($Parsed.Kind -eq 'None') { return @() }
    $useSE = ($MatchMode -eq 'SeasonEpisode') -or ($MatchMode -eq 'Auto' -and $Parsed.Kind -eq 'SE')
    if ($useSE) {
        if ($null -eq $Parsed.Season) { return @() }
        $found = @(foreach ($n in $Parsed.Episodes) { $Episodes | Where-Object { $_.Season -eq $Parsed.Season -and $_.Number -eq $n } | Select-Object -First 1 })
        # Anime is often numbered absolutely ("S01E063", or TheTVDB-style "S02E63" while TVmaze uses
        # year seasons); when the season/episode pair doesn't exist, fall back to the absolute number.
        if ($found.Count -eq 0 -and $MatchMode -eq 'Auto') {
            $found = @(foreach ($n in $Parsed.Episodes) { $Episodes | Where-Object { $_.Absolute -eq $n } | Select-Object -First 1 })
        }
        return $found
    }
    @(foreach ($n in $Parsed.Episodes) { $Episodes | Where-Object { $_.Absolute -eq $n } | Select-Object -First 1 })
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
    for ($i = 0; $i -lt $found.Count; $i++) {
        $e = $found[$i]
        [pscustomobject]@{
            Season   = if ($useFile -and $null -ne $fileSeason) { $fileSeason } else { $e.Season }
            Number   = if ($useFile) { $Parsed.Episodes[[Math]::Min($i, $Parsed.Episodes.Count - 1)] } else { $e.Number }
            Absolute = $e.Absolute
            Title    = if ($title) { $title } else { $e.Title }
            AirDate  = $e.AirDate
        }
    }
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

# Returns the new relative path (may include sub-folders if the scheme contains "\").
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
    ($parts -join '\') + $Parsed.Suffix + $Parsed.Ext
}

# ---------------------------------------------------------------- rename + undo

function Invoke-RenamePlan($Plan) {
    $log = New-Object System.Collections.Generic.List[object]
    $results = foreach ($p in $Plan) {
        try {
            $dir = Split-Path $p.Target -Parent
            [void][IO.Directory]::CreateDirectory($dir)
            if ([string]::Equals($p.Source, $p.Target, [StringComparison]::OrdinalIgnoreCase)) {
                # Case-only change: go through a temporary name, Windows won't do it in one step.
                $tmp = $p.Source + '.renaming-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                [IO.File]::Move($p.Source, $tmp)
                [IO.File]::Move($tmp, $p.Target)
            } else {
                if ([IO.File]::Exists($p.Target)) { throw 'A file with the new name already exists.' }
                [IO.File]::Move($p.Source, $p.Target)
            }
            $log.Add([pscustomobject]@{ From = $p.Source; To = $p.Target })
            [pscustomobject]@{ Item = $p; Ok = $true; Error = $null }
        } catch {
            [pscustomobject]@{ Item = $p; Ok = $false; Error = $_.Exception.Message }
        }
    }
    if ($log.Count -gt 0) {
        $undoDir = Join-Path $script:AppDir 'undo'
        [void][IO.Directory]::CreateDirectory($undoDir)
        ConvertTo-Json -InputObject $log.ToArray() |
            Set-Content -LiteralPath (Join-Path $undoDir ((Get-Date).ToString('yyyyMMdd-HHmmss-fff') + '.json')) -Encoding UTF8
    }
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
    foreach ($e in $entries) {
        try {
            if (-not [IO.File]::Exists($e.To)) { throw "Missing: $($e.To)" }
            if ([string]::Equals($e.From, $e.To, [StringComparison]::OrdinalIgnoreCase)) {
                $tmp = $e.To + '.renaming-' + [guid]::NewGuid().ToString('N').Substring(0, 8)
                [IO.File]::Move($e.To, $tmp)
                [IO.File]::Move($tmp, $e.From)
            } else {
                if ([IO.File]::Exists($e.From)) { throw "Already exists: $($e.From)" }
                [void][IO.Directory]::CreateDirectory((Split-Path $e.From -Parent))
                [IO.File]::Move($e.To, $e.From)
            }
            $ok++
        } catch {
            $errors += $_.Exception.Message
        }
    }
    Move-Item -LiteralPath $file.FullName -Destination ($file.FullName + '.undone') -Force
    [pscustomobject]@{ Restored = $ok; Errors = $errors }
}
