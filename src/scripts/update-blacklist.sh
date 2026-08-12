#!/bin/sh
set -eu

PATH=/etc/unbound/tool:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH

SOURCE_URL=${SOURCE_URL:-https://trustpositif.komdigi.go.id/assets/db/domains_isp}
SOURCE_NAME=${SOURCE_NAME:-domains_isp}
DBDIR=${DBDIR:-/var/lib/dnstrust}
MIN_BYTES=${MIN_BYTES:-50000000}
MIN_DOMAINS=${MIN_DOMAINS:-1000000}
MIN_FREE_BYTES=${MIN_FREE_BYTES:-1500000000}
MAX_SHRINK_PERCENT=${MAX_SHRINK_PERCENT:-20}
RELATIVE_CHECK_MIN_DOMAINS=${RELATIVE_CHECK_MIN_DOMAINS:-100000}
MAX_REJECTED_LINES=${MAX_REJECTED_LINES:-10000}
HEALTHCHECK_SERVER=${HEALTHCHECK_SERVER:-127.0.0.1}
HEALTHCHECK_PORT=${HEALTHCHECK_PORT:-53}
HEALTHCHECK_DOMAIN=${HEALTHCHECK_DOMAIN:-}
HEALTHCHECK_ALLOWED_DOMAIN=${HEALTHCHECK_ALLOWED_DOMAIN:-}
HEALTHCHECK_ALLOWED_EXPECTED=${HEALTHCHECK_ALLOWED_EXPECTED:-}
DN_COMMAND=${DN_COMMAND:-/usr/local/sbin/dnstrust-control}
BLCREATE_COMMAND=${BLCREATE_COMMAND:-blcreate}
PERSIST_COMMAND=${PERSIST_COMMAND:-}
PERSIST_DIR=${PERSIST_DIR:-}
LOCK_HOLD_SECONDS=${LOCK_HOLD_SECONDS:-0}
FAULT_POINT=${FAULT_POINT:-}

ACTIVE_CDB="$DBDIR/blacklist.db"
ACTIVE_RAW="$DBDIR/trust.txt.raw"
ACTIVE_LIST="$DBDIR/trust.txt"
ACTIVE_REJECTED="$DBDIR/trust.rejected"
ACTIVE_METADATA="$DBDIR/trust.metadata"
ACTIVE_COUNT="$DBDIR/trust.count"
ACTIVE_ETAG="$DBDIR/domains_isp.etag"
ACTIVE_LASTCHECK="$DBDIR/trust.lastcheck"

PREVIOUS_CDB="$DBDIR/blacklist.db.previous"
PREVIOUS_RAW="$DBDIR/trust.txt.raw.previous"
PREVIOUS_LIST="$DBDIR/trust.txt.previous"
PREVIOUS_REJECTED="$DBDIR/trust.rejected.previous"
PREVIOUS_METADATA="$DBDIR/trust.metadata.previous"
PREVIOUS_COUNT="$DBDIR/trust.count.previous"
PREVIOUS_ETAG="$DBDIR/domains_isp.etag.previous"
PREVIOUS_LASTCHECK="$DBDIR/trust.lastcheck.previous"

PENDING="$DBDIR/.activation.pending"
LOCK=${LOCK_FILE:-/etc/unbound/run/update-blacklist.lock}
STAGE="$DBDIR/.update-stage.$$"
RAW_NEW="$STAGE/source.raw"
LIST_UNSORTED="$STAGE/trust.unsorted"
LIST_NEW="$STAGE/trust.txt"
REJECTED_NEW="$STAGE/trust.rejected"
METADATA_NEW="$STAGE/trust.metadata"
COUNT_NEW="$STAGE/trust.count"
ETAG_NEW="$STAGE/domains_isp.etag"
HEADERS_NEW="$STAGE/headers"
CDB_NEW="$STAGE/blacklist.db"

log() {
    printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*"
}

fail() {
    log "ERROR: $*" >&2
    exit 1
}

validate_uint() {
    variable_name=$1
    variable_value=$2
    case "$variable_value" in
        ''|*[!0-9]*) fail "$variable_name must be an unsigned integer" ;;
    esac
}

cleanup_stage() {
    stage_dir=$1
    case "$stage_dir" in
        "$DBDIR"/.update-stage.*) ;;
        *) return ;;
    esac

    rm -f \
        "$stage_dir/source.raw" \
        "$stage_dir/trust.unsorted" \
        "$stage_dir/trust.txt" \
        "$stage_dir/trust.rejected" \
        "$stage_dir/trust.metadata" \
        "$stage_dir/trust.count" \
        "$stage_dir/domains_isp.etag" \
        "$stage_dir/headers" \
        "$stage_dir/blacklist.db" \
        "$stage_dir/blacklist.db.tmp"
    rmdir "$stage_dir" 2>/dev/null || true
}

cleanup() {
    rm -f "$PENDING.tmp" "$ACTIVE_LASTCHECK.tmp"
    cleanup_stage "$STAGE"
}
trap cleanup EXIT HUP INT TERM

restore_file() {
    active=$1
    previous=$2
    rm -f "$active"
    if [ -f "$previous" ]; then
        mv "$previous" "$active"
    fi
}

persist_state() {
    [ -n "$PERSIST_COMMAND" ] || return 0
    /bin/sh -c "$PERSIST_COMMAND"
}

rollback_previous() {
    reason=$1
    [ -f "$PREVIOUS_CDB" ] || fail "rollback unavailable: $reason"

    log "rolling back activation: $reason"
    rm -f "$DBDIR/blacklist.db.failed"
    if [ -f "$ACTIVE_CDB" ]; then
        mv "$ACTIVE_CDB" "$DBDIR/blacklist.db.failed"
    fi
    mv "$PREVIOUS_CDB" "$ACTIVE_CDB"

    restore_file "$ACTIVE_RAW" "$PREVIOUS_RAW"
    restore_file "$ACTIVE_LIST" "$PREVIOUS_LIST"
    restore_file "$ACTIVE_REJECTED" "$PREVIOUS_REJECTED"
    restore_file "$ACTIVE_METADATA" "$PREVIOUS_METADATA"
    restore_file "$ACTIVE_COUNT" "$PREVIOUS_COUNT"
    restore_file "$ACTIVE_ETAG" "$PREVIOUS_ETAG"
    restore_file "$ACTIVE_LASTCHECK" "$PREVIOUS_LASTCHECK"

    if ! "$DN_COMMAND" refresh; then
        fail "rollback file selesai tetapi dnstrust-unbound refresh gagal"
    fi
    if ! persist_state; then
        fail "rollback aktif tetapi persistence sync gagal"
    fi

    pending_stage=$(sed -n 's/^stage=//p' "$PENDING" 2>/dev/null || true)
    rm -f "$PENDING"
    if [ -n "$pending_stage" ]; then
        cleanup_stage "$pending_stage"
    fi
    log "rollback completed"
}

recover_pending_activation() {
    [ -f "$PENDING" ] || return 0
    log "unfinished activation marker found"

    if [ -f "$PREVIOUS_CDB" ]; then
        rollback_previous "recovery after interrupted updater"
    else
        pending_stage=$(sed -n 's/^stage=//p' "$PENDING" 2>/dev/null || true)
        rm -f "$PENDING"
        if [ -n "$pending_stage" ]; then
            cleanup_stage "$pending_stage"
        fi
        log "marker cleared; active database had not been replaced"
    fi
}

backup_file() {
    active=$1
    previous=$2
    rm -f "$previous"
    if [ -f "$active" ]; then
        mv "$active" "$previous"
    fi
}

read_blacklist_counter() {
    "$DN_COMMAND" stats_noreset \
        | awk -F= '/^total[.]num[.]blacklist=/{print $2; exit}'
}

health_check() {
    check_domain=$HEALTHCHECK_DOMAIN
    if [ -z "$check_domain" ]; then
        check_domain=$(head -n 1 "$ACTIVE_LIST")
    fi
    [ -n "$check_domain" ] || return 1

    before=$(read_blacklist_counter)
    case "$before" in
        ''|*[!0-9]*) return 1 ;;
    esac

    answer=$(dig +short +time=3 +tries=1 \
        "@$HEALTHCHECK_SERVER" -p "$HEALTHCHECK_PORT" \
        "$check_domain" A)
    [ -n "$answer" ] || return 1

    after=$(read_blacklist_counter)
    case "$after" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$after" -gt "$before" ] || return 1

    if [ -n "$HEALTHCHECK_ALLOWED_DOMAIN" ]; then
        allowed_answer=$(dig +short +time=3 +tries=1 \
            "@$HEALTHCHECK_SERVER" -p "$HEALTHCHECK_PORT" \
            "$HEALTHCHECK_ALLOWED_DOMAIN" A)
        [ -n "$allowed_answer" ] || return 1
        if [ -n "$HEALTHCHECK_ALLOWED_EXPECTED" ]; then
            [ "$allowed_answer" = "$HEALTHCHECK_ALLOWED_EXPECTED" ] || return 1
        fi
    fi

    log "health check passed: $check_domain -> $(printf '%s' "$answer" | tr '\n' ',')"
}

mkdir -p "$DBDIR" /etc/unbound/run
validate_uint MIN_BYTES "$MIN_BYTES"
validate_uint MIN_DOMAINS "$MIN_DOMAINS"
validate_uint MIN_FREE_BYTES "$MIN_FREE_BYTES"
validate_uint MAX_SHRINK_PERCENT "$MAX_SHRINK_PERCENT"
validate_uint RELATIVE_CHECK_MIN_DOMAINS "$RELATIVE_CHECK_MIN_DOMAINS"
validate_uint MAX_REJECTED_LINES "$MAX_REJECTED_LINES"
validate_uint HEALTHCHECK_PORT "$HEALTHCHECK_PORT"
validate_uint LOCK_HOLD_SECONDS "$LOCK_HOLD_SECONDS"
if [ "$MAX_SHRINK_PERCENT" -gt 99 ]; then
    fail "MAX_SHRINK_PERCENT must be between 0 and 99"
fi

exec 9>"$LOCK"
if ! flock -n 9; then
    log "update already running"
    exit 0
fi

if [ "$LOCK_HOLD_SECONDS" -gt 0 ]; then
    sleep "$LOCK_HOLD_SECONDS"
fi

recover_pending_activation

free_kb=$(df -Pk "$DBDIR" | awk 'NR==2 {print $4}')
case "$free_kb" in
    ''|*[!0-9]*) fail "unable to determine free disk space" ;;
esac
db_fstype=$(findmnt -n -o FSTYPE -T "$DBDIR" 2>/dev/null || true)
if [ "$free_kb" -eq 0 ] && [ "$db_fstype" = "tmpfs" ]; then
    free_kb=$(awk '/^MemAvailable:/{print $2; exit}' /proc/meminfo)
    case "$free_kb" in
        ''|*[!0-9]*) fail "unable to determine available memory for tmpfs" ;;
    esac
fi
free_bytes=$((free_kb * 1024))
if [ "$free_bytes" -lt "$MIN_FREE_BYTES" ]; then
    fail "insufficient free space: $free_bytes bytes, minimum $MIN_FREE_BYTES"
fi
if [ -n "$PERSIST_DIR" ]; then
    [ -d "$PERSIST_DIR" ] || fail "persistence directory not found: $PERSIST_DIR"
    persist_free_kb=$(df -Pk "$PERSIST_DIR" | awk 'NR==2 {print $4}')
    case "$persist_free_kb" in
        ''|*[!0-9]*) fail "unable to determine persistence free space" ;;
    esac
    persist_free_bytes=$((persist_free_kb * 1024))
    if [ "$persist_free_bytes" -lt "$MIN_FREE_BYTES" ]; then
        fail "insufficient persistence space: $persist_free_bytes bytes, minimum $MIN_FREE_BYTES"
    fi
fi

mkdir "$STAGE"
started_at=$(date +%s)

set -- curl \
    --silent \
    --show-error \
    --location \
    --fail \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 20 \
    --max-time 900 \
    --dump-header "$HEADERS_NEW" \
    --etag-save "$ETAG_NEW" \
    --output "$RAW_NEW" \
    --write-out "%{http_code}"

if [ -s "$ACTIVE_ETAG" ]; then
    set -- "$@" --etag-compare "$ACTIVE_ETAG"
fi

HTTP_CODE=$("$@" "$SOURCE_URL")
case "$HTTP_CODE" in
    304)
        log "$SOURCE_NAME unchanged"
        exit 0
        ;;
    200) ;;
    *) fail "unexpected HTTP status: $HTTP_CODE" ;;
esac

if [ "$FAULT_POINT" = "after-download" ]; then
    fail "injected fault after download"
fi

RAW_BYTES=$(wc -c < "$RAW_NEW")
RAW_DOMAINS=$(wc -l < "$RAW_NEW")
if [ "$RAW_BYTES" -lt "$MIN_BYTES" ]; then
    fail "download rejected: $RAW_BYTES bytes, minimum $MIN_BYTES"
fi
if [ "$RAW_DOMAINS" -lt "$MIN_DOMAINS" ]; then
    fail "download rejected: $RAW_DOMAINS lines, minimum $MIN_DOMAINS"
fi
if head -c 4096 "$RAW_NEW" | grep -Eiq '<html|<!doctype|access denied'; then
    fail "download rejected: response looks like HTML"
fi

SOURCE_SHA256=$(sha256sum "$RAW_NEW" | awk '{print $1}')
LAST_MODIFIED=$(awk 'BEGIN{IGNORECASE=1} /^last-modified:/{sub(/^[^:]*:[[:space:]]*/,""); sub(/\r$/,""); print; exit}' "$HEADERS_NEW")
NEW_ETAG=$(sed -n '1p' "$ETAG_NEW" 2>/dev/null || true)

ACTIVE_SHA256=""
if [ -s "$ACTIVE_METADATA" ]; then
    ACTIVE_SHA256=$(sed -n 's/^source_sha256=//p' "$ACTIVE_METADATA")
fi
if [ -z "$ACTIVE_SHA256" ] && [ -s "$ACTIVE_RAW" ]; then
    ACTIVE_SHA256=$(sha256sum "$ACTIVE_RAW" | awk '{print $1}')
fi

if [ -n "$ACTIVE_SHA256" ] && [ "$SOURCE_SHA256" = "$ACTIVE_SHA256" ]; then
    cat > "$ACTIVE_LASTCHECK.tmp" <<EOF
checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_url=$SOURCE_URL
http_status=$HTTP_CODE
etag=$NEW_ETAG
last_modified=$LAST_MODIFIED
source_sha256=$SOURCE_SHA256
result=unchanged-by-content-hash
EOF
    mv "$ACTIVE_LASTCHECK.tmp" "$ACTIVE_LASTCHECK"
    if [ -s "$ETAG_NEW" ]; then
        mv "$ETAG_NEW" "$ACTIVE_ETAG"
    fi
    rm -f "$DBDIR/blacklist.db.failed"
    if ! persist_state; then
        fail "content unchanged but persistence sync failed"
    fi
    log "$SOURCE_NAME content unchanged: sha256=$SOURCE_SHA256"
    exit 0
fi

# Generasi lama kedua tidak lagi diperlukan saat konten baru benar-benar beda.
# Generasi aktif akan menjadi previous pada saat transaksi aktivasi.
rm -f \
    "$PREVIOUS_CDB" \
    "$PREVIOUS_RAW" \
    "$PREVIOUS_LIST" \
    "$PREVIOUS_REJECTED" \
    "$PREVIOUS_METADATA" \
    "$PREVIOUS_COUNT" \
    "$PREVIOUS_ETAG" \
    "$PREVIOUS_LASTCHECK"

: > "$REJECTED_NEW"
LC_ALL=C awk -v rejected="$REJECTED_NEW" '
{
    original=$0
    domain=tolower($0)
    sub(/\r$/, "", domain)
    reason=""

    if (length(domain) == 0) reason="empty"
    else if (length(domain) > 253) reason="domain-too-long"
    else if (domain ~ /[^a-z0-9._-]/) reason="invalid-character"
    else if (domain ~ /^\./ || domain ~ /\.$/ || domain ~ /\.\./) reason="empty-label"

    if (reason == "") {
        labels=split(domain, label, ".")
        for (i=1; i<=labels; i++) {
            if (length(label[i]) > 63) {
                reason="label-too-long"
                break
            }
            if (label[i] ~ /^-/ || label[i] ~ /-$/) {
                reason="hyphen-edge"
                break
            }
        }
    }

    if (reason != "") {
        printf "%d\t%s\t%s\n", NR, reason, original >> rejected
    } else {
        print domain
    }
}' "$RAW_NEW" > "$LIST_UNSORTED"

VALID_BEFORE_DEDUPE=$(wc -l < "$LIST_UNSORTED")
LC_ALL=C sort -u "$LIST_UNSORTED" > "$LIST_NEW"
ACTIVE_DOMAINS=$(wc -l < "$LIST_NEW")
REJECTED_DOMAINS=$(wc -l < "$REJECTED_NEW")
DUPLICATE_DOMAINS=$((VALID_BEFORE_DEDUPE - ACTIVE_DOMAINS))

if [ "$ACTIVE_DOMAINS" -lt "$MIN_DOMAINS" ]; then
    fail "normalized list rejected: $ACTIVE_DOMAINS domains, minimum $MIN_DOMAINS"
fi
if [ "$REJECTED_DOMAINS" -gt "$MAX_REJECTED_LINES" ]; then
    fail "normalized list rejected: $REJECTED_DOMAINS invalid lines"
fi

previous_count=0
if [ -s "$ACTIVE_COUNT" ]; then
    previous_count=$(sed -n '1p' "$ACTIVE_COUNT")
elif [ -s "$ACTIVE_LIST" ]; then
    previous_count=$(wc -l < "$ACTIVE_LIST")
fi
case "$previous_count" in
    ''|*[!0-9]*) previous_count=0 ;;
esac

if [ "$previous_count" -ge "$RELATIVE_CHECK_MIN_DOMAINS" ]; then
    minimum_relative=$((previous_count * (100 - MAX_SHRINK_PERCENT) / 100))
    if [ "$ACTIVE_DOMAINS" -lt "$minimum_relative" ]; then
        fail "list shrank from $previous_count to $ACTIVE_DOMAINS; minimum allowed $minimum_relative"
    fi
fi

printf '%s\n' "$ACTIVE_DOMAINS" > "$COUNT_NEW"
build_started=$(date +%s)
(
    cd "$STAGE"
    "$BLCREATE_COMMAND" < trust.txt
)
build_finished=$(date +%s)
[ -s "$CDB_NEW" ] || fail "blcreate did not produce blacklist.db"
# Unbound workers run as an unprivileged user and hot-remap this file after the
# atomic activation below. Keep it readable without reloading the daemon.
chmod 0644 "$CDB_NEW"

if [ "$FAULT_POINT" = "after-build" ]; then
    fail "injected fault after build"
fi

finished_at=$(date +%s)
cat > "$METADATA_NEW" <<EOF
source_name=$SOURCE_NAME
source_url=$SOURCE_URL
updated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
http_status=$HTTP_CODE
etag=$NEW_ETAG
last_modified=$LAST_MODIFIED
source_sha256=$SOURCE_SHA256
raw_bytes=$RAW_BYTES
raw_domains=$RAW_DOMAINS
active_domains=$ACTIVE_DOMAINS
rejected_domains=$REJECTED_DOMAINS
duplicate_domains=$DUPLICATE_DOMAINS
cdb_bytes=$(wc -c < "$CDB_NEW")
download_validate_build_seconds=$((finished_at - started_at))
blcreate_seconds=$((build_finished - build_started))
EOF

cat > "$PENDING.tmp" <<EOF
stage=$STAGE
started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
EOF
mv "$PENDING.tmp" "$PENDING"

# CDB dipindahkan pertama sehingga recovery selalu memiliki database rollback.
backup_file "$ACTIVE_CDB" "$PREVIOUS_CDB"
backup_file "$ACTIVE_RAW" "$PREVIOUS_RAW"
backup_file "$ACTIVE_LIST" "$PREVIOUS_LIST"
backup_file "$ACTIVE_REJECTED" "$PREVIOUS_REJECTED"
backup_file "$ACTIVE_METADATA" "$PREVIOUS_METADATA"
backup_file "$ACTIVE_COUNT" "$PREVIOUS_COUNT"
backup_file "$ACTIVE_ETAG" "$PREVIOUS_ETAG"
backup_file "$ACTIVE_LASTCHECK" "$PREVIOUS_LASTCHECK"

mv "$CDB_NEW" "$ACTIVE_CDB"
mv "$RAW_NEW" "$ACTIVE_RAW"
mv "$LIST_NEW" "$ACTIVE_LIST"
mv "$REJECTED_NEW" "$ACTIVE_REJECTED"
mv "$METADATA_NEW" "$ACTIVE_METADATA"
mv "$COUNT_NEW" "$ACTIVE_COUNT"

if [ "$FAULT_POINT" = "after-activate" ]; then
    log "injecting hard crash after activation"
    kill -9 $$
fi

if ! "$DN_COMMAND" refresh; then
    rollback_previous "dnstrust-unbound refresh failed"
    fail "new database activation failed"
fi

if ! health_check; then
    rollback_previous "post-refresh health check failed"
    fail "new database failed health check"
fi

if [ -s "$ETAG_NEW" ]; then
    mv "$ETAG_NEW" "$ACTIVE_ETAG"
fi
rm -f "$DBDIR/blacklist.db.failed"
cat > "$ACTIVE_LASTCHECK.tmp" <<EOF
checked_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
source_url=$SOURCE_URL
http_status=$HTTP_CODE
etag=$NEW_ETAG
last_modified=$LAST_MODIFIED
source_sha256=$SOURCE_SHA256
result=activated
EOF
mv "$ACTIVE_LASTCHECK.tmp" "$ACTIVE_LASTCHECK"
if ! persist_state; then
    rollback_previous "persistence sync failed"
    fail "new database could not be persisted"
fi
rm -f "$PENDING"

log "blacklist activated: raw=$RAW_DOMAINS active=$ACTIVE_DOMAINS rejected=$REJECTED_DOMAINS duplicates=$DUPLICATE_DOMAINS bytes=$RAW_BYTES"
