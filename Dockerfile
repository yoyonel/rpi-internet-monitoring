FROM debian:bookworm-slim

ARG TIME_CHECK=180
ENV TIME_CHECK=$TIME_CHECK

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install -y --no-install-recommends \
    curl \
    jq \
    ca-certificates \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Ookla Speedtest CLI — add repo key and source explicitly (no curl|bash)
RUN install -d /usr/share/keyrings \
    && curl -fsSL https://packagecloud.io/ookla/speedtest-cli/gpgkey \
       | gpg --dearmor -o /usr/share/keyrings/ookla-speedtest.gpg \
    && echo "deb [signed-by=/usr/share/keyrings/ookla-speedtest.gpg] https://packagecloud.io/ookla/speedtest-cli/debian/ bookworm main" \
       > /etc/apt/sources.list.d/ookla-speedtest.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends speedtest \
    && rm -rf /var/lib/apt/lists/*

# Run as non-root user
RUN useradd -r -s /bin/false speedtest-user

COPY docker-entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/docker-entrypoint.sh

USER speedtest-user

ENTRYPOINT ["/bin/bash", "-c", "timeout --preserve-status --signal=SIGTERM $TIME_CHECK /usr/local/bin/docker-entrypoint.sh"]
