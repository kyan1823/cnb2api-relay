#!/bin/sh
# Container entrypoint: seed the upstream map, make sure TLS material exists,
# then run nginx and the registration service side by side under tini.
set -eu

MAP="${UPSTREAM_CONF:-/etc/nginx/http.d/cnb-ai-upstream.conf}"
CRT=/etc/nginx/ssl/fullchain.pem
KEY=/etc/nginx/ssl/privkey.pem

# The vhost references $cnb_ai_upstream, so the map must exist before nginx is
# tested. cnb-register.py overwrites this on the first registration.
#
# The seed target is a closed local port on purpose: *.cnb.run resolves as a
# wildcard, so seeding a made-up subdomain would let stray requests reach CNB's
# edge and return its 302 instead of a clean 502 until the first registration.
if [ ! -s "$MAP" ]; then
    mkdir -p "$(dirname "$MAP")"
    printf 'map $request_uri $cnb_ai_upstream { default 127.0.0.1:1; }\n' > "$MAP"
    echo "seeded $MAP"
fi

# Keep the container bootable before real certificates are dropped in; clients
# then need -k until fullchain.pem / privkey.pem are replaced.
if [ ! -s "$CRT" ] || [ ! -s "$KEY" ]; then
    echo "WARN: no certificate at $CRT / $KEY, generating a self-signed one" >&2
    mkdir -p /etc/nginx/ssl
    openssl req -x509 -nodes -newkey rsa:2048 -days 365 \
        -subj "/CN=${SERVER_NAME:-localhost}" \
        -keyout "$KEY" -out "$CRT" >/dev/null 2>&1
fi

nginx -t

python3 /usr/local/bin/cnb-register.py &
REG_PID=$!
nginx -g 'daemon off;' &
NGX_PID=$!

stop() {
    kill "$REG_PID" "$NGX_PID" 2>/dev/null || true
    wait 2>/dev/null || true
}
trap stop TERM INT

while kill -0 "$NGX_PID" 2>/dev/null && kill -0 "$REG_PID" 2>/dev/null; do
    sleep 5 &
    wait $! || true
done

echo "relay child exited, shutting down" >&2
stop
exit 1
