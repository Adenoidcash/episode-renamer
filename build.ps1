# Builds dist\EpisodeRenamer.exe (single file, no console) and dist\EpisodeRenamer-<version>.zip.
# Requires the ps2exe module:  Install-Module ps2exe -Scope CurrentUser
# The version comes from $script:AppVersion in EpisodeRenamer.Core.ps1 unless -Version is given.
param([string]$Version)

$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
if (-not $Version) {
    $m = Select-String -Path (Join-Path $root 'EpisodeRenamer.Core.ps1') -Pattern "AppVersion = '([\d.]+)'"
    $Version = $m.Matches[0].Groups[1].Value
}
$dist = Join-Path $root 'dist'
$build = Join-Path $root 'build'
Remove-Item $dist, $build -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory $dist, $build | Out-Null

# ps2exe compiles one script and $PSScriptRoot is empty inside the exe, so inline the core file.
$dotSource = ". (Join-Path `$PSScriptRoot 'EpisodeRenamer.Core.ps1')"
$gui = Get-Content (Join-Path $root 'EpisodeRenamer.ps1') -Raw
$core = Get-Content (Join-Path $root 'EpisodeRenamer.Core.ps1') -Raw
if (-not $gui.Contains($dotSource)) { throw "Couldn't find the core dot-source line in EpisodeRenamer.ps1" }
$merged = Join-Path $build 'EpisodeRenamer.merged.ps1'
Set-Content $merged $gui.Replace($dotSource, $core) -Encoding UTF8

Import-Module ps2exe
Invoke-ps2exe -inputFile $merged -outputFile (Join-Path $dist 'EpisodeRenamer.exe') `
    -noConsole -STA -iconFile (Join-Path $root 'assets\icon.ico') `
    -title 'Episode Renamer' -description 'Rename TV episodes using TVmaze / TheTVDB' `
    -product 'Episode Renamer' -version $Version

# Zip for people who'd rather run the scripts than an unsigned exe.
$zipDir = Join-Path $build "EpisodeRenamer-$Version"
New-Item -ItemType Directory $zipDir | Out-Null
Copy-Item (Join-Path $dist 'EpisodeRenamer.exe'), (Join-Path $root 'EpisodeRenamer.ps1'), (Join-Path $root 'EpisodeRenamer.Core.ps1'),
    (Join-Path $root 'Episode Renamer.cmd'), (Join-Path $root 'README.md'), (Join-Path $root 'LICENSE') $zipDir
Compress-Archive -Path $zipDir -DestinationPath (Join-Path $dist "EpisodeRenamer-$Version.zip")

Remove-Item $build -Recurse -Force
Get-ChildItem $dist | Select-Object Name, @{ n = 'KB'; e = { [int]($_.Length / 1KB) } }
