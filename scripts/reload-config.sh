#!/bin/sh
#
# Ask Prometheus, Alertmanager and blackbox_exporter to re-read their
# configuration.
#
# Runs as the config-reload service on every `docker compose up -d`, after both
# are up. Compose only recreates a container when its own definition changes,
# so editing a mounted config file alone would otherwise leave the running
# process on the old config until it was restarted by hand.
#
# Reloading is cheap and idempotent, so this fires unconditionally rather than
# trying to detect what changed.
#
# Prometheus needs --web.enable-lifecycle for its reload endpoint to exist;
# without it the endpoint returns 403.

set -eu

PROM_URL="${PROM_URL:-https://prometheus:9090}"
ALERT_URL="${ALERT_URL:-https://alertmanager:9093}"
# blackbox_exporter reads its modules once at startup, and its container is not
# recreated when only .env changes -- so without this reload a new entry in
# BLACKBOX_DNS_TARGETS reaches Prometheus as a target whose module the exporter
# has never heard of. No credentials: it listens on the internal network only.
BLACKBOX_URL="${BLACKBOX_URL:-http://blackbox-exporter:9115}"
SECRETS_DIR="${SECRETS_DIR:-/run/secrets}"
RETRIES="${RETRIES:-30}"
# Which account to log in as. An account is the file secrets/<service>_<user>,
# so the username is part of the filename holding its password.
PROMETHEUS_WEB_USER="${PROMETHEUS_WEB_USER:-admin}"
ALERTMANAGER_WEB_USER="${ALERTMANAGER_WEB_USER:-admin}"

log() { echo "[reload] $*"; }

read_pw() {
  f="$SECRETS_DIR/$1_$2"
  [ -f "$f" ] || { echo "[reload] ERROR: no password file $f" >&2; exit 1; }
  cat "$f"
}

prom_pw=$(read_pw prometheus   "$PROMETHEUS_WEB_USER")
alert_pw=$(read_pw alertmanager "$ALERTMANAGER_WEB_USER")

# Self-signed certificate, so certificate verification is skipped. The
# connection is still encrypted and still requires the basic-auth credentials.
CURL="curl -sS --insecure --max-time 5"

# curl with or without credentials. An empty username means the endpoint takes
# none, and sending an empty Authorization header instead would be a request
# to be rejected rather than a request without auth.
call() {
  user="$1"; pw="$2"; shift 2
  if [ -n "$user" ]; then
    $CURL -u "$user:$pw" "$@"
  else
    $CURL "$@"
  fi
}

wait_for() {
  name="$1"; url="$2"; user="$3"; pw="$4"
  i=0
  while [ "$i" -lt "$RETRIES" ]; do
    if call "$user" "$pw" -o /dev/null "$url/-/ready" 2>/dev/null; then
      return 0
    fi
    i=$((i + 1))
  done
  log "WARNING: $name did not become ready after $RETRIES attempts; skipping"
  return 1
}

reload() {
  name="$1"; url="$2"; user="$3"; pw="$4"
  wait_for "$name" "$url" "$user" "$pw" || return 0

  code=$(call "$user" "$pw" -o /dev/null -w '%{http_code}' -X POST "$url/-/reload" || echo 000)
  case "$code" in
    200) log "$name reloaded" ;;
    403) log "WARNING: $name returned 403 -- lifecycle endpoint disabled" ;;
    401) log "WARNING: $name returned 401 -- credentials rejected" ;;
    *)   log "WARNING: $name reload returned HTTP $code" ;;
  esac
}

# blackbox first, and the order matters. Prometheus scrapes as soon as it has
# reloaded, so if it learns about a new probe module before blackbox does, the
# first probes come back 400 Unknown module and the target sits down until the
# next scrape. Reloading the exporter first closes that window.
reload blackbox     "$BLACKBOX_URL" "" ""
reload prometheus   "$PROM_URL"  "$PROMETHEUS_WEB_USER"  "$prom_pw"
reload alertmanager "$ALERT_URL" "$ALERTMANAGER_WEB_USER" "$alert_pw"

log "done"
