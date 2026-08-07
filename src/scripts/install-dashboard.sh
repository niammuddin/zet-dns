#!/bin/sh
set -eu

test "$(id -u)" -eq 0 || {
    echo "install.sh harus dijalankan sebagai root" >&2
    exit 1
}

BUNDLE_DIR=${1:-/tmp/dnstrust-admin-bundle}
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

DASHBOARD_HEALTH_URL=${DASHBOARD_HEALTH_URL:-}
BACKUP_DIR=/var/backups/dnstrust-admin-preinstall-$(date -u +%Y%m%dT%H%M%SZ)
TLS_DIR=/etc/dnstrust-admin/tls
TLS_CERT=$TLS_DIR/server.crt
TLS_KEY=$TLS_DIR/server.key

if test ! -s "$(artifact_path config.json)" && test -s "$ARTIFACT_ROOT/etc/config.example.json"; then
    cp "$ARTIFACT_ROOT/etc/config.example.json" "$(artifact_path config.json)"
fi

for file in \
    dnstrust-admin config.json rpz.safesearch \
    dnstrust-admin.service \
    dnstrust-admin-collect.service dnstrust-admin-collect.timer \
    dnstrust-admin-worker.service dnstrust-admin-worker.path; do
    test -s "$(artifact_path "$file")" || {
        echo "artifact tidak ditemukan: $file" >&2
        exit 1
    }
done

install -d -m 0700 "$BACKUP_DIR"
for file in \
    /etc/nftables.conf \
    /etc/unbound/unbound.conf \
    /etc/unbound/whitelist.conf \
    /etc/unbound/safesearch.conf \
    /var/lib/dnstrust-admin/rpz.safesearch.source \
    /etc/dnstrust-admin/config.json \
    "$TLS_CERT" \
    "$TLS_KEY" \
    /usr/local/sbin/dnstrust-healthcheck; do
    if test -f "$file"; then
        cp -a "$file" "$BACKUP_DIR/$(printf '%s' "$file" | tr '/' '_')"
    fi
done

id dnstrust-admin >/dev/null 2>&1 || \
    useradd --system --home-dir /var/lib/dnstrust-admin --shell /usr/sbin/nologin dnstrust-admin

install -d -o root -g dnstrust-admin -m 0770 \
    /var/lib/dnstrust-admin \
    /var/lib/dnstrust-admin/queue \
    /var/lib/dnstrust-admin/actions \
    /var/lib/dnstrust-admin/backups
if ! grep -q '^; force .* safesearch' /var/lib/dnstrust-admin/rpz.safesearch.source 2>/dev/null; then
    install -o root -g dnstrust-admin -m 0640 "$(artifact_path rpz.safesearch)" /var/lib/dnstrust-admin/rpz.safesearch.source
fi
install -d -o root -g dnstrust-admin -m 0750 /etc/dnstrust-admin
install -o root -g root -m 0755 "$(artifact_path dnstrust-admin)" /usr/local/sbin/dnstrust-admin
if test ! -f /etc/dnstrust-admin/config.json; then
    install -o root -g dnstrust-admin -m 0640 "$(artifact_path config.json)" /etc/dnstrust-admin/config.json
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl diperlukan untuk HTTPS otomatis" >&2
    exit 1
fi
install -d -o root -g dnstrust-admin -m 0750 "$TLS_DIR"
if test ! -s "$TLS_CERT" || test ! -s "$TLS_KEY"; then
    san='DNS:localhost,IP:127.0.0.1'
    for ip in $(hostname -I 2>/dev/null || true); do
        case "$ip" in
            *.*) san="$san,IP:$ip" ;;
        esac
    done
    openssl req -x509 -newkey rsa:2048 -nodes -days 825 \
        -keyout "$TLS_KEY" \
        -out "$TLS_CERT" \
        -subj "/CN=dns-admin" \
        -addext "subjectAltName=$san" >/dev/null 2>&1
    chown root:dnstrust-admin "$TLS_KEY" "$TLS_CERT"
    chmod 0640 "$TLS_KEY"
    chmod 0644 "$TLS_CERT"
fi

config_tmp=$(mktemp)
sed \
    -e 's|^[[:space:]]*"tls_cert_file"[[:space:]]*:.*|  "tls_cert_file": "/etc/dnstrust-admin/tls/server.crt",|' \
    -e 's|^[[:space:]]*"tls_key_file"[[:space:]]*:.*|  "tls_key_file": "/etc/dnstrust-admin/tls/server.key"|' \
    /etc/dnstrust-admin/config.json > "$config_tmp"
install -o root -g dnstrust-admin -m 0640 "$config_tmp" /etc/dnstrust-admin/config.json
rm -f "$config_tmp"

for unit in \
    dnstrust-admin.service \
    dnstrust-admin-collect.service dnstrust-admin-collect.timer \
    dnstrust-admin-worker.service dnstrust-admin-worker.path; do
    install -o root -g root -m 0644 "$(artifact_path "$unit")" "/etc/systemd/system/$unit"
done

nft -c -f /etc/nftables.conf
systemctl daemon-reload
systemctl reload nftables.service
systemctl enable --now dnstrust-admin-collect.timer
systemctl enable --now dnstrust-admin-worker.path
systemctl start dnstrust-admin-collect.service
systemctl enable --now dnstrust-admin.service

sleep 1
systemctl is-active --quiet dnstrust-admin.service
systemctl is-active --quiet dnstrust-admin-collect.timer
systemctl is-active --quiet dnstrust-admin-worker.path
systemctl is-active --quiet dnstrust-unbound.service
if test -n "$DASHBOARD_HEALTH_URL"; then
    curl --insecure --silent --show-error --fail --max-time 5 "$DASHBOARD_HEALTH_URL/login" >/dev/null
fi

printf 'DNS Trust Admin installed. Backup: %s\n' "$BACKUP_DIR"
