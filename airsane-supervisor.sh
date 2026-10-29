#!/bin/bash
set -euo pipefail

if [ "$#" -ne 1 ]; then
	echo "[airsane-supervisor] Expected a readiness-file path" >&2
	exit 2
fi

ready_file=$1
usb_bus=/dev/bus/usb
mdns_announce="${MDNS_ANNOUNCE:-true}"
airsane_debug="${AIRSANE_DEBUG:-true}"
airsane_listen_port="${AIRSANE_LISTEN_PORT:-8090}"
announce_secure="${ANNOUNCE_SECURE:-false}"
announce_base_url="${ANNOUNCE_BASE_URL:-}"
airsane_pid=
watcher_pid=
runtime_dir=

start_airsane() {
	runuser -u saned -- /usr/local/bin/airsaned \
		"--listen-port=$airsane_listen_port" \
		"--mdns-announce=$mdns_announce" \
		"--announce-secure=$announce_secure" \
		"--announce-base-url=$announce_base_url" \
		--access-log=- \
		"--debug=$airsane_debug" &
	airsane_pid=$!
	sleep 1
	if ! kill -0 "$airsane_pid" 2>/dev/null; then
		wait "$airsane_pid" || true
		echo "[airsane-supervisor] AirSane failed to start" >&2
		return 1
	fi
}

stop_airsane() {
	if [ -n "$airsane_pid" ]; then
		kill -TERM "$airsane_pid" 2>/dev/null || true
		wait "$airsane_pid" || true
		airsane_pid=
	fi
}

cleanup() {
	if [ -n "$watcher_pid" ]; then
		kill -TERM "$watcher_pid" 2>/dev/null || true
		wait "$watcher_pid" 2>/dev/null || true
	fi
	stop_airsane
	if [ -n "$runtime_dir" ]; then
		rm -rf "$runtime_dir"
	fi
}

is_usb_device_node() {
	case "$1" in
		"$usb_bus"/[0-9][0-9][0-9]/[0-9][0-9][0-9])
			[ -c "$1" ]
			;;
		*)
			return 1
			;;
	esac
}

trap cleanup EXIT
trap 'exit 0' INT TERM

if [ ! -d "$usb_bus" ]; then
	echo "[airsane-supervisor] USB bus directory not found: $usb_bus" >&2
	exit 1
fi
if ! command -v inotifywait >/dev/null 2>&1; then
	echo "[airsane-supervisor] inotifywait not found" >&2
	exit 1
fi

runtime_dir=$(mktemp -d /run/airsane-hotplug.XXXXXX)
event_fifo=$runtime_dir/events
mkfifo "$event_fifo"
exec 3<>"$event_fifo"
inotifywait --monitor --recursive --event create --event moved_to --format '%w%f' "$usb_bus" > "$event_fifo" &
watcher_pid=$!
sleep 1
if ! kill -0 "$watcher_pid" 2>/dev/null; then
	echo "[airsane-supervisor] Failed to monitor USB device events" >&2
	exit 1
fi

start_airsane
touch "$ready_file"
echo "[airsane-supervisor] Watching $usb_bus for attached USB devices" >&2

while true; do
	if IFS= read -r -t 1 event_path <&3; then
		restart_airsane=0
		if is_usb_device_node "$event_path"; then
			restart_airsane=1
		fi

		sleep 1
		while IFS= read -r -t 1 event_path <&3; do
			if is_usb_device_node "$event_path"; then
				restart_airsane=1
			fi
		done

		if [ "$restart_airsane" -eq 1 ]; then
			echo "[airsane-supervisor] USB device attached; restarting AirSane" >&2
			stop_airsane
			start_airsane
		fi
	fi

	if ! kill -0 "$airsane_pid" 2>/dev/null; then
		echo "[airsane-supervisor] AirSane exited unexpectedly" >&2
		exit 1
	fi
	if ! kill -0 "$watcher_pid" 2>/dev/null; then
		echo "[airsane-supervisor] USB event watcher exited unexpectedly" >&2
		exit 1
	fi
done
