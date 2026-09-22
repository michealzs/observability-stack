#!/usr/bin/env python3
"""Lint Prometheus rule files beyond what promtool checks.

Every alerting rule must have an expression, a "for" duration, a severity label
from the allowed set, and summary and description annotations. Recording rules
must have an expression and follow the level:metric:operation naming convention.

Usage: scripts/check_rules.py prometheus/rules/*.yml
"""

import re
import sys

try:
    import yaml
except ImportError:  # pragma: no cover
    sys.stderr.write("check_rules: PyYAML is required (python3 -m pip install pyyaml)\n")
    sys.exit(2)

ALLOWED_SEVERITIES = ("critical", "warning", "info")
DURATION = re.compile(r"^(\d+(ms|s|m|h|d|w|y))+$")
RECORD_NAME = re.compile(r"^[a-zA-Z_][a-zA-Z0-9_]*:[a-zA-Z0-9_]+:[a-zA-Z0-9_]+$")


def check_alert(where, rule):
    errors = []
    for key in ("expr", "for"):
        if key not in rule:
            errors.append(f"{where}: missing '{key}'")
    if "for" in rule and not DURATION.match(str(rule["for"])):
        errors.append(f"{where}: 'for' must be a duration such as 5m or 0m, got {rule['for']!r}")
    severity = (rule.get("labels") or {}).get("severity")
    if severity not in ALLOWED_SEVERITIES:
        errors.append(f"{where}: labels.severity must be one of {', '.join(ALLOWED_SEVERITIES)}, got {severity!r}")
    annotations = rule.get("annotations") or {}
    for key in ("summary", "description"):
        if not str(annotations.get(key) or "").strip():
            errors.append(f"{where}: missing annotations.{key}")
    return errors


def check_record(where, rule):
    errors = []
    if "expr" not in rule:
        errors.append(f"{where}: missing 'expr'")
    if not RECORD_NAME.match(str(rule["record"])):
        errors.append(f"{where}: recording rule names must look like level:metric:operation")
    return errors


def check_file(path):
    errors = []
    with open(path, encoding="utf-8") as handle:
        data = yaml.safe_load(handle)
    groups = (data or {}).get("groups") or []
    if not groups:
        return [f"{path}: no rule groups found"]
    for group in groups:
        group_name = group.get("name", "<unnamed>")
        rules = group.get("rules") or []
        if not rules:
            errors.append(f"{path}: group {group_name} has no rules")
        for index, rule in enumerate(rules):
            if "alert" in rule:
                errors.extend(check_alert(f"{path}: alert {rule['alert']}", rule))
            elif "record" in rule:
                errors.extend(check_record(f"{path}: record {rule['record']}", rule))
            else:
                errors.append(f"{path}: group {group_name} rule #{index + 1} is neither an alert nor a record")
    return errors


def main(paths):
    if not paths:
        sys.stderr.write(__doc__)
        return 2
    errors = []
    alerts = 0
    records = 0
    for path in paths:
        errors.extend(check_file(path))
        with open(path, encoding="utf-8") as handle:
            for group in (yaml.safe_load(handle) or {}).get("groups") or []:
                for rule in group.get("rules") or []:
                    alerts += "alert" in rule
                    records += "record" in rule
    for error in errors:
        print(error)
    if errors:
        print(f"check_rules: {len(errors)} problem(s) in {len(paths)} file(s)")
        return 1
    print(f"check_rules: OK ({alerts} alerting rules, {records} recording rules in {len(paths)} files)")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
