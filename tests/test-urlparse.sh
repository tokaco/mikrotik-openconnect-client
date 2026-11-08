#!/bin/sh
# URL-parsing tests for entrypoint.sh --parse.
# Run under whatever /bin/sh is: the parser must behave identically on
# busybox ash (Alpine) and dash (Debian).
#
#   sh tests/test-urlparse.sh [path-to-entrypoint.sh]
set -u

EP="${1:-$(dirname "$0")/../entrypoint.sh}"
[ -x "$EP" ] || { echo "not executable: $EP" >&2; exit 1; }

pass=0; fail=0

# field <output> <name>  -> value of that field
field() { printf '%s\n' "$1" | awk -v k="$2" '$1==k { sub(/^[^=]*= ?/, ""); print; exit }'; }

# ok <url> <field> <expected>
ok() {
    _out=$(sh "$EP" --parse "$1" 2>&1) || {
        printf 'FAIL  %-58s  parse errored: %s\n' "$1" "$_out"; fail=$((fail+1)); return
    }
    _got=$(field "$_out" "$2")
    if [ "$_got" = "$3" ]; then
        pass=$((pass+1))
    else
        printf 'FAIL  %-58s  %s: expected [%s] got [%s]\n' "$1" "$2" "$3" "$_got"
        fail=$((fail+1))
    fi
}

# bad <url> <substring-of-error>
bad() {
    if _out=$(sh "$EP" --parse "$1" 2>&1); then
        printf 'FAIL  %-58s  expected rejection, got: %s\n' "$1" "$(echo "$_out" | tr '\n' ' ')"
        fail=$((fail+1))
    else
        case "$_out" in
            *"$2"*) pass=$((pass+1)) ;;
            *) printf 'FAIL  %-58s  error did not mention [%s]: %s\n' "$1" "$2" "$_out"
               fail=$((fail+1)) ;;
        esac
    fi
}

echo "== bare host (backward compatibility) =="
ok 'vpn.example.com'                 url    'https://vpn.example.com'
ok 'vpn.example.com'                 host   'vpn.example.com'
ok 'vpn.example.com'                 port   ''
# A bare host must NOT grow a trailing slash: the request has to stay
# byte-identical to what the pre-URL version sent.
ok 'vpn.example.com:4443'            url    'https://vpn.example.com:4443'
ok 'vpn.example.com:4443'            port   '4443'

echo "== scheme =="
ok 'https://vpn.example.com'         url    'https://vpn.example.com'
ok 'HTTPS://vpn.example.com'         scheme 'https'
ok 'http://vpn.example.com/x'        scheme 'https'
bad 'ftp://vpn.example.com'          'unsupported scheme'

echo "== the motivating case: route selector in the query =="
ok 'https://connect.poihali.space/?route=kizhi-canyon-8ww4ht' \
                                     url    'https://connect.poihali.space/?route=kizhi-canyon-8ww4ht'
ok 'https://connect.poihali.space/?route=kizhi-canyon-8ww4ht' \
                                     host   'connect.poihali.space'
ok 'https://connect.poihali.space/?route=kizhi-canyon-8ww4ht' \
                                     query  'route=kizhi-canyon-8ww4ht'
ok 'https://connect.poihali.space/?route=kizhi-canyon-8ww4ht' \
                                     path   ''
# Query without the slash separator must parse the same way.
ok 'https://connect.poihali.space?route=abc'    query 'route=abc'
ok 'https://connect.poihali.space?route=abc'    host  'connect.poihali.space'

echo "== path + query + port + fragment =="
ok 'https://h.example:8443/tunnel/grp?route=abc&x=1#frag' url   'https://h.example:8443/tunnel/grp?route=abc&x=1'
ok 'https://h.example:8443/tunnel/grp?route=abc&x=1#frag' path  'tunnel/grp'
ok 'https://h.example:8443/tunnel/grp?route=abc&x=1#frag' query 'route=abc&x=1'
ok 'https://h.example/grp'                                path  'grp'

echo "== credentials in the URL =="
ok 'https://alice:s3cret@vpn.example.com/g'   user 'alice'
ok 'https://alice:s3cret@vpn.example.com/g'   pass '<set>'
ok 'https://alice:s3cret@vpn.example.com/g'   host 'vpn.example.com'
# Credentials must be stripped from the URL handed to openconnect.
ok 'https://alice:s3cret@vpn.example.com/g'   url  'https://vpn.example.com/g'
ok 'https://alice@vpn.example.com'            user 'alice'
ok 'https://alice@vpn.example.com'            pass ''
# Percent-encoded userinfo.
ok 'https://u%40corp.ru:p%40ss@vpn.example.com' user 'u@corp.ru'
# A literal '@' in the password: split at the LAST '@'.
ok 'https://alice:p@ss@vpn.example.com'       user 'alice'
ok 'https://alice:p@ss@vpn.example.com'       host 'vpn.example.com'

echo "== IP literals and IPv6 =="
ok '10.0.0.5'                        host '10.0.0.5'
ok '10.0.0.5'                        url  'https://10.0.0.5'
ok 'https://[2001:db8::1]:4443/g'    host '2001:db8::1'
ok 'https://[2001:db8::1]:4443/g'    port '4443'
ok 'https://[2001:db8::1]:4443/g'    url  'https://[2001:db8::1]:4443/g'
ok 'https://[2001:db8::1]'           host '2001:db8::1'
ok 'https://[2001:db8::1]'           url  'https://[2001:db8::1]'

echo "== rejections =="
bad 'https://host:99999/'            'port out of range'
bad 'https://host:abc/'              'invalid port'
bad 'https://:443/'                  'could not find a hostname'
bad ''                               'is empty'

echo
echo "passed: $pass   failed: $fail"
[ "$fail" -eq 0 ]
