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

dnssd_host_name="${DNSSD_HOST_NAME:-}"
if [ -n "$dnssd_host_name" ]; then
	if ! printf '%s\n' "$dnssd_host_name" | awk '
		{
			if (length($0) > 253) {
				exit 1
			}
			label_count = split($0, labels, ".")
			if (label_count < 2) {
				exit 1
			}
			for (i = 1; i <= label_count; i++) {
				label = labels[i]
				if (length(label) == 0 || length(label) > 63 ||
					label ~ /^-/ || label ~ /-$/ ||
					label ~ /[^A-Za-z0-9-]/) {
					exit 1
				}
			}
		}
	'; then
		echo "[entrypoint] DNSSD_HOST_NAME must be a fully qualified DNS hostname" >&2
		exit 1
	fi

	cups_config=/etc/cups/cupsd.conf
	if [ ! -f "$cups_config" ]; then
		echo "[entrypoint] CUPS configuration not found: $cups_config" >&2
		exit 1
	fi

	cups_config_tmp=$(mktemp "${cups_config}.XXXXXX")
	if ! awk -v host_name="$dnssd_host_name" '
		BEGIN {
			print "DNSSDHostName " host_name
		}
		tolower($1) == "dnssdhostname" {
			next
		}
		{ print }
	' "$cups_config" > "$cups_config_tmp"; then
		rm -f "$cups_config_tmp"
		echo "[entrypoint] Failed to update CUPS DNS-SD hostname" >&2
		exit 1
	fi
	chmod --reference="$cups_config" "$cups_config_tmp"
	mv "$cups_config_tmp" "$cups_config"
	echo "[entrypoint] Set CUPS DNS-SD hostname to $dnssd_host_name" >&2
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

announce_secure="${ANNOUNCE_SECURE:-false}"
case "$announce_secure" in
true|false) ;;
*)
	echo "[entrypoint] ANNOUNCE_SECURE must be 'true' or 'false'" >&2
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

airsane_access_network="${AIRSANE_ACCESS_NETWORK:-}"
if [ -n "$airsane_access_network" ]; then
	if ! python3 -c 'import ipaddress, sys; ipaddress.ip_network(sys.argv[1], strict=False)' "$airsane_access_network" >/dev/null 2>&1; then
		echo "[entrypoint] AIRSANE_ACCESS_NETWORK must be a valid IP address or CIDR network" >&2
		exit 1
	fi

	airsane_access_file=/etc/airsane/access.conf
	airsane_access_rule="allow $airsane_access_network"
	install -d -m 755 /etc/airsane
	touch "$airsane_access_file"
	if ! grep -Fqx "$airsane_access_rule" "$airsane_access_file"; then
		printf '%s\n' "$airsane_access_rule" >> "$airsane_access_file"
	fi
	echo "[entrypoint] Added AirSane access rule: $airsane_access_rule" >&2
fi

mkdir -p /etc/default
touch /etc/default/airsane
if grep -q '^MDNS_ANNOUNCE=' /etc/default/airsane; then
	sed -i "s/^MDNS_ANNOUNCE=.*/MDNS_ANNOUNCE=$mdns_announce/" /etc/default/airsane
else
	printf 'MDNS_ANNOUNCE=%s\n' "$mdns_announce" >> /etc/default/airsane
fi

if [ "$mdns_announce" = "true" ]; then
	if ! command -v /usr/bin/dbus-daemon >/dev/null 2>&1; then
		echo "[entrypoint] dbus-daemon not found" >&2
		exit 1
	fi

	install -d -m 755 /run/dbus
	echo "[entrypoint] Starting the system D-Bus daemon" >&2
	if ! /usr/bin/dbus-daemon --system --fork; then
		echo "[entrypoint] Failed to start the system D-Bus daemon" >&2
		exit 1
	fi
	if [ ! -s /run/dbus/pid ]; then
		echo "[entrypoint] System D-Bus did not create its PID file" >&2
		exit 1
	fi
	dbus_pid=$(cat /run/dbus/pid)
	case "$dbus_pid" in
		''|*[!0-9]*)
			echo "[entrypoint] System D-Bus created an invalid PID file" >&2
			exit 1
			;;
	esac
	if ! kill -0 "$dbus_pid" 2>/dev/null; then
		echo "[entrypoint] System D-Bus exited after startup" >&2
		exit 1
	fi
	if [ ! -S /run/dbus/system_bus_socket ]; then
		echo "[entrypoint] System D-Bus socket was not created" >&2
		exit 1
	fi

	avahi_config=/etc/avahi/avahi-daemon.conf
	avahi_host_name="${AVAHI_HOST_NAME:-${HOSTNAME:-}}"
	avahi_domain="${AVAHI_DOMAIN:-local}"
	case "$avahi_host_name" in
		''|*[!A-Za-z0-9.-]*|.*|*.)
			echo "[entrypoint] AVAHI_HOST_NAME must be a non-empty hostname containing only letters, numbers, dots, and hyphens" >&2
			exit 1
			;;
	esac
	case "$avahi_host_name" in
		-*|*-)
			echo "[entrypoint] AVAHI_HOST_NAME must not start or end with a hyphen" >&2
			exit 1
			;;
	esac
	if ! printf '%s\n' "$avahi_domain" | awk '
		{
			if (length($0) == 0 || length($0) > 253) {
				exit 1
			}
			label_count = split($0, labels, ".")
			for (i = 1; i <= label_count; i++) {
				label = labels[i]
				if (length(label) == 0 || length(label) > 63 ||
					label ~ /^-/ || label ~ /-$/ ||
					label ~ /[^A-Za-z0-9-]/) {
					exit 1
				}
			}
		}
	'; then
		echo "[entrypoint] AVAHI_DOMAIN must be a valid DNS domain name" >&2
		exit 1
	fi
	if [ ! -f "$avahi_config" ]; then
		echo "[entrypoint] Avahi configuration not found: $avahi_config" >&2
		exit 1
	fi

	avahi_config_tmp=$(mktemp "${avahi_config}.XXXXXX")
	if ! awk -v host_name="$avahi_host_name" -v domain_name="$avahi_domain" '
		function section_name(line, name) {
			name = line
			sub(/^[[:space:]]*\[/, "", name)
			sub(/\][[:space:]]*$/, "", name)
			return tolower(name)
		}
		/^[[:space:]]*\[[^]]*\][[:space:]]*$/ {
			if (in_server && !hostname_written) {
				print "host-name=" host_name
				hostname_written = 1
			}
			if (in_server && !domain_written) {
				print "domain-name=" domain_name
				domain_written = 1
			}
			in_server = (section_name($0) == "server")
			if (in_server) {
				server_found = 1
			}
			print
			next
		}
		in_server && /^[[:space:]]*host-name[[:space:]]*=/ {
			if (!hostname_written) {
				print "host-name=" host_name
				hostname_written = 1
			}
			next
		}
		in_server && /^[[:space:]]*domain-name[[:space:]]*=/ {
			if (!domain_written) {
				print "domain-name=" domain_name
				domain_written = 1
			}
			next
		}
		{ print }
		END {
			if (in_server && !hostname_written) {
				print "host-name=" host_name
				hostname_written = 1
			}
			if (in_server && !domain_written) {
				print "domain-name=" domain_name
				domain_written = 1
			}
			if (!server_found) {
				print ""
				print "[server]"
				print "host-name=" host_name
				print "domain-name=" domain_name
			}
		}
	' "$avahi_config" > "$avahi_config_tmp"; then
		rm -f "$avahi_config_tmp"
		echo "[entrypoint] Failed to update Avahi configuration" >&2
		exit 1
	fi
	chmod --reference="$avahi_config" "$avahi_config_tmp"
	mv "$avahi_config_tmp" "$avahi_config"

	install -d -o avahi -g avahi /run/avahi-daemon
	echo "[entrypoint] Starting Avahi for AirScan discovery (host-name=$avahi_host_name, domain-name=$avahi_domain)" >&2
	if ! /usr/sbin/avahi-daemon \
		--no-drop-root \
		--file=/etc/avahi/avahi-daemon.conf \
		--daemonize \
		--debug; then
		echo "[entrypoint] Failed to start Avahi daemon" >&2
		exit 1
	fi
	sleep 1
	if [ ! -s /run/avahi-daemon/pid ]; then
		echo "[entrypoint] Avahi did not create its PID file" >&2
		exit 1
	fi
	avahi_pid=$(cat /run/avahi-daemon/pid)
	case "$avahi_pid" in
		''|*[!0-9]*)
			echo "[entrypoint] Avahi created an invalid PID file" >&2
			exit 1
			;;
	esac
	if ! kill -0 "$avahi_pid" 2>/dev/null; then
		echo "[entrypoint] Avahi exited after startup" >&2
		exit 1
	fi
else
	echo "[entrypoint] AirSane mDNS announcements disabled" >&2
fi

echo "[entrypoint] Starting AirSane on port $airsane_listen_port (MDNS_ANNOUNCE=$mdns_announce, AIRSANE_DEBUG=$airsane_debug)" >&2

airsane_ready_file=/run/airsane-supervisor.ready
rm -f "$airsane_ready_file"
MDNS_ANNOUNCE="$mdns_announce" \
	AIRSANE_DEBUG="$airsane_debug" \
	AIRSANE_LISTEN_PORT="$airsane_listen_port" \
	ANNOUNCE_SECURE="$announce_secure" \
	ANNOUNCE_BASE_URL="${ANNOUNCE_BASE_URL:-}" \
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
