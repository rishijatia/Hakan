FROM python:3.11-slim

# Install system deps
RUN apt-get update && apt-get install -y --no-install-recommends \
    git curl xz-utils proxychains4 && \
    rm -rf /var/lib/apt/lists/*

# Install Hermes
RUN curl -fsSL https://raw.githubusercontent.com/NousResearch/hermes-agent/main/scripts/install.sh | bash

# Copy config files
COPY config.yaml /root/.hermes/config.yaml
COPY SOUL.md /root/.hermes/SOUL.md
COPY start.sh /start.sh
RUN chmod +x /start.sh

EXPOSE 8080

CMD ["/start.sh"]


