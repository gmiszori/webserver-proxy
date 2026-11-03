#!/bin/sh
# Lets only Cloudflare reach ports 80 and 443 on PUBLIC_BIND_IP. Run as root;
# running it again reloads the ranges from cloudflare-ips-v4.txt.
#
# Docker forwards published ports past ufw and the INPUT chain, so the rules go
# in DOCKER-USER, which Docker checks before its own rules and never changes.
# Only connections to the public address are matched: HAProxy reaching the
# sites on ports 80 and 443 inside Docker is not. SSH and WireGuard are not
# affected.
#
#   cloudflare-only.sh          add or reload the rules
#   cloudflare-only.sh remove   remove them
set -eu
dir=$(dirname "$(readlink -f "$0")")

# Docker uses either the nftables or the legacy variant of iptables, and each
# variant sees only its own rules. Use the one whose FORWARD chain sends
# traffic to DOCKER-USER.
ipt=
for cmd in iptables iptables-nft iptables-legacy; do
	if command -v "$cmd" >/dev/null && "$cmd" -S FORWARD 2>/dev/null | grep -q -- '-j DOCKER-USER$'; then
		ipt=$cmd
		break
	fi
done
if [ -z "$ipt" ]; then
	echo "No DOCKER-USER chain: is Docker running, with its iptables rules on?" >&2
	exit 1
fi

# Deletes the jumps from DOCKER-USER to these rules, except to the chain named
# in $1, whatever address they were added for.
remove_jumps() {
	"$ipt" -S DOCKER-USER | grep -- '-j CLOUDFLARE-ONLY-[AB]$' | grep -v -- "-j ${1:-none}\$" |
		sed 's/^-A /-D /' | while read -r rule; do
			# shellcheck disable=SC2086 # $rule is a list of arguments
			"$ipt" $rule
		done
}
delete_chain() {
	"$ipt" -F "$1" 2>/dev/null || true
	"$ipt" -X "$1" 2>/dev/null || true
}

if [ "${1-}" = remove ]; then
	remove_jumps
	delete_chain CLOUDFLARE-ONLY-A
	delete_chain CLOUDFLARE-ONLY-B
	echo "Removed: ports 80 and 443 are open to everyone again."
	exit 0
fi

public_ip=$(sed -n 's/^PUBLIC_BIND_IP=//p' "$dir/../.env" | tr -d '\r')
case "$public_ip" in
	*[!0-9.]* | "") echo "PUBLIC_BIND_IP in .env is not an IPv4 address: '$public_ip'" >&2; exit 1 ;;
esac

ranges=$(grep -Ev '^[[:space:]]*(#|$)' "$dir/cloudflare-ips-v4.txt" | tr -d '\r')
for range in $ranges; do
	case "$range" in
		*[!0-9./]* | */*/*) echo "Not an IPv4 range in cloudflare-ips-v4.txt: '$range'" >&2; exit 1 ;;
	esac
done
# A broken or truncated list must not lock every visitor out.
if [ "$(echo "$ranges" | wc -l)" -lt 10 ]; then
	echo "cloudflare-ips-v4.txt has fewer than 10 ranges; not applying it" >&2
	exit 1
fi

# The new rules are built in a second chain and switched to at the end, so the
# ports are never open while reloading, and a failure leaves the old rules on.
old=$("$ipt" -S DOCKER-USER | sed -n 's/.* -j \(CLOUDFLARE-ONLY-[AB]\)$/\1/p' | head -n 1)
new=CLOUDFLARE-ONLY-A
[ "$old" != "$new" ] || new=CLOUDFLARE-ONLY-B

delete_chain "$new"
"$ipt" -N "$new"
for range in $ranges; do
	"$ipt" -A "$new" -s "$range" -j RETURN
done
"$ipt" -A "$new" -j DROP

# --ctdir ORIGINAL: replies from the container also carry the original
# destination port, and must not be dropped.
for port in 80 443; do
	"$ipt" -I DOCKER-USER -p tcp -m conntrack --ctorigdst "$public_ip" --ctorigdstport "$port" --ctdir ORIGINAL -j "$new"
done
remove_jumps "$new"
[ -z "$old" ] || [ "$old" = "$new" ] || delete_chain "$old"

echo "Ports 80 and 443 on $public_ip now accept only Cloudflare ($(echo "$ranges" | wc -l) ranges)."
