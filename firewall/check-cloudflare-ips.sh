#!/bin/sh
# Compares Cloudflare's published ranges with the copies that depend on them:
# cloudflare-ips-v4.txt here, and trusted_proxies in each site's Caddyfile.
# Prints what differs and exits 1 if anything does.
set -eu
cd "$(dirname "$0")"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/cloudflare-ips.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

fetch() { curl -fsS --retry 3 --max-time 30 "$1"; }
# One range per line, sorted, without comments or blank lines.
ranges() { sed 's/#.*//' | tr -s ' \t' '\n\n' | grep -v '^$' | sort -u; }

fetch https://www.cloudflare.com/ips-v4 | ranges >"$tmp/v4"
fetch https://www.cloudflare.com/ips-v6 | ranges >"$tmp/v6"
# A failed or truncated download must not be reported as a change.
if [ "$(wc -l <"$tmp/v4")" -lt 10 ] || [ "$(wc -l <"$tmp/v6")" -lt 3 ]; then
	echo "Cloudflare's list looks incomplete; not comparing" >&2
	exit 2
fi
sort -u "$tmp/v4" "$tmp/v6" >"$tmp/all"

changed=0
# compare NAME EXPECTED ACTUAL
compare() {
	if ! diff -u --label "Cloudflare" --label "$1" "$2" "$3" >"$tmp/diff"; then
		printf '### %s\n\n```diff\n%s\n```\n\n' "$1" "$(cat "$tmp/diff")"
		changed=1
	fi
}

ranges <cloudflare-ips-v4.txt >"$tmp/firewall"
compare "webserver-proxy: firewall/cloudflare-ips-v4.txt" "$tmp/v4" "$tmp/firewall"

for file in mensa.miszori.dev/main/Caddyfile vault.miszori.dev/main/Caddyfile amoeba/main/client/Caddyfile; do
	fetch "https://raw.githubusercontent.com/gmiszori/$file" |
		sed -n 's/^[[:space:]]*trusted_proxies static //p' | ranges >"$tmp/caddy"
	repo=${file%%/*}
	compare "$repo: ${file#*/main/}" "$tmp/all" "$tmp/caddy"
done

exit "$changed"
