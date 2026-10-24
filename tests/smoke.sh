#!/bin/sh
# End-to-end check of haproxy.cfg against stub apps. Leaves nothing running.
set -eu
cd "$(dirname "$0")/.."

export PUBLIC_BIND_IP=127.0.0.1 VAULT_DOMAIN=vault.test AMOEBA_DOMAIN=amoeba.test MENSA_DOMAIN=mensa.test
PROXY_IP=172.31.251.2
compose() { docker compose --env-file /dev/null -p webserver-test -f compose.yaml -f tests/compose.yaml "$@"; }
trap 'compose down -v >/dev/null 2>&1 || true' EXIT

compose up -d --wait
compose exec -T haproxy haproxy -c -q -f /usr/local/etc/haproxy/haproxy.cfg

failed=0
# check NAME GLOB RESPONSE: RESPONSE must match GLOB and must not name the
# proxy as the client (that would mean the PROXY header was lost).
check() {
	case "$3" in
		*"$PROXY_IP"*) echo "FAIL $1: app saw the proxy, not the client: '$3'"; failed=1 ;;
		$2) echo "ok   $1" ;;
		*) echo "FAIL $1: got '$3'"; failed=1 ;;
	esac
}
https_get() { curl -sk --max-time 5 --resolve "$1:18443:127.0.0.1" "https://$1:18443/" || true; }
http_get() { curl -s --max-time 5 -H "Host: $1" http://127.0.0.1:18080/ || true; }

# The stubs issue their internal certificates right after start.
for _ in $(seq 30); do
	case "$(https_get vault.test)$(https_get amoeba.test)$(https_get mensa.test)" in *https*https*https*) break ;; esac
	sleep 1
done

check "https by SNI reaches vault" 'vault https *' "$(https_get vault.test)"
check "https by SNI reaches amoeba" 'amoeba https *' "$(https_get amoeba.test)"
check "https by SNI reaches mensa" 'mensa https *' "$(https_get mensa.test)"
check "http by Host reaches vault" 'vault http *' "$(http_get vault.test)"
check "http by Host reaches amoeba" 'amoeba http *' "$(http_get amoeba.test)"
check "http by Host reaches mensa" 'mensa http *' "$(http_get mensa.test)"
check "unknown SNI is closed" '' "$(https_get unknown.test)"
check "unknown Host is closed" '' "$(http_get unknown.test)"

# Another container on the shared network must not be able to claim a client
# address: only the proxy's PROXY headers are trusted.
spoofed=$(compose exec -T vault sh -c \
	"printf 'PROXY TCP4 203.0.113.9 172.31.251.10 1111 80\r\nGET / HTTP/1.0\r\nHost: amoeba.test\r\n\r\n' | nc -w 3 amoeba 80" | tail -n 1 || true)
case "$spoofed" in
	*203.0.113.9*) echo "FAIL spoofed PROXY header was trusted: '$spoofed'"; failed=1 ;;
	*) echo "ok   spoofed PROXY header is not trusted ('$spoofed')" ;;
esac

exit "$failed"
