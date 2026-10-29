# cupsane

[![Docker Hub](https://img.shields.io/docker/v/bartekmp/cupsane?label=Docker%20Hub&logo=docker)](https://hub.docker.com/r/bartekmp/cupsane)
[![GitHub Container Registry](https://img.shields.io/badge/ghcr.io-bartekmp%2Fcupsane-blue?logo=github)](https://ghcr.io/bartekmp/cupsane)
[![Build](https://github.com/bartekmp/cupsane/actions/workflows/build-and-push.yml/badge.svg)](https://github.com/bartekmp/cupsane/actions/workflows/build-and-push.yml)

A containerized CUPS print server with SANE scanner support and AirSane, an AirScan/eSCL scanner server with a simple web interface.

## Features

- **CUPS** - Network print server with web interface
- **AirSane** - AirScan/eSCL scanner server, mDNS discovery, and a simple web interface
- **SANE** - Scanner backends, including HP devices
- **Persistent configuration** - Printer settings survive container restarts
- **Network accessible** - Printing and scanning are available on the LAN

## Services and ports

- **631** - CUPS web interface and IPP printing inside the container
- **8631** - CUPS port in the Kubernetes deployment and bridged Docker example
- **8090** - AirSane web interface and AirScan/eSCL service

The separate SANE network daemon (`saned`) is not started; scanner clients connect through AirSane instead.

AirSane publishes scanners with mDNS. The Docker Compose configuration uses host networking so AirScan clients on the LAN can discover the service. In Kubernetes, discovery requires a network that permits mDNS multicast and makes the advertised pod address reachable from scanner clients; many default Kubernetes networks do not. The web interface remains available at the configured node port even when mDNS discovery is unavailable.

## Environment variables

| Variable | Default | Description |
|----------|---------|-------------|
| `TZ` | — | Timezone (e.g., `Europe/Warsaw`) |
| `MDNS_ANNOUNCE` | `true` | Set to `false` to disable AirSane's mDNS service announcement; the web UI remains available at port 8090, but automatic AirScan discovery is disabled. |
| `AIRSANE_DEBUG` | `true` | Set to `false` to disable AirSane debug logging. |
| `AIRSANE_LISTEN_PORT` | `8090` | TCP port AirSane listens on (valid range: 1–65535). |
| `ANNOUNCE_SECURE` | `false` | Set to `true` to mark AirSane's announced service as secure. |
| `ANNOUNCE_BASE_URL` | empty | Optional base URL included in AirSane's service announcement. |
| `AVAHI_HOST_NAME` | container `HOSTNAME` | Hostname written to the `[server]` section of `/etc/avahi/avahi-daemon.conf` when mDNS announcements are enabled. |
| `AVAHI_DOMAIN` | `local` | Domain written as `domain-name` in the Avahi `[server]` section when mDNS announcements are enabled. |
| `AIRSANE_ACCESS_NETWORK` | empty | Optional IP address or CIDR network added as an `allow` rule in `/etc/airsane/access.conf` before AirSane starts (e.g. `10.0.0.0/24`). |
| `DNSSD_HOST_NAME` | CUPS default | Optional fully qualified DNS hostname written as the `DNSSDHostName` directive in `/etc/cups/cupsd.conf` before CUPS starts (e.g. `cupsane.example.com`). |

The supplied Docker Compose and Kubernetes configurations set `MDNS_ANNOUNCE=false`. To enable mDNS announcements for AirScan discovery, change the value to `true` or remove the variable.
For Docker Compose, set `AIRSANE_DEBUG`, `AIRSANE_LISTEN_PORT`, `ANNOUNCE_SECURE`, `ANNOUNCE_BASE_URL`, `AVAHI_HOST_NAME`, `AVAHI_DOMAIN`, `AIRSANE_ACCESS_NETWORK`, or `DNSSD_HOST_NAME` in the shell or a `.env` file. When changing the listen port in a deployment with explicit port mappings, update those mappings to match.
When mDNS announcements are enabled, the entrypoint starts a container-local system D-Bus before Avahi, sets the Avahi `host-name` from `AVAHI_HOST_NAME` (or the container's `HOSTNAME` if unset) and `domain-name` from `AVAHI_DOMAIN`, and checks that Avahi remains running after startup. Both daemons use the container's `/run`; do not bind-mount the host's `/var/run/dbus` over the container's system-bus socket.
Avahi may log that it is removing a PID file for a process that no longer exists after an unclean shutdown. That message alone does not mean startup failed; the entrypoint now checks that Avahi remains alive.

## Deployment methods

### 1. Docker Run

For AirScan discovery on a Linux host, use host networking:

```bash
docker run --rm -d \
  --name cupsane \
  --network host \
  --privileged \
  -e MDNS_ANNOUNCE=false \
  -v /dev/bus/usb:/dev/bus/usb \
  bartekmp/cupsane:latest
```

With host networking, CUPS is available on port 631 and AirSane on port 8090.

For bridged networking with explicit CUPS configuration persistence:

```bash
mkdir -p ./storage/cups-config ./storage/cups-cache ./storage/cups-spool

docker run --rm -d \
  --name cupsane \
  --privileged \
  -v /dev/bus/usb:/dev/bus/usb \
  -v ./storage/cups-config:/etc/cups \
  -v ./storage/cups-cache:/var/cache/cups \
  -v ./storage/cups-spool:/var/spool/cups \
  -e TZ=Europe/Warsaw \
  -p 8631:631 \
  -p 8090:8090 \
  bartekmp/cupsane:latest
```

Port mapping makes the web interface reachable, but Docker bridge networking does not generally forward AirSane's mDNS announcements. Use host networking or configure an mDNS relay if LAN scanner discovery is required.

### 2. Docker Compose

The supplied Compose file is intended for Linux hosts and uses host networking for scanner access and mDNS discovery. The container watches the mounted `/dev/bus/usb` tree for newly created USB device nodes and restarts AirSane after an attachment; CUPS stays running. This relies on Linux USB device nodes being bind-mounted into the container. Detaching a device does not trigger a restart.

```bash
mkdir cupsane && cd cupsane
# Copy docker-compose.yml to this directory
mkdir -p storage/cups-config storage/cups-cache storage/cups-spool
docker compose up -d
docker compose logs -f
```

The Compose service binds directly to the host network. AirSane is at `http://<host-ip>:8090`; CUPS listens on port 631.

### 3. Kubernetes (k3s/k8s)

#### Prerequisites

```bash
sudo mkdir -p /opt/cupsd-data/{config,cache,spool}
sudo chmod 755 /opt/cupsd-data/{config,cache,spool}
```

#### Deploy

```bash
kubectl apply -f cupsd-deployment.yaml
kubectl get pods -l app=cupsane
kubectl logs -f deployment/cupsane
```

Access CUPS at `http://<node-ip>:8631` and AirSane at `http://<node-ip>:8090`.

The deployment pins the pod to the `workstation` node, where the USB scanner is expected to be connected. Change `nodeSelector` in `cupsd-deployment.yaml` if needed. AirScan discovery from outside the cluster also depends on the cluster network forwarding mDNS multicast and making the pod's advertised address reachable; use a multicast-capable network or mDNS relay if required.

## Configuration

### CUPS

Access CUPS at `http://<your-ip>:631` when using host networking, or at the mapped port such as `http://<your-ip>:8631` when using bridged networking.

- Add printers via the web interface
- Configure print queues and sharing
- Monitor print jobs

The default server configuration allows access from the LAN. To modify network access, edit `config/cupsd.conf` and rebuild the image.

### AirSane

Access the simple web interface at `http://<your-ip>:8090`. AirSane also publishes compatible scanners over AirScan/eSCL for clients such as Apple Image Capture, Windows scanner software, and Mopria Scan.

Scans are delivered to the requesting client. AirSane does not archive scans in the container, so there is no scan-output volume. Existing files in a previously configured host-side scan directory are not modified by this image.

## Persistent data

Persist these CUPS directories as needed:

- `/etc/cups` - CUPS configuration and printer definitions
- `/var/cache/cups` - CUPS cache files
- `/var/spool/cups` - Print job queue

## Troubleshooting

### Check scanner detection

AirSane runs as the `saned` account. Check that the SANE backends can see devices as that user:

```bash
docker exec cupsane su -s /bin/sh -c 'scanimage -L' saned
```

### View logs

```bash
docker logs cupsane
docker compose logs -f
kubectl logs deployment/cupsane
```

### Restart services

```bash
docker restart cupsane
docker compose restart
kubectl rollout restart deployment/cupsane
```

## Building from source

```bash
docker build -t cupsane .
docker run --rm --privileged -p 8631:631 -p 8090:8090 cupsane
```

For AirScan discovery on a Linux host, run the image with `--network host` instead of port mappings. To publish an updated image:

```bash
docker tag cupsane bartekmp/cupsane:latest
docker push bartekmp/cupsane:latest
```

## Requirements

- USB printer/scanner connected to the host
- Privileged container access for USB device access
- D-Bus support for HPLIP devices; the image starts its own system bus when mDNS announcements are enabled, so host D-Bus mounts are not used
- Host networking or mDNS multicast support for AirScan scanner discovery

## Supported devices

Primarily designed for HP printers/scanners via HPLIP, but also supports:

- Generic PostScript printers
- PDF printing (cups-pdf)
- Network printers via IPP

Scanner availability depends on the SANE backends enabled in the image.

## License

See LICENSE for details.
