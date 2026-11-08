#!/bin/sh
# Certificate-authentication tests for entrypoint.sh.
#
# Checks that each supported configuration turns into the right openconnect
# command line (via --print-cmd) and that bad configurations are rejected with
# a clear error. Nothing connects to a network.
#
# The PKI is NOT generated here: the Alpine image ships without the openssl
# CLI on purpose, so fixtures are produced once by tests/gen-test-certs.sh and
# mounted in.
#
#   docker run --rm -v "$PWD/tests:/tests:ro" -v "$CERTS:/certs:ro" \
#       --entrypoint /bin/sh IMAGE /tests/test-certauth.sh /entrypoint.sh /certs
set -u

EP="${1:-/entrypoint.sh}"
W="${2:-/certs}"
[ -x "$EP" ] || { echo "not executable: $EP" >&2; exit 1; }
for f in ca.pem client.pem client.key client-combined.pem client.enc.key client.p12 empty.pem; do
    [ -s "$W/$f" ] || [ "$f" = empty.pem ] || {
        echo "missing fixture $W/$f -- run tests/gen-test-certs.sh first" >&2; exit 1; }
done
EMPTY="$W/empty.pem"
[ -e "$EMPTY" ] || { EMPTY=$(mktemp); }

pass=0; fail=0

ok() { pass=$((pass+1)); printf 'ok    %s\n' "$1"; }
no() { fail=$((fail+1)); printf 'FAIL  %s\n' "$1"; }

cmd() { env "$@" "$EP" --print-cmd 2>&1; }

# expect <desc> <substring> -- env...
expect() {
    _d="$1"; _want="$2"; shift 2
    _out=$(cmd "$@") || { no "$_d (exited nonzero: $_out)"; return; }
    case "$_out" in
        *"$_want"*) ok "$_d" ;;
        *) no "$_d"; printf '        want substring: %s\n        got: %s\n' "$_want" "$_out" ;;
    esac
}

# reject <desc> <error substring> -- env...
reject() {
    _d="$1"; _want="$2"; shift 2
    if _out=$(cmd "$@" 2>&1); then
        no "$_d (expected rejection, got: $_out)"
    else
        case "$_out" in
            *"$_want"*) ok "$_d" ;;
            *) no "$_d"; printf '        want error: %s\n        got: %s\n' "$_want" "$_out" ;;
        esac
    fi
}

# absent <desc> <substring that must NOT appear> -- env...
absent() {
    _d="$1"; _bad="$2"; shift 2
    _out=$(cmd "$@") || { no "$_d (exited nonzero: $_out)"; return; }
    case "$_out" in
        *"$_bad"*) no "$_d"; printf '        must not contain: %s\n        got: %s\n' "$_bad" "$_out" ;;
        *) ok "$_d" ;;
    esac
}

echo "using fixtures from $W"

S=ANYCONNECT_SERVER=https://vpn.example.com/

echo
echo "== certificate-only auth needs no username or password =="
expect "cert alone is accepted"            "'--certificate=$W/client-combined.pem'" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem"
# This is the behaviour change: previously both were mandatory.
absent "no --passwd-on-stdin without a password" "--passwd-on-stdin" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem"
absent "no --user when none was given"     "--user" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem"

echo
echo "== separate key, encrypted key, PKCS#12 =="
expect "separate --sslkey is passed"       "'--sslkey=$W/client.key'" \
        "$S" "ANYCONNECT_CERT=$W/client.pem" "ANYCONNECT_SSLKEY=$W/client.key"
expect "key passphrase is passed"          "--key-password" \
        "$S" "ANYCONNECT_CERT=$W/client.pem" "ANYCONNECT_SSLKEY=$W/client.enc.key" \
        "ANYCONNECT_KEY_PASSWORD=keypw"
expect "passphrase is redacted in --print-cmd" "--key-password=<redacted>" \
        "$S" "ANYCONNECT_CERT=$W/client.pem" "ANYCONNECT_KEY_PASSWORD=keypw"
expect "PKCS#12 bundle is accepted"        "'--certificate=$W/client.p12'" \
        "$S" "ANYCONNECT_CERT=$W/client.p12" "ANYCONNECT_KEY_PASSWORD=p12pw"

echo
echo "== passphrase from a file =="
# $W may be a read-only mount, so the passphrase file goes somewhere writable.
TMPD=$(mktemp -d)
printf 'keypw\n' > "$TMPD/keypw.txt"
expect "ANYCONNECT_KEY_PASSWORD_FILE is read" "--key-password=<redacted>" \
        "$S" "ANYCONNECT_CERT=$W/client.pem" "ANYCONNECT_KEY_PASSWORD_FILE=$TMPD/keypw.txt"

echo
echo "== certificate + password (servers that want both) =="
expect "both are configured"               "--passwd-on-stdin" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem" "ANYCONNECT_USER=alice" \
        "ANYCONNECT_PASSWORD=secret"
expect "username still passed"             "'--user=alice'" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem" "ANYCONNECT_USER=alice" \
        "ANYCONNECT_PASSWORD=secret"

echo
echo "== server CA, authgroup, MCA =="
expect "--cafile is passed"                "'--cafile=$W/ca.pem'" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem" "ANYCONNECT_CAFILE=$W/ca.pem"
expect "--authgroup is passed"             "'--authgroup=Tunnel-Group'" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem" "ANYCONNECT_AUTHGROUP=Tunnel-Group"
expect "--mca-certificate is passed"       "'--mca-certificate=$W/client.pem'" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem" "ANYCONNECT_MCA_CERT=$W/client.pem" \
        "ANYCONNECT_MCA_KEY=$W/client.key"

echo
echo "== inline *_DATA: PEM, literal backslash-n, base64 =="
CERT_PEM=$(cat "$W/client-combined.pem")
expect "inline PEM with real newlines"     "'--certificate=/tmp/oc-creds/client.pem'" \
        "$S" "ANYCONNECT_CERT_DATA=$CERT_PEM"
# RouterOS environment values are a single line, so literal \n must work.
CERT_1LINE=$(awk '{printf "%s\\n", $0}' "$W/client-combined.pem")
expect "inline PEM with literal backslash-n" "'--certificate=/tmp/oc-creds/client.pem'" \
        "$S" "ANYCONNECT_CERT_DATA=$CERT_1LINE"
CERT_B64=$(base64 < "$W/client-combined.pem" | tr -d '\n')
expect "inline base64 PEM"                 "'--certificate=/tmp/oc-creds/client.pem'" \
        "$S" "ANYCONNECT_CERT_DATA=$CERT_B64"
P12_B64=$(base64 < "$W/client.p12" | tr -d '\n')
expect "inline base64 PKCS#12"             "'--certificate=/tmp/oc-creds/client.pem'" \
        "$S" "ANYCONNECT_CERT_DATA=$P12_B64" "ANYCONNECT_KEY_PASSWORD=p12pw"

echo "-- inline material must land with restrictive permissions --"
rm -rf /tmp/oc-creds
env "$S" "ANYCONNECT_CERT_DATA=$CERT_PEM" "$EP" --print-cmd >/dev/null 2>&1
perm=$(ls -l /tmp/oc-creds/client.pem 2>/dev/null | cut -c1-10)
[ "$perm" = "-rw-------" ] && ok "inline cert written 600 (got $perm)" \
                           || no "inline cert permissions are $perm, expected -rw-------"
# And the decoded bytes must match the original exactly.
if cmp -s /tmp/oc-creds/client.pem "$W/client-combined.pem"; then
    ok "inline PEM decoded byte-identically"
else
    no "inline PEM differs from the source file"
fi
rm -rf /tmp/oc-creds
env "$S" "ANYCONNECT_CERT_DATA=$P12_B64" "ANYCONNECT_KEY_PASSWORD=p12pw" "$EP" --print-cmd >/dev/null 2>&1
if cmp -s /tmp/oc-creds/client.pem "$W/client.p12"; then
    ok "inline base64 PKCS#12 decoded byte-identically"
else
    no "inline PKCS#12 differs from the source file"
fi

echo
echo "== pkcs11 URIs are passed through, not stat()ed =="
expect "pkcs11: URI passed through"        "'--certificate=pkcs11:token=mytoken;object=client'" \
        "$S" "ANYCONNECT_CERT=pkcs11:token=mytoken;object=client"

echo
echo "== rejections =="
reject "no credentials at all"             "no credentials" "$S"
reject "missing certificate file"          "does not exist" \
        "$S" "ANYCONNECT_CERT=$W/nope.pem"
reject "empty certificate file"            "is empty" \
        "$S" "ANYCONNECT_CERT=$EMPTY"
reject "key without certificate"           "cannot authenticate" \
        "$S" "ANYCONNECT_SSLKEY=$W/client.key" "ANYCONNECT_PASSWORD=p" "ANYCONNECT_USER=u"
reject "both path and inline form"         "not both" \
        "$S" "ANYCONNECT_CERT=$W/client.pem" "ANYCONNECT_CERT_DATA=$CERT_PEM"
reject "undecodable inline data"           "could not decode" \
        "$S" "ANYCONNECT_CERT_DATA=!!!not-base64-and-not-pem!!!"
reject "MCA key without MCA cert"          "without ANYCONNECT_MCA_CERT" \
        "$S" "ANYCONNECT_CERT=$W/client-combined.pem" "ANYCONNECT_MCA_KEY=$W/client.key"
reject "password-only auth still needs a user" "no username" \
        "$S" "ANYCONNECT_PASSWORD=secret"

echo
echo "== password-only auth is unchanged =="
expect "password auth still works"         "--passwd-on-stdin" \
        "$S" "ANYCONNECT_USER=alice" "ANYCONNECT_PASSWORD=secret"
absent "no cert flags when none configured" "--certificate" \
        "$S" "ANYCONNECT_USER=alice" "ANYCONNECT_PASSWORD=secret"

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
