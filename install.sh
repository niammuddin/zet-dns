#!/bin/sh
set -eu

test "$(id -u)" -eq 0 || {
    echo "install.sh harus dijalankan sebagai root" >&2
    exit 1
}

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname -- "$0")" && pwd)
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
    install-dns.sh install-dashboard.sh config.json \
    unbound unbound-checkconf unbound-control dnstrust-unbound \
    dnstrust-control verify-dnstrust-hot-remap blcreate libcdb.so.1 update-blacklist.sh \
    unbound.conf module-config.conf lamanlabuh.conf whitelist.conf \
    local.conf forwarder.conf hosts.conf tproxy.conf safesearch.conf \
    rpz.safesearch dnstrust-unbound.service \
    unbound-blacklist-update.service unbound-blacklist-update.timer \
    unbound-blacklist-update.env nftables.conf \
    disable-stub.conf dnstrust-admin \
    dnstrust-admin.service dnstrust-admin-collect.service \
    dnstrust-admin-collect.timer dnstrust-admin-worker.service \
    dnstrust-admin-worker.path; do
    test -s "$(artifact_path "$required")" || {
        echo "artifact tidak ditemukan: $required" >&2
        exit 1
    }
done

HOT_REMAP_HELPER=$(artifact_path dnstrust-unbound)
if grep -Eq 'unbound-control.*reload|\$UNBOUND_CONTROL.*reload' "$HOT_REMAP_HELPER"; then
    echo "dnstrust-unbound refresh tidak boleh reload Unbound" >&2
    exit 1
fi
grep -q 'sleep 1' "$HOT_REMAP_HELPER" || {
    echo "dnstrust-unbound tidak memuat hot-remap wait" >&2
    exit 1
}

command -v openssl >/dev/null 2>&1 || {
    echo "openssl diperlukan untuk HTTPS dan session key" >&2
    exit 1
}

printf 'Password dashboard (Enter untuk membuat password acak): '
stty -echo
IFS= read -r ADMIN_PASSWORD
stty echo
printf '\n'
if test -z "$ADMIN_PASSWORD"; then
    ADMIN_PASSWORD=$(openssl rand -base64 24 | tr -dc 'A-Za-z0-9' | cut -c1-20)
    GENERATED_PASSWORD=yes
else
    GENERATED_PASSWORD=no
fi
test "${#ADMIN_PASSWORD}" -ge 12 || {
    echo "password minimal 12 karakter" >&2
    exit 1
}

WORK=$(mktemp -d)
cleanup() { rm -rf "$WORK"; }
trap cleanup EXIT INT TERM
cp -a "$BUNDLE_DIR"/. "$WORK"/

# DNS installer owns the resolver, CDB, updater, nftables, and systemd units.
"$WORK/src/scripts/install-dns.sh" "$WORK"

PASS_HASH=$(printf '%s' "$ADMIN_PASSWORD" | "$WORK/src/bin/dnstrust-admin" hash-password)
SESSION_KEY=$(openssl rand -base64 32 | tr '+/' '-_' | tr -d '=')
CONFIG_TMP="$WORK/config.generated.json"
sed \
    -e 's|^[[:space:]]*"listen"[[:space:]]*:.*|  "listen": "0.0.0.0:9080",|' \
    -e "s|SET_WITH_HASH_PASSWORD|$PASS_HASH|" \
    -e "s|SET_WITH_RANDOM_BASE64URL_32_BYTES|$SESSION_KEY|" \
    "$WORK/src/etc/config.json" > "$CONFIG_TMP"
mv "$CONFIG_TMP" "$WORK/src/etc/config.json"

# Dashboard installer creates the self-signed HTTPS certificate and preserves
# the generated credentials during installation.
"$WORK/src/scripts/install-dashboard.sh" "$WORK"

echo
echo "DNS Trust installation completed successfully."
echo "Dashboard: https://$(hostname -I | awk '{print $1}'):9080/"
if test "$GENERATED_PASSWORD" = yes; then
    echo "Generated dashboard password: $ADMIN_PASSWORD"
else
    echo "Dashboard password: (password yang Anda masukkan saat instalasi)"
fi
echo "Session key: generated automatically and stored securely."
echo "Sertifikat self-signed: /etc/dnstrust-admin/tls/server.crt"
