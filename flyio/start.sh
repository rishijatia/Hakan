#!/bin/sh
set -e

if [ -n "$PROXY_HOST" ] && [ -n "$PROXY_PORT" ]; then
    cat > /etc/proxychains4.conf << EOF
strict_chain
proxy_dns
quiet_mode
[ProxyList]
socks5 $PROXY_HOST $PROXY_PORT $PROXY_USER $PROXY_PASS
EOF
    exec proxychains4 -q hermes gateway run
else
    exec hermes gateway run
fi
