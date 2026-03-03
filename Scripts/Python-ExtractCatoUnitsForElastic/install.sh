#!/usr/bin/env bash
set -euo pipefail

# Installs a root-crontab job for daily Cato unit export and configures log rotation.
# Script location: /root/work/scripts/shell/cato-betriebsstellen

SCRIPT_DIR="/root/work/scripts/shell/cato-betriebsstellen"
SCRIPT_FILE="${SCRIPT_DIR}/Python-ExtractCatoUnitsForElastic.py"
LOGROTATE_CONF="/etc/logrotate.d/cato_betr"
TARGET_LOG_DIR="/var/log/cato_betr"
CRON_MARKER="# cato_betr daily export"
CRON_SCHEDULE="34 6 * * *"
CRON_CMD="${CRON_SCHEDULE} ${SCRIPT_FILE} >> ${TARGET_LOG_DIR}/cato_export.log 2>&1"

if [[ "$(id -u)" -ne 0 ]]; then
  echo "Please run as root." >&2
  exit 1
fi

mkdir -p "${TARGET_LOG_DIR}"

touch "${TARGET_LOG_DIR}/cato_export.log"
chmod 0755 "${TARGET_LOG_DIR}"
chmod 0644 "${TARGET_LOG_DIR}/cato_export.log"

cat > "${LOGROTATE_CONF}" <<ROTATE
${TARGET_LOG_DIR}/*.log {
    daily
    rotate 14
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
}
ROTATE

current_cron="$(crontab -l 2>/dev/null || true)"
filtered_cron="$(printf '%s\n' "${current_cron}" | sed '/cato_betr daily export/d' | sed '/Python-ExtractCatoUnitsForElastic.py/d')"

new_cron="${filtered_cron}"
if [[ -n "${new_cron}" ]]; then
  new_cron+=$'\n'
fi
new_cron+="${CRON_MARKER}"
new_cron+=$'\n'
new_cron+="${CRON_CMD}"
new_cron+=$'\n'

printf '%s' "${new_cron}" | crontab -

echo "Installed root crontab entry: ${CRON_CMD}"
echo "Installed logrotate config: ${LOGROTATE_CONF}"
