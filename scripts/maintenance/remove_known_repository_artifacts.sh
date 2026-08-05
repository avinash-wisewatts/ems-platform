#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"
FILES=(
  postgres/ddl/110_enhance_eniscope_energy_profile.sql.before_energy_domain_fix
  postgres/ddl/121_energy_1min_5min_analytics.sql.before_groupby_fix
  postgres/ddl/60_asset_analytics_base.sql.before_metering_fix
  postgres/migrations/170_energy_1min_5min_analytics.sql.before_groupby_fix
  postgres/restructure_manifest.csv.before_170
  postgres/restructure_manifest.csv.bak-grafana-mvp-20260802-231703
  telegraf/config/telegraf.conf.backup-20260803-070903
  telegraf/config/telegraf.conf.backup-20260803-072442
)
for file in "${FILES[@]}"; do
  if [[ -e "$file" ]]; then
    rm -- "$file"
    printf '[REMOVED] %s\n' "$file"
  else
    printf '[ABSENT]  %s\n' "$file"
  fi
done
