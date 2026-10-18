# Episode Renamer - Windows Forms GUI. Launch with "Episode Renamer.cmd".
# Keep this file ASCII-only (Windows PowerShell 5.1 reads BOM-less files as ANSI).

$ErrorActionPreference = 'Stop'
$fnBefore = @(Get-ChildItem function: | ForEach-Object { $_.Name })
. (Join-Path $PSScriptRoot 'EpisodeRenamer.Core.ps1')
# Every core function gets copied into the background runspace (see Start-Background).
$script:CoreFunctionNames = @(Get-ChildItem function: | ForEach-Object { $_.Name } | Where-Object { $fnBefore -notcontains $_ })

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
try {
    Add-Type -Name Dpi -Namespace Win32 -MemberDefinition '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();'
    [void][Win32.Dpi]::SetProcessDPIAware()
} catch { }
try {
    # Dark title bars (Windows 10 2004+ / Windows 11).
    Add-Type -Name Dwm -Namespace Win32 -MemberDefinition '[DllImport("dwmapi.dll")] public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);'
} catch { }
[Windows.Forms.Application]::EnableVisualStyles()

$settings = Get-Settings
$script:EpisodeCache = @{}
$script:SearchResults = @()
$script:SelectedShow = $null
$script:Loading = $true
$script:Jobs = New-Object System.Collections.ArrayList
$script:Sync = [hashtable]::Synchronized(@{ Status = '' })
$script:AfterFetch = $null
$script:YearHint = $null
$script:UpdateUrl = $null
$script:LibTabs = @{}
$script:Closing = $false

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
# Dropdowns are owner-drawn in dark mode: Windows ignores BackColor on DropDownList combo boxes.
$script:DrawCombo = {
    param($sender, $e)
    if ($e.Index -lt 0) { return }
    $p = $script:Pal
    $selected = ($e.State -band [Windows.Forms.DrawItemState]::Selected) -ne 0
    $brush = New-Object Drawing.SolidBrush $(if ($selected) { $p.Sel } else { $p.Input })
    $e.Graphics.FillRectangle($brush, $e.Bounds)
    $brush.Dispose()
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, [string]$sender.Items[$e.Index], $sender.Font, $e.Bounds, $p.Text,
        [Windows.Forms.TextFormatFlags]::VerticalCenter -bor [Windows.Forms.TextFormatFlags]::EndEllipsis)
}

function New-Combo([int]$Width, [string[]]$Items) {
    $c = New-Object Windows.Forms.ComboBox
    $c.Width = $Width; $c.DropDownStyle = 'DropDownList'; $c.Margin = New-Pad 3 4 3 3
    foreach ($i in $Items) { [void]$c.Items.Add($i) }
    $c.Add_DrawItem($script:DrawCombo)
    $c
}
function New-CheckBox([string]$Text) {
    $c = New-Object Windows.Forms.CheckBox
    $c.Text = $Text; $c.AutoSize = $true; $c.Margin = New-Pad 10 7 3 3
    $c
}
function New-Row {
    $p = New-Object Windows.Forms.FlowLayoutPanel
    $p.AutoSize = $true; $p.Dock = 'Fill'; $p.WrapContents = $true; $p.Margin = New-Pad 0 0 0 0
    $p
}
function New-Stack {
    $t = New-Object Windows.Forms.TableLayoutPanel
    $t.Dock = 'Fill'; $t.ColumnCount = 1
    $t
}
function Add-StackRow($Stack, $Control, [switch]$Fill) {
    $style = if ($Fill) { New-Object Windows.Forms.RowStyle('Percent', 100) } else { New-Object Windows.Forms.RowStyle('AutoSize') }
    [void]$Stack.RowStyles.Add($style)
    $Stack.Controls.Add($Control)
}
function New-Grid([object[]]$Columns) {
    $g = New-Object Windows.Forms.DataGridView
    $g.Dock = 'Fill'
    $g.AllowUserToAddRows = $false; $g.AllowUserToDeleteRows = $false; $g.AllowUserToResizeRows = $false
    $g.RowHeadersVisible = $false
    $g.SelectionMode = 'FullRowSelect'
    $g.AutoSizeColumnsMode = 'Fill'
    $g.BackgroundColor = [Drawing.SystemColors]::Window
    $g.BorderStyle = 'Fixed3D'
    $use = New-Object Windows.Forms.DataGridViewCheckBoxColumn
    $use.HeaderText = 'Use'; $use.FillWeight = 5
    [void]$g.Columns.Add($use)
    foreach ($c in $Columns) {
        $col = New-Object Windows.Forms.DataGridViewTextBoxColumn
        $col.HeaderText = $c[0]; $col.FillWeight = $c[1]; $col.ReadOnly = $true
        [void]$g.Columns.Add($col)
    }
    $g.Add_CurrentCellDirtyStateChanged({ if ($this.IsCurrentCellDirty) { $this.CommitEdit('CurrentCellChange') } })
    $g
}

# A simple tab strip (header buttons + swappable pages). Used instead of TabControl because Windows
# always paints a light frame around TabControl pages, which can't be themed for dark mode.
function New-TabHost {
    $t = New-Stack
    $t.Margin = New-Pad 0 6 0 0
    $hdr = New-Row
    $hdr.WrapContents = $false
    $body = New-Object Windows.Forms.Panel
    $body.Dock = 'Fill'
    $body.Padding = New-Pad 2 6 2 2
    Add-StackRow $t $hdr
    Add-StackRow $t $body -Fill
    $obj = [pscustomobject]@{ Control = $t; Header = $hdr; Body = $body; Pages = (New-Object System.Collections.ArrayList); SelectedTab = $null }
    $t.Tag = $obj
    $obj
}

function Add-TabPage($TabHost, [string]$Title) {
    $page = New-Object Windows.Forms.Panel
    $page.Dock = 'Fill'
    $page.Visible = $false
    $page.Text = $Title
    $btn = New-Object Windows.Forms.Button
    $btn.Text = $Title; $btn.AutoSize = $true; $btn.Name = 'tabbtn'
    $btn.FlatStyle = 'Flat'; $btn.FlatAppearance.BorderSize = 0
    $btn.Margin = New-Pad 0 0 2 0; $btn.Padding = New-Pad 10 3 10 3
    $btn.Tag = @{ Host = $TabHost; Page = $page }
    $btn.Add_Click({ Select-TabPage $this.Tag.Host $this.Tag.Page })
    $TabHost.Header.Controls.Add($btn)
    $TabHost.Body.Controls.Add($page)
    [void]$TabHost.Pages.Add($page)
    if (-not $TabHost.SelectedTab) { Select-TabPage $TabHost $page }
    $page
}

function Select-TabPage($TabHost, $Page) {
    foreach ($p in $TabHost.Pages) { $p.Visible = ($p -eq $Page) }
    $TabHost.SelectedTab = $Page
    Update-TabHeader $TabHost
}

function Update-TabHeader($TabHost) {
    $p = $script:Pal
    if (-not $p) { return }   # pages created before the theme is set up; Set-AppTheme styles them
    foreach ($b in $TabHost.Header.Controls) {
        $sel = $b.Tag.Page -eq $TabHost.SelectedTab
        $b.FlatStyle = 'Flat'
        $b.FlatAppearance.BorderSize = 0
        $b.FlatAppearance.MouseOverBackColor = $p.Surface
        $b.BackColor = if ($sel) { $p.Surface } else { $p.Back }
        $b.ForeColor = if ($sel) { $p.Accent } else { $p.Muted }
        $b.Font = if ($sel) { $script:BoldFont } else { $form.Font }
    }
}

function Set-StatusColor($Cell, [string]$Status) {
    $p = $script:Pal
    $Cell.Style.ForeColor = switch -Wildcard ($Status) {
        'Ready*'      { $p.Ok }
        'Renamed*'    { $p.Ok }
        'Rename folder' { $p.Ok }
        'Unchanged'   { $p.Dim }
        'Up to date*' { $p.Dim }
        ''            { $p.Dim }
        default       { $p.Bad }
    }
}

# ---------------------------------------------------------------- form + shared options

$form = New-Object Windows.Forms.Form
$form.Text = "Episode Renamer $script:AppVersion"
$form.Font = New-Object Drawing.Font('Segoe UI', 9)
$form.AutoScaleMode = 'Dpi'
$form.ClientSize = New-Object Drawing.Size(1180, 720)
$form.MinimumSize = New-Object Drawing.Size(900, 520)
$form.StartPosition = 'CenterScreen'
$form.AllowDrop = $true
$script:BoldFont = New-Object Drawing.Font($form.Font, [Drawing.FontStyle]::Bold)

$main = New-Stack
$main.Padding = New-Pad 6 6 6 6
$form.Controls.Add($main)

# Shared: where data comes from and how names are built (used by Episodes and TV Library).
$rowSource = New-Row
$cboSource = New-Combo 120 @('TVmaze', 'TheTVDB', 'Sonarr')
$cboOrder = New-Combo 100 @('Aired', 'DVD', 'Absolute')
$txtLang = New-TextBox 50
$btnSettings = New-Button 'Settings...'
$rowSource.Controls.AddRange(@((New-Label 'TV source:'), $cboSource, (New-Label 'Episode order:'), $cboOrder,
        (New-Label 'Language (TVDB):'), $txtLang, $btnSettings))

$rowMatch = New-Row
$cboMatch = New-Combo 130 @($MatchModes.Keys)
$cboNumbering = New-Combo 130 @($NumberingModes.Keys)
$cboTitles = New-Combo 140 @($TitleModes.Keys)
$chkExtras = New-CheckBox 'Rename matching extras (.nfo, -thumb.jpg, .srt)'
$rowMatch.Controls.AddRange(@((New-Label 'Match files by:'), $cboMatch, (New-Label 'Numbering:'), $cboNumbering,
        (New-Label 'Titles:'), $cboTitles, $chkExtras))

$rowScheme = New-Row
$txtScheme = New-TextBox 420
$btnResetScheme = New-Button 'Reset'
$lblTokens = New-Label 'Tokens: {show} {season:00} {episode:00} {title} {absolute:000} {year} {airdate}'
$lblTokens.ForeColor = [Drawing.Color]::DimGray
$lblTokens.Tag = 'muted'
$rowScheme.Controls.AddRange(@((New-Label 'Episode name scheme:'), $txtScheme, $btnResetScheme, $lblTokens))

$tabs = New-TabHost

# Shared status bar.
$rowStatus = New-Row
$btnUndo = New-Button 'Undo last rename'
$progress = New-Object Windows.Forms.ProgressBar
$progress.Style = 'Marquee'; $progress.Width = 110; $progress.Height = 16; $progress.Margin = New-Pad 10 9 3 3; $progress.Visible = $false
$lblStatus = New-Label ''
$lnkUpdate = New-Object Windows.Forms.LinkLabel
$lnkUpdate.AutoSize = $true; $lnkUpdate.Margin = New-Pad 16 8 3 0; $lnkUpdate.Visible = $false
$rowStatus.Controls.AddRange(@($btnUndo, $progress, $lblStatus, $lnkUpdate))

Add-StackRow $main $rowSource
Add-StackRow $main $rowMatch
Add-StackRow $main $rowScheme
Add-StackRow $main $tabs.Control -Fill
Add-StackRow $main $rowStatus

# ---------------------------------------------------------------- Episodes tab

$pageEp = Add-TabPage $tabs 'Episodes'
$stackEp = New-Stack
$pageEp.Controls.Add($stackEp)

$rowFolder = New-Row
$txtFolder = New-TextBox 560
$btnBrowse = New-Button 'Browse...'
$btnAddFiles = New-Button 'Add files...'
$chkRecurse = New-CheckBox 'Include subfolders'
$btnScan = New-Button 'Scan'
$rowFolder.Controls.AddRange(@((New-Label 'Folder:'), $txtFolder, $btnBrowse, $btnAddFiles, $chkRecurse, $btnScan))

$rowShow = New-Row
$txtSearch = New-TextBox 240
$btnSearch = New-Button 'Search'
$cboResults = New-Combo 430 @()
$txtShowName = New-TextBox 200
$rowShow.Controls.AddRange(@((New-Label 'Show:'), $txtSearch, $btnSearch, $cboResults, (New-Label 'Name in file:'), $txtShowName))

$grid = New-Grid @(@('Original name', 40), @('Detected', 9), @('New name', 46), @('Status', 14))

$rowEpButtons = New-Row
$btnPreview = New-Button 'Refresh preview'
$btnRename = New-Button 'Rename checked'
$btnRename.Font = $script:BoldFont
$btnAll = New-Button 'Check all'
$btnNone = New-Button 'Check none'
$btnRemove = New-Button 'Remove selected'
$chkOnlyChanges = New-CheckBox 'Only show files that change'
$rowEpButtons.Controls.AddRange(@($btnPreview, $btnRename, $btnAll, $btnNone, $btnRemove, $chkOnlyChanges))

Add-StackRow $stackEp $rowFolder
Add-StackRow $stackEp $rowShow
Add-StackRow $stackEp $grid -Fill
Add-StackRow $stackEp $rowEpButtons

# ---------------------------------------------------------------- library tabs (TV Library, Movies)

function New-LibraryTab([string]$Kind, [string]$Title, [string]$Hint) {
    $page = Add-TabPage $tabs $Title
    $stack = New-Stack
    $page.Controls.Add($stack)

    $rowF = New-Row
    $txt = New-TextBox 560
    $btnB = New-Button 'Browse...'; $btnB.Tag = $Kind
    $btnA = New-Button 'Analyze'; $btnA.Tag = $Kind; $btnA.Font = $script:BoldFont
    $rowF.Controls.AddRange(@((New-Label 'Folder:'), $txt, $btnB, $btnA))
    $lblHint = New-Label $Hint
    $lblHint.ForeColor = [Drawing.Color]::DimGray
    $lblHint.Tag = 'muted'
    $lblHint.Margin = New-Pad 6 2 3 4

    $g = New-Grid @(@('Current name', 34), @('New name', 34), @('Matched as', 17), @('Status', 17))
    $g.Tag = $Kind

    $rowB = New-Row
    $btnRen = New-Button 'Rename checked'; $btnRen.Tag = $Kind; $btnRen.Font = $script:BoldFont
    $btnMatch = New-Button 'Change match...'; $btnMatch.Tag = $Kind
    $btnAll = New-Button 'Check all'; $btnAll.Tag = $Kind
    $btnNone = New-Button 'Check none'; $btnNone.Tag = $Kind
    $chkDetails = New-CheckBox 'Show file details'; $chkDetails.Tag = $Kind; $chkDetails.Checked = $true
    $chkOnly = New-CheckBox 'Only show changes'; $chkOnly.Tag = $Kind; $chkOnly.Checked = $true
    $rowB.Controls.AddRange(@($btnRen, $btnMatch, $btnAll, $btnNone, $chkDetails, $chkOnly))
    $chkFolders = $null
    if ($Kind -eq 'Movie') {
        $chkFolders = New-CheckBox 'Put loose movies in their own folder'; $chkFolders.Tag = $Kind
        $rowB.Controls.Add($chkFolders)
    }

    Add-StackRow $stack $rowF
    Add-StackRow $stack $lblHint
    Add-StackRow $stack $g -Fill
    Add-StackRow $stack $rowB

    $btnB.Add_Click({
            $st = $script:LibTabs[$this.Tag]
            $d = New-Object Windows.Forms.FolderBrowserDialog
            $d.Description = 'Pick the folder to analyze'
            if ($st.Txt.Text -and (Test-Path -LiteralPath $st.Txt.Text)) { $d.SelectedPath = $st.Txt.Text }
            if ($d.ShowDialog($form) -eq 'OK') { $st.Txt.Text = $d.SelectedPath; Invoke-Safe { Start-Analyze $st } }
        })
    $btnA.Add_Click({ $st = $script:LibTabs[$this.Tag]; Invoke-Safe { Start-Analyze $st } })
    $btnRen.Add_Click({ $st = $script:LibTabs[$this.Tag]; Invoke-Safe { Invoke-LibraryRename $st } })
    $btnMatch.Add_Click({ $st = $script:LibTabs[$this.Tag]; Invoke-Safe { Show-ChangeMatch $st } })
    $btnAll.Add_Click({ foreach ($r in $script:LibTabs[$this.Tag].Grid.Rows) { if ($r.Tag.Parent -and $r.Tag.Plan.Ops.Count) { $r.Cells[0].Value = $true } } })
    $btnNone.Add_Click({ foreach ($r in $script:LibTabs[$this.Tag].Grid.Rows) { if ($r.Tag.Parent) { $r.Cells[0].Value = $false } } })
    $chkDetails.Add_CheckedChanged({
            $gr = $script:LibTabs[$this.Tag].Grid
            $gr.CurrentCell = $null
            foreach ($r in $gr.Rows) { if (-not $r.Tag.Parent) { $r.Visible = $this.Checked -and $r.Tag.Wanted } }
        })
    $chkOnly.Add_CheckedChanged({
            if ($script:Loading) { return }
            $settings.OnlyChanges = $this.Checked
            Show-LibraryPlans $script:LibTabs[$this.Tag]
        })
    $g.Add_CellDoubleClick({ if ($_.RowIndex -ge 0) { $st = $script:LibTabs[$this.Tag]; Invoke-Safe { Show-ChangeMatch $st } } })
    if ($chkFolders) {
        $chkFolders.Add_CheckedChanged({
                $st = $script:LibTabs[$this.Tag]
                if (-not $script:Loading -and @($st.Plans).Count) { Invoke-Safe { Start-Analyze $st } }
            })
    }

    [pscustomobject]@{ Kind = $Kind; Page = $page; Txt = $txt; Grid = $g; Plans = @(); Details = $chkDetails; OnlyChanges = $chkOnly; MovieFolders = $chkFolders }
}

$script:LibTabs['TV'] = New-LibraryTab 'TV' 'TV Library' 'Pick one show folder or a whole TV library. Show folders become "Show (Year)", season folders "Season 01", and episodes follow the name scheme above.'
$script:LibTabs['Movie'] = New-LibraryTab 'Movie' 'Movies' 'Pick a movies folder (or one movie''s folder). Movies become "Title (Year)\Title (Year).mkv". Add a free TMDB key in Settings for exact titles; otherwise the title and year come from the filename.'

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

function Confirm-Action([string]$Message) {
    [Windows.Forms.MessageBox]::Show($form, $Message, 'Episode Renamer', 'YesNo', 'Question') -eq 'Yes'
}

function Get-LookupContext {
    @{
        Source = [string]$cboSource.SelectedItem; Order = [string]$cboOrder.SelectedItem; Lang = $txtLang.Text.Trim()
        Match = $MatchModes[[string]$cboMatch.SelectedItem]; Numbering = $NumberingModes[[string]$cboNumbering.SelectedItem]
        TitleMode = $TitleModes[[string]$cboTitles.SelectedItem]; Scheme = $txtScheme.Text; Extras = $chkExtras.Checked
        MovieFolders = $script:LibTabs['Movie'].MovieFolders.Checked
        TvdbKey = $settings.TvdbApiKey; TvdbPin = $settings.TvdbPin; TmdbKey = $settings.TmdbKey
        SonarrUrl = $settings.SonarrUrl; SonarrKey = $settings.SonarrKey; RadarrUrl = $settings.RadarrUrl; RadarrKey = $settings.RadarrKey
        PlexUrl = $settings.PlexUrl; PlexToken = $settings.PlexToken; JellyfinUrl = $settings.JellyfinUrl; JellyfinKey = $settings.JellyfinKey
        ArrSync = [bool]$settings.ArrSync
    }
}

# The show folder for the Episodes tab: the scanned folder, or its parent when that's a "Season N" folder.
function Get-EpisodesShowLeaf {
    $dir = $txtFolder.Text.Trim().TrimEnd('\')
    if (-not $dir) { return '' }
    if ($null -ne (Get-FolderSeason $dir)) { $dir = Split-Path $dir -Parent }
    Split-Path $dir -Leaf
}

# After renaming/undo: tell Sonarr/Radarr about moved folders and rescan, refresh Plex/Jellyfin.
# Runs in the background; the outcome is added to the status bar (and shown if something failed).
function Start-MediaSync($Entries, [string]$Kind, $UndoResult) {
    $ctx = Get-LookupContext
    if (-not $ctx.ArrSync) { return }
    if (-not (($ctx.SonarrUrl -and $ctx.SonarrKey) -or ($ctx.RadarrUrl -and $ctx.RadarrKey) -or ($ctx.PlexUrl -and $ctx.PlexToken) -or ($ctx.JellyfinUrl -and $ctx.JellyfinKey))) { return }
    $script:StatusBeforeSync = $lblStatus.Text
    [void](Start-Background 'Updating Sonarr / Radarr / Plex / Jellyfin...' {
            param($Entries, $Kind, $UndoResult, $Ctx)
            $lines = if ($UndoResult) { @(Sync-AfterUndo $UndoResult $Ctx) } else { @(Sync-MediaApps @($Entries) $Ctx $Kind) }
            @{ Lines = @($lines) }
        } @{ Entries = @($Entries); Kind = $Kind; UndoResult = $UndoResult; Ctx = $ctx } {
            param($o)
            $lines = @($o.Lines | Where-Object { $_ })
            if ($lines.Count -eq 0) { Set-Status $script:StatusBeforeSync; return }
            $bad = @($lines | Where-Object { $_ -match "couldn't|rejected|failed|isn't connected" })
            Set-Status "$($script:StatusBeforeSync)   Media apps: $($lines.Count - $bad.Count) updated$(if ($bad.Count) { ", $($bad.Count) problem(s)" })."
            $lblStatus.Tag = $lines -join "`n"
            $tips.SetToolTip($lblStatus, ($lines -join "`n"))
            if ($bad.Count) { [void][Windows.Forms.MessageBox]::Show($form, ($lines -join "`n"), 'Episode Renamer - media apps', 'OK', 'Warning') }
        })
}

# ---------------------------------------------------------------- background work
# Network calls run in a separate runspace so the window keeps painting; a timer picks up the result
# and runs the completion block on the UI thread. Only one visible (non-quiet) job runs at a time.

$script:BgPrelude = (($script:CoreFunctionNames | ForEach-Object { "function $_ {`n$((Get-Item "function:$_").Definition)`n}" }) -join "`n") + "`nInitialize-Core`n"

$jobTimer = New-Object Windows.Forms.Timer
$jobTimer.Interval = 100

function Test-Busy { @($script:Jobs | Where-Object { -not $_.Quiet }).Count -gt 0 }

function Set-Busy([bool]$On) {
    foreach ($c in @($rowSource, $rowMatch, $rowScheme, $tabs.Control, $btnUndo)) { $c.Enabled = -not $On }
    $progress.Visible = $On
    $form.UseWaitCursor = $On
}

# $Work runs in the background runspace (only core functions exist there) and must return everything
# $OnDone needs; $OnDone gets that value on the UI thread.
function Start-Background([string]$Status, [scriptblock]$Work, [hashtable]$Params, [scriptblock]$OnDone, [switch]$Quiet) {
    if (-not $Quiet -and (Test-Busy)) { return $false }
    $ps = [powershell]::Create()
    [void]$ps.AddScript($script:BgPrelude, $false).Invoke()
    $ps.Commands.Clear()
    [void]$ps.AddScript($Work.ToString(), $false)
    foreach ($k in $Params.Keys) { [void]$ps.AddParameter($k, $Params[$k]) }
    [void]$script:Jobs.Add(@{ PS = $ps; Handle = $ps.BeginInvoke(); OnDone = $OnDone; Quiet = [bool]$Quiet })
    if (-not $Quiet) { $script:Sync.Status = ''; Set-Busy $true; Set-Status $Status }
    $jobTimer.Start()
    $true
}

$jobTimer.Add_Tick({
        # Results that arrive after the window closed have nowhere to go.
        if ($form.IsDisposed -or $script:Closing) { $jobTimer.Stop(); return }
        if ((Test-Busy) -and $script:Sync.Status -and $lblStatus.Text -ne $script:Sync.Status) { $lblStatus.Text = $script:Sync.Status }
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

# ---------------------------------------------------------------- Episodes: file list

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

# ---------------------------------------------------------------- Episodes: lookup

function Invoke-Search {
    $q = $txtSearch.Text.Trim()
    if (-not $q) { throw 'Type a show name to search for.' }
    $src = [string]$cboSource.SelectedItem
    $params = @{ Query = $q; Ctx = (Get-LookupContext); Token = $script:TvdbToken; YearHint = $script:YearHint; FolderLeaf = (Get-EpisodesShowLeaf)
        Parsed = @($grid.Rows | ForEach-Object { $_.Tag.Parsed } | Where-Object { $_.Kind -ne 'None' }) }
    [void](Start-Background "Searching $src for '$q'..." {
            param($Query, $Ctx, $Token, $YearHint, $Parsed, $FolderLeaf)
            $script:TvdbToken = $Token
            $r = @(Find-Shows $Query $Ctx $FolderLeaf)
            # Several shows with exactly this name and no year to go on (anime vs live-action One Piece):
            # pick the one whose episode list contains the most of the files, like the TV Library tab does.
            $pick = -1
            $episodes = $null
            $sameName = @($r | Where-Object { $_.Name -eq $Query } | Select-Object -First 4)
            if (-not ($YearHint -and @($r | Where-Object { "$($_.Year)" -eq "$YearHint" }).Count) -and $sameName.Count -gt 1 -and $Parsed.Count) {
                $best = -1
                foreach ($cand in $sameName) {
                    $eps = Get-ShowEpisodes $cand $Ctx
                    $score = @($Parsed | Where-Object { @(Find-Episodes $_ $eps $Ctx.Match).Count -gt 0 }).Count
                    if ($score -gt $best) { $best = $score; $pick = [array]::IndexOf($r, $cand); $episodes = $eps }
                }
            }
            @{ Results = $r; Query = $Query; Token = $script:TvdbToken; Pick = $pick; Episodes = $episodes }
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
    if (-not $picked -and $o.Pick -ge 0) {
        # Chosen by which show's episode list matched the files; its episodes are already downloaded.
        $idx = $o.Pick
        $picked = $true
        $show = $script:SearchResults[$idx]
        $script:EpisodeCache["$($show.Source)|$($show.Id)|$($cboOrder.SelectedItem)|$($txtLang.Text.Trim())"] = @($o.Episodes)
    }
    # Without a confident pick, open the list once the episodes have loaded so the user checks it.
    $script:PromptPick = (-not $picked -and $script:SearchResults.Count -gt 1)
    $cboResults.SelectedIndex = $idx
}

function Get-CacheKey {
    if (-not $script:SelectedShow) { return $null }
    "$($script:SelectedShow.Source)|$($script:SelectedShow.Id)|$($cboOrder.SelectedItem)|$($txtLang.Text.Trim())"
}

function Request-Episodes {
    $show = $script:SelectedShow
    $params = @{ Show = $show; Ctx = (Get-LookupContext); Token = $script:TvdbToken; CacheKey = (Get-CacheKey) }
    [void](Start-Background "Downloading episode list for $($show.Name)..." {
            param($Show, $Ctx, $Token, $CacheKey)
            $script:TvdbToken = $Token
            # Same lookup as the TV Library tab: TVmaze, TheTVDB or Sonarr, depending on where the show came from.
            $e = @(Get-ShowEpisodes $Show $Ctx)
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

# ---------------------------------------------------------------- Episodes: preview + rename

function Set-RowState($Row, [string]$NewName, [string]$Status) {
    $Row.Tag.Status = $Status
    $Row.Cells[3].Value = $NewName
    $Row.Cells[4].Value = $Status
    Set-StatusColor $Row.Cells[4] $Status
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
    $src = $script:SelectedShow.Source
    $grid.SuspendLayout()
    foreach ($row in $grid.Rows) {
        $item = $row.Tag
        $item.Target = $null
        $found = @(Find-Episodes $item.Parsed $eps $mode $item.FolderSeason $script:SelectedShow.Name)
        if ($found.Count -eq 0) {
            $why = if ($item.Parsed.Kind -eq 'None') { "No episode number, and no $src episode with that title" } else { "Not found on $src" }
            Set-RowState $row '' $why; continue
        }
        $found = @(Resolve-EpisodeInfo $found $item.Parsed $item.FolderSeason $numbering $titleMode)
        if (@($found | Where-Object { $_.NeedsNumber }).Count) { Set-RowState $row '' (Get-NeedsNumberText $found $src); continue }
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

    Update-EpisodeRowVisibility
    $grid.ResumeLayout()
    Update-ReadyCount
}

# "Only show files that change": hide files that are already correct or couldn't be matched.
function Test-RowWanted([string]$Status) {
    $Status -in @('Ready', 'Duplicate new name', 'Name already taken', 'Search for a show', '') -or $Status -like 'Renamed*' -or $Status -like 'Error*'
}

function Update-EpisodeRowVisibility {
    $only = $chkOnlyChanges.Checked
    $grid.CurrentCell = $null
    $same = 0; $unmatched = 0
    foreach ($row in $grid.Rows) {
        $s = "$($row.Tag.Status)"
        $show = (-not $only) -or (Test-RowWanted $s)
        if (-not (Test-RowWanted $s)) { if ($s -eq 'Unchanged') { $same++ } else { $unmatched++ } }
        if ($row.Visible -ne $show) { $row.Visible = $show }
    }
    $script:HiddenNote = ''
    if ($same + $unmatched -gt 0) {
        $what = (@($(if ($same) { "$same already correct" }), $(if ($unmatched) { "$unmatched not matched" })) | Where-Object { $_ }) -join ', '
        $script:HiddenNote = if ($only) { "   Hidden: $what (untick ""Only show files that change"" to see them)." } else { "   ($what.)" }
    }
}

# Cheap enough to run on every checkbox click (the full preview isn't).
function Update-ReadyCount {
    $ready = 0
    foreach ($row in $grid.Rows) { if ($row.Cells[0].Value -and $row.Tag.Status -eq 'Ready') { $ready++ } }
    if (-not (Test-Busy)) { Set-Status ("$ready file(s) ready to rename." + $script:HiddenNote) }
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
    if (-not (Confirm-Action $msg)) { return }

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
    if ($ok -gt 0) { Start-MediaSync @([pscustomobject]@{ OldLeaf = (Get-EpisodesShowLeaf); NewLeaf = '' }) 'TV' $null }
}

# ---------------------------------------------------------------- library tabs: analyze, show, rename, re-match

function Start-Analyze($St) {
    $root = $St.Txt.Text.Trim().TrimEnd('\')
    if (-not $root -or -not (Test-Path -LiteralPath $root -PathType Container)) { throw 'Pick a folder that exists first.' }
    $St.Txt.Text = $root
    $params = @{ Root = $root; Ctx = (Get-LookupContext); Kind = $St.Kind; Sync = $script:Sync; Token = $script:TvdbToken }
    [void](Start-Background "Scanning $root..." {
            param($Root, $Ctx, $Kind, $Sync, $Token)
            $script:TvdbToken = $Token
            $plans = New-Object System.Collections.Generic.List[object]
            if ($Kind -eq 'TV') {
                $dirs = @(Get-TvShowFolders $Root)
                for ($i = 0; $i -lt $dirs.Count; $i++) {
                    $Sync.Status = "Looking up $(Split-Path $dirs[$i] -Leaf) ($($i + 1) of $($dirs.Count))..."
                    $plans.Add((Get-ShowPlan $dirs[$i] $Ctx $null))
                }
            } else {
                $items = @(Get-MovieItems $Root)
                for ($i = 0; $i -lt $items.Count; $i++) {
                    $Sync.Status = "Checking $(Split-Path $items[$i].Path -Leaf) ($($i + 1) of $($items.Count))..."
                    $plans.Add((Get-MoviePlan $items[$i] $Ctx $null))
                }
            }
            @{ Plans = $plans.ToArray(); Kind = $Kind; Token = $script:TvdbToken }
        } $params {
            param($o)
            $script:TvdbToken = $o.Token
            $st = $script:LibTabs[$o.Kind]
            $st.Plans = @($o.Plans)
            Show-LibraryPlans $st
        })
}

function Get-MatchText($Plan) {
    $m = $Plan.Match
    if (-not $m) { return '' }
    $year = if ($m.Year) { " ($($m.Year))" } else { '' }
    $src = if ($m.Source -eq 'Filename') { 'from filename' } else { $m.Source }
    "$($m.Name)$year  [$src]"
}

function Show-LibraryPlans($St) {
    $g = $St.Grid
    $only = $St.OnlyChanges.Checked
    $g.SuspendLayout()
    $g.Rows.Clear()
    $plans = @($St.Plans)
    $hiddenShows = 0; $hiddenFiles = 0
    for ($i = 0; $i -lt $plans.Count; $i++) {
        $p = $plans[$i]
        $canRun = @($p.Ops).Count -gt 0 -and $p.Status -notlike 'Error*'
        # Hide what needs nothing; keep shows that need attention (not found, errors) visible.
        if ($only -and -not $canRun -and $p.Status -like 'Up to date*') { $hiddenShows++; continue }
        $idx = $g.Rows.Add($canRun, $p.Label, $p.NewName, (Get-MatchText $p), $p.Status)
        $row = $g.Rows[$idx]
        $row.Tag = @{ Plan = $p; Index = $i; Parent = $true; Wanted = $true }
        $row.DefaultCellStyle.Font = $script:BoldFont
        $row.Cells[1].ToolTipText = $p.Dir
        Set-StatusColor $row.Cells[4] $p.Status
        foreach ($r in @($p.Rows)) {
            $wanted = (-not $only) -or $r.Status -in @('Ready', 'Rename folder')
            if (-not $wanted) { $hiddenFiles++ }
            $idx = $g.Rows.Add($null, ('      ' + $r.Current), ('      ' + $r.New), '', $r.Status)
            $child = $g.Rows[$idx]
            $child.Cells[0] = New-Object Windows.Forms.DataGridViewTextBoxCell
            $child.Cells[0].ReadOnly = $true
            $child.Tag = @{ Plan = $p; Index = $i; Parent = $false; Wanted = $wanted }
            $child.DefaultCellStyle.ForeColor = $script:Pal.Child
            Set-StatusColor $child.Cells[4] $r.Status
            $child.Visible = $St.Details.Checked -and $wanted
        }
    }
    $g.ResumeLayout()
    $what = if ($St.Kind -eq 'TV') { 'show(s)' } else { 'movie(s)' }
    $ready = @($plans | Where-Object { @($_.Ops).Count -gt 0 -and $_.Status -notlike 'Error*' }).Count
    $note = ''
    if ($only -and ($hiddenShows + $hiddenFiles)) {
        $parts = @($(if ($hiddenShows) { "$hiddenShows already up to date" }), $(if ($hiddenFiles) { "$hiddenFiles file(s) that won't change" })) | Where-Object { $_ }
        $note = "   Hidden: $($parts -join ', ') (untick ""Only show changes"" to see them)."
    }
    Set-Status "$($plans.Count) $what found, $ready with changes to make.$note"
}

function Invoke-LibraryRename($St) {
    $rows = @($St.Grid.Rows | Where-Object { $_.Tag.Parent -and $_.Cells[0].Value -and @($_.Tag.Plan.Ops).Count -gt 0 })
    if ($rows.Count -eq 0) { throw 'Nothing is checked that has changes to make.' }
    $opCount = ($rows | ForEach-Object { @($_.Tag.Plan.Ops | Where-Object { $_.Op -ne 'RmDirIfEmpty' }).Count } | Measure-Object -Sum).Sum
    $what = if ($St.Kind -eq 'TV') { 'show(s)' } else { 'movie(s)' }
    if (-not (Confirm-Action "Apply $opCount rename(s) across $($rows.Count) $($what)?`n`nYou can put everything back with ""Undo last rename"".")) { return }
    $results = Invoke-LibraryPlans @($rows | ForEach-Object { $_.Tag.Plan })
    $ok = 0
    foreach ($r in $results) {
        $row = $rows | Where-Object { $_.Tag.Plan -eq $r.Plan } | Select-Object -First 1
        $row.Cells[0].Value = $false
        if ($r.Error) {
            $row.Cells[4].Value = "Stopped after $($r.Done) of $(@($r.Plan.Ops).Count): $($r.Error)"
        } else {
            $ok++
            $row.Cells[4].Value = 'Renamed'
        }
        Set-StatusColor $row.Cells[4] $row.Cells[4].Value
    }
    Set-Status "Done: $ok of $($rows.Count) $what renamed. Click Analyze to see the result."
    if ($ok -gt 0) { Start-MediaSync @(Get-SyncEntries $results) $St.Kind $null }
}

function Show-ChangeMatch($St) {
    $row = $St.Grid.CurrentRow
    if (-not $row -or -not $row.Tag) { throw 'Select a show or movie in the list first.' }
    $plan = $row.Tag.Plan
    $isTv = $St.Kind -eq 'TV'
    $script:DlgResults = @($plan.Results)

    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = "Change match - $($plan.Label)"; $dlg.Font = $form.Font; $dlg.AutoScaleMode = 'Dpi'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'; $dlg.AutoSize = $true; $dlg.AutoSizeMode = 'GrowAndShrink'; $dlg.Padding = New-Pad 10 10 10 10
    $stack = New-Stack
    $stack.AutoSize = $true
    $rowQ = New-Row
    $script:DlgQuery = New-TextBox 300; $script:DlgQuery.Text = $plan.Query
    $script:DlgYear = New-TextBox 60; $script:DlgYear.Text = "$($plan.Year)"
    $btnFind = New-Button 'Search'
    $rowQ.Controls.AddRange(@((New-Label 'Title:'), $script:DlgQuery, (New-Label 'Year:'), $script:DlgYear, $btnFind))
    $script:DlgList = New-Object Windows.Forms.ListBox
    $script:DlgList.Width = 620; $script:DlgList.Height = 240; $script:DlgList.Margin = New-Pad 6 6 6 6
    foreach ($r in $script:DlgResults) { [void]$script:DlgList.Items.Add($r.Display) }
    if ($script:DlgList.Items.Count) { $script:DlgList.SelectedIndex = [Math]::Max(0, [array]::IndexOf([object[]]$script:DlgResults, $plan.Match)) }
    $rowBtn = New-Row
    $ok = New-Button 'Use selected'; $ok.DialogResult = 'OK'
    $typed = New-Button 'Use title and year as typed'; $typed.DialogResult = 'Yes'
    $cancel = New-Button 'Cancel'; $cancel.DialogResult = 'Cancel'
    $rowBtn.Controls.Add($ok)
    if (-not $isTv) { $rowBtn.Controls.Add($typed) }
    $rowBtn.Controls.Add($cancel)
    Add-StackRow $stack $rowQ
    Add-StackRow $stack $script:DlgList
    Add-StackRow $stack $rowBtn
    $dlg.Controls.Add($stack)
    $dlg.AcceptButton = $btnFind; $dlg.CancelButton = $cancel
    Set-WindowTheme $dlg
    $script:DlgKind = $St.Kind
    $btnFind.Add_Click({
            Invoke-Safe {
                $ctx = Get-LookupContext
                $q = $script:DlgQuery.Text.Trim()
                $y = if ($script:DlgYear.Text.Trim() -match '^\d{4}$') { [int]$script:DlgYear.Text.Trim() } else { $null }
                $form.UseWaitCursor = $true
                try {
                    if ($script:DlgKind -eq 'TV') { $res = @(Find-Shows $q $ctx) }
                    elseif ($ctx.RadarrUrl -and $ctx.RadarrKey) { $res = @(Search-Radarr $q $y $ctx) }
                    elseif ($settings.TmdbKey) { $res = @(Search-Tmdb $q $y $settings.TmdbKey) }
                    else { throw 'Searching for movies needs Radarr or a TMDB key (Settings). Without either, type the title and year and click "Use title and year as typed".' }
                } finally { $form.UseWaitCursor = $false }
                $script:DlgResults = $res
                $script:DlgList.Items.Clear()
                foreach ($r in $res) { [void]$script:DlgList.Items.Add($r.Display) }
                if ($res.Count) { $script:DlgList.SelectedIndex = 0 } else { throw "Nothing found for '$q'." }
            }
        })
    $script:DlgList.Add_DoubleClick({ if ($script:DlgList.SelectedIndex -ge 0) { $this.FindForm().DialogResult = 'OK' } })

    $answer = $dlg.ShowDialog($form)
    $forced = $null
    if ($answer -eq 'OK' -and $script:DlgList.SelectedIndex -ge 0) { $forced = $script:DlgResults[$script:DlgList.SelectedIndex] }
    elseif ($answer -eq 'Yes' -and $script:DlgQuery.Text.Trim()) {
        $y = if ($script:DlgYear.Text.Trim() -match '^\d{4}$') { [int]$script:DlgYear.Text.Trim() } else { $null }
        $forced = [pscustomobject]@{ Source = 'Filename'; Id = $null; Name = $script:DlgQuery.Text.Trim(); Year = $y; Display = $script:DlgQuery.Text.Trim() }
    }
    $results = $script:DlgResults
    $dlg.Dispose()
    if (-not $forced) { return }

    $params = @{ Kind = $St.Kind; Plan = $plan; Ctx = (Get-LookupContext); Forced = $forced; Token = $script:TvdbToken; Index = $row.Tag.Index; Results = $results }
    [void](Start-Background "Re-checking $($plan.Label) as $($forced.Name)..." {
            param($Kind, $Plan, $Ctx, $Forced, $Token, $Index, $Results)
            $script:TvdbToken = $Token
            $p = if ($Kind -eq 'TV') { Get-ShowPlan $Plan.Dir $Ctx $Forced } else { Get-MoviePlan $Plan.Item $Ctx $Forced }
            $p.Results = @($Results)
            @{ Plan = $p; Index = $Index; Kind = $Kind; Token = $script:TvdbToken }
        } $params {
            param($o)
            $script:TvdbToken = $o.Token
            $st = $script:LibTabs[$o.Kind]
            $list = @($st.Plans)
            $list[$o.Index] = $o.Plan
            $st.Plans = $list
            Show-LibraryPlans $st
        })
}

# ---------------------------------------------------------------- undo, settings, updates

function Invoke-Undo {
    if (-not (Confirm-Action 'Undo the most recent batch of renames?')) { return }
    $r = Undo-LastRename
    $msg = "Restored $($r.Restored) file(s) and folder(s)."
    if ($r.Errors.Count) { $msg += "`n`nProblems:`n" + (($r.Errors | Select-Object -First 10) -join "`n") }
    [void][Windows.Forms.MessageBox]::Show($form, $msg, 'Episode Renamer', 'OK', 'Information')
    if ($tabs.SelectedTab -eq $pageEp) {
        if ($txtFolder.Text.Trim() -and (Test-Path -LiteralPath $txtFolder.Text.Trim())) { Invoke-Scan }
        Set-Status $msg.Split("`n")[0]
        Start-MediaSync @() 'TV' $r
    } else {
        # Re-analyzing would race the media-app update for the busy slot; show the result and let the user re-analyze.
        foreach ($st in $script:LibTabs.Values) { if ($st.Page -eq $tabs.SelectedTab) { $st.Plans = @(); Show-LibraryPlans $st } }
        Set-Status ($msg.Split("`n")[0] + ' Click Analyze to see the folder as it is now.')
        Start-MediaSync @() 'TV' $r
    }
}

function New-LinkLabel([string]$Text, [string]$Url) {
    $l = New-Object Windows.Forms.LinkLabel
    $l.Text = $Text; $l.AutoSize = $true; $l.Margin = New-Pad 6 2 3 8; $l.Tag = $Url
    $l.Add_LinkClicked({ Start-Process $this.Tag })
    $l
}

# One "label / text box" row in a settings grid; returns the text box.
function Add-SettingRow($Table, [string]$Label, [string]$Value, [switch]$Secret) {
    $tb = New-TextBox 330
    $tb.Text = "$Value"
    if ($Secret) { $tb.UseSystemPasswordChar = $true }
    $Table.Controls.Add((New-Label $Label))
    $Table.Controls.Add($tb)
    $tb
}

function New-SettingsPage($Tabs, [string]$Title) {
    $page = Add-TabPage $Tabs $Title
    $page.Padding = New-Pad 8 8 8 8
    $t = New-Object Windows.Forms.TableLayoutPanel
    $t.AutoSize = $true; $t.ColumnCount = 3; $t.Dock = 'Fill'
    $page.Controls.Add($t)
    $t
}

function Add-SpanRow($Table, $Control) { $Table.Controls.Add($Control); $Table.SetColumnSpan($Control, 3) }

function Show-SettingsDialog {
    $dlg = New-Object Windows.Forms.Form
    $dlg.Text = 'Settings'; $dlg.Font = $form.Font; $dlg.AutoScaleMode = 'Dpi'
    $dlg.FormBorderStyle = 'FixedDialog'; $dlg.MaximizeBox = $false; $dlg.MinimizeBox = $false
    $dlg.StartPosition = 'CenterParent'; $dlg.ClientSize = New-Object Drawing.Size(640, 470); $dlg.Padding = New-Pad 8 8 8 8
    $outer = New-Stack
    $dlg.Controls.Add($outer)
    $st = New-TabHost

    # Lookups
    $t1 = New-SettingsPage $st 'Lookups'
    Add-SpanRow $t1 (New-Label 'All keys are optional. TVmaze (TV) and filename-based movie names work without any.')
    $txtTvdb = Add-SettingRow $t1 'TheTVDB API key:' $settings.TvdbApiKey -Secret; $t1.Controls.Add((New-Label ''))
    $txtPin = Add-SettingRow $t1 'TheTVDB subscriber PIN:' $settings.TvdbPin -Secret; $t1.Controls.Add((New-Label ''))
    Add-SpanRow $t1 (New-LinkLabel 'Get a TheTVDB key: https://thetvdb.com/api-information' 'https://thetvdb.com/api-information')
    $txtTmdb = Add-SettingRow $t1 'TMDB API key (movies):' $settings.TmdbKey -Secret; $t1.Controls.Add((New-Label ''))
    Add-SpanRow $t1 (New-LinkLabel 'Get a free TMDB key: https://www.themoviedb.org/settings/api' 'https://www.themoviedb.org/settings/api')
    $credit = New-Label 'TV information from TVmaze (tvmaze.com) and TheTVDB (thetvdb.com). Movie information from TMDB (themoviedb.org). This app is not endorsed or certified by TheTVDB or TMDB.'
    $credit.MaximumSize = New-Object Drawing.Size(580, 0); $credit.Tag = 'muted'; $credit.Margin = New-Pad 6 14 3 0
    Add-SpanRow $t1 $credit

    # Media apps
    $t2 = New-SettingsPage $st 'Media apps'
    $intro = New-Label 'Optional. When connected, the app tells these programs about renamed folders and rescans, so Sonarr/Radarr don''t show episodes or movies as missing. Choose "Sonarr" as the TV source to name episodes exactly the way Sonarr numbers them.'
    $intro.MaximumSize = New-Object Drawing.Size(580, 0)
    Add-SpanRow $t2 $intro
    $script:SetBoxes = @{}
    foreach ($app in @(
            @{ Name = 'Sonarr'; Url = 'SonarrUrl'; Key = 'SonarrKey'; Hint = 'http://192.168.1.10:8989'; KeyLabel = 'API key' },
            @{ Name = 'Radarr'; Url = 'RadarrUrl'; Key = 'RadarrKey'; Hint = 'http://192.168.1.10:7878'; KeyLabel = 'API key' },
            @{ Name = 'Plex'; Url = 'PlexUrl'; Key = 'PlexToken'; Hint = 'http://192.168.1.10:32400'; KeyLabel = 'token' },
            @{ Name = 'Jellyfin'; Url = 'JellyfinUrl'; Key = 'JellyfinKey'; Hint = 'http://192.168.1.10:8096'; KeyLabel = 'API key' })) {
        $u = Add-SettingRow $t2 "$($app.Name) address:" $settings[$app.Url]
        $tips.SetToolTip($u, "For example $($app.Hint)")
        $btnTest = New-Button 'Test'; $btnTest.Tag = $app.Name
        $t2.Controls.Add($btnTest)
        $k = Add-SettingRow $t2 "$($app.Name) $($app.KeyLabel):" $settings[$app.Key] -Secret; $t2.Controls.Add((New-Label ''))
        $script:SetBoxes[$app.Url] = $u; $script:SetBoxes[$app.Key] = $k
        $btnTest.Add_Click({
                $name = $this.Tag
                $ctx = Get-LookupContext
                foreach ($key in @($script:SetBoxes.Keys)) { $ctx[$key] = $script:SetBoxes[$key].Text.Trim() }
                $dlgForm = $this.FindForm()
                $dlgForm.UseWaitCursor = $true
                try { $msg = Test-MediaApp $name $ctx; $icon = 'Information' }
                catch { $msg = "$name : $($_.Exception.Message)"; $icon = 'Warning' }
                finally { $dlgForm.UseWaitCursor = $false }
                [void][Windows.Forms.MessageBox]::Show($dlgForm, $msg, 'Episode Renamer', 'OK', $icon)
            })
    }
    $chkSync = New-CheckBox 'After renaming, update Sonarr/Radarr folders and rescan, and refresh Plex/Jellyfin'
    $chkSync.Checked = [bool]$settings.ArrSync
    Add-SpanRow $t2 $chkSync
    $where = New-Label 'API keys: Sonarr/Radarr Settings > General. Plex token: support.plex.tv "Finding an authentication token". Jellyfin: Dashboard > API Keys.'
    $where.MaximumSize = New-Object Drawing.Size(580, 0); $where.Tag = 'muted'; $where.Margin = New-Pad 6 10 3 0
    Add-SpanRow $t2 $where

    # Appearance
    $t3 = New-SettingsPage $st 'Appearance'
    $cboTheme = New-Combo 160 @('System', 'Light', 'Dark')
    $cboTheme.SelectedItem = if (@('System', 'Light', 'Dark') -contains $settings.Theme) { $settings.Theme } else { 'System' }
    $t3.Controls.Add((New-Label 'Theme:')); $t3.Controls.Add($cboTheme)
    $tn = New-Label '"System" follows the Windows light/dark setting.'; $tn.Tag = 'muted'
    $t3.Controls.Add($tn)

    $btns = New-Row
    $btns.FlowDirection = 'RightToLeft'
    $ok = New-Button 'Save'; $ok.DialogResult = 'OK'
    $cancel = New-Button 'Cancel'; $cancel.DialogResult = 'Cancel'
    $btns.Controls.AddRange(@($cancel, $ok))
    Add-StackRow $outer $st.Control -Fill
    Add-StackRow $outer $btns
    $dlg.AcceptButton = $ok; $dlg.CancelButton = $cancel
    Set-WindowTheme $dlg

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $settings.TvdbApiKey = $txtTvdb.Text.Trim()
        $settings.TvdbPin = $txtPin.Text.Trim()
        $settings.TmdbKey = $txtTmdb.Text.Trim()
        foreach ($key in @($script:SetBoxes.Keys)) { $settings[$key] = $script:SetBoxes[$key].Text.Trim() }
        $settings.ArrSync = $chkSync.Checked
        $themeChanged = $settings.Theme -ne [string]$cboTheme.SelectedItem
        $settings.Theme = [string]$cboTheme.SelectedItem
        $script:TvdbToken = $null
        Save-Settings $settings
        if ($themeChanged) { Set-AppTheme }
    }
    $dlg.Dispose()
}

# ---------------------------------------------------------------- theme (light / dark)

function Test-SystemDark {
    try { (Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Themes\Personalize' -Name AppsUseLightTheme -ErrorAction Stop).AppsUseLightTheme -eq 0 } catch { $false }
}

function Get-Palette([bool]$Dark) {
    $c = { param($r, $g, $b) [Drawing.Color]::FromArgb($r, $g, $b) }
    if ($Dark) {
        @{ Dark = $true; Back = (& $c 30 32 38); Surface = (& $c 40 43 51); Input = (& $c 24 26 31); Text = (& $c 230 232 238)
            Muted = (& $c 150 157 172); Border = (& $c 62 67 79); Accent = (& $c 107 155 255); Sel = (& $c 45 74 140)
            Ok = (& $c 74 222 128); Bad = (& $c 248 113 113); Dim = (& $c 138 145 160); Child = (& $c 170 177 190) }
    } else {
        @{ Dark = $false; Back = [Drawing.SystemColors]::Control; Surface = [Drawing.SystemColors]::ControlLight; Input = [Drawing.SystemColors]::Window
            Text = [Drawing.SystemColors]::ControlText; Muted = [Drawing.Color]::DimGray; Border = [Drawing.SystemColors]::ControlDark
            Accent = [Drawing.Color]::FromArgb(0, 102, 204); Sel = [Drawing.SystemColors]::Highlight
            Ok = [Drawing.Color]::DarkGreen; Bad = [Drawing.Color]::Firebrick; Dim = [Drawing.Color]::Gray; Child = [Drawing.Color]::DimGray }
    }
}
$script:Pal = Get-Palette $false

function Set-TitleBarTheme($Window) {
    try {
        $v = if ($script:Pal.Dark) { 1 } else { 0 }
        [void][Win32.Dwm]::DwmSetWindowAttribute($Window.Handle, 20, [ref]$v, 4)
    } catch { }
}

function Set-GridTheme($G) {
    $p = $script:Pal
    $G.EnableHeadersVisualStyles = -not $p.Dark
    $G.BackgroundColor = $p.Input
    $G.GridColor = $p.Border
    $G.DefaultCellStyle.BackColor = $p.Input
    $G.DefaultCellStyle.ForeColor = $p.Text
    $G.DefaultCellStyle.SelectionBackColor = $p.Sel
    $G.DefaultCellStyle.SelectionForeColor = if ($p.Dark) { $p.Text } else { [Drawing.SystemColors]::HighlightText }
    $G.ColumnHeadersDefaultCellStyle.BackColor = $p.Surface
    $G.ColumnHeadersDefaultCellStyle.ForeColor = $p.Muted
    $G.ColumnHeadersDefaultCellStyle.SelectionBackColor = $p.Surface
    $G.BorderStyle = if ($p.Dark) { 'FixedSingle' } else { 'Fixed3D' }
    foreach ($row in $G.Rows) {
        if ($row.Tag -is [hashtable] -and $row.Tag.ContainsKey('Parent') -and -not $row.Tag.Parent) { $row.DefaultCellStyle.ForeColor = $p.Child }
        $last = $row.Cells[$row.Cells.Count - 1]
        Set-StatusColor $last "$($last.Value)"
    }
}

function Set-ControlTheme($C) {
    $p = $script:Pal
    if ($C -is [Windows.Forms.DataGridView]) { Set-GridTheme $C; return }
    if ($C -is [Windows.Forms.TextBox] -or $C -is [Windows.Forms.ListBox]) {
        $C.BackColor = $p.Input; $C.ForeColor = $p.Text
        if ($C -is [Windows.Forms.TextBox]) { $C.BorderStyle = if ($p.Dark) { 'FixedSingle' } else { 'Fixed3D' } }
    } elseif ($C -is [Windows.Forms.ComboBox]) {
        $C.FlatStyle = if ($p.Dark) { 'Flat' } else { 'Standard' }
        $C.DrawMode = if ($p.Dark) { 'OwnerDrawFixed' } else { 'Normal' }
        $C.BackColor = $p.Input; $C.ForeColor = $p.Text
    } elseif ($C -is [Windows.Forms.Button] -and $C.Name -eq 'tabbtn') {
        return   # styled by Update-TabHeader
    } elseif ($C -is [Windows.Forms.Button]) {
        if ($p.Dark) {
            $C.FlatStyle = 'Flat'; $C.BackColor = $p.Surface; $C.ForeColor = $p.Text; $C.FlatAppearance.BorderColor = $p.Border
        } else {
            $C.FlatStyle = 'Standard'; $C.BackColor = [Drawing.SystemColors]::Control; $C.ForeColor = $p.Text; $C.UseVisualStyleBackColor = $true
        }
    } elseif ($C -is [Windows.Forms.LinkLabel]) {
        $C.LinkColor = $p.Accent; $C.ActiveLinkColor = $p.Accent; $C.BackColor = $p.Back
    } elseif ($C -is [Windows.Forms.TabControl]) {
        # Flat button tabs have no light 3D frame around the page area.
        $C.DrawMode = if ($p.Dark) { 'OwnerDrawFixed' } else { 'Normal' }
        $C.Appearance = if ($p.Dark) { 'FlatButtons' } else { 'Normal' }
        $C.Invalidate()
    } elseif ($C -is [Windows.Forms.ProgressBar]) {
    } else {
        $C.BackColor = $p.Back
        $C.ForeColor = if ($C -is [Windows.Forms.Label] -and $C.Tag -eq 'muted') { $p.Muted } else { $p.Text }
    }
    foreach ($child in $C.Controls) { Set-ControlTheme $child }
    if ($C.Tag -and $C.Tag.PSObject.Properties['Header']) { Update-TabHeader $C.Tag }
}

# Theme a whole window (main form or a dialog), including its title bar.
function Set-WindowTheme($Window) {
    $Window.BackColor = $script:Pal.Back
    $Window.ForeColor = $script:Pal.Text
    foreach ($child in $Window.Controls) { Set-ControlTheme $child }
    if ($Window.IsHandleCreated) { Set-TitleBarTheme $Window } else { $Window.Add_HandleCreated({ Set-TitleBarTheme $this }) }
}

function Set-AppTheme {
    $dark = switch ($settings.Theme) { 'Dark' { $true } 'Light' { $false } default { Test-SystemDark } }
    $script:Pal = Get-Palette $dark
    Set-WindowTheme $form
    $form.Refresh()
}

# Dark tab headers (owner-drawn only in dark mode; light mode keeps the normal Windows look).
$script:DrawTab = {
    param($sender, $e)
    $p = $script:Pal
    $selected = $sender.SelectedIndex -eq $e.Index
    $back = if ($selected) { $p.Back } else { $p.Surface }
    $brush = New-Object Drawing.SolidBrush $back
    $e.Graphics.FillRectangle($brush, $e.Bounds)
    $brush.Dispose()
    $fore = if ($selected) { $p.Text } else { $p.Muted }
    [Windows.Forms.TextRenderer]::DrawText($e.Graphics, $sender.TabPages[$e.Index].Text, $sender.Font, $e.Bounds, $fore,
        [Windows.Forms.TextFormatFlags]::HorizontalCenter -bor [Windows.Forms.TextFormatFlags]::VerticalCenter)
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
            # On a library tab, a dropped folder becomes that tab's folder.
            foreach ($st in $script:LibTabs.Values) {
                if ($st.Page -eq $tabs.SelectedTab) {
                    if ($paths.Count -eq 1 -and (Test-Path -LiteralPath $paths[0] -PathType Container)) { $st.Txt.Text = $paths[0]; Start-Analyze $st }
                    return
                }
            }
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
        if ($tabs.SelectedTab -eq $pageEp -and $txtSearch.Text.Trim()) { Invoke-Safe { Invoke-Search } }
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

$grid.Add_CellValueChanged({ if ($_.ColumnIndex -eq 0 -and -not $script:BulkCheck) { Update-ReadyCount } })
$chkOnlyChanges.Add_CheckedChanged({
        if ($script:Loading) { return }
        $settings.OnlyChanges = $chkOnlyChanges.Checked
        foreach ($st in $script:LibTabs.Values) { $st.OnlyChanges.Checked = $chkOnlyChanges.Checked }
        Update-EpisodeRowVisibility; Update-ReadyCount
    })

$btnPreview.Add_Click({ Invoke-Safe { Update-Preview -Fetch } })
$btnRename.Add_Click({ Invoke-Safe { Invoke-Rename } })
$btnUndo.Add_Click({ Invoke-Safe { Invoke-Undo } })
$btnAll.Add_Click({ $script:BulkCheck = $true; foreach ($r in $grid.Rows) { if ($r.Visible) { $r.Cells[0].Value = $true } }; $script:BulkCheck = $false; Update-ReadyCount })
$btnNone.Add_Click({ $script:BulkCheck = $true; foreach ($r in $grid.Rows) { $r.Cells[0].Value = $false }; $script:BulkCheck = $false; Update-ReadyCount })
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
        $settings.TvRoot = $script:LibTabs['TV'].Txt.Text.Trim()
        $settings.MovieRoot = $script:LibTabs['Movie'].Txt.Text.Trim()
        $settings.MovieFolders = $script:LibTabs['Movie'].MovieFolders.Checked
        $settings.OnlyChanges = $chkOnlyChanges.Checked
        try { Save-Settings $settings } catch { }
        # Don't wait for running lookups (PowerShell.Stop() blocks until a web request returns); ask them
        # to stop and let the process exit below.
        $script:Closing = $true
        $jobTimer.Stop()
        foreach ($j in @($script:Jobs)) { try { [void]$j.PS.BeginStop($null, $null) } catch { } }
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
$script:LibTabs['TV'].Txt.Text = $settings.TvRoot
$script:LibTabs['Movie'].Txt.Text = $settings.MovieRoot
$script:LibTabs['Movie'].MovieFolders.Checked = [bool]$settings.MovieFolders
$chkOnlyChanges.Checked = [bool]$settings.OnlyChanges
foreach ($st in $script:LibTabs.Values) { $st.OnlyChanges.Checked = [bool]$settings.OnlyChanges }
Set-AppTheme
$script:Loading = $false
Set-Status 'Pick a folder (or drag one in) to get started.'

[void]$form.ShowDialog()
# A lookup still running in the background would keep the process alive after the window is gone.
if (@($script:Jobs | Where-Object { -not $_.Handle.IsCompleted }).Count) { [Environment]::Exit(0) }
