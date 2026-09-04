#!/bin/sh
#
# Prepare everything the services need before they start:
#
#   1. a TLS certificate per service, obtained according to CERT_MODE
#   2. the web-auth configs Prometheus and Alertmanager read, generated from
#      the password files in secrets/<service>_<username>
#
# Certificates are kept one directory per service, then one per domain, which
# is certbot's own layout:
#
#   certs/prometheus/<domain>/    certs/alertmanager/<domain>/
#   certs/grafana/<domain>/
#
# Each service mounts only its own directory, at /certs, so no service can
# read the private key of another. Filenames match certbot in every mode, so
# the services never need reconfiguring when the issuer changes:
#
#   privkey.pem    private key
#   cert.pem       the certificate on its own
#   chain.pem      intermediates (self-signed: the certificate itself)
#   fullchain.pem  cert.pem + chain.pem, what the services actually load
#
# CERT_MODE picks where those files come from:
#
#   self-signed  generate a pair here when one is absent          (default)
#   certbot      copy from a certbot / Let us Encrypt directory
#   provided     use whatever is already in certs/<service>/<domain>/
#
# Nothing here ever overwrites a self-signed or provided certificate, and
# nothing here ever writes back to the certbot directory.
#
# Panel accounts are one flat file per account, directly in secrets/:
#
#   secrets/prometheus_<username>     content is that user's password
#
# So secrets/grafana_admin holds the password for the Grafana account admin.
# Creating a file creates an account. <service>_WEB_USER in .env names the
# account the internal clients log in as.
#
# Runs as the bootstrap service before the others. Also runs on the host if
# openssl and htpasswd are available:
#
#     set -a; . ./.env; set +a; sh scripts/bootstrap.sh

set -eu

CERTS_DIR="${CERTS_DIR:-certs}"
SECRETS_DIR="${SECRETS_DIR:-secrets}"
CERT_MODE="${CERT_MODE:-self-signed}"
CERT_DAYS="${CERT_DAYS:-3650}"
# Domain each certificate is issued for, and the directory name underneath
# certs/<service>/. Per-service overrides are CERT_DOMAIN_PROMETHEUS and so on.
CERT_DOMAIN="${CERT_DOMAIN:-localhost}"
# Root of a certbot install -- the directory holding live/ and archive/, not
# live/ itself. certbot puts symlinks in live/ that point into archive/, so a
# mount of live/ alone arrives with every link dangling.
CERTBOT_DIR="${CERTBOT_DIR:-/letsencrypt}"
# Warn this many days before a certificate runs out.
CERT_WARN_DAYS="${CERT_WARN_DAYS:-30}"
# Services that get a certificate. Each is also a SAN, so the cert works for
# service-to-service calls by container name on the compose network.
CERT_SERVICES="${CERT_SERVICES:-prometheus alertmanager grafana}"
# Services that additionally need a --web.config.file for basic auth.
WEB_AUTH_SERVICES="${WEB_AUTH_SERVICES:-prometheus alertmanager}"
# Grafana provisions exactly one admin; this names which account file it reads.
GRAFANA_ADMIN_USER="${GRAFANA_ADMIN_USER:-admin}"
# Credentials a service uses to reach something else, as <folder>/<file>.
# Unlike a panel account, a generated value here is only a placeholder: the
# far end has its own idea of what the password is. Generating one anyway
# lets a fresh checkout start rather than crashing on a missing file.
SERVICE_SECRETS="${SERVICE_SECRETS:-prometheus/scrape_node_password alertmanager/smtp_password}"
# Files created by this run, reported at the end.
GENERATED=""
PLACEHOLDERS=""

log()  { echo "[bootstrap] $*"; }
warn() { echo "[bootstrap] WARNING: $*" >&2; }
fail() { echo "[bootstrap] ERROR: $*" >&2; exit 1; }

# Read VAR_<SERVICE>, falling back to VAR. Uppercases the service name.
lookup() {
  _var="$1"; _svc="$2"; _fallback="$3"
  _upper=$(echo "$_svc" | tr '[:lower:]' '[:upper:]')
  eval "_v=\${${_var}_${_upper}:-}"
  [ -n "${_v:-}" ] || _v="$_fallback"
  echo "$_v"
}


# --------------------------------------------------------------- certificates
have_cert() {
  [ -f "$1/fullchain.pem" ] && [ -f "$1/privkey.pem" ]
}

# Report the expiry date, and complain if it is past or close.
check_expiry() {
  svc="$1"; dir="$2"
  [ -f "$dir/cert.pem" ] || return 0

  exp=$(openssl x509 -in "$dir/cert.pem" -noout -enddate 2>/dev/null | cut -d= -f2)
  if ! openssl x509 -in "$dir/cert.pem" -noout -checkend 0 >/dev/null 2>&1; then
    warn "$svc: certificate EXPIRED ($exp)"
  elif ! openssl x509 -in "$dir/cert.pem" -noout \
         -checkend $((CERT_WARN_DAYS * 86400)) >/dev/null 2>&1; then
    warn "$svc: certificate expires within $CERT_WARN_DAYS days ($exp)"
  else
    log "$svc: certificate valid until $exp"
  fi
}

# self-signed -- generate a pair, but only if there is not one already.
cert_self_signed() {
  svc="$1"; dir="$2"; domain="$3"

  if have_cert "$dir"; then
    log "$svc: certificate already present, leaving it alone"
    return 0
  fi

  log "$svc: generating a self-signed certificate for $domain"
  # The container name is a SAN as well as the domain, because Prometheus and
  # Grafana reach each other as https://<service>:<port> on the compose
  # network, whatever the browser-facing domain happens to be. localhost is
  # there for a browser on the host; skip it when it is already the domain,
  # since a repeated SAN is untidy.
  sans="DNS:$domain,DNS:$svc"
  [ "$domain" = "localhost" ] || sans="$sans,DNS:localhost"
  sans="$sans,IP:127.0.0.1,IP:::1"

  openssl req -x509 -newkey rsa:2048 -sha256 \
    -days "$CERT_DAYS" \
    -nodes \
    -keyout "$dir/privkey.pem" \
    -out    "$dir/cert.pem" \
    -subj   "/CN=$domain/O=MetricWatch/OU=self-signed" \
    -addext "subjectAltName=$sans" \
    -addext "basicConstraints=critical,CA:FALSE" \
    -addext "keyUsage=critical,digitalSignature,keyEncipherment" \
    -addext "extendedKeyUsage=serverAuth" \
    >/dev/null 2>&1 || fail "openssl failed for $svc"

  # Self-signed: there is no intermediate, so the chain is the cert itself.
  cp "$dir/cert.pem" "$dir/chain.pem"
  cp "$dir/cert.pem" "$dir/fullchain.pem"
  chmod 644 "$dir"/*.pem
  log "$svc: wrote $dir/{privkey,cert,chain,fullchain}.pem valid $CERT_DAYS days"
}

# certbot -- copy from $CERTBOT_DIR/live/<domain>/ on every run, so a renewal
# on the host reaches the services the next time bootstrap runs. This script
# never invokes certbot itself; issuing a certificate needs a public DNS name
# and a completed HTTP-01 or DNS-01 challenge, which is a job for the host.
cert_from_certbot() {
  svc="$1"; dir="$2"; domain="$3"

  src="$CERTBOT_DIR/live/$domain"

  # A missing source is fatal on a first run and survivable afterwards: better
  # to keep serving the copy from last week than to fail the whole stack.
  if [ ! -f "$src/fullchain.pem" ] || [ ! -f "$src/privkey.pem" ]; then
    if have_cert "$dir"; then
      warn "$svc: $src is unreadable or incomplete -- keeping the copy in $dir"
      return 0
    fi
    fail "$svc: no certificate at $src
         CERTBOT_DIR must be the certbot root (the directory holding live/
         and archive/), mounted readable, and live/$domain must exist.
         Issue one on the host first, e.g.
           certbot certonly --standalone -d $domain"
  fi

  for f in privkey.pem cert.pem chain.pem fullchain.pem; do
    if [ -f "$src/$f" ]; then
      # -L because every file in live/ is a symlink into archive/.
      cp -L "$src/$f" "$dir/$f"
    else
      warn "$svc: $src/$f is missing"
    fi
  done
  chmod 644 "$dir"/*.pem
  log "$svc: copied the certificate for $domain from $src"
}

# provided -- someone else put the files there: a corporate CA, mkcert,
# acme.sh, Vault, a cloud issuer. Verify, and otherwise keep hands off.
cert_provided() {
  svc="$1"; dir="$2"; domain="$3"

  have_cert "$dir" || fail \
    "$svc: CERT_MODE=provided but $dir/fullchain.pem or $dir/privkey.pem is missing.
         Put your own PEM files there, or set CERT_MODE=self-signed in .env."
  log "$svc: using the certificate already in $dir"
}

provision_cert() {
  svc="$1"
  domain=$(lookup CERT_DOMAIN "$svc" "$CERT_DOMAIN")
  [ -n "$domain" ] || fail "$svc: no certificate domain -- set CERT_DOMAIN in .env"
  dir="$CERTS_DIR/$svc/$domain"
  mkdir -p "$dir"

  # Certificates used to sit directly in certs/<service>/. Those files are no
  # longer read; say so rather than letting a stale pair look like the live one.
  for stale in "$CERTS_DIR/$svc"/*.pem; do
    [ -e "$stale" ] || continue
    warn "$svc: $CERTS_DIR/$svc holds .pem files from the old flat layout.
         They are ignored now that certificates live in <service>/<domain>/.
         Remove them: rm -f $CERTS_DIR/$svc/*.pem"
    break
  done

  case "$CERT_MODE" in
    self-signed) cert_self_signed  "$svc" "$dir" "$domain" ;;
    certbot)     cert_from_certbot "$svc" "$dir" "$domain" ;;
    provided)    cert_provided     "$svc" "$dir" "$domain" ;;
    *) fail "CERT_MODE=$CERT_MODE is not one of: self-signed, certbot, provided" ;;
  esac

  check_expiry "$svc" "$dir"
}

log "certificate mode: $CERT_MODE"
for svc in $CERT_SERVICES; do
  provision_cert "$svc"
done

# ------------------------------------------------------------------ web auth
# Panel accounts are flat files directly in secrets/, one per account:
#
#   secrets/<service>_<username>      contents are that user's password
#
# So secrets/grafana_admin is the password for the Grafana account "admin".
# The generated web-auth config sits beside them as secrets/<service>_web.yml.
# It is skipped when accounts are enumerated -- anything ending .yml is not a
# username -- so it cannot be mistaken for one.
#
# The service's own folder, secrets/<service>/, keeps the credentials the
# service uses to reach other things: scrape passwords, the SMTP password.
# The two never collide, because the glob <service>_* cannot match the
# directory <service>/.

# Complain about layouts this replaced rather than silently creating no
# accounts at all, which would lock everyone out.
check_legacy_secrets() {
  svc="$1"
  if [ -f "$SECRETS_DIR/$svc/web_password" ]; then
    fail "$svc: $SECRETS_DIR/$svc/web_password is no longer read.
         Accounts are one flat file per user now:
           mv $SECRETS_DIR/$svc/web_password $SECRETS_DIR/${svc}_admin"
  fi
  if [ -f "$SECRETS_DIR/$svc/web.yml" ]; then
    warn "$svc: $SECRETS_DIR/$svc/web.yml is left over and no longer read.
         The generated config is $SECRETS_DIR/${svc}_web.yml now.
         Remove it: rm -f $SECRETS_DIR/$svc/web.yml"
  fi
  if [ -d "$SECRETS_DIR/$svc/users" ]; then
    fail "$svc: $SECRETS_DIR/$svc/users/ is no longer read.
         Accounts are flat files named <service>_<username>:
           for f in $SECRETS_DIR/$svc/users/*; do
             mv \"\$f\" $SECRETS_DIR/${svc}_\$(basename \"\$f\"); done
           rmdir $SECRETS_DIR/$svc/users"
  fi
}

# Generate a password and write it to $1, but never over an existing file --
# an existing password is the user's and must survive every run.
#
# openssl rand is the source because the toolbox image already has it, and it
# is a CSPRNG. base64 then trims the characters that make a password awkward
# to paste through a shell or a URL, leaving ~22 chars of the 32 random bytes.
make_password() {
  file="$1"; what="$2"

  [ -e "$file" ] && return 0

  pw=$(openssl rand -base64 32 2>/dev/null | tr -d '/+=\n' | cut -c1-24)
  [ "${#pw}" -ge 16 ] || fail "could not generate a password for $what"

  # Create it private, so the secret is never briefly world-readable, then
  # widen it. 0644 is needed because the containers that read these run as
  # their own users -- grafana as 472, prometheus as nobody -- while this
  # script runs as root, and 0600 would lock every one of them out. The same
  # applies to web.yml and privkey.pem, which are already 0644. What protects
  # secrets/ is the host directory, not the file mode.
  (umask 077; printf '%s' "$pw" > "$file") || fail "cannot write $file"
  chmod 644 "$file"
  log "$what: generated a random password in $file"
  GENERATED="$GENERATED $file"
}

# The services read these as their own users -- grafana as 472, prometheus as
# nobody -- so a password file only root can read stops the stack dead, with
# an error that surfaces inside the container rather than here. Fix it where
# it is diagnosable, and say so rather than changing a mode silently.
ensure_readable() {
  file="$1"
  [ -f "$file" ] || return 0
  # -r as a non-root user is what actually matters; test the mode instead,
  # since this script runs as root and can read anything.
  mode=$(stat -c '%a' "$file" 2>/dev/null) || return 0
  case "$mode" in
    *[4567]) return 0 ;;   # world-readable already
  esac
  chmod 644 "$file" && log "widened $file from $mode to 644 so the service can read it"
}

seed_service_secrets() {
  for rel in $SERVICE_SECRETS; do
    dir=${rel%/*}
    mkdir -p "$SECRETS_DIR/$dir"
    before="$GENERATED"
    make_password "$SECRETS_DIR/$rel" "placeholder for $rel"
    [ "$before" = "$GENERATED" ] || PLACEHOLDERS="$PLACEHOLDERS $SECRETS_DIR/$rel"
    ensure_readable "$SECRETS_DIR/$rel"
  done
}

# Accounts to create when nothing exists yet, so a fresh checkout comes up
# without anyone having to invent three passwords first.
seed_accounts() {
  for svc in $CERT_SERVICES; do
    case " $WEB_AUTH_SERVICES grafana " in
      *" $svc "*) : ;;
      *) continue ;;
    esac

    check_legacy_secrets "$svc"

    # Only seed when the service has no account at all. One existing account
    # means the operator has taken charge of this service; adding another
    # behind their back would be a surprise.
    [ -z "$(list_accounts "$svc")" ] || continue

    user=$(default_user_for "$svc")
    make_password "$SECRETS_DIR/${svc}_${user}" "$svc account $user"
  done

  # Every account file, seeded or not -- an existing one may have been created
  # by hand with a mode the containers cannot read.
  for svc in $CERT_SERVICES; do
    for f in "$SECRETS_DIR/${svc}_"*; do
      [ -f "$f" ] || continue
      case "$f" in *.yml|*.yaml) continue ;; esac
      ensure_readable "$f"
    done
  done
}

default_user_for() {
  case "$1" in
    prometheus)   echo "${PROMETHEUS_WEB_USER:-admin}" ;;
    alertmanager) echo "${ALERTMANAGER_WEB_USER:-admin}" ;;
    grafana)      echo "${GRAFANA_ADMIN_USER:-admin}" ;;
    *)            echo admin ;;
  esac
}

# Every secrets/<service>_* file is one account. Returns nothing if there are
# none, which each caller treats as fatal.
list_accounts() {
  svc="$1"
  for pw_file in "$SECRETS_DIR/${svc}_"*; do
    [ -f "$pw_file" ] || continue
    base=$(basename "$pw_file")
    case "$base" in
      *.yml|*.yaml|*.example|*.tmp) continue ;;   # not an account
    esac
    # Strip the "<service>_" prefix; whatever is left is the username, so a
    # username may itself contain underscores.
    echo "${base#${svc}_}"
  done
}

# Prometheus and Alertmanager take a --web.config.file holding a bcrypt hash
# per user. Certificate paths are /certs/<domain>/... because each service
# mounts its own certs/<service>/ directory at /certs.
write_web_config() {
  svc="$1"
  out="$SECRETS_DIR/${svc}_web.yml"
  domain=$(lookup CERT_DOMAIN "$svc" "$CERT_DOMAIN")

  check_legacy_secrets "$svc"

  users=$(list_accounts "$svc")
  [ -n "$users" ] || fail "$svc: no accounts found.
         Create one, named for the user:
           printf '%s' 'your-password' > $SECRETS_DIR/${svc}_admin"

  tmp="$out.tmp"
  cat > "$tmp" <<WEBCFG
# Generated by scripts/bootstrap.sh -- do not edit.
# Accounts come from $SECRETS_DIR/${svc}_<username> (one file per account).
# After changing a password there: docker compose up -d bootstrap
tls_server_config:
  cert_file: /certs/$domain/fullchain.pem
  key_file: /certs/$domain/privkey.pem
  min_version: TLS12
basic_auth_users:
WEBCFG

  n=0
  for user in $users; do
    pw_file="$SECRETS_DIR/${svc}_${user}"
    pw=$(cat "$pw_file")
    [ -n "$pw" ] || { rm -f "$tmp"; fail "$svc: $pw_file is empty"; }

    hash=$(htpasswd -nbB -C 10 "$user" "$pw" 2>/dev/null | cut -d: -f2)
    [ -n "$hash" ] || { rm -f "$tmp"; fail "$svc: htpasswd produced no hash for user $user"; }

    echo "  $user: $hash" >> "$tmp"
    n=$((n + 1))
  done

  mv "$tmp" "$out"
  chmod 644 "$out"
  log "$svc: wrote $out ($n account(s), bcrypt cost 10, cert $domain)"
}

# Create anything missing before it is read. An existing file is never
# touched, so a password you set stays exactly as you set it.
seed_accounts
seed_service_secrets

for svc in $WEB_AUTH_SERVICES; do
  write_web_config "$svc"
done

# Grafana reads its password file itself, so there is nothing to generate --
# but check it exists here, where the error is legible, instead of letting
# Grafana fail later with a stack trace about an unreadable secret.
check_legacy_secrets grafana
grafana_pw="$SECRETS_DIR/grafana_${GRAFANA_ADMIN_USER:-admin}"
if [ -f "$grafana_pw" ]; then
  [ -s "$grafana_pw" ] || fail "grafana: $grafana_pw is empty"
  log "grafana: admin account ${GRAFANA_ADMIN_USER:-admin} reads $grafana_pw"
else
  fail "grafana: missing $grafana_pw
         GRAFANA_ADMIN_USER in .env is ${GRAFANA_ADMIN_USER:-admin}, so:
           printf '%s' 'your-password' > $grafana_pw"
fi

if [ -n "$GENERATED" ]; then
  log "generated $(echo $GENERATED | wc -w | tr -d ' ') password file(s) this run"
fi
if [ -n "$PLACEHOLDERS" ]; then
  warn "the following are RANDOM PLACEHOLDERS, not the real credentials.
         The far end -- the exporter, the mail server -- will reject them.
         Replace each with the real password, then: docker compose up -d"
  for f in $PLACEHOLDERS; do echo "           $f" >&2; done
fi

log "bootstrap complete"
