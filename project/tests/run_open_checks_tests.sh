#!/usr/bin/env bash
# Gerichte tests van de concrete recovery- en windowchecks; geen Oracle-acties.
set -uo pipefail
umask 077
ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/opg-open-checks.XXXXXX") || exit 1
trap 'rm -rf -- "$TMP_BASE"' EXIT
PASS=0 FAIL=0
expect_rc() { local name=$1 expected=$2; shift 2; "$@" >"$TMP_BASE/last.out" 2>&1; local actual=$?; if (( actual == expected )); then printf 'ok - %s (rc=%s)\n' "$name" "$actual"; PASS=$((PASS+1)); else printf 'not ok - %s (verwacht=%s actueel=%s)\n' "$name" "$expected" "$actual"; cat "$TMP_BASE/last.out"; FAIL=$((FAIL+1)); fi; }

HOME_DIR="$TMP_BASE/oracle/base/product/19/dbhome_1"; ORACLE_BASE="$TMP_BASE/oracle/base"; RUN_DIR="$TMP_BASE/run"
PATCH_ROOT="$TMP_BASE/patches"; OPATCH_ROOT="$PATCH_ROOT/opatch"; SQL_FIX="$TMP_BASE/sql"
mkdir -p "$HOME_DIR/bin" "$HOME_DIR/dbs" "$HOME_DIR/network/admin" "$HOME_DIR/inventory/ContentsXML" "$ORACLE_BASE/oraInventory/ContentsXML" "$RUN_DIR" "$PATCH_ROOT/JUL2026/39472050" "$PATCH_ROOT/JUL2026/39222882" "$OPATCH_ROOT" "$SQL_FIX"
printf '<HOME/>\n' >"$HOME_DIR/inventory/ContentsXML/oraclehomeproperties.xml"; printf '<INVENTORY/>\n' >"$ORACLE_BASE/oraInventory/ContentsXML/inventory.xml"
printf 'NAMES.DIRECTORY_PATH=(TNSNAMES)\n' >"$HOME_DIR/network/admin/sqlnet.ora"; printf 'spfile\n' >"$HOME_DIR/dbs/spfileDB1.ora"; printf 'password\n' >"$HOME_DIR/dbs/orapwDB1"
printf 'db ru\n' >"$PATCH_ROOT/JUL2026/39472050/payload"; printf 'ojvm\n' >"$PATCH_ROOT/JUL2026/39222882/payload"
BASE_IMAGE="$TMP_BASE/LINUX.X64_193000_db_home.zip"; OPATCH_ZIP="$OPATCH_ROOT/p6880880_190000_Linux-x86-64.zip"
printf 'base image\n' >"$BASE_IMAGE"; printf 'opatch zip\n' >"$OPATCH_ZIP"
PROCEDURE="$TMP_BASE/oracle_home_rebuild.md"; printf 'Approved rebuild procedure\n' >"$PROCEDURE"; chmod 0640 "$PROCEDURE"
ORATAB="$TMP_BASE/oratab"; printf 'DB1:%s:Y\n' "$HOME_DIR" >"$ORATAB"; ORAINST="$TMP_BASE/oraInst.loc"; printf 'inventory_loc=%s\n' "$ORACLE_BASE/oraInventory" >"$ORAINST"
cat >"$SQL_FIX/DB1.txt" <<EOF
SPFILE|$HOME_DIR/dbs/spfileDB1.ora
DBPROP|DB1|DB1|PRIMARY|READ WRITE|YES
SERVICES|DB1_APP
EOF
BACKUP="$TMP_BASE/check_backup"; printf '#!/usr/bin/env bash\necho RESULT=READY\nexit 0\n' >"$BACKUP"; chmod +x "$BACKUP"

export OPG_TEST_MODE=1 TARGET_ORACLE_HOME="$HOME_DIR" RUN_DIR RUN_ID=REC1 HOST_NAME=pilot.example
RECOVERY_BASE_IMAGE_SHA256=$(sha256sum "$BASE_IMAGE" | awk '{print $1}')
OPATCH_ZIP_SHA256=$(sha256sum "$OPATCH_ZIP" | awk '{print $1}')
export RECOVERY_BASE_IMAGE="$BASE_IMAGE" RECOVERY_BASE_IMAGE_SHA256
export OPATCH_ROOT OPATCH_ZIPFILE=p6880880_190000_Linux-x86-64.zip OPATCH_ZIP_SHA256 OPATCH_VERSION=12.2.0.1.52 RECOVERY_OPATCH_ZIP_VERSION_OVERRIDE=12.2.0.1.52
export PATCH_ROOT MONTH=JUL2026 DB_PATCH=39472050 OJVM_PATCH=39222882 ORATAB_FILE="$ORATAB" ORAINST_LOC="$ORAINST"
export ORACLE_BASE_OVERRIDE="$ORACLE_BASE" RECOVERY_SQL_FIXTURE_DIR="$SQL_FIX" RECOVERY_TEST_RUNNING=true BACKUP_CHECK_COMMAND="$BACKUP" HOME_RECOVERY_PROCEDURE="$PROCEDURE" HOME_REBUILD_MIN_FREE_MB=0 RECOVERY_MANIFEST_FILE="$RUN_DIR/recovery_manifest.json"

expect_rc 'geldige base image en volledige rebuild-route' 0 bash "$ROOT/checks/check_oracle_home_recovery"
first_manifest_hash=$(sha256sum "$RECOVERY_MANIFEST_FILE" | awk '{print $1}')
export RECOVERY_MANIFEST_FILE="$RUN_DIR/preapply_recovery_manifest.json"
expect_rc 'ongewijzigde rebuild-route is bij pre-apply identiek' 0 bash "$ROOT/checks/check_oracle_home_recovery"
second_manifest_hash=$(sha256sum "$RECOVERY_MANIFEST_FILE" | awk '{print $1}')
if [[ "$first_manifest_hash" == "$second_manifest_hash" ]]; then printf 'ok - recovery-identiteit is deterministisch\n'; PASS=$((PASS+1)); else printf 'not ok - recovery-identiteit wijzigde zonder inputwijziging\n'; FAIL=$((FAIL+1)); fi

# Pilot05f: voer de echte RMAN-checkfuncties uit met gecontroleerde binaries.
SBT_LIBRARY="$TMP_BASE/libddobk.so"; printf 'fixture library\n' >"$SBT_LIBRARY"
cat >"$HOME_DIR/bin/rman" <<'EOF'
#!/usr/bin/env bash
case "${RMAN_FIXTURE_MODE:-valid}" in
  wrong_library) library=/wrong/libddobk.so; host=$EXPECTED_BACKUP_HOST; storage=$EXPECTED_STORAGE_UNIT ;;
  wrong_host) library=$EXPECTED_SBT_LIBRARY; host=wrong.example; storage=$EXPECTED_STORAGE_UNIT ;;
  wrong_storage) library=$EXPECTED_SBT_LIBRARY; host=$EXPECTED_BACKUP_HOST; storage=/wrong-unit ;;
  *) library=$EXPECTED_SBT_LIBRARY; host=$EXPECTED_BACKUP_HOST; storage=$EXPECTED_STORAGE_UNIT ;;
esac
printf "CONFIGURE CHANNEL DEVICE TYPE 'SBT_TAPE' PARMS 'SBT_LIBRARY=%s, ENV=(STORAGE_UNIT=%s, BACKUP_HOST=%s)';\n" "$library" "$storage" "$host"
case "${RMAN_FIXTURE_MODE:-valid}" in
  large) head -c 1048576 /dev/zero | tr '\0' X; printf '\n' ;;
  error_stdout) printf 'RMAN-03002: failure of show command\n' ;;
  error_stderr) printf 'ORA-19511: media management software error\n' >&2 ;;
esac
exit 0
EOF
cat >"$HOME_DIR/bin/sqlplus" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' 'LEVEL0|2026-08-18 12:00:00|1.00' 'DATABASE_BACKUP|2026-08-18 12:00:00|1.00' 'ARCHIVELOG_BACKUP|2026-08-18 12:00:00|1.00' 'RECENT_SBT_PIECES|4'
exit 0
EOF
chmod +x "$HOME_DIR/bin/rman" "$HOME_DIR/bin/sqlplus"
RMAN_DRIVER="$TMP_BASE/check_rman_fixture"
cat >"$RMAN_DRIVER" <<'EOF'
#!/usr/bin/env bash
# Alleen functiedefinities laden; de productie-main begint bij de oratabcontrole.
source <(sed '/^if \[\[ ! -r "\$ORATAB_FILE" \]\]; then/,$d' "$PILOT05F_ROOT/checks/check_rman_backup")
check_rman_configuration DB1 "$TARGET_ORACLE_HOME" || true
check_backup_metadata DB1 "$TARGET_ORACLE_HOME" || true
if (( blocked_count > 0 )); then exit 2; fi
if (( unknown_count > 0 )); then exit 3; fi
printf 'RESULT=READY\n'
exit 0
EOF
chmod +x "$RMAN_DRIVER"
stub_backup=$BACKUP_CHECK_COMMAND
export PILOT05F_ROOT="$ROOT" EXPECTED_SBT_LIBRARY="$SBT_LIBRARY" EXPECTED_BACKUP_HOST=ddboost.example EXPECTED_STORAGE_UNIT=/oracle-backups
export BACKUP_CHECK_COMMAND="$RMAN_DRIVER" RMAN_FIXTURE_MODE=valid OPG_CHECK_PHASE=preapply
expect_rc 'geldige DD Boost-configuratie en backups zijn READY' 0 "$RMAN_DRIVER"
if grep -Fq "EXPECTED_SBT_LIBRARY=<$SBT_LIBRARY> length=${#SBT_LIBRARY}" "$TMP_BASE/last.out"; then printf 'ok - DD Boost-input is bytebewust diagnosticeerbaar\n'; PASS=$((PASS+1)); else printf 'not ok - DD Boost-inputdiagnostiek ontbreekt\n'; FAIL=$((FAIL+1)); fi
export RMAN_FIXTURE_MODE=wrong_library; expect_rc 'verkeerde SBT_LIBRARY is BLOCKED' 2 "$RMAN_DRIVER"
export RMAN_FIXTURE_MODE=wrong_host; expect_rc 'verkeerde BACKUP_HOST is BLOCKED' 2 "$RMAN_DRIVER"
export RMAN_FIXTURE_MODE=wrong_storage; expect_rc 'verkeerde STORAGE_UNIT is BLOCKED' 2 "$RMAN_DRIVER"
export RMAN_FIXTURE_MODE=large; expect_rc 'grote RMAN-output met vroege match blijft READY' 0 "$RMAN_DRIVER"
export RMAN_FIXTURE_MODE=error_stdout; expect_rc 'RMAN-error op stdout is UNKNOWN' 3 "$RMAN_DRIVER"
export RMAN_FIXTURE_MODE=error_stderr; expect_rc 'ORA-error op stderr is fail-closed UNKNOWN' 3 "$RMAN_DRIVER"
export RMAN_FIXTURE_MODE=valid
expect_rc 'PREAPPLY directe backupcheck is READY' 0 "$BACKUP_CHECK_COMMAND"
export RECOVERY_MANIFEST_FILE="$RUN_DIR/pilot05f_preapply_recovery_manifest.json"
expect_rc 'PREAPPLY geneste recoverycheck geeft met identieke input dezelfde uitkomst' 0 bash "$ROOT/checks/check_oracle_home_recovery"

export BACKUP_CHECK_COMMAND=$stub_backup OPG_CHECK_PHASE=preapply
good_base=$RECOVERY_BASE_IMAGE; export RECOVERY_BASE_IMAGE="$TMP_BASE/missing-base-image.zip"
expect_rc 'ontbrekende base image' 2 bash "$ROOT/checks/check_oracle_home_recovery"
export RECOVERY_BASE_IMAGE=$good_base RECOVERY_OPATCH_ZIP_VERSION_OVERRIDE=12.2.0.1.44
expect_rc 'verkeerde OPatch-versie in staged zip' 2 bash "$ROOT/checks/check_oracle_home_recovery"
export RECOVERY_OPATCH_ZIP_VERSION_OVERRIDE=12.2.0.1.52; good_procedure=$HOME_RECOVERY_PROCEDURE; export HOME_RECOVERY_PROCEDURE="$TMP_BASE/missing-procedure.md"
expect_rc 'ontbrekende herstelprocedure' 2 bash "$ROOT/checks/check_oracle_home_recovery"
export HOME_RECOVERY_PROCEDURE=$good_procedure
BACKUP_BLOCKED="$TMP_BASE/check_backup_blocked"; printf '#!/usr/bin/env bash\necho RESULT=BLOCKED\nexit 2\n' >"$BACKUP_BLOCKED"; chmod +x "$BACKUP_BLOCKED"; good_backup=$BACKUP_CHECK_COMMAND; export BACKUP_CHECK_COMMAND=$BACKUP_BLOCKED
expect_rc 'RMAN-check niet READY' 2 bash "$ROOT/checks/check_oracle_home_recovery"
export BACKUP_CHECK_COMMAND=$good_backup
good_checksum=$RECOVERY_BASE_IMAGE_SHA256; export RECOVERY_BASE_IMAGE_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
expect_rc 'ongeldige base-imagechecksum' 2 bash "$ROOT/checks/check_oracle_home_recovery"
export RECOVERY_BASE_IMAGE_SHA256=$good_checksum RECOVERY_SQL_FIXTURE_DIR="$TMP_BASE/missing-sql"
expect_rc 'onbetrouwbare database-recoveryquery' 3 bash "$ROOT/checks/check_oracle_home_recovery"

WINDOW="$TMP_BASE/maintenance_window.conf"; export MAINTENANCE_WINDOW_MANIFEST="$WINDOW" OPG_CHECK_PHASE=preapply OPG_NOW_EPOCH_OVERRIDE=1785931200 RUN_ID=REC1 HOST_NAME=pilot.example TARGET_ORACLE_HOME="$HOME_DIR"
cat >"$WINDOW" <<EOF
hostname=pilot.example
change_id=DEMO-2026-001
start=2026-08-05T10:00:00Z
end=2026-08-05T14:00:00Z
allowed_oracle_home=$HOME_DIR
run_id=REC1
min_remaining_minutes=30
EOF
chmod 0640 "$WINDOW"
expect_rc 'geldig actief onderhoudsvenster' 0 bash "$ROOT/checks/check_maintenance_window"
export OPG_NOW_EPOCH_OVERRIDE=1785942000
expect_rc 'verlopen onderhoudsvenster' 2 bash "$ROOT/checks/check_maintenance_window"
export OPG_NOW_EPOCH_OVERRIDE=1785937500
expect_rc 'onvoldoende resterende venstertijd' 2 bash "$ROOT/checks/check_maintenance_window"
export OPG_NOW_EPOCH_OVERRIDE=1785931200
sed -i 's/hostname=pilot.example/hostname=other.example/' "$WINDOW"
expect_rc 'verkeerde host in venster' 2 bash "$ROOT/checks/check_maintenance_window"
sed -i 's/hostname=other.example/hostname=pilot.example/' "$WINDOW"
chmod 0666 "$WINDOW"
if [[ $(stat -c '%a' "$WINDOW") == 666 ]]; then expect_rc 'onveilige venstermanifestrechten' 2 bash "$ROOT/checks/check_maintenance_window"
elif grep -Fq 'group/other-writable' "$ROOT/checks/check_maintenance_window"; then printf 'ok - onveilige venstermanifestrechten (statische regressie; NTFS emuleert mode niet)\n'; PASS=$((PASS+1)); else printf 'not ok - rechtencontrole ontbreekt\n'; FAIL=$((FAIL+1)); fi
chmod 0640 "$WINDOW"; WINDOW_REAL=$WINDOW; WINDOW_LINK="$TMP_BASE/maintenance_window.link"; ln -s "$WINDOW_REAL" "$WINDOW_LINK"; export MAINTENANCE_WINDOW_MANIFEST=$WINDOW_LINK
# De enkele quotes zoeken bewust naar de letterlijke broncodetekst "$manifest".
# shellcheck disable=SC2016
if [[ -L "$WINDOW_LINK" ]]; then expect_rc 'symlink als venstermanifest' 3 bash "$ROOT/checks/check_maintenance_window"
elif grep -Fq '! -L "$manifest"' "$ROOT/checks/check_maintenance_window"; then printf 'ok - symlink als venstermanifest (statische regressie; NTFS maakte geen symlink)\n'; PASS=$((PASS+1)); else printf 'not ok - symlinkcontrole ontbreekt\n'; FAIL=$((FAIL+1)); fi
export MAINTENANCE_WINDOW_MANIFEST=$WINDOW_REAL
sed -i "s|allowed_oracle_home=.*|allowed_oracle_home=$TMP_BASE|" "$WINDOW"
expect_rc 'verkeerde Oracle Home in venster' 2 bash "$ROOT/checks/check_maintenance_window"
sed -i "s|allowed_oracle_home=.*|allowed_oracle_home=$HOME_DIR|; s|start=.*|start=2026-99-99T10:00:00Z|" "$WINDOW"
expect_rc 'onbetrouwbare venstertijd' 3 bash "$ROOT/checks/check_maintenance_window"

printf '\nResultaat open checks: %s geslaagd, %s mislukt\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
