# webserver-proxy

A shared front door that lets several Docker Compose sites run on one server
behind the same ports 80 and 443. One HAProxy container routes each connection
by hostname and passes TLS through untouched, so every site keeps its own
certificates and still sees its visitors' real IP addresses. The code was
written with AI under my direction.

![Terminal running the smoke test: HAProxy starts in front of two stub sites, and nine checks pass, covering routing by SNI and Host, closing unknown hostnames, and ignoring a spoofed PROXY header](docs/images/demo.gif)

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
![HAProxy](https://img.shields.io/badge/proxy-HAProxy-106DA9)
![Caddy](https://img.shields.io/badge/sites-Caddy-1F88C0)
![Docker](https://img.shields.io/badge/runs%20in-Docker-2496ED)

## Features

- **Several sites on one server.** Each site keeps its own Docker Compose
  stack and repository, and the proxy hands it the traffic for its hostname.
- **TLS stays with each site.** Port 443 is routed by the hostname in the TLS
  handshake (SNI) and never decrypted. Every site keeps its own Let's Encrypt
  certificates, TLS settings and security headers.
- **Real visitor IPs.** Every forwarded connection starts with a PROXY v2
  header, so the sites' per-IP rate limits and logs keep working.
- **Certificates renew as before.** Port 80 is routed by `Host`, so each
  site's own HTTP→HTTPS redirect and ACME HTTP-01 challenges still work.
  TLS-ALPN-01 works through the passthrough.
- **Sites come and go independently.** The proxy starts without them, finds
  them through Docker DNS when they come up, and doesn't restart when a site
  is redeployed.
- **Long connections stay open.** WebSockets and slow uploads may sit idle for
  up to an hour.

## Quick start

Everything runs in Docker; you only need Docker and curl. To see it work
locally, start the proxy in front of two stub sites:

```bash
./tests/smoke.sh
```

It uses the production `haproxy.cfg` on loopback ports 18080 and 18443, runs
nine checks, and removes everything again. The same script is the test suite,
and CI runs it on every push.

## How it works

```
                :80 / :443  (PUBLIC_BIND_IP)
                              │
                   ┌──────────▼──────────┐
                   │  haproxy            │  routes by SNI (443) / Host (80)
                   │  172.31.250.2       │  adds a PROXY v2 header
                   └──────────┬──────────┘
                              │  "webserver" network
            ┌─────────────────┼─────────────────┐
     ┌──────▼─────┐    ┌──────▼─────┐    ┌──────▼─────┐
     │ vault      │    │ amoeba     │    │ mensa      │
     │ Caddy      │    │ Caddy      │    │ Caddy      │
     └────────────┘    └────────────┘    └────────────┘
       each site's own Caddy: certificates, TLS, headers
```

It currently fronts three sites, each in its own repository: vault
(end-to-end encrypted file sharing), amoeba (an online five-in-a-row game) and
mensa (the day's menus of the ETH, UZH and other Zurich canteens). HAProxy
forwards TCP only, so the sites don't offer HTTP/3.

| Path | What |
|------|------|
| `haproxy.cfg` | Routing by SNI on 443 and `Host` on 80, the PROXY v2 header, and timeouts. |
| `compose.yaml` | The HAProxy container, published on `PUBLIC_BIND_IP`, and the shared `webserver` network. |
| `tests/` | `smoke.sh` and the stub sites it routes to. |

## Deploying

The proxy runs on the same host as the sites and needs Docker with Compose
v2. Deploy it before any site: it creates the shared `webserver` network that
the sites join.

1. Point each site's DNS `A` record at the server.
2. Open inbound TCP 80 and 443, and make sure nothing else on the host binds
   them.
3. On the server:
   ```bash
   git clone https://github.com/gmiszori/webserver-proxy && cd webserver-proxy
   cp .env.example .env   # set PUBLIC_BIND_IP and the site domains
   docker compose up -d
   ```
4. Deploy each site as described in [Adding a site](#adding-a-site). After
   the first time, the order doesn't matter.

To update: `git pull && docker compose up -d`. Restarting the proxy takes
about a second and drops open connections, such as game WebSockets or uploads
in progress. Certificates live with the sites and are not affected.

Logs: `docker compose logs haproxy`. They show the client address, route,
timings and bytes.

### Adding a site

1. In the site's compose file, don't publish 80/443. Instead, join the
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
2. In the site's Caddyfile global options, accept the proxy's PROXY header:
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
4. Run `docker compose up -d` to restart the proxy.

### Configuration (`.env`)

| Variable | Default | |
|----------|---------|--|
| `PUBLIC_BIND_IP` | – | A specific local interface address for 80/443; the LAN address behind NAT, never `0.0.0.0`. |
| `VAULT_DOMAIN` | `vault.miszori.dev` | Must match vault's `DOMAIN`. |
| `AMOEBA_DOMAIN` | – | Must match amoeba's `DOMAIN`. |
| `MENSA_DOMAIN` | `mensa.miszori.dev` | Must match mensa's `DOMAIN`. |

The shared network is `172.31.250.0/24`. The proxy has the fixed address
`.2`, and sites get dynamic addresses from `.128/25`. If the subnet clashes
with something on the host, change it here and the trusted address in each
site's Caddyfile together.

The Compose project and the network are named `webserver`, not
`webserver-proxy`, because the sites join the network by that name. Renaming
it means changing every site and redeploying them all together.

## Security

- **No decryption at the edge.** The proxy never holds private keys or sees
  decrypted traffic, so a flaw in it can't expose what visitors send.
- **Only the proxy can set a client IP.** Sites trust PROXY headers from
  `172.31.250.2` alone, so another container on the network can't fake a
  visitor's address; the smoke test checks this. That address is outside
  Docker's dynamic range, so no other container can take it.
- **Unknown hostnames are closed.** Requests for other names or a bare IP get
  no response on either port, so scanners don't reach a default site.
- **Minimal container.** It runs as HAProxy's unprivileged user with a
  read-only filesystem, no Linux capabilities, no privilege escalation and
  memory/process caps. There is no Docker socket, runtime API or stats page
  to attack.
- **No URIs in logs.** Port 80 logs leave out paths and headers, which may
  carry share links or tokens; port 443 traffic is never readable anyway.
- **Pinned image.** The HAProxy image is pinned by digest, and Dependabot
  proposes updates weekly.

When deploying, keep real values in `.env`, which git ignores, and merge
Dependabot's image updates promptly. If a site's DNS goes through Cloudflare's
proxy (orange cloud), sites see Cloudflare's addresses instead of visitors';
use "DNS only" to keep real IPs.

## License

[MIT](LICENSE)
