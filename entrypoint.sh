#!/bin/sh
# openconnect supervisor for MikroTik RouterOS containers.
# POSIX sh only: must run under both busybox ash (Alpine) and dash (Debian).
set -eu

log() { echo "*** $*"; }
warn() { echo "!! $*" >&2; }
die() { echo "!! $*" >&2; exit 1; }

# ===========================================================================
# ANYCONNECT_SERVER: bare host or full URL
# ===========================================================================
# All of these are accepted:
#
#   vpn.example.com
#   vpn.example.com:4443
#   https://vpn.example.com
#   https://connect.poihali.space/?route=kizhi-canyon-8ww4ht
#   https://user:pass@vpn.example.com:4443/group?x=1#ignored
#   https://[2001:db8::1]:4443/group
#
# The URL is split into SRV_* and reassembled into SRV_URL, which is what
# openconnect receives. openconnect keeps everything after the host as its
# "urlpath" and sends it on the initial request, so a selector such as
# ?route=kizhi-canyon-8ww4ht reaches the server intact.
#
# Parsing rather than passing the string straight through, because:
#   - the DNS readiness wait needs the bare hostname; getent cannot resolve
#     "https://host/?route=x"
#   - credentials embedded in the URL can fill ANYCONNECT_USER/_PASSWORD, so
#     a single variable can carry the whole configuration
#   - the parts get logged, which makes a malformed URL obvious in the log
# ===========================================================================

# Percent-decoding, applied only to the userinfo part of a URL: a password of
# "p@ss/word" must be written "p%40ss%2Fword" or it would break parsing.
# Hex is decoded by hand so this works on busybox awk, mawk and gawk alike.
pct_decode() {
    printf '%s' "$1" | awk '
    BEGIN { hex = "0123456789abcdef" }
    {
        out = ""
        while (match($0, /%[0-9A-Fa-f][0-9A-Fa-f]/)) {
            out = out substr($0, 1, RSTART - 1)
            h = tolower(substr($0, RSTART + 1, 2))
            hi = index(hex, substr(h, 1, 1)) - 1
            lo = index(hex, substr(h, 2, 1)) - 1
            out = out sprintf("%c", hi * 16 + lo)
            $0 = substr($0, RSTART + 3)
        }
        printf "%s", out $0
    }'
}

# parse_server <string>
# Sets SRV_SCHEME SRV_USER SRV_PASS SRV_HOST SRV_PORT SRV_PATH SRV_QUERY SRV_URL
parse_server() {
    _raw="$1"
    [ -n "$_raw" ] || die "ANYCONNECT_SERVER is empty"

    # --- scheme. Only "://" introduces one, so "host:443" stays a host. ---
    case "$_raw" in
        *://*) SRV_SCHEME=$(printf '%s' "${_raw%%://*}" | tr 'A-Z' 'a-z')
               _rest=${_raw#*://} ;;
        *)     SRV_SCHEME=https
               _rest=$_raw ;;
    esac
    case "$SRV_SCHEME" in
        https) ;;
        http)  log "WARNING: http:// given, openconnect speaks TLS only -> using https://"
               SRV_SCHEME=https ;;
        *)     die "unsupported scheme '$SRV_SCHEME://' in ANYCONNECT_SERVER (use https://)" ;;
    esac

    # --- fragment: client-side only, never sent ---------------------------
    _rest=${_rest%%\#*}

    # --- query ------------------------------------------------------------
    case "$_rest" in
        *\?*) SRV_QUERY=${_rest#*\?}; _base=${_rest%%\?*} ;;
        *)    SRV_QUERY=""          ; _base=$_rest        ;;
    esac

    # --- path -------------------------------------------------------------
    case "$_base" in
        */*) SRV_PATH=${_base#*/}; _auth=${_base%%/*} ;;
        *)   SRV_PATH=""         ; _auth=$_base       ;;
    esac

    # --- userinfo: split at the LAST '@' so a literal '@' in a password
    #     still lands on the correct side -------------------------------
    case "$_auth" in
        *@*) _userinfo=${_auth%@*}; _hostport=${_auth##*@} ;;
        *)   _userinfo=""         ; _hostport=$_auth       ;;
    esac
    case "$_userinfo" in
        *:*) SRV_USER=$(pct_decode "${_userinfo%%:*}")
             SRV_PASS=$(pct_decode "${_userinfo#*:}") ;;
        *)   SRV_USER=$(pct_decode "$_userinfo")
             SRV_PASS="" ;;
    esac

    # --- host / port, including bracketed IPv6 literals -------------------
    case "$_hostport" in
        \[*\]:*) _h=${_hostport%%\]:*}; SRV_HOST=${_h#\[}; SRV_PORT=${_hostport##*\]:} ;;
        \[*\])   _h=${_hostport%\]}   ; SRV_HOST=${_h#\[}; SRV_PORT=""                 ;;
        *:*)     SRV_HOST=${_hostport%:*}                ; SRV_PORT=${_hostport##*:}   ;;
        *)       SRV_HOST=$_hostport                     ; SRV_PORT=""                 ;;
    esac

    [ -n "$SRV_HOST" ] || die "could not find a hostname in ANYCONNECT_SERVER='$_raw'"
    case "$SRV_PORT" in
        "")       ;;
        *[!0-9]*) die "invalid port '$SRV_PORT' in ANYCONNECT_SERVER='$_raw'" ;;
        *) [ "$SRV_PORT" -ge 1 ] && [ "$SRV_PORT" -le 65535 ] \
               || die "port out of range: '$SRV_PORT'" ;;
    esac

    # --- reassemble -------------------------------------------------------
    case "$SRV_HOST" in
        *:*) _hb="[$SRV_HOST]" ;;   # re-bracket IPv6
        *)   _hb="$SRV_HOST"   ;;
    esac
    SRV_URL="$SRV_SCHEME://$_hb"
    [ -n "$SRV_PORT" ] && SRV_URL="$SRV_URL:$SRV_PORT"
    # Append "/..." only when there is something to append, so a bare host
    # produces byte-for-byte the request openconnect made before.
    if [ -n "$SRV_PATH" ] || [ -n "$SRV_QUERY" ]; then
        SRV_URL="$SRV_URL/$SRV_PATH"
        [ -n "$SRV_QUERY" ] && SRV_URL="$SRV_URL?$SRV_QUERY"
    fi
    return 0
}

# ===========================================================================
# Client certificate material
# ===========================================================================
# Each of ANYCONNECT_CERT / _SSLKEY / _CAFILE / _MCA_CERT / _MCA_KEY may be
# given either as a path (mount it with /container/mounts on RouterOS) or
# inline through the matching *_DATA variable. The inline form exists because
# a MikroTik can always set an environment variable, while mounting a file
# needs writable storage the device may not have.
#
# A *_DATA value may be:
#   - PEM text with real newlines
#   - PEM text with literal \n sequences (RouterOS env values are one line)
#   - base64 of either of the above, or of a binary PKCS#12
CRED_DIR=/tmp/oc-creds

# write_cred <content> <basename> -> prints the path it wrote
write_cred() {
    _content="$1"; _name="$2"
    mkdir -p "$CRED_DIR"
    chmod 700 "$CRED_DIR"
    _dest="$CRED_DIR/$_name"
    case "$_content" in
        *-----BEGIN*)
            # Turn literal backslash-n into real newlines. awk rather than
            # sed: busybox, mawk and gawk all agree on this, BSD sed does not.
            printf '%s' "$_content" | awk '{ gsub(/\\n/, "\n"); print }' > "$_dest"
            ;;
        *)
            # Not PEM, so assume base64 (a .p12 has no textual marker).
            printf '%s' "$_content" | tr -d ' \t\n\r' | base64 -d > "$_dest" 2>/dev/null \
                || die "could not decode $_name: not PEM and not valid base64"
            [ -s "$_dest" ] || die "could not decode $_name: decoded to an empty file"
            ;;
    esac
    chmod 600 "$_dest"
    printf '%s' "$_dest"
}

# A pkcs11:/tpmkey: URI is handed to openconnect untouched, not stat()ed.
is_cred_uri() {
    case "$1" in
        pkcs11:*|tpmkey:*|system:*) return 0 ;;
        *) return 1 ;;
    esac
}

# resolve_cred <path-value> <data-value> <basename> <label> -> prints the path
# Materialises the inline form when given, otherwise validates the path.
resolve_cred() {
    _path="$1"; _data="$2"; _name="$3"; _label="$4"
    if [ -n "$_data" ]; then
        [ -z "$_path" ] || die "$_label: set either the path or the *_DATA form, not both"
        write_cred "$_data" "$_name"
        return 0
    fi
    [ -n "$_path" ] || return 0
    if is_cred_uri "$_path"; then
        printf '%s' "$_path"
        return 0
    fi
    [ -e "$_path" ] || die "$_label: '$_path' does not exist (mount it into the container?)"
    [ -r "$_path" ] || die "$_label: '$_path' is not readable"
    [ -s "$_path" ] || die "$_label: '$_path' is empty"
    printf '%s' "$_path"
}

# read_secret_file <path> <label> -> prints contents minus one trailing newline
read_secret_file() {
    [ -r "$1" ] || die "$2: '$1' is not readable"
    _v=$(cat "$1"; printf x)
    _v=${_v%x}
    printf '%s' "${_v%"$(printf '\n')"}"
}

is_ip_literal() {
    case "$1" in
        *:*)                         return 0 ;;   # IPv6
        *[!0-9.]*)                   return 1 ;;
        [0-9]*.[0-9]*.[0-9]*.[0-9]*) return 0 ;;   # IPv4
        *)                           return 1 ;;
    esac
}

# ===========================================================================
# iptables backend probing
# ===========================================================================
# RouterOS kernels differ by device and version in which netfilter modules
# they expose:
#   - armv7 (hAP ac^2, RB4011, ...): nf_tables is typically ABSENT, while the
#     legacy xt_* / nf_conntrack modules are loaded -> legacy backend
#   - x86_64 CHR and RouterOS >= 7.21: nf_tables is usually present
# Presence of the binary proves nothing, so each candidate is tested by
# actually inserting and removing a rule in the nat table.
#
# Exports IPTABLES (binary) and IPTABLES_NAT_TARGET (MASQUERADE|SNAT|none)
# for vpnc-script, so the data plane never has to re-probe.
probe_iptables() {
    IPTABLES=""
    IPTABLES_NAT_TARGET="none"

    for _cand in iptables-legacy iptables-nft iptables; do
        command -v "$_cand" >/dev/null 2>&1 || continue
        # Can the nat table be read at all? Fails outright when the
        # iptable_nat module is missing.
        "$_cand" -t nat -L POSTROUTING -n >/dev/null 2>&1 || {
            log "  $_cand: nat table unavailable"
            continue
        }
        # -o lo is harmless and is removed again immediately.
        if "$_cand" -t nat -A POSTROUTING -o lo -j MASQUERADE >/dev/null 2>&1; then
            "$_cand" -t nat -D POSTROUTING -o lo -j MASQUERADE >/dev/null 2>&1 || true
            IPTABLES="$_cand"; IPTABLES_NAT_TARGET="MASQUERADE"
            log "  $_cand: nat OK, MASQUERADE supported"
            break
        fi
        if "$_cand" -t nat -A POSTROUTING -o lo -j SNAT --to-source 127.0.0.1 >/dev/null 2>&1; then
            "$_cand" -t nat -D POSTROUTING -o lo -j SNAT --to-source 127.0.0.1 >/dev/null 2>&1 || true
            IPTABLES="$_cand"; IPTABLES_NAT_TARGET="SNAT"
            log "  $_cand: nat OK, only SNAT supported (no MASQUERADE module)"
            break
        fi
        log "  $_cand: nat readable but no usable NAT target"
        [ -n "$IPTABLES" ] || IPTABLES="$_cand"
    done

    if [ -z "$IPTABLES" ]; then
        IPTABLES="iptables"
        warn "no working iptables backend found; forwarded traffic will NOT be"
        warn "NAT-ed and the VPN will drop it. Check that the RouterOS kernel"
        warn "exposes iptable_nat (run: /entrypoint.sh --doctor)."
    fi
    export IPTABLES IPTABLES_NAT_TARGET
}

# ===========================================================================
# Sub-commands
# ===========================================================================
PRINT_CMD=0
case "${1:-}" in
  --print-cmd)
    # Show the openconnect command line that the current environment would
    # produce, then exit. Connects to nothing; passphrases are redacted.
    PRINT_CMD=1
    ;;
  --parse|--parse-only)
    # Print the parse result and exit. Connects to nothing, masks the
    # password: safe to paste into a bug report.
    [ $# -ge 2 ] || die "usage: $0 --parse <server-or-url>"
    parse_server "$2"
    printf 'scheme = %s\nuser   = %s\npass   = %s\nhost   = %s\nport   = %s\npath   = %s\nquery  = %s\nurl    = %s\n' \
        "$SRV_SCHEME" "$SRV_USER" \
        "$([ -n "$SRV_PASS" ] && echo '<set>' || echo '')" \
        "$SRV_HOST" "$SRV_PORT" "$SRV_PATH" "$SRV_QUERY" "$SRV_URL"
    exit 0
    ;;
  --doctor)
    # Run this ON the router to find out what its kernel actually supports:
    #   /container/shell  (RouterOS 7.17+)  ->  /entrypoint.sh --doctor
    echo "=== openconnect-mikrotik doctor ==="
    echo "--- image ---"
    echo "distro:  $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
    echo "shell:   $(readlink -f /bin/sh 2>/dev/null || echo '?')"
    openconnect --version 2>&1 | head -2
    echo "--- kernel ---"
    uname -a
    echo "--- /dev/net/tun (required; openconnect cannot run without it) ---"
    if [ -c /dev/net/tun ]; then echo "OK: /dev/net/tun present"
    else echo "MISSING: /dev/net/tun -- RouterOS must expose it to the container"; fi
    echo "--- ip_forward ---"
    if sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1; then
        echo "OK: writable (= $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null))"
    else
        echo "FAIL: cannot set net.ipv4.ip_forward -- router traffic will not be forwarded"
    fi
    echo "--- netfilter modules seen by the kernel ---"
    grep -E 'nf_tables|nf_nat|iptable_nat|nf_conntrack|xt_|ipt_' /proc/modules 2>/dev/null \
        | awk '{print "  " $1}' | sort || echo "  (/proc/modules unreadable or modules built in)"
    echo "--- iptables backends ---"
    for c in iptables-legacy iptables-nft iptables; do
        if command -v "$c" >/dev/null 2>&1; then echo "  $c: $("$c" --version 2>&1 | head -1)"
        else echo "  $c: not installed"; fi
    done
    echo "--- NAT capability probe ---"
    probe_iptables
    echo "chosen: IPTABLES=$IPTABLES IPTABLES_NAT_TARGET=$IPTABLES_NAT_TARGET"
    echo "--- TLS backend / certificate features ---"
    _feat=$(openconnect --version 2>&1 | sed -n 's/^Using \(.*\)$/\1/p')
    echo "  $_feat"
    case "$_feat" in
        *PKCS#11*) echo "  PKCS#11: available (pkcs11: URIs usable for cert/key)" ;;
        *) echo "  PKCS#11: NOT available in this build -- a pkcs11: URI will fail."
           echo "           Use the :debian tag (GnuTLS) for hardware tokens." ;;
    esac
    echo "--- client certificate ---"
    if [ -z "${ANYCONNECT_CERT:-}${ANYCONNECT_CERT_DATA:-}" ]; then
        echo "  not configured (password authentication)"
    else
        if [ -n "${ANYCONNECT_CERT_DATA:-}" ]; then
            echo "  source: ANYCONNECT_CERT_DATA (inline)"
            _c=$(write_cred "${ANYCONNECT_CERT_DATA}" doctor-cert.pem 2>/dev/null) \
                && echo "  decoded OK -> $_c" || { echo "  DECODE FAILED"; _c=""; }
        else
            _c="${ANYCONNECT_CERT}"
            echo "  source: ANYCONNECT_CERT=$_c"
            if is_cred_uri "$_c"; then
                echo "  looks like a PKCS#11/TPM URI; passed through to openconnect"
                _c=""
            elif [ ! -e "$_c" ]; then echo "  MISSING: no such file (mount it into the container?)"; _c=""
            elif [ ! -r "$_c" ]; then echo "  UNREADABLE: check permissions"; _c=""
            elif [ ! -s "$_c" ]; then echo "  EMPTY FILE"; _c=""
            else echo "  file OK ($(wc -c <"$_c" | tr -d ' ') bytes)"; fi
        fi
        # An expired certificate is the classic silent cert-auth failure, so
        # show the validity window when openssl is available.
        if [ -n "$_c" ] && ! command -v openssl >/dev/null 2>&1; then
            echo "  (no openssl CLI in this image, so subject/dates are not shown here;"
            echo "   openconnect logs \"Client certificate expires soon\" when it connects)"
        fi
        if [ -n "$_c" ] && command -v openssl >/dev/null 2>&1; then
            if openssl x509 -in "$_c" -noout >/dev/null 2>&1; then
                openssl x509 -in "$_c" -noout -subject -issuer -dates 2>/dev/null | sed 's/^/  /'
                if openssl x509 -in "$_c" -noout -checkend 0 >/dev/null 2>&1; then
                    openssl x509 -in "$_c" -noout -checkend 2592000 >/dev/null 2>&1 \
                        && echo "  validity: OK" \
                        || echo "  validity: EXPIRES WITHIN 30 DAYS"
                else
                    echo "  validity: EXPIRED -- the server will reject this certificate"
                fi
            else
                echo "  not a PEM X.509 certificate (PKCS#12/.p12 is fine; openssl cannot"
                echo "  inspect it here without the passphrase)"
            fi
        fi
        _k="${ANYCONNECT_SSLKEY:-}"
        if [ -n "${ANYCONNECT_SSLKEY_DATA:-}" ]; then echo "  key: inline via ANYCONNECT_SSLKEY_DATA"
        elif [ -z "$_k" ]; then echo "  key: none given (expected inside the certificate or .p12)"
        elif is_cred_uri "$_k"; then echo "  key: URI $_k"
        elif [ -r "$_k" ]; then echo "  key: $_k OK"
        else echo "  key: $_k MISSING or UNREADABLE"; fi
        [ -n "${ANYCONNECT_KEY_PASSWORD:-}${ANYCONNECT_KEY_PASSWORD_FILE:-}" ] \
            && echo "  key passphrase: set" || echo "  key passphrase: not set"
    fi
    echo "--- DNS ---"
    cat /etc/resolv.conf 2>/dev/null | sed 's/^/  /' || echo "  no /etc/resolv.conf"
    if [ -n "${ANYCONNECT_SERVER:-}" ]; then
        parse_server "$ANYCONNECT_SERVER"
        echo "--- ANYCONNECT_SERVER ---"
        echo "  url  = $SRV_URL"
        echo "  host = $SRV_HOST"
        if getent hosts "$SRV_HOST" >/dev/null 2>&1; then
            echo "  resolve: OK -> $(getent hosts "$SRV_HOST" | awk '{print $1}' | tr '\n' ' ')"
        else
            echo "  resolve: FAILED"
        fi
    else
        echo "(set ANYCONNECT_SERVER to also test name resolution)"
    fi
    echo "=== end ==="
    exit 0
    ;;
  --help|-h)
    sed -n '1,40p' "$0" | grep -E '^#( |$)' | sed 's/^# \{0,1\}//'
    echo
    echo "Usage: entrypoint.sh [--parse <url> | --doctor | --help]"
    echo "With no arguments it connects, using the ANYCONNECT_* environment."
    exit 0
    ;;
esac

# ===========================================================================
# Configuration
# ===========================================================================
: "${ANYCONNECT_SERVER:?ANYCONNECT_SERVER is required}"

parse_server "$ANYCONNECT_SERVER"

# Credentials: explicit environment wins, URL userinfo is the fallback.
ANYCONNECT_USER="${ANYCONNECT_USER:-$SRV_USER}"
if [ -n "${ANYCONNECT_PASSWORD_FILE:-}" ]; then
    [ -r "$ANYCONNECT_PASSWORD_FILE" ] \
        || die "ANYCONNECT_PASSWORD_FILE '$ANYCONNECT_PASSWORD_FILE' is not readable"
    # Keep the content byte-exact apart from one trailing newline.
    ANYCONNECT_PASSWORD=$(cat "$ANYCONNECT_PASSWORD_FILE"; printf x)
    ANYCONNECT_PASSWORD=${ANYCONNECT_PASSWORD%x}
    ANYCONNECT_PASSWORD=${ANYCONNECT_PASSWORD%"$(printf '\n')"}
else
    ANYCONNECT_PASSWORD="${ANYCONNECT_PASSWORD:-$SRV_PASS}"
fi

# --- client certificate authentication --------------------------------------
# openconnect can authenticate with a certificate instead of, or alongside, a
# password, so neither a username nor a password is required any more.
CERT=$(resolve_cred   "${ANYCONNECT_CERT:-}"     "${ANYCONNECT_CERT_DATA:-}"     client.pem "ANYCONNECT_CERT")
SSLKEY=$(resolve_cred "${ANYCONNECT_SSLKEY:-}"   "${ANYCONNECT_SSLKEY_DATA:-}"   client.key "ANYCONNECT_SSLKEY")
CAFILE=$(resolve_cred "${ANYCONNECT_CAFILE:-}"   "${ANYCONNECT_CAFILE_DATA:-}"   ca.pem     "ANYCONNECT_CAFILE")
MCA_CERT=$(resolve_cred "${ANYCONNECT_MCA_CERT:-}" "${ANYCONNECT_MCA_CERT_DATA:-}" mca.pem  "ANYCONNECT_MCA_CERT")
MCA_KEY=$(resolve_cred  "${ANYCONNECT_MCA_KEY:-}"  "${ANYCONNECT_MCA_KEY_DATA:-}"  mca.key  "ANYCONNECT_MCA_KEY")

if [ -n "${ANYCONNECT_KEY_PASSWORD_FILE:-}" ]; then
    ANYCONNECT_KEY_PASSWORD=$(read_secret_file "$ANYCONNECT_KEY_PASSWORD_FILE" ANYCONNECT_KEY_PASSWORD_FILE)
else
    ANYCONNECT_KEY_PASSWORD="${ANYCONNECT_KEY_PASSWORD:-}"
fi
ANYCONNECT_MCA_KEY_PASSWORD="${ANYCONNECT_MCA_KEY_PASSWORD:-}"
ANYCONNECT_AUTHGROUP="${ANYCONNECT_AUTHGROUP:-}"

[ -z "$SSLKEY" ] || [ -n "$CERT" ] \
    || die "ANYCONNECT_SSLKEY without ANYCONNECT_CERT: a key alone cannot authenticate"
[ -z "$ANYCONNECT_KEY_PASSWORD" ] || [ -n "$CERT" ] \
    || die "ANYCONNECT_KEY_PASSWORD is set but no certificate was given"
[ -z "$MCA_KEY" ] || [ -n "$MCA_CERT" ] \
    || die "ANYCONNECT_MCA_KEY without ANYCONNECT_MCA_CERT"

# Which authentication is in play. A certificate alone is enough; so is a
# password; servers that want both get both.
if [ -n "$CERT" ] && [ -n "$ANYCONNECT_PASSWORD" ]; then
    AUTH_MODE="certificate + password"
elif [ -n "$CERT" ]; then
    AUTH_MODE="certificate"
elif [ -n "$ANYCONNECT_PASSWORD" ]; then
    AUTH_MODE="password"
else
    die "no credentials: set ANYCONNECT_CERT (certificate auth), or ANYCONNECT_PASSWORD / ANYCONNECT_PASSWORD_FILE, or embed them in the ANYCONNECT_SERVER URL"
fi

# A username is required for password auth; with a certificate the identity
# usually comes from the certificate itself, so it stays optional.
[ -n "$ANYCONNECT_USER" ] || [ -n "$CERT" ] \
    || die "no username: set ANYCONNECT_USER or embed it in the ANYCONNECT_SERVER URL"

ANYCONNECT_OPTIONS="${ANYCONNECT_OPTIONS:-}"
ANYCONNECT_PROTOCOL="${ANYCONNECT_PROTOCOL:-anyconnect}"
ANYCONNECT_SERVERCERT="${ANYCONNECT_SERVERCERT:-}"
ANYCONNECT_NONINTER="${ANYCONNECT_NONINTER:-0}"
ANYCONNECT_TIMESTAMP="${ANYCONNECT_TIMESTAMP:-1}"
RECONNECT_DELAY="${RECONNECT_DELAY:-5}"
DNS_WAIT="${DNS_WAIT:-60}"
export ANYCONNECT_VPN_DNS="${ANYCONNECT_VPN_DNS:-0}"
export ANYCONNECT_MTU="${ANYCONNECT_MTU:-1412}"

# Build argv once, in "$@": the only way to keep quoting exact in POSIX sh.
# Built before the loop because it never varies between reconnect attempts.
set -- --protocol="$ANYCONNECT_PROTOCOL" --script=/etc/vpnc/vpnc-script
[ -n "$ANYCONNECT_USER" ] && set -- "$@" --user="$ANYCONNECT_USER"
# --passwd-on-stdin only when there IS a password: with certificate-only auth
# it would make openconnect read a password that never arrives.
[ -n "$ANYCONNECT_PASSWORD" ] && set -- "$@" --passwd-on-stdin
[ -n "$CERT" ]      && set -- "$@" --certificate="$CERT"
[ -n "$SSLKEY" ]    && set -- "$@" --sslkey="$SSLKEY"
[ -n "$CAFILE" ]    && set -- "$@" --cafile="$CAFILE"
[ -n "$MCA_CERT" ]  && set -- "$@" --mca-certificate="$MCA_CERT"
[ -n "$MCA_KEY" ]   && set -- "$@" --mca-key="$MCA_KEY"
# NOTE: openconnect has no way to read a key passphrase from stdin, so these
# have to go in argv, where `ps` inside the container can see them. Prefer an
# unencrypted key file with mode 600 on a single-purpose router container, or
# keep the passphrase in ANYCONNECT_KEY_PASSWORD_FILE so at least it is not
# visible in /container/envs print.
[ -n "$ANYCONNECT_KEY_PASSWORD" ]     && set -- "$@" --key-password="$ANYCONNECT_KEY_PASSWORD"
[ -n "$ANYCONNECT_MCA_KEY_PASSWORD" ] && set -- "$@" --mca-key-password="$ANYCONNECT_MCA_KEY_PASSWORD"
[ -n "$ANYCONNECT_AUTHGROUP" ]   && set -- "$@" --authgroup="$ANYCONNECT_AUTHGROUP"
[ -n "$ANYCONNECT_SERVERCERT" ]  && set -- "$@" --servercert="$ANYCONNECT_SERVERCERT"
[ "$ANYCONNECT_NONINTER" = "1" ]  && set -- "$@" --non-inter
[ "$ANYCONNECT_TIMESTAMP" = "1" ] && set -- "$@" --timestamp
# Unquoted on purpose: ANYCONNECT_OPTIONS carries several words.
# shellcheck disable=SC2086
set -- "$@" ${ANYCONNECT_OPTIONS} "$SRV_URL"

if [ "$PRINT_CMD" = "1" ]; then
    # Print the command line that would be run, with passphrases redacted.
    printf 'openconnect'
    for _a in "$@"; do
        case "$_a" in
            --key-password=*|--mca-key-password=*) printf " %s=<redacted>" "${_a%%=*}" ;;
            *) printf " '%s'" "$_a" ;;
        esac
    done
    printf '\n'
    exit 0
fi

# Корректный выход по SIGTERM/SIGINT (MikroTik шлёт SIGTERM при /container/stop),
# иначе цикл реконнекта не даст контейнеру остановиться.
running=1
oc_pid=""
sleep_pid=""
on_signal() {
    running=0
    log "signal received, stopping..."
    # Never "kill 0" here: that signals the whole process group, this script
    # included, turning a clean shutdown into a self-kill.
    [ -n "$oc_pid" ]    && kill -TERM "$oc_pid"    2>/dev/null || true
    [ -n "$sleep_pid" ] && kill -TERM "$sleep_pid" 2>/dev/null || true
}
trap on_signal TERM INT

# Interruptible sleep: backgrounded so a SIGTERM during the delay is acted on
# at once instead of waiting the delay out.
nap() {
    sleep "$1" & sleep_pid=$!
    wait "$sleep_pid" 2>/dev/null || true
    sleep_pid=""
}

log "start"
log "server url  = $SRV_URL"
log "server host = $SRV_HOST${SRV_PORT:+ (port $SRV_PORT)}"
[ -n "$SRV_PATH" ]  && log "url path    = /$SRV_PATH"
[ -n "$SRV_QUERY" ] && log "url query   = ?$SRV_QUERY"
log "protocol    = $ANYCONNECT_PROTOCOL"
log "auth        = $AUTH_MODE"
[ -n "$ANYCONNECT_USER" ] && log "user        = $ANYCONNECT_USER"
[ -n "$CERT" ]   && log "certificate = $CERT"
[ -n "$SSLKEY" ] && log "private key = $SSLKEY"
[ -n "$CAFILE" ] && log "server CA   = $CAFILE"
ip -o a || true

[ -c /dev/net/tun ] || warn "/dev/net/tun is missing -- openconnect will fail to start a tunnel"

# Разрешаем IP-форвардинг, чтобы пакеты, прилетающие от MikroTik по veth-tun,
# уходили в tun0 (и обратно). Это даёт маршрут router -> 10.10.10.x через контейнер.
sysctl -w net.ipv4.ip_forward=1 >/dev/null 2>&1 || warn "could not enable ip_forward"
log "ip_forward = $(cat /proc/sys/net/ipv4/ip_forward 2>/dev/null || echo '?')"

log "probing iptables backends..."
probe_iptables
log "using $IPTABLES (nat target: $IPTABLES_NAT_TARGET)"

# Ждём готовности DNS до DNS_WAIT секунд. Нужно из-за race condition в MikroTik:
# namespace/veth поднимаются раньше, чем DNS становится доступен.
if is_ip_literal "$SRV_HOST"; then
    log "$SRV_HOST is an IP literal, skipping DNS wait"
else
    log "waiting up to ${DNS_WAIT}s for DNS to resolve $SRV_HOST..."
    i=0
    resolved=0
    while [ "$i" -lt "$DNS_WAIT" ] && [ "$running" -eq 1 ]; do
        if getent hosts "$SRV_HOST" >/dev/null 2>&1; then
            log "DNS ready after ${i}s"
            resolved=1
            break
        fi
        i=$((i + 1))
        nap 1
    done
    [ "$running" -eq 1 ] || { log "stopped while waiting for DNS"; exit 0; }
    [ "$resolved" -eq 1 ] || die "DNS did not become ready after ${DNS_WAIT}s, giving up"
fi

# Пароль уходит в openconnect через fd 3, указывающий на уже удалённый файл:
# пароль не остаётся на диске, не виден в ps и в argv, и -- в отличие от пайпа --
# $! гарантированно равен pid самого openconnect, а не последнего звена пайпа.
open_password_fd() {
    _pw=$(mktemp /tmp/.oc-pw.XXXXXX)
    chmod 600 "$_pw"
    printf '%s\n' "$ANYCONNECT_PASSWORD" >"$_pw"
    exec 3<"$_pw"
    rm -f "$_pw"
}

while [ "$running" -eq 1 ]; do
    log "launching openconnect -> $SRV_URL"

    if [ -n "$ANYCONNECT_PASSWORD" ]; then
        open_password_fd
    else
        # Certificate-only auth: nothing to feed, and stdin must not be a
        # terminal or an unexpected prompt would block forever.
        exec 3</dev/null
    fi

    openconnect "$@" <&3 &
    oc_pid=$!
    exec 3<&-

    # `wait ... || true` would collapse the status into 0 and make every exit
    # look clean, so capture it before falling back.
    rc=0
    wait "$oc_pid" 2>/dev/null || rc=$?
    oc_pid=""

    if [ "$running" -eq 0 ]; then
        log "openconnect stopped (rc=$rc), exiting on signal"
        exit 0
    fi

    log "openconnect exited with rc=$rc, reconnecting in ${RECONNECT_DELAY}s"
    nap "$RECONNECT_DELAY"
done
