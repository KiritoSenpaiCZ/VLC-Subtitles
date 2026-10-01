# VLC-Subtitles

All Highflight VLC subtitle extensions in one place: search Czech and Slovak fansub sites from inside VLC, download a subtitle and apply it to the video that's playing, in a few clicks.

## Extensions

| Extension | Site | Version | Needs |
|---|---|---|---|
| Hiyori Subtitles | [hiyori.cz](https://hiyori.cz) | 1.1.0 | Account |
| WoSir Subtitles | [wosir.cz](https://www.wosir.cz) | 1.1.0 | Account |
| Edna Subtitles | [edna.cz](https://www.edna.cz) | 1.1.0 | Account |
| Kamui Subtitles | [kamui-subs.cz](https://kamui-subs.cz) | 1.1.0 | Account + ZIP password |
| Titulky.com Subtitles | [titulky.com](https://premium.titulky.com) | 1.1.0 | Account |
| Legie Kondor Subtitles | [anime4.legiekondor.cz](https://anime4.legiekondor.cz) | 1.0.0 | Nothing |
| NyaSub Subtitles | [nyasub.cz](https://nyasub.cz) | 1.0.0 | Nothing |
| Hanabi Subtitles | [hanabi.fan](https://hanabi.fan) | 1.0.0 | Access token (free account) |

## Install

The installer copies all eight extensions into VLC's extensions folder (and creates it if needed). **Run it again any time to update**: it shows what changed, and your saved logins, tokens and downloaded subtitles are kept.

### Windows

Open PowerShell and run:

```powershell
irm https://raw.githubusercontent.com/KiritoSenpaiCZ/VLC-Subtitles/main/install.ps1 | iex
```

Or download this repo (Code → Download ZIP), unpack it and run:

```powershell
powershell -ExecutionPolicy Bypass -File install.ps1
```

### macOS

Open Terminal and run:

```bash
curl -fsSL https://raw.githubusercontent.com/KiritoSenpaiCZ/VLC-Subtitles/main/install.sh | bash
```

Or from a downloaded copy of this repo: `bash install.sh`

### Manual install

Copy the `.lua` files you want from the [`extensions`](extensions) folder into:

- Windows: `%APPDATA%\vlc\lua\extensions\`
- macOS: `~/Library/Application Support/org.videolan.vlc/lua/extensions/`

### After installing

Restart VLC completely (on Windows, check that no `vlc.exe` is left in Task Manager). The extensions are in the **View** menu on Windows, and under **VLC → Extensions** on macOS.

## Usage

1. Play a video. Most extensions guess the show title (and episode) from the file name
2. Open the extension, fill in your login if the site needs one (it's remembered), and click **Search**
3. Pick the show, then the subtitle, then **Download Selected**. It's downloaded, unpacked and applied to the video

Subtitles are saved to `Documents/VLC Subtitles` and cleaned up automatically after 30 days.

## Your logins

Passwords and tokens are stored in the macOS Keychain, or encrypted with Windows DPAPI (only your Windows user account can read them). They are only ever sent to the site they belong to.

## Requirements

- VLC 3.x (tested on 3.0.23)
- Windows 10 or newer (uses the built-in `curl` and `tar`), or macOS

## Notes

- These are unofficial, fan-made extensions. Apart from Hanabi (which uses Hanabi's official API), they read the sites' public web pages, so a site redesign can break one until it's updated.
- VLC doesn't update these by itself: to update, just run the installer again.

## Kodi

The same sites are available for Kodi as subtitle addons, from the [Highflight Kodi repository](https://github.com/KiritoSenpaiCZ/KiritoSenpaiCZ.github.io).
