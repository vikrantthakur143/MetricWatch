# blackbox

`blackbox.yml` holds the modules — *how* to probe. What to probe is next door
in `prometheus/targets/blackbox-*.yml`, one file per probe job. Both are
tracked and both ship ready to run.

Four modules: `icmp`, `tcp_connect`, `http_2xx`, `dns_query`.

## The DNS split

A DNS probe's *target* is the **resolver** being asked. The name being looked
up is `query_name` inside the module, and the record type is `query_type`
beside it.

That split is not a design choice — blackbox reads both from the module and
ignores them as probe parameters, so they cannot come from the target file
however they are passed. `blackbox-dns.yml` repeats them as labels so a graph
or an alert says which lookup it was; change one in `blackbox.yml` and change
the matching label there.

To watch a second name, copy the `dns_query` block under a new name and add a
target line pointing at it:

```yaml
- labels:
    module: dns_query_mx
    query_name: example.com
    query_type: MX
  targets:
  - 127.0.0.11:53
```

The `module` label is what selects the block; Prometheus turns it into the
`module=` parameter and then drops it, so it does not end up on the series.
The other three probe jobs fix their module in `prometheus.yml` instead,
because there is only ever one sensible choice.

## Applying a change

    docker compose up -d

`config-reload` reloads blackbox first and Prometheus second, on purpose:
Prometheus scrapes the moment it reloads, so learning about a new module
before the exporter does gets a `400 Unknown module` and a target that sits
down until the next scrape.

## Debugging a probe

blackbox publishes no port, so ask it from inside the network:

```bash
docker run --rm --network metricwatch curlimages/curl:8.11.1 -s "http://blackbox-exporter:9115/probe?target=8.8.8.8&module=icmp&debug=true"
```

The debug output ends with the module it used and why a failing probe failed,
which is usually quicker than reading `probe_success` in Prometheus.

Validate the file before restarting:

```bash
docker run --rm -v "$PWD/blackbox:/etc/blackbox_exporter:ro" prom/blackbox-exporter:v0.26.0 --config.file=/etc/blackbox_exporter/blackbox.yml --config.check
```
