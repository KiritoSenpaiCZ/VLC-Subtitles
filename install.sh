#!/bin/bash
# Installs or updates all Highflight VLC subtitle extensions (macOS).
#
# One-liner (Terminal):
#   curl -fsSL https://raw.githubusercontent.com/KiritoSenpaiCZ/VLC-Subtitles/main/install.sh | bash
#
# Or from a downloaded/cloned copy of the repo:
#   bash install.sh
#
# Run it again any time to update. Only the extension files are replaced;
# saved logins, tokens and downloaded subtitles are left alone.

set -u

EXTENSIONS="hiyori wosir edna kamui titulky legiekondor nyasub hanabi"
RAW_BASE="https://raw.githubusercontent.com/KiritoSenpaiCZ/VLC-Subtitles/main/extensions"
DEST="${VLC_EXT_DIR:-$HOME/Library/Application Support/org.videolan.vlc/lua/extensions}"

if [ "$(uname -s)" != "Darwin" ] && [ -z "${VLC_EXT_DIR:-}" ]; then
	echo "This installer is for macOS (on Windows use install.ps1)."
	exit 1
fi

# version = "1.2.3" / VERSION = "1.2.3" inside an extension file, or empty
ext_version() {
	[ -f "$1" ] || return 0
	grep -oiE '(^|[^a-z_])version[[:space:]]*=[[:space:]]*"[0-9][0-9.]*"' "$1" | head -n1 | grep -oE '[0-9][0-9.]*' | head -n1
}

# local mode when this script sits next to an extensions/ folder (cloned or
# downloaded repo); otherwise (e.g. piped from curl) download
LOCAL_DIR=""
src="${BASH_SOURCE[0]:-}"
if [ -n "$src" ] && [ -f "$src" ]; then
	candidate="$(cd "$(dirname "$src")" && pwd)/extensions"
	[ -d "$candidate" ] && LOCAL_DIR="$candidate"
fi

echo
echo "Highflight VLC subtitle extensions"
echo "Installing into: $DEST"
if [ -n "$LOCAL_DIR" ]; then echo "Source: $LOCAL_DIR"; else echo "Source: GitHub (KiritoSenpaiCZ/VLC-Subtitles)"; fi
echo

mkdir -p "$DEST" || { echo "Couldn't create $DEST"; exit 1; }

failed=0
for name in $EXTENSIONS; do
	file="$name.lua"
	target="$DEST/$file"
	tmp="$DEST/$file.download"
	rm -f "$tmp"
	if [ -n "$LOCAL_DIR" ]; then
		cp "$LOCAL_DIR/$file" "$tmp" 2>/dev/null
	else
		curl -fsSL --max-time 60 -o "$tmp" "$RAW_BASE/$file"
	fi
	# sanity check before replacing anything: a real VLC extension
	if [ $? -ne 0 ] || ! grep -q "function descriptor" "$tmp" 2>/dev/null; then
		failed=$((failed + 1))
		printf "  %-12s FAILED (couldn't get a valid file)\n" "$name"
		rm -f "$tmp"
		continue
	fi
	old="$(ext_version "$target")"
	new="$(ext_version "$tmp")"
	if ! mv -f "$tmp" "$target"; then
		failed=$((failed + 1))
		printf "  %-12s FAILED (couldn't write %s)\n" "$name" "$target"
		rm -f "$tmp"
		continue
	fi
	if [ -z "$old" ]; then
		printf "  %-12s installed %s\n" "$name" "$new"
	elif [ "$old" != "$new" ]; then
		printf "  %-12s updated %s -> %s\n" "$name" "$old" "$new"
	else
		printf "  %-12s up to date (%s)\n" "$name" "$new"
	fi
done

echo
if [ "$failed" -gt 0 ]; then
	echo "$failed extension(s) failed, the rest are installed. Run the installer again to retry."
else
	echo "All done."
fi
if pgrep -x VLC >/dev/null 2>&1; then
	echo "VLC is running: quit it completely (Cmd+Q) and start it again to load the changes."
else
	echo "Start VLC and open the extensions from the VLC menu > Extensions."
fi
echo
[ "$failed" -eq 0 ]
