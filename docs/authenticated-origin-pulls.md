# Authenticated Origin Pulls

The [Cloudflare-only firewall](../README.md#cloudflare-only-firewall) lets in only Cloudflare's addresses. But every Cloudflare customer connects from those same addresses, so someone could point their own Cloudflare zone at this server and reach the sites without going through this zone's WAF and rate-limit rules.

With Authenticated Origin Pulls, Cloudflare presents a client certificate on every connection to the server, and each site's Caddy rejects the TLS handshake without it. The certificate is our own, uploaded to this zone only (zone-level), so another customer's zone can't present it. Cloudflare's shared certificate would not be enough, because every customer's traffic carries it.

| Piece | Where |
| --- | --- |
| Our CA certificate (public) | `origin-pull-ca.pem` next to each site's Caddyfile: mensa, amoeba (`client/`), vault |
| Client certificate and key | Uploaded to Cloudflare for the `miszori.dev` zone |
| CA private key | Offline, in the password manager; only needed to issue a new client certificate |
| Switch | `ORIGIN_PULL=on` or `off` in each site's `.env`, default `off` |

The client certificate and the CA expire in November 2036.

## Turning it on

Order matters: Cloudflare must send the certificate **before** any site requires it, or that site goes down.

### 1. Upload the client certificate to Cloudflare

Create an API token (My Profile → API Tokens → Create Custom Token) for the `miszori.dev` zone with **Zone · SSL and Certificates · Edit** and **Zone · Zone Settings · Edit**. Find the Zone ID on the zone's Overview page. On your computer, in the folder with `client.pem` and `client.key`:

```bash
export CF_API_TOKEN=... ZONE_ID=...
```

```bash
jq -n --rawfile certificate client.pem --rawfile private_key client.key '{certificate: $certificate, private_key: $private_key}' | curl -sS -X POST "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/origin_tls_client_auth" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data @- | jq '.success, .result.id, .result.status, .errors'
```

Wait until the status is `active` (usually a few minutes):

```bash
curl -sS "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/origin_tls_client_auth" -H "Authorization: Bearer $CF_API_TOKEN" | jq '.result[] | {id, status, expires_on}'
```

### 2. Turn it on for the zone

```bash
curl -sS -X PATCH "https://api.cloudflare.com/client/v4/zones/$ZONE_ID/settings/tls_client_auth" -H "Authorization: Bearer $CF_API_TOKEN" -H "Content-Type: application/json" --data '{"value":"on"}' | jq '.success, .result.value'
```

The same switch is in the dashboard under SSL/TLS → Origin Server → Authenticated Origin Pulls. Nothing changes for visitors yet: the sites still accept connections without the certificate.

### 3. Require it on each site, one at a time

On the server, in each site's checkout, after pulling the version that has `origin-pull-ca.pem`:

```bash
grep -q '^ORIGIN_PULL=' .env && sed -i 's/^ORIGIN_PULL=.*/ORIGIN_PULL=on/' .env || echo 'ORIGIN_PULL=on' >> .env
```

Then recreate that site's Caddy:

| Site | Command |
| --- | --- |
| mensa | `docker compose up -d caddy` |
| amoeba | `docker compose up -d --build web` |
| vault | `docker compose up -d caddy` |

### 4. Check it

The site still loads normally through Cloudflare:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' https://mensa.miszori.dev/
```

A connection without the certificate now fails during the TLS handshake. Run this on the server, where the firewall doesn't apply, and expect an error such as `certificate required` instead of a status code:

```bash
curl -sS -o /dev/null -w '%{http_code}\n' --resolve mensa.miszori.dev:443:<server-IP> https://mensa.miszori.dev/
```

Repeat steps 3 and 4 for amoeba and vault. Better Stack alerts you if a site stops loading.

## Turning it off

Reverse order: set `ORIGIN_PULL=off` and recreate Caddy on **every** site first, then turn the zone setting off in Cloudflare. Turning Cloudflare off first takes all three sites down.

## A new client certificate

When the certificate nears expiry, or if its key may have leaked, issue a new one from the same CA, upload it as in step 1, and delete the old one in Cloudflare once the new one is active. The sites need no change, because they trust the CA, not the certificate. With `ca.pem` and `ca.key` from the password manager:

```bash
openssl req -newkey rsa:2048 -nodes -sha256 -keyout client.key -out client.csr -subj "/CN=Cloudflare origin pull miszori.dev"
```

```bash
printf 'basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\nextendedKeyUsage=clientAuth\n' > client.ext && openssl x509 -req -in client.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 3650 -sha256 -extfile client.ext -out client.pem
```

If the CA key itself may have leaked, make a new CA too, replace `origin-pull-ca.pem` in all three repositories, deploy them with `ORIGIN_PULL=off`, upload the new client certificate, and then switch back on.
