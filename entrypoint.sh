#!/bin/sh
set -e

# Ensure runtime directory for saned exists
mkdir -p /run/saned || true

# If /etc/cups is empty due to bind mount, seed a default cupsd.conf
if [ -d /etc/cups ] && [ -z "$(ls -A /etc/cups 2>/dev/null)" ] && [ -f /opt/defaults/cupsd.conf ]; then
	cp /opt/defaults/cupsd.conf /etc/cups/cupsd.conf
fi

# If /etc/sane.d is present and saned.conf missing (or empty), seed it
if [ -d /etc/sane.d ] && [ ! -s /etc/sane.d/saned.conf ] && [ -f /opt/defaults/saned.conf ]; then
	cp /opt/defaults/saned.conf /etc/sane.d/saned.conf
fi

# Optionally force minimal SANE config (hpaio-only) for saned to speed up detection
if [ "${SANE_FORCE_HPAIO_ONLY:-1}" = "1" ] && [ -d /etc/sane.only-hpaio ]; then
	export SANE_CONFIG_DIR=/etc/sane.only-hpaio
	echo "[entrypoint] saned using minimal SANE config at $SANE_CONFIG_DIR (hpaio only)" >&2
fi

# Start saned to handle USB scanner access
# scanservjs will connect via net backend to avoid "Device busy" conflicts
SANED_PORT="${SANED_PORT:-6566}"
if command -v /usr/sbin/saned >/dev/null 2>&1; then
	echo "[entrypoint] Starting saned on port $SANED_PORT" >&2
	/usr/sbin/saned -l -p "${SANED_PORT}" -D &
	# Give saned a moment to start and claim the device
	sleep 1
else
	echo "[entrypoint] WARNING: saned not found at /usr/sbin/saned" >&2
fi

# Configure scanservjs to use net backend (connects to saned)
mkdir -p /etc/sane.net-only
printf "net\n" > /etc/sane.net-only/dll.conf
echo "localhost" > /etc/sane.net-only/net.conf
export SANE_CONFIG_DIR=/etc/sane.net-only
echo "[entrypoint] scanservjs will use saned via net backend" >&2

# Start scanservjs in background
if [ -d /usr/lib/scanservjs ]; then
	(cd /usr/lib/scanservjs && node ./server/server.js &) 
else
	echo "[entrypoint] /usr/lib/scanservjs missing; scanservjs not started" >&2
fi

# Start CUPS in foreground to keep container alive
if command -v /usr/sbin/cupsd >/dev/null 2>&1; then
	exec /usr/sbin/cupsd -f
else
	echo "[entrypoint] cupsd not found at /usr/sbin/cupsd" >&2
	# Fall back to keeping container alive if cupsd missing
	exec tail -f /dev/null
fi
