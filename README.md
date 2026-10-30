# cnb2api relay (Docker)

A standalone container that puts **one fixed public domain** in front of a
cnb2api workspace whose own URL changes on every restart. It runs two things
together:

- **nginx** — terminates TLS for your domain, exposes `/ops/register`, and
  proxies everything else to the current workspace (SSE passes through
  unbuffered).
- **`cnb-register.py`** — a tiny local HTTP service the workspace posts its new
  `PROXY_URI` to on boot; it rewrites the nginx upstream map and reloads nginx,
  rolling back if `nginx -t` or the reload fails.

This directory is self-contained and does not modify the cnb2api repository:
`cnb-register.py` is vendored from it (see [Vendored script](#vendored-script)).
For the bare-VPS install and the architecture behind it, see the upstream
[`docs/DEPLOY.md`](https://github.com/kyan1823/cnb2api/blob/main/docs/DEPLOY.md).

## 1. Fill in the three inputs

```bash
cp register.env.example register.env          # openssl rand -hex 24 -> REG_TOKEN
```

- `register.env` — `REG_TOKEN`, the same value the CNB secrets repo will send.
- `nginx/http.d/ai.conf` — replace both `ai.example.com` occurrences with your
  domain, and set `SERVER_NAME` in `docker-compose.yml` to match.
- `nginx/ssl/fullchain.pem` + `privkey.pem` — your TLS pair (Cloudflare Origin
  certificate, or Let's Encrypt via
  `certbot --webroot -w ./certbot -d ai.example.com`). If you skip this, the
  container generates a self-signed pair on first boot so it still starts;
  clients then need `-k` until you drop in real certs and
  `docker compose restart relay`.

## 2. Start it

```bash
docker compose up -d --build
docker compose logs -f relay
```

Wait for `nginx: configuration file /etc/nginx/nginx.conf test is successful`.

## 3. Point CNB at it

In the CNB secrets repo (`proxy.yml`):

```yaml
REGISTER_URL: "https://ai.example.com/ops/register"
REG_TOKEN: "the same value as register.env"
```

The next workspace boot logs `===== registered upstream to relay =====`.
Without the secrets repo, an already-running workspace can also register itself
by hand:

```bash
curl -X POST https://ai.example.com/ops/register \
  -H "X-Reg-Token: $REG_TOKEN" -H 'Content-Type: application/json' \
  -d '{"uri":"https://<subdomain>-9001.cnb.run"}'
```

## 4. Verify

```bash
curl https://ai.example.com/health
curl https://ai.example.com/v1/models -H "Authorization: Bearer $PROXY_KEY"
docker compose logs relay | grep -i register     # register: {"ok": true, ...}
```

## Layout

```
Dockerfile              alpine + nginx + python3 + tini
docker-compose.yml      ports 80/443, bind mounts, healthcheck
entrypoint.sh           seeds the map, self-signed cert fallback, runs both
cnb-register.py         vendored registration service (RELOAD_CMD patch)
nginx/http.d/ai.conf    vhost + SNI map (mounted rw; contains the map variable)
nginx/ssl/              fullchain.pem / privkey.pem (mounted rw)
register.env            REG_TOKEN (mounted ro; gitignored)
certbot/                HTTP-01 webroot for Let's Encrypt (mounted ro)
```

| Mount | Container path | Written by |
|---|---|---|
| `nginx/http.d/` | `/etc/nginx/http.d/` | you (`ai.conf`) + `cnb-register.py` (`cnb-ai-upstream.conf`) |
| `nginx/ssl/` | `/etc/nginx/ssl/` | you (real certs) or the entrypoint (self-signed fallback) |
| `register.env` | `/root/.cnb/register.env` | you |
| `certbot/` | `/var/www/certbot` | certbot, for HTTP-01 challenges |

## Things that are load-bearing

- The upstream host is a per-request nginx variable, so `ai.conf` sets
  `resolver 127.0.0.11` (Docker's embedded DNS). Without a resolver nginx
  answers `no resolver defined to resolve` and every proxied request 500s.
- The map value is `host:443`; `ai.conf` strips the port for SNI and the `Host`
  header, which must not contain one.
- `UPSTREAM_PORT` (compose) and the workspace's `PROXY_PORT` must both be 9001,
  otherwise the map points at a port the port-proxy does not serve.
- Reloads use `nginx -s reload` via `RELOAD_CMD`, because the container has no
  systemd.
- `client_max_body_size 8m` is load-bearing: the proxy itself accepts 4 MiB
  request bodies, and nginx's 1 MiB default would 413 first.
- The healthcheck probes `/ops/register` for a 403 (no token), which proves
  nginx **and** the registration service are up without depending on the
  workspace being reachable.
- Before the first registration the map points at `127.0.0.1:1`, so proxied
  requests get a clean 502. (A made-up `*.cnb.run` seed would resolve — the zone
  is a wildcard — and serve CNB's edge page instead.)
- Reload is graceful: a request or two immediately after `/ops/register`
  returns 200 can still hit the previous upstream; the new map is live in
  ~0.4 s on the test box.

## Vendored script

`cnb-register.py` comes from
[kyan1823/cnb2api `deploy/cnb-register.py`](https://github.com/kyan1823/cnb2api/blob/main/deploy/cnb-register.py)
with one change: the reload command is read from `RELOAD_CMD` (default
`systemctl reload nginx`), so it works in a container. Everything else —
token check, URI validation, `nginx -t` gate, rollback — is upstream behaviour.
When updating it, diff against upstream and re-apply just that hunk.
