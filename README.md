# Highflight VLC Subtitles

VLC extensions for Czech/Slovak anime and TV subtitle sites, all in one place with a one-line installer for Windows and macOS. Search a site from inside VLC, pick a subtitle, and it's downloaded and applied to the video that's playing.

Compatible with VLC 3.x on Windows 10/11 and macOS (tested on VLC 3.0.23).

## Extensions in this repository

| Extension | Site | Content | Version | Needs | Support |
|---|---|---|---|---|---|
| Edna Subtitles | [edna.cz](https://www.edna.cz) | Czech/Slovak TV shows | 1.2.0 | Account | Unofficial |
| Hanabi Subtitles | [hanabi.fan](https://hanabi.fan) | Czech anime | 1.1.0 | Access token (free account) | **Official API** |
| Hiyori Subtitles | [hiyori.cz](https://hiyori.cz) | Czech/Slovak anime | 1.3.0 | Account | Unofficial |
| HNS Subtitles | [hns.sk](https://hns.sk) | Czech/Slovak anime | 1.0.0 | Account (e-mail) | Unofficial |
| Kamui-Subs Subtitles | [kamui-subs.cz](https://kamui-subs.cz) | Czech anime | 1.3.0 | Account + ZIP password | Unofficial |
| Legie Kondor Subtitles | [anime4.legiekondor.cz](https://anime4.legiekondor.cz) | Czech anime | 1.1.0 | Nothing | Unofficial |
| NyaSub Subtitles | [nyasub.cz](https://nyasub.cz) | Czech anime | 1.1.0 | Nothing | Unofficial |
| Titulky.com Subtitles | [titulky.com](https://premium.titulky.com) | Czech/Slovak movies and TV | 1.3.0 | Premium account | Unofficial |
| WoSir Subtitles | [wosir.cz](https://www.wosir.cz) | Czech anime | 1.3.0 | Account | Unofficial |

**Support:**
- **Official API**: the site publishes and supports an API for exactly this purpose. Documented and stable.
- **Unofficial**: the extension reads the site's own web pages (HTML scraping). Not sanctioned by the site, and it can break at any time if the site changes its layout, until the extension is updated.

## Installation Instructions
The installer copies all nine extensions into VLC's extensions folder (creating it if needed). **Run it again any time to update**: it shows what changed, and your saved logins, tokens and downloaded subtitles are kept.

**Windows** — open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/KiritoSenpaiCZ/VLC-Subtitles/main/install.ps1 | iex
```

**macOS** — open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/KiritoSenpaiCZ/VLC-Subtitles/main/install.sh | bash
```

From a downloaded copy of this repo (Code > Download ZIP) instead: `powershell -ExecutionPolicy Bypass -File install.ps1` on Windows, `bash install.sh` on macOS.

Manual install: copy the `.lua` files you want from the [`extensions`](extensions) folder into `%APPDATA%\vlc\lua\extensions\` (Windows) or `~/Library/Application Support/org.videolan.vlc/lua/extensions/` (macOS).

Then quit VLC completely and start it again. The extensions are in the **View** menu on Windows, and under **VLC > Extensions** on macOS.

## Usage
1. Play a video. Most extensions guess the show title (and episode) from the file name
2. Open the extension, fill in your login if the site needs one (it's remembered), and click **Search**
3. Pick the show, then the subtitle, then **Download Selected**. It's downloaded, unpacked and applied to the video

The extensions are in Czech when your system language is Czech or Slovak, and in English otherwise.

Subtitles are saved to `Documents/VLC Subtitles` and cleaned up automatically after 30 days. Passwords and tokens are kept in the macOS Keychain or encrypted with Windows DPAPI, and are only ever sent to the site they belong to.

## Repository layout
- `extensions/<name>.lua` — the extensions themselves
- `install.ps1` / `install.sh` — the Windows and macOS installers
- `dev/` — maintenance tools (shared code kept in one place), not needed to use the extensions

## Kodi
The same sites (except titulky.com) are available as Kodi subtitle addons, from the [Highflight Subtitles Repository](https://github.com/KiritoSenpaiCZ/KiritoSenpaiCZ.github.io).

## Issues
Please open an issue in this repo with the extension's name, a description of the problem and, if possible, a VLC debug log (Tools > Messages, set Verbosity to 2 - Debug, reproduce the problem, then save the log).
