#!/usr/bin/env bash
set -euo pipefail
umask 027

ETC_DIR=/etc/oracle-patch-guard
CONTEXT_ROOT=/var/lib/oracle-patch-guard
CONTEXT_HELPER=/usr/local/sbin/opg_context_root.sh
MEDIA_HELPER=/usr/local/sbin/opg_media_stage_root.sh
MEDIA_ENGINE=/usr/local/libexec/opg_media_stage_root.py
RUN_USER=oracle
CONFIG_GROUP=oinstall
if [[ -n ${OPG_PREPARE_TEST_ROOT:-} ]]; then
  [[ "$OPG_PREPARE_TEST_ROOT" == /tmp/opg-bootstrap-tests.* ]] || exit 70
  ETC_DIR=$OPG_PREPARE_TEST_ROOT/etc/oracle-patch-guard
  CONTEXT_ROOT=$OPG_PREPARE_TEST_ROOT/var/lib/oracle-patch-guard
  CONTEXT_HELPER=$OPG_PREPARE_TEST_ROOT/usr/local/sbin/opg_context_root.sh
  MEDIA_HELPER=$OPG_PREPARE_TEST_ROOT/usr/local/sbin/opg_media_stage_root.sh
  MEDIA_ENGINE=$OPG_PREPARE_TEST_ROOT/usr/local/libexec/opg_media_stage_root.py
  RUN_USER=root
  CONFIG_GROUP=root
fi

fail() {
  rc=$1
  shift
  echo "OPG_PREPARE_RESULT|host=$(hostname -f)|status=BLOCKED|exit_code=$rc|message=$*"
  exit "$rc"
}

echo "OPG_PREPARE|host=$(hostname -f)|phase=START"

# BOOTSTRAP is the sole installer. PREPARE checks for deployment drift; the
# calling OEM wrapper still owns creation/validation of the formal runcontext.
CONFIG=$ETC_DIR/patchGD_guard.conf
[[ -f "$CONFIG" && ! -L "$CONFIG" && $(stat -c '%U:%G:%a' "$CONFIG") == "root:${CONFIG_GROUP}:640" ]] \
  || fail 20 "host config missing/unsafe; run bootstrap as root"
declare -A paths=()
while IFS= read -r raw || [[ -n "$raw" ]]; do
  raw=${raw%$'\r'}
  [[ "$raw" == *=* ]] || continue
  key=${raw%%=*}; value=${raw#*=}
  key=${key#"${key%%[![:space:]]*}"}; key=${key%"${key##*[![:space:]]}"}
  value=${value#"${value%%[![:space:]]*}"}; value=${value%"${value##*[![:space:]]}"}
  case "$key" in
    OPG_ROOT|RUN_ROOT|LOCK_ROOT)
      [[ -z ${paths[$key]+x} && "$value" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail 20 "invalid or duplicate $key"
      paths[$key]=$value ;;
  esac
done <"$CONFIG"
BASE=${paths[OPG_ROOT]:-}; RUN_ROOT=${paths[RUN_ROOT]:-}; LOCK_ROOT=${paths[LOCK_ROOT]:-}
[[ -n "$BASE" && -n "$RUN_ROOT" && -n "$LOCK_ROOT" ]] || fail 20 "required runtime paths missing"
CONFIG_SRC="$BASE/config"
PROJECT="$BASE/current/project"

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

# Validate installed artifacts; never refresh configuration or trust mid-run.
for name in patchGD_guard.conf approval_public.pem oracle_home_rebuild.md; do
  target=$ETC_DIR/$name
  [[ -f "$target" && ! -L "$target" && $(stat -c '%U:%G:%a' "$target") == "root:${CONFIG_GROUP}:640" ]] \
    || fail 20 "unsafe installed artifact: $target; rerun bootstrap"
  cmp -s "$CONFIG_SRC/$name" "$target" || fail 20 "central/local artifact differs: $name; rerun bootstrap"
done
for target in "$CONTEXT_HELPER" "$MEDIA_HELPER" "$MEDIA_ENGINE"; do
  [[ -f "$target" && ! -L "$target" && $(stat -c '%U:%G:%a' "$target") == root:root:755 ]] \
    || fail 20 "unsafe installed helper: $target; rerun bootstrap"
  cmp -s "$BASE/current/oem-tasks/${target##*/}" "$target" || fail 20 "helper release differs; rerun bootstrap"
done
for spec in "$ETC_DIR|root:root:755" "$CONTEXT_ROOT|root:${CONFIG_GROUP}:750" \
            "$RUN_ROOT|${RUN_USER}:${CONFIG_GROUP}:750" "$LOCK_ROOT|root:${CONFIG_GROUP}:2770"; do
  target=${spec%%|*}; expected=${spec#*|}
  [[ -d "$target" && ! -L "$target" && $(stat -c '%U:%G:%a' "$target") == "$expected" ]] \
    || fail 20 "runtime directory missing/unsafe: $target; rerun bootstrap"
done

# Validatie
test -r "$ETC_DIR/patchGD_guard.conf" || fail 20 "installed config unreadable"
test -r "$ETC_DIR/approval_public.pem" || fail 20 "installed approval key unreadable"
test -r "$ETC_DIR/oracle_home_rebuild.md" || fail 20 "installed recovery procedure unreadable"
test -d "$RUN_ROOT" || fail 20 "run root missing"
test -d "$LOCK_ROOT" || fail 20 "lock root missing"

echo "OPG_PREPARE_RESULT|host=$(hostname -f)|status=READY|exit_code=0"
exit 0
