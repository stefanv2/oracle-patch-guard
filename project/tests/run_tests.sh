#!/usr/bin/env bash
# Reproduceerbare test-harness zonder echte Oracle-opdrachten.
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/opg-tests.XXXXXX") || exit 1
PASS=0 FAIL=0
TEST_APPROVAL_PRIVATE="$TMP_BASE/test-approval-private.pem"
TEST_APPROVAL_PUBLIC="$TMP_BASE/test-approval-public.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$TEST_APPROVAL_PRIVATE" >/dev/null 2>&1 || exit 1
openssl pkey -in "$TEST_APPROVAL_PRIVATE" -pubout -out "$TEST_APPROVAL_PUBLIC" >/dev/null 2>&1 || exit 1
if [[ ${OPG_KEEP_TEST_TMP:-0} == 1 ]]; then
  printf 'Tijdelijke testmap blijft bewaard: %s\n' "$TMP_BASE"
else
  trap 'rm -rf -- "$TMP_BASE"' EXIT
fi

record() {
  local name=$1 expected=$2 actual=$3 output_file=${4:-} last_line='' result_ok=true
  if [[ -n "$output_file" ]]; then
    last_line=$(tail -n 1 "$output_file" 2>/dev/null || true)
    [[ "$last_line" == OPG_RESULT\|*"|exit_code=${expected}" ]] || result_ok=false
  fi
  if [[ "$expected" == "$actual" && "$result_ok" == true ]]; then
    printf 'ok - %s (rc=%s, OPG_RESULT=ok)\n' "$name" "$actual"; PASS=$((PASS+1))
  else
    printf 'not ok - %s (verwacht=%s actueel=%s result=%s)\n' "$name" "$expected" "$actual" "${last_line:-ONTBREEKT}"; FAIL=$((FAIL+1))
  fi
}

assert_no_downtime_started() {
  local name=$1 run=$2
  if compgen -G "$RUN_ROOT/$run/shutdown_*.log" >/dev/null || compgen -G "$RUN_ROOT/$run/listener_stop_*.log" >/dev/null; then
    printf 'not ok - %s (shutdown/listenerstop is ten onrechte gestart)\n' "$name"; FAIL=$((FAIL+1))
  else
    printf 'ok - %s (geen downtime gestart)\n' "$name"; PASS=$((PASS+1))
  fi
}

setup_case() {
  local name=$1 fixture=${2:-healthy_single}
  CASE_DIR="${TMP_BASE}/${name}"; HOME_DIR="${CASE_DIR}/dbhome_1"; RUN_ROOT="${CASE_DIR}/runs"; LOCK_ROOT="${CASE_DIR}/locks"
  PATCH_ROOT="${CASE_DIR}/patches"; OPATCH_ROOT="${PATCH_ROOT}/opatch"; ORATAB="${CASE_DIR}/oratab"
  mkdir -p "$HOME_DIR/bin" "$HOME_DIR/OPatch" "$HOME_DIR/inventory/ContentsXML" "$CASE_DIR/central_inventory/ContentsXML" \
    "$PATCH_ROOT/JUL2026/39472050" "$PATCH_ROOT/JUL2026/39222882" "$OPATCH_ROOT" "$RUN_ROOT" "$LOCK_ROOT" "$CASE_DIR/tmp" "$CASE_DIR/fixture"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_DIR/bin/sqlplus"; chmod +x "$HOME_DIR/bin/sqlplus"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_DIR/OPatch/opatch"; chmod +x "$HOME_DIR/OPatch/opatch"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_DIR/OPatch/datapatch"; chmod +x "$HOME_DIR/OPatch/datapatch"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_DIR/bin/emctl"; chmod +x "$HOME_DIR/bin/emctl"
  printf '<HOME/>\n' >"$HOME_DIR/inventory/ContentsXML/oraclehomeproperties.xml"
  printf '<INVENTORY/>\n' >"$CASE_DIR/central_inventory/ContentsXML/inventory.xml"
  printf 'README DB RU\n' >"$PATCH_ROOT/JUL2026/39472050/README.txt"
  printf 'README OJVM\n' >"$PATCH_ROOT/JUL2026/39222882/README.txt"
  printf 'db payload\n' >"$PATCH_ROOT/JUL2026/39472050/payload.bin"
  printf 'ojvm payload\n' >"$PATCH_ROOT/JUL2026/39222882/payload.bin"
  printf 'opatch zip\n' >"$OPATCH_ROOT/p6880880_190000_Linux-x86-64.zip"
  printf 'DB1:%s:Y\n' "$HOME_DIR" >"$ORATAB"
  cp -- "$TEST_APPROVAL_PUBLIC" "$CASE_DIR/approval-public.pem"
  sed "s|__TARGET_HOME__|$HOME_DIR|g" "$ROOT/fixtures/$fixture/database_inventory.csv" >"$CASE_DIR/fixture/database_inventory.csv"
  CONFIG="${CASE_DIR}/opg.conf"
  cat >"$CONFIG" <<EOF
PATCH_ROOT=$PATCH_ROOT
OPATCH_ROOT=$OPATCH_ROOT
RUN_ROOT=$RUN_ROOT
LOCK_ROOT=$LOCK_ROOT
ORATAB_FILE=$ORATAB
ASSESSMENT_MAX_AGE_MINUTES=60
MIN_HOME_FREE_MB=0
MIN_INVENTORY_FREE_MB=0
MIN_STAGE_FREE_MB=0
MIN_TMP_FREE_MB=0
COMMAND_TIMEOUT_SECONDS=30
ROLLBACK_RETENTION_HOURS=0
SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EMCTL_PATH=$HOME_DIR/bin/emctl
APPROVAL_PUBLIC_KEY=$CASE_DIR/approval-public.pem
ALLOW_TEST_MODE=true
MOCK_CENTRAL_INVENTORY=$CASE_DIR/central_inventory
EOF
  FIXTURE_ENV="${CASE_DIR}/fixture.env"
  cat >"$FIXTURE_ENV" <<'EOF'
MOCK_OPATCH_VERSION=12.2.0.1.52
MOCK_CHECK_BACKUP=VERIFIED
MOCK_CHECK_ORACLE_HOME_RECOVERY=VERIFIED
MOCK_CHECK_DATAPUMP=NONE
MOCK_CHECK_DATAGUARD=HEALTHY
MOCK_CHECK_MAINTENANCE_WINDOW=OK
EOF
  export OPG_TEST_MODE=1 OPG_FIXTURE_FILE="$FIXTURE_ENV" OPG_FIXTURE_DIR="$CASE_DIR/fixture" TMPDIR="$CASE_DIR/tmp"
}

guard() { bash "$ROOT/patchGD_guard.sh" "$@" --config "$CONFIG"; }
enable_local_media() {
  local identity=1111111111111111111111111111111111111111111111111111111111111111 stage
  LOCAL_STAGE="$CASE_DIR/local-stage"; stage="$LOCAL_STAGE/ready/JUL2026/$identity"
  mkdir -p "$stage/media/JUL2026" "$stage/opatch"
  cp -a "$PATCH_ROOT/JUL2026/39472050" "$stage/media/JUL2026/"
  cp -a "$PATCH_ROOT/JUL2026/39222882" "$stage/media/JUL2026/"
  cp "$OPATCH_ROOT/p6880880_190000_Linux-x86-64.zip" "$stage/opatch/"
  LOCAL_MEDIA_HELPER="$CASE_DIR/opg_media_verify"
  cat >"$LOCAL_MEDIA_HELPER" <<EOF
#!/usr/bin/env bash
set -u
[[ \${1:-} == verify-active-stage && \${2:-} == JUL2026 ]] || exit 70
db_hash=\$(sha256sum "$stage/media/JUL2026/39472050/payload.bin" | awk '{print \$1}')
ojvm_hash=\$(sha256sum "$stage/media/JUL2026/39222882/payload.bin" | awk '{print \$1}')
zip_hash=\$(sha256sum "$stage/opatch/p6880880_190000_Linux-x86-64.zip" | awk '{print \$1}')
printf 'READY|JUL2026|$identity|$stage/media|$stage/opatch|$identity|2222222222222222222222222222222222222222222222222222222222222222|OPG_TREE_HASH_V2|%s|%s|%s\n' "\$db_hash" "\$ojvm_hash" "\$zip_hash"
EOF
  chmod 0755 "$LOCAL_MEDIA_HELPER"
  printf '\nLOCAL_MEDIA_MODE=required\nLOCAL_STAGE_ROOT=%s\n' "$LOCAL_STAGE" >>"$CONFIG"
  export OPG_TEST_LOCAL_STAGE_ROOT="$LOCAL_STAGE" OPG_TEST_MEDIA_STAGE_HELPER="$LOCAL_MEDIA_HELPER"
}
assess() {
  local run=$1
  guard assess --non-interactive --target-oracle-home "$HOME_DIR" --run-id "$run" 39472050 39222882 JUL2026 12.2.0.1.52 p6880880_190000_Linux-x86-64.zip >"$CASE_DIR/${run}.out" 2>&1
}
plan() {
  local run=$1
  guard plan --non-interactive --run-id "$run" >"$CASE_DIR/${run}.plan.out" 2>&1
}
approval() {
  local run=$1 expires=${2:-$(( $(date +%s) + 3600 ))} hash token manifest_signature approval_signature
  token="$RUN_ROOT/$run/approval.json"
  manifest_signature="$RUN_ROOT/$run/patch_manifest.sig"
  approval_signature="$RUN_ROOT/$run/approval.sig"
  hash=$(sha256sum "$RUN_ROOT/$run/patch_manifest.json" | awk '{print $1}')
  cat >"$token" <<EOF
{
  "approved": true,
  "manifest_sha256": "$hash",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "target_oracle_home": "$HOME_DIR",
  "expires_epoch": $expires,
  "accept_SHARED_HOME": "SHARED_HOME",
  "accept_PREEXISTING_INVALIDS": "PREEXISTING_INVALIDS",
  "accept_HOME_RECOVERY_REBUILD_VERIFIED": "HOME_RECOVERY_REBUILD_VERIFIED",
  "accept_OPATCH_SELF_UPGRADE": "OPATCH_SELF_UPGRADE",
  "manifest_signature_file": "$manifest_signature",
  "approval_signature_file": "$approval_signature"
}
EOF
  if [[ ${TEST_SIGN_APPROVAL:-0} == 1 ]]; then
    [[ -r "$CASE_DIR/approval-private.pem" ]] || cp -- "$TEST_APPROVAL_PRIVATE" "$CASE_DIR/approval-private.pem"
    openssl dgst -sha256 -sign "$CASE_DIR/approval-private.pem" -out "$manifest_signature" "$RUN_ROOT/$run/patch_manifest.json"
    openssl dgst -sha256 -sign "$CASE_DIR/approval-private.pem" -out "$approval_signature" "$token"
  fi
  printf '%s' "$token"
}

force_partial_start_state() {
  local run=$1 sid=${2:-DB1}
  sed -i 's/"state": "03_PLAN_GENERATED"/"state": "PARTIAL"/; s/"phase": "PLAN"/"phase": "START_DATABASES"/' "$RUN_ROOT/$run/execution_state.json"
  printf 'ORACLE instance started.\nDatabase mounted.\nDatabase opened.\n' >"$RUN_ROOT/$run/startup_${sid}.log"
  printf '%s|INFO|COMMAND_END|label=startup_%s|started=x|finished=x|exit_code=0|output=%s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$sid" "$RUN_ROOT/$run/startup_${sid}.log" >>"$RUN_ROOT/$run/commands.log"
  printf '\nMOCK_RESUME_INVENTORY=BOTH\n' >>"$FIXTURE_ENV"
}

mock_datapatch_sqlpatch_rows() {
  printf "\nMOCK_DATAPATCH_SQLPATCH_ROWS='%s'\n" "$1" >>"$FIXTURE_ENV"
}

# 1. Gezonde single-instance database.
setup_case healthy; assess R1; record 'gezonde single-instance met geaccepteerde rebuild-route' 10 $? "$CASE_DIR/R1.out"
[[ ${OPG_STOP_AFTER_FIRST:-0} == 1 ]] && { printf '\nResultaat: %s geslaagd, %s mislukt\n' "$PASS" "$FAIL"; (( FAIL == 0 )); exit $?; }

# 2. Meerdere databases in dezelfde home -> afzonderlijke CONDITIONAL.
setup_case multi multiple_databases; printf 'DB1:%s:Y\nDB2:%s:Y\n' "$HOME_DIR" "$HOME_DIR" >"$ORATAB"; assess R2; record 'meerdere databases zelfde home' 10 $? "$CASE_DIR/R2.out"

# 3. Entry uit andere home wordt niet geselecteerd.
setup_case otherhome; mkdir -p "$CASE_DIR/other"; printf 'DB1:%s:Y\nOTHER:%s:Y\n' "$HOME_DIR" "$CASE_DIR/other" >"$ORATAB"; assess R3; record 'oratab andere home uitgesloten' 10 $? "$CASE_DIR/R3.out"

# 4. ASM/Grid-entry blokkeert de generieke flow.
setup_case asm; printf 'DB1:%s:Y\n+ASM:/u01/app/grid:N\n' "$HOME_DIR" >"$ORATAB"; assess R4; record 'ASM/Grid gedetecteerd' 20 $? "$CASE_DIR/R4.out"

# 5. Oudere OPatch met geldig medium plant een goedgekeurde self-upgrade.
setup_case oldopatch; printf '\nMOCK_OPATCH_VERSION=12.2.0.1.44\n' >>"$FIXTURE_ENV"; assess R5; record 'oudere OPatch plant self-upgrade' 10 $? "$CASE_DIR/R5.out"

# 6. Mislukte DB-RU-conflictcontrole.
setup_case dbconflict; printf '\nMOCK_RC_conflict_db_ru=1\n' >>"$FIXTURE_ENV"; assess R6; record 'DB-RU conflict' 20 $? "$CASE_DIR/R6.out"

# 7. Mislukte OJVM-conflictcontrole.
setup_case ojvmconflict; printf '\nMOCK_RC_conflict_ojvm=1\n' >>"$FIXTURE_ENV"; assess R7; record 'OJVM conflict' 20 $? "$CASE_DIR/R7.out"

# 8. Actieve Data Pump.
setup_case datapump; printf '\nMOCK_CHECK_DATAPUMP=ACTIVE\n' >>"$FIXTURE_ENV"; assess R8; record 'actieve Data Pump' 20 $? "$CASE_DIR/R8.out"

# 9. Ongezonde/niet-ondersteunde Data Guard.
setup_case dg dataguard_unhealthy; printf 'DG1:%s:Y\n' "$HOME_DIR" >"$ORATAB"; assess R9; record 'Data Guard blokkeert' 20 $? "$CASE_DIR/R9.out"

# 10. Bestaande SQL-patchfout.
setup_case sqlpatch; printf '\nMOCK_SQLPATCH_ERROR=true\n' >>"$FIXTURE_ENV"; assess R10; record 'bestaande SQL-patchfout' 20 $? "$CASE_DIR/R10.out"

# 11. Afgebroken run na DB-RU binary apply.
setup_case partial; assess R11 >/dev/null; plan R11 >/dev/null; token=$(approval R11); printf '\nMOCK_RC_apply_ojvm=1\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R11 --approved-manifest "$RUN_ROOT/R11/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'afgebroken na DB-RU' 40 $? "$CASE_DIR/apply.out"
[[ ${OPG_STOP_AFTER_R11:-0} == 1 ]] && { printf 'R11-map: %s\n' "$CASE_DIR"; exit 0; }

# 12. Autostart N en vooraf gestopt blijft gestopt; er is geen datapatch-log.
setup_case autostartn autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; assess R12 >/dev/null; plan R12 >/dev/null; token=$(approval R12)
guard apply --non-interactive --run-id R12 --approved-manifest "$RUN_ROOT/R12/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; rc=$?; [[ ! -e "$RUN_ROOT/R12/datapatch_DBN.log" ]] || rc=99; record 'autostart N blijft gestopt' 0 "$rc" "$CASE_DIR/apply.out"

# 13. Datapatch slaagt voor DB1 en faalt voor DB2.
setup_case dp2 multiple_databases; printf 'DB1:%s:Y\nDB2:%s:Y\n' "$HOME_DIR" "$HOME_DIR" >"$ORATAB"; assess R13 >/dev/null; plan R13 >/dev/null; token=$(approval R13); printf '\nMOCK_RC_datapatch_DB2=1\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R13 --approved-manifest "$RUN_ROOT/R13/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'datapatch per database fout' 40 $? "$CASE_DIR/apply.out"

# 14. Gewijzigde omgeving vóór resume.
setup_case resumechange; assess R14 >/dev/null; plan R14 >/dev/null; token=$(approval R14); printf '\nMOCK_RC_apply_ojvm=1\n' >>"$FIXTURE_ENV"; guard apply --non-interactive --run-id R14 --approved-manifest "$RUN_ROOT/R14/patch_manifest.json" --approval-token "$token" >/dev/null 2>&1 || true
printf '\nMOCK_ENVIRONMENT_CHANGED=true\n' >>"$FIXTURE_ENV"; guard resume --non-interactive --run-id R14 >"$CASE_DIR/resume.out" 2>&1; record 'gewijzigde omgeving voor resume' 50 $? "$CASE_DIR/resume.out"

# 15. Twee jobs voor dezelfde home: een bezette lock blokkeert apply.
setup_case lock; assess R15 >/dev/null; plan R15 >/dev/null; token=$(approval R15); printf '\nMOCK_LOCK_BUSY=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R15 --approved-manifest "$RUN_ROOT/R15/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'exclusieve home-lock' 60 $? "$CASE_DIR/apply.out"

# 16. OEM-time-outmarker plus actieve PID.
setup_case timeout; assess R16 >/dev/null; sleep 5 & sleeper=$!; sed -i "s/\"pid\": [0-9]*/\"pid\": $sleeper/" "$RUN_ROOT/R16/execution_state.json"; printf 'mock timeout\n' >"$RUN_ROOT/R16/oem_timeout.marker"
guard status --run-id R16 >"$CASE_DIR/status.out" 2>&1; rc=$?; grep -q 'PATCH_PROCESS_RUNNING' "$CASE_DIR/status.out" || rc=99; kill "$sleeper" 2>/dev/null || true; wait "$sleeper" 2>/dev/null || true; record 'OEM-time-out proces draait' 30 "$rc" "$CASE_DIR/status.out"

# 17. Ongeldig/verlopen approval-token.
setup_case expired; assess R17 >/dev/null; plan R17 >/dev/null; token=$(approval R17 1)
guard apply --non-interactive --run-id R17 --approved-manifest "$RUN_ROOT/R17/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'verlopen approval-token' 20 $? "$CASE_DIR/apply.out"

# 18. Patchchecksum gewijzigd tussen assessment en apply.
setup_case checksum; assess R18 >/dev/null; plan R18 >/dev/null; token=$(approval R18); printf 'changed\n' >>"$PATCH_ROOT/JUL2026/39472050/payload.bin"
guard apply --non-interactive --run-id R18 --approved-manifest "$RUN_ROOT/R18/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'gewijzigde patchchecksum' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'checksum blokkeert vóór downtime' R18

# 19. Actieve Data Pump ontstaat na assess maar vóór apply.
setup_case preapplydp; assess R19 >/dev/null; plan R19 >/dev/null; token=$(approval R19); printf '\nMOCK_PREAPPLY_DATAPUMP=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R19 --approved-manifest "$RUN_ROOT/R19/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'pre-apply Data Pump hercontrole' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'Data Pump blokkeert vóór downtime' R19

# 20. Back-upvalidatie vervalt na assessment.
setup_case preapplybackup; assess R20 >/dev/null; plan R20 >/dev/null; token=$(approval R20); printf '\nMOCK_CHECK_BACKUP=BLOCKED\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R20 --approved-manifest "$RUN_ROOT/R20/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'pre-apply back-uphercontrole' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'back-up blokkeert vóór downtime' R20

# 21. Vrije ruimte wordt vlak vóór apply onvoldoende.
setup_case preapplyspace; assess R21 >/dev/null; plan R21 >/dev/null; token=$(approval R21); printf '\nMOCK_PREAPPLY_SPACE_LOW=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R21 --approved-manifest "$RUN_ROOT/R21/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'pre-apply vrije-ruimtecontrole' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'ruimte blokkeert vóór downtime' R21

# 22. OJVM-conflict ontstaat pas na assessment.
setup_case preapplyconflict; assess R22 >/dev/null; plan R22 >/dev/null; token=$(approval R22); printf '\nMOCK_RC_conflict_ojvm=1\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R22 --approved-manifest "$RUN_ROOT/R22/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'pre-apply OJVM-conflictcontrole' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'conflict blokkeert vóór downtime' R22

# 23. Een niet-nul SQLPlus-exitcode mag niet als succes verdwijnen.
setup_case sqlplusexit; assess R23 >/dev/null; plan R23 >/dev/null; token=$(approval R23); printf '\nMOCK_RC_validation_DB1=7\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R23 --approved-manifest "$RUN_ROOT/R23/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'SQLPlus-exitcode blijft behouden' 50 $? "$CASE_DIR/apply.out"

# 24. Semantisch foutieve SQL-patchregistratie blokkeert COMPLETE.
setup_case sqlpatchvalidation; assess R24 >/dev/null; plan R24 >/dev/null; token=$(approval R24); printf '\nMOCK_VALIDATION_SQLPATCH_BAD=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R24 --approved-manifest "$RUN_ROOT/R24/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'SQL-patchregistratie inhoudelijk fout' 50 $? "$CASE_DIR/apply.out"

# 25-26. De echte asymmetrische verificatietak accepteert geldig materiaal en weigert een gewijzigd token.
setup_case signedvalid autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; assess R25 >/dev/null; plan R25 >/dev/null; TEST_SIGN_APPROVAL=1; token=$(approval R25); unset TEST_SIGN_APPROVAL; printf '\nTEST_REQUIRE_SIGNATURES=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R25 --approved-manifest "$RUN_ROOT/R25/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'asymmetrisch ondertekende approval geldig' 0 $? "$CASE_DIR/apply.out"

setup_case signedtamper; assess R26 >/dev/null; plan R26 >/dev/null; TEST_SIGN_APPROVAL=1; token=$(approval R26); unset TEST_SIGN_APPROVAL; printf '\nTEST_REQUIRE_SIGNATURES=true\n' >>"$FIXTURE_ENV"; sed -i 's/"approved": true/"approved": false/' "$token"
guard apply --non-interactive --run-id R26 --approved-manifest "$RUN_ROOT/R26/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'gewijzigd ondertekend approval-token' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'approval blokkeert vóór downtime' R26

# 27. Veilige resume na een DB-RU-applyfout die in inventory toch volledig aanwezig blijkt.
setup_case resumesafe; assess R27 >/dev/null; plan R27 >/dev/null; token=$(approval R27); printf '\nMOCK_RC_apply_db_ru=1\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R27 --approved-manifest "$RUN_ROOT/R27/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1 || true
guard resume --non-interactive --run-id R27 >"$CASE_DIR/resume.out" 2>&1; record 'fasegebonden veilige resume' 0 $? "$CASE_DIR/resume.out"

# 28. Een gemanipuleerd per-SID completion-marker blokkeert resume.
setup_case resumemarker multiple_databases; printf 'DB1:%s:Y\nDB2:%s:Y\n' "$HOME_DIR" "$HOME_DIR" >"$ORATAB"; assess R28 >/dev/null; plan R28 >/dev/null; token=$(approval R28); printf '\nMOCK_RC_datapatch_DB2=1\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R28 --approved-manifest "$RUN_ROOT/R28/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1 || true
sed -i '/^run_id=/d' "$RUN_ROOT/R28/datapatch_DB1.complete"
guard resume --non-interactive --run-id R28 >"$CASE_DIR/resume.out" 2>&1; record 'ongeldig completion-marker blokkeert resume' 50 $? "$CASE_DIR/resume.out"

# 29-33. Fail-closed resultaten voor de drie nieuw ingevulde controles.
setup_case recoveryblocked; printf '\nMOCK_CHECK_ORACLE_HOME_RECOVERY=BLOCKED\n' >>"$FIXTURE_ENV"; assess R29; record 'ongeldige rebuild-route blokkeert' 20 $? "$CASE_DIR/R29.out"
setup_case recoveryunknown; printf '\nMOCK_CHECK_ORACLE_HOME_RECOVERY=UNKNOWN\n' >>"$FIXTURE_ENV"; assess R30; record 'onbetrouwbare rebuild-controle is UNKNOWN' 30 $? "$CASE_DIR/R30.out"
setup_case datapumpunknown; printf '\nMOCK_CHECK_DATAPUMP=UNKNOWN\n' >>"$FIXTURE_ENV"; assess R31; record 'onbetrouwbare Data Pump-query is UNKNOWN' 30 $? "$CASE_DIR/R31.out"
setup_case windowblocked; printf '\nMOCK_CHECK_MAINTENANCE_WINDOW=BLOCKED\n' >>"$FIXTURE_ENV"; assess R32; record 'ongeldig onderhoudsvenster blokkeert' 20 $? "$CASE_DIR/R32.out"
setup_case windowunknown; printf '\nMOCK_CHECK_MAINTENANCE_WINDOW=UNKNOWN\n' >>"$FIXTURE_ENV"; assess R33; record 'onbetrouwbaar onderhoudsvenster is UNKNOWN' 30 $? "$CASE_DIR/R33.out"

# 34-35. Regressies: RAC OPTION OFF is geen componentfout en alleen de laatste
# status per patch_id+action telt in DBA_REGISTRY_SQLPATCH.
setup_case sqlregression; assess R34 >/dev/null
# De enkele quotes zoeken bewust naar de letterlijke SQL-tekst v$option.
# shellcheck disable=SC2016
if grep -Fq "status in ('INVALID','LOADING','UPGRADING','DOWNGRADING','REMOVING')" "$RUN_ROOT/R34/inventory.sql" && ! grep -Fq 'v$option' "$RUN_ROOT/R34/inventory.sql"; then record 'RAC OPTION OFF is geen componentfout' 0 0; else record 'RAC OPTION OFF is geen componentfout' 0 1; fi
if grep -Fq 'partition by patch_id, action order by action_time desc' "$RUN_ROOT/R34/inventory.sql"; then record 'historische WITH ERRORS gevolgd door SUCCESS blokkeert niet' 0 0; else record 'historische WITH ERRORS gevolgd door SUCCESS blokkeert niet' 0 1; fi

# 36. Dry-run onderdrukt de read-only assessmentcontroles niet.
setup_case dryrunassess
guard assess --dry-run --non-interactive --target-oracle-home "$HOME_DIR" --run-id R36 39472050 39222882 JUL2026 12.2.0.1.52 p6880880_190000_Linux-x86-64.zip >"$CASE_DIR/R36.out" 2>&1
rc=$?; grep -q 'MOCK label=opatch_lsinventory_before' "$RUN_ROOT/R36/inventory_before.txt" || rc=99
record 'dry-run voert read-only assessment werkelijk uit' 10 "$rc" "$CASE_DIR/R36.out"

# 37. Apply-dry-run stopt vóór iedere downtime- of patchmutatie.
setup_case dryrunapply; assess R37 >/dev/null; plan R37 >/dev/null; token=$(approval R37)
guard apply --dry-run --non-interactive --run-id R37 --approved-manifest "$RUN_ROOT/R37/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -q '"state": "03_PLAN_GENERATED"' "$RUN_ROOT/R37/execution_state.json" || rc=99
record 'apply dry-run respecteert mutatiegrens' 0 "$rc" "$CASE_DIR/apply.out"; assert_no_downtime_started 'apply dry-run veroorzaakt geen downtime' R37

# 38-41. Startup vereist rc=0, alleen ORA-32004, juiste PMON en een verse OPEN-status.
setup_case startupclean; assess R38 >/dev/null; plan R38 >/dev/null; token=$(approval R38)
guard apply --non-interactive --run-id R38 --approved-manifest "$RUN_ROOT/R38/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'startup zonder waarschuwingen' 0 $? "$CASE_DIR/apply.out"

setup_case startupwarning; assess R39 >/dev/null; plan R39 >/dev/null; token=$(approval R39); printf '\nMOCK_STARTUP_ORA32004=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R39 --approved-manifest "$RUN_ROOT/R39/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'startup met uitsluitend ORA-32004' 0 $? "$CASE_DIR/apply.out"

setup_case startuperror; assess R40 >/dev/null; plan R40 >/dev/null; token=$(approval R40); printf "\nMOCK_STARTUP_ERROR='ORA-01034: ORACLE not available'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R40 --approved-manifest "$RUN_ROOT/R40/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'echte ORA-startupfout blijft fataal' 40 $? "$CASE_DIR/apply.out"

setup_case startupnotopen; assess R41 >/dev/null; plan R41 >/dev/null; token=$(approval R41); printf '\nMOCK_STARTUP_OPEN_MODE=MOUNTED\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R41 --approved-manifest "$RUN_ROOT/R41/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'rc nul maar database niet OPEN' 40 $? "$CASE_DIR/apply.out"

setup_case startuppmon; assess R42 >/dev/null; plan R42 >/dev/null; token=$(approval R42); printf '\nMOCK_STARTUP_PMON_PRESENT=false\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R42 --approved-manifest "$RUN_ROOT/R42/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'ontbrekende PMON blokkeert startup' 40 $? "$CASE_DIR/apply.out"

# 43-45. Resume reconstrueert alleen aantoonbare database/listenerprogressie.
setup_case resumestarted; assess R43 >/dev/null; plan R43 >/dev/null; token=$(approval R43); force_partial_start_state R43
guard resume --non-interactive --run-id R43 >"$CASE_DIR/resume.out" 2>&1
rc=$?; grep -q '^run_id=R43$' "$RUN_ROOT/R43/startup_DB1.complete" || rc=99; ! grep -q 'label=apply_db_ru\|label=apply_ojvm' "$RUN_ROOT/R43/commands.log" || rc=98
record 'PARTIAL START resume met reeds aanwezige binaries' 0 "$rc" "$CASE_DIR/resume.out"

setup_case resumelistenerwrong; printf '\nLISTENER_READY_TIMEOUT_SECONDS=1\nLISTENER_POLL_SECONDS=1\n' >>"$CONFIG"; assess R44 >/dev/null; plan R44 >/dev/null; token=$(approval R44); force_partial_start_state R44; printf '\nMOCK_LISTENER_WRONG_HOME=true\n' >>"$FIXTURE_ENV"
guard resume --non-interactive --run-id R44 >"$CASE_DIR/resume.out" 2>&1; record 'listener uit verkeerde home blokkeert resume' 50 $? "$CASE_DIR/resume.out"

setup_case resumelistenernotready; printf '\nLISTENER_READY_TIMEOUT_SECONDS=1\nLISTENER_POLL_SECONDS=1\n' >>"$CONFIG"; assess R45 >/dev/null; plan R45 >/dev/null; token=$(approval R45); force_partial_start_state R45; printf '\nMOCK_LISTENER_SERVICES_READY=false\n' >>"$FIXTURE_ENV"
guard resume --non-interactive --run-id R45 >"$CASE_DIR/resume.out" 2>&1; record 'listener zonder READY-services blokkeert resume' 50 $? "$CASE_DIR/resume.out"

# 46-47. Fasecontext blijft strikt; checksumwerk is zichtbaar en begrensd.
setup_case resumecontext; assess R46 >/dev/null; plan R46 >/dev/null; token=$(approval R46); force_partial_start_state R46; printf 'changed\n' >>"$PATCH_ROOT/JUL2026/39472050/payload.bin"
guard resume --non-interactive --run-id R46 >"$CASE_DIR/resume.out" 2>&1; rc=$?; grep -q 'STATIC_CONTEXT_MISMATCH|check=db_patch_tree_sha256' "$RUN_ROOT/R46/commands.log" || rc=99; record 'gewijzigde fasecontext blokkeert resume diagnostisch' 50 "$rc" "$CASE_DIR/resume.out"

setup_case integritylog; assess R47 >/dev/null; rc=$?; grep -q 'INTEGRITY_CHECK_START' "$RUN_ROOT/R47/commands.log" && grep -q 'INTEGRITY_CHECK_END.*status=OK' "$RUN_ROOT/R47/commands.log" || rc=99; record 'checksum start/eindlogging' 10 "$rc" "$CASE_DIR/R47.out"

setup_case integritytimeout; printf '\nINTEGRITY_CHECK_TIMEOUT_SECONDS=1\n' >>"$CONFIG"; printf '\nMOCK_TREE_HASH_DELAY_SECONDS=2\n' >>"$FIXTURE_ENV"; assess R48
rc=$?; grep -q 'INTEGRITY_CHECK_END.*status=TIMEOUT' "$RUN_ROOT/R48/commands.log" || rc=99; record 'checksumtimeout faalt gesloten' 30 "$rc" "$CASE_DIR/R48.out"

# 49-51. Expliciete home- en dry-runregressies plus de begrensde stop-wachtlus.
setup_case startupwronghome; assess R49 >/dev/null; plan R49 >/dev/null; token=$(approval R49); printf '\nMOCK_STARTUP_PMON_WRONG_HOME=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R49 --approved-manifest "$RUN_ROOT/R49/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'PMON uit verkeerde home blokkeert startup' 40 $? "$CASE_DIR/apply.out"

setup_case resumedryrun; assess R50 >/dev/null; plan R50 >/dev/null; token=$(approval R50); force_partial_start_state R50; state_hash_before=$(sha256sum "$RUN_ROOT/R50/execution_state.json" | awk '{print $1}')
guard resume --dry-run --non-interactive --run-id R50 >"$CASE_DIR/resume.out" 2>&1
rc=$?; state_hash_after=$(sha256sum "$RUN_ROOT/R50/execution_state.json" | awk '{print $1}'); [[ "$state_hash_before" == "$state_hash_after" && ! -e "$RUN_ROOT/R50/startup_DB1.complete" ]] || rc=99
record 'resume dry-run wijzigt state en markers niet' 0 "$rc" "$CASE_DIR/resume.out"

# De enkele quotes zoeken bewust naar de letterlijke broncodetekst "$listener".
# shellcheck disable=SC2016
if grep -Fq 'wait_for_listener_stopped "$listener"' "$ROOT/patchGD_guard.sh" && grep -Fq 'LISTENER_STOP_WAIT_END' "$ROOT/patchGD_guard.sh"; then record 'listenerstop gebruikt begrensde geobserveerde wachtlus' 0 0; else record 'listenerstop gebruikt begrensde geobserveerde wachtlus' 0 1; fi

# 52-57. De approval-public-key is vanaf ASSESS een immutable trust-anchor.
setup_case trustmanifest; assess R52 >/dev/null
expected_key_hash=$(sha256sum "$CASE_DIR/approval-public.pem" | awk '{print $1}')
grep -Fq '"approval_public_key_sha256": "'"$expected_key_hash"'"' "$RUN_ROOT/R52/patch_manifest.json"
record 'approval-public-keyhash staat in immutable manifest' 0 $?
manifest_hash_before=$(sha256sum "$RUN_ROOT/R52/patch_manifest.json" | awk '{print $1}'); plan R52 >/dev/null; manifest_hash_after=$(sha256sum "$RUN_ROOT/R52/patch_manifest.json" | awk '{print $1}')
[[ "$manifest_hash_before" == "$manifest_hash_after" ]]; record 'PLAN verandert trust-anchor niet' 0 $?

setup_case trustsame autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; assess R53 >/dev/null; plan R53 >/dev/null; TEST_SIGN_APPROVAL=1; token=$(approval R53); unset TEST_SIGN_APPROVAL; printf '\nTEST_REQUIRE_SIGNATURES=true\n' >>"$FIXTURE_ENV"
guard apply --dry-run --non-interactive --run-id R53 --approved-manifest "$RUN_ROOT/R53/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
record 'ongewijzigde approval trust-anchor is PREAPPLY READY' 0 $? "$CASE_DIR/apply.out"

setup_case trustchanged autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; assess R54 >/dev/null; plan R54 >/dev/null
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$CASE_DIR/approval-private.pem" >/dev/null 2>&1
openssl pkey -in "$CASE_DIR/approval-private.pem" -pubout -out "$CASE_DIR/approval-public.pem" >/dev/null 2>&1
TEST_SIGN_APPROVAL=1; token=$(approval R54); unset TEST_SIGN_APPROVAL; printf '\nTEST_REQUIRE_SIGNATURES=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R54 --approved-manifest "$RUN_ROOT/R54/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fq 'APPROVAL_TRUST_CHANGED' "$RUN_ROOT/R54/preapply_findings.psv" || rc=99
record 'vervangen key met eigen geldige signatures blijft BLOCKED' 20 "$rc" "$CASE_DIR/apply.out"; assert_no_downtime_started 'trust-anchorwijziging blokkeert vóór downtime' R54

setup_case trustmissing; rm -f -- "$CASE_DIR/approval-public.pem"; assess R55
rc=$?; grep -Fq 'APPROVAL_TRUST_UNAVAILABLE' "$RUN_ROOT/R55/findings.psv" || rc=99; record 'ontbrekende public key blokkeert ASSESS' 20 "$rc" "$CASE_DIR/R55.out"

setup_case trustunreadable; chmod 000 "$CASE_DIR/approval-public.pem"
if [[ -r "$CASE_DIR/approval-public.pem" ]]; then
  # De enkele quotes zoeken bewust naar de letterlijke broncodetekst met variabelenaam.
  # shellcheck disable=SC2016
  grep -Fq '[[ -f "$APPROVAL_PUBLIC_KEY" && -r "$APPROVAL_PUBLIC_KEY" && ! -L "$APPROVAL_PUBLIC_KEY" ]]' "$ROOT/patchGD_guard.sh"; record 'onleesbare public key (statische regressie onder privileged testuser)' 0 $?
else
  assess R56; rc=$?; grep -Fq 'APPROVAL_TRUST_UNAVAILABLE' "$RUN_ROOT/R56/findings.psv" || rc=99; record 'onleesbare public key blokkeert ASSESS' 20 "$rc" "$CASE_DIR/R56.out"
fi

setup_case trustsymlink; key_real="$CASE_DIR/approval-public.real"; mv -- "$CASE_DIR/approval-public.pem" "$key_real"; ln -s "$key_real" "$CASE_DIR/approval-public.pem" 2>/dev/null || true
if [[ -L "$CASE_DIR/approval-public.pem" ]]; then
  assess R57; rc=$?; grep -Fq 'APPROVAL_TRUST_UNAVAILABLE' "$RUN_ROOT/R57/findings.psv" || rc=99; record 'symlink public key blokkeert ASSESS' 20 "$rc" "$CASE_DIR/R57.out"
else
  # De enkele quotes zoeken bewust naar de letterlijke broncodetekst met variabelenaam.
  # shellcheck disable=SC2016
  grep -Fq '! -L "$APPROVAL_PUBLIC_KEY"' "$ROOT/patchGD_guard.sh"; record 'symlink public key (statische regressie op filesystem zonder symlinks)' 0 $?
fi

# Pilot07: PLAN/APPLY gebruiken uitsluitend de manifestgebonden lokale stage.
setup_case localonly autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; enable_local_media; assess R58 >/dev/null; plan R58 >/dev/null; token=$(approval R58); mv "$PATCH_ROOT" "$CASE_DIR/remote.offline"
guard apply --non-interactive --run-id R58 --approved-manifest "$RUN_ROOT/R58/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fq '"media_mode": "LOCAL_IMMUTABLE_V2"' "$RUN_ROOT/R58/patch_manifest.json" || rc=99; record 'Pilot07 apply gebruikt lokale immutable media zonder share-fallback' 0 "$rc" "$CASE_DIR/apply.out"

setup_case localtamper autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; enable_local_media; assess R59 >/dev/null; plan R59 >/dev/null; token=$(approval R59); printf tamper >>"$LOCAL_STAGE/ready/JUL2026/1111111111111111111111111111111111111111111111111111111111111111/media/JUL2026/39472050/payload.bin"
guard apply --non-interactive --run-id R59 --approved-manifest "$RUN_ROOT/R59/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'Pilot07 lokale mediamutatie blokkeert vóór downtime' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'lokale mediamutatie bereikt geen downtime' R59

setup_case localreplace autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; enable_local_media; assess R62 >/dev/null; plan R62 >/dev/null; token=$(approval R62); identity=1111111111111111111111111111111111111111111111111111111111111111
mv "$LOCAL_STAGE/ready/JUL2026/$identity" "$LOCAL_STAGE/ready/JUL2026/${identity}.original"; cp -a "$LOCAL_STAGE/ready/JUL2026/${identity}.original" "$LOCAL_STAGE/ready/JUL2026/$identity"; printf replacement-tamper >>"$LOCAL_STAGE/ready/JUL2026/$identity/media/JUL2026/39472050/payload.bin"
guard apply --non-interactive --run-id R62 --approved-manifest "$RUN_ROOT/R62/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'Pilot07 inhoudelijk vervangen stagepad blokkeert vóór downtime' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'vervangen stagepad bereikt geen downtime' R62

setup_case localresume autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; enable_local_media; assess R60 >/dev/null; plan R60 >/dev/null; token=$(approval R60); printf '\nMOCK_RC_apply_db_ru=1\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R60 --approved-manifest "$RUN_ROOT/R60/patch_manifest.json" --approval-token "$token" >/dev/null 2>&1 || true
mv "$PATCH_ROOT" "$CASE_DIR/remote.offline"; sed -i '/MOCK_RC_apply_db_ru=1/d' "$FIXTURE_ENV"
guard resume --non-interactive --run-id R60 >"$CASE_DIR/resume.out" 2>&1; rc=$?
record 'Pilot07 resume gebruikt dezelfde lokale stage zonder share' 0 "$rc" "$CASE_DIR/resume.out"

setup_case localkeychange autostart_n; printf 'DBN:%s:N\n' "$HOME_DIR" >"$ORATAB"; enable_local_media; assess R61 >/dev/null; plan R61 >/dev/null; token=$(approval R61); sed -i 's/2222222222222222222222222222222222222222222222222222222222222222/3333333333333333333333333333333333333333333333333333333333333333/' "$LOCAL_MEDIA_HELPER"
guard apply --non-interactive --run-id R61 --approved-manifest "$RUN_ROOT/R61/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'Pilot07 gewijzigde artifact-keyidentiteit blokkeert vóór downtime' 20 $? "$CASE_DIR/apply.out"; assert_no_downtime_started 'artifact-keywijziging bereikt geen downtime' R61

unset OPG_TEST_LOCAL_STAGE_ROOT OPG_TEST_MEDIA_STAGE_HELPER

# P0-contract: user-PDB's staan tijdens datapatch READ WRITE. Daarna wordt de
# oorspronkelijke state idempotent hersteld en opnieuw uit de database gelezen.
setup_case pdbalreadyrw; assess R63 >/dev/null; plan R63 >/dev/null; token=$(approval R63); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=READ WRITE'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R63 --approved-manifest "$RUN_ROOT/R63/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; ! grep -qi '^alter pluggable database' "$RUN_ROOT/R63/prepare_datapatch_pdb_DB1.sql" || rc=99; ! grep -qi '^alter pluggable database' "$RUN_ROOT/R63/restore_pdb_DB1.sql" || rc=98
record 'PDB reeds READ WRITE blijft UNCHANGED zonder ALTER' 0 "$rc" "$CASE_DIR/apply.out"

setup_case pdbmountedtorw; assess R64 >/dev/null; plan R64 >/dev/null; token=$(approval R64); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=MOUNTED'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R64 --approved-manifest "$RUN_ROOT/R64/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fqx 'alter pluggable database "PDB1" open read write;' "$RUN_ROOT/R64/prepare_datapatch_pdb_DB1.sql" || rc=99; ! grep -qi '^alter pluggable database' "$RUN_ROOT/R64/restore_pdb_DB1.sql" || rc=98
record 'PDB MOUNTED wordt vóór datapatch gericht READ WRITE' 0 "$rc" "$CASE_DIR/apply.out"

setup_case pdbalreadyro; sed -i 's/PDB1=READ WRITE/PDB1=READ ONLY/' "$CASE_DIR/fixture/database_inventory.csv"; assess R65 >/dev/null; plan R65 >/dev/null; token=$(approval R65); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=READ ONLY'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R65 --approved-manifest "$RUN_ROOT/R65/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fqx 'alter pluggable database "PDB1" open read write;' "$RUN_ROOT/R65/prepare_datapatch_pdb_DB1.sql" || rc=99; grep -Fqx 'alter pluggable database "PDB1" open read only;' "$RUN_ROOT/R65/restore_pdb_DB1.sql" || rc=98
record 'PDB READ ONLY wordt tijdelijk READ WRITE en daarna READ ONLY' 0 "$rc" "$CASE_DIR/apply.out"

setup_case pdbalreadymounted; sed -i 's/PDB1=READ WRITE/PDB1=MOUNTED/' "$CASE_DIR/fixture/database_inventory.csv"; assess R66 >/dev/null; plan R66 >/dev/null; token=$(approval R66); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=MOUNTED'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R66 --approved-manifest "$RUN_ROOT/R66/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fqx 'alter pluggable database "PDB1" open read write;' "$RUN_ROOT/R66/prepare_datapatch_pdb_DB1.sql" || rc=99; grep -Fqx 'alter pluggable database "PDB1" close immediate;' "$RUN_ROOT/R66/restore_pdb_DB1.sql" || rc=98
record 'PDB oorspronkelijk MOUNTED wordt na datapatch weer MOUNTED' 0 "$rc" "$CASE_DIR/apply.out"

setup_case pdbfinalmismatch; sed -i 's/PDB1=READ WRITE/PDB1=MOUNTED/' "$CASE_DIR/fixture/database_inventory.csv"; assess R67 >/dev/null; plan R67 >/dev/null; token=$(approval R67); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=MOUNTED'\nMOCK_PDB_RESTORE_FINAL_STATES='PDB1=READ WRITE'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R67 --approved-manifest "$RUN_ROOT/R67/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; [[ -e "$RUN_ROOT/R67/datapatch_DB1.log" ]] || rc=99; grep -Fq '"phase": "RESTORE_PDB"' "$RUN_ROOT/R67/execution_state.json" || rc=98
record 'afwijkende PDB-eindstate na datapatch faalt gesloten' 40 "$rc" "$CASE_DIR/apply.out"

setup_case pdbseed; assess R68 >/dev/null; plan R68 >/dev/null; token=$(approval R68); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=READ WRITE'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R68 --approved-manifest "$RUN_ROOT/R68/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fq 'where con_id > 2' "$RUN_ROOT/R68/pdb_state_DB1.sql" || rc=99; ! grep -Fq "PDB\$SEED" "$RUN_ROOT/R68/restore_pdb_DB1.sql" || rc=98
record "PDB\$SEED blijft buiten restore-mutaties" 0 "$rc" "$CASE_DIR/apply.out"

setup_case pdbmultiple; sed -i 's/PDB1=READ WRITE/PDB1=READ WRITE;PDB2=READ ONLY/' "$CASE_DIR/fixture/database_inventory.csv"; assess R69 >/dev/null; plan R69 >/dev/null; token=$(approval R69); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=MOUNTED;PDB2=READ ONLY'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R69 --approved-manifest "$RUN_ROOT/R69/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fqx 'alter pluggable database "PDB1" open read write;' "$RUN_ROOT/R69/prepare_datapatch_pdb_DB1.sql" || rc=99; grep -Fqx 'alter pluggable database "PDB2" open read write;' "$RUN_ROOT/R69/prepare_datapatch_pdb_DB1.sql" || rc=98; grep -Fqx 'alter pluggable database "PDB2" open read only;' "$RUN_ROOT/R69/restore_pdb_DB1.sql" || rc=97
record 'multiple PDBs tijdelijk READ WRITE en exact hersteld' 0 "$rc" "$CASE_DIR/apply.out"

setup_case pdbrace65019; sed -i 's/PDB1=READ WRITE/PDB1=MOUNTED/' "$CASE_DIR/fixture/database_inventory.csv"; assess R70 >/dev/null; plan R70 >/dev/null; token=$(approval R70); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=MOUNTED'\nMOCK_RC_restore_pdb_DB1=1\nMOCK_PDB_RESTORE_FINAL_STATES='PDB1=MOUNTED'\nMOCK_PDB_RESTORE_ERROR='ORA-65019: pluggable database PDB1 already open'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id R70 --approved-manifest "$RUN_ROOT/R70/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fq 'ORA-65019' "$RUN_ROOT/R70/restore_pdb_DB1.log" || rc=99; grep -Fq 'PDB_RESTORE_COMMAND_FAILED_BUT_FINAL_STATE_VERIFIED' "$RUN_ROOT/R70/commands.log" || rc=98
record 'ORA-65019 met exact correcte verse eindstate blijft idempotent' 0 "$rc" "$CASE_DIR/apply.out"

# P0: exacte expected-container x expected-patch cardinaliteit.
p0_ts=20260830120000000000
p0_root_ru="CDB_SQLPATCH|1|CDB\$ROOT|39472050|SUCCESS|${p0_ts}"
p0_root_ojvm="CDB_SQLPATCH|1|CDB\$ROOT|39222882|SUCCESS|${p0_ts}"
p0_pdb1_ru="CDB_SQLPATCH|3|PDB1|39472050|SUCCESS|${p0_ts}"
p0_pdb1_ojvm="CDB_SQLPATCH|3|PDB1|39222882|SUCCESS|${p0_ts}"

setup_case p0noncdb; sed -i 's/"YES","PDB1=READ WRITE"/"NO",""/' "$CASE_DIR/fixture/database_inventory.csv"; assess P0R1 >/dev/null; plan P0R1 >/dev/null; token=$(approval P0R1)
guard apply --non-interactive --run-id P0R1 --approved-manifest "$RUN_ROOT/P0R1/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
record 'P0 non-CDB behoudt geldige datapatch-flow' 0 $? "$CASE_DIR/apply.out"

setup_case p0rootonly; sed -i 's/"PDB1=READ WRITE"/""/' "$CASE_DIR/fixture/database_inventory.csv"; assess P0R2 >/dev/null; plan P0R2 >/dev/null; token=$(approval P0R2)
guard apply --non-interactive --run-id P0R2 --approved-manifest "$RUN_ROOT/P0R2/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fqx "1|CDB\$ROOT" "$RUN_ROOT/P0R2/datapatch_expected_containers_DB1.psv" || rc=99; record "P0 CDB met alleen CDB\$ROOT slaagt" 0 "$rc" "$CASE_DIR/apply.out"

setup_case p0multiopen; sed -i 's/PDB1=READ WRITE/PDB1=READ WRITE;PDB2=READ WRITE/' "$CASE_DIR/fixture/database_inventory.csv"; assess P0R3 >/dev/null; plan P0R3 >/dev/null; token=$(approval P0R3)
guard apply --non-interactive --run-id P0R3 --approved-manifest "$RUN_ROOT/P0R3/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; [[ $(grep -c '^CDB_SQLPATCH|' "$RUN_ROOT/P0R3/datapatch_sqlpatch_DB1.log") -eq 6 ]] || rc=99; record 'P0 meerdere OPEN PDBs hebben RU overal SUCCESS' 0 "$rc" "$CASE_DIR/apply.out"

setup_case p0ruojvm; assess P0R4 >/dev/null; plan P0R4 >/dev/null; token=$(approval P0R4)
guard apply --non-interactive --run-id P0R4 --approved-manifest "$RUN_ROOT/P0R4/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fq 'result=PASS|containers=2|patches=2' "$RUN_ROOT/P0R4/commands.log" || rc=99; record 'P0 RU en OJVM slagen voor iedere container' 0 "$rc" "$CASE_DIR/apply.out"

setup_case p0mounted; sed -i 's/PDB1=READ WRITE/PDB1=MOUNTED/' "$CASE_DIR/fixture/database_inventory.csv"; assess P0R5 >/dev/null; plan P0R5 >/dev/null; token=$(approval P0R5); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=MOUNTED'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id P0R5 --approved-manifest "$RUN_ROOT/P0R5/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fqx 'alter pluggable database "PDB1" open read write;' "$RUN_ROOT/P0R5/prepare_datapatch_pdb_DB1.sql" || rc=99; grep -Fqx 'alter pluggable database "PDB1" close immediate;' "$RUN_ROOT/P0R5/restore_pdb_DB1.sql" || rc=98; grep -Fqx 'PDB_STATE|PDB1|MOUNTED' "$RUN_ROOT/P0R5/pdb_state_after_DB1.log" || rc=97
record 'P0 oorspronkelijk MOUNTED wordt gepatcht en exact hersteld' 0 "$rc" "$CASE_DIR/apply.out"

setup_case p0missingru; assess P0R6 >/dev/null; plan P0R6 >/dev/null; token=$(approval P0R6); mock_datapatch_sqlpatch_rows "${p0_root_ru};${p0_root_ojvm};${p0_pdb1_ojvm}"
guard apply --non-interactive --run-id P0R6 --approved-manifest "$RUN_ROOT/P0R6/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'P0 ontbrekende RU voor één PDB faalt gesloten' 40 $? "$CASE_DIR/apply.out"

# Permanente reproductie van de oorspronkelijke false-PASS: root is volledig,
# maar de verwachte PDB mist OJVM. De oude generieke greps zouden beide patch-ID's zien.
setup_case p0originalfalsepass; assess P0R7 >/dev/null; plan P0R7 >/dev/null; token=$(approval P0R7); mock_datapatch_sqlpatch_rows "${p0_root_ru};${p0_root_ojvm};${p0_pdb1_ru}"
guard apply --non-interactive --run-id P0R7 --approved-manifest "$RUN_ROOT/P0R7/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -Fq 'container=PDB1|con_id=3|patch_type=OJVM|patch_id=39222882|status=MISSING' "$RUN_ROOT/P0R7/commands.log" || rc=99; record 'P0 oorspronkelijke false-PASS mist OJVM en faalt gesloten' 40 "$rc" "$CASE_DIR/apply.out"

setup_case p0missingpdb; assess P0R8 >/dev/null; plan P0R8 >/dev/null; token=$(approval P0R8); mock_datapatch_sqlpatch_rows "${p0_root_ru};${p0_root_ojvm}"
guard apply --non-interactive --run-id P0R8 --approved-manifest "$RUN_ROOT/P0R8/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'P0 volledig ontbrekende PDB faalt gesloten' 40 $? "$CASE_DIR/apply.out"

setup_case p0badstatus; assess P0R9 >/dev/null; plan P0R9 >/dev/null; token=$(approval P0R9); mock_datapatch_sqlpatch_rows "${p0_root_ru};${p0_root_ojvm};${p0_pdb1_ru};CDB_SQLPATCH|3|PDB1|39222882|WITH ERRORS|${p0_ts}"
guard apply --non-interactive --run-id P0R9 --approved-manifest "$RUN_ROOT/P0R9/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'P0 laatste status niet SUCCESS faalt gesloten' 40 $? "$CASE_DIR/apply.out"

setup_case p0duplicate; assess P0R10 >/dev/null; plan P0R10 >/dev/null; token=$(approval P0R10); mock_datapatch_sqlpatch_rows "${p0_root_ru};${p0_root_ojvm};${p0_pdb1_ru};${p0_pdb1_ojvm};${p0_pdb1_ojvm}"
guard apply --non-interactive --run-id P0R10 --approved-manifest "$RUN_ROOT/P0R10/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'P0 dubbele container-patchregistratie is ambigu en faalt' 40 $? "$CASE_DIR/apply.out"

setup_case p0badconid; assess P0R11 >/dev/null; plan P0R11 >/dev/null; token=$(approval P0R11); mock_datapatch_sqlpatch_rows "${p0_root_ru};${p0_root_ojvm};CDB_SQLPATCH|X|PDB1|39472050|SUCCESS|${p0_ts};${p0_pdb1_ojvm}"
guard apply --non-interactive --run-id P0R11 --approved-manifest "$RUN_ROOT/P0R11/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'P0 onparseerbare con_id faalt gesloten' 40 $? "$CASE_DIR/apply.out"

setup_case p0unknownset; assess P0R12 >/dev/null; plan P0R12 >/dev/null; token=$(approval P0R12); printf "\nMOCK_DATAPATCH_CONTAINER_ROWS='DATAPATCH_CONTAINER|1|CDB\$ROOT|READ WRITE'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id P0R12 --approved-manifest "$RUN_ROOT/P0R12/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'P0 onbetrouwbare verwachte containerset faalt gesloten' 40 $? "$CASE_DIR/apply.out"

setup_case p0openfail; sed -i 's/PDB1=READ WRITE/PDB1=MOUNTED/' "$CASE_DIR/fixture/database_inventory.csv"; assess P0R13 >/dev/null; plan P0R13 >/dev/null; token=$(approval P0R13); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=MOUNTED'\nMOCK_RC_prepare_datapatch_pdb_DB1=1\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id P0R13 --approved-manifest "$RUN_ROOT/P0R13/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'P0 noodzakelijke PDB kan niet worden geopend en faalt gesloten' 40 $? "$CASE_DIR/apply.out"

setup_case p0restorefail; sed -i 's/PDB1=READ WRITE/PDB1=MOUNTED/' "$CASE_DIR/fixture/database_inventory.csv"; assess P0R14 >/dev/null; plan P0R14 >/dev/null; token=$(approval P0R14); printf "\nMOCK_PDB_CURRENT_STATES='PDB1=MOUNTED'\nMOCK_PDB_RESTORE_FINAL_STATES='PDB1=READ WRITE'\n" >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id P0R14 --approved-manifest "$RUN_ROOT/P0R14/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1; record 'P0 oorspronkelijke PDB-state kan niet worden hersteld en faalt gesloten' 40 $? "$CASE_DIR/apply.out"

printf '\nResultaat: %s geslaagd, %s mislukt\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
