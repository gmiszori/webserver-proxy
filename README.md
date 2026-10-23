# webserver

The shared front door for the sites on this VPS. One HAProxy container owns
host ports 80 and 443 and hands each connection to the right app by hostname:

```
                    :80 / :443  (PUBLIC_BIND_IP)
                         │
              ┌──────────▼──────────┐
              │  haproxy            │  routes by SNI (443) / Host (80)
              │  172.31.250.2       │  adds a PROXY v2 header
              └────┬───────────┬────┘
       "webserver" │ network   │
            ┌──────▼─────┐ ┌───▼────────┐
            │ vault      │ │ amoeba     │  each app's own Caddy:
            │ Caddy      │ │ Caddy      │  certificates, TLS, headers
            └────────────┘ └────────────┘
```

The apps live in their own repositories and deploy independently:

- [vault.miszori.dev](https://github.com/gmiszori/vault.miszori.dev)
- [amoeba](https://github.com/gmiszori/amoeba)

## How it works

- **443 is passed through, not decrypted.** HAProxy reads only the hostname
  from the TLS handshake (SNI) and forwards the still-encrypted connection.
  Each app's Caddy keeps its own Let's Encrypt certificates, TLS settings and
  security headers. Certificate challenges work both ways: TLS-ALPN-01
  through the passthrough, HTTP-01 through port 80.
- **80 is routed by `Host`**, so each app keeps serving its own HTTP→HTTPS
  redirects.
- **Real client addresses survive.** Every forwarded connection starts with
  a PROXY v2 header. The apps' Caddy servers trust that header from
  `172.31.250.2` only, so per-IP limits and logs see visitors, not the proxy.
  Another container on the network cannot claim a client address.
- **Unknown hostnames and IP-only requests are closed**, on both ports.
- **Long connections stay up.** Once established, a connection may sit idle
  for up to an hour (game WebSockets, slow uploads). The apps' own Caddy
  timeouts are tighter and still apply.
- **HTTP/3 (UDP 443) is not offered.** HAProxy forwards TCP only.
- The proxy holds no certificates and has no Docker socket, runtime API or
  stats page. It runs read-only, with no capabilities, as HAProxy's
  unprivileged user.

## Deploying

Deploy this first: it creates the shared `webserver` network that the apps
join as an external network.

```bash
git clone https://github.com/gmiszori/webserver && cd webserver
cp .env.example .env   # set PUBLIC_BIND_IP and the app domains
docker compose up -d
```

Then deploy each app as its README describes. Order no longer matters after
that: the proxy starts without the apps and finds them through Docker DNS when
they come up, and redeploying an app doesn't touch the proxy.

Logs: `docker compose logs haproxy`. They contain the client address,
frontend, backend, timings and bytes, but no URIs or headers.

## Configuration (`.env`)

| Variable | Default | |
|----------|---------|--|
| `PUBLIC_BIND_IP` | – | A specific local interface address for 80/443; the LAN address behind NAT, never `0.0.0.0`. |
| `VAULT_DOMAIN` | `vault.miszori.dev` | Must match vault's `DOMAIN`. |
| `AMOEBA_DOMAIN` | – | Must match amoeba's `DOMAIN`. |

The network is `172.31.250.0/24`. The proxy has the fixed address `.2`, and
apps get dynamic addresses from `.128/25`. If the subnet clashes with
something on the host, change it here and the trusted address in each app's
Caddyfile (`proxy_protocol { allow … }`) together.

## Adding a site

1. In the app's compose file, don't publish 80/443. Instead, join the
   external `webserver` network under an alias:
   ```yaml
   services:
     web:
       networks:
         default:
         webserver:
           aliases: [myapp]
   networks:
     webserver:
       external: true
   ```
2. In the app's Caddyfile global options, accept the proxy's PROXY header:
   ```
   servers {
   	listener_wrappers {
   		proxy_protocol {
   			allow 172.31.250.2/32
   		}
   		tls
   	}
   	protocols h1 h2
   }
   ```
   Also declare the HTTP→HTTPS redirect as a site, e.g.
   `http:// { redir https://{host}{uri} 308 }`. Caddy's automatic redirect
   server doesn't get the listener wrapper and would answer 400.
3. In `haproxy.cfg`, add a `use_backend` line to each frontend and an
   `_https`/`_http` backend pair pointing at the alias. Then add the domain to
   `.env`, `.env.example` and `compose.yaml`.
4. Run `docker compose up -d`. The proxy restarts in about a second, and
   open connections are dropped.

## Testing

```bash
./tests/smoke.sh
```

This starts the production `haproxy.cfg` in front of two stub Caddy apps on an
isolated network and loopback ports `18080`/`18443`. It checks routing by SNI
and `Host`, rejection of unknown names, that the apps see the client rather
than the proxy, and that a spoofed PROXY header from another container is not
trusted. It needs only Docker, and CI runs it on every push.
