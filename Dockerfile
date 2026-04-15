FROM python:3.11-slim-bookworm

ARG TIME_CHECK=180
ENV TIME_CHECK=$TIME_CHECK

# On définit le shell avec pipefail pour la sécurité des pipes (DL4006)
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# Installation outils de base
RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    ca-certificates \
    gnupg \
    procps \
    && rm -rf /var/lib/apt/lists/*

# Installation Speedtest
RUN curl -s https://packagecloud.io/install/repositories/ookla/speedtest-cli/script.deb.sh | bash \
    && apt-get install -y --no-install-recommends speedtest \
    && rm -rf /var/lib/apt/lists/*

# Installation Python libs
RUN pip install --no-cache-dir --upgrade pip && \
    pip install --no-cache-dir yt-dlp humanfriendly

COPY docker-entrypoint.sh /usr/local/bin/
COPY compute_average_download_biterate.py /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh /usr/local/bin/compute_average_download_biterate.py

ENTRYPOINT ["/bin/bash", "-c", "timeout --preserve-status --signal=SIGTERM $TIME_CHECK /usr/local/bin/docker-entrypoint.sh"]