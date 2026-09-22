#!/usr/bin/env bash
# Add a node_exporter target to prometheus/targets/nodes.yml and reload Prometheus.
#
# Usage:
#   scripts/add-node.sh HOST[:PORT] [--env ENV] [--role ROLE] [--no-reload]
#
# Examples:
#   scripts/add-node.sh 10.0.10.13
#   scripts/add-node.sh web-03.internal:9100 --env prod --role web
#
# The target is appended as its own "- targets:" block, written to a temp file
# and moved into place so a half-written file is never left behind. Prometheus
# re-reads file_sd targets on its own; the reload at the end also picks up rule
# changes. Use --no-reload when editing a checkout that is not the running stack.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TARGETS_FILE="${TARGETS_FILE:-$REPO_ROOT/prometheus/targets/nodes.yml}"
DEFAULT_PORT="${DEFAULT_PORT:-9100}"

usage() {
  cat <<USAGE
Usage: $(basename "$0") HOST[:PORT] [--env ENV] [--role ROLE] [--no-reload]

Appends HOST (default port $DEFAULT_PORT) to $TARGETS_FILE
and reloads Prometheus through "make reload".
USAGE
}

die() {
  echo "add-node: $*" >&2
  exit 1
}

host=""
env_label=""
role_label=""
reload=1

while [[ $# -gt 0 ]]; do
  case "$1" in
    --env)
      [[ $# -ge 2 ]] || die "--env needs a value"
      env_label="$2"
      shift 2
      ;;
    --role)
      [[ $# -ge 2 ]] || die "--role needs a value"
      role_label="$2"
      shift 2
      ;;
    --no-reload)
      reload=0
      shift
      ;;
    -h | --help)
      usage
      exit 0
      ;;
    -*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$host" ]] || die "only one host per run"
      host="$1"
      shift
      ;;
  esac
done

if [[ -z "$host" ]]; then
  usage >&2
  exit 1
fi

# Hostname or IPv4 with an optional :port. Label values are kept simple so the
# YAML written below never needs quoting.
[[ "$host" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?(:[0-9]{1,5})?$ ]] || die "invalid host: $host"
for value in "$env_label" "$role_label"; do
  [[ -z "$value" || "$value" =~ ^[A-Za-z0-9_.-]+$ ]] || die "label values may only contain letters, digits, _ . and -: $value"
done

target="$host"
[[ "$target" == *:* ]] || target="$host:$DEFAULT_PORT"

[[ -f "$TARGETS_FILE" ]] || die "targets file not found: $TARGETS_FILE"

# Already listed (quoted or not, any indentation)? Then there is nothing to do.
escaped_target="${target//./\\.}"
if grep -Eq "^[[:space:]]*-[[:space:]]+\"?${escaped_target}\"?[[:space:]]*$" "$TARGETS_FILE"; then
  echo "add-node: $target is already in $TARGETS_FILE"
  exit 0
fi

tmp="$(mktemp "${TARGETS_FILE}.XXXXXX")"
cleanup() {
  rm -f "$tmp"
}
trap cleanup EXIT

cp "$TARGETS_FILE" "$tmp"
# Make sure the existing content ends with a newline before appending.
if [[ -s "$tmp" && "$(tail -c 1 "$tmp" | od -An -c | tr -d ' ')" != '\n' ]]; then
  echo >> "$tmp"
fi

{
  echo "- targets:"
  echo "    - \"$target\""
  if [[ -n "$env_label" || -n "$role_label" ]]; then
    echo "  labels:"
    if [[ -n "$env_label" ]]; then
      echo "    env: $env_label"
    fi
    if [[ -n "$role_label" ]]; then
      echo "    role: $role_label"
    fi
  fi
} >> "$tmp"

# Best effort structural check before the live file is replaced.
if command -v python3 > /dev/null 2>&1 && python3 -c 'import yaml' > /dev/null 2>&1; then
  python3 - "$tmp" <<'PY' || die "the updated targets file does not parse as a file_sd list; leaving $TARGETS_FILE unchanged"
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as handle:
    data = yaml.safe_load(handle)
assert isinstance(data, list), "top level must be a list"
for group in data:
    assert isinstance(group, dict) and isinstance(group.get("targets"), list), "each entry needs a targets list"
PY
fi

mv "$tmp" "$TARGETS_FILE"
trap - EXIT
echo "add-node: added $target to $TARGETS_FILE"

if (( reload )); then
  if command -v make > /dev/null 2>&1 && command -v docker > /dev/null 2>&1; then
    make -C "$REPO_ROOT" reload
  else
    echo "add-node: make or docker not found, skipping reload (Prometheus re-reads the file within a minute anyway)" >&2
  fi
fi
