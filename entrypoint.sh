#!/bin/sh
set -eu

if [ -f /driver/install.sh ]; then
	printf '%s\n' "[entrypoint] Running /driver/install.sh" >&2
	cd /driver/
	sh install.sh
fi

if [ -d /etc/cups ] && [ -z "$(ls -A /etc/cups 2>/dev/null)" ] && [ -f /opt/defaults/cupsd.conf ]; then
	cp /opt/defaults/cupsd.conf /etc/cups/cupsd.conf
fi

if ! command -v /usr/sbin/avahi-daemon >/dev/null 2>&1; then
	echo "[entrypoint] avahi-daemon not found" >&2
	exit 1
fi

if ! command -v /usr/local/bin/airsaned >/dev/null 2>&1; then
	echo "[entrypoint] airsaned not found" >&2
	exit 1
fi

if ! id saned >/dev/null 2>&1; then
	echo "[entrypoint] saned user not found" >&2
	exit 1
fi

mdns_announce="${MDNS_ANNOUNCE:-true}"
case "$mdns_announce" in
	true|false) ;;
	*)
		echo "[entrypoint] MDNS_ANNOUNCE must be 'true' or 'false'" >&2
		exit 1
		;;
esac

mkdir -p /etc/default
touch /etc/default/airsane
if grep -q '^MDNS_ANNOUNCE=' /etc/default/airsane; then
	sed -i "s/^MDNS_ANNOUNCE=.*/MDNS_ANNOUNCE=$mdns_announce/" /etc/default/airsane
else
	printf 'MDNS_ANNOUNCE=%s\n' "$mdns_announce" >> /etc/default/airsane
fi

if [ "$mdns_announce" = "true" ]; then
	install -d -o avahi -g avahi /run/avahi-daemon
	echo "[entrypoint] Starting Avahi for AirScan discovery" >&2
	/usr/sbin/avahi-daemon --daemonize
else
	echo "[entrypoint] AirSane mDNS announcements disabled" >&2
fi

echo "[entrypoint] Starting AirSane on port 8090 (MDNS_ANNOUNCE=$mdns_announce)" >&2
su -s /bin/sh -c "exec /usr/local/bin/airsaned --listen-port=8090 --mdns-announce=$mdns_announce --access-log=- --debug=true" saned &
airsane_pid=$!
sleep 1
if ! kill -0 "$airsane_pid" 2>/dev/null; then
	echo "[entrypoint] AirSane failed to start" >&2
	exit 1
fi

if command -v /usr/sbin/cupsd >/dev/null 2>&1; then
	exec /usr/sbin/cupsd -f
else
	echo "[entrypoint] cupsd not found at /usr/sbin/cupsd" >&2
	exit 1
fi
