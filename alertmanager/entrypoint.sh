#!/bin/sh
# Render the Alertmanager configuration from its envsubst template, then start
# Alertmanager. Only the variables listed below are substituted, so Go template
# syntax and any literal "$" elsewhere in the file are left untouched.
#
#   entrypoint.sh [alertmanager flags...]   render, then exec alertmanager
#   entrypoint.sh check                     render, then run amtool check-config
set -eu

TEMPLATE="${ALERTMANAGER_TEMPLATE:-/etc/alertmanager/alertmanager.yml.tmpl}"
CONFIG="${ALERTMANAGER_CONFIG:-/etc/alertmanager/alertmanager.yml}"

: "${SLACK_WEBHOOK_URL:?SLACK_WEBHOOK_URL must be set (see .env.example)}"
: "${SLACK_CHANNEL:=#alerts}"
export SLACK_CHANNEL

if [ ! -r "$TEMPLATE" ]; then
  echo "entrypoint: template $TEMPLATE not found or not readable" >&2
  exit 1
fi

# shellcheck disable=SC2016 # the single quoted list is the envsubst variable filter, not a shell expansion
envsubst '${SLACK_WEBHOOK_URL} ${SLACK_CHANNEL}' < "$TEMPLATE" > "$CONFIG"
chmod 0600 "$CONFIG"

if [ "${1:-}" = "check" ]; then
  exec amtool check-config "$CONFIG"
fi

exec alertmanager --config.file="$CONFIG" "$@"
