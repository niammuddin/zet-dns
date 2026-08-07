FROM debian:bookworm

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y --no-install-recommends \
    systemd \
    systemd-sysv \
    systemd-resolved \
    openssh-server \
    nftables \
    dnsutils \
    unbound \
    unbound-anchor \
    netbase \
    qemu-guest-agent \
    curl \
    ca-certificates \
    openssl \
    util-linux \
    iproute2 \
    procps \
    && apt-get clean && rm -rf /var/lib/apt/lists/*

# Stub qemu-guest-agent: a container has no virtio-serial port, so the stock
# unit (BindsTo=dev-virtio-ports-...) can never start. Replace it to mirror a
# working appliance guest agent.
COPY qemu-guest-agent.service /etc/systemd/system/qemu-guest-agent.service
RUN systemctl enable qemu-guest-agent.service

STOPSIGNAL SIGRTMIN+3

CMD ["/sbin/init"]
