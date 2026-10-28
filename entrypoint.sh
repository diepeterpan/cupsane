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

airsane_debug="${AIRSANE_DEBUG:-true}"
case "$airsane_debug" in
	true|false) ;;
	*)
		echo "[entrypoint] AIRSANE_DEBUG must be 'true' or 'false'" >&2
		exit 1
		;;
esac

airsane_listen_port="${AIRSANE_LISTEN_PORT:-8090}"
case "$airsane_listen_port" in
	''|*[!0-9]*)
		echo "[entrypoint] AIRSANE_LISTEN_PORT must be an integer from 1 to 65535" >&2
		exit 1
		;;
esac
if [ "${#airsane_listen_port}" -gt 5 ] || [ "$airsane_listen_port" -lt 1 ] || [ "$airsane_listen_port" -gt 65535 ]; then
	echo "[entrypoint] AIRSANE_LISTEN_PORT must be an integer from 1 to 65535" >&2
	exit 1
fi

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

echo "[entrypoint] Starting AirSane on port $airsane_listen_port (MDNS_ANNOUNCE=$mdns_announce, AIRSANE_DEBUG=$airsane_debug)" >&2

airsane_ready_file=/run/airsane-supervisor.ready
rm -f "$airsane_ready_file"
MDNS_ANNOUNCE="$mdns_announce" \
	AIRSANE_DEBUG="$airsane_debug" \
	AIRSANE_LISTEN_PORT="$airsane_listen_port" \
	/usr/local/bin/airsane-supervisor.sh "$airsane_ready_file" &
airsane_supervisor_pid=$!
attempt=0
while [ ! -f "$airsane_ready_file" ] && [ "$attempt" -lt 10 ]; do
	if ! kill -0 "$airsane_supervisor_pid" 2>/dev/null; then
		wait "$airsane_supervisor_pid" || true
		echo "[entrypoint] AirSane supervisor failed to start" >&2
		exit 1
	fi
	sleep 1
	attempt=$((attempt + 1))
done
if [ ! -f "$airsane_ready_file" ]; then
	kill -TERM "$airsane_supervisor_pid" 2>/dev/null || true
	wait "$airsane_supervisor_pid" || true
	echo "[entrypoint] Timed out waiting for AirSane to start" >&2
	exit 1
fi

if command -v /usr/sbin/cupsd >/dev/null 2>&1; then
	exec /usr/sbin/cupsd -f
else
	echo "[entrypoint] cupsd not found at /usr/sbin/cupsd" >&2
	exit 1
fi
