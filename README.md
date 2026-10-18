# Episode Renamer

Renames TV episode files using real episode titles looked up online, with a naming scheme you set.

Default scheme: `One Piece - S02E63 - A Promise Between Men! Luffy and the Whale Vow to Meet Again!.mkv`

## Download

Grab **`EpisodeRenamer.exe`** from the [latest release](../../releases/latest) and run it. You don't need to install anything; it runs on the PowerShell that comes with Windows 10/11.

The exe isn't code-signed, so Windows SmartScreen may say *"Windows protected your PC"*. Click **More info → Run anyway**.
If you'd rather not run an unsigned exe, download the zip and double-click **`Episode Renamer.cmd`** instead. It runs the same app straight from the readable `.ps1` scripts.

## Build the exe yourself

```powershell
Install-Module ps2exe -Scope CurrentUser
powershell -ExecutionPolicy Bypass -File .\build.ps1 -Version 1.0.0
```
This writes `dist\EpisodeRenamer.exe` and `dist\EpisodeRenamer-1.0.0.zip`.

## Use

1. **Browse...** to a folder, or drag a folder or files onto the window.
2. The show name is guessed from the filenames. Click **Search** and pick the right show from the list (e.g. the anime vs the live-action).
3. Check the **New name** column, untick any files you want to skip, then click **Rename checked**.
4. Click **Undo last rename** to put the last batch back.

## Sources

| Source  | Key needed | Notes |
|---------|-----------|-------|
| TVmaze  | No        | Good for most western TV. Long-running anime are numbered by year (One Piece = `S2001E11`). |
| TheTVDB | Yes       | Same numbering as Plex/Sonarr (One Piece = `S02E63`). Supports Aired / DVD / Absolute order and episode titles in other languages. Get a key at https://thetvdb.com/api-information and paste it into **Settings...** |

**Match files by**
- **Auto** uses `S02E63` / `2x63` when the filename has it. Otherwise the lone number (`One Piece - 063`) is treated as the absolute episode number.
- **Season + Episode** matches only on SxxExx.
- **Absolute number** always matches on the episode number as an absolute count.

## Naming scheme tokens

| Token | Example |
|-------|---------|
| `{show}` | One Piece |
| `{season:00}` / `{season}` | 02 / 2 |
| `{episode:00}` | 63 (`63-E64` for double episodes) |
| `{absolute:000}` | 063 |
| `{title}` | A Promise Between Men! ... |
| `{year}` | 1999 |
| `{airdate}` | 2001-08-29 |
| `{original}` | the old filename |

Use `\` to sort files into folders. Folder paths are relative to the folder you scanned, e.g.
`{show}\Season {season:00}\{show} - S{season:00}E{episode:00} - {title}`

Characters Windows doesn't allow in filenames are replaced or removed (`:` becomes ` -`, and `?` and `*` are dropped).
Subtitle files keep their language tag (`.en.srt`, `.eng.forced.srt`).

Settings and undo logs are stored in `%APPDATA%\EpisodeRenamer\`.
