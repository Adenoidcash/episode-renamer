# Episode Renamer web UI for Linux / Docker / Unraid.
#   docker run -d -p 8080:8080 -v /path/to/media:/media -v /path/to/appdata:/config ghcr.io/adenoidcash/episode-renamer
FROM mcr.microsoft.com/powershell:lts-ubuntu-22.04

LABEL org.opencontainers.image.title="Episode Renamer" \
      org.opencontainers.image.description="Rename TV episodes and movies for Plex/Jellyfin using TVmaze, TheTVDB and TMDB" \
      org.opencontainers.image.source="https://github.com/Adenoidcash/episode-renamer" \
      org.opencontainers.image.licenses="MIT"

ENV POWERSHELL_TELEMETRY_OPTOUT=1 \
    POWERSHELL_UPDATECHECK=Off \
    DOTNET_CLI_TELEMETRY_OPTOUT=1 \
    PORT=8080 \
    MEDIA_ROOTS=/media \
    EPISODE_RENAMER_CONFIG=/config \
    PUID=99 \
    PGID=100 \
    UMASK=002

WORKDIR /app
COPY EpisodeRenamer.Core.ps1 server.ps1 ./
COPY web ./web
COPY docker/entrypoint.sh /entrypoint.sh
# Strip Windows line endings in case the repo was checked out on Windows.
RUN sed -i 's/\r$//' /entrypoint.sh && chmod 755 /entrypoint.sh && mkdir -p /config /media

VOLUME ["/config"]
EXPOSE 8080
ENTRYPOINT ["/entrypoint.sh"]
