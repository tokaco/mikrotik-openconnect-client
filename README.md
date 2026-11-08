# openconnect-mikrotik

An [OpenConnect](https://www.infradead.org/openconnect/) VPN client packaged to
run as a **MikroTik RouterOS container**, so a router can send selected traffic
through an AnyConnect / Cisco SSL VPN without any client on the LAN devices.

Images are built automatically for `linux/amd64`, `linux/arm64` and
`linux/arm/v7` and published to GitHub Container Registry, so RouterOS can pull
them directly.

```
ghcr.io/tokaco/openconnect-mikrotik:latest
```

## Tags

| Tag | Base | Size | When to use |
|---|---|---|---|
| `latest`, `alpine` | Alpine 3.22 | ~61 MB (~14 MB download) | Default. Matters on devices such as the hAP ac² with 128 MB of flash. |
| `debian` | Debian 13 (trixie) | ~264 MB | Fallback if the Alpine image misbehaves on your RouterOS build, and the only variant with **PKCS#11** (hardware tokens). Same lineage as the original image this repo replaces. |
| `alpine-armv7`, `debian-arm64`, … | | | Pin one architecture explicitly if your RouterOS version mishandles multi-arch manifest lists. |
| `v1.2.3` | Alpine | | Immutable release tags (`v1.2.3-debian` for the Debian variant). |

Both variants ship **the same** `entrypoint.sh`, `vpnc-script` and environment
variables; only the base distro differs.

## `ANYCONNECT_SERVER` accepts a full URL

The server can be given as a bare host *or* as a complete URL, so a single
variable can carry a server, a port, a path, a selector and even credentials:

```sh
vpn.example.com
vpn.example.com:4443
https://vpn.example.com
https://connect.example.com/?route=vpn
https://user:pass@vpn.example.com:4443/group?x=1
https://[2001:db8::1]:4443/group
```


Notes:

- Only `https` is meaningful; `http://` is accepted with a warning and upgraded.
- Credentials in the URL are used only when `ANYCONNECT_USER` /
  `ANYCONNECT_PASSWORD` are not set, and they are **stripped** from the URL
  handed to OpenConnect.
- Percent-encode special characters in credentials: `p@ss/word` →
  `p%40ss%2Fword`.
- The fragment (`#...`) is dropped, as in any browser.

Check how a URL will be interpreted without connecting to anything:

```console
$ docker run --rm ghcr.io/tokaco/openconnect-mikrotik:latest \
      --parse 'https://connect.example.com/?route=vpn'
scheme = https
user   =
pass   =
host   = connect.example.com
port   =
path   =
query  = route=vpn
url    = https://connect.example.com/?route=vpn
```

## Certificate authentication

OpenConnect can authenticate with a client certificate instead of, or in
addition to, a password. Set `ANYCONNECT_CERT` and neither a username nor a
password is required.

```routeros
/container/envs/add name=vpn key=ANYCONNECT_SERVER value="https://vpn.example.com/"
/container/envs/add name=vpn key=ANYCONNECT_CERT   value="/certs/client.pem"
```

The certificate may be:

- **PEM with the key appended** — one file, nothing else needed.
- **PEM plus a separate key** — add `ANYCONNECT_SSLKEY`.
- **PKCS#12 / `.p12`** — add `ANYCONNECT_KEY_PASSWORD` for its passphrase.
- **A `pkcs11:` URI** for a hardware token — **only on the `:debian` tag**; the
  Alpine build links OpenSSL without PKCS#11. `--doctor` says which you have.

If the key is encrypted, give the passphrase with `ANYCONNECT_KEY_PASSWORD`, or
better `ANYCONNECT_KEY_PASSWORD_FILE` so it stays out of
`/container/envs print`.

### Supplying the certificate without a mount

Mounting a file into a RouterOS container needs writable storage the device may
not have, so every file variable has an inline `*_DATA` twin that accepts the
material through the environment instead. It is written to `/tmp/oc-creds`
with mode `600` at startup.

`ANYCONNECT_CERT_DATA` accepts PEM text, PEM with literal `\n` sequences
(RouterOS environment values are a single line), or base64 of either — or of a
binary `.p12`:

```sh
# base64 is usually easiest to paste into a RouterOS env value
base64 -w0 client.pem
```

```routeros
/container/envs/add name=vpn key=ANYCONNECT_CERT_DATA value="LS0tLS1CRUdJTi..."
```

The same applies to `ANYCONNECT_SSLKEY_DATA`, `ANYCONNECT_CAFILE_DATA`,
`ANYCONNECT_MCA_CERT_DATA` and `ANYCONNECT_MCA_KEY_DATA`. Give either the path
or the `*_DATA` form for a given item, not both.

### Checking the configuration

`--print-cmd` shows the exact OpenConnect command line your environment
produces, with passphrases redacted and without connecting:

```console
$ docker run --rm -e ANYCONNECT_SERVER=https://vpn.example.com/ \
      -e ANYCONNECT_CERT=/certs/client.p12 -e ANYCONNECT_KEY_PASSWORD=secret \
      -v "$PWD/certs:/certs:ro" ghcr.io/tokaco/openconnect-mikrotik:latest --print-cmd
openconnect '--protocol=anyconnect' '--script=/etc/vpnc/vpnc-script' \
  '--certificate=/certs/client.p12' --key-password=<redacted> '--timestamp' \
  'https://vpn.example.com/'
```

`--doctor` reports whether the certificate is present, readable and decodable.
The `:debian` variant also prints its subject and validity window; the Alpine
image omits the `openssl` CLI because it measured +9.4 MB on disk and +3 MB of
download, and OpenConnect already logs `Client certificate expires soon at: …`
when it connects (tune with `ANYCONNECT_OPTIONS=--cert-expire-warning=30`).

> **One caveat.** OpenConnect has no way to read a *key passphrase* from stdin,
> so `--key-password` must go in the command line, where `ps` inside the
> container can see it. The account password does not: it is passed on a file
> descriptor. On a single-purpose router container this is usually acceptable;
> if it is not, use an unencrypted key file with mode `600` instead.

## Environment variables

| Variable | Default | Meaning |
|---|---|---|
| `ANYCONNECT_SERVER` | *required* | Host or full URL (see above). |
| `ANYCONNECT_USER` | from URL | Username. Required for password auth; optional with a certificate. |
| `ANYCONNECT_PASSWORD` | from URL | Password. Not needed when `ANYCONNECT_CERT` is set. |
| `ANYCONNECT_PASSWORD_FILE` | — | Read the password from a file instead; takes precedence over `ANYCONNECT_PASSWORD`. Keeps it out of `/container/envs print`. |
| `ANYCONNECT_PROTOCOL` | `anyconnect` | Any protocol OpenConnect supports: `anyconnect`, `nc`, `gp`, `pulse`, `f5`, `fortinet`, `array`. |
| `ANYCONNECT_OPTIONS` | — | Extra OpenConnect flags, split on whitespace. |
| `ANYCONNECT_SERVERCERT` | — | Pin the server certificate (`pin-sha256:…`). Use this instead of trusting whatever is presented. |
| `ANYCONNECT_NONINTER` | `0` | `1` adds `--non-inter`: fail fast instead of blocking on a prompt. Recommended once the setup works. |
| `ANYCONNECT_TIMESTAMP` | `1` | Prefix OpenConnect log lines with a timestamp. |
| `ANYCONNECT_MTU` | `1412` | Fallback MTU when the server does not push one. |
| `ANYCONNECT_VPN_DNS` | `0` | `1` writes the VPN-pushed DNS servers into the container's `/etc/resolv.conf`. **See the caveat below.** |
| `ANYCONNECT_CERT` | — | Client certificate: PEM, PKCS#12, or a `pkcs11:` URI. Enables certificate auth. |
| `ANYCONNECT_SSLKEY` | — | Private key, when it is not inside `ANYCONNECT_CERT`. |
| `ANYCONNECT_KEY_PASSWORD` | — | Passphrase for an encrypted key or `.p12`. |
| `ANYCONNECT_KEY_PASSWORD_FILE` | — | Read that passphrase from a file instead. |
| `ANYCONNECT_CAFILE` | — | CA bundle used to verify the **server**. |
| `ANYCONNECT_AUTHGROUP` | — | Tunnel group / authentication group to select. |
| `ANYCONNECT_MCA_CERT`, `ANYCONNECT_MCA_KEY`, `ANYCONNECT_MCA_KEY_PASSWORD` | — | Secondary certificate for AnyConnect multiple-certificate auth. |
| `ANYCONNECT_*_DATA` | — | Inline form of `CERT`, `SSLKEY`, `CAFILE`, `MCA_CERT`, `MCA_KEY`: PEM text, PEM with literal `\n`, or base64. |
| `RECONNECT_DELAY` | `5` | Seconds to wait before reconnecting. |
| `DNS_WAIT` | `60` | Seconds to wait for DNS to come up before giving up at startup. |

## Setting it up on RouterOS

Container support must be enabled first; this reboots the router.

```routeros
/system/device-mode/update container=yes
```

Give the container a veth and a way out to the internet:

```routeros
/interface/veth/add name=veth-vpn address=172.17.0.2/24 gateway=172.17.0.1
/interface/bridge/add name=bridge-vpn
/interface/bridge/port/add bridge=bridge-vpn interface=veth-vpn
/ip/address/add address=172.17.0.1/24 interface=bridge-vpn
/ip/firewall/nat/add chain=srcnat action=masquerade src-address=172.17.0.0/24
```

Point RouterOS at GHCR and define the environment:

```routeros
/container/config/set registry-url=https://ghcr.io tmpdir=usb1/pull

/container/envs/add name=vpn key=ANYCONNECT_SERVER \
    value="https://connect.example.com/?route=vpn"
/container/envs/add name=vpn key=ANYCONNECT_USER     value="myuser"
/container/envs/add name=vpn key=ANYCONNECT_PASSWORD value="mypassword"
```

Create and start the container:

```routeros
/container/add \
    remote-image=tokaco/openconnect-mikrotik:latest \
    interface=veth-vpn \
    envlist=vpn \
    root-dir=usb1/openconnect \
    logging=yes \
    start-on-boot=yes

/container/start [find remote-image~"openconnect"]
/log/print where topics~"container"
```

Then route the traffic you want through the container. For example, send one
address list through the VPN with policy routing:

```routeros
/routing/table/add name=via-vpn fib
/ip/route/add dst-address=0.0.0.0/0 gateway=172.17.0.2 routing-table=via-vpn
/ip/firewall/mangle/add chain=prerouting action=mark-routing \
    new-routing-mark=via-vpn passthrough=no \
    src-address-list=via-vpn
/ip/firewall/address-list/add list=via-vpn address=192.168.88.50
```

The container answers for whatever the VPN assigned it, and NATs forwarded
traffic to that address, so the LAN needs no changes.

## Troubleshooting: `--doctor`

RouterOS kernels differ by device and version in which netfilter modules they
expose, which is the usual reason a container VPN *connects* but carries no
traffic. `--doctor` reports exactly what the router's kernel offers:

```routeros
/container/shell [find remote-image~"openconnect"]
```

```console
# /entrypoint.sh --doctor
=== openconnect-mikrotik doctor ===
--- /dev/net/tun (required; openconnect cannot run without it) ---
OK: /dev/net/tun present
--- ip_forward ---
OK: writable (= 1)
--- NAT capability probe ---
  iptables-legacy: nat OK, MASQUERADE supported
chosen: IPTABLES=iptables-legacy IPTABLES_NAT_TARGET=MASQUERADE
```

It also resolves `ANYCONNECT_SERVER` and prints the parsed URL, so a
misconfigured selector is obvious.

| Symptom | Likely cause |
|---|---|
| `MISSING: /dev/net/tun` | RouterOS is not exposing the TUN device to the container. |
| `IPTABLES_NAT_TARGET=none` | The kernel has no `iptable_nat`. Traffic reaches the VPN with a private source address and is dropped. |
| `FAIL: cannot set net.ipv4.ip_forward` | `/proc/sys` is not writable; forwarded traffic will not pass. |
| Tunnel connects, then drops in a loop | Often certificate verification. Set `ANYCONNECT_SERVERCERT`, and check the router's clock. |

## Design notes

Three decisions are deliberate and worth knowing before changing them.

**The iptables backend is probed at runtime, not fixed at build time.** On
armv7 devices (hAP ac², RB4011) RouterOS typically does *not* load `nf_tables`,
while the legacy `xt_*` modules are present; x86 CHR and RouterOS 7.21+ usually
do have `nf_tables`. The original image hard-coded
`update-alternatives --set iptables iptables-legacy`. Instead, `entrypoint.sh`
tries `iptables-legacy`, then `iptables-nft`, by actually inserting and removing
a rule in the `nat` table, and exports the winner to `vpnc-script`. Presence of
the binary proves nothing; only inserting a rule does.

**VPN-pushed DNS is off by default.** The container's `/etc/resolv.conf` is used
for one thing: resolving the VPN server itself. Pointing it at a nameserver that
lives *inside* the tunnel means that when the tunnel drops, the server hostname
can no longer be resolved and the reconnect loop can never recover. RouterOS
serves DNS to the LAN anyway. Set `ANYCONNECT_VPN_DNS=1` only if you need to
resolve names that exist solely inside the VPN.

**The VPN gateway is pinned to the original uplink.** Before installing a
default route through `tun0`, `vpnc-script` adds a host route to the VPN server
via the pre-existing gateway. Without it, OpenConnect's own TLS socket would be
routed into the tunnel it is carrying, and the connection would collapse.

## Development

```sh
# URL parser, 39 cases -- runs under dash and busybox ash
sh tests/test-urlparse.sh ./entrypoint.sh

# Build and test locally
docker build -t ocmt:alpine -f Dockerfile .
docker build -t ocmt:debian -f Dockerfile.debian .

# Data-plane test: real tun device, real routes, real NAT rules
docker run --rm --cap-add NET_ADMIN --device /dev/net/tun \
    -v "$PWD/tests:/tests:ro" --entrypoint /bin/sh \
    ocmt:alpine /tests/test-vpnc-script.sh

# Certificate auth. The PKI is generated separately because the Alpine image
# ships without the openssl CLI; any image that has it will do.
CERTS=$(mktemp -d)
docker run --rm -v "$PWD/tests:/tests:ro" -v "$CERTS:/out" \
    --entrypoint /bin/sh ocmt:debian /tests/gen-test-certs.sh /out
docker run --rm -v "$PWD/tests:/tests:ro" -v "$CERTS:/certs:ro" \
    --entrypoint /bin/sh ocmt:alpine /tests/test-certauth.sh /entrypoint.sh /certs

# End-to-end: a real ocserv with certificate-only auth, a real tunnel
sh tests/test-e2e-certauth.sh ocmt:alpine

# Lint exactly as CI does
docker run --rm -v "$PWD:/mnt:ro" koalaman/shellcheck:stable \
    --shell=sh --severity=warning entrypoint.sh vpnc-script tests/*.sh
```

Both scripts are POSIX `sh` and must stay compatible with busybox ash *and*
dash; CI runs the parser tests under both, and the end-to-end test brings up an
actual ocserv so certificate auth is verified against a real server rather than
by inspecting flags.

## License

[MIT](LICENSE) for the scripts in this repository. The packaged software keeps
its own licenses — OpenConnect is LGPL-2.1.
