#!/bin/sh
set -eu

test "$(id -u)" -eq 0 || {
    echo "install.sh must run as root" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUNDLE_DIR=${1:-"$SCRIPT_DIR"}
ARTIFACT_ROOT=$BUNDLE_DIR/src

artifact_path() {
    name=$1
    for dir in bin scripts systemd etc/unbound etc; do
        if [ -f "$ARTIFACT_ROOT/$dir/$name" ]; then
            printf '%s/%s/%s\n' "$ARTIFACT_ROOT" "$dir" "$name"
            return 0
        fi
    done
    return 1
}

for required in \
    unbound \
    unbound-checkconf \
    unbound-control \
    dnstrust-unbound \
    dnstrust-control \
    blcreate \
    libcdb.so.1 \
    update-blacklist.sh \
    unbound.conf \
    module-config.conf \
    lamanlabuh.conf \
    local.conf \
    forwarder.conf \
    hosts.conf \
    tproxy.conf \
    rpz.safesearch \
    safesearch.conf \
    whitelist.conf \
    dnstrust-unbound.service \
    unbound-blacklist-update.service \
    unbound-blacklist-update.timer \
    unbound-blacklist-update.env \
    nftables.conf \
    disable-stub.conf; do
    test -s "$(artifact_path "$required")" || {
        echo "missing bundle artifact: $required" >&2
        exit 1
    }
done

for command in ldconfig runuser unbound-anchor sshd nft systemctl dig; do
    command -v "$command" >/dev/null 2>&1 || {
        echo "required host command missing: $command" >&2
        exit 1
    }
done

is_lxc() {
    if command -v systemd-detect-virt >/dev/null 2>&1; then
        test "$(systemd-detect-virt --container 2>/dev/null || true)" = lxc && return 0
    fi
    grep -qa 'container=lxc' /proc/1/environ 2>/dev/null && return 0
    return 1
}

if is_lxc; then
    nft list tables >/dev/null 2>&1 || {
        echo "LXC detected but nftables is not usable; enable NET_ADMIN / privileged container first" >&2
        exit 1
    }
else
    systemctl list-unit-files qemu-guest-agent.service >/dev/null 2>&1 || {
        echo "qemu-guest-agent.service is missing; install qemu-guest-agent first" >&2
        exit 1
    }
fi

IN_LXC=no
is_lxc && IN_LXC=yes || true
if test "$IN_LXC" = yes; then
    echo "LXC detected: skipping qemu-guest-agent and getty units"
fi

id dnstrust >/dev/null 2>&1 || \
    useradd --system --home-dir /var/lib/dnstrust --shell /usr/sbin/nologin dnstrust

install -d -o root -g root -m 0755 /etc/unbound /etc/systemd/system
install -d -o dnstrust -g dnstrust -m 0750 /etc/unbound/run /var/lib/dnstrust
install -d -o dnstrust -g dnstrust -m 0750 /run/dnstrust
install -d -o root -g root -m 0755 /usr/local/libexec

install -o root -g root -m 0755 "$(artifact_path unbound)" /usr/local/sbin/unbound
install -o root -g root -m 0755 "$(artifact_path unbound-checkconf)" /usr/local/sbin/unbound-checkconf
install -o root -g root -m 0755 "$(artifact_path unbound-control)" /usr/local/sbin/unbound-control
install -o root -g root -m 0755 "$(artifact_path dnstrust-unbound)" /usr/local/libexec/dnstrust-unbound
install -o root -g root -m 0755 "$(artifact_path blcreate)" /usr/local/bin/blcreate
install -o root -g root -m 0755 "$(artifact_path update-blacklist.sh)" /usr/local/sbin/update-dnstrust-blacklist
install -o root -g root -m 0755 "$(artifact_path dnstrust-control)" /usr/local/sbin/dnstrust-control
install -o root -g root -m 0644 "$(artifact_path libcdb.so.1)" /usr/local/lib/libcdb.so.1

install -o root -g root -m 0644 "$(artifact_path unbound.conf)" /etc/unbound/unbound.conf
install -o root -g root -m 0644 "$(artifact_path module-config.conf)" /etc/unbound/module-config.conf
install -o root -g root -m 0644 "$(artifact_path lamanlabuh.conf)" /etc/unbound/lamanlabuh.conf
install -o root -g root -m 0644 "$(artifact_path whitelist.conf)" /etc/unbound/whitelist.conf
install -o root -g root -m 0644 "$(artifact_path local.conf)" /etc/unbound/local.conf
install -o root -g root -m 0644 "$(artifact_path forwarder.conf)" /etc/unbound/forwarder.conf
install -o root -g root -m 0644 "$(artifact_path hosts.conf)" /etc/unbound/hosts.conf
install -o root -g root -m 0644 "$(artifact_path tproxy.conf)" /etc/unbound/tproxy.conf
install -o root -g root -m 0644 "$(artifact_path rpz.safesearch)" /etc/unbound/rpz.safesearch
install -o root -g root -m 0644 "$(artifact_path safesearch.conf)" /etc/unbound/safesearch.conf
install -o root -g root -m 0644 "$(artifact_path dnstrust-unbound.service)" /etc/systemd/system/dnstrust-unbound.service
install -o root -g root -m 0644 "$(artifact_path unbound-blacklist-update.service)" /etc/systemd/system/unbound-blacklist-update.service
install -o root -g root -m 0644 "$(artifact_path unbound-blacklist-update.timer)" /etc/systemd/system/unbound-blacklist-update.timer
install -o root -g root -m 0644 "$(artifact_path unbound-blacklist-update.env)" /etc/default/unbound-blacklist-update
install -o root -g root -m 0644 "$(artifact_path nftables.conf)" /etc/nftables.conf
install -d -o root -g root -m 0755 /etc/systemd/resolved.conf.d
install -o root -g root -m 0644 "$(artifact_path disable-stub.conf)" /etc/systemd/resolved.conf.d/disable-stub.conf

ldconfig

if test ! -s /var/lib/dnstrust/root.key; then
    if ! runuser -u dnstrust -- \
        /usr/sbin/unbound-anchor -a /var/lib/dnstrust/root.key; then
        test -s /var/lib/dnstrust/root.key || {
            echo "unable to initialize DNSSEC root trust anchor" >&2
            exit 1
        }
    fi
fi

if test ! -s /var/lib/dnstrust/blacklist.db; then
    printf '%s\n' seed.invalid > /var/lib/dnstrust/trust.txt
    (
        cd /var/lib/dnstrust
        /usr/local/bin/blcreate < trust.txt
    )
    chown dnstrust:dnstrust /var/lib/dnstrust/trust.txt /var/lib/dnstrust/blacklist.db
    chmod 0644 /var/lib/dnstrust/blacklist.db
fi

/usr/local/sbin/unbound-checkconf /etc/unbound/unbound.conf
/usr/sbin/sshd -t
/usr/sbin/nft -c -f /etc/nftables.conf

systemctl daemon-reload
systemctl set-default multi-user.target
if test "$IN_LXC" = no; then
    systemctl enable getty@tty1.service serial-getty@ttyS0.service
    systemctl enable --now qemu-guest-agent.service
fi
systemctl restart systemd-resolved.service
systemctl enable --now dnstrust-unbound.service
systemctl enable --now unbound-blacklist-update.timer
systemctl enable --now nftables.service
systemctl reload ssh.service

echo "Fresh DNS Trust baseline installed"
