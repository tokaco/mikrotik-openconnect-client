#!/bin/sh
# Generates the throwaway PKI the certificate tests use, into a directory.
#
# Kept separate from the tests so it can run wherever openssl exists: the
# Alpine image deliberately ships without the openssl CLI, so the fixtures are
# produced once (by any image that has it) and mounted into the image under
# test.
#
#   sh tests/gen-test-certs.sh <output-dir> [server-cn]
set -eu

OUT="${1:?usage: gen-test-certs.sh <output-dir> [server-cn]}"
SRV_CN="${2:-oc-e2e-server}"
command -v openssl >/dev/null 2>&1 || { echo "no openssl CLI available" >&2; exit 1; }
mkdir -p "$OUT"
cd "$OUT"

openssl req -x509 -newkey rsa:2048 -nodes -days 90 -subj /CN=test-ca \
    -keyout ca.key -out ca.pem >/dev/null 2>&1

# Server certificate, with a SAN so normal hostname validation can work.
openssl req -newkey rsa:2048 -nodes -subj "/CN=$SRV_CN" \
    -keyout server.key -out server.csr >/dev/null 2>&1
cat > server.ext <<EXT
subjectAltName=DNS:$SRV_CN
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EXT
openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -days 60 \
    -extfile server.ext -out server.pem >/dev/null 2>&1

# Client certificate: CN is the identity ocserv will extract.
openssl req -newkey rsa:2048 -nodes -subj /CN=testuser \
    -keyout client.key -out client.csr >/dev/null 2>&1
cat > client.ext <<EXT
keyUsage=digitalSignature
extendedKeyUsage=clientAuth
EXT
openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -days 60 \
    -extfile client.ext -out client.pem >/dev/null 2>&1

cat client.pem client.key > client-combined.pem
openssl rsa -in client.key -aes256 -passout pass:keypw -out client.enc.key >/dev/null 2>&1
openssl pkcs12 -export -inkey client.key -in client.pem -certfile ca.pem \
    -passout pass:p12pass -out client.p12 >/dev/null 2>&1

# A self-signed certificate the test CA never signed: must be refused.
openssl req -x509 -newkey rsa:2048 -nodes -days 60 -subj /CN=rogue \
    -keyout rogue.key -out rogue.pem >/dev/null 2>&1
cat rogue.pem rogue.key > rogue-combined.pem

# An already-expired client certificate, for the doctor's validity check.
openssl req -x509 -newkey rsa:2048 -nodes -subj /CN=expired-client \
    -not_before 20200101000000Z -not_after 20200201000000Z \
    -keyout expired.key -out expired.pem >/dev/null 2>&1 || true

: > empty.pem

# The public-key pin openconnect accepts via --servercert.
{
  printf 'pin-sha256:'
  openssl x509 -in server.pem -pubkey -noout \
    | openssl pkey -pubin -outform der \
    | openssl dgst -sha256 -binary | base64 | tr -d '\n'
  printf '\n'
} > server.pin

rm -f server.csr client.csr server.ext client.ext
# Readable by the unprivileged-ish contexts that mount this directory.
chmod 644 ./*.pem ./*.key ./*.p12 ./*.pin 2>/dev/null || true

for f in ca.pem server.pem server.key client.pem client.key client-combined.pem \
         client.enc.key client.p12 rogue-combined.pem server.pin; do
    [ -s "$f" ] || { echo "failed to generate $f" >&2; exit 1; }
done
echo "generated test PKI in $OUT (server CN=$SRV_CN)"
