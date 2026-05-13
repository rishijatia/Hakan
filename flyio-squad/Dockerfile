FROM nousresearch/hermes-agent:latest

# GitHub CLI + git utilities (squad does actual coding work)
RUN apt-get update && \
    apt-get install -y --no-install-recommends curl && \
    curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
        | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg && \
    chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg && \
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
        | tee /etc/apt/sources.list.d/github-cli.list > /dev/null && \
    apt-get update && apt-get install -y --no-install-recommends gh jq && \
    rm -rf /var/lib/apt/lists/*

COPY flyio-squad/start.sh /start.sh
RUN chmod +x /start.sh

ENTRYPOINT ["/usr/bin/tini", "-g", "--", "/start.sh"]
