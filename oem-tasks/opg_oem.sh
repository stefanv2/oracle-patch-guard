#!/usr/bin/env bash
# Oracle Patch Guard generic OEM entrypoint.
# Discovery/context/routing only; all safety and patch decisions remain in core.
set -u
set -o pipefail
umask 077
IFS=$'\n\t'

readonly EXIT_BLOCKED=20 EXIT_UNKNOWN=30 EXIT_USAGE=70
readonly SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
export PATH=$SAFE_PATH

SCRIPT_NAME=${0##*/}
COMMAND=${1:-}
[[ $# -eq 1 ]] || COMMAND=

fail() {
  local code=$1 phase=$2 message=$3 status=BLOCKED
  (( code == EXIT_UNKNOWN )) && status=UNKNOWN
  printf 'OPG OEM %s: %s\n' "$status" "$message" >&2
  printf 'OPG_OEM_RESULT|status=%s|phase=%s|exit_code=%s\n' "$status" "$phase" "$code"
  exit "$code"
}

usage() {
  printf 'Gebruik: %s {precheck|prepare|stage-media|create-window|assess|plan|stage|apply|publish-completion|approval-check|show-context|new-run}\n' "$SCRIPT_NAME" >&2
  exit "$EXIT_USAGE"
}

case "$COMMAND" in
  precheck|prepare|stage-media|create-window|assess|plan|stage|apply|publish-completion|approval-check|show-context|new-run) ;;
  *) usage ;;
esac

trim() {
  local value=$1
  value="${value#"${value%%[![:space:]]*}"}"
  value="${value%"${value##*[![:space:]]}"}"
  printf '%s' "$value"
}

config_path_value() {
  local config=$1 wanted=$2 raw key value found='' line_no=0 mode perm owner
  [[ -f "$config" && -r "$config" && ! -L "$config" ]] || fail "$EXIT_BLOCKED" CONFIG "Centrale Patch Guard-config ontbreekt of is onveilig: ${config}"
  mode=$(stat -c '%a' "$config" 2>/dev/null) || fail "$EXIT_UNKNOWN" CONFIG 'Configmode kon niet worden bepaald.'
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || fail "$EXIT_UNKNOWN" CONFIG 'Configmode is ongeldig.'
  perm=$((8#$mode)); (( (perm & 0022) == 0 )) || fail "$EXIT_BLOCKED" CONFIG 'Centrale config is group/world-writable.'
  if [[ ${TEST_MODE:-false} != true ]]; then owner=$(stat -c '%U' "$config" 2>/dev/null) || fail "$EXIT_UNKNOWN" CONFIG 'Configowner kon niet worden bepaald.'; [[ "$owner" == root ]] || fail "$EXIT_BLOCKED" CONFIG 'Live config moet root-owned zijn.'; fi
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1)); raw=${raw%$'\r'}; raw=$(trim "$raw")
    [[ -n "$raw" && ${raw:0:1} != '#' ]] || continue
    [[ "$raw" == *=* ]] || continue
    key=$(trim "${raw%%=*}"); value=$(trim "${raw#*=}")
    [[ "$key" == "$wanted" ]] || continue
    [[ -z "$found" ]] || fail "$EXIT_BLOCKED" CONFIG "Dubbele sleutel ${wanted} in ${config}."
    found=$value
  done <"$config"
  [[ -n "$found" ]] || fail "$EXIT_BLOCKED" CONFIG "Verplichte configsleutel ontbreekt of is leeg: ${wanted}"
  [[ "$found" == /* && "$found" =~ ^/[A-Za-z0-9_./-]+$ && "$found" != *'//'*
     && "$found" != */../* && "$found" != */./* && "$found" != */.. && "$found" != */. ]] || fail "$EXIT_BLOCKED" CONFIG "Ongeldig absoluut pad voor ${wanted}."
  printf '%s' "$found"
}

TEST_MODE=false
if [[ ${OPG_WRAPPER_TEST_MODE:-0} == 1 ]]; then
  TEST_MODE=true
  [[ ${OPG_TEST_ROOT:-} == /tmp/opg-oem-wrapper-tests.* ]] || fail "$EXIT_USAGE" INIT 'Ongeldige testroot.'
  CONFIG_FILE=${OPG_TEST_CONFIG:-${OPG_TEST_ROOT}/etc/patchGD_guard.conf}
  if [[ -n ${OPG_TEST_OPG_ROOT:-} ]]; then OPG_ROOT=$OPG_TEST_OPG_ROOT; else OPG_ROOT=$(config_path_value "$CONFIG_FILE" OPG_ROOT) || exit $?; fi
  if [[ -n ${OPG_TEST_APPROVAL_ROOT:-} ]]; then APPROVAL_ROOT=$OPG_TEST_APPROVAL_ROOT; elif [[ -n ${OPG_TEST_OPG_ROOT:-} ]]; then APPROVAL_ROOT=${OPG_ROOT}/approvals; else APPROVAL_ROOT=$(config_path_value "$CONFIG_FILE" APPROVAL_ROOT) || exit $?; fi
  CONTEXT_ROOT=${OPG_TEST_CONTEXT_ROOT:-${OPG_TEST_ROOT}/var/lib/oracle-patch-guard}
  TASK_ROOT=${OPG_TEST_TASK_ROOT:-${OPG_TEST_ROOT}/oem-tasks}
  PROJECT_ROOT=${OPG_TEST_PROJECT_ROOT:-${OPG_TEST_ROOT}/current/project}
  DISCOVERY_FIXTURE=${OPG_TEST_DISCOVERY_FIXTURE:-${OPG_TEST_ROOT}/discovery.psv}
  CONTEXT_OWNER=${OPG_TEST_CONTEXT_OWNER:-$(id -un)}
  CONTEXT_GROUP=${OPG_TEST_CONTEXT_GROUP:-$(id -gn)}
  SUDO_BIN=${OPG_TEST_SUDO_BIN:-${OPG_TEST_ROOT}/mock-sudo}
  CONTEXT_HELPER=${OPG_TEST_CONTEXT_HELPER:-${OPG_TEST_ROOT}/local-sbin/opg_context_root.sh}
  CONTEXT_HELPER_OWNER=${OPG_TEST_CONTEXT_HELPER_OWNER:-$(id -un)}
  CONTEXT_HELPER_GROUP=${OPG_TEST_CONTEXT_HELPER_GROUP:-$(id -gn)}
  CONTEXT_HELPER_PARENT_STOP=${OPG_TEST_CONTEXT_HELPER_PARENT_STOP:-${OPG_TEST_ROOT}/local-sbin}
  MEDIA_STAGE_HELPER=${OPG_TEST_MEDIA_STAGE_HELPER:-${OPG_TEST_ROOT}/local-sbin/opg_media_stage_root.sh}
  MEDIA_STAGE_HELPER_OWNER=${OPG_TEST_MEDIA_STAGE_HELPER_OWNER:-$(id -un)}
  MEDIA_STAGE_HELPER_GROUP=${OPG_TEST_MEDIA_STAGE_HELPER_GROUP:-$(id -gn)}
  MEDIA_STAGE_HELPER_PARENT_STOP=${OPG_TEST_MEDIA_STAGE_HELPER_PARENT_STOP:-${OPG_TEST_ROOT}/local-sbin}
else
  CONFIG_FILE=/etc/oracle-patch-guard/patchGD_guard.conf
  OPG_ROOT=$(config_path_value "$CONFIG_FILE" OPG_ROOT) || exit $?
  APPROVAL_ROOT=$(config_path_value "$CONFIG_FILE" APPROVAL_ROOT) || exit $?
  CONTEXT_ROOT=/var/lib/oracle-patch-guard
  TASK_ROOT=${OPG_ROOT}/oem-tasks
  PROJECT_ROOT=${OPG_ROOT}/current/project
  DISCOVERY_FIXTURE=
  CONTEXT_OWNER=root
  CONTEXT_GROUP=oinstall
  SUDO_BIN=/usr/bin/sudo
  CONTEXT_HELPER=/usr/local/sbin/opg_context_root.sh
  CONTEXT_HELPER_OWNER=root
  CONTEXT_HELPER_GROUP=root
  CONTEXT_HELPER_PARENT_STOP=/
  MEDIA_STAGE_HELPER=/usr/local/sbin/opg_media_stage_root.sh
  MEDIA_STAGE_HELPER_OWNER=root
  MEDIA_STAGE_HELPER_GROUP=root
  MEDIA_STAGE_HELPER_PARENT_STOP=/
fi

for deployment_path in "$OPG_ROOT" "$APPROVAL_ROOT"; do
  [[ "$deployment_path" == /* && "$deployment_path" =~ ^/[A-Za-z0-9_./-]+$ && "$deployment_path" != *'//'*
     && "$deployment_path" != */../* && "$deployment_path" != */./* && "$deployment_path" != */.. && "$deployment_path" != */. ]] || fail "$EXIT_BLOCKED" CONFIG 'Relatief of ongeldig deploymentpad geweigerd.'
done

CONTEXT_FILE=${CONTEXT_ROOT}/current_run.json
ACTIVE_CYCLE_FILE=${OPG_ROOT}/config/active_cycle
PREPARE_SCRIPT=${TASK_ROOT}/opg_prepare_host.sh
WINDOW_SCRIPT=${TASK_ROOT}/opg_create_window.sh
ASSESS_SCRIPT=${TASK_ROOT}/opg_assess_task.sh
STAGE_SCRIPT=${TASK_ROOT}/opg_stage_approval.sh
CORE_SCRIPT=${PROJECT_ROOT}/patchGD_guard.sh
APPLY_SCRIPT=${PROJECT_ROOT}/oem_apply.sh
APPROVAL_CHECK_SCRIPT=${PROJECT_ROOT}/oem_approval_check.sh
SUMMARY_SCRIPT=${PROJECT_ROOT}/lib/opg_result_summary_v1.1.sh

PATCH_ROOT=
OPATCH_ROOT=
RUN_ROOT=/var/log/oracle-patch-guard
ORATAB_FILE=/etc/oratab
LOCAL_MEDIA_MODE=disabled

require_safe_file() {
  local path=$1 description=$2 mode perm
  [[ -f "$path" && -r "$path" && ! -L "$path" ]] || fail "$EXIT_BLOCKED" DISCOVERY "${description} ontbreekt, is niet leesbaar/regulier of is een symlink: ${path}"
  mode=$(stat -c '%a' "$path" 2>/dev/null) || fail "$EXIT_UNKNOWN" DISCOVERY "Modes konden niet worden bepaald voor ${path}."
  [[ "$mode" =~ ^[0-7]{3,4}$ ]] || fail "$EXIT_UNKNOWN" DISCOVERY "Ongeldige mode voor ${path}."
  perm=$((8#$mode))
  (( (perm & 0022) == 0 )) || fail "$EXIT_BLOCKED" DISCOVERY "${description} is group/world-writable: ${path} (${mode})."
}

load_local_paths() {
  local raw key value line_no=0
  declare -A seen=()
  [[ -f "$CONFIG_FILE" && -r "$CONFIG_FILE" && ! -L "$CONFIG_FILE" ]] || fail "$EXIT_BLOCKED" CONFIG "Centrale Patch Guard-config ontbreekt of is onveilig: ${CONFIG_FILE}"
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1)); raw=${raw%$'\r'}
    raw=$(trim "$raw")
    [[ -n "$raw" && ${raw:0:1} != '#' ]] || continue
    [[ "$raw" == *=* ]] || continue
    key=$(trim "${raw%%=*}"); value=$(trim "${raw#*=}")
    if [[ "$value" == '"'*'"' && ${#value} -ge 2 ]]; then value=${value:1:${#value}-2}; fi
    case "$key" in
      PATCH_ROOT|OPATCH_ROOT|RUN_ROOT|ORATAB_FILE)
        [[ -z ${seen[$key]+x} ]] || fail "$EXIT_BLOCKED" CONFIG "Dubbele sleutel ${key} in ${CONFIG_FILE}."
        [[ "$value" == /* && "$value" =~ ^/[A-Za-z0-9_./-]+$ ]] || fail "$EXIT_BLOCKED" CONFIG "Ongeldig absoluut pad voor ${key} op regel ${line_no}."
        printf -v "$key" '%s' "$value"; seen[$key]=1
        ;;
      LOCAL_MEDIA_MODE)
        [[ -z ${seen[$key]+x} ]] || fail "$EXIT_BLOCKED" CONFIG "Dubbele sleutel ${key} in ${CONFIG_FILE}."
        [[ "$value" == disabled || "$value" == required ]] || fail "$EXIT_BLOCKED" CONFIG 'LOCAL_MEDIA_MODE moet disabled of required zijn.'
        LOCAL_MEDIA_MODE=$value; seen[$key]=1
        ;;
      *) ;;
    esac
  done <"$CONFIG_FILE"
  for key in PATCH_ROOT OPATCH_ROOT RUN_ROOT; do
    [[ -n ${seen[$key]+x} ]] || fail "$EXIT_BLOCKED" CONFIG "Verplichte configsleutel ontbreekt: ${key}."
  done
  if [[ "$TEST_MODE" != true && "$LOCAL_MEDIA_MODE" != required ]]; then fail "$EXIT_BLOCKED" CONFIG 'Pilot07 productie vereist LOCAL_MEDIA_MODE=required; share-fallback is geweigerd.'; fi
}

load_cycle() {
  local raw cycle_file key value line_no=0
  declare -A values=() seen=()
  require_safe_file "$ACTIVE_CYCLE_FILE" active-cycle
  mapfile -t active_lines < <(sed 's/\r$//' "$ACTIVE_CYCLE_FILE" | awk '{$1=$1} NF && $1 !~ /^#/ {print}')
  [[ ${#active_lines[@]} -eq 1 ]] || fail "$EXIT_BLOCKED" CYCLE 'active_cycle moet exact één niet-lege waarde bevatten.'
  PATCH_CYCLE=${active_lines[0]}
  [[ "$PATCH_CYCLE" =~ ^[A-Z][A-Z0-9_-]{2,31}$ ]] || fail "$EXIT_BLOCKED" CYCLE "Ongeldige actieve patchcycle: ${PATCH_CYCLE}"
  CYCLE_DIR=${PATCH_ROOT}/${PATCH_CYCLE}
  [[ -d "$CYCLE_DIR" && ! -L "$CYCLE_DIR" ]] || fail "$EXIT_BLOCKED" CYCLE "Cycle-directory ontbreekt of is een symlink: ${CYCLE_DIR}"
  cycle_file=${CYCLE_DIR}/opg_cycle.conf
  require_safe_file "$cycle_file" opg_cycle.conf
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    line_no=$((line_no + 1)); raw=${raw%$'\r'}; raw=$(trim "$raw")
    [[ -n "$raw" && ${raw:0:1} != '#' ]] || continue
    [[ "$raw" == *=* ]] || fail "$EXIT_BLOCKED" CYCLE "Ongeldige metadataregel ${line_no}."
    key=$(trim "${raw%%=*}"); value=$(trim "${raw#*=}")
    case "$key" in PATCH_CYCLE|DB_RU_PATCH_ID|OJVM_PATCH_ID|OPATCH_VERSION|OPATCH_ZIP|DB_RU_ZIP|DB_RU_ZIP_SHA256|OJVM_ZIP|OJVM_ZIP_SHA256|OPATCH_ZIP_SHA256|ARTIFACT_MANIFEST|ARTIFACT_MANIFEST_SIG) ;; *) fail "$EXIT_BLOCKED" CYCLE "Onbekende cycle-key: ${key}" ;; esac
    [[ -z ${seen[$key]+x} ]] || fail "$EXIT_BLOCKED" CYCLE "Dubbele cycle-key: ${key}"
    [[ -n "$value" ]] || fail "$EXIT_BLOCKED" CYCLE "Lege cycle-waarde: ${key}"
    values[$key]=$value; seen[$key]=1
  done <"$cycle_file"
  for key in PATCH_CYCLE DB_RU_PATCH_ID OJVM_PATCH_ID OPATCH_VERSION OPATCH_ZIP; do
    [[ -n ${values[$key]+x} ]] || fail "$EXIT_BLOCKED" CYCLE "Verplichte cycle-key ontbreekt: ${key}"
  done
  [[ ${values[PATCH_CYCLE]} == "$PATCH_CYCLE" ]] || fail "$EXIT_BLOCKED" CYCLE 'active_cycle en opg_cycle.conf conflicteren.'
  DB_RU_PATCH_ID=${values[DB_RU_PATCH_ID]}; OJVM_PATCH_ID=${values[OJVM_PATCH_ID]}
  OPATCH_VERSION=${values[OPATCH_VERSION]}; OPATCH_ZIP=${values[OPATCH_ZIP]}
  [[ "$DB_RU_PATCH_ID" =~ ^[0-9]{6,10}$ ]] || fail "$EXIT_BLOCKED" CYCLE 'DB RU patch-ID is niet numeriek/geldig.'
  [[ "$OJVM_PATCH_ID" =~ ^[0-9]{6,10}$ ]] || fail "$EXIT_BLOCKED" CYCLE 'OJVM patch-ID is niet numeriek/geldig.'
  [[ "$DB_RU_PATCH_ID" != "$OJVM_PATCH_ID" ]] || fail "$EXIT_BLOCKED" CYCLE 'DB RU en OJVM patch-ID zijn gelijk.'
  [[ "$OPATCH_VERSION" =~ ^[0-9]+([.][0-9]+){3,5}$ ]] || fail "$EXIT_BLOCKED" CYCLE 'Ongeldige OPatch-versie.'
  [[ "$OPATCH_ZIP" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]zip$ && "$OPATCH_ZIP" != */* ]] || fail "$EXIT_BLOCKED" CYCLE 'Ongeldige OPatch ZIP-bestandsnaam.'
  if [[ "$LOCAL_MEDIA_MODE" == required ]]; then
    for key in DB_RU_ZIP DB_RU_ZIP_SHA256 OJVM_ZIP OJVM_ZIP_SHA256 OPATCH_ZIP_SHA256 ARTIFACT_MANIFEST ARTIFACT_MANIFEST_SIG; do
      [[ -n ${values[$key]+x} ]] || fail "$EXIT_BLOCKED" CYCLE "Verplichte Pilot07 cycle-key ontbreekt: ${key}"
    done
    [[ ${values[DB_RU_ZIP]} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]zip$ && -f "$CYCLE_DIR/${values[DB_RU_ZIP]}" && ! -L "$CYCLE_DIR/${values[DB_RU_ZIP]}" ]] || fail "$EXIT_BLOCKED" CYCLE 'DB RU transport-ZIP ontbreekt of is onveilig.'
    [[ ${values[OJVM_ZIP]} =~ ^[A-Za-z0-9][A-Za-z0-9._-]*[.]zip$ && -f "$CYCLE_DIR/${values[OJVM_ZIP]}" && ! -L "$CYCLE_DIR/${values[OJVM_ZIP]}" ]] || fail "$EXIT_BLOCKED" CYCLE 'OJVM transport-ZIP ontbreekt of is onveilig.'
  else
    [[ -d "$CYCLE_DIR/$DB_RU_PATCH_ID" && ! -L "$CYCLE_DIR/$DB_RU_PATCH_ID" ]] || fail "$EXIT_BLOCKED" CYCLE 'DB RU patch-directory ontbreekt of is een symlink.'
    [[ -d "$CYCLE_DIR/$OJVM_PATCH_ID" && ! -L "$CYCLE_DIR/$OJVM_PATCH_ID" ]] || fail "$EXIT_BLOCKED" CYCLE 'OJVM patch-directory ontbreekt of is een symlink.'
  fi
  [[ -f "$OPATCH_ROOT/$OPATCH_ZIP" && -r "$OPATCH_ROOT/$OPATCH_ZIP" && ! -L "$OPATCH_ROOT/$OPATCH_ZIP" ]] || fail "$EXIT_BLOCKED" CYCLE "OPatch ZIP ontbreekt in de door core geconfigureerde OPATCH_ROOT: ${OPATCH_ROOT}/${OPATCH_ZIP}"
}

canonical_home() {
  local home=$1
  [[ "$home" == /* && -d "$home" && ! -L "$home" && -x "$home/bin/oracle" ]] || return 1
  (cd -P -- "$home" 2>/dev/null && pwd -P)
}

discover_from_fixture() {
  local sid home active extra canonical
  require_safe_file "$DISCOVERY_FIXTURE" discovery-fixture
  DISCOVERED_TARGETS=()
  while IFS='|' read -r sid home active extra; do
    [[ -z "$extra" && -n "$sid" ]] || fail "$EXIT_BLOCKED" TARGET 'Ongeldige discovery-fixture.'
    [[ "$sid" =~ ^[A-Za-z0-9_#$]+$ && "$sid" != +ASM* ]] || continue
    canonical=$(canonical_home "$home") || continue
    [[ "$active" == "$canonical" ]] || continue
    DISCOVERED_TARGETS+=("${sid}|${canonical}")
  done <"$DISCOVERY_FIXTURE"
}

discover_from_oratab() {
  local raw sid home autostart extra canonical process_dir process_name exe matched
  [[ -f "$ORATAB_FILE" && -r "$ORATAB_FILE" && ! -L "$ORATAB_FILE" ]] || fail "$EXIT_BLOCKED" TARGET "oratab ontbreekt of is onveilig: ${ORATAB_FILE}"
  DISCOVERED_TARGETS=()
  while IFS= read -r raw || [[ -n "$raw" ]]; do
    raw=${raw%$'\r'}; raw=$(trim "$raw")
    [[ -n "$raw" && ${raw:0:1} != '#' ]] || continue
    IFS=: read -r sid home autostart extra <<<"$raw"
    [[ -z ${extra:-} && "$autostart" =~ ^[YN]$ && "$sid" =~ ^[A-Za-z0-9_#$]+$ && "$sid" != +ASM* ]] || continue
    [[ ! "$home" =~ /grid([/]|$) ]] || continue
    canonical=$(canonical_home "$home") || continue
    matched=false
    for process_dir in /proc/[0-9]*; do
      [[ -r "$process_dir/cmdline" ]] || continue
      process_name=
      IFS= read -r -d '' process_name <"$process_dir/cmdline" 2>/dev/null || true
      [[ ${process_name##*/} == "ora_pmon_${sid}" ]] || continue
      exe=$(readlink -f "$process_dir/exe" 2>/dev/null || true)
      [[ "$exe" == "$canonical/bin/oracle" ]] && matched=true
    done
    [[ "$matched" == true ]] && DISCOVERED_TARGETS+=("${sid}|${canonical}")
  done <"$ORATAB_FILE"
}

discover_target() {
  local sid home extra joined
  if [[ "$TEST_MODE" == true ]]; then discover_from_fixture; else discover_from_oratab; fi
  [[ ${#DISCOVERED_TARGETS[@]} -eq 1 ]] || {
    if [[ ${#DISCOVERED_TARGETS[@]} -eq 0 ]]; then fail "$EXIT_BLOCKED" TARGET 'Geen unieke actieve non-ASM Oracle database target gevonden.'; fi
    joined=$(IFS=,; printf '%s' "${DISCOVERED_TARGETS[*]}")
    fail "$EXIT_BLOCKED" TARGET "Meerdere actieve Oracle targets gevonden; automatische keuze geweigerd: ${joined}"
  }
  IFS='|' read -r sid home extra <<<"${DISCOVERED_TARGETS[0]}"
  [[ -z "$extra" ]] || fail "$EXIT_UNKNOWN" TARGET 'Interne targetparserfout.'
  ORACLE_SID=$sid; ORACLE_HOME=$home
  SHORT_HOST=${OPG_TEST_SHORT_HOST:-$(hostname -s 2>/dev/null || true)}
  FQDN=${OPG_TEST_FQDN:-$(hostname -f 2>/dev/null || hostname 2>/dev/null || true)}
  [[ "$SHORT_HOST" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,62}$ ]] || fail "$EXIT_BLOCKED" TARGET 'Short hostname is ongeldig.'
  [[ "$FQDN" =~ ^[A-Za-z0-9][A-Za-z0-9.-]{0,252}$ ]] || fail "$EXIT_BLOCKED" TARGET 'FQDN is ongeldig.'
  LD_LIBRARY_PATH=${ORACLE_HOME}/lib:/lib:/usr/lib
}

discover_all() {
  load_local_paths
  load_cycle
  discover_target
}

context_get() {
  local key=$1
  python3 - "$CONTEXT_FILE" "$key" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    data = json.load(handle)
value = data.get(sys.argv[2])
if not isinstance(value, str) or not value:
    raise SystemExit(1)
print(value)
PY
}

read_context_file() {
  local identity
  [[ -f "$CONTEXT_FILE" && -r "$CONTEXT_FILE" && ! -L "$CONTEXT_FILE" ]] || fail "$EXIT_BLOCKED" CONTEXT 'current_run.json ontbreekt, is onleesbaar of is een symlink.'
  identity=$(stat -c '%U:%G:%a' "$CONTEXT_FILE" 2>/dev/null) || fail "$EXIT_UNKNOWN" CONTEXT 'Contextpermissions konden niet worden bepaald.'
  [[ "$identity" == "${CONTEXT_OWNER}:${CONTEXT_GROUP}:640" ]] || fail "$EXIT_BLOCKED" CONTEXT "Contextpermissions wijken af: ${identity}."
  RUN_ID=$(context_get run_id) || fail "$EXIT_BLOCKED" CONTEXT 'RUN_ID ontbreekt in current_run.json.'
  CTX_SHORT_HOST=$(context_get short_hostname) || fail "$EXIT_BLOCKED" CONTEXT 'short_hostname ontbreekt.'
  CTX_FQDN=$(context_get fqdn) || fail "$EXIT_BLOCKED" CONTEXT 'fqdn ontbreekt.'
  CTX_SID=$(context_get oracle_sid) || fail "$EXIT_BLOCKED" CONTEXT 'oracle_sid ontbreekt.'
  CTX_HOME=$(context_get oracle_home) || fail "$EXIT_BLOCKED" CONTEXT 'oracle_home ontbreekt.'
  CTX_CYCLE=$(context_get patch_cycle) || fail "$EXIT_BLOCKED" CONTEXT 'patch_cycle ontbreekt.'
  CTX_DB=$(context_get db_ru_patch_id) || fail "$EXIT_BLOCKED" CONTEXT 'db_ru_patch_id ontbreekt.'
  CTX_OJVM=$(context_get ojvm_patch_id) || fail "$EXIT_BLOCKED" CONTEXT 'ojvm_patch_id ontbreekt.'
  CTX_OPATCH_VERSION=$(context_get opatch_version) || fail "$EXIT_BLOCKED" CONTEXT 'opatch_version ontbreekt.'
  CTX_OPATCH_ZIP=$(context_get opatch_zip) || fail "$EXIT_BLOCKED" CONTEXT 'opatch_zip ontbreekt.'
  CTX_CONFIG=$(context_get config_path) || fail "$EXIT_BLOCKED" CONTEXT 'config_path ontbreekt.'
  WINDOW_ID=$(context_get window_id) || fail "$EXIT_BLOCKED" CONTEXT 'window_id ontbreekt.'
  [[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || fail "$EXIT_BLOCKED" CONTEXT 'RUN_ID in context is ongeldig.'
}

validate_context_file() {
  read_context_file
  [[ "$CTX_SHORT_HOST" == "$SHORT_HOST" && "$CTX_FQDN" == "$FQDN" && "$CTX_SID" == "$ORACLE_SID" && "$CTX_HOME" == "$ORACLE_HOME" ]] || fail "$EXIT_BLOCKED" CONTEXT 'Opgeslagen targetcontext wijkt af van verse discovery.'
  [[ "$CTX_CYCLE" == "$PATCH_CYCLE" && "$CTX_DB" == "$DB_RU_PATCH_ID" && "$CTX_OJVM" == "$OJVM_PATCH_ID" && "$CTX_OPATCH_VERSION" == "$OPATCH_VERSION" && "$CTX_OPATCH_ZIP" == "$OPATCH_ZIP" ]] || fail "$EXIT_BLOCKED" CONTEXT 'Opgeslagen patchcyclecontext wijkt af van centrale metadata.'
  [[ "$CTX_CONFIG" == "$CONFIG_FILE" ]] || fail "$EXIT_BLOCKED" CONTEXT 'Opgeslagen configpad wijkt af.'
}

ensure_context_root() {
  require_context_helper
  sudo_context_helper prepare-root || fail "$EXIT_UNKNOWN" CONTEXT 'Contextroot kon niet via de begrensde sudo-helper worden voorbereid.'
  [[ -d "$CONTEXT_ROOT" && ! -L "$CONTEXT_ROOT" ]] || fail "$EXIT_BLOCKED" CONTEXT 'Contextroot is geen veilige directory.'
  local identity
  identity=$(stat -c '%U:%G:%a' "$CONTEXT_ROOT" 2>/dev/null) || fail "$EXIT_UNKNOWN" CONTEXT 'Contextrootpermissions konden niet worden bepaald.'
  [[ "$identity" == "${CONTEXT_OWNER}:${CONTEXT_GROUP}:750" ]] || fail "$EXIT_BLOCKED" CONTEXT "Contextrootpermissions wijken af: ${identity}."
}

derive_new_context() {
  local stamp run_stamp
  stamp=${OPG_TEST_NOW_ISO:-$(date -u '+%Y-%m-%dT%H:%M:%SZ')}
  run_stamp=${OPG_TEST_RUN_STAMP:-$(date -u '+%Y%m%dT%H%M%SZ')}
  [[ "$stamp" =~ ^[0-9T:Z-]+$ && "$run_stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "$EXIT_UNKNOWN" CONTEXT 'Run-tijdstempel is ongeldig.'
  RUN_ID=${SHORT_HOST}-${ORACLE_SID}-${PATCH_CYCLE}-OEM-${run_stamp}
  WINDOW_ID=OPG-${PATCH_CYCLE}-${run_stamp}
  [[ "$RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || fail "$EXIT_BLOCKED" CONTEXT 'Afgeleide RUN_ID is ongeldig of te lang.'
  [[ ! -e "${RUN_ROOT}/${RUN_ID}" ]] || fail "$EXIT_BLOCKED" CONTEXT "Afgeleide RUN_ID bestaat al in RUN_ROOT; stil hergebruik is geweigerd: ${RUN_ID}"
  CONTEXT_CREATED_AT=$stamp
}

emit_context_json() {
  printf '{\n  "schema_version": "1",\n  "run_id": "%s",\n  "short_hostname": "%s",\n  "fqdn": "%s",\n  "oracle_sid": "%s",\n  "oracle_home": "%s",\n  "patch_cycle": "%s",\n  "db_ru_patch_id": "%s",\n  "ojvm_patch_id": "%s",\n  "opatch_version": "%s",\n  "opatch_zip": "%s",\n  "config_path": "%s",\n  "window_id": "%s",\n  "created_at": "%s"\n}\n' \
    "$RUN_ID" "$SHORT_HOST" "$FQDN" "$ORACLE_SID" "$ORACLE_HOME" "$PATCH_CYCLE" "$DB_RU_PATCH_ID" "$OJVM_PATCH_ID" "$OPATCH_VERSION" "$OPATCH_ZIP" "$CONFIG_FILE" "$WINDOW_ID" "$CONTEXT_CREATED_AT"
}

create_context() {
  ensure_context_root
  [[ ! -e "$CONTEXT_FILE" ]] || fail "$EXIT_BLOCKED" CONTEXT 'Actieve run-context bestaat al.'
  derive_new_context
  if ! emit_context_json | sudo_context_helper publish; then fail "$EXIT_UNKNOWN" CONTEXT 'Context kon niet via de begrensde sudo-helper worden gepubliceerd.'; fi
  read_context_file
  printf 'OPG_CONTEXT_CREATED|run_id=%s|sid=%s|home=%s|cycle=%s\n' "$RUN_ID" "$ORACLE_SID" "$ORACLE_HOME" "$PATCH_CYCLE"
}

run_state() {
  local state_file=${RUN_ROOT}/${RUN_ID}/execution_state.json
  if [[ ! -e "$state_file" ]]; then printf 'NONE'; return 0; fi
  [[ -f "$state_file" && -r "$state_file" && ! -L "$state_file" ]] || fail "$EXIT_BLOCKED" CONTEXT 'Run-state bestaat maar is niet veilig leesbaar.'
  python3 - "$state_file" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    state = json.load(handle).get("state")
if not isinstance(state, str) or not state:
    raise SystemExit(1)
print(state)
PY
}

require_state() {
  local expected=$1 actual
  actual=$(run_state) || fail "$EXIT_UNKNOWN" CONTEXT 'Run-state kon niet betrouwbaar worden gelezen.'
  [[ "$actual" == "$expected" ]] || fail "$EXIT_BLOCKED" CONTEXT "Fase ${COMMAND} vereist state ${expected}; gevonden ${actual}."
}

load_or_create_context() {
  local allow_create=$1
  discover_all
  if [[ -e "$CONTEXT_FILE" ]]; then validate_context_file
  elif [[ "$allow_create" == true ]]; then create_context
  else fail "$EXIT_BLOCKED" CONTEXT "Geen actieve run-context; start eerst prepare, create-window of assess."
  fi
}

require_script() {
  local path=$1 label=$2
  [[ -f "$path" && -r "$path" && ! -L "$path" ]] || fail "$EXIT_BLOCKED" ROUTING "Onderliggend ${label}-script ontbreekt of is onveilig: ${path}"
}

require_context_helper() {
  local identity parent parent_identity parent_owner parent_mode
  [[ -x "$SUDO_BIN" && -f "$SUDO_BIN" && ! -L "$SUDO_BIN" ]] || fail "$EXIT_UNKNOWN" CONTEXT "sudo is niet veilig beschikbaar: ${SUDO_BIN}"
  [[ -x "$CONTEXT_HELPER" && -f "$CONTEXT_HELPER" && -r "$CONTEXT_HELPER" && ! -L "$CONTEXT_HELPER" ]] || fail "$EXIT_UNKNOWN" CONTEXT "Root-context-helper ontbreekt of is onveilig: ${CONTEXT_HELPER}"
  identity=$(stat -c '%U:%G:%a' "$CONTEXT_HELPER" 2>/dev/null) || fail "$EXIT_UNKNOWN" CONTEXT 'Root-context-helperpermissions konden niet worden bepaald.'
  [[ "$identity" == "${CONTEXT_HELPER_OWNER}:${CONTEXT_HELPER_GROUP}:755" ]] || fail "$EXIT_UNKNOWN" CONTEXT "Root-context-helperpermissions wijken af: ${identity}."
  if [[ ${OPG_WRAPPER_TEST_MODE:-0} != 1 && -w "$CONTEXT_HELPER" ]]; then
    fail "$EXIT_UNKNOWN" CONTEXT 'Root-context-helper is schrijfbaar door de wrappergebruiker.'
  fi
  parent=${CONTEXT_HELPER%/*}
  while :; do
    [[ -d "$parent" && ! -L "$parent" ]] || fail "$EXIT_UNKNOWN" CONTEXT "Helper-parentdirectory ontbreekt of is een symlink: ${parent}"
    parent_identity=$(stat -c '%U:%G:%a' "$parent" 2>/dev/null) || fail "$EXIT_UNKNOWN" CONTEXT "Helper-parentpermissions konden niet worden bepaald: ${parent}"
    parent_owner=${parent_identity%%:*}
    parent_mode=${parent_identity##*:}
    [[ "$parent_owner" == "$CONTEXT_HELPER_OWNER" ]] || fail "$EXIT_UNKNOWN" CONTEXT "Helper-parent is niet van ${CONTEXT_HELPER_OWNER}: ${parent_identity}|${parent}"
    (( (8#$parent_mode & 0022) == 0 )) || fail "$EXIT_UNKNOWN" CONTEXT "Helper-parent is group/world-writable: ${parent_identity}|${parent}"
    if [[ ${OPG_WRAPPER_TEST_MODE:-0} != 1 && -w "$parent" ]]; then
      fail "$EXIT_UNKNOWN" CONTEXT "Helper-parent is schrijfbaar door de wrappergebruiker: ${parent}"
    fi
    [[ "$parent" == "$CONTEXT_HELPER_PARENT_STOP" ]] && break
    [[ "$parent" != / ]] || fail "$EXIT_UNKNOWN" CONTEXT 'Helper-parentgrens werd niet veilig bereikt.'
    parent=${parent%/*}
    [[ -n "$parent" ]] || parent=/
  done
}

require_media_stage_helper() {
  local identity parent parent_identity parent_owner parent_mode
  [[ "$LOCAL_MEDIA_MODE" == required ]] || fail "$EXIT_BLOCKED" MEDIA 'stage-media vereist LOCAL_MEDIA_MODE=required.'
  [[ -x "$SUDO_BIN" && -f "$SUDO_BIN" && ! -L "$SUDO_BIN" ]] || fail "$EXIT_UNKNOWN" MEDIA "sudo is niet veilig beschikbaar: ${SUDO_BIN}"
  [[ -x "$MEDIA_STAGE_HELPER" && -f "$MEDIA_STAGE_HELPER" && -r "$MEDIA_STAGE_HELPER" && ! -L "$MEDIA_STAGE_HELPER" ]] || fail "$EXIT_UNKNOWN" MEDIA "Lokale media-helper ontbreekt of is onveilig: ${MEDIA_STAGE_HELPER}"
  identity=$(stat -c '%U:%G:%a' "$MEDIA_STAGE_HELPER" 2>/dev/null) || fail "$EXIT_UNKNOWN" MEDIA 'Media-helperpermissions konden niet worden bepaald.'
  [[ "$identity" == "${MEDIA_STAGE_HELPER_OWNER}:${MEDIA_STAGE_HELPER_GROUP}:755" ]] || fail "$EXIT_UNKNOWN" MEDIA "Media-helperpermissions wijken af: ${identity}."
  if [[ ${OPG_WRAPPER_TEST_MODE:-0} != 1 && -w "$MEDIA_STAGE_HELPER" ]]; then fail "$EXIT_UNKNOWN" MEDIA 'Media-helper is schrijfbaar door de wrappergebruiker.'; fi
  parent=${MEDIA_STAGE_HELPER%/*}
  while :; do
    [[ -d "$parent" && ! -L "$parent" ]] || fail "$EXIT_UNKNOWN" MEDIA "Media-helper-parent ontbreekt of is een symlink: ${parent}"
    parent_identity=$(stat -c '%U:%G:%a' "$parent" 2>/dev/null) || fail "$EXIT_UNKNOWN" MEDIA "Media-helper-parentpermissions onbekend: ${parent}"
    parent_owner=${parent_identity%%:*}; parent_mode=${parent_identity##*:}
    [[ "$parent_owner" == "$MEDIA_STAGE_HELPER_OWNER" ]] || fail "$EXIT_UNKNOWN" MEDIA "Media-helper-parent heeft verkeerde owner: ${parent_identity}|${parent}"
    (( (8#$parent_mode & 0022) == 0 )) || fail "$EXIT_UNKNOWN" MEDIA "Media-helper-parent is group/world-writable: ${parent_identity}|${parent}"
    [[ "$parent" == "$MEDIA_STAGE_HELPER_PARENT_STOP" ]] && break
    [[ "$parent" != / ]] || fail "$EXIT_UNKNOWN" MEDIA 'Media-helper-parentgrens werd niet bereikt.'
    parent=${parent%/*}; [[ -n "$parent" ]] || parent=/
  done
}

sudo_context_helper() {
  "$SUDO_BIN" -n "$CONTEXT_HELPER" "$@"
}

publish_completion_evidence() {
  local rc=0
  require_context_helper
  sudo_context_helper publish-completion "$RUN_ID" || rc=$?
  if (( rc != 0 )); then
    printf 'OPG_COMPLETION_PUBLISH|run_id=%s|status=FAILED|reason=helper_exit_%s\n' "$RUN_ID" "$rc" >&2
    printf 'OPG_OEM_RESULT|status=UNKNOWN|phase=PUBLISH_COMPLETION|exit_code=%s|run_id=%s\n' "$EXIT_UNKNOWN" "$RUN_ID"
    return "$EXIT_UNKNOWN"
  fi
  printf 'OPG_COMPLETION_PUBLISH|run_id=%s|status=SUCCESS\n' "$RUN_ID"
  return 0
}

clean_oracle_env() {
  /usr/bin/env -i HOME="${HOME:-/tmp}" USER="${USER:-unknown}" LOGNAME="${LOGNAME:-${USER:-unknown}}" LANG=C \
    ORACLE_HOME="$ORACLE_HOME" ORACLE_SID="$ORACLE_SID" LD_LIBRARY_PATH="$LD_LIBRARY_PATH" PATH="$SAFE_PATH" \
    OPG_ROOT="$OPG_ROOT" OPG_APPROVAL_ROOT="$APPROVAL_ROOT" OPG_CONFIG_FILE="$CONFIG_FILE" "$@"
}

run_precheck() {
  local run_stamp precheck_run_id
  discover_all
  run_stamp=${OPG_TEST_PRECHECK_RUN_STAMP:-$(date -u '+%Y%m%dT%H%M%SZ')}
  [[ "$run_stamp" =~ ^[0-9]{8}T[0-9]{6}Z$ ]] || fail "$EXIT_UNKNOWN" PRECHECK 'PRECHECK-tijdstempel is ongeldig.'
  precheck_run_id=${SHORT_HOST}-${ORACLE_SID}-${PATCH_CYCLE}-PRECHECK-${run_stamp}
  [[ "$precheck_run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || fail "$EXIT_BLOCKED" PRECHECK 'Afgeleide PRECHECK RUN_ID is ongeldig of te lang.'
  [[ ! -e "${RUN_ROOT}/${precheck_run_id}" ]] || fail "$EXIT_BLOCKED" PRECHECK "Afgeleide PRECHECK RUN_ID bestaat al: ${precheck_run_id}"
  require_script "$CORE_SCRIPT" core
  clean_oracle_env /bin/bash "$CORE_SCRIPT" precheck --non-interactive --target-oracle-home "$ORACLE_HOME" \
    --run-id "$precheck_run_id" --config "$CONFIG_FILE" "$DB_RU_PATCH_ID" "$OJVM_PATCH_ID" "$PATCH_CYCLE" "$OPATCH_VERSION" "$OPATCH_ZIP"
}

archive_context_for_new_run() {
  local reason=${OPG_NEW_RUN_REASON:-} state old_run
  [[ -n "$reason" && ${#reason} -le 160 && "$reason" =~ ^[A-Za-z0-9][A-Za-z0-9_.:,/@+-]*(\ [A-Za-z0-9_.:,/@+-]+)*$ ]] || fail "$EXIT_USAGE" CONTEXT 'new-run vereist een veilige OPG_NEW_RUN_REASON (maximaal 160 tekens).'
  load_local_paths
  read_context_file
  old_run=$RUN_ID
  state=$(run_state) || fail "$EXIT_UNKNOWN" CONTEXT 'Run-state kon niet worden gelezen.'
  case "$state" in 12_COMPLETE|BLOCKED|UNKNOWN|MANUAL_INTERVENTION_REQUIRED) ;; *) fail "$EXIT_BLOCKED" CONTEXT "Context kan niet worden vernieuwd vanuit niet-terminale state ${state}." ;; esac
  discover_all
  derive_new_context
  [[ "$RUN_ID" != "$old_run" ]] || fail "$EXIT_BLOCKED" CONTEXT 'Nieuwe RUN_ID is gelijk aan de terminale oude RUN_ID.'
  require_context_helper
  if ! emit_context_json | sudo_context_helper rotate "$reason"; then fail "$EXIT_UNKNOWN" CONTEXT 'Terminale context kon niet via de begrensde sudo-helper worden geroteerd.'; fi
  read_context_file
  printf 'OPG_CONTEXT_CREATED|run_id=%s|sid=%s|home=%s|cycle=%s\n' "$RUN_ID" "$ORACLE_SID" "$ORACLE_HOME" "$PATCH_CYCLE"
}

case "$COMMAND" in
  precheck)
    run_precheck
    ;;
  prepare)
    require_script "$PREPARE_SCRIPT" prepare
    /bin/bash "$PREPARE_SCRIPT" || exit $?
    load_or_create_context true
    ;;
  stage-media)
    rc=0
    load_or_create_context false; require_state NONE; require_media_stage_helper
    "$SUDO_BIN" -n "$MEDIA_STAGE_HELPER" stage-active-cycle || rc=$?
    if (( rc != 0 )); then
      if (( rc == EXIT_UNKNOWN )); then fail "$EXIT_UNKNOWN" MEDIA 'Lokale immutable media-stage kon niet betrouwbaar worden uitgevoerd.'; fi
      fail "$EXIT_BLOCKED" MEDIA 'Lokale immutable media-stage kon niet veilig worden gepubliceerd/gevalideerd.'
    fi
    printf 'OPG_OEM_RESULT|status=READY|phase=STAGE_MEDIA|exit_code=0|run_id=%s\n' "$RUN_ID"
    ;;
  create-window)
    load_or_create_context true; require_state NONE; require_script "$WINDOW_SCRIPT" create-window
    /bin/bash "$WINDOW_SCRIPT" "$RUN_ID" "$ORACLE_HOME" "$WINDOW_ID"
    ;;
  assess)
    load_or_create_context true; require_state NONE; require_script "$ASSESS_SCRIPT" assess
    clean_oracle_env /bin/bash "$ASSESS_SCRIPT" "$ORACLE_HOME" "$RUN_ID" "$DB_RU_PATCH_ID" "$OJVM_PATCH_ID" "$PATCH_CYCLE" "$OPATCH_VERSION" "$OPATCH_ZIP" "$CONFIG_FILE"
    ;;
  plan)
    load_or_create_context false; require_state 02_ASSESS_OK; require_script "$CORE_SCRIPT" core
    clean_oracle_env /bin/bash "$CORE_SCRIPT" plan --non-interactive --run-id "$RUN_ID" --config "$CONFIG_FILE"; rc=$?
    if [[ -f "$SUMMARY_SCRIPT" && -r "$SUMMARY_SCRIPT" && ! -L "$SUMMARY_SCRIPT" ]]; then /bin/bash "$SUMMARY_SCRIPT" "${RUN_ROOT}/${RUN_ID}" PLAN || true; fi
    exit "$rc"
    ;;
  stage)
    load_or_create_context false; require_state 03_PLAN_GENERATED; require_script "$STAGE_SCRIPT" stage
    OPG_STAGE_APPROVAL_ROOT="$APPROVAL_ROOT" /bin/bash "$STAGE_SCRIPT" "$RUN_ID"
    ;;
  apply)
    load_or_create_context false; require_state 03_PLAN_GENERATED; require_script "$APPLY_SCRIPT" apply
    rc=0
    clean_oracle_env /bin/bash "$APPLY_SCRIPT" "$RUN_ID" "${APPROVAL_ROOT}/${RUN_ID}/patch_manifest.json" "${APPROVAL_ROOT}/${RUN_ID}/approval.json" "$CONFIG_FILE" || rc=$?
    (( rc == 0 )) || exit "$rc"
    publish_completion_evidence
    ;;
  publish-completion)
    load_or_create_context false; require_state 12_COMPLETE
    publish_completion_evidence
    ;;
  approval-check)
    load_or_create_context false; require_state 03_PLAN_GENERATED; require_script "$APPROVAL_CHECK_SCRIPT" approval-check
    clean_oracle_env /bin/bash "$APPROVAL_CHECK_SCRIPT" "$RUN_ID" "$ORACLE_SID" "$ORACLE_HOME"
    ;;
  show-context)
    load_or_create_context false
    cat "$CONTEXT_FILE"
    ;;
  new-run)
    archive_context_for_new_run
    ;;
esac
