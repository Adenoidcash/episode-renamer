# Episode Renamer

Tidies up TV and movie files for Plex, Jellyfin, Kodi and similar apps, using real titles looked up online and a naming scheme you set.

```
TV\One Piece (1999)\Season 02\One Piece - S02E63 - A Promise Between Men! Luffy and the Whale Vow to Meet Again!.mkv
Movies\Inception (2010)\Inception (2010).mkv
```

The window has three tabs:

| Tab | What it does |
|-----|--------------|
| **Episodes** | Renames the episode files in one folder. |
| **TV Library** | Takes one show folder or a whole TV library and fixes everything in it. Show folders become `Show (Year)`, season folders become `Season 01` / `Specials`, and episodes follow your name scheme. Loose episodes get moved into the right season folder, and season folders left empty are removed. |
| **Movies** | Takes a movies folder (or a single movie's folder). Each movie becomes `Title (Year)\Title (Year).mkv`. Loose movie files get their own folder (you can turn this off), and `sample` files are ignored. |

## Download

Grab **`EpisodeRenamer.exe`** from the [latest release](../../releases/latest) and run it. You don't need to install anything; it runs on the PowerShell that comes with Windows 10/11.

The exe isn't code-signed, so Windows SmartScreen may say *"Windows protected your PC"*. Click **More info → Run anyway**.
If you'd rather not run an unsigned exe, download the zip and double-click **`Episode Renamer.cmd`** instead. It runs the same app straight from the readable `.ps1` scripts.

## Build the exe yourself

```powershell
Install-Module ps2exe -Scope CurrentUser
powershell -ExecutionPolicy Bypass -File .\build.ps1
```
This writes `dist\EpisodeRenamer.exe` and `dist\EpisodeRenamer-<version>.zip`. The version comes from `EpisodeRenamer.Core.ps1`.

## Use

**Episodes tab**
1. **Browse...** to a folder, or drag a folder or files onto the window.
2. The show name is guessed from the filenames. Click **Search**; the right show is usually picked automatically.
3. Check the **New name** column, untick any files you want to skip, then click **Rename checked**.

**TV Library / Movies tabs**
1. **Browse...** to the folder, or drag it onto the window, and click **Analyze**. Nothing is changed yet.
2. Each show or movie gets a bold row with its new name, what it was matched as, and a status. The rows under it list every file and folder change. Untick **Show file details** for a compact view.
3. If something was matched wrong, select it and click **Change match...** (or double-click the row). For a movie you can also just type the title and year.
4. Untick anything you want to skip, then click **Rename checked**.

**Undo last rename** (bottom left) puts the whole last batch back, including folder renames, moved files, created folders and removed empty folders.

## Sources

All keys are optional and go in **Settings...**

| Source  | Used for | Key needed | Notes |
|---------|----------|-----------|-------|
| TVmaze  | TV | No | Good for most western TV. Long-running anime are numbered by year (One Piece = `S2001E11`). The app works around this using your files' own numbers and `Season NN` folders. |
| TheTVDB | TV | Yes | Same numbering as Plex/Sonarr (One Piece = `S02E63`). Supports Aired / DVD / Absolute order and episode titles in other languages. Get a key at https://thetvdb.com/api-information |
| TMDB    | Movies | Yes (free) | Exact titles and years. Without a key, the title and year come from the file or folder name (`Inception.2010.1080p.BluRay` becomes `Inception (2010)`). Get a key at https://www.themoviedb.org/settings/api |

The **TV Library** tab finds each show by its folder name. A year in the name (`One Piece (1999)`) picks the right one. Without a year, when several shows share the name, it picks the one whose episode list contains your files. A show folder is never renamed if none of its episodes match.

**Match files by**
- **Auto** uses `S02E63` / `2x63` when the filename has it. Otherwise the lone number (`One Piece - 063`) is treated as the absolute episode number.
- **Season + Episode** matches only on SxxExx.
- **Absolute number** always matches on the episode number as an absolute count.

**Numbering**
- **Auto** uses the source's season and episode numbers. The exception is a source that numbers seasons by year (TVmaze does this for long anime: `S2001E11`). Then the app uses the file's own numbers and its `Season 02` folder instead, giving `S02E63`.
- **From source** always uses the online numbering.
- **From file / folder** always uses the numbers in the filename, plus the season from a `Season NN` folder when the filename has none.

**Titles**
- **Keep filename title** keeps the episode title that's already in the filename, e.g. `[Anime Time] One Piece - 0063 - A Promise Between Men!...`. It only looks the title up when the file has none.
- **From source** always uses the online title.

**Picking the right show:** if the folder path has a year in brackets, e.g. `One Piece (1999)`, the app picks the search result that first aired that year. Otherwise it opens the results list so you can check its pick.

**Rename matching extras:** files next to a video that share its name get renamed with it. That covers `<video>.nfo`, `<video>-thumb.jpg` and `<video>.en.srt`, so Plex/Kodi metadata and subtitles stay paired. The Original name column shows `(+N extra)`; hover over it to see the files.

**Updates:** when a newer release is on GitHub, a *"Version x.y.z is available"* link appears at the bottom of the window.

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
