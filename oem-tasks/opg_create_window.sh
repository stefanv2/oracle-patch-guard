#!/usr/bin/env bash
set -euo pipefail
umask 077

RUN_ID=${1:?RUN_ID ontbreekt}
ORACLE_HOME_TARGET=${2:?TARGET_ORACLE_HOME ontbreekt}
CHANGE_ID=${3:-OEM-PATCH-GUARD}

WINDOW=/etc/oracle-patch-guard/maintenance_window.conf
TMP=$(mktemp /tmp/opg-maintenance-window.XXXXXX)

START=$(date --iso-8601=seconds)
END=$(date --iso-8601=seconds -d '+6 hours')

cat > "$TMP" <<EOW
hostname=$(hostname -f)
change_id=$CHANGE_ID
start=$START
end=$END
allowed_oracle_home=$ORACLE_HOME_TARGET
run_id=$RUN_ID
min_remaining_minutes=60
EOW

sudo -n install -o root -g oinstall -m 0640 \
  "$TMP" "$WINDOW"

rm -f "$TMP"

echo "OPG_WINDOW|host=$(hostname -f)|run_id=$RUN_ID|start=$START|end=$END"
echo "OPG_WINDOW_RESULT|host=$(hostname -f)|status=READY|exit_code=0"
