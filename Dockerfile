# docker build -t cupsane:latest .
FROM debian:bookworm-slim

RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl cups cups-filters printer-driver-cups-pdf printer-driver-hpcups hplip ghostscript printer-driver-gutenprint \
    python3-reportlab libjpeg62-turbo snmp libusb-1.0-0 python3-dbus python3 \
    sane-utils libsane1 libsane-common libsane-hpaio sane-airscan avahi-daemon dbus \
    bash inotify-tools wget unzip build-essential cmake git g++ \
    libjbig-dev libcups2-dev libusb-1.0-0-dev pkg-config xxd \
    libsane-dev libjpeg-dev libpng-dev libavahi-client-dev \
    && rm -rf /var/lib/apt/lists/*

RUN useradd -m -g lpadmin lpadmin

RUN git clone --depth 1 https://github.com/SimulPiscator/AirSane.git /tmp/AirSane && \
    cmake -S /tmp/AirSane -B /tmp/AirSane-build -DCMAKE_BUILD_TYPE=Release && \
    cmake --build /tmp/AirSane-build --parallel && \
    cmake --install /tmp/AirSane-build && \
    rm -f /lib/systemd/system/airsaned.service && \
    rm -rf /tmp/AirSane /tmp/AirSane-build

RUN sed -i '/^[[:space:]]*enable-dbus[[:space:]]*=/d; /^\[server\]/a enable-dbus=yes' /etc/avahi/avahi-daemon.conf && \
    sed -i '/^[[:space:]]*use-ipv6[[:space:]]*=/d; /^\[server\]/a use-ipv6=no' /etc/avahi/avahi-daemon.conf && \
    usermod -aG scanner,lp,avahi saned && \
    sed -i '/^[[:space:]]*hpaio[[:space:]]*$/d; /^[[:space:]]*airscan[[:space:]]*$/d' /etc/sane.d/dll.conf && \
    printf '\nhpaio\nairscan\n' >> /etc/sane.d/dll.conf && \
    printf 'usb\n' > /etc/sane.d/hpaio.conf

WORKDIR /app
RUN wget --no-cache https://github.com/diepeterpan/Gurich/archive/refs/heads/master.zip && \
    unzip master.zip && \
    cd /app/Gurich-master && make all && \
    cp bin/gurich /usr/lib/cups/filter/ && \
    cp bin/gurich_cbackend /usr/lib/cups/backend/gurich && \
    cp ppd/* /usr/share/ppd/ && \
    rm -rf /app/Gurich-master /app/master.zip

EXPOSE 631 8090

COPY --chown=root:lp config/cupsd.conf /etc/cups/cupsd.conf

RUN mkdir -p /opt/defaults && \
    cp /etc/cups/cupsd.conf /opt/defaults/cupsd.conf

COPY entrypoint.sh /entrypoint.sh
COPY airsane-supervisor.sh /usr/local/bin/airsane-supervisor.sh
RUN chmod +x /entrypoint.sh /usr/local/bin/airsane-supervisor.sh

CMD ["/entrypoint.sh"]
