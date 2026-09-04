#!/usr/bin/env python3
"""Adapt the hand-built sensor dashboards for provisioning.

The originals in this directory are Grafana UI exports. Four changes are
needed before they can be provisioned into a fresh Grafana:

  1. Every panel pins the datasource uid "Prometheus-main", which exists only
     in the Grafana they were exported from. Provisioned dashboards must not
     name a uid, so they are repointed at a "datasource" template variable
     that resolves wherever they are loaded.

  2. Two of the four query final_sensor_data, a metric this stack does not
     produce. They are dropped rather than ported: they duplicate the other
     two panel for panel.

  3. The filters were job/instance -- which board answered -- while the
     metric carries location and area, which is what someone reading the
     dashboard actually wants. Those become the variables.

  4. Provisioned dashboards need id: null, or Grafana treats the export's id
     as a database row to overwrite.

Run from the repo root, writes into grafana/dashboards-custom/:

    python scripts/grafana_dashboard/adapt.py
"""

import json
import os
import sys

SRC = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(SRC, "..", "..", "grafana", "dashboards-custom")

# The uid baked into the exports, and what replaces it.
STALE_UID = "Prometheus-main"
DS_REF = {"type": "prometheus", "uid": "${datasource}"}


def ds_variable():
    """A datasource picker, defaulting to whatever Prometheus is present."""
    return {
        "current": {},
        "hide": 0,
        "includeAll": False,
        "label": "Datasource",
        "multi": False,
        "name": "datasource",
        "options": [],
        "query": "prometheus",
        "refresh": 1,
        "regex": "",
        "skipUrlSync": False,
        "type": "datasource",
    }


def label_variable(name, label, query, all_value=True):
    """A multi-select over one label of sensor_data."""
    return {
        "current": {},
        "datasource": DS_REF,
        "definition": query,
        "hide": 0,
        # includeAll + multi so the dashboard is useful before anyone has
        # chosen anything, which is how a wall display is normally left.
        "includeAll": all_value,
        "label": label,
        "multi": True,
        "name": name,
        "options": [],
        "query": {"qryType": 1, "query": query, "refId": name},
        "refresh": 1,
        "regex": "",
        "skipUrlSync": False,
        "sort": 1,
        "type": "query",
    }


def walk_panels(panels):
    """Yield every panel, including those nested inside collapsed rows."""
    for p in panels:
        yield p
        for nested in p.get("panels") or []:
            yield nested


def repoint_datasources(obj):
    """Replace the hardcoded uid anywhere it appears, at any depth."""
    if isinstance(obj, dict):
        if obj.get("uid") == STALE_UID:
            obj["uid"] = "${datasource}"
        for v in obj.values():
            repoint_datasources(v)
    elif isinstance(obj, list):
        for v in obj:
            repoint_datasources(v)


def rewrite_expr(expr, scoped):
    """Swap the job/instance filters for location/area/sensor ones.

    `scoped` distinguishes the detail dashboard, which filters on the
    variables, from the overview, which deliberately shows everything.
    """
    expr = expr.replace("final_sensor_data", "sensor_data")
    # The exports filter on a single board. Regex-match the variables instead,
    # so "All" works and multi-select produces a valid selector.
    expr = expr.replace('instance="$node", job="$job"',
                        'location=~"$location", area=~"$area"')
    expr = expr.replace('instance="$node",job="$job"',
                        'location=~"$location", area=~"$area"')
    # dht22 is one sensor model among several; let the variable decide.
    if scoped:
        expr = expr.replace('sensor="dht22"', 'sensor=~"$sensor"')
    else:
        expr = expr.replace('sensor="dht22", ', '').replace('sensor="dht22"', '')
        expr = expr.replace("{, ", "{").replace("{ ", "{")
    return expr


def adapt(src_name, out_name, uid, title, scoped):
    with open(os.path.join(SRC, src_name), encoding="utf-8") as fh:
        d = json.load(fh)

    repoint_datasources(d)

    for p in walk_panels(d.get("panels", [])):
        if p.get("type") == "row":
            continue
        p.setdefault("datasource", DS_REF)
        for t in p.get("targets") or []:
            if "expr" in t:
                t["expr"] = rewrite_expr(t["expr"], scoped)
            t.setdefault("datasource", DS_REF)
            # Legends read better as place than as board address.
            if not t.get("legendFormat") or t["legendFormat"] in ("{{instance}}", ""):
                t["legendFormat"] = "{{location}}/{{area}}"

    # The exports carry "links" to the Grafana and the boards they were built
    # against, by real hostname. The output of this script is tracked, so
    # those would be published. Drop them rather than rewriting them: a link
    # to someone else's LAN is no use to anyone reading the repo.
    dropped = [l.get("url", "") for l in (d.get("links") or []) if l.get("url")]
    if dropped:
        d["links"] = []
        print("  dropped %d dashboard link(s) naming real hosts" % len(dropped))

    # Same for a variable whose saved "current" value is a real target.
    for v in d.get("templating", {}).get("list", []):
        v.pop("current", None)

    variables = [ds_variable()]
    if scoped:
        variables += [
            label_variable("location", "Location",
                           "label_values(sensor_data, location)"),
            label_variable("area", "Area",
                           'label_values(sensor_data{location=~"$location"}, area)'),
            label_variable("sensor", "Sensor",
                           "label_values(sensor_data, sensor)"),
        ]
    d["templating"] = {"list": variables}

    # Provisioning owns these fields.
    d["id"] = None
    d["uid"] = uid
    d["title"] = title
    d["version"] = 1
    d["editable"] = False
    d["refresh"] = "30s"
    tags = set(d.get("tags") or []) | {"sensor", "metricwatch"}
    d["tags"] = sorted(tags)

    out_path = os.path.normpath(os.path.join(OUT, out_name))
    with open(out_path, "w", encoding="utf-8", newline="\n") as fh:
        json.dump(d, fh, indent=2, sort_keys=False)
        fh.write("\n")
    print("wrote %s  (uid=%s, title=%r)" % (out_path, uid, title))


def main():
    if not os.path.isdir(OUT):
        sys.exit("no such directory: %s -- run from the repo root" % OUT)
    adapt("Dashboard_Sensor_Data.json", "sensor-data.json",
          "metricwatch-sensors", "Sensor Data", scoped=True)
    adapt("Dashboard_Sensor_Data_Public.json", "sensor-data-overview.json",
          "metricwatch-sensors-all", "Sensor Data Overview", scoped=False)


if __name__ == "__main__":
    main()
