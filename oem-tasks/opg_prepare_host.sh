#!/usr/bin/env bash
set -euo pipefail
umask 027

BASE=/mnt/datadomain/software/patches/Linux/oracle-patch-guard
CONFIG_SRC="$BASE/config"
PROJECT="$BASE/current/project"

ETC_DIR=/etc/oracle-patch-guard
RUN_ROOT=/var/log/oracle-patch-guard
LOCK_ROOT=/var/lock/oracle-patch-guard

fail() {
  rc=$1
  shift
  echo "OPG_PREPARE_RESULT|host=$(hostname -f)|status=BLOCKED|exit_code=$rc|message=$*"
  exit "$rc"
}

echo "OPG_PREPARE|host=$(hostname -f)|phase=START"

# Centrale bron bereikbaar?
test -d "$PROJECT" || fail 20 "central project unavailable"
test -r "$CONFIG_SRC/patchGD_guard.conf" || fail 20 "central config unavailable"
test -r "$CONFIG_SRC/approval_public.pem" || fail 20 "approval public key unavailable"
test -r "$CONFIG_SRC/oracle_home_rebuild.md" || fail 20 "recovery procedure unavailable"

# Frozen executables aanwezig?
for f in \
  "$PROJECT/patchGD_guard.sh" \
  "$PROJECT/oem_assess.sh" \
  "$PROJECT/oem_apply.sh" \
  "$PROJECT/oem_status.sh" \
  "$PROJECT/checks/check_rman_backup" \
  "$PROJECT/checks/check_oracle_home_recovery" \
  "$PROJECT/checks/check_maintenance_window" \
  "$PROJECT/checks/check_dataguard"
do
  test -x "$f" || fail 20 "not executable: $f"
done

# Benodigde OS-tools
for cmd in flock sha256sum openssl timeout; do
  command -v "$cmd" >/dev/null 2>&1 || fail 20 "missing command: $cmd"
done

# Hostconfig installeren
sudo -n install -d -o root -g oinstall -m 0750 "$ETC_DIR"

sudo -n install -o root -g oinstall -m 0640 \
  "$CONFIG_SRC/patchGD_guard.conf" \
  "$ETC_DIR/patchGD_guard.conf"

sudo -n install -o root -g oinstall -m 0640 \
  "$CONFIG_SRC/approval_public.pem" \
  "$ETC_DIR/approval_public.pem"

sudo -n install -o root -g oinstall -m 0640 \
  "$CONFIG_SRC/oracle_home_rebuild.md" \
  "$ETC_DIR/oracle_home_rebuild.md"

sudo -n install -d -o root -g oinstall -m 0750 \
  /var/lib/oracle-patch-guard

sudo -n install -d -o root -g oinstall -m 0750 \
  /var/lib/oracle-patch-guard/approvals

# Runtime directories
sudo -n install -d -o oracle -g oinstall -m 0750 "$RUN_ROOT"
sudo -n install -d -o root -g oinstall -m 2770 "$LOCK_ROOT"

# Validatie
test -r "$ETC_DIR/patchGD_guard.conf" || fail 20 "installed config unreadable"
test -r "$ETC_DIR/approval_public.pem" || fail 20 "installed approval key unreadable"
test -r "$ETC_DIR/oracle_home_rebuild.md" || fail 20 "installed recovery procedure unreadable"
test -d "$RUN_ROOT" || fail 20 "run root missing"
test -d "$LOCK_ROOT" || fail 20 "lock root missing"

echo "OPG_PREPARE_RESULT|host=$(hostname -f)|status=READY|exit_code=0"
exit 0
