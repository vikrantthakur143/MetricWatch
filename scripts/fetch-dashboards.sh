#!/bin/sh
#
# Assemble the directory Grafana provisions dashboards from.
#
# Downloads each dashboard listed in GRAFANA_DASHBOARDS from grafana.com,
# copies any hand-written JSON out of GRAFANA_DASHBOARDS_CUSTOM_DIR, and
# writes the result to the output directory.
#
# Runs as the dashboard-init service before grafana starts. Also runs
# standalone from the repo root, reading the same .env Compose reads:
#
#     set -a; . ./.env; set +a; sh scripts/fetch-dashboards.sh
#
# Needs only curl and a POSIX shell. Environment:
#
#   GRAFANA_DASHBOARDS             comma-separated id[:name[:revision]] items
#   GRAFANA_DATASOURCE             datasource to bind downloads to
#   GRAFANA_DASHBOARDS_CUSTOM_DIR  directory of hand-written JSON
#   DASHBOARDS_OUT                 output directory
#
# All four are set from .env in docker-compose.yml.

set -eu

OUT="${DASHBOARDS_OUT:-grafana/dashboards}"
DASHBOARDS="${GRAFANA_DASHBOARDS:-}"
DATASOURCE="${GRAFANA_DATASOURCE:-Prometheus}"
CUSTOM_DIR="${GRAFANA_DASHBOARDS_CUSTOM_DIR:-}"
BASE_URL="${GRAFANA_COM_URL:-https://grafana.com/api/dashboards}"

log()  { echo "[dashboards] $*"; }
warn() { echo "[dashboards] WARNING: $*" >&2; }
fail() { echo "[dashboards] ERROR: $*" >&2; exit 1; }

mkdir -p "$OUT"

# Names of the files written this run, so anything left over from an earlier
# list can be removed at the end. A subshell writes them, hence a temp file.
KEEP=$(mktemp)
trap 'rm -f "$KEEP"' EXIT

# --- download the grafana.com dashboards ----------------------------------
#
# GRAFANA_DASHBOARDS is a comma-separated list; each item is up to three
# colon-separated fields:
#
#     id                 name defaults to dashboard-<id>, revision to latest
#     id:name            name is the output filename without .json
#     id:name:revision   pin a revision instead of taking the latest
#
# Splitting on ':' with three fields leaves any spaces inside a name intact.
if [ -z "$DASHBOARDS" ]; then
  log "GRAFANA_DASHBOARDS is empty; no downloads"
else
  echo "$DASHBOARDS" | tr ',' '\n' | while IFS=: read -r id name rev; do
    # Trim the whitespace people leave after a comma.
    id=$(echo "$id" | tr -d '[:space:]')
    [ -n "$id" ] || continue

    case "$id" in
      *[!0-9]*) fail "'$id' is not a numeric dashboard ID -- check GRAFANA_DASHBOARDS in .env" ;;
    esac

    name=$(echo "${name:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')
    rev=$(echo "${rev:-}"  | tr -d '[:space:]')
    [ -n "$name" ] || name="dashboard-$id"
    [ -n "$rev" ]  || rev="latest"

    dest="$OUT/$name.json"
    tmp="$dest.tmp"
    url="$BASE_URL/$id/revisions/$rev/download"
    echo "$name.json" >> "$KEEP"

    log "fetching id=$id revision=$rev -> $name.json"
    code=$(curl -sS -L -o "$tmp" -w '%{http_code}' "$url" 2>/dev/null || echo 000)

    if [ "$code" != "200" ] || [ ! -s "$tmp" ]; then
      rm -f "$tmp"
      if [ -f "$dest" ]; then
        warn "fetch failed (HTTP $code); keeping the existing $name.json"
        continue
      fi
      fail "fetch failed for id=$id (HTTP $code) and no previous copy exists"
    fi

    # Cheap sanity check: a dashboard is a JSON object mentioning panels.
    case "$(head -c 1 "$tmp")" in
      '{') : ;;
      *)   rm -f "$tmp"; fail "id=$id did not return a JSON object" ;;
    esac
    grep -q '"panels"' "$tmp" || { rm -f "$tmp"; fail "id=$id has no panels"; }

    # Dashboards published with an input placeholder need it bound to a real
    # datasource; newer ones use a template variable and are untouched by this.
    sed "s/\${DS_PROMETHEUS}/$DATASOURCE/g" "$tmp" > "$dest"
    rm -f "$tmp"
  done
fi

# --- copy the hand-written dashboards -------------------------------------
# The directory is not tracked, so a fresh clone does not have one. Create it
# rather than reporting it missing: somewhere to drop a dashboard is more use
# than a warning that there is nowhere to drop one.
if [ -n "$CUSTOM_DIR" ] && [ ! -d "$CUSTOM_DIR" ]; then
  mkdir -p "$CUSTOM_DIR" || fail "cannot create $CUSTOM_DIR"
  log "created $CUSTOM_DIR"
fi

if [ -n "$CUSTOM_DIR" ] && [ -d "$CUSTOM_DIR" ]; then
  n=0
  for f in "$CUSTOM_DIR"/*.json; do
    [ -e "$f" ] || continue
    log "including custom $(basename "$f")"
    cp "$f" "$OUT/$(basename "$f")"
    echo "$(basename "$f")" >> "$KEEP"
    n=$((n + 1))
  done
  [ "$n" -gt 0 ] || log "no custom dashboards in $CUSTOM_DIR"
else
  log "GRAFANA_DASHBOARDS_CUSTOM_DIR not set or missing; skipping custom dashboards"
fi

# --- drop anything no longer listed ---------------------------------------
# The output directory is generated, so a dashboard removed from .env should
# disappear from Grafana rather than linger from a previous run.
for f in "$OUT"/*.json; do
  [ -e "$f" ] || continue
  base=$(basename "$f")
  grep -qxF "$base" "$KEEP" || { log "removing $base (no longer listed)"; rm -f "$f"; }
done

# --- warn about duplicate titles -------------------------------------------
# Two dashboards with the same title in the same folder do more than look
# untidy: Grafana refuses the whole provisioning provider write access, so
# NOTHING in this directory updates any more. The filenames can differ and
# still collide, because the title lives inside the JSON. Grafana only says
# so in its own log, which is easy to miss, so say it here too.
dup=$(for f in "$OUT"/*.json; do
        [ -e "$f" ] || continue
        grep -o '"title"[[:space:]]*:[[:space:]]*"[^"]*"' "$f" | tail -1 | cut -d'"' -f4
      done | sort | uniq -d)
if [ -n "$dup" ]; then
  warn "two or more dashboards share a title, so Grafana will stop updating
         every dashboard in this folder:"
  echo "$dup" | while IFS= read -r t; do [ -n "$t" ] && echo "           \"$t\"" >&2; done
  warn "drop one of them from GRAFANA_DASHBOARDS in .env, or move it to a
         separate provider with its own folder."
fi

log "provisioned $(find "$OUT" -name '*.json' | wc -l | tr -d ' ') dashboard(s) into $OUT"
