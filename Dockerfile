# openconnect VPN client for MikroTik RouterOS containers

ARG ALPINE_VERSION=3.22
FROM alpine:${ALPINE_VERSION}

RUN apk add --no-cache \
      openconnect \
      iproute2 \
      iptables \
      iptables-legacy \
      musl-utils \
      ca-certificates

COPY entrypoint.sh /entrypoint.sh
COPY vpnc-script /etc/vpnc/vpnc-script
RUN chmod +x /entrypoint.sh /etc/vpnc/vpnc-script \
    && /entrypoint.sh --parse https://selftest.invalid/?route=x >/dev/null

ENV ANYCONNECT_PROTOCOL=anyconnect \
    RECONNECT_DELAY=5 \
    DNS_WAIT=60

ENTRYPOINT ["/entrypoint.sh"]
