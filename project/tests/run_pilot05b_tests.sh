#!/usr/bin/env bash
# Gerichte regressies voor de vier bevindingen uit de echte pilot05b-run.
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/opg-pilot05b-tests.XXXXXX") || exit 1
PASS=0 FAIL=0
trap 'rm -rf -- "$TMP_BASE"' EXIT

record() {
  local name=$1 expected=$2 actual=$3 output_file=${4:-} last_line='' result_ok=true
  if [[ -n "$output_file" ]]; then
    last_line=$(tail -n 1 "$output_file" 2>/dev/null || true)
    [[ "$last_line" == OPG_RESULT\|*"|exit_code=${expected}" ]] || result_ok=false
  fi
  if [[ "$expected" == "$actual" && "$result_ok" == true ]]; then
    printf 'ok - %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf 'not ok - %s (verwacht=%s actueel=%s result=%s)\n' "$name" "$expected" "$actual" "${last_line:-ONTBREEKT}"
    FAIL=$((FAIL + 1))
  fi
}

setup_case() {
  local name=$1
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
  printf '%s\n' 'pilot05f test approval public key' >"$CASE_DIR/approval-public.pem"
  sed "s|__TARGET_HOME__|$HOME_DIR|g" "$ROOT/fixtures/healthy_single/database_inventory.csv" >"$CASE_DIR/fixture/database_inventory.csv"
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
OPATCH_UPGRADE_MIN_FREE_MB=0
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
MOCK_OPATCH_MEDIA=VALID
MOCK_CHECK_BACKUP=VERIFIED
MOCK_CHECK_ORACLE_HOME_RECOVERY=VERIFIED
MOCK_CHECK_DATAPUMP=NONE
MOCK_CHECK_DATAGUARD=HEALTHY
MOCK_CHECK_MAINTENANCE_WINDOW=OK
EOF
  export OPG_TEST_MODE=1 OPG_FIXTURE_FILE="$FIXTURE_ENV" OPG_FIXTURE_DIR="$CASE_DIR/fixture" TMPDIR="$CASE_DIR/tmp"
}

guard() { bash "$ROOT/patchGD_guard.sh" "$@" --config "$CONFIG"; }
assess() { guard assess --non-interactive --target-oracle-home "$HOME_DIR" --run-id "$1" 39472050 39222882 JUL2026 12.2.0.1.52 p6880880_190000_Linux-x86-64.zip >"$CASE_DIR/$1.assess.out" 2>&1; }
plan() { guard plan --non-interactive --run-id "$1" >"$CASE_DIR/$1.plan.out" 2>&1; }
approval() {
  local run=$1 token hash
  token="$RUN_ROOT/$run/approval.json"
  hash=$(sha256sum "$RUN_ROOT/$run/patch_manifest.json" | awk '{print $1}')
  cat >"$token" <<EOF
{
  "approved": true,
  "manifest_sha256": "$hash",
  "hostname": "$(hostname -f 2>/dev/null || hostname)",
  "target_oracle_home": "$HOME_DIR",
  "expires_epoch": $(( $(date +%s) + 3600 )),
  "accept_SHARED_HOME": "SHARED_HOME",
  "accept_PREEXISTING_INVALIDS": "PREEXISTING_INVALIDS",
  "accept_HOME_RECOVERY_REBUILD_VERIFIED": "HOME_RECOVERY_REBUILD_VERIFIED",
  "accept_OPATCH_SELF_UPGRADE": "OPATCH_SELF_UPGRADE"
}
EOF
  printf '%s' "$token"
}

prepare_old_run() {
  local run=$1
  printf '\nMOCK_OPATCH_VERSION=12.2.0.1.51\n' >>"$FIXTURE_ENV"
  assess "$run"
  plan "$run" >/dev/null
}

force_partial_listener_state() {
  local run=$1
  sed -i 's/"state": "03_PLAN_GENERATED"/"state": "PARTIAL"/; s/"phase": "PLAN"/"phase": "START_LISTENER"/' "$RUN_ROOT/$run/execution_state.json"
  printf '\nMOCK_RESUME_INVENTORY=BOTH\n' >>"$FIXTURE_ENV"
}

run_listener_service_resume_case() {
  local name=$1 run=$2 expected_service=$3 reported_service=$4 reported_sid=$5 ready=$6
  setup_case "$name"
  printf '\nLISTENER_READY_TIMEOUT_SECONDS=1\nLISTENER_POLL_SECONDS=1\n' >>"$CONFIG"
  sed "s/APP_SVC/${expected_service}/" "$CASE_DIR/fixture/database_inventory.csv" >"$CASE_DIR/fixture/database_inventory.updated.csv"
  mv "$CASE_DIR/fixture/database_inventory.updated.csv" "$CASE_DIR/fixture/database_inventory.csv"
  assess "$run" >/dev/null
  plan "$run" >/dev/null
  force_partial_listener_state "$run"
  printf '\nMOCK_LISTENER_REPORTED_SERVICE=%s\nMOCK_LISTENER_REPORTED_SID=%s\nMOCK_LISTENER_SERVICES_READY=%s\n' \
    "$reported_service" "$reported_sid" "$ready" >>"$FIXTURE_ENV"
  guard resume --non-interactive --run-id "$run" >"$CASE_DIR/resume.out" 2>&1
}

# P05-01: planning, happy path, idempotency, invalid/unknown media and dry-run.
setup_case oldvalid; prepare_old_run P01A; rc=$?
grep -q 'CONDITIONAL|OPATCH_SELF_UPGRADE' "$RUN_ROOT/P01A/findings.psv" || rc=99
grep -q '"opatch_upgrade_required": true' "$RUN_ROOT/P01A/patch_manifest.json" || rc=98
record 'P05-01 oude OPatch met geldig medium plant upgrade' 0 "$rc"
token=$(approval P01A)
guard apply --non-interactive --run-id P01A --approved-manifest "$RUN_ROOT/P01A/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; [[ -d "$HOME_DIR/OPatch.before-P01A" && "$(<"$HOME_DIR/OPatch/.opg-version")" == 12.2.0.1.52 ]] || rc=99
grep -q 'OPATCH_UPGRADE_COMPLETE' "$RUN_ROOT/P01A/commands.log" || rc=98
upgrade_line=$(grep -n 'OPATCH_UPGRADE_COMPLETE' "$RUN_ROOT/P01A/commands.log" | head -1 | cut -d: -f1)
ru_line=$(grep -n 'COMMAND_START|label=apply_db_ru|' "$RUN_ROOT/P01A/commands.log" | head -1 | cut -d: -f1)
[[ "$upgrade_line" =~ ^[0-9]+$ && "$ru_line" =~ ^[0-9]+$ && "$upgrade_line" -lt "$ru_line" ]] || rc=97
record 'P05-01 self-upgrade voltooit vóór RU/OJVM' 0 "$rc" "$CASE_DIR/apply.out"

setup_case exact; assess P01B >/dev/null; plan P01B >/dev/null; token=$(approval P01B)
guard apply --non-interactive --run-id P01B --approved-manifest "$RUN_ROOT/P01B/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; [[ ! -e "$HOME_DIR/OPatch.before-P01B" ]] || rc=99; grep -q 'OPATCH_UPGRADE_SKIP' "$RUN_ROOT/P01B/commands.log" || rc=98
record 'P05-01 exacte OPatch wordt idempotent overgeslagen' 0 "$rc" "$CASE_DIR/apply.out"

setup_case corrupt; printf '\nMOCK_OPATCH_VERSION=12.2.0.1.51\nMOCK_OPATCH_MEDIA=CORRUPT\n' >>"$FIXTURE_ENV"; assess P01C
record 'P05-01 corrupte ZIP blokkeert assess' 20 $? "$CASE_DIR/P01C.assess.out"
setup_case unknown; printf '\nMOCK_OPATCH_VERSION=12.2.0.1.51\nMOCK_OPATCH_MEDIA=UNKNOWN\n' >>"$FIXTURE_ENV"; assess P01D
record 'P05-01 onbetrouwbare ZIP-validatie is UNKNOWN' 30 $? "$CASE_DIR/P01D.assess.out"

setup_case dryrun; prepare_old_run P01E >/dev/null; token=$(approval P01E); before=$(sha256sum "$HOME_DIR/OPatch/opatch" | awk '{print $1}')
guard apply --dry-run --non-interactive --run-id P01E --approved-manifest "$RUN_ROOT/P01E/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; after=$(sha256sum "$HOME_DIR/OPatch/opatch" | awk '{print $1}'); [[ "$before" == "$after" && ! -e "$HOME_DIR/OPatch.stage-P01E" && ! -e "$HOME_DIR/OPatch.before-P01E" ]] || rc=99
record 'P05-01 dry-run wijzigt OPatch niet' 0 "$rc" "$CASE_DIR/apply.out"

for point in STAGING BACKUP PROMOTION; do
  setup_case "interrupt-${point,,}"; run="P01${point:0:1}"; prepare_old_run "$run" >/dev/null; token=$(approval "$run")
  printf '\nMOCK_OPATCH_INTERRUPT_AFTER=%s\n' "$point" >>"$FIXTURE_ENV"
  guard apply --non-interactive --run-id "$run" --approved-manifest "$RUN_ROOT/$run/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
  apply_rc=$?; printf '\nMOCK_OPATCH_INTERRUPT_AFTER=\n' >>"$FIXTURE_ENV"
  guard resume --non-interactive --run-id "$run" >"$CASE_DIR/resume.out" 2>&1
  rc=$?; [[ "$apply_rc" == 40 && "$(<"$HOME_DIR/OPatch/.opg-version")" == 12.2.0.1.52 ]] || rc=99
  [[ $(grep -Fc 'COMMAND_START|label=apply_db_ru|' "$RUN_ROOT/$run/commands.log") == 1 && $(grep -Fc 'COMMAND_START|label=apply_ojvm|' "$RUN_ROOT/$run/commands.log") == 1 ]] || rc=98
  record "P05-01 veilige resume na ${point,,}" 0 "$rc" "$CASE_DIR/resume.out"
done

# P05-02: setupfout en echte contention blijven verschillend.
setup_case locktypes; assess P02 >/dev/null; plan P02 >/dev/null; token=$(approval P02); rmdir "$LOCK_ROOT"
guard apply --dry-run --non-interactive --run-id P02 --approved-manifest "$RUN_ROOT/P02/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/lock-setup.out" 2>&1
rc=$?; grep -q 'status=BLOCKED|phase=LOCK_SETUP|exit_code=20' "$CASE_DIR/lock-setup.out" || rc=99
record 'P05-02 ontbrekende lock-root is LOCK_SETUP' 20 "$rc" "$CASE_DIR/lock-setup.out"
mkdir "$LOCK_ROOT"; printf '\nMOCK_LOCK_BUSY=true\n' >>"$FIXTURE_ENV"
guard apply --dry-run --non-interactive --run-id P02 --approved-manifest "$RUN_ROOT/P02/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/lock-busy.out" 2>&1
record 'P05-02 echte contention blijft ALREADY_RUNNING' 60 $? "$CASE_DIR/lock-busy.out"

# P05-03: registratie plus bounded polling, en fail-closed timeout.
setup_case listenerdelay; printf '\nLISTENER_READY_TIMEOUT_SECONDS=4\nLISTENER_POLL_SECONDS=1\n' >>"$CONFIG"; printf '\nMOCK_LISTENER_READY_AFTER_POLLS=2\n' >>"$FIXTURE_ENV"
assess P03A >/dev/null; plan P03A >/dev/null; token=$(approval P03A)
guard apply --non-interactive --run-id P03A --approved-manifest "$RUN_ROOT/P03A/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -q 'LISTENER_REGISTER_END|sid=DB1|status=OK' "$RUN_ROOT/P03A/commands.log" || rc=99; grep -q 'LISTENER_READY_POLL.*status=NOT_READY' "$RUN_ROOT/P03A/commands.log" || rc=98
record 'P05-03 vertraagde registratie slaagt via register en polling' 0 "$rc" "$CASE_DIR/apply.out"

setup_case listenertimeout; printf '\nLISTENER_READY_TIMEOUT_SECONDS=1\nLISTENER_POLL_SECONDS=1\n' >>"$CONFIG"; printf '\nMOCK_LISTENER_SERVICES_READY=false\n' >>"$FIXTURE_ENV"
assess P03B >/dev/null; plan P03B >/dev/null; token=$(approval P03B)
guard apply --non-interactive --run-id P03B --approved-manifest "$RUN_ROOT/P03B/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?; grep -q 'LISTENER_READY_WAIT_END.*status=TIMEOUT' "$RUN_ROOT/P03B/commands.log" || rc=99
record 'P05-03 listener-timeout blijft fail-closed' 40 "$rc" "$CASE_DIR/apply.out"

# P05-04: echte PARTIAL:START_LISTENER-route en negatieve postconditions.
setup_case listenerresume; assess P04A >/dev/null; plan P04A >/dev/null; force_partial_listener_state P04A
guard resume --non-interactive --run-id P04A >"$CASE_DIR/resume.out" 2>&1
rc=$?; grep -q 'COMMAND_START|label=listener_register_DB1|' "$RUN_ROOT/P04A/commands.log" || rc=99
! grep -q 'COMMAND_START|label=apply_db_ru\|COMMAND_START|label=apply_ojvm' "$RUN_ROOT/P04A/commands.log" || rc=98
record 'P05-04 START_LISTENER resume gaat veilig naar datapatch' 0 "$rc" "$CASE_DIR/resume.out"

setup_case listenerwronghome; assess P04B >/dev/null; plan P04B >/dev/null; force_partial_listener_state P04B; printf '\nMOCK_LISTENER_WRONG_HOME=true\n' >>"$FIXTURE_ENV"
guard resume --non-interactive --run-id P04B >"$CASE_DIR/resume.out" 2>&1
record 'P05-04 listener uit verkeerde home blokkeert' 50 $? "$CASE_DIR/resume.out"

setup_case listenerservicebad; printf '\nLISTENER_READY_TIMEOUT_SECONDS=1\nLISTENER_POLL_SECONDS=1\n' >>"$CONFIG"; assess P04C >/dev/null; plan P04C >/dev/null; force_partial_listener_state P04C; printf '\nMOCK_LISTENER_SERVICES_READY=false\n' >>"$FIXTURE_ENV"
guard resume --non-interactive --run-id P04C >"$CASE_DIR/resume.out" 2>&1
record 'P05-04 niet-READY manifestservice blokkeert' 50 $? "$CASE_DIR/resume.out"

# P05-05: alleen exact of unqualified + punt + domeinsuffix mag matchen.
run_listener_service_resume_case fqdnexact P05A service1.example.com service1.example.com DB1 true
record 'P05-05 exacte gekwalificeerde service matcht' 0 $? "$CASE_DIR/resume.out"

run_listener_service_resume_case fqdnshort P05B DB1XDB DB1XDB.example.com DB1 true
rc=$?
record 'P05-05 ongekwalificeerde service matcht dezelfde FQDN-service' 0 "$rc" "$CASE_DIR/resume.out"
if ! grep -Eq 'label=(apply_db_ru|apply_ojvm)|OPATCH_UPGRADE_COMPLETE' "$RUN_ROOT/P05B/commands.log"; then
  record 'P05-05 START_LISTENER-resume past OPatch/RU/OJVM niet opnieuw toe' 0 0
else
  record 'P05-05 START_LISTENER-resume past OPatch/RU/OJVM niet opnieuw toe' 0 1
fi

run_listener_service_resume_case unrelatedprefix P05C service1 service123.example.com DB1 true
record 'P05-05 generieke serviceprefix matcht niet' 50 $? "$CASE_DIR/resume.out"

run_listener_service_resume_case differentfqdn P05D service1.example.com service1.other.example DB1 true
record 'P05-05 gekwalificeerde service blijft exact' 50 $? "$CASE_DIR/resume.out"

run_listener_service_resume_case wrongsid P05E service1 service1 DB2 true
record 'P05-05 juiste service met verkeerde SID faalt' 50 $? "$CASE_DIR/resume.out"

run_listener_service_resume_case notready P05F service1 service1 DB1 false
record 'P05-05 juiste service en SID zonder READY faalt' 50 $? "$CASE_DIR/resume.out"

# P05-06: rungebonden componentbaseline, conservatieve health-classificatie en validation-only resume.
run_registry_apply_case() {
  local name=$1 run=$2 before=$3 after=$4 cdb=${5:-YES}
  setup_case "$name"
  if [[ "$cdb" == NO ]]; then
    printf 'SID,ORACLE_HOME,oratab_autostart,instance_running,database_role,open_mode,CDB,PDB_status,listener,services\n' >"$CASE_DIR/fixture/database_inventory.csv"
    printf '"DB1","%s","Y","true","PRIMARY","READ WRITE","NO","","LISTENER","APP_SVC"\n' "$HOME_DIR" >>"$CASE_DIR/fixture/database_inventory.csv"
  fi
  printf "\nMOCK_REGISTRY_BEFORE='%s'\nMOCK_REGISTRY_AFTER='%s'\n" "$before" "$after" >>"$FIXTURE_ENV"
  assess "$run" >/dev/null
  plan "$run" >/dev/null
  local token
  token=$(approval "$run")
  guard apply --non-interactive --run-id "$run" --approved-manifest "$RUN_ROOT/$run/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
}

run_registry_apply_case registryvalid P06A \
  'REGISTRY|CATALOG|VALID;CDB_REGISTRY|1|CATALOG|VALID' \
  'REGISTRY|CATALOG|VALID;CDB_REGISTRY|1|CATALOG|VALID'
record 'P05-06 gezonde VALID-componenten blijven geldig' 0 $? "$CASE_DIR/apply.out"

run_registry_apply_case registryoptionoff P06B \
  'REGISTRY|CATALOG|VALID;REGISTRY|RAC|OPTION OFF' \
  'REGISTRY|CATALOG|VALID;REGISTRY|RAC|OPTION OFF' NO
record 'P05-06 RAC OPTION OFF blijft geldig op non-RAC' 0 $? "$CASE_DIR/apply.out"

setup_case registryinvalidbefore
printf 'SID,ORACLE_HOME,oratab_autostart,instance_running,database_role,open_mode,CDB,PDB_status,listener,services\n' >"$CASE_DIR/fixture/database_inventory.csv"
printf '"DB1","%s","Y","true","PRIMARY","READ WRITE","NO","","LISTENER","APP_SVC"\n' "$HOME_DIR" >>"$CASE_DIR/fixture/database_inventory.csv"
printf "\nMOCK_REGISTRY_BEFORE='REGISTRY|CATALOG|VALID;REGISTRY|XDB|INVALID'\n" >>"$FIXTURE_ENV"
assess P06C
record 'P05-06 vooraf INVALID component blokkeert assess' 20 $? "$CASE_DIR/P06C.assess.out"
if ! compgen -G "$RUN_ROOT/P06C/shutdown_*.log" >/dev/null; then
  record 'P05-06 ongezonde baseline bereikt geen downtime' 0 0
else
  record 'P05-06 ongezonde baseline bereikt geen downtime' 0 1
fi

run_registry_apply_case registrydegraded P06D \
  'REGISTRY|CATALOG|VALID;CDB_REGISTRY|1|CATALOG|VALID' \
  'REGISTRY|CATALOG|INVALID;CDB_REGISTRY|1|CATALOG|VALID'
record 'P05-06 VALID naar INVALID faalt eindvalidatie' 50 $? "$CASE_DIR/apply.out"

run_registry_apply_case registrystatuschange P06E \
  'REGISTRY|CATALOG|VALID;REGISTRY|RAC|OPTION OFF' \
  'REGISTRY|CATALOG|VALID;REGISTRY|RAC|VALID' NO
record 'P05-06 acceptabele statuswijziging faalt gesloten' 50 $? "$CASE_DIR/apply.out"

run_registry_apply_case registrymissing P06F \
  'REGISTRY|CATALOG|VALID;REGISTRY|XDB|VALID' \
  'REGISTRY|CATALOG|VALID' NO
record 'P05-06 verdwenen component faalt gesloten' 50 $? "$CASE_DIR/apply.out"

run_registry_apply_case registrynewbad P06G \
  'REGISTRY|CATALOG|VALID' \
  'REGISTRY|CATALOG|VALID;REGISTRY|XDB|INVALID' NO
record 'P05-06 nieuwe ongezonde component faalt gesloten' 50 $? "$CASE_DIR/apply.out"

setup_case registryqueryerror
printf '\nMOCK_REGISTRY_QUERY_FAILED=true\n' >>"$FIXTURE_ENV"
assess P06H
record 'P05-06 registryquery-fout tijdens assess is UNKNOWN' 30 $? "$CASE_DIR/P06H.assess.out"

run_registry_apply_case registryparseerror P06I \
  'REGISTRY|CATALOG|VALID;CDB_REGISTRY|1|CATALOG|VALID' \
  'REGISTRY|CATALOG|VALID'
rc=$?
record 'P05-06 registryparse-fout na patch faalt gesloten' 50 "$rc" "$CASE_DIR/apply.out"

setup_case registrysqlpatch
assess P06J >/dev/null; plan P06J >/dev/null; token=$(approval P06J)
printf '\nMOCK_VALIDATION_SQLPATCH_BAD=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id P06J --approved-manifest "$RUN_ROOT/P06J/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
record 'P05-06 DB-RU en OJVM SQLPATCH SUCCESS blijven verplicht' 50 $? "$CASE_DIR/apply.out"

setup_case registryinvalidobjects
assess P06K >/dev/null; plan P06K >/dev/null; token=$(approval P06K)
printf '\nMOCK_VALIDATION_INVALID_COUNT=1\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id P06K --approved-manifest "$RUN_ROOT/P06K/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
record 'P05-06 invalid-objectregressie blijft verplicht' 50 $? "$CASE_DIR/apply.out"

run_registry_apply_case registrycdb P06L \
  'REGISTRY|CATALOG|VALID;CDB_REGISTRY|1|CATALOG|VALID;CDB_REGISTRY|3|XDB|VALID' \
  'REGISTRY|CATALOG|VALID;CDB_REGISTRY|1|CATALOG|VALID;CDB_REGISTRY|3|XDB|INVALID'
record 'P05-06 CDB-componentdegradatie faalt gesloten' 50 $? "$CASE_DIR/apply.out"

setup_case registryvalidationresume
printf "\nMOCK_REGISTRY_BEFORE='REGISTRY|CATALOG|VALID;CDB_REGISTRY|1|CATALOG|VALID'\nMOCK_REGISTRY_AFTER='REGISTRY|CATALOG|INVALID;CDB_REGISTRY|1|CATALOG|VALID'\n" >>"$FIXTURE_ENV"
assess P06M >/dev/null; plan P06M >/dev/null; token=$(approval P06M)
guard apply --non-interactive --run-id P06M --approved-manifest "$RUN_ROOT/P06M/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1 || true
before_mutations=$(grep -Ec 'label=(apply_db_ru|apply_ojvm|datapatch_DB1|utlrp_DB1)' "$RUN_ROOT/P06M/commands.log")
printf "\nMOCK_REGISTRY_AFTER='REGISTRY|CATALOG|VALID;CDB_REGISTRY|1|CATALOG|VALID'\n" >>"$FIXTURE_ENV"
guard resume --non-interactive --run-id P06M >"$CASE_DIR/resume.out" 2>&1
rc=$?
after_mutations=$(grep -Ec 'label=(apply_db_ru|apply_ojvm|datapatch_DB1|utlrp_DB1)' "$RUN_ROOT/P06M/commands.log")
[[ "$before_mutations" == "$after_mutations" ]] || rc=99
record 'P05-06 validation-resume herhaalt OPatch/RU/OJVM/datapatch/utlrp niet' 0 "$rc" "$CASE_DIR/resume.out"

setup_case registrybaselinetamper
assess P06N >/dev/null; plan P06N >/dev/null; token=$(approval P06N)
chmod 0640 "$RUN_ROOT/P06N/registry_components_before.psv"
printf 'DB1|REGISTRY|0|TAMPERED|VALID\n' >>"$RUN_ROOT/P06N/registry_components_before.psv"
guard apply --non-interactive --run-id P06N --approved-manifest "$RUN_ROOT/P06N/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?
[[ ! -e "$RUN_ROOT/P06N/shutdown_DB1.log" ]] || rc=99
record 'P05-06 gewijzigde runbaseline blokkeert vóór downtime' 20 "$rc" "$CASE_DIR/apply.out"

setup_case registrypreapplychange
assess P06O >/dev/null; plan P06O >/dev/null; token=$(approval P06O)
printf '\nMOCK_REGISTRY_PREAPPLY_CHANGED=true\n' >>"$FIXTURE_ENV"
guard apply --non-interactive --run-id P06O --approved-manifest "$RUN_ROOT/P06O/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/apply.out" 2>&1
rc=$?
[[ ! -e "$RUN_ROOT/P06O/shutdown_DB1.log" ]] || rc=99
record 'P05-06 componentwijziging bij pre-apply blokkeert vóór downtime' 20 "$rc" "$CASE_DIR/apply.out"

printf '\nPilot05b-resultaat: %s geslaagd, %s mislukt\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
