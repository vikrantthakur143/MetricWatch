# Monitoring stack

Prometheus + Alertmanager + Grafana under Docker Compose.

    docker compose up -d

| Service      | URL                     | Password file                  |
|--------------|-------------------------|--------------------------------|
| Prometheus   | https://localhost:9090  | `secrets/prometheus_<user>`    |
| Alertmanager | https://localhost:9093  | `secrets/alertmanager_<user>`  |
| Grafana      | https://localhost:3000  | `secrets/grafana_<user>`       |

The username is part of the filename — `secrets/grafana_admin` holds the
password for the Grafana account `admin`. `.env` names which account each
service uses. The host in those URLs is `CERT_DOMAIN` from `.env`,
`localhost` by default.

Grafana comes with Prometheus pre-configured as its default datasource, and
`grafana/provisioning/` carries worked examples for alerting, plugins and
access control — inert until you copy them into place. See
[Grafana provisioning](#grafana-provisioning).

All three serve TLS and require credentials. Certificates are self-signed out
of the box, so browsers warn until you trust each service's
`certs/<service>/<domain>/cert.pem` locally; set `CERT_MODE=certbot` in `.env`
to use real ones instead. See [TLS](#tls).

> Self-signed TLS and local accounts. Fine on a trusted network — this is not
> a substitute for a real CA and an identity provider on the internet.

## Files

    docker-compose.yml              the whole stack
    prometheus/prometheus.yml       scrape jobs and alerting config, yours
    prometheus/targets/*.yml        file_sd target lists, yours
    prometheus/rules/*.yml          alert rules (8 files, 7 loaded, 98 alerts), yours
    prometheus/example/             tracked copy of the three above
    blackbox/blackbox.yml           probe modules, tracked
    alertmanager/alertmanager.yml   routing, mute windows, email receiver, tracked
    grafana/grafana.ini             server settings
    grafana/provisioning/           datasources, dashboards, provisioning examples
    grafana/dashboards-custom/      hand-written dashboard JSON, yours
    grafana/dashboards/             assembled output, gitignored
    .env                            domain, accounts, ports, versions, limits
    secrets/<service>_<user>        one file per panel account, gitignored
    secrets/<service>_web.yml       generated web-auth config, gitignored
    secrets/<service>/              service-to-service credentials, gitignored
    certs/<service>/<domain>/       TLS material, per service and domain
    docker/toolbox/                 helper image for the init services
    scripts/bootstrap.sh            certs + web auth, runs before everything
    scripts/init-config.sh          seeds prometheus/ from example/ on a first run
    scripts/fetch-dashboards.sh     assembles dashboards, runs before grafana
    scripts/reload-config.sh        reloads configs on every `up -d`

`grafana/ldap.toml` is a leftover: it is not mounted into the container and
`grafana.ini` has no `[auth.ldap]` section, so nothing reads it.

Configuration is written inline — no templates — and everything ships ready
to run. Files fall into three kinds:

- **Tracked, edited in place.** `alertmanager.yml`, `blackbox/blackbox.yml`,
  the Grafana provisioning. Published files: keep your own hostnames and mail
  addresses out of them, or use `--skip-worktree` (below).
- **Yours, seeded from a tracked copy.** The whole Prometheus configuration —
  `prometheus.yml`, `targets/`, `rules/` — is gitignored, because it is where
  you say what to watch and when to be woken up. `prometheus/example/` holds
  the shipped version, and the `config-init` service copies it into place the
  first time the stack runs. See *Seeding the Prometheus config* below.
- **Yours, empty to begin with.** `grafana/dashboards-custom/`, for dashboards
  you build rather than download. Also gitignored;
  `scripts/fetch-dashboards.sh` creates the directory if it is not there.
- **Generated.** The Grafana dashboard directory (from `GRAFANA_DASHBOARDS`),
  the TLS certificates under `certs/`, and the `web.yml` files under
  `secrets/`. Produced by scripts in `scripts/`, run as init services before
  the containers that need them, and all gitignored.

## Secrets

Nothing under `secrets/` is tracked in git. The whole directory is mounted
read-only at `/run/secrets`, so `secrets/grafana_admin` on the host is
`/run/secrets/grafana_admin` inside a container.

### Panel logins

**You do not have to create these.** On the first run bootstrap generates a
random 24-character password for each service that has no account yet, using
`openssl rand`, and prints where it put it:

    [bootstrap] grafana account admin: generated a random password in secrets/grafana_admin

Read one with `cat secrets/grafana_admin`. An existing file is never
overwritten, so a password you set by hand survives every later run.

Each account is **one flat file named `<service>_<username>`**, holding that
account's password:

    secrets/prometheus_<username>     login for the Prometheus UI
    secrets/alertmanager_<username>   login for the Alertmanager UI
    secrets/grafana_<username>        login for Grafana

Creating a file creates an account:

    printf '%s' 'your-password' > secrets/prometheus_admin
    docker compose up -d bootstrap && docker compose restart prometheus

`.env` names which account the stack itself logs in as —
`PROMETHEUS_WEB_USER`, `ALERTMANAGER_WEB_USER` and `GRAFANA_ADMIN_USER`. Those
are the accounts `config-reload` uses, that Prometheus notifies Alertmanager
with, and that Grafana provisions as its admin.

**Prometheus and Alertmanager accept every file matching their prefix**, so
`secrets/prometheus_viewer` adds a second login — useful for a read-only
account that is not the one the automation uses. Removing the file and
re-running bootstrap removes the account. Grafana is different: it provisions
exactly one admin, the one `GRAFANA_ADMIN_USER` names, and ignores any other
`grafana_*` file.

A username may contain underscores: only the leading `<service>_` is stripped,
so `secrets/grafana_jane_doe` is the account `jane_doe`.

### The other credentials

These stay in the per-service folder, because they are not panel logins — they
are what a service uses to reach something else. The folder `secrets/prometheus/`
and the flat `secrets/prometheus_*` files never collide, since that glob cannot
match the directory `prometheus`.

    secrets/prometheus/scrape_node_password          node_exporter job
    secrets/alertmanager/smtp_password               SMTP account password

The `prometheus` and `alertmanager` jobs used to need one each. They do not
any more: both now scrape the container in this compose file, using that
service's own panel account (`secrets/prometheus_admin`,
`secrets/alertmanager_admin`), so there is no second password to keep in step.
Earlier installs will still have `scrape_prometheus_password` and
`scrape_alertmanager_password` sitting in `secrets/prometheus/`; nothing reads
them and they can be deleted.

These are generated too, but only so the stack starts — a random value here
is a **placeholder**, because the far end (the exporter, the mail server) has
its own idea of what the password is and will reject it. Bootstrap says so
loudly, listing each file it invented. Replace them with the real values.

Generated files are `chmod 644`. The containers read them as their own users
— Grafana as uid 472, Prometheus as `nobody` — so `0600` locks all of them
out; bootstrap widens any it finds and logs that it did. What protects
`secrets/` is the host directory, not the file mode.

The matching usernames are not secret and sit in `prometheus.yml` and
`alertmanager.yml`.

Each file holds the password and nothing else — no key name, no quotes, and no
trailing newline. The tools trim surrounding whitespace, but a stray newline is
easy to introduce and awkward to diagnose.

### The generated web-auth config

`secrets/prometheus_web.yml` and `secrets/alertmanager_web.yml` are
**generated** by `scripts/bootstrap.sh` from the `<service>_*` account files.
They hold one bcrypt hash per account plus that service's certificate paths,
and are what `--web.config.file` points at. Do not edit them; change a password
file and re-run the bootstrap service.

They sit beside the account files without being mistaken for one: anything
ending `.yml` is skipped when accounts are enumerated, so `alertmanager_web.yml`
never becomes a user called `web.yml`.

Bootstrap refuses to run against the layouts this replaced — a `web_password`
file or a `users/` directory — and prints the `mv` that migrates it, rather
than generating an empty account list and locking everyone out. A leftover
`secrets/<service>/web.yml` from the old path only draws a warning, since it is
generated and safe to delete.

### Grafana is the exception on password *changes*

Grafana only seeds the admin password into a *fresh* database. On an existing
volume the file changes nothing until you reset it explicitly:

    docker exec grafana grafana cli admin reset-admin-password \
      "$(cat secrets/grafana_admin)"

## TLS

Certificates are filed by service, then by domain — certbot's own layout, so
real certbot output drops straight in:

    certs/prometheus/<domain>/     certs/alertmanager/<domain>/
    certs/grafana/<domain>/
      privkey.pem                    private key
      cert.pem                       the certificate alone
      chain.pem                      intermediates (self-signed: the cert itself)
      fullchain.pem                  what the service actually loads

`<domain>` is `CERT_DOMAIN` from `.env` (`localhost` by default), or the
per-service `CERT_DOMAIN_PROMETHEUS`, `_ALERTMANAGER`, `_GRAFANA` when the
services answer on different names. The same value sets each service's
external URL.

A service mounts **only its own service directory**, at `/certs`, so none of
them can read another's private key — and the domain level below that keeps
two domains apart when one service serves both.

### Where the certificates come from

`CERT_MODE` in `.env` picks the issuer. Because the filenames are the same in
every mode, switching needs no change to any service config — only a
`docker compose up -d`.

| `CERT_MODE` | What bootstrap does | Needs a public domain |
|---|---|---|
| `self-signed` *(default)* | Issues a pair when one is absent | no |
| `certbot` | Copies from an existing certbot install | yes |
| `provided` | Verifies what you put there, nothing else | depends on issuer |

**`self-signed`** issues each certificate for its domain — `CN=<domain>` —
with SANs for that domain, the container name, `localhost`, `127.0.0.1` and
`::1`. One file therefore covers both browser access and service-to-service
calls by container name on the compose network. It writes **only when
`fullchain.pem` and `privkey.pem` are absent**, so anything you put there
survives; delete a service's directory to force a new pair. `CERT_DAYS`
(default 3650, ten years) sets the lifetime. Browsers cap *publicly trusted*
certificates at 398 days, but that rule does not apply to one you trust
locally, which is what this is. Changing `CERT_DAYS` affects only newly
generated certificates.

**`certbot`** copies from `$CERTBOT_DIR/live/<domain>/` on every run, so a
renewal on the host reaches the services the next time bootstrap runs. Two
things to get right:

- `CERTBOT_DIR` is the certbot **root** — the directory holding `live/` *and*
  `archive/`, normally `/etc/letsencrypt`. Everything in `live/` is a symlink
  into `archive/`, so mounting `live/` alone gives the container nothing but
  dangling links. It is a bind mount and cannot be made conditional, so it
  defaults to `./certs`: a path that already exists and is ignored in the
  other modes.
- `CERT_DOMAIN` names the `live/` subdirectory to copy from, and the
  directory the copy lands in. It is the same variable in all three modes.

This stack does **not** run certbot. Issuing a certificate needs a public DNS
name and a completed HTTP-01 or DNS-01 challenge, so that stays on the host:

    certbot certonly --standalone -d mon.example.com

After a renewal, `docker compose up -d bootstrap` copies the new files in;
restart the services to be sure they load them.

**`provided`** is the escape hatch for every other issuer — a corporate CA,
`mkcert`, `acme.sh`, Vault, a cloud-issued certificate. Drop the four PEM
files into `certs/<service>/` yourself; bootstrap only checks they are there.

In all three modes bootstrap reports each expiry date, and warns when a
certificate has run out or falls inside `CERT_WARN_DAYS` (default 30). A mode
that cannot produce a certificate **fails**, which stops the stack rather than
starting a service with no key — except that `certbot` mode keeps an existing
copy, with a warning, when the certbot directory is temporarily unreadable.

### Verification between services

Prometheus→Alertmanager and Grafana→Prometheus skip verification
(`insecure_skip_verify` / `tlsSkipVerify`). This is required for `self-signed`,
and stays correct under `certbot` too: those calls use container names
(`https://prometheus:9090`), which a publicly issued certificate does not
cover. The connections are still encrypted and still require credentials.

## Configuration: .env

Everything site-specific lives in `.env`, which Compose reads automatically.
It is **not** tracked; start from the template:

    cp .env.example .env

It holds the tuning knobs — the certificate domain and source (`CERT_DOMAIN`,
`CERT_MODE`), which account each service uses (`*_WEB_USER`,
`GRAFANA_ADMIN_USER`), ports, image versions, resource limits, the network
subnet, the TSDB path and the dashboard list. What is monitored is not in
here — that is `prometheus/targets/`.

`.env` carries configuration, never passwords. It names *which* account is
used; the password for that account lives in `secrets/<service>_<username>`,
also untracked.

Two of those variables reach Grafana as `GF_*` environment overrides rather
than through `grafana.ini`: the admin account and the certificate paths both
contain a value from `.env`, and `grafana.ini` cannot interpolate it. Grafana
also refuses to start if a `${VAR}` appears inside `$__file{}`, so the path
cannot be assembled inside the file either.

Apply changes with `docker compose up -d`; anything touching ports, images or
limits recreates the affected container.

## Local config files

Nothing needs copying before the stack starts, with one exception — the file
that is the only place a password could end up:

    cp .env.example .env

### Seeding the Prometheus config

`prometheus/prometheus.yml`, `prometheus/targets/*.yml` and
`prometheus/rules/*.yml` are **not tracked**. That is where you say what to
scrape, which hosts to watch and when to be woken up, so editing them should
not show up in `git status` and your hostnames should never reach a public
repo by accident.

`prometheus/example/` holds the shipped version of all three, and it *is*
tracked. The `config-init` service copies it into place before Prometheus
starts:

    prometheus/example/prometheus.yml   ->  prometheus/prometheus.yml
    prometheus/example/targets/*.yml    ->  prometheus/targets/
    prometheus/example/rules/*.yml      ->  prometheus/rules/

It does that **only on a first run**, which it defines as the Prometheus TSDB
being empty. A database with data in it belongs to an install that has been
configured already, whatever state its files are in, and rewriting them would
undo someone's work. An existing file is never overwritten in either case, so
a half-populated directory fills in rather than being replaced.

After that first run it only reports: if a file exists in `example/` but not
in `prometheus/`, it names the file and tells you to copy it back, rather than
letting Prometheus crash-loop over a missing rule file.

To take the shipped version of something after you have changed it:

    cp prometheus/example/targets/node_exporter.yml prometheus/targets/

Add a host of your own by adding a line to the relevant list:

    - labels:
        hostname: web01
        os: linux
      targets:
      - web01.example.com:9100

Prometheus re-reads the target files on its own, so adding a host needs no
restart or reload — unlike a change to `prometheus.yml` itself, which the
`config-reload` service picks up on the next `docker compose up -d`.

### The files that are still tracked

`alertmanager.yml`, `blackbox/blackbox.yml` and the Grafana provisioning are
published files. Anything site-specific you add — a mail address, a
smarthost, your own usernames — must not be committed. To keep such an edit
out of `git status` entirely:

    git update-index --skip-worktree alertmanager/alertmanager.yml

Undo it with `--no-skip-worktree` when you next want to commit that file.

The Grafana datasource names the account Grafana logs into Prometheus with,
and the path to its password file. If you change `PROMETHEUS_WEB_USER` from
`admin`, change it in `grafana/provisioning/datasources/prometheus.yml` too —
in both `basicAuthUser` and the `$__file{}` path, which have to agree. The
path is written out literally because Grafana refuses to start if a `${VAR}`
appears inside `$__file{}`.

## Network and resources

Everything runs on a dedicated bridge network, `metricwatch` on
`172.28.0.0/16`, rather than the compose default — `172.17`, `172.18` and
`172.19` were already taken on this host.

Limits are sized from measured **peak** usage rather than steady state, since
that is what triggers an OOM kill — Prometheus peaked at 129 MiB, Grafana at
189 MiB, Alertmanager at 27 MiB. Each limit leaves roughly 3-4x headroom:

    prometheus     1.00 cpu / 512M   reserve 0.10 / 128M
    alertmanager   0.25 cpu / 128M   reserve 0.05 / 32M
    grafana        0.50 cpu / 512M   reserve 0.10 / 128M
    node-exporter  0.25 cpu / 128M   reserve 0.05 / 32M
    blackbox       0.25 cpu / 128M   reserve 0.05 / 32M
    init services  0.50 cpu / 128M

Prometheus memory grows with series cardinality, so that is the one most
likely to need raising. Check with:

    docker inspect prometheus --format '{{.State.OOMKilled}}'

### Where the TSDB lives

`PROMETHEUS_DATA` in `.env`, defaulting to `./prometheus_data` — inside the
repo, and gitignored. It has to be a local disk; Docker Desktop cannot
bind-mount a network share.

**On Linux, create it before the first `docker compose up -d`:**

```bash
mkdir -p prometheus_data && sudo chown 65534:65534 prometheus_data
```

Prometheus runs as uid 65534, and a bind-mount directory that Docker creates
arrives owned by root — so it cannot write, and dies at startup with

    Error opening query log file ... /prometheus/queries.active: permission denied
    panic: Unable to create mmap-ed active query log

The message names the query log, which makes it read like a logging problem;
it is the whole data directory. The same `chown` fixes it after the fact.
Docker Desktop ignores ownership on bind mounts, so this never bites on
Windows or macOS — which is exactly why it is easy to ship broken.

A named volume avoids the problem entirely, since Docker seeds its ownership
from the image. One variable selects either: a bare name is a volume, anything
with a slash is a bind mount.

    PROMETHEUS_DATA=prometheus-data     # named volume, add it to volumes: too

Retention has a size ceiling (`PROMETHEUS_RETENTION_SIZE`, 200GB) alongside
the 3650d window, so it cannot grow without bound. Whichever limit is reached
first wins — check the disk can hold 200GB before relying on the time window.

Neither Prometheus nor Alertmanager expands environment variables in its config
file, which is why these are referenced through the native `password_file` and
`auth_password_file` directives rather than through the environment. Both read
the file at use time rather than at startup, so rotating a secret takes effect
on the next scrape or notification with no restart or reload.

## Editing

Edit a config file, then:

    docker compose up -d

The `config-reload` service runs on every `up -d` and asks Prometheus,
Alertmanager and blackbox_exporter to re-read their configs in place. Compose
only recreates a container when its own definition changes, so editing a
mounted file alone would otherwise leave the running process on the old copy
until someone restarted it by hand. The reload is unconditional and idempotent
— it does not try to work out what changed.

blackbox is in that list for a reason worth knowing: its modules are read once
at startup, and editing `blackbox/blackbox.yml` does not change the container
definition, so Compose leaves it running on the old copy. It is also reloaded
**first**, before Prometheus — Prometheus scrapes the moment it reloads, so if
it learns about a new probe module before the exporter does, the first probes
come back `400 Unknown module` and the target sits down until the next scrape.

Confirm a change landed:

    curl -sk -u admin:"$(cat secrets/prometheus_admin)" \
      https://localhost:9090/api/v1/status/config

Some things are not part of the reloadable config and still need a restart —
`grafana.ini`, the compose file itself, and any command-line flag:

    docker compose restart <service>

Prometheus only exposes `POST /-/reload` when started with
`--web.enable-lifecycle`, which the compose file now sets; without it the
endpoint returns 403, which is what it did here until this was added.
Alertmanager exposes its reload endpoint unconditionally. Both sit behind the
same basic auth as the rest of the UI.

## Dashboards

Grafana loads dashboards from `grafana/dashboards/`. That directory is
assembled, not edited: `scripts/fetch-dashboards.sh` fills it from two sources
— dashboards downloaded from grafana.com by numeric ID, and hand-written JSON
copied out of `grafana/dashboards-custom/`.

The script runs as the `dashboard-init` service. Compose starts it and waits
for it to exit successfully before starting grafana, so the directory is always
populated first:

    depends_on:
      dashboard-init:
        condition: service_completed_successfully

### The dashboard list

`GRAFANA_DASHBOARDS` in `.env` is the list. It is comma-separated, and each
item is up to three colon-separated fields — `id[:name[:revision]]`:

    GRAFANA_DASHBOARDS=1860:node-exporter-full,3662,1860:pinned:1

That reads as: id 1860 saved as `node-exporter-full.json` at the latest
revision; id 3662 with the name defaulting to `dashboard-3662`; and id 1860
again, this time pinned to revision 1 under a different name. The id is the
number in the dashboard's grafana.com URL. Names may contain spaces, but not a
comma or a colon — and a value containing spaces has to be quoted, or `. ./.env`
from a shell splits on them and fails.

Five ship by default, one per thing this stack monitors:

    15489  Prometheus 2.0 Stats        Prometheus itself
    16420  Alerts                      what is firing, from Alertmanager
     3590  Grafana Internals           Grafana itself
     1860  Node Exporter Full          the host
    20338  Blackbox exporter - ICMP    the ping probes

Two related settings sit beside it:

    GRAFANA_DATASOURCE=Prometheus
    GRAFANA_DASHBOARDS_CUSTOM_DIR=grafana/dashboards-custom

To add your own dashboard, drop the JSON into that custom directory. Filenames
are preserved. The directory is gitignored and starts out empty —
`fetch-dashboards.sh` creates it if a clone does not have one — so a dashboard
you build stays yours and never reaches the repo.

Which also means nothing backs it up. A dashboard that exists only inside
Grafana lives in the `grafana-data` volume; export it to this directory if
losing that volume would matter.

A dashboard exported from the Grafana UI cannot be provisioned as-is, which is
what `scripts/grafana_dashboard/adapt.py` is for. Put the export in that
directory — the raw exports are gitignored, since they carry the URLs and
datasource uid of the Grafana they came from — and the script fixes the three
things that stop one from being provisioned:

- **A pinned datasource uid.** An export names the uid of the Grafana it came
  from. A provisioned dashboard must not, or it points at nothing on any
  other server, so the panels are repointed at a `datasource` variable.
- **`id` must be null.** Otherwise Grafana treats the export's id as a
  database row to overwrite.
- **Filters worth having.** The exports it was written for filtered on `job`
  and `instance` — which machine answered — while the metric carried
  `location` and `area`, which is what someone reading the dashboard actually
  wants. That part is specific to those sensor dashboards; adapt it if your
  own export needs different variables.

Re-run it after editing an export:

    python scripts/grafana_dashboard/adapt.py

Either way, apply it with:

    docker compose up -d dashboard-init

Grafana rescans the directory every 30s, so no restart is needed.

Notes on behaviour:

- `grafana/dashboards/` is generated and gitignored. Edit `.env` or the custom
  folder — anything written directly into the output is overwritten.
- **The list is authoritative.** A JSON file in the output that the current
  run did not produce is deleted, so removing an item from `GRAFANA_DASHBOARDS`
  actually removes the dashboard instead of leaving it behind.
- **Two dashboards may not share a title.** The title lives inside the JSON,
  so distinct filenames are not enough. On a collision Grafana refuses write
  access to the *whole provider* and silently stops updating every dashboard
  in the folder — it says so only in its own log. `fetch-dashboards.sh`
  checks for this and warns. Grafana dashboards 1860 and 12486 are both
  titled "Node Exporter Full", which is why only 1860 ships in the default
  list.
- Dashboards published with a `${DS_PROMETHEUS}` input placeholder are bound to
  `GRAFANA_DATASOURCE`. Newer dashboards use a datasource template variable
  instead and are left alone.
- A non-numeric ID fails immediately rather than fetching a 404.
- If a download fails but a previous copy of that file exists, the script keeps
  the old copy and warns. If there is no previous copy it fails, and grafana
  will not start — a fresh checkout therefore needs network access on first
  `docker compose up`.
- The script needs only curl and a POSIX shell, and also runs on the host once
  `.env` is loaded into the environment:

      set -a; . ./.env; set +a; sh scripts/fetch-dashboards.sh

## Grafana provisioning

`grafana/provisioning/` is read at Grafana start-up. Grafana parses only
`.yaml` and `.yml` there, so every file ending `.example` is inert until you
copy it:

    grafana/provisioning/
      datasources/prometheus.yml               Prometheus, with basic auth (active)
      dashboards/dashboards.yml                the provider (active)
      alerting/alerting.yaml.example           rules, contact points, policies
      plugins/plugins.yaml.example             app plugins
      access-control/access-control.yaml.example   RBAC roles and assignments

Only the datasource and the dashboard provider are active by default. To
enable one of the others:

    cd grafana/provisioning/alerting
    cp alerting.yaml.example alerting.yaml
    docker compose restart grafana

Things worth knowing before you do:

- **Provisioned objects are read-only in the UI.** Delete the file and restart
  to edit them there instead.
- **Removing an object from a file does not delete it** from Grafana's
  database. Alerting files take a `deleteRules:` list for that.
- **Grafana alerting is separate from Prometheus alerting.** The 92 rules in
  `prometheus/rules/` are evaluated by Prometheus and routed by Alertmanager.
  Rules in `alerting.yaml` are evaluated by Grafana and routed by Grafana's
  own notification policy. Provisioning the same condition in both means it
  fires twice — use Grafana's for what Prometheus cannot express, such as a
  query spanning two datasources.
- **`plugins.yaml` enables an app plugin, it does not install one.** This
  stack has no plugin volume, so a plugin installed by hand inside the
  container is lost on the next recreate. Install with `GF_INSTALL_PLUGINS`
  on the grafana service, or bake it into an image.
- **Custom RBAC roles need Grafana Enterprise.** On the OSS image here,
  Grafana logs that RBAC is unavailable and ignores the file. Permissions
  come from the built-in Viewer/Editor/Admin roles instead;
  `auto_assign_org_role` in `grafana.ini` decides what a new user gets, and
  this stack sets it to Viewer.

## What is monitored

Nine jobs, thirteen targets, and every one of them is a container in this
compose file — so a fresh clone comes up monitoring itself with nothing `down`
and nothing to fill in first:

    job                 target list                   transport
    prometheus          targets/prometheus.yml        https, basic auth
    alertmanager        targets/alertmanager.yml      https, basic auth
    grafana             targets/grafana.yml           https, no auth
    node_exporter       targets/node_exporter.yml     http, basic auth
    blackbox_exporter   targets/blackbox_exporter.yml http
    blackbox_icmp       targets/blackbox-icmp.yml     probe
    blackbox_dns        targets/blackbox-dns.yml      probe
    blackbox_tcp        targets/blackbox-tcp.yml      probe
    blackbox_http       targets/blackbox-http.yml     probe

Every job reads a `file_sd` list — there are no static targets in
`prometheus.yml`. Those lists are not tracked — `prometheus/example/` is, and
`config-init` seeds them from it on a first run — so adding a host of your own
is a one-line edit that stays local. Prometheus re-reads them itself: no
restart, no reload.

Prometheus, Alertmanager and Grafana are scraped through their own TLS
listeners rather than over plain http inside the network, so a broken
certificate or web-auth config shows up as a down target instead of passing
unnoticed. All three set `insecure_skip_verify`: they are reached by container
name, while the certificate names the domain from `.env`. Grafana needs no
credentials because it does not ask for a login on `/metrics` — set `[metrics]
basic_auth_username` and `basic_auth_password` in `grafana.ini` if you would
rather it did, and add a matching `basic_auth` block to the job.

Check them all at https://localhost:9090/targets.

### The two exporters

`node-exporter` and `blackbox-exporter` publish no ports. They are reachable
only from the compose network, which is why neither runs TLS or asks for a
password — do not add a `ports:` entry to either. node_exporter has no
authentication of its own and everything it exposes describes the host;
blackbox will connect anywhere it can reach on behalf of whoever asks it to.

node-exporter mounts `/` at `/host` read-only and runs with
`--path.rootfs=/host`, the upstream recipe: the collectors read the host
through that prefix and strip it again before labelling, so mountpoints come
out as `/` rather than `/host`. On Docker Desktop, `/` is the Linux VM rather
than Windows or macOS, so the numbers describe the VM — that is the whole of
what a container can see.

The `node_exporter` job carries basic auth for the benefit of the remote hosts
in `targets/node_exporter.yml`; the local container ignores the header. That
job is `http`, so on a link you do not trust the password crosses it in
cleartext and so do the metrics. Put a remote node_exporter behind TLS — it
takes the same `--web.config.file` Prometheus does — and give it a job of its
own with `scheme: https`.

### Probes

A probe is configured in two files. **What** to probe is a target list like
any other job — `targets/blackbox-icmp.yml` and its three neighbours. **How**
to probe is a module in `blackbox/blackbox.yml`: `icmp`, `tcp_connect`,
`http_2xx`, `dns_query`. Three of the four jobs fix their module in
`prometheus.yml`; DNS takes it from a label, so a second lookup is a new
module plus a new target line and no change to `prometheus.yml`.

Three things are worth knowing:

- Probes run **from inside the compose network**, so names resolve the way a
  container resolves them. `grafana:3000` is the port Grafana listens on
  internally, not `GRAFANA_PORT`. And `localhost` in the ICMP list is the
  blackbox container itself — a control that proves the prober works, not a
  network test. Use the machine's LAN address to ping the Docker host.
- **A DNS probe's target is the resolver, not the name.** The name is
  `query_name` in the module and the record type is `query_type` beside it,
  because blackbox reads both from the module and ignores them as probe
  parameters — they cannot be set from the target file. The target list
  repeats them as labels so a graph or an alert says which lookup it was; keep
  the two in step. Shipped defaults ask `127.0.0.11:53`, the resolver Docker
  gives every container, and `8.8.8.8:53` for comparison.
- The HTTP probe counts `401` as a failure, so point it at endpoints that need
  no login. Grafana's `/api/health` is public; Prometheus and Alertmanager
  require auth on every path, which is why the TCP probe covers those two
  instead.

`http_2xx` sets `insecure_skip_verify`, since this stack serves itself
self-signed certificates and a verifying probe would fail on every scrape.
`probe_ssl_earliest_cert_expiry` is exported either way, so
`Blackbox.rules.yml` still alerts on an expiry — what is given up is
verification of the chain. Set it to `false` in `blackbox/blackbox.yml` if
every URL you probe is publicly trusted.

To debug one, ask blackbox directly from inside the network:

```bash
docker run --rm --network metricwatch curlimages/curl:8.11.1 -s "http://blackbox-exporter:9115/probe?target=8.8.8.8&module=icmp&debug=true"
```

See `blackbox/README.md` for more.

### Sensors

There is no `sensors` job. `Sensors.rules.yml` is still here (in
`prometheus/example/rules/` as well as your own copy) and reads

    sensor_data{sensor="dht22",location="...",area="...",type="temperature"}

The two Sensor dashboards that went with it have been removed;
`scripts/grafana_dashboard/adapt.py` is what built them, if you want them
back. To use the rules, add a scrape job for whatever exposes that metric — a
microcontroller serving `/metrics` needs `scheme: http` and no auth, because
an ESP-class board has room for neither, so keep those on a network you trust
— and put the `Sensors.rules.yml` line back in `rule_files`. It is commented
out rather than deleted because its `absent(sensor_data)` alert would fire and
stay firing with no such job.

## Alerting

Alertmanager sends email via the smarthost set in `alertmanager.yml`, reading
its password from `secrets/alertmanager/smtp_password` — see Secrets above.

Routing mutes by severity and time of day (Asia/Kolkata): `warning` is muted
during business hours and `info` outside them. `critical` is never muted —
it notifies around the clock at `group_wait: 0m`.

`PrometheusAlertmanagerE2eDeadManSwitch` is `expr: vector(1)`, an always-firing
critical alert meant as an end-to-end delivery check. It is routed to the
`null` receiver, which discards it — otherwise it would email every
`repeat_interval` (1h) forever. That route is matched on alertname and must
stay above the `critical` route, since sibling routes are first match wins.
Repoint it at a dead-man's-switch endpoint if one is ever set up.

## Notes

- Eight rule files are present and seven are loaded, 98 alerts. Three of the
  seven have no matching scrape job and so never fire: `WindowsExporter` (5
  alerts, no Windows target), `MysqldExporter` (10, no mysqld_exporter target)
  and `Ping` (3, SNMP metrics with no SNMP job). That leaves 80 able to fire.
  They are kept because adding the matching exporter is the only thing
  standing between them and working; delete the file and its `rule_files`
  line if you would rather not carry them.
- `Blackbox.rules.yml` (6 alerts) covers all four probe jobs at once by
  matching `job=~"blackbox_.*"`: a probe failing for two minutes, one that is
  passing but slow, a bad HTTP status, and TLS expiry — which needs a rule of
  its own precisely because the probes do not verify certificates. It also
  alerts on blackbox_exporter itself being down, since every other rule in
  the file goes quiet rather than firing when that happens.
- `Sensors.rules.yml` (7 alerts) is the eighth file and is **not** loaded,
  because there is no `sensors` job for it to watch and its
  `absent(sensor_data)` alert would fire forever. It covers the target being
  down, no `sensor_data` at all, a reading that has not moved in an hour (a
  failed DHT22 keeps serving its last value), readings outside what the
  hardware can measure, and wide temperature bounds. The thresholds are
  deliberately loose — narrow them per location by adding a label selector
  rather than editing them in place, so a greenhouse and a server room can
  differ.
- `promtool check rules` reports a lint error on `NodeExporter.rules.yml` for
  duplicate `HostOutOfMemory` and `HostCpuHighIowait` names. That is expected:
  each is a set of alerts at different thresholds selected by the
  `monitortype` label. Prometheus loads the file and all 46 rules.
- All four passwords were committed in plain text in the initial commit — two
  as live config, two inside commented-out blocks — and remain recoverable
  from git history. Moving them into `secrets/` stops them spreading further
  but does not remove them from the history that already exists. Rotate all
  four at the source for this to mean anything.
- `grafana/ldap.toml` carries the upstream sample `bind_password`. It is not
  in `secrets/` because the file is not mounted into the container and nothing
  reads it.
- Earlier versions of this stack used TLS, basic auth and a `.env` file. The
  TLS and basic auth settings on the `prometheus` and `alertmanager` jobs are
  live again, now taking their passwords from `secrets/` rather than inline.
  `.gitignore` excludes a `backup/` directory of old configs and certificates,
  but no such directory is present here.
