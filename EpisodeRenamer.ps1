# Episode Renamer - Windows Forms GUI. Launch with "Episode Renamer.cmd".
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'EpisodeRenamer.Core.ps1')

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
try {
    Add-Type -Name Dpi -Namespace Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][Win32.Dpi]::SetProcessDPIAware()
} catch { }
[Windows.Forms.Application]::EnableVisualStyles()

$settings = Get-Settings
$script:EpisodeCache = @{}
$script:SearchResults = @()
$script:SelectedShow = $null
$script:Loading = $true
$script:Jobs = New-Object System.Collections.ArrayList
$script:AfterFetch = $null
$script:YearHint = $null
$script:UpdateUrl = $null

$MatchModes = [ordered]@{ 'Auto' = 'Auto'; 'Season + Episode' = 'SeasonEpisode'; 'Absolute number' = 'Absolute' }
$NumberingModes = [ordered]@{ 'Auto' = 'Auto'; 'From source' = 'Source'; 'From file / folder' = 'File' }
$TitleModes = [ordered]@{ 'Keep filename title' = 'File'; 'From source' = 'Source' }

function Select-ByValue($Combo, $Map, $Value, $Fallback) {
    $label = ($Map.GetEnumerator() | Where-Object { $_.Value -eq $Value } | Select-Object -First 1).Key
    $Combo.SelectedItem = if ($label) { $label } else { $Fallback }
}

# ---------------------------------------------------------------- control helpers

function New-Pad($l, $t, $r, $b) { New-Object Windows.Forms.Padding($l, $t, $r, $b) }

function New-Label([string]$Text) {
    $c = New-Object Windows.Forms.Label
    $c.Text = $Text; $c.AutoSize = $true; $c.Margin = New-Pad 6 8 3 0
    $c
}
function New-Button([string]$Text) {
    $c = New-Object Windows.Forms.Button
    $c.Text = $Text; $c.AutoSize = $true; $c.Margin = New-Pad 3 3 3 3
    $c
}
function New-TextBox([int]$Width) {
    $c = New-Object Windows.Forms.TextBox
    $c.Width = $Width; $c.Margin = New-Pad 3 4 3 3
    $c
}
function New-Combo([int]$Width, [string[]]$Items) {
    $c = New-Object Windows.Forms.ComboBox
    $c.Width = $Width; $c.DropDownStyle = 'DropDownList'; $c.Margin = New-Pad 3 4 3 3
    foreach ($i in $Items) { [void]$c.Items.Add($i) }
    $c
}
function New-Row {
    $p = New-Object Windows.Forms.FlowLayoutPanel
    $p.AutoSize = $true; $p.Dock = 'Fill'; $p.WrapContents = $true; $p.Margin = New-Pad 0 0 0 0
    $p
}

# ---------------------------------------------------------------- form

$form = New-Object Windows.Forms.Form
$form.Text = "Episode Renamer $script:AppVersion"
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object Drawing.Size(1180, 680)
$form.MinimumSize = New-Object Drawing.Size(900, 500)
$form.StartPosition = 'CenterScreen'
$form.AllowDrop = $true

$layout = New-Object Windows.Forms.TableLayoutPanel
$layout.Dock = 'Fill'; $layout.ColumnCount = 1; $layout.Padding = New-Pad 6 6 6 6
$form.Controls.Add($layout)

# Row 1: folder
$row1 = New-Row
$txtFolder = New-TextBox 560
$btnBrowse = New-Button 'Browse...'
$btnAddFiles = New-Button 'Add files...'
$chkRecurse = New-Object Windows.Forms.CheckBox
$chkRecurse.Text = 'Include subfolders'; $chkRecurse.AutoSize = $true; $chkRecurse.Margin = New-Pad 8 7 3 3
$btnScan = New-Button 'Scan'
$row1.Controls.AddRange(@((New-Label 'Folder:'), $txtFolder, $btnBrowse, $btnAddFiles, $chkRecurse, $btnScan))

# Row 2: lookup source
$row2 = New-Row
$cboSource = New-Combo 120 @('TVmaze', 'TheTVDB')
$cboOrder = New-Combo 100 @('Aired', 'DVD', 'Absolute')
$txtLang = New-TextBox 50
$btnSettings = New-Button 'Settings...'
$row2.Controls.AddRange(@((New-Label 'Source:'), $cboSource, (New-Label 'Episode order:'), $cboOrder,
        (New-Label 'Language (TVDB):'), $txtLang, $btnSettings))

# Row 2b: how files map to episodes
$row2b = New-Row
$cboMatch = New-Combo 130 @($MatchModes.Keys)
$cboNumbering = New-Combo 130 @($NumberingModes.Keys)
$cboTitles = New-Combo 140 @($TitleModes.Keys)
$chkExtras = New-Object Windows.Forms.CheckBox
$chkExtras.Text = 'Rename matching extras (.nfo, -thumb.jpg, .srt)'; $chkExtras.AutoSize = $true; $chkExtras.Margin = New-Pad 12 7 3 3
$row2b.Controls.AddRange(@((New-Label 'Match files by:'), $cboMatch, (New-Label 'Numbering:'), $cboNumbering,
        (New-Label 'Titles:'), $cboTitles, $chkExtras))

# Row 3: show search
$row3 = New-Row
$txtSearch = New-TextBox 240
$btnSearch = New-Button 'Search'
$cboResults = New-Combo 430 @()
$txtShowName = New-TextBox 200
$row3.Controls.AddRange(@((New-Label 'Show:'), $txtSearch, $btnSearch, $cboResults, (New-Label 'Name in file:'), $txtShowName))

# Row 4: scheme
$row4 = New-Row
$txtScheme = New-TextBox 460
$btnResetScheme = New-Button 'Reset'
$lblTokens = New-Label 'Tokens: {show} {season:00} {episode:00} {title} {absolute:000} {year} {airdate}   Use \ for folders, e.g. Season {season:00}\...'
$lblTokens.ForeColor = [Drawing.Color]::DimGray
$row4.Controls.AddRange(@((New-Label 'Name scheme:'), $txtScheme, $btnResetScheme, $lblTokens))

# Grid
$grid = New-Object Windows.Forms.DataGridView
$grid.Dock = 'Fill'
$grid.AllowUserToAddRows = $false
$grid.AllowUserToDeleteRows = $false
$grid.AllowUserToResizeRows = $false
$grid.RowHeadersVisible = $false
$grid.SelectionMode = 'FullRowSelect'
$grid.AutoSizeColumnsMode = 'Fill'
$grid.BackgroundColor = [Drawing.SystemColors]::Window
$grid.BorderStyle = 'Fixed3D'
$colUse = New-Object Windows.Forms.DataGridViewCheckBoxColumn
$colUse.HeaderText = 'Use'; $colUse.FillWeight = 5
[void]$grid.Columns.Add($colUse)
foreach ($c in @(@('Original name', 40), @('Detected', 9), @('New name', 46), @('Status', 14))) {
    $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
    $col.HeaderText = $c[0]; $col.FillWeight = $c[1]; $col.ReadOnly = $true
    [void]$grid.Columns.Add($col)
}

# Bottom bar
$row5 = New-Row
$btnPreview = New-Button 'Refresh preview'
$btnRename = New-Button 'Rename checked'
$btnRename.Font = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)
$btnUndo = New-Button 'Undo last rename'
$btnAll = New-Button 'Check all'
$btnNone = New-Button 'Check none'
$btnRemove = New-Button 'Remove selected'
$progress = New-Object Windows.Forms.ProgressBar
$progress.Style = 'Marquee'; $progress.Width = 110; $progress.Height = 16; $progress.Margin = New-Pad 10 9 3 3; $progress.Visible = $false
$lblStatus = New-Label ''
$lnkUpdate = New-Object Windows.Forms.LinkLabel
$lnkUpdate.AutoSize = $true; $lnkUpdate.Margin = New-Pad 16 8 3 0; $lnkUpdate.Visible = $false
$row5.Controls.AddRange(@($btnPreview, $btnRename, $btnUndo, $btnAll, $btnNone, $btnRemove, $progress, $lblStatus, $lnkUpdate))

foreach ($r in @($row1, $row2, $row2b, $row3, $row4)) { [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); $layout.Controls.Add($r) }
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('Percent', 100))); $layout.Controls.Add($grid)
[void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle('AutoSize'))); $layout.Controls.Add($row5)

$tips = New-Object Windows.Forms.ToolTip
$tips.SetToolTip($cboOrder, 'Aired = normal TV order. DVD/Absolute only differ on TheTVDB (TVmaze: Absolute = S01E<absolute>).')
$tips.SetToolTip($cboMatch, 'Auto: use SxxExx when the file has it, otherwise treat the lone number (e.g. "- 063") as an absolute episode number.')
$tips.SetToolTip($cboNumbering, 'Auto: use the source''s season/episode, unless it numbers seasons by year (TVmaze anime) - then use the file''s numbers and its "Season NN" folder.')
$tips.SetToolTip($cboTitles, 'Keep filename title: keep the episode title already in the filename and only look it up when the file has none.')
$tips.SetToolTip($chkExtras, 'Files next to a video that share its name - "<video>.nfo", "<video>-thumb.jpg", "<video>.en.srt" - get renamed along with it.')
$tips.SetToolTip($txtShowName, 'The show name written into the new file names. Edit it if you want a different spelling.')

# ---------------------------------------------------------------- general helpers

function Invoke-Safe([scriptblock]$Action) {
    try {
        & $Action
    } catch {
        [void][Windows.Forms.MessageBox]::Show($form, $_.Exception.Message, 'Episode Renamer', 'OK', 'Error')
    }
}

function Set-Status([string]$Text) { $lblStatus.Text = $Text }

# ---------------------------------------------------------------- background work
# Network calls run in a separate runspace so the window keeps painting; a timer picks up the result
# and runs the completion block on the UI thread. Only one visible (non-quiet) job runs at a time.

$script:BgFunctionNames = @('Invoke-Json', 'Search-TVmaze', 'Get-TVmazeEpisodes', 'Complete-AbsoluteNumbers',
    'Connect-Tvdb', 'Get-TvdbHeaders', 'Search-Tvdb', 'Get-TvdbEpisodes')
$script:BgPrelude = "[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12`n" +
    (($script:BgFunctionNames | ForEach-Object { "function $_ {`n$((Get-Item "function:$_").Definition)`n}" }) -join "`n")

$jobTimer = New-Object Windows.Forms.Timer
$jobTimer.Interval = 100

function Test-Busy { @($script:Jobs | Where-Object { -not $_.Quiet }).Count -gt 0 }

function Set-Busy([bool]$On) {
    foreach ($c in @($row1, $row2, $row2b, $row3, $row4, $btnPreview, $btnRename, $btnUndo, $btnRemove)) { $c.Enabled = -not $On }
    $progress.Visible = $On
    $form.UseWaitCursor = $On
}

# $Work runs in the background runspace (only the functions in BgFunctionNames exist there) and must
# return everything $OnDone needs; $OnDone gets that value on the UI thread.
function Start-Background([string]$Status, [scriptblock]$Work, [hashtable]$Params, [scriptblock]$OnDone, [switch]$Quiet) {
    if (-not $Quiet -and (Test-Busy)) { return $false }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:BgPrelude, $false).Invoke()
    $ps.Commands.Clear()
    [void]$ps.AddScript($Work.ToString(), $false)
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    [void]$script:Jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Quiet = [bool]$Quiet })
    if (-not $Quiet) { Set-Busy $true; Set-Status $Status }
    $jobTimer.Start()
    $true
}

$jobTimer.Add_Tick({
        foreach ($j in @($script:Jobs | Where-Object { $_.Handle.IsCompleted })) {
            $script:Jobs.Remove($j)
            $out = $null; $err = $null
            try {
                $res = $j.PS.EndInvoke($j.Handle)
                if ($res.Count -gt 0) { $out = $res[$res.Count - 1] }
                elseif ($j.PS.Streams.Error.Count -gt 0) { $err = $j.PS.Streams.Error[0].Exception.Message }
            } catch {
                $ex = $_.Exception
                while ($ex.InnerException) { $ex = $ex.InnerException }
                $err = $ex.Message
            } finally {
                $j.PS.Dispose()
            }
            if (-not $j.Quiet) { Set-Busy $false; Set-Status '' }
            if ($err) {
                if (-not $j.Quiet) { [void][Windows.Forms.MessageBox]::Show($form, $err, 'Episode Renamer', 'OK', 'Error') }
                continue
            }
            Invoke-Safe { & $j.OnDone $out }
        }
        if ($script:Jobs.Count -eq 0) { $jobTimer.Stop() }
    })

# ---------------------------------------------------------------- file list

function Get-RelativeDisplay($Item) {
    $root = $Item.Root.TrimEnd('\') + '\'
    $text = if ($Item.FullPath.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { $Item.FullPath.Substring($root.Length) } else { [IO.Path]::GetFileName($Item.FullPath) }
    if ($Item.Companions.Count -gt 0) { $text += "   (+$($Item.Companions.Count) extra)" }
    $text
}

function Get-DetectedText($Parsed) {
    switch ($Parsed.Kind) {
        'SE'  { $t = 'S{0:00}E{1:00}' -f $Parsed.Season, $Parsed.Episodes[0]; if ($Parsed.Episodes.Count -gt 1) { $t += '-E{0:00}' -f $Parsed.Episodes[-1] }; return $t }
        'Abs' { return '#' + ($Parsed.Episodes -join ',') }
    }
    '?'
}

function Set-RowOriginal($Row) {
    $Row.Cells[1].Value = Get-RelativeDisplay $Row.Tag
    $Row.Cells[1].ToolTipText = (@($Row.Tag.FullPath) + @($Row.Tag.Companions | ForEach-Object { '  + ' + [IO.Path]::GetFileName($_.Path) })) -join "`n"
}

function Add-Files([string[]]$Paths, [string]$Root) {
    $existing = @{}
    foreach ($row in $grid.Rows) {
        $existing[$row.Tag.FullPath.ToLower()] = $true
        foreach ($c in $row.Tag.Companions) { $existing[$c.Path.ToLower()] = $true }
    }
    $dirCache = @{}
    # Videos first so their extras are claimed before stand-alone subtitles get rows of their own.
    $ordered = @($Paths | Sort-Object { if ($script:VideoExt -contains [IO.Path]::GetExtension($_).ToLower()) { 0 } else { 1 } }, { $_ })
    foreach ($path in $ordered) {
        if ($existing[$path.ToLower()]) { continue }
        $ext = [IO.Path]::GetExtension($path).ToLower()
        $isVideo = $script:VideoExt -contains $ext
        if (-not $isVideo -and $script:SubExt -notcontains $ext) { continue }
        $dir = Split-Path $path -Parent
        $companions = @()
        if ($isVideo -and $chkExtras.Checked) {
            if (-not $dirCache.ContainsKey($dir)) { $dirCache[$dir] = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue) }
            $companions = @(Get-Companions $path $dirCache[$dir] | Where-Object { -not $existing[$_.Path.ToLower()] })
        }
        $item = [pscustomobject]@{
            FullPath     = $path
            Root         = if ($Root) { $Root } else { $dir }
            Parsed       = ConvertFrom-EpisodeFileName ([IO.Path]::GetFileName($path))
            FolderSeason = Get-FolderSeason $dir
            Companions   = $companions
            Target       = $null
            Status       = ''
        }
        $i = $grid.Rows.Add($true, '', (Get-DetectedText $item.Parsed), '', '')
        $grid.Rows[$i].Tag = $item
        Set-RowOriginal $grid.Rows[$i]
        $existing[$path.ToLower()] = $true
        foreach ($c in $companions) { $existing[$c.Path.ToLower()] = $true }
    }
    $script:YearHint = $grid.Rows | ForEach-Object { Get-YearHint (Split-Path $_.Tag.FullPath -Parent) } | Where-Object { $_ } |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 1 -ExpandProperty Name
    Update-SearchGuess
    Update-Preview
}

function Update-SearchGuess {
    if ($txtSearch.Text.Trim() -or $grid.Rows.Count -eq 0) { return }
    $guess = $grid.Rows | ForEach-Object { $_.Tag.Parsed.ShowGuess } | Where-Object { $_ } |
        Group-Object | Sort-Object Count -Descending | Select-Object -First 1 -ExpandProperty Name
    if (-not $guess) { $guess = Get-FolderShowGuess (Split-Path $grid.Rows[0].Tag.FullPath -Parent) }
    $txtSearch.Text = $guess
}

function Invoke-Scan {
    $folder = $txtFolder.Text.Trim()
    if (-not $folder -or -not (Test-Path -LiteralPath $folder -PathType Container)) { throw 'Pick a folder that exists first.' }
    $grid.Rows.Clear()
    $files = Get-ChildItem -LiteralPath $folder -File -Recurse:$chkRecurse.Checked |
        Where-Object { $script:VideoExt -contains $_.Extension.ToLower() -or $script:SubExt -contains $_.Extension.ToLower() } |
        Sort-Object FullName
    Add-Files @($files | ForEach-Object { $_.FullName }) $folder
    if (-not (Test-Busy)) { Set-Status "$($grid.Rows.Count) file(s) found." }
}

# ---------------------------------------------------------------- lookup

function Invoke-Search {
    $q = $txtSearch.Text.Trim()
    if (-not $q) { throw 'Type a show name to search for.' }
    $src = [string]$cboSource.SelectedItem
    $params = @{ Source = $src; Query = $q; Lang = $txtLang.Text.Trim(); Key = $settings.TvdbApiKey; Pin = $settings.TvdbPin; Token = $script:TvdbToken }
    [void](Start-Background "Searching $src for '$q'..." {
            param($Source, $Query, $Lang, $Key, $Pin, $Token)
            $script:TvdbToken = $Token
            if ($Source -eq 'TheTVDB') { Connect-Tvdb $Key $Pin; $r = @(Search-Tvdb $Query $Lang) } else { $r = @(Search-TVmaze $Query) }
            @{ Results = $r; Query = $Query; Token = $script:TvdbToken }
        } $params { param($o) Complete-Search $o })
}

function Complete-Search($o) {
    $script:TvdbToken = $o.Token
    $script:SearchResults = @($o.Results)
    $script:SelectedShow = $null
    $cboResults.Items.Clear()
    foreach ($r in $script:SearchResults) { [void]$cboResults.Items.Add($r.Display) }
    if ($script:SearchResults.Count -eq 0) { Update-Preview; throw "No shows found for '$($o.Query)'." }
    # Prefer the show whose first-aired year matches a "(1999)" in the folder path.
    $idx = 0
    if ($script:YearHint) {
        for ($i = 0; $i -lt $script:SearchResults.Count; $i++) { if ("$($script:SearchResults[$i].Year)" -eq "$script:YearHint") { $idx = $i; break } }
    }
    $picked = ($script:YearHint -and "$($script:SearchResults[$idx].Year)" -eq "$script:YearHint")
    # Without a year match, open the list once the episodes have loaded so the user checks the pick.
    $script:PromptPick = (-not $picked -and $script:SearchResults.Count -gt 1)
    $cboResults.SelectedIndex = $idx
}

function Get-CacheKey {
    if (-not $script:SelectedShow) { return $null }
    "$($script:SelectedShow.Source)|$($script:SelectedShow.Id)|$($cboOrder.SelectedItem)|$($txtLang.Text.Trim())"
}

function Request-Episodes {
    $show = $script:SelectedShow
    $params = @{ Source = $show.Source; Id = $show.Id; Order = [string]$cboOrder.SelectedItem; Lang = $txtLang.Text.Trim()
        Key = $settings.TvdbApiKey; Pin = $settings.TvdbPin; Token = $script:TvdbToken; CacheKey = (Get-CacheKey) }
    [void](Start-Background "Downloading episode list for $($show.Name)..." {
            param($Source, $Id, $Order, $Lang, $Key, $Pin, $Token, $CacheKey)
            $script:TvdbToken = $Token
            if ($Source -eq 'TheTVDB') { Connect-Tvdb $Key $Pin; $e = @(Get-TvdbEpisodes $Id $Order $Lang) } else { $e = @(Get-TVmazeEpisodes $Id $Order) }
            @{ Episodes = $e; CacheKey = $CacheKey; Token = $script:TvdbToken }
        } $params {
            param($o)
            $script:TvdbToken = $o.Token
            $script:EpisodeCache[$o.CacheKey] = @($o.Episodes)
            Update-Preview -Fetch   # settings may have changed while downloading; this fetches again if so
            if ($script:PromptPick -and -not (Test-Busy)) {
                $script:PromptPick = $false
                Set-Status "$($script:SearchResults.Count) shows found - check the right one is picked."
                $cboResults.DroppedDown = $true
            }
            if ($script:AfterFetch -and $script:EpisodeCache.ContainsKey((Get-CacheKey))) {
                $next = $script:AfterFetch; $script:AfterFetch = $null; & $next
            }
        })
}

# ---------------------------------------------------------------- preview + rename

function Set-RowState($Row, [string]$NewName, [string]$Status) {
    $Row.Tag.Status = $Status
    $Row.Cells[3].Value = $NewName
    $Row.Cells[4].Value = $Status
    $color = switch -Wildcard ($Status) {
        'Ready'     { [Drawing.Color]::DarkGreen }
        'Renamed*'  { [Drawing.Color]::DarkGreen }
        'Unchanged' { [Drawing.Color]::Gray }
        ''          { [Drawing.Color]::Gray }
        default     { [Drawing.Color]::Firebrick }
    }
    $Row.Cells[4].Style.ForeColor = $color
}

function Test-TargetTaken([string]$Target, [string]$Source) {
    [IO.File]::Exists($Target) -and -not [string]::Equals($Target, $Source, [StringComparison]::OrdinalIgnoreCase)
}

function Update-Preview([switch]$Fetch) {
    if ($script:Loading -or $grid.Rows.Count -eq 0) { return }
    if (-not $script:SelectedShow) {
        foreach ($row in $grid.Rows) { if ($row.Tag.Status -notlike 'Renamed*') { $row.Tag.Target = $null; Set-RowState $row '' 'Search for a show' } }
        return
    }
    $key = Get-CacheKey
    if (-not $script:EpisodeCache.ContainsKey($key)) {
        if ($Fetch -and -not (Test-Busy)) { Request-Episodes }
        return
    }
    $eps = $script:EpisodeCache[$key]

    $scheme = $txtScheme.Text
    $mode = $MatchModes[[string]$cboMatch.SelectedItem]
    $numbering = $NumberingModes[[string]$cboNumbering.SelectedItem]
    $titleMode = $TitleModes[[string]$cboTitles.SelectedItem]
    $hasFolders = $scheme -match '[\\/]'
    foreach ($row in $grid.Rows) {
        $item = $row.Tag
        $item.Target = $null
        if ($item.Parsed.Kind -eq 'None') { Set-RowState $row '' 'No episode number found'; continue }
        $found = @(Find-Episodes $item.Parsed $eps $mode)
        if ($found.Count -eq 0) { Set-RowState $row '' "Not found on $($script:SelectedShow.Source)"; continue }
        $found = @(Resolve-EpisodeInfo $found $item.Parsed $item.FolderSeason $numbering $titleMode)
        $ctx = @{ Show = $txtShowName.Text; Episodes = $found; Year = $script:SelectedShow.Year; Original = [IO.Path]::GetFileNameWithoutExtension($item.FullPath) }
        $rel = Format-NewName $scheme $ctx $item.Parsed
        if (-not $rel) { Set-RowState $row '' 'Scheme gives an empty name'; continue }
        $baseDir = if ($hasFolders) { $item.Root } else { Split-Path $item.FullPath -Parent }
        $item.Target = Join-Path $baseDir $rel
        $newBase = Join-Path (Split-Path $item.Target -Parent) ([IO.Path]::GetFileNameWithoutExtension($item.Target))
        foreach ($c in $item.Companions) { $c.Target = $newBase + $c.Remainder }

        $display = if ($hasFolders) { $rel } else { [IO.Path]::GetFileName($rel) }
        if ($item.Target -ceq $item.FullPath) { Set-RowState $row $display 'Unchanged' }
        elseif ((Test-TargetTaken $item.Target $item.FullPath) -or @($item.Companions | Where-Object { Test-TargetTaken $_.Target $_.Path }).Count) { Set-RowState $row $display 'Name already taken' }
        else { Set-RowState $row $display 'Ready' }
    }
    # Two checked files must not end up with the same name.
    $groups = $grid.Rows | Where-Object { $_.Cells[0].Value -and $_.Tag.Status -eq 'Ready' } | Group-Object { $_.Tag.Target.ToLower() } | Where-Object { $_.Count -gt 1 }
    foreach ($g in $groups) { foreach ($row in $g.Group) { Set-RowState $row $row.Cells[3].Value 'Duplicate new name' } }

    $ready = @($grid.Rows | Where-Object { $_.Cells[0].Value -and $_.Tag.Status -eq 'Ready' }).Count
    if (-not (Test-Busy)) { Set-Status "$ready file(s) ready to rename." }
}

function Invoke-Rename {
    if ($script:SelectedShow -and -not $script:EpisodeCache.ContainsKey((Get-CacheKey))) {
        $script:AfterFetch = { Invoke-Rename }
        Update-Preview -Fetch
        return
    }
    Update-Preview
    $rows = @($grid.Rows | Where-Object { $_.Cells[0].Value -and $_.Tag.Status -eq 'Ready' })
    if ($rows.Count -eq 0) { throw 'Nothing is ready to rename. Check the Status column.' }
    $extraCount = ($rows | ForEach-Object { $_.Tag.Companions.Count } | Measure-Object -Sum).Sum
    $msg = "Rename $($rows.Count) file(s)?"
    if ($extraCount) { $msg = "Rename $($rows.Count) file(s) plus $extraCount matching extra file(s)?" }
    if ([Windows.Forms.MessageBox]::Show($form, $msg, 'Episode Renamer', 'YesNo', 'Question') -ne 'Yes') { return }

    $plan = foreach ($row in $rows) {
        [pscustomobject]@{ Source = $row.Tag.FullPath; Target = $row.Tag.Target; Row = $row; Companion = $null }
        foreach ($c in $row.Tag.Companions) { [pscustomobject]@{ Source = $c.Path; Target = $c.Target; Row = $row; Companion = $c } }
    }
    $results = Invoke-RenamePlan @($plan)
    $ok = 0
    $extraErrors = @()
    foreach ($r in $results) {
        $row = $r.Item.Row
        if ($r.Item.Companion) {
            if ($r.Ok) { $r.Item.Companion.Path = $r.Item.Target } else { $extraErrors += "$([IO.Path]::GetFileName($r.Item.Source)): $($r.Error)" }
            continue
        }
        if ($r.Ok) {
            $ok++
            $row.Tag.FullPath = $r.Item.Target
            $row.Tag.Parsed = ConvertFrom-EpisodeFileName ([IO.Path]::GetFileName($r.Item.Target))
            $row.Tag.FolderSeason = Get-FolderSeason (Split-Path $r.Item.Target -Parent)
            $row.Cells[2].Value = Get-DetectedText $row.Tag.Parsed
            Set-RowState $row $row.Cells[3].Value 'Renamed'
        } else {
            Set-RowState $row $row.Cells[3].Value "Error: $($r.Error)"
        }
    }
    foreach ($row in $rows) { Set-RowOriginal $row }
    Set-Status "Renamed $ok of $($rows.Count) file(s)."
    if ($extraErrors.Count) {
        [void][Windows.Forms.MessageBox]::Show($form, "Some extra files couldn't be renamed:`n`n" + (($extraErrors | Select-Object -First 10) -join "`n"), 'Episode Renamer', 'OK', 'Warning')
    }
}

function Invoke-Undo {
    $answer = [Windows.Forms.MessageBox]::Show($form, 'Undo the most recent batch of renames?', 'Episode Renamer', 'YesNo', 'Question')
    if ($answer -ne 'Yes') { return }
    $r = Undo-LastRename
    $msg = "Restored $($r.Restored) file(s)."
    if ($r.Errors.Count) { $msg += "`n`nProblems:`n" + (($r.Errors | Select-Object -First 10) -join "`n") }
    [void][Windows.Forms.MessageBox]::Show($form, $msg, 'Episode Renamer', 'OK', 'Information')
    if ($txtFolder.Text.Trim() -and (Test-Path -LiteralPath $txtFolder.Text.Trim())) { Invoke-Scan }
}

function Show-SettingsDialog {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Settings'; $dlg.Font = $form.Font; $dlg.AutoScaleMode = 'Dpi'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'; $dlg.AutoSize = $true; $dlg.AutoSizeMode = 'GrowAndShrink'; $dlg.Padding = New-Pad 10 10 10 10
    $t = New-Object Windows.Forms.TableLayoutPanel
    $t.AutoSize = $true; $t.ColumnCount = 2; $t.Dock = 'Fill'
    $info = New-Label "TheTVDB needs a free/personal API key. Some keys also need your subscriber PIN.`nTVmaze works without any key."
    $t.Controls.Add($info); $t.SetColumnSpan($info, 2)
    $txtKey = New-TextBox 340; $txtKey.Text = $settings.TvdbApiKey
    $txtPin = New-TextBox 340; $txtPin.Text = $settings.TvdbPin
    $t.Controls.Add((New-Label 'TheTVDB API key:')); $t.Controls.Add($txtKey)
    $t.Controls.Add((New-Label 'Subscriber PIN (optional):')); $t.Controls.Add($txtPin)
    $link = New-Object Windows.Forms.LinkLabel
    $link.Text = 'Get a key: https://thetvdb.com/api-information'; $link.AutoSize = $true; $link.Margin = New-Pad 6 8 3 8
    $link.Add_LinkClicked({ Start-Process 'https://thetvdb.com/api-information' })
    $t.Controls.Add($link); $t.SetColumnSpan($link, 2)
    $btns = New-Row
    $ok = New-Button 'Save'; $ok.DialogResult = 'OK'
    $cancel = New-Button 'Cancel'; $cancel.DialogResult = 'Cancel'
    $btns.Controls.AddRange(@($ok, $cancel))
    $t.Controls.Add($btns); $t.SetColumnSpan($btns, 2)
    $dlg.Controls.Add($t)
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    if ($dlg.ShowDialog($form) -eq 'OK') {
        $settings.TvdbApiKey = $txtKey.Text.Trim()
        $settings.TvdbPin = $txtPin.Text.Trim()
        $script:TvdbToken = $null
        Save-Settings $settings
    }
    $dlg.Dispose()
}

function Start-UpdateCheck {
    [void](Start-Background '' {
            param($Repo)
            Invoke-Json "https://api.github.com/repos/$Repo/releases/latest"
        } @{ Repo = $script:RepoSlug } {
            param($rel)
            try { $newer = [version]($rel.tag_name.TrimStart('v')) -gt [version]$script:AppVersion } catch { $newer = $false }
            if ($newer) {
                $script:UpdateUrl = $rel.html_url
                $lnkUpdate.Text = "Version $($rel.tag_name.TrimStart('v')) is available - click to download"
                $lnkUpdate.Visible = $true
            }
        } -Quiet)
}

# ---------------------------------------------------------------- events

$btnBrowse.Add_Click({
        $d = New-Object Windows.Forms.FolderBrowserDialog
        $d.Description = 'Folder with the episodes to rename'
        if ($txtFolder.Text -and (Test-Path -LiteralPath $txtFolder.Text)) { $d.SelectedPath = $txtFolder.Text }
        if ($d.ShowDialog($form) -eq 'OK') { $txtFolder.Text = $d.SelectedPath; $txtSearch.Text = ''; Invoke-Safe { Invoke-Scan } }
    })
$btnAddFiles.Add_Click({
        $d = New-Object Windows.Forms.OpenFileDialog
        $d.Multiselect = $true
        $d.Filter = 'Video and subtitle files|' + ((@($script:VideoExt) + @($script:SubExt) | ForEach-Object { "*$_" }) -join ';') + '|All files|*.*'
        if ($d.ShowDialog($form) -eq 'OK') { Invoke-Safe { Add-Files $d.FileNames $null } }
    })
$btnScan.Add_Click({ Invoke-Safe { Invoke-Scan } })
$txtFolder.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Invoke-Safe { Invoke-Scan } } })
$chkExtras.Add_CheckedChanged({ if (-not $script:Loading -and $grid.Rows.Count -gt 0 -and $txtFolder.Text.Trim()) { Invoke-Safe { Invoke-Scan } } })

$form.Add_DragEnter({ if ($_.Data.GetDataPresent([Windows.Forms.DataFormats]::FileDrop) -and -not (Test-Busy)) { $_.Effect = 'Copy' } })
$form.Add_DragDrop({
        $paths = @($_.Data.GetData([Windows.Forms.DataFormats]::FileDrop))
        Invoke-Safe {
            if ($paths.Count -eq 1 -and (Test-Path -LiteralPath $paths[0] -PathType Container)) {
                $txtFolder.Text = $paths[0]; $txtSearch.Text = ''; Invoke-Scan
            } else {
                $files = foreach ($p in $paths) {
                    if (Test-Path -LiteralPath $p -PathType Container) { Get-ChildItem -LiteralPath $p -File -Recurse | ForEach-Object { $_.FullName } } else { $p }
                }
                Add-Files @($files) $null
            }
        }
    })

$cboSource.Add_SelectedIndexChanged({
        if ($script:Loading) { return }
        $cboResults.Items.Clear(); $script:SearchResults = @(); $script:SelectedShow = $null
        Update-Preview
        if ($txtSearch.Text.Trim()) { Invoke-Safe { Invoke-Search } }
    })
$cboResults.Add_SelectedIndexChanged({
        $i = $cboResults.SelectedIndex
        if ($i -lt 0 -or $i -ge $script:SearchResults.Count) { return }
        $script:SelectedShow = $script:SearchResults[$i]
        $script:Loading = $true; $txtShowName.Text = $script:SelectedShow.Name; $script:Loading = $false
        Invoke-Safe { Update-Preview -Fetch }
    })
$btnSearch.Add_Click({ Invoke-Safe { Invoke-Search } })
$txtSearch.Add_KeyDown({ if ($_.KeyCode -eq 'Enter') { $_.SuppressKeyPress = $true; Invoke-Safe { Invoke-Search } } })

$cboOrder.Add_SelectedIndexChanged({ Invoke-Safe { Update-Preview -Fetch } })
$txtLang.Add_Leave({ Invoke-Safe { Update-Preview -Fetch } })
$cboMatch.Add_SelectedIndexChanged({ Invoke-Safe { Update-Preview } })
$cboNumbering.Add_SelectedIndexChanged({ Invoke-Safe { Update-Preview } })
$cboTitles.Add_SelectedIndexChanged({ Invoke-Safe { Update-Preview } })
$txtScheme.Add_TextChanged({ Invoke-Safe { Update-Preview } })
$txtShowName.Add_TextChanged({ Invoke-Safe { Update-Preview } })
$btnResetScheme.Add_Click({ $txtScheme.Text = $script:DefaultScheme })
$btnSettings.Add_Click({ Show-SettingsDialog })
$lnkUpdate.Add_LinkClicked({ if ($script:UpdateUrl) { Start-Process $script:UpdateUrl } })

$grid.Add_CurrentCellDirtyStateChanged({ if ($grid.IsCurrentCellDirty) { $grid.CommitEdit('CurrentCellChange') } })
$grid.Add_CellValueChanged({ if ($_.ColumnIndex -eq 0) { Invoke-Safe { Update-Preview } } })

$btnPreview.Add_Click({ Invoke-Safe { Update-Preview -Fetch } })
$btnRename.Add_Click({ Invoke-Safe { Invoke-Rename } })
$btnUndo.Add_Click({ Invoke-Safe { Invoke-Undo } })
$btnAll.Add_Click({ foreach ($r in $grid.Rows) { $r.Cells[0].Value = $true } })
$btnNone.Add_Click({ foreach ($r in $grid.Rows) { $r.Cells[0].Value = $false } })
$btnRemove.Add_Click({ foreach ($r in @($grid.SelectedRows)) { $grid.Rows.Remove($r) }; Invoke-Safe { Update-Preview } })

$form.Add_Shown({ Start-UpdateCheck })
$form.Add_FormClosing({
        $settings.Scheme = $txtScheme.Text
        $settings.Source = [string]$cboSource.SelectedItem
        $settings.Order = [string]$cboOrder.SelectedItem
        $settings.Language = $txtLang.Text.Trim()
        $settings.MatchMode = $MatchModes[[string]$cboMatch.SelectedItem]
        $settings.Numbering = $NumberingModes[[string]$cboNumbering.SelectedItem]
        $settings.TitleMode = $TitleModes[[string]$cboTitles.SelectedItem]
        $settings.RenameExtras = $chkExtras.Checked
        $settings.Recurse = $chkRecurse.Checked
        $settings.LastFolder = $txtFolder.Text.Trim()
        try { Save-Settings $settings } catch { }
        foreach ($j in @($script:Jobs)) { try { $j.PS.Stop(); $j.PS.Dispose() } catch { } }
    })

# ---------------------------------------------------------------- start

$txtScheme.Text = if ($settings.Scheme) { $settings.Scheme } else { $script:DefaultScheme }
$cboSource.SelectedItem = if ($cboSource.Items -contains $settings.Source) { $settings.Source } else { 'TVmaze' }
$cboOrder.SelectedItem = if ($cboOrder.Items -contains $settings.Order) { $settings.Order } else { 'Aired' }
$txtLang.Text = $settings.Language
Select-ByValue $cboMatch $MatchModes $settings.MatchMode 'Auto'
Select-ByValue $cboNumbering $NumberingModes $settings.Numbering 'Auto'
Select-ByValue $cboTitles $TitleModes $settings.TitleMode 'Keep filename title'
$chkExtras.Checked = [bool]$settings.RenameExtras
$chkRecurse.Checked = [bool]$settings.Recurse
$txtFolder.Text = $settings.LastFolder
$script:Loading = $false
Set-Status 'Pick a folder (or drag one in), then search for the show.'

[void]$form.ShowDialog()
