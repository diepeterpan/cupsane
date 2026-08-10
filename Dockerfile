FROM sbs20/scanservjs:latest AS scanservjs

FROM alpine:edge

RUN echo 'https://dl-cdn.alpinelinux.org/alpine/edge/community' >> /etc/apk/repositories && \
    echo '@testing https://dl-cdn.alpinelinux.org/alpine/edge/testing' >> /etc/apk/repositories && \
    apk update && apk --no-cache add \
    curl cups cups-filters cups-pdf@testing ghostscript gutenprint \
    py3-reportlab libjpeg-turbo net-snmp libusb py3-dbus python3 \
    sane sane-backends sane-airscan \
    hplip sane-backend-hpaio \
    nodejs npm imagemagick

RUN apk add bash inotify-tools 
RUN apk add --no-cache -X https://dl-cdn.alpinelinux.org/alpine/edge/testing jbigkit
    
# Copy scanservjs from official image
COPY --from=scanservjs /usr/lib/scanservjs /app
COPY --from=scanservjs /etc/scanservjs /etc/scanservjs

# Create scanservjs data directories with preview images
RUN mkdir -p /var/lib/scanservjs/output /var/lib/scanservjs/temp /var/lib/scanservjs/preview && \
    chmod 777 /var/lib/scanservjs/output /var/lib/scanservjs/temp /var/lib/scanservjs/preview && \
    mkdir -p /run/saned && \
    magick -size 64x64 xc:white /var/lib/scanservjs/preview/default.jpg && \
    # Ensure essential SANE backends are enabled
    sed -i \
        -e 's/^#\s*hpaio\s*$/hpaio/' \
        -e 's/^#\s*airscan\s*$/airscan/' \
        -e 's/^#\s*net\s*$/net/' \
        /etc/sane.d/dll.conf && \
        (grep -qx 'hpaio' /etc/sane.d/dll.conf || echo 'hpaio' >> /etc/sane.d/dll.conf) && \
        (grep -qx 'airscan' /etc/sane.d/dll.conf || echo 'airscan' >> /etc/sane.d/dll.conf) && \
        (grep -qx 'net' /etc/sane.d/dll.conf || echo 'net' >> /etc/sane.d/dll.conf) && \
        echo 'usb' > /etc/sane.d/hpaio.conf && \
        printf "# SANE net backend servers\n127.0.0.1\n::1\nlocalhost\n" > /etc/sane.d/net.conf && \
    # Create a minimal SANE config dir that only loads hpaio (to avoid long scans)
    mkdir -p /etc/sane.only-hpaio && \
    printf "hpaio\n" > /etc/sane.only-hpaio/dll.conf && \
    printf "usb\n" > /etc/sane.only-hpaio/hpaio.conf

RUN wget https://github.com/vaginessa/ricoh-sp112-ppd/archive/refs/heads/master.zip
RUN unzip master.zip -d /tmp/extracted_files
COPY /tmp/extracted_files/ /app/ricoh-sp112-ppd/

WORKDIR /app

EXPOSE 631 6566 8081

COPY --chown=root:lp config/cupsd.conf /etc/cups/cupsd.conf
COPY config/saned.conf /etc/sane.d/saned.conf

# Override scanservjs to listen on port 8081
COPY config/scanservjs.local.json /etc/scanservjs/local.json
COPY config/scanservjs.config.js /etc/scanservjs/config.local.js

# Keep default copies to seed mounted volumes at runtime
RUN mkdir -p /opt/defaults && \
    cp /etc/cups/cupsd.conf /opt/defaults/cupsd.conf && \
    cp /etc/sane.d/saned.conf /opt/defaults/saned.conf

COPY entrypoint.sh /entrypoint.sh

RUN chmod +x /entrypoint.sh

CMD ["/entrypoint.sh"]
