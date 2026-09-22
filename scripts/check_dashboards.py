#!/usr/bin/env python3
"""Validate the provisioned Grafana dashboards.

Checks that every file parses as JSON, has the top level keys Grafana needs
(uid, title, panels, schemaVersion), keeps "id" null so provisioning does not
collide with existing dashboards, uses unique uids, and that every panel,
target and template variable references a datasource uid this stack provisions.

Usage: scripts/check_dashboards.py grafana/dashboards/*.json
"""

import json
import sys

REQUIRED_KEYS = ("uid", "title", "panels", "schemaVersion")
PROVISIONED_DATASOURCES = {"prometheus", "loki", "alertmanager"}
PANEL_TYPES_WITHOUT_DATASOURCE = {"row", "text"}


def iter_panels(panels):
    for panel in panels:
        yield panel
        yield from iter_panels(panel.get("panels") or [])


def datasource_uid(obj):
    datasource = obj.get("datasource")
    if isinstance(datasource, dict):
        return datasource.get("uid")
    return datasource


def check_dashboard(path, dashboard):
    errors = []
    for key in REQUIRED_KEYS:
        if key not in dashboard:
            errors.append(f"{path}: missing top level key '{key}'")
    if dashboard.get("id") is not None:
        errors.append(f"{path}: 'id' must be null for provisioned dashboards")
    if not isinstance(dashboard.get("panels"), list) or not dashboard.get("panels"):
        errors.append(f"{path}: 'panels' must be a non-empty list")
        return errors
    seen_panel_ids = set()
    for panel in iter_panels(dashboard["panels"]):
        panel_id = panel.get("id")
        title = panel.get("title") or f"panel {panel_id}"
        if panel_id in seen_panel_ids:
            errors.append(f"{path}: duplicate panel id {panel_id}")
        seen_panel_ids.add(panel_id)
        if panel.get("type") in PANEL_TYPES_WITHOUT_DATASOURCE:
            continue
        if datasource_uid(panel) not in PROVISIONED_DATASOURCES:
            errors.append(f"{path}: panel '{title}' datasource uid {datasource_uid(panel)!r} is not provisioned")
        for target in panel.get("targets") or []:
            if datasource_uid(target) not in PROVISIONED_DATASOURCES:
                errors.append(f"{path}: panel '{title}' target {target.get('refId')} datasource is not provisioned")
            if not (target.get("expr") or "").strip():
                errors.append(f"{path}: panel '{title}' target {target.get('refId')} has an empty expr")
    for variable in (dashboard.get("templating") or {}).get("list") or []:
        if variable.get("type") == "query" and datasource_uid(variable) not in PROVISIONED_DATASOURCES:
            errors.append(f"{path}: variable '{variable.get('name')}' datasource is not provisioned")
    return errors


def main(paths):
    if not paths:
        sys.stderr.write(__doc__)
        return 2
    errors = []
    uids = {}
    for path in paths:
        try:
            with open(path, encoding="utf-8") as handle:
                dashboard = json.load(handle)
        except ValueError as exc:
            errors.append(f"{path}: invalid JSON: {exc}")
            continue
        errors.extend(check_dashboard(path, dashboard))
        uid = dashboard.get("uid")
        if uid in uids:
            errors.append(f"{path}: uid {uid!r} is already used by {uids[uid]}")
        uids[uid] = path
    for error in errors:
        print(error)
    if errors:
        print(f"check_dashboards: {len(errors)} problem(s) in {len(paths)} file(s)")
        return 1
    print(f"check_dashboards: OK ({len(paths)} dashboards)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
