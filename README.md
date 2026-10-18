# Episode Renamer

Tidies up TV and movie files for Plex, Jellyfin, Kodi, Sonarr and Radarr, using real titles looked up online and a naming scheme you set.

```
TV/One Piece (1999)/Season 02/One Piece - S02E63 - A Promise Between Men! Luffy and the Whale Vow to Meet Again!.mkv
Movies/Inception (2010)/Inception (2010).mkv
```

It comes in two forms with the same renaming engine:

- **Windows app**: a desktop window with **Episodes**, **TV Library** and **Movies** tabs.
- **Docker / Unraid / Linux**: a web page you open in your browser, with **TV Library** and **Movies** tabs.

| Tab | What it does |
|-----|--------------|
| **Episodes** (Windows) | Renames the episode files in one folder. |
| **TV Library** | Takes one show folder or a whole TV library and fixes everything in it. Show folders become `Show (Year)`, season folders become `Season 01` / `Specials`, and episodes follow your name scheme. Loose episodes get moved into the right season folder, and season folders left empty are removed. |
| **Movies** | Takes a movies folder (or a single movie's folder). Each movie becomes `Title (Year)/Title (Year).mkv`. Loose movie files get their own folder (you can turn this off), and `sample` files are ignored. |

Every change is previewed first, and **Undo last rename** puts a whole batch back, including folder renames, moved files, created folders and removed empty folders.

## Windows

Grab **`EpisodeRenamer.exe`** from the [latest release](../../releases/latest) and run it. You don't need to install anything; it runs on the PowerShell that comes with Windows 10/11.

The exe isn't code-signed, so Windows SmartScreen may say *"Windows protected your PC"*. Click **More info → Run anyway**.
If you'd rather not run an unsigned exe, download the zip and double-click **`Episode Renamer.cmd`** instead. It runs the same app straight from the readable `.ps1` scripts.

**Settings → Appearance** switches between light, dark, or following Windows (the default).

## Unraid

1. In Unraid go to **Docker → Template repositories**, add `https://github.com/Adenoidcash/episode-renamer`, and click **Save**.
2. Click **Add Container** and pick **episode-renamer** from the template list.
3. Set **Media** to the share that holds your TV and Movies folders (e.g. `/mnt/user/` or `/mnt/user/media/`). The app can only see and rename things inside it.
4. Optionally set a **Web password**, then click **Apply** and open the WebUI. The default port is 8080.

Files keep Unraid's usual owner (`nobody:users`, PUID 99 / PGID 100). Settings and undo history live in `/mnt/user/appdata/episode-renamer`.

## Docker / Linux

```bash
docker run -d --name episode-renamer -p 8080:8080 \
  -v /path/to/media:/media -v /path/to/appdata:/config \
  -e PUID=1000 -e PGID=1000 \
  ghcr.io/adenoidcash/episode-renamer:latest
```

Then open `http://<server>:8080`. A [`docker-compose.yml`](docker-compose.yml) is included.

| Variable | Default | Meaning |
|----------|---------|---------|
| `PUID` / `PGID` | 99 / 100 | Owner of renamed files and created folders |
| `UMASK` | 002 | Permissions for created folders |
| `WEB_PASSWORD` | *(none)* | If set, the browser asks for it (any user name) |
| `MEDIA_ROOTS` | `/media` | Folders the app may use; separate several with `;` |
| `PORT` | 8080 | Port inside the container |

Without Docker, any machine with [PowerShell 7](https://learn.microsoft.com/powershell/scripting/install/installing-powershell) can run `pwsh ./server.ps1` with the same variables.

## Sonarr, Radarr, Plex and Jellyfin (optional)

Sonarr and Radarr keep track of files by path. If something renames files behind their back, they show episodes as missing ("season incomplete"), and a renamed show folder leaves them pointing at a folder that no longer exists. Connect them in **Settings → Media apps** and the app:

- **After renaming**, points Sonarr/Radarr at the renamed show or movie folder and tells them to rescan, so nothing shows as missing.
- **After undo**, points them back again.
- **With "Sonarr" as the TV source**, names and numbers episodes from Sonarr's own episode list, so they always match what Sonarr expects. That matters most for anime, where sources number seasons differently.
- **With Radarr connected**, looks movies up through Radarr, so no TMDB key is needed.
- **With Plex or Jellyfin connected**, asks them to rescan their libraries after renaming.

Each connection has a **Test** button. Where to find the keys:

| App | Address example | Key |
|-----|----------------|-----|
| Sonarr | `http://192.168.1.10:8989` | Settings → General → API Key |
| Radarr | `http://192.168.1.10:7878` | Settings → General → API Key |
| Plex | `http://192.168.1.10:32400` | Your [Plex token](https://support.plex.tv/articles/204059436-finding-an-authentication-token-x-plex-token/) |
| Jellyfin | `http://192.168.1.10:8096` | Dashboard → API Keys |

Shows and movies are matched to Sonarr/Radarr by folder name, so it works even when they see your media at a different path (e.g. `/tv` in Sonarr and `/media/TV` here).

## Where the information comes from

All keys are optional and go in **Settings**.

| Source  | Used for | Key needed | Notes |
|---------|----------|-----------|-------|
| TVmaze  | TV | No | Good for most western TV. Long-running anime are numbered by year (One Piece = `S2001E11`). The app works around this using your files' own numbers and `Season NN` folders. |
| TheTVDB | TV | Yes | Same numbering as Plex/Sonarr (One Piece = `S02E63`). Supports Aired / DVD / Absolute order and episode titles in other languages. Get a key at https://thetvdb.com/api-information |
| Sonarr  | TV | Your Sonarr | Uses the shows already in your Sonarr, numbered exactly as Sonarr expects. |
| TMDB    | Movies | Yes (free) | Exact titles and years. Get a key at https://www.themoviedb.org/settings/api |
| Radarr  | Movies | Your Radarr | Movie lookups through your Radarr. |

Without any key, movie titles and years come from the file or folder name (`Inception.2010.1080p.BluRay` becomes `Inception (2010)`).

If TVmaze is down (it occasionally is), searches automatically try Sonarr or TheTVDB when those are set up.

The **TV Library** tab finds each show by its folder name. A year in the name (`One Piece (1999)`) picks the right one. Without a year, when several shows share the name, it picks the one whose episode list contains your files. A show folder is never renamed if none of its episodes match.

**Match files by**
- **Auto** uses `S02E63` / `2x63` / `2nd Season - 01` / `Season 2 - 01` when the filename has it. Otherwise a lone number (`One Piece - 063`) means "episode N of this season" inside a `Season N` folder, or the absolute episode number when that fits better.
- **Season + Episode** matches only on season and episode numbers.
- **Absolute number** always matches on the episode number as an absolute count.

**Numbering**
- **Auto** uses the source's season and episode numbers. The exception is a source that numbers seasons by year (TVmaze does this for long anime: `S2001E11`). Then the app uses the file's own numbers and its `Season 02` folder instead, giving `S02E63`.
- **From source** always uses the online numbering.
- **From file / folder** always uses the numbers in the filename, plus the season from a `Season NN` folder when the filename has none.

**Titles**
- **Keep filename title** keeps the episode title that's already in the filename, e.g. `[Anime Time] One Piece - 0063 - A Promise Between Men!...`. It only looks the title up when the file has none.
- **From source** always uses the online title.

**Rename matching extras:** files next to a video that share its name get renamed with it. That covers `<video>.nfo`, `<video>-thumb.jpg` and `<video>.en.srt`, so Plex/Kodi metadata and subtitles stay paired.

**Updates (Windows):** when a newer release is on GitHub, a *"Version x.y.z is available"* link appears at the bottom of the window.

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

On the Episodes tab, use `\` to sort files into folders. Folder paths are relative to the folder you scanned, e.g.
`{show}\Season {season:00}\{show} - S{season:00}E{episode:00} - {title}`

Characters Windows doesn't allow in filenames are replaced or removed (`:` becomes ` -`, and `?` and `*` are dropped).
Subtitle files keep their language tag (`.en.srt`, `.eng.forced.srt`).

Settings and undo logs are stored in `%APPDATA%\EpisodeRenamer\` on Windows and `/config` in Docker.

## Build it yourself

```powershell
Install-Module ps2exe -Scope CurrentUser
powershell -ExecutionPolicy Bypass -File .\build.ps1
docker build -t episode-renamer .
```

`build.ps1` writes `dist\EpisodeRenamer.exe` and `dist\EpisodeRenamer-<version>.zip`; the version comes from `EpisodeRenamer.Core.ps1`. Publishing a GitHub release also builds and publishes the Docker image automatically.

## Credits

TV information is provided by [TVmaze](https://www.tvmaze.com) and [TheTVDB](https://thetvdb.com). Please consider adding missing information or [subscribing](https://thetvdb.com/subscribe). Movie information is provided by [TMDB](https://www.themoviedb.org). This product uses the TMDB API but is not endorsed or certified by TMDB, and it isn't endorsed or certified by TheTVDB either.
