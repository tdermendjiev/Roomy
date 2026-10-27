#!/bin/sh
# Roomy post-install: create the metrics textfile directory if node_exporter is around, reload systemd.
set -e
if [ -d /var/lib/node_exporter ]; then
  mkdir -p /var/lib/node_exporter/textfile_collector
fi
mkdir -p /var/log/roomy
if command -v systemctl >/dev/null 2>&1; then
  systemctl daemon-reload >/dev/null 2>&1 || true
fi
cat <<'MSG'
roomy installed.
  roomy doctor                           check the environment
  roomy scan                             see what could be reclaimed
  systemctl enable --now roomy-fleet@<user>.timer   unattended cleanup for <user>'s home
Policy: /etc/roomy/policy.json  (defaults: safe tier only, quarantine, 7-day retention)
MSG
