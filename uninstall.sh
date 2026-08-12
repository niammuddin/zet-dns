#!/bin/sh
set -eu

test "$(id -u)" -eq 0 || {
    echo "uninstall.sh harus dijalankan sebagai root" >&2
    exit 1
}

if test "${1:-}" != "--yes"; then
    printf 'Ketik REMOVE DNS TRUST untuk melanjutkan penghapusan: '
    IFS= read -r answer
    test "$answer" = "REMOVE DNS TRUST" || {
        echo "dibatalkan" >&2
        exit 1
    }
fi

BACKUP=/var/backups/dnstrust-uninstall-$(date -u +%Y%m%dT%H%M%SZ)
install -d -m 0700 "$BACKUP"
for path in \
    /etc/unbound /var/lib/dnstrust /etc/default/unbound-blacklist-update \
    /etc/nftables.conf /etc/ssh/sshd_config.d/99-dnstrust-clean.conf \
    /etc/systemd/resolved.conf.d/disable-stub.conf \
    /etc/dnstrust-admin /var/lib/dnstrust-admin \
    /etc/systemd/system/dnstrust-unbound.service \
    /etc/systemd/system/unbound-blacklist-update.service \
    /etc/systemd/system/unbound-blacklist-update.timer \
    /etc/systemd/system/dnstrust-tproxy-routing.service \
    /etc/systemd/system/dnstrust-admin.service \
    /etc/systemd/system/dnstrust-admin-collect.service \
    /etc/systemd/system/dnstrust-admin-collect.timer \
    /etc/systemd/system/dnstrust-admin-worker.service \
    /etc/systemd/system/dnstrust-admin-worker.path; do
    if test -e "$path"; then
        dest="$BACKUP$(printf '%s' "$path" | tr '/' '_')"
        cp -a "$path" "$dest"
    fi
done

for unit in \
    dnstrust-admin.service dnstrust-admin-collect.timer \
    dnstrust-admin-worker.path dnstrust-unbound.service \
    unbound-blacklist-update.timer unbound-blacklist-update.service \
    dnstrust-tproxy-routing.service nftables.service; do
    systemctl disable --now "$unit" 2>/dev/null || true
done

rm -f \
    /usr/local/sbin/unbound /usr/local/sbin/unbound-checkconf \
    /usr/local/sbin/unbound-control /usr/local/sbin/update-dnstrust-blacklist \
    /usr/local/sbin/dnstrust-control /usr/local/sbin/verify-dnstrust-hot-remap \
    /usr/local/sbin/dnstrust-admin \
    /usr/local/libexec/dnstrust-unbound /usr/local/bin/blcreate \
    /usr/local/lib/libcdb.so.1 /etc/default/unbound-blacklist-update \
    /etc/nftables.conf /etc/tproxy.conf \
    /etc/ssh/sshd_config.d/99-dnstrust-clean.conf \
    /etc/systemd/resolved.conf.d/disable-stub.conf
rm -rf /etc/dnstrust-admin /var/lib/dnstrust-admin /var/lib/dnstrust
rm -f /etc/systemd/system/dnstrust-*.service \
    /etc/systemd/system/dnstrust-*.timer \
    /etc/systemd/system/dnstrust-*.path \
    /etc/systemd/system/unbound-blacklist-update.service \
    /etc/systemd/system/unbound-blacklist-update.timer
rm -rf /etc/unbound

userdel dnstrust-admin 2>/dev/null || true
userdel dnstrust 2>/dev/null || true
systemctl daemon-reload
systemctl restart systemd-resolved.service 2>/dev/null || true
systemctl reload ssh.service 2>/dev/null || true

echo "DNS Trust dan dashboard dihapus. Backup konfigurasi: $BACKUP"
