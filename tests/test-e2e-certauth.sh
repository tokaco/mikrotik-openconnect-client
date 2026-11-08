#!/bin/sh
# End-to-end certificate-authentication test.
#
# Brings up a real ocserv configured for certificate-only auth, then connects
# the actual image to it with a client certificate and checks that the tunnel
# comes up and carries traffic. This is what proves certificate auth works,
# as opposed to the flags merely being spelled correctly.
#
#   sh tests/test-e2e-certauth.sh [image] [platform]
set -u

IMAGE="${1:-ocmt:alpine}"
PLATFORM="${2:-}"
[ -n "$PLATFORM" ] && PLAT="--platform $PLATFORM" || PLAT=""
NET=oc-e2e-net
SRV=oc-e2e-server
CLI=oc-e2e-client
W=$(mktemp -d)

cleanup() {
    docker rm -f "$CLI" "$SRV" >/dev/null 2>&1
    docker network rm "$NET" >/dev/null 2>&1
    rm -rf "$W"
}
trap cleanup EXIT INT TERM
cleanup

fail=0
ok() { printf 'ok    %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }

echo "== generating the test PKI =="
# Built first because it is also the image that generates the certificates:
# the Alpine image under test deliberately has no openssl CLI.
docker build -q $PLAT -t oc-e2e-ocserv -f tests/e2e/Dockerfile.ocserv tests/e2e >/dev/null \
    || { echo "could not build the ocserv test image"; exit 1; }
docker run --rm $PLAT -v "$PWD/tests:/tests:ro" -v "$W:/out" \
    --entrypoint /bin/sh oc-e2e-ocserv /tests/gen-test-certs.sh /out "$SRV" \
    || { echo "certificate generation failed"; exit 1; }
PIN=$(tr -d '\r\n' < "$W/server.pin")
echo "server pin = $PIN"

echo
echo "== starting ocserv (certificate-only auth) =="
docker network create "$NET" >/dev/null
docker run -d --name "$SRV" --network "$NET" $PLAT \
    --cap-add NET_ADMIN --device /dev/net/tun \
    -v "$W:/certs:ro" oc-e2e-ocserv >/dev/null \
    || { echo "could not start ocserv"; exit 1; }

# Wait for the server to listen.
i=0
while [ "$i" -lt 30 ]; do
    docker logs "$SRV" 2>&1 | grep -q "listening" && break
    i=$((i+1)); sleep 1
done
if ! docker logs "$SRV" 2>&1 | grep -q "listening"; then
    echo "ocserv did not come up:"; docker logs "$SRV" 2>&1 | tail -20; exit 1
fi
ok "ocserv is listening"

# run_client <description> <extra docker -e args...>
run_client() {
    _desc="$1"; shift
    docker rm -f "$CLI" >/dev/null 2>&1
    docker run -d --name "$CLI" --network "$NET" $PLAT \
        --cap-add NET_ADMIN --device /dev/net/tun \
        -v "$W:/certs:ro" \
        -e "ANYCONNECT_SERVER=https://$SRV/" \
        -e "ANYCONNECT_SERVERCERT=$PIN" \
        -e ANYCONNECT_NONINTER=1 \
        "$@" "$IMAGE" >/dev/null || { no "$_desc (container would not start)"; return 1; }

    _i=0
    while [ "$_i" -lt 40 ]; do
        if docker logs "$CLI" 2>&1 | grep -qE "CSTP connected|Connected as "; then return 0; fi
        if docker logs "$CLI" 2>&1 | grep -qE "Login failed|Failed to open HTTPS connection|Failed to obtain WebVPN cookie|Creating SSL connection failed"; then
            no "$_desc"; docker logs "$CLI" 2>&1 | tail -15 | sed 's/^/        /'; return 1
        fi
        _i=$((_i+1)); sleep 1
    done
    no "$_desc (timed out)"; docker logs "$CLI" 2>&1 | tail -20 | sed 's/^/        /'; return 1
}

echo
echo "== PEM certificate + key in one file, no username, no password =="
if run_client "tunnel established with certificate-only auth" \
      -e ANYCONNECT_CERT=/certs/client-combined.pem; then
    ok "tunnel established with certificate-only auth"

    docker logs "$CLI" 2>&1 | grep -q "auth        = certificate" \
        && ok "entrypoint reported certificate auth mode" \
        || no "entrypoint did not report certificate auth mode"

    # The server identified the client from the certificate CN.
    docker logs "$SRV" 2>&1 | grep -q "testuser" \
        && ok "server authenticated the CN from the certificate (testuser)" \
        || no "server did not log the certificate CN"

    # "CSTP connected" is logged before vpnc-script has configured the
    # device, so wait for the address rather than racing it.
    addr=""
    i=0
    while [ "$i" -lt 25 ]; do
        addr=$(docker exec "$CLI" ip -4 -o addr show dev tun0 2>/dev/null | awk '{print $4}')
        [ -n "$addr" ] && break
        i=$((i+1)); sleep 1
    done
    case "$addr" in
        10.10.10.*) ok "tun0 got a VPN address from the server ($addr)" ;;
        *) no "tun0 has no VPN address (got '${addr:-none}')" ;;
    esac

    docker exec "$CLI" ip route show 2>/dev/null | grep -q "10.99.0.0/16 dev tun0" \
        && ok "server-pushed split route installed" \
        || no "server-pushed split route missing"

    # Traffic actually crosses the tunnel.
    if ! docker exec "$CLI" sh -c 'command -v ping' >/dev/null 2>&1; then
        printf 'skip  ping test (no ping in this image)\n'
    elif docker exec "$CLI" ping -c 2 -W 3 10.10.10.1 >/dev/null 2>&1; then
        ok "ping to the VPN gateway through the tunnel"
    else
        no "could not ping the VPN gateway through the tunnel"
    fi

    # Clean shutdown: SIGTERM must stop the container, not restart the loop.
    docker stop -t 10 "$CLI" >/dev/null 2>&1
    docker logs "$CLI" 2>&1 | grep -q "exiting on signal" \
        && ok "clean shutdown on SIGTERM" \
        || no "did not shut down cleanly on SIGTERM"
fi

echo
echo "== PKCS#12 bundle with a passphrase =="
if run_client "tunnel established from a PKCS#12 bundle" \
      -e ANYCONNECT_CERT=/certs/client.p12 \
      -e ANYCONNECT_KEY_PASSWORD=p12pass; then
    ok "tunnel established from a PKCS#12 bundle"
fi

echo
echo "== inline certificate via ANYCONNECT_CERT_DATA (base64) =="
CERT_B64=$(base64 < "$W/client-combined.pem" | tr -d '\n')
if run_client "tunnel established from inline base64 certificate" \
      -e "ANYCONNECT_CERT_DATA=$CERT_B64"; then
    ok "tunnel established from inline base64 certificate"
fi

echo
echo "== a certificate the server's CA did not sign must be refused =="
docker rm -f "$CLI" >/dev/null 2>&1
docker run -d --name "$CLI" --network "$NET" $PLAT \
    --cap-add NET_ADMIN --device /dev/net/tun -v "$W:/certs:ro" \
    -e "ANYCONNECT_SERVER=https://$SRV/" -e "ANYCONNECT_SERVERCERT=$PIN" \
    -e ANYCONNECT_NONINTER=1 -e RECONNECT_DELAY=1 \
    -e ANYCONNECT_CERT=/certs/rogue-combined.pem "$IMAGE" >/dev/null
i=0; connected=no
while [ "$i" -lt 15 ]; do
    docker logs "$CLI" 2>&1 | grep -qE "CSTP connected|Connected as " && { connected=yes; break; }
    i=$((i+1)); sleep 1
done
[ "$connected" = no ] && ok "untrusted client certificate was rejected" \
                      || no "untrusted client certificate was ACCEPTED"

echo
echo "failed: $fail"
[ "$fail" -eq 0 ]
