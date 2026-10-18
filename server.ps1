#!/usr/bin/env pwsh
# Episode Renamer web server: the TV Library and Movies tools in a browser, for Linux, Docker and Unraid.
# Runs on PowerShell 7+:   pwsh ./server.ps1
#
# Environment variables
#   PORT                    port to listen on (default 8080)
#   MEDIA_ROOTS             folders the app may browse and rename in, separated by ';' (default /media)
#   WEB_PASSWORD            if set, the browser asks for this password (any user name)
#   EPISODE_RENAMER_CONFIG  where settings and undo logs live (the Docker image uses /config)

$ErrorActionPreference = 'Stop'
$fnBefore = @(Get-ChildItem function: | ForEach-Object { $_.Name })
. (Join-Path $PSScriptRoot 'EpisodeRenamer.Core.ps1')
$coreFunctions = @(Get-ChildItem function: | ForEach-Object { $_.Name } | Where-Object { $fnBefore -notcontains $_ })
# Background jobs run in their own runspace; give them every core function.
$Prelude = (($coreFunctions | ForEach-Object { "function $_ {`n$((Get-Item "function:$_").Definition)`n}" }) -join "`n") + "`nInitialize-Core`n"

$Port = if ($env:PORT) { [int]$env:PORT } else { 8080 }
$defaultRoot = if ($IsWindows) { [Environment]::GetFolderPath('UserProfile') } else { '/media' }
$rootList = if ($env:MEDIA_ROOTS) { $env:MEDIA_ROOTS } else { $defaultRoot }
$MediaRoots = @($rootList -split ';' | ForEach-Object { $_.Trim() } | Where-Object { $_ } | ForEach-Object {
        $full = [IO.Path]::GetFullPath($_).TrimEnd('\', '/')
        if ($full) { $full } else { '/' }
    })
$PathCompare = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
$WebDir = Join-Path $PSScriptRoot 'web'
$Password = $env:WEB_PASSWORD
$SecretMask = '********'
$SecretKeys = @('TvdbApiKey', 'TvdbPin', 'TmdbKey', 'SonarrKey', 'RadarrKey', 'PlexToken', 'JellyfinKey')

$settings = Get-Settings
$plans = @{ TV = @(); Movie = @() }
$jobs = @{}

# ---------------------------------------------------------------- helpers

function Test-InRoots([string]$Path) {
    if (-not $Path) { return $false }
    try { $full = [IO.Path]::GetFullPath($Path).TrimEnd('\', '/') } catch { return $false }
    if (-not $full) { $full = '/' }
    foreach ($r in $MediaRoots) {
        if ($r -eq '/') { return $true }
        if ([string]::Equals($full, $r, $PathCompare) -or $full.StartsWith($r + $script:Sep, $PathCompare)) { return $true }
    }
    $false
}

function Get-Context {
    @{
        Source = $settings.Source; Order = $settings.Order; Lang = $settings.Language
        Match = $settings.MatchMode; Numbering = $settings.Numbering; TitleMode = $settings.TitleMode
        Scheme = $settings.Scheme; Extras = [bool]$settings.RenameExtras; MovieFolders = [bool]$settings.MovieFolders
        TvdbKey = $settings.TvdbApiKey; TvdbPin = $settings.TvdbPin; TmdbKey = $settings.TmdbKey
        SonarrUrl = $settings.SonarrUrl; SonarrKey = $settings.SonarrKey; RadarrUrl = $settings.RadarrUrl; RadarrKey = $settings.RadarrKey
        PlexUrl = $settings.PlexUrl; PlexToken = $settings.PlexToken; JellyfinUrl = $settings.JellyfinUrl; JellyfinKey = $settings.JellyfinKey
        ArrSync = [bool]$settings.ArrSync
    }
}

function ConvertTo-MatchDto($m) {
    if (-not $m) { return $null }
    [ordered]@{ source = $m.Source; id = $m.Id; name = $m.Name; year = "$($m.Year)"; display = $m.Display }
}

function ConvertFrom-MatchDto($d) {
    $year = if ("$($d.year)" -match '^\d{4}$') { "$($d.year)" } else { $null }
    $display = if ($d.display) { $d.display } else { $d.name }
    [pscustomobject]@{ Source = $d.source; Id = $d.id; Name = $d.name; Year = $year; Display = $display }
}

function ConvertTo-PlanDto($p, [int]$Index) {
    [ordered]@{
        index   = $Index
        label   = $p.Label
        dir     = $p.Dir
        newName = $p.NewName
        status  = $p.Status
        changes = @($p.Ops | Where-Object { $_.Op -ne 'RmDirIfEmpty' }).Count
        match   = ConvertTo-MatchDto $p.Match
        query   = $p.Query
        year    = "$($p.Year)"
        rows    = @($p.Rows | ForEach-Object { [ordered]@{ current = $_.Current; new = $_.New; status = $_.Status } })
        results = @($p.Results | ForEach-Object { ConvertTo-MatchDto $_ })
    }
}

function Get-SettingsDto {
    $s = [ordered]@{}
    foreach ($k in $settings.Keys) { $s[$k] = $settings[$k] }
    foreach ($k in $SecretKeys) { $s[$k] = if ($settings[$k]) { $SecretMask } else { '' } }
    $s
}

# ---------------------------------------------------------------- background jobs

function Start-ServerJob([string]$Type, [string]$Kind, [scriptblock]$Work, [hashtable]$Params) {
    $id = [guid]::NewGuid().ToString('N').Substring(0, 10)
    $sync = [hashtable]::Synchronized(@{ Status = 'Starting...' })
    $Params['Sync'] = $sync
    $Params['Token'] = $script:TvdbToken
    $ps = [powershell]::Create()
    [void]$ps.AddScript($Prelude, $false).Invoke()
    $ps.Commands.Clear()
    [void]$ps.AddScript($Work.ToString(), $false)
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    $jobs[$id] = @{ Type = $Type; Kind = $Kind; PS = $ps; Handle = $ps.BeginInvoke(); Sync = $sync; Done = $false; Error = $null }
    $id
}

function Update-ServerJob($j) {
    if ($j.Done -or -not $j.Handle.IsCompleted) { return }
    try {
        $res = $j.PS.EndInvoke($j.Handle)
        $out = if ($res.Count -gt 0) { $res[$res.Count - 1] } else { $null }
        if (-not $out) {
            if ($j.PS.Streams.Error.Count -gt 0) { throw $j.PS.Streams.Error[0].Exception }
            throw 'The job ended without a result.'
        }
        if ($out.Token) { $script:TvdbToken = $out.Token }
        if ($j.Type -eq 'analyze') { $plans[$j.Kind] = @($out.Plans) }
        else {
            $list = @($plans[$j.Kind])
            if ($out.Index -lt $list.Count) { $list[$out.Index] = $out.Plan }
            $plans[$j.Kind] = $list
        }
    } catch {
        $ex = $_.Exception
        while ($ex.InnerException) { $ex = $ex.InnerException }
        $j.Error = $ex.Message
    } finally {
        $j.PS.Dispose()
        $j.Done = $true
    }
}

$AnalyzeWork = {
    param($Root, $Ctx, $Kind, $Sync, $Token)
    $script:TvdbToken = $Token
    $list = New-Object System.Collections.Generic.List[object]
    if ($Kind -eq 'TV') {
        $Sync.Status = 'Looking for show folders...'
        $dirs = @(Get-TvShowFolders $Root)
        for ($i = 0; $i -lt $dirs.Count; $i++) {
            $Sync.Status = "Looking up $(Split-Path $dirs[$i] -Leaf) ($($i + 1) of $($dirs.Count))"
            $list.Add((Get-ShowPlan $dirs[$i] $Ctx $null))
        }
    } else {
        $Sync.Status = 'Looking for movies...'
        $items = @(Get-MovieItems $Root)
        for ($i = 0; $i -lt $items.Count; $i++) {
            $Sync.Status = "Checking $(Split-Path $items[$i].Path -Leaf) ($($i + 1) of $($items.Count))"
            $list.Add((Get-MoviePlan $items[$i] $Ctx $null))
        }
    }
    @{ Plans = $list.ToArray(); Token = $script:TvdbToken }
}

$RematchWork = {
    param($Kind, $Plan, $Ctx, $Forced, $Index, $Sync, $Token)
    $script:TvdbToken = $Token
    $Sync.Status = "Re-checking $($Plan.Label) as $($Forced.Name)"
    $p = if ($Kind -eq 'TV') { Get-ShowPlan $Plan.Dir $Ctx $Forced } else { Get-MoviePlan $Plan.Item $Ctx $Forced }
    $p.Results = @($Plan.Results)
    @{ Plan = $p; Index = $Index; Token = $script:TvdbToken }
}

# ---------------------------------------------------------------- http plumbing

function Send-Json($Ctx, $Obj, [int]$Code = 200) {
    $json = ConvertTo-Json -InputObject $Obj -Depth 10 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $Ctx.Response.StatusCode = $Code
    $Ctx.Response.ContentType = 'application/json; charset=utf-8'
    $Ctx.Response.Headers['Cache-Control'] = 'no-store'
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.Close()
}

function Send-Error($Ctx, [string]$Message, [int]$Code = 400) { Send-Json $Ctx @{ error = $Message } $Code }

function Send-File($Ctx, [string]$Path) {
    $types = @{ '.html' = 'text/html; charset=utf-8'; '.js' = 'text/javascript; charset=utf-8'; '.css' = 'text/css; charset=utf-8'
        '.png' = 'image/png'; '.ico' = 'image/x-icon'; '.svg' = 'image/svg+xml'; '.json' = 'application/json' }
    $bytes = [IO.File]::ReadAllBytes($Path)
    $type = $types[[IO.Path]::GetExtension($Path).ToLower()]
    $Ctx.Response.ContentType = if ($type) { $type } else { 'application/octet-stream' }
    $Ctx.Response.ContentLength64 = $bytes.Length
    $Ctx.Response.OutputStream.Write($bytes, 0, $bytes.Length)
    $Ctx.Response.Close()
}

function Read-Body($Req) {
    if (-not $Req.HasEntityBody) { return @{} }
    $text = [IO.StreamReader]::new($Req.InputStream, [Text.Encoding]::UTF8).ReadToEnd()
    if (-not $text.Trim()) { return @{} }
    $text | ConvertFrom-Json -AsHashtable
}

function Test-Auth($Req) {
    if (-not $Password) { return $true }
    $h = $Req.Headers['Authorization']
    if (-not $h -or -not $h.StartsWith('Basic ')) { return $false }
    try { $pair = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($h.Substring(6))) } catch { return $false }
    $given = $pair.Substring($pair.IndexOf(':') + 1)
    # Constant-time compare.
    $a = [Text.Encoding]::UTF8.GetBytes($given); $b = [Text.Encoding]::UTF8.GetBytes($Password)
    $diff = $a.Length -bxor $b.Length
    for ($i = 0; $i -lt [Math]::Min($a.Length, $b.Length); $i++) { $diff = $diff -bor ($a[$i] -bxor $b[$i]) }
    $diff -eq 0
}

# ---------------------------------------------------------------- routes

function Invoke-Route($Ctx) {
    $req = $Ctx.Request
    $path = $req.Url.AbsolutePath
    $method = $req.HttpMethod

    if (-not (Test-Auth $req)) {
        $Ctx.Response.Headers['WWW-Authenticate'] = 'Basic realm="Episode Renamer"'
        Send-Error $Ctx 'Password required.' 401
        return
    }

    if (-not $path.StartsWith('/api/')) {
        $rel = if ($path -eq '/') { 'index.html' } else { $path.TrimStart('/') }
        $file = [IO.Path]::GetFullPath((Join-Path $WebDir $rel))
        if ($file.StartsWith([IO.Path]::GetFullPath($WebDir), $PathCompare) -and [IO.File]::Exists($file)) { Send-File $Ctx $file }
        else { Send-Error $Ctx 'Not found.' 404 }
        return
    }

    $q = $req.QueryString
    switch ("$method $path") {
        'GET /api/info' {
            Send-Json $Ctx ([ordered]@{ version = $script:AppVersion; roots = $MediaRoots; separator = "$script:Sep"; repo = $script:RepoSlug })
        }
        'GET /api/settings' { Send-Json $Ctx (Get-SettingsDto) }
        'POST /api/settings' {
            $body = Read-Body $req
            foreach ($k in @($settings.Keys)) {
                if (-not $body.ContainsKey($k)) { continue }
                if ($k -in $SecretKeys) {
                    if ($body[$k] -eq $SecretMask) { continue }
                    $script:TvdbToken = $null
                }
                $settings[$k] = $body[$k]
            }
            Save-Settings $settings
            Send-Json $Ctx (Get-SettingsDto)
        }
        'GET /api/browse' {
            $p = $q['path']
            if (-not $p) {
                Send-Json $Ctx ([ordered]@{ path = ''; parent = $null; dirs = @($MediaRoots | ForEach-Object { [ordered]@{ name = $_; path = $_ } }) })
                return
            }
            if (-not (Test-InRoots $p) -or -not [IO.Directory]::Exists($p)) { Send-Error $Ctx "Not an allowed folder: $p"; return }
            $full = [IO.Path]::GetFullPath($p).TrimEnd('\', '/'); if (-not $full) { $full = '/' }
            $isRoot = @($MediaRoots | Where-Object { [string]::Equals($_, $full, $PathCompare) }).Count -gt 0
            $parent = if ($isRoot) { '' } else { Split-Path $full -Parent }
            $dirs = @(Get-ChildItem -LiteralPath $full -Directory -ErrorAction SilentlyContinue | Where-Object { -not $_.Name.StartsWith('.') } |
                    Sort-Object Name | ForEach-Object { [ordered]@{ name = $_.Name; path = $_.FullName } })
            Send-Json $Ctx ([ordered]@{ path = $full; parent = $parent; dirs = $dirs })
        }
        'POST /api/analyze' {
            $body = Read-Body $req
            $kind = if ($body.kind -eq 'Movie') { 'Movie' } else { 'TV' }
            $root = "$($body.root)".Trim().TrimEnd('\', '/')
            if (-not $root) { $root = '/' }
            if (-not (Test-InRoots $root) -or -not [IO.Directory]::Exists($root)) {
                Send-Error $Ctx "That folder doesn't exist or isn't under the media folders this app may use ($($MediaRoots -join ', '))."
                return
            }
            if ($kind -eq 'TV') { $settings.TvRoot = $root } else { $settings.MovieRoot = $root }
            Save-Settings $settings
            $plans[$kind] = @()
            $id = Start-ServerJob 'analyze' $kind $AnalyzeWork @{ Root = $root; Ctx = (Get-Context); Kind = $kind }
            Send-Json $Ctx @{ job = $id }
        }
        'GET /api/job' {
            $j = $jobs[$q['id']]
            if (-not $j) { Send-Error $Ctx 'Unknown job.' 404; return }
            Update-ServerJob $j
            Send-Json $Ctx ([ordered]@{ done = $j.Done; status = $j.Sync.Status; error = $j.Error; kind = $j.Kind })
        }
        'GET /api/plans' {
            $kind = if ($q['kind'] -eq 'Movie') { 'Movie' } else { 'TV' }
            $list = @($plans[$kind])
            $dtos = for ($i = 0; $i -lt $list.Count; $i++) { ConvertTo-PlanDto $list[$i] $i }
            Send-Json $Ctx @{ kind = $kind; plans = @($dtos) }
        }
        'POST /api/search' {
            $body = Read-Body $req
            $query = "$($body.query)".Trim()
            if (-not $query) { Send-Error $Ctx 'Type a title to search for.'; return }
            $year = if ("$($body.year)" -match '^\d{4}$') { [int]$body.year } else { $null }
            if ($body.kind -eq 'Movie') {
                $c = Get-Context
                if ($c.RadarrUrl -and $c.RadarrKey) { $res = @(Search-Radarr $query $year $c) }
                elseif ($settings.TmdbKey) { $res = @(Search-Tmdb $query $year $settings.TmdbKey) }
                else { Send-Error $Ctx 'Searching for movies needs Radarr or a TMDB key (Settings). Without either, type the title and year and use them as typed.'; return }
            } else {
                $res = @(Find-Shows $query (Get-Context))
            }
            Send-Json $Ctx @{ results = @($res | ForEach-Object { ConvertTo-MatchDto $_ }) }
        }
        'POST /api/rematch' {
            $body = Read-Body $req
            $kind = if ($body.kind -eq 'Movie') { 'Movie' } else { 'TV' }
            $list = @($plans[$kind])
            $index = [int]$body.index
            if ($index -lt 0 -or $index -ge $list.Count) { Send-Error $Ctx 'That item is no longer in the list. Analyze again.'; return }
            if (-not $body.match -or -not $body.match.name) { Send-Error $Ctx 'Pick a match first.'; return }
            $forced = ConvertFrom-MatchDto $body.match
            $id = Start-ServerJob 'rematch' $kind $RematchWork @{ Kind = $kind; Plan = $list[$index]; Ctx = (Get-Context); Forced = $forced; Index = $index }
            Send-Json $Ctx @{ job = $id }
        }
        'POST /api/rename' {
            $body = Read-Body $req
            $kind = if ($body.kind -eq 'Movie') { 'Movie' } else { 'TV' }
            $list = @($plans[$kind])
            $chosen = @(@($body.indexes) | ForEach-Object { [int]$_ } | Where-Object { $_ -ge 0 -and $_ -lt $list.Count } | Sort-Object -Unique |
                    Where-Object { @($list[$_].Ops).Count -gt 0 })
            if ($chosen.Count -eq 0) { Send-Error $Ctx 'Nothing is checked that has changes to make.'; return }
            $results = Invoke-LibraryPlans @($chosen | ForEach-Object { $list[$_] })
            $out = for ($i = 0; $i -lt $results.Count; $i++) {
                $r = $results[$i]
                $p = $list[$chosen[$i]]
                $p.Status = if ($r.Error) { "Stopped after $($r.Done) of $(@($p.Ops).Count): $($r.Error)" } else { 'Renamed' }
                $p.Ops = @()
                [ordered]@{ index = $chosen[$i]; ok = -not $r.Error; error = $r.Error }
            }
            $sync = @(Sync-MediaApps @(Get-SyncEntries $results) (Get-Context) $kind)
            Send-Json $Ctx @{ results = @($out); sync = $sync }
        }
        'POST /api/undo' {
            $r = Undo-LastRename
            $sync = @(Sync-AfterUndo $r (Get-Context))
            Send-Json $Ctx ([ordered]@{ restored = $r.Restored; errors = @($r.Errors); sync = $sync })
        }
        'POST /api/test' {
            # Test a connection with the values typed in Settings (saved values stand in for masked keys).
            $body = Read-Body $req
            $app = "$($body.app)"
            $names = @{ Sonarr = @('SonarrUrl', 'SonarrKey'); Radarr = @('RadarrUrl', 'RadarrKey'); Plex = @('PlexUrl', 'PlexToken'); Jellyfin = @('JellyfinUrl', 'JellyfinKey') }[$app]
            if (-not $names) { Send-Error $Ctx 'Unknown app.'; return }
            $c = Get-Context
            $c[$names[0]] = "$($body.url)".Trim()
            if ($body.key -and $body.key -ne $SecretMask) { $c[$names[1]] = "$($body.key)".Trim() }
            try { Send-Json $Ctx @{ ok = $true; message = (Test-MediaApp $app $c) } }
            catch { Send-Json $Ctx @{ ok = $false; message = "${app}: $($_.Exception.Message)" } }
        }
        default { Send-Error $Ctx 'Not found.' 404 }
    }
}

# ---------------------------------------------------------------- main loop

$listener = [Net.HttpListener]::new()
$prefix = if ($IsWindows) { "http://localhost:$Port/" } else { "http://*:$Port/" }
$listener.Prefixes.Add($prefix)
$listener.Start()
Write-Host "Episode Renamer $script:AppVersion web UI on port $Port"
Write-Host "Media folders: $($MediaRoots -join ', ')"
Write-Host "Settings and undo logs: $script:AppDir"
if ($Password) { Write-Host 'Password protection is on.' }

try {
    while ($listener.IsListening) {
        $task = $listener.GetContextAsync()
        while (-not $task.Wait(500)) { }   # short waits so Ctrl+C / docker stop get through
        $ctx = $task.Result
        try {
            Invoke-Route $ctx
        } catch {
            $msg = $_.Exception.Message
            Write-Host "Error handling $($ctx.Request.HttpMethod) $($ctx.Request.Url.AbsolutePath): $msg"
            try { Send-Error $ctx $msg 500 } catch { }
        }
    }
} finally {
    $listener.Stop()
}
