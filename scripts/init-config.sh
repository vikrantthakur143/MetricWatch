#!/bin/sh
#
# Put the Prometheus configuration in place on a first run.
#
# prometheus.yml, the target lists and the rule files are yours to edit, so
# they are not tracked. What IS tracked is prometheus/example/, a pristine
# copy of all three. This script copies that into place the first time the
# stack starts, and then stays out of the way:
#
#   prometheus/example/prometheus.yml   ->  prometheus/prometheus.yml
#   prometheus/example/targets/*.yml    ->  prometheus/targets/
#   prometheus/example/rules/*.yml      ->  prometheus/rules/
#
# "First run" means the Prometheus TSDB is empty. That is the honest test: a
# database with data in it belongs to an install that has been configured
# already, whatever state its config files are in, and silently rewriting
# those would undo somebody's work. A missing file is reported instead, and
# left for them to restore -- from example/, which is still right there.
#
# An existing file is never overwritten in either case, so a half-populated
# config directory fills in rather than being replaced.
#
# Runs as the config-init service before prometheus. Also runs on the host:
#
#     EXAMPLE_DIR=prometheus/example CONFIG_DIR=prometheus \
#       TSDB_DIR=./prometheus_data sh scripts/init-config.sh

set -eu

# Inside the container these are the mount points from docker-compose.yml.
CONFIG_DIR="${CONFIG_DIR:-/work/config}"
EXAMPLE_DIR="${EXAMPLE_DIR:-$CONFIG_DIR/example}"
TSDB_DIR="${TSDB_DIR:-/tsdb}"

log()  { echo "[config-init] $*"; }
warn() { echo "[config-init] WARNING: $*" >&2; }
fail() { echo "[config-init] ERROR: $*" >&2; exit 1; }

[ -d "$EXAMPLE_DIR" ] || fail "no example directory at $EXAMPLE_DIR"

# Every file example/ offers, as paths relative to it.
example_files() {
  ( cd "$EXAMPLE_DIR" && find . -type f -name '*.yml' | sed 's|^\./||' | sort )
}

# A Prometheus data directory that has been written to holds wal/ from the
# first second it runs, and chunks_head/ and block directories after that.
# Anything else -- absent, or the empty directory Docker just created for the
# bind mount -- is a first run.
first_run() {
  [ -d "$TSDB_DIR" ] || return 0
  for entry in "$TSDB_DIR"/*; do
    [ -e "$entry" ] && return 1
  done
  return 0
}

copied=0
skipped=0
missing=""

if first_run; then
  log "no Prometheus data in $TSDB_DIR -- treating this as a first run"
  for rel in $(example_files); do
    dest="$CONFIG_DIR/$rel"
    if [ -e "$dest" ]; then
      skipped=$((skipped + 1))
      continue
    fi
    mkdir -p "$(dirname "$dest")"
    cp "$EXAMPLE_DIR/$rel" "$dest" || fail "cannot write $dest"
    chmod 644 "$dest"
    copied=$((copied + 1))
  done

  if [ "$copied" -gt 0 ]; then
    log "copied $copied file(s) from $EXAMPLE_DIR"
  fi
  if [ "$skipped" -gt 0 ]; then
    log "left $skipped existing file(s) alone"
  fi
else
  log "$TSDB_DIR already holds data -- leaving the configuration alone"
  for rel in $(example_files); do
    [ -e "$CONFIG_DIR/$rel" ] || missing="$missing $rel"
  done
fi

# Prometheus refuses to start without its config or a named rule file, and
# says so in a way that needs reading twice. Say it here, where the fix is
# one copy away, rather than letting the container crash-loop.
if [ -n "$missing" ]; then
  warn "these files exist in $EXAMPLE_DIR but not in $CONFIG_DIR:"
  for rel in $missing; do echo "           $rel" >&2; done
  warn "Prometheus will fail to start if it needs one of them. Restore with:
         cp prometheus/example/<file> prometheus/<file>"
fi

log "config-init complete"
