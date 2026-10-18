#!/bin/sh
# Start the web server as PUID:PGID (Unraid's nobody:users = 99:100 by default) so renamed files and
# created folders get the same owner as the rest of the media share.
set -e

umask "${UMASK:-002}"
mkdir -p /config

if [ "$(id -u)" = "0" ]; then
    PUID="${PUID:-99}"
    PGID="${PGID:-100}"
    chown "$PUID:$PGID" /config
    chown -R "$PUID:$PGID" /config/undo /config/settings.json 2>/dev/null || true
    # PowerShell keeps a small cache in $HOME; give it somewhere writable.
    export HOME=/tmp/episode-renamer
    mkdir -p "$HOME" && chown "$PUID:$PGID" "$HOME"
    echo "Running as uid $PUID / gid $PGID, umask $(umask)"
    exec setpriv --reuid="$PUID" --regid="$PGID" --clear-groups pwsh -NoLogo -NoProfile -File /app/server.ps1
fi

exec pwsh -NoLogo -NoProfile -File /app/server.ps1
