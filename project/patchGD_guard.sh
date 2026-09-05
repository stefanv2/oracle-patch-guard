#!/usr/bin/env bash
# Oracle Patch Guard - veilige, stateful opvolger van patchGD.sh.
# Deze MVP ondersteunt uitsluitend Oracle Database 19c single-instance zonder
# RAC, SEHA, Data Guard, Grid Infrastructure of ASM-afhankelijkheden.

set -u
set -o pipefail
umask 077

SCRIPT_DIR=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=lib/opg_core.sh
source "${SCRIPT_DIR}/lib/opg_core.sh"

usage() {
  cat <<'EOF'
Gebruik:
  patchGD_guard.sh precheck [opties] DB_PATCH OJVM_PATCH MONTH OPATCH_VERSION OPATCH_ZIPFILE
  patchGD_guard.sh assess  [opties] DB_PATCH OJVM_PATCH MONTH OPATCH_VERSION OPATCH_ZIPFILE
  patchGD_guard.sh plan    [opties] DB_PATCH OJVM_PATCH MONTH OPATCH_VERSION OPATCH_ZIPFILE
  patchGD_guard.sh apply   [opties] DB_PATCH OJVM_PATCH MONTH OPATCH_VERSION OPATCH_ZIPFILE
  patchGD_guard.sh status  --run-id RUN_ID
  patchGD_guard.sh resume  [opties] --run-id RUN_ID
  patchGD_guard.sh cleanup [opties] --run-id RUN_ID

Verplichte/bruikbare opties:
  --target-oracle-home PAD   Exacte Oracle Home (verplicht voor precheck/assess)
  --run-id ID                Unieke run-ID
  --config BESTAND           Configuratiebestand
  --dry-run                  Genereer/registreer opdrachten, voer ze niet uit
  --non-interactive          Geen prompt; alle goedkeuringscontroles blijven actief
  --approved-manifest PAD    Centraal goedgekeurd patch_manifest.json
  --approval-token PAD       approval.json met expliciete goedkeuring
  --use-defaults             Gebruik uitsluitend hiermee de historische defaults
  --os-update                Bewust niet ondersteund in deze patch-MVP
  --reboot                   Bewust niet ondersteund in deze patch-MVP

Zonder precies vijf patchparameters of --use-defaults wordt alleen deze usage getoond.
EOF
}

COMMAND=${1:-}
if [[ -z "$COMMAND" ]]; then usage; exit "$EXIT_INVALID_PARAMS"; fi
shift || true

CONFIG_FILE=${OPG_CONFIG_FILE:-/etc/oracle-patch-guard/patchGD_guard.conf}
TARGET_INPUT=
RUN_ID=
DRY_RUN=false
NON_INTERACTIVE=false
USE_DEFAULTS=false
APPROVED_MANIFEST=
APPROVAL_TOKEN=
REQUEST_OS_UPDATE=false
REQUEST_REBOOT=false
POSITIONAL=()

while (( $# > 0 )); do
  case "$1" in
    --target-oracle-home) [[ $# -ge 2 ]] || { usage; exit "$EXIT_INVALID_PARAMS"; }; TARGET_INPUT=$2; shift 2 ;;
    --run-id) [[ $# -ge 2 ]] || { usage; exit "$EXIT_INVALID_PARAMS"; }; RUN_ID=$2; shift 2 ;;
    --config) [[ $# -ge 2 ]] || { usage; exit "$EXIT_INVALID_PARAMS"; }; CONFIG_FILE=$2; shift 2 ;;
    --dry-run) DRY_RUN=true; shift ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    --approved-manifest) [[ $# -ge 2 ]] || { usage; exit "$EXIT_INVALID_PARAMS"; }; APPROVED_MANIFEST=$2; shift 2 ;;
    --approval-token) [[ $# -ge 2 ]] || { usage; exit "$EXIT_INVALID_PARAMS"; }; APPROVAL_TOKEN=$2; shift 2 ;;
    --use-defaults) USE_DEFAULTS=true; shift ;;
    --os-update) REQUEST_OS_UPDATE=true; shift ;;
    --reboot) REQUEST_REBOOT=true; shift ;;
    -h|--help) usage; exit 0 ;;
    --*) printf 'Onbekende optie: %s\n' "$1" >&2; usage; exit "$EXIT_INVALID_PARAMS" ;;
    *) POSITIONAL+=("$1"); shift ;;
  esac
done

# Veilige ingebouwde configuratie; lokale config overschrijft deze waarden.
PATCH_ROOT=
OPATCH_ROOT=
RUN_ROOT=/var/log/oracle-patch-guard
LOCK_ROOT=/var/lock/oracle-patch-guard
ORATAB_FILE=/etc/oratab
ORAINST_LOC=/etc/oraInst.loc
EXPECTED_ORACLE_OWNER=
ASSESSMENT_MAX_AGE_MINUTES=60
MIN_HOME_FREE_MB=10240
MIN_INVENTORY_FREE_MB=2048
MIN_STAGE_FREE_MB=15360
MIN_TMP_FREE_MB=2048
OPATCH_UPGRADE_MIN_FREE_MB=1024
COMMAND_TIMEOUT_SECONDS=7200
# Publieke configuratie-interface voor organisatiechecks; bewust behouden.
# shellcheck disable=SC2034
SQLPLUS_TIMEOUT_SECONDS=900
# Wordt indirect gelezen door de ingeladen core-library.
# shellcheck disable=SC2034
INTEGRITY_CHECK_TIMEOUT_SECONDS=1800
LISTENER_STOP_TIMEOUT_SECONDS=30
LISTENER_READY_TIMEOUT_SECONDS=60
LISTENER_POLL_SECONDS=2
ROLLBACK_RETENTION_HOURS=168
SAFE_PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
EMCTL_PATH=
MANAGE_LISTENERS=true
LISTENER_NAMES="LISTENER"
BACKUP_CHECK_COMMAND=
ORACLE_HOME_RECOVERY_CHECK_COMMAND=
MAINTENANCE_WINDOW_CHECK_COMMAND=
# Gereserveerde configuratie-interface; de MVP gebruikt de ingebouwde SQL-controle.
# shellcheck disable=SC2034
DATAPUMP_CHECK_COMMAND=
DATAGUARD_CHECK_COMMAND=
RECOVERY_BASE_IMAGE=
RECOVERY_BASE_IMAGE_SHA256=
OPATCH_ZIP_SHA256=
HOME_RECOVERY_PROCEDURE=
HOME_REBUILD_MIN_FREE_MB=30720
MAINTENANCE_WINDOW_MANIFEST=
APPROVAL_PUBLIC_KEY=
LOCAL_MEDIA_MODE=disabled
LOCAL_STAGE_ROOT=/u01/stage/oracle-patch-guard
MEDIA_STAGE_HELPER=/usr/local/sbin/opg_media_stage_root.sh
ALLOW_TEST_MODE=false
DEFAULT_DB_PATCH=39472050
DEFAULT_OJVM_PATCH=39222882
DEFAULT_MONTH=JUL2026
DEFAULT_OPATCH_VERSION=12.2.0.1.52
DEFAULT_OPATCH_ZIPFILE=p6880880_190000_Linux-x86-64.zip

validate_config_trust() {
  local file=$1 owner mode group_digit other_digit current_user
  [[ -f "$file" && ! -L "$file" && -r "$file" ]] || return 1
  owner=$(stat -c '%U' "$file" 2>/dev/null) || return 1
  mode=$(stat -c '%a' "$file" 2>/dev/null) || return 1
  current_user=$(id -un)
  group_digit=${mode: -2:1}; other_digit=${mode: -1}
  [[ "$group_digit" =~ ^[0-7]$ && "$other_digit" =~ ^[0-7]$ ]] || return 1
  (( (group_digit & 2) == 0 && (other_digit & 2) == 0 )) || return 1
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then [[ "$owner" == "$current_user" || "$owner" == root ]]; else [[ "$owner" == root ]]; fi
}

if [[ -r "$CONFIG_FILE" ]]; then
  validate_config_trust "$CONFIG_FILE" || { printf 'Configuratiebestand heeft een onveilige eigenaar, mode of symlinkstatus: %s\n' "$CONFIG_FILE" >&2; exit "$EXIT_INVALID_PARAMS"; }
  # Beheerdersconfiguratie is vertrouwde code; productie vereist root-eigendom.
  # shellcheck disable=SC1090
  source "$CONFIG_FILE"
elif [[ "$CONFIG_FILE" != /etc/oracle-patch-guard/patchGD_guard.conf || ${OPG_TEST_MODE:-0} != 1 ]]; then
  printf 'Configuratiebestand niet leesbaar: %s\n' "$CONFIG_FILE" >&2
  exit "$EXIT_INVALID_PARAMS"
fi
for required_path_setting in PATCH_ROOT OPATCH_ROOT RUN_ROOT LOCK_ROOT; do
  required_path_value=${!required_path_setting:-}
  [[ "$required_path_value" == /* && "$required_path_value" =~ ^/[A-Za-z0-9_./-]+$ &&
     "$required_path_value" != *'//'* && "$required_path_value" != */../* &&
     "$required_path_value" != */./* && "$required_path_value" != */.. && "$required_path_value" != */. ]] || {
    printf 'Ontbrekend of ongeldig absoluut runtimepad voor %s.\n' "$required_path_setting" >&2
    exit "$EXIT_INVALID_PARAMS"
  }
done
for numeric_setting in INTEGRITY_CHECK_TIMEOUT_SECONDS LISTENER_STOP_TIMEOUT_SECONDS LISTENER_READY_TIMEOUT_SECONDS LISTENER_POLL_SECONDS; do
  [[ ${!numeric_setting:-} =~ ^[1-9][0-9]*$ ]] || { printf 'Ongeldige positieve integer voor %s.\n' "$numeric_setting" >&2; exit "$EXIT_INVALID_PARAMS"; }
done
[[ "$OPATCH_UPGRADE_MIN_FREE_MB" =~ ^[0-9]+$ ]] || { printf 'Ongeldige niet-negatieve integer voor OPATCH_UPGRADE_MIN_FREE_MB.\n' >&2; exit "$EXIT_INVALID_PARAMS"; }
export PATH=$SAFE_PATH

if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
  LOCAL_STAGE_ROOT=${OPG_TEST_LOCAL_STAGE_ROOT:-$LOCAL_STAGE_ROOT}
  MEDIA_STAGE_HELPER=${OPG_TEST_MEDIA_STAGE_HELPER:-$MEDIA_STAGE_HELPER}
else
  LOCAL_STAGE_ROOT=/u01/stage/oracle-patch-guard
  MEDIA_STAGE_HELPER=/usr/local/sbin/opg_media_stage_root.sh
fi
[[ "$LOCAL_MEDIA_MODE" == disabled || "$LOCAL_MEDIA_MODE" == required ]] || { printf 'LOCAL_MEDIA_MODE moet disabled of required zijn.\n' >&2; exit "$EXIT_INVALID_PARAMS"; }
if [[ ${OPG_TEST_MODE:-0} != 1 && "$LOCAL_MEDIA_MODE" != required ]]; then
  printf 'Pilot07 productie weigert legacy/share-media: LOCAL_MEDIA_MODE=required is verplicht.\n' >&2
  exit "$EXIT_INVALID_PARAMS"
fi

if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
  opg_test_fixture_load || exit "$EXIT_INVALID_PARAMS"
fi

HOST_NAME=${OPG_HOSTNAME_OVERRIDE:-$(hostname -f 2>/dev/null || hostname)}
EXEC_USER=${OPG_USER_OVERRIDE:-$(id -un)}

if [[ -z "$RUN_ID" && "$COMMAND" =~ ^(precheck|assess|plan)$ ]]; then
  if [[ "$COMMAND" == precheck ]]; then
    RUN_ID="PRECHECK-$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  else
    RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
  fi
fi
if [[ -z "$RUN_ID" ]] || ! opg_validate_run_id "$RUN_ID"; then
  printf 'Een geldige --run-id is verplicht.\n' >&2
  usage
  exit "$EXIT_INVALID_PARAMS"
fi
RUN_DIR="${RUN_ROOT}/${RUN_ID}"

load_patch_parameters() {
  if (( ${#POSITIONAL[@]} == 5 )); then
    DB_PATCH=${POSITIONAL[0]}; OJVM_PATCH=${POSITIONAL[1]}; MONTH=${POSITIONAL[2]}
    OPATCH_VERSION=${POSITIONAL[3]}; OPATCH_ZIPFILE=${POSITIONAL[4]}
  elif (( ${#POSITIONAL[@]} == 0 )) && [[ "$USE_DEFAULTS" == true ]]; then
    DB_PATCH=$DEFAULT_DB_PATCH; OJVM_PATCH=$DEFAULT_OJVM_PATCH; MONTH=$DEFAULT_MONTH
    OPATCH_VERSION=$DEFAULT_OPATCH_VERSION; OPATCH_ZIPFILE=$DEFAULT_OPATCH_ZIPFILE
  elif [[ "$COMMAND" =~ ^(plan|apply|status|resume|cleanup)$ ]] && (( ${#POSITIONAL[@]} == 0 )); then
    return 0
  else
    usage; return "$EXIT_INVALID_PARAMS"
  fi
  opg_validate_patch_value "$DB_PATCH" || return "$EXIT_INVALID_PARAMS"
  opg_validate_patch_value "$OJVM_PATCH" || return "$EXIT_INVALID_PARAMS"
  opg_validate_month "$MONTH" || return "$EXIT_INVALID_PARAMS"
  opg_validate_version "$OPATCH_VERSION" || return "$EXIT_INVALID_PARAMS"
  opg_validate_zip_name "$OPATCH_ZIPFILE" || return "$EXIT_INVALID_PARAMS"
}

if ! load_patch_parameters; then
  printf 'Ongeldige patchparameters.\n' >&2
  exit "$EXIT_INVALID_PARAMS"
fi

initialize_local_media() {
  local output status cycle identity patch_root opatch_root artifact_hash key_hash format db_hash ojvm_hash zip_hash extra
  [[ "$LOCAL_MEDIA_MODE" == required ]] || return 0
  opg_acquire_media_lock || return $?
  [[ ${MONTH:-} =~ ^[A-Z][A-Z0-9_-]{2,31}$ ]] || return 1
  validate_media_helper_trust || return 1
  output=$("$MEDIA_STAGE_HELPER" verify-active-stage "$MONTH" 2>>"${RUN_DIR:-/tmp}/media_stage_verify.err") || return 1
  IFS='|' read -r status cycle identity patch_root opatch_root artifact_hash key_hash format db_hash ojvm_hash zip_hash extra <<<"$output"
  [[ -z "$extra" && "$status" == READY && "$cycle" == "$MONTH" ]] || return 1
  [[ "$identity" =~ ^[0-9a-f]{64}$ && "$identity" == "$artifact_hash" && "$key_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$format" == OPG_TREE_HASH_V2 && "$db_hash" =~ ^[0-9a-f]{64}$ && "$ojvm_hash" =~ ^[0-9a-f]{64}$ && "$zip_hash" =~ ^[0-9a-f]{64}$ ]] || return 1
  [[ "$patch_root" == "${LOCAL_STAGE_ROOT}/ready/${MONTH}/${identity}/media" && "$opatch_root" == "${LOCAL_STAGE_ROOT}/ready/${MONTH}/${identity}/opatch" ]] || return 1
  [[ -d "$patch_root" && ! -L "$patch_root" && -d "$opatch_root" && ! -L "$opatch_root" ]] || return 1
  PATCH_ROOT=$patch_root; OPATCH_ROOT=$opatch_root
  LOCAL_MEDIA_IDENTITY=$identity; LOCAL_ARTIFACT_MANIFEST_SHA256=$artifact_hash
  LOCAL_ARTIFACT_KEY_SHA256=$key_hash; LOCAL_TREE_HASH_FORMAT=$format
  LOCAL_DB_TREE_SHA256=$db_hash; LOCAL_OJVM_TREE_SHA256=$ojvm_hash; LOCAL_OPATCH_ZIP_SHA256=$zip_hash
  export PATCH_ROOT OPATCH_ROOT
}

validate_media_helper_trust() {
  local expected_owner expected_group identity parent parent_identity owner mode
  [[ -x "$MEDIA_STAGE_HELPER" && -f "$MEDIA_STAGE_HELPER" && ! -L "$MEDIA_STAGE_HELPER" ]] || return 1
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then expected_owner=$(id -un); expected_group=$(id -gn); else expected_owner=root; expected_group=root; fi
  identity=$(stat -c '%U:%G:%a' "$MEDIA_STAGE_HELPER" 2>/dev/null) || return 1
  [[ "$identity" == "${expected_owner}:${expected_group}:755" ]] || return 1
  [[ ${OPG_TEST_MODE:-0} == 1 ]] || [[ ! -w "$MEDIA_STAGE_HELPER" ]] || return 1
  [[ ${OPG_TEST_MODE:-0} == 1 ]] && return 0
  parent=${MEDIA_STAGE_HELPER%/*}
  while :; do
    [[ -d "$parent" && ! -L "$parent" ]] || return 1
    parent_identity=$(stat -c '%U:%a' "$parent" 2>/dev/null) || return 1
    owner=${parent_identity%%:*}; mode=${parent_identity##*:}
    [[ "$owner" == root && "$mode" =~ ^[0-7]{3,4}$ ]] || return 1
    (( (8#$mode & 0022) == 0 )) || return 1
    [[ "$parent" == / ]] && break
    parent=${parent%/*}; [[ -n "$parent" ]] || parent=/
  done
}

load_run_context() {
  local state_file="${RUN_DIR}/execution_state.json" manifest="${RUN_DIR}/patch_manifest.json"
  [[ -r "$state_file" && -r "$manifest" ]] || return 1
  TARGET_ORACLE_HOME=$(opg_get_json_string "$state_file" target_oracle_home)
  DB_PATCH=$(opg_get_json_string "$manifest" db_patch)
  OJVM_PATCH=$(opg_get_json_string "$manifest" ojvm_patch)
  MONTH=$(opg_get_json_string "$manifest" month)
  OPATCH_VERSION=$(opg_get_json_string "$manifest" required_opatch_version)
  OPATCH_ZIPFILE=$(opg_get_json_string "$manifest" opatch_zipfile)
  OPATCH_ACTUAL_VERSION=$(opg_get_json_string "$manifest" assessed_opatch_version)
  OPATCH_UPGRADE_REQUIRED=$(opg_get_json_boolean "$manifest" opatch_upgrade_required)
  opg_load_state
}

init_new_run() {
  [[ -n "$TARGET_INPUT" ]] || { printf '%s\n' '--target-oracle-home is verplicht.' >&2; return "$EXIT_INVALID_PARAMS"; }
  [[ "$TARGET_INPUT" =~ ^/[A-Za-z0-9_./-]+$ ]] || { printf 'Doel-Oracle Home bevat niet-toegestane tekens.\n' >&2; return "$EXIT_INVALID_PARAMS"; }
  TARGET_ORACLE_HOME=$(opg_canonical_dir "$TARGET_INPUT") || {
    printf 'Doel-Oracle Home bestaat niet of is niet canoniek oplosbaar: %s\n' "$TARGET_INPUT" >&2
    return "$EXIT_BLOCKED"
  }
  if [[ -e "$RUN_DIR" ]]; then
    printf 'Run-ID bestaat al; gebruik status/resume en start niet opnieuw: %s\n' "$RUN_ID" >&2
    return "$EXIT_BLOCKED"
  fi
  mkdir -p -- "$RUN_ROOT" || return "$EXIT_BLOCKED"
  # De tweede mkdir is bewust niet idempotent: twee gelijktijdige processen met
  # dezelfde run-ID mogen nooit samen dezelfde statebestanden schrijven.
  mkdir -- "$RUN_DIR" 2>/dev/null || return "$EXIT_BLOCKED"
  chmod 0700 "$RUN_DIR" 2>/dev/null || true
  : >"${RUN_DIR}/commands.log"; : >"${RUN_DIR}/state_history.log"
  CURRENT_STATE=NONE; CURRENT_PHASE=ASSESS
}

write_sql_files() {
  opg_atomic_write "${RUN_DIR}/inventory.sql" <<'SQL'
set pages 0 feedback off heading off verify off echo off trimspool on lines 32767
whenever sqlerror exit failure rollback
select 'DB|'||name||'|'||database_role||'|'||open_mode||'|'||cdb from v$database;
select 'PDB|'||listagg(name||'='||open_mode, ';') within group(order by con_id) from v$pdbs where con_id > 2;
select 'SERVICES|'||listagg(name, ';') within group(order by name) from v$active_services where name not like 'SYS$%';
select 'INVALID|'||count(*) from dba_objects where status='INVALID';
select 'COMPONENT_INVALID|'||count(*) from dba_registry where status in ('INVALID','LOADING','UPGRADING','DOWNGRADING','REMOVING');
select 'REGISTRY|'||comp_id||'|'||status from dba_registry order by comp_id;
select 'CDB_REGISTRY|'||con_id||'|'||comp_id||'|'||status from cdb_registry order by con_id, comp_id;
select 'SQLPATCH_ERRORS|'||count(*) from (select patch_id, action, status, row_number() over (partition by patch_id, action order by action_time desc) rn from dba_registry_sqlpatch) where rn = 1 and status <> 'SUCCESS';
select 'DATAPUMP|'||count(*) from dba_datapump_jobs where state not in ('NOT RUNNING','COMPLETED');
select 'DATAPUMP_JOB|'||owner_name||'|'||job_name||'|'||operation||'|'||job_mode||'|'||state
from dba_datapump_jobs where state not in ('NOT RUNNING','COMPLETED') order by owner_name, job_name;
select 'ASM_FILES|'||count(*) from v$datafile where name like '+%';
exit success
SQL
  opg_atomic_write "${RUN_DIR}/shutdown.sql" <<'SQL'
whenever sqlerror exit failure rollback
shutdown immediate;
exit success
SQL
  opg_atomic_write "${RUN_DIR}/startup.sql" <<'SQL'
whenever sqlerror exit failure rollback
startup;
exit success
SQL
  opg_atomic_write "${RUN_DIR}/startup_verify.sql" <<'SQL'
set pages 0 feedback off heading off verify off echo off trimspool on lines 32767
whenever sqlerror exit failure rollback
select 'STARTUP_STATE|'||i.status||'|'||i.database_status||'|'||d.open_mode
from v$instance i cross join v$database d;
exit success
SQL
  opg_atomic_write "${RUN_DIR}/alter_system_register.sql" <<'SQL'
whenever sqlerror exit failure rollback
alter system register;
exit success
SQL
  opg_atomic_write "${RUN_DIR}/datapatch_containers.sql" <<'SQL'
set pages 0 feedback off heading off verify off echo off trimspool on lines 32767
whenever sqlerror exit failure rollback
select 'DATAPATCH_CONTAINER|'||con_id||'|'||name||'|'||open_mode
from v$containers where con_id = 1 or con_id > 2 order by con_id;
exit success
SQL
  opg_atomic_write "${RUN_DIR}/datapatch_sqlpatch_cdb.sql" <<SQL
set pages 0 feedback off heading off verify off echo off trimspool on lines 32767
whenever sqlerror exit failure rollback
select 'CDB_SQLPATCH|'||r.con_id||'|'||c.name||'|'||r.patch_id||'|'||r.action||'|'||r.status||'|'||
       to_char(r.action_time,'YYYYMMDDHH24MISSFF6')
from cdb_registry_sqlpatch r join v\$containers c on c.con_id=r.con_id
where r.patch_id in (${DB_PATCH},${OJVM_PATCH})
  and (r.con_id = 1 or r.con_id > 2)
  and r.action_time = (
    select max(x.action_time) from cdb_registry_sqlpatch x
    where x.con_id=r.con_id and x.patch_id=r.patch_id
  )
order by r.con_id, r.patch_id;
exit success
SQL
  opg_atomic_write "${RUN_DIR}/datapatch_sqlpatch_noncdb.sql" <<SQL
set pages 0 feedback off heading off verify off echo off trimspool on lines 32767
whenever sqlerror exit failure rollback
select 'CDB_SQLPATCH|0|NONCDB|'||r.patch_id||'|'||r.action||'|'||r.status||'|'||
       to_char(r.action_time,'YYYYMMDDHH24MISSFF6')
from dba_registry_sqlpatch r
where r.patch_id in (${DB_PATCH},${OJVM_PATCH})
  and r.action_time = (
    select max(x.action_time) from dba_registry_sqlpatch x where x.patch_id=r.patch_id
  )
order by r.patch_id;
exit success
SQL
  opg_atomic_write "${RUN_DIR}/validate.sql" <<SQL
set pages 0 feedback off heading off verify off echo off trimspool on lines 32767
whenever sqlerror exit failure rollback
select 'REGISTRY|'||comp_id||'|'||status from dba_registry order by comp_id;
select 'INVALID|'||count(*) from dba_objects where status='INVALID';
select 'CDB|'||cdb from v\$database;
select 'DB|'||name||'|'||database_role||'|'||open_mode||'|'||cdb from v\$database;
select 'PDB|'||listagg(name||'='||open_mode, ';') within group(order by con_id) from v\$pdbs where con_id > 2;
select 'SERVICES|'||listagg(name, ';') within group(order by name) from v\$active_services where name not like 'SYS$%';
select 'CDB_REGISTRY|'||con_id||'|'||comp_id||'|'||status from cdb_registry order by con_id, comp_id;
exit success
SQL
  opg_atomic_write "${RUN_DIR}/utlrp_wrapper.sql" <<'SQL'
whenever sqlerror exit failure rollback
@?/rdbms/admin/utlrp.sql
exit success
SQL
}

check_path_space() {
  local path=$1 minimum=$2 id=$3 description=$4 free
  free=$(opg_free_mb "$path")
  if [[ -z "$free" || ! "$free" =~ ^[0-9]+$ ]]; then
    opg_add_finding UNKNOWN "$id" "Vrije ruimte kon niet worden vastgesteld voor ${description}." "$path"
  elif (( free < minimum )); then
    opg_add_finding BLOCKED "$id" "Onvoldoende vrije ruimte voor ${description}: ${free} MiB, minimaal ${minimum} MiB." "$path"
  else
    opg_add_finding READY "$id" "Voldoende vrije ruimte voor ${description}: ${free} MiB." "$path"
  fi
}

run_optional_check() {
  local name=$1 command_text=$2 required=$3 mock_key=${4:-$1} output rc execute_in_test=false
  # Positie 3 blijft bewust onderdeel van de bestaande check-interface.
  : "$required"
  output="${RUN_DIR}/${name}.txt"
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    local variable value
    variable="MOCK_CHECK_${mock_key^^}"
    value=${!variable:-UNKNOWN}
    if [[ "$value" == EXECUTE ]]; then
      execute_in_test=true
    else
      printf '%s\n' "$value" >"$output"
      case "$value" in
        VERIFIED|OK|HEALTHY|NONE) return 0 ;;
        BLOCKED|UNHEALTHY|ACTIVE) return 2 ;;
        *) return 3 ;;
      esac
    fi
  fi
  if [[ -z "$command_text" ]]; then
    printf 'NOT_CONFIGURED\n' >"$output"; return 3
  fi
  # Organisatiespecifieke commando's worden uitsluitend als vooraf beheerde,
  # argumentloze executables geaccepteerd; geen eval of shellfragmenten.
  [[ "$command_text" =~ ^/[A-Za-z0-9_./-]+$ && -x "$command_text" ]] || { printf 'INVALID_CHECK_COMMAND\n' >"$output"; return 3; }
  export TARGET_ORACLE_HOME RUN_DIR RUN_ID HOST_NAME DB_PATCH OJVM_PATCH MONTH OPATCH_VERSION OPATCH_ZIPFILE
  export PATCH_ROOT OPATCH_ROOT ORATAB_FILE ORAINST_LOC BACKUP_CHECK_COMMAND
  export RECOVERY_BASE_IMAGE RECOVERY_BASE_IMAGE_SHA256 OPATCH_ZIP_SHA256 HOME_RECOVERY_PROCEDURE HOME_REBUILD_MIN_FREE_MB
  export MAINTENANCE_WINDOW_MANIFEST OPG_CHECK_PHASE OPG_WINDOW_BINDING_MODE RECOVERY_MANIFEST_FILE
  if [[ "$execute_in_test" == true ]]; then
    OPG_TEST_EXECUTE_CAPTURE=true opg_run_capture "$name" "$output" "$command_text"; rc=$?
  else
    opg_run_capture "$name" "$output" "$command_text"; rc=$?
  fi
  return "$rc"
}

approval_public_key_sha256() {
  [[ -n "$APPROVAL_PUBLIC_KEY" && "$APPROVAL_PUBLIC_KEY" == /* ]] || return 1
  [[ -f "$APPROVAL_PUBLIC_KEY" && -r "$APPROVAL_PUBLIC_KEY" && ! -L "$APPROVAL_PUBLIC_KEY" ]] || return 1
  opg_sha256 "$APPROVAL_PUBLIC_KEY"
}

check_datapump_evidence() {
  local phase=$1 evidence_file sid running source count jobs checked=0 blocked=0 unknown=0
  evidence_file="${RUN_DIR}/${phase}_datapump.txt"
  : >"$evidence_file"
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    local value=${MOCK_CHECK_DATAPUMP:-NONE}
    [[ "$phase" == preapply && ${MOCK_PREAPPLY_DATAPUMP:-false} == true ]] && value=ACTIVE
    case "$value" in
      NONE) printf 'READY|all_running_databases|active_jobs=0\n' >"$evidence_file"; return 0 ;;
      ACTIVE) printf 'ACTIVE|SID=DB1|owner=MOCK|job=SYS_EXPORT_SCHEMA_01|operation=EXPORT|job_mode=SCHEMA|state=EXECUTING\n' >"$evidence_file"; return 2 ;;
      *) printf 'UNKNOWN|mock_result=%s\n' "$value" >"$evidence_file"; return 3 ;;
    esac
  fi
  while IFS= read -r sid; do
    running=$(opg_read_original_state "$sid" running)
    [[ "$running" == true ]] || continue
    checked=$((checked + 1))
    if [[ "$phase" == assess ]]; then source="${RUN_DIR}/inventory_${sid}.txt"; else source="${RUN_DIR}/preapply_recheck_${sid}.log"; fi
    if [[ ! -r "$source" ]]; then
      printf 'UNKNOWN|SID=%s|reason=inventory_output_unreadable|source=%s\n' "$sid" "$source" >>"$evidence_file"; unknown=1; continue
    fi
    count=$(grep '^DATAPUMP|' "$source" | tail -1 | cut -d'|' -f2)
    if [[ ! "$count" =~ ^[0-9]+$ ]]; then
      printf 'UNKNOWN|SID=%s|reason=invalid_count|source=%s\n' "$sid" "$source" >>"$evidence_file"; unknown=1; continue
    fi
    jobs=$(grep -c '^DATAPUMP_JOB|' "$source" 2>/dev/null || true)
    if (( jobs != count )); then
      printf 'UNKNOWN|SID=%s|reason=count_evidence_mismatch|count=%s|job_rows=%s\n' "$sid" "$count" "$jobs" >>"$evidence_file"; unknown=1; continue
    fi
    if (( count > 0 )); then
      grep '^DATAPUMP_JOB|' "$source" | while IFS='|' read -r _ owner job operation job_mode state; do
        printf 'ACTIVE|SID=%s|owner=%s|job=%s|operation=%s|job_mode=%s|state=%s\n' "$sid" "$owner" "$job" "$operation" "$job_mode" "$state"
      done >>"$evidence_file"
      blocked=1
    else
      printf 'READY|SID=%s|active_jobs=0\n' "$sid" >>"$evidence_file"
    fi
  done < <(opg_manifest_sids)
  (( checked > 0 )) || printf 'READY|no_running_databases|active_jobs=0\n' >>"$evidence_file"
  (( blocked == 0 )) || return 2
  (( unknown == 0 )) || return 3
  return 0
}

normalize_registry_components() {
  local sid=$1 cdb=$2 source=$3 destination=$4 rc
  : >"$destination"
  awk -F'|' -v sid="$sid" -v cdb="$cdb" '
    function classify(status) {
      if (status=="VALID" || status=="OPTION OFF") return 0
      if (status ~ /^(INVALID|LOADING|LOADED|UPGRADING|UPGRADED|DOWNGRADING|DOWNGRADED|REMOVING|REMOVED)$/) return 2
      return 3
    }
    $1=="REGISTRY" {
      if (NF!=3 || $2=="" || $3=="") { parse_bad=1; next }
      key="REGISTRY" SUBSEP "0" SUBSEP $2
      if (seen[key]++) { parse_bad=1; next }
      print sid "|REGISTRY|0|" $2 "|" $3
      db_rows++
      state=classify($3); if (state==2) unhealthy=1; else if (state==3) unknown=1
      next
    }
    $1=="CDB_REGISTRY" && cdb=="YES" {
      if (NF!=4 || $2 !~ /^[0-9]+$/ || $3=="" || $4=="") { parse_bad=1; next }
      key="CDB_REGISTRY" SUBSEP $2 SUBSEP $3
      if (seen[key]++) { parse_bad=1; next }
      print sid "|CDB_REGISTRY|" $2 "|" $3 "|" $4
      cdb_rows++
      state=classify($4); if (state==2) unhealthy=1; else if (state==3) unknown=1
      next
    }
    END {
      if (parse_bad || unknown || db_rows==0 || (cdb=="YES" && cdb_rows==0)) exit 3
      if (unhealthy) exit 2
    }
  ' "$source" >"$destination"
  rc=$?
  LC_ALL=C sort -t'|' -k1,1 -k2,2 -k3,3n -k4,4 -o "$destination" "$destination"
  return "$rc"
}

write_mock_registry_inventory() {
  local cdb=$1 destination=$2 rows
  [[ ${MOCK_REGISTRY_QUERY_FAILED:-false} != true ]] || return 1
  rows=${MOCK_REGISTRY_BEFORE:-REGISTRY|CATALOG|VALID}
  printf '%s\n' "$rows" | tr ';' '\n' >"$destination"
  if [[ -z ${MOCK_REGISTRY_BEFORE:-} && "$cdb" == YES ]]; then
    printf 'CDB_REGISTRY|1|CATALOG|VALID\n' >>"$destination"
  fi
}

record_registry_baseline() {
  local sid=$1 cdb=$2 source=$3 rc
  local normalized="${RUN_DIR}/registry_components_${sid}.psv"
  normalize_registry_components "$sid" "$cdb" "$source" "$normalized"; rc=$?
  cat "$normalized" >>"${RUN_DIR}/registry_components_before.psv"
  case "$rc" in
    0) return 0 ;;
    2) opg_add_finding BLOCKED REGISTRY_COMPONENT_UNHEALTHY "Vooraf bestaande Oracle-componentstatus is ongezond." "$normalized" ;;
    *) opg_add_finding UNKNOWN REGISTRY_COMPONENT_UNKNOWN "Oracle-componentstatus kon niet betrouwbaar worden geïnterpreteerd." "$source" ;;
  esac
  return "$rc"
}

compare_registry_with_baseline() {
  local sid=$1 cdb=$2 source=$3 phase=$4 current expected rc
  current="${RUN_DIR}/registry_components_${phase}_${sid}.psv"
  expected="${RUN_DIR}/registry_components_expected_${sid}.psv"
  normalize_registry_components "$sid" "$cdb" "$source" "$current"; rc=$?
  awk -F'|' -v sid="$sid" '$1==sid' "${RUN_DIR}/registry_components_before.psv" >"$expected"
  cat "$current" >>"${RUN_DIR}/registry_components_${phase}.psv"
  if (( rc != 0 )); then
    opg_log ERROR "REGISTRY_BASELINE_COMPARE_FAILED|sid=${sid}|phase=${phase}|reason=current_unhealthy_or_unreliable|rc=${rc}"
    return 1
  fi
  if ! cmp -s -- "$expected" "$current"; then
    opg_log ERROR "REGISTRY_BASELINE_COMPARE_FAILED|sid=${sid}|phase=${phase}|reason=component_set_or_status_changed|expected=${expected}|actual=${current}"
    return 1
  fi
  opg_log INFO "REGISTRY_BASELINE_COMPARE_OK|sid=${sid}|phase=${phase}"
}

inventory_databases() {
  local parsed="${RUN_DIR}/oratab_selected.psv" all="${RUN_DIR}/oratab_all.psv"
  local sid home autostart count=0 running role mode cdb pdb listener services invalid component_invalid sqlpatch_errors asm_files output detected_listeners='' listener_name pmon_pid pmon_exe
  opg_parse_oratab "$all" || return 1
  awk -F'|' -v home="$TARGET_ORACLE_HOME" '$2==home' "$all" >"$parsed"
  printf 'SID,ORACLE_HOME,oratab_autostart,instance_running,database_role,open_mode,CDB,PDB_status,listener,services\n' >"${RUN_DIR}/database_state_before.csv"
  printf 'SID,invalid_objects\n' >"${RUN_DIR}/invalid_objects_before.csv"
  printf 'SID,patch_id,status,action_time\n' >"${RUN_DIR}/sqlpatch_before.csv"
  : >"${RUN_DIR}/registry_components_before.psv"

  if [[ ${OPG_TEST_MODE:-0} != 1 && "$MANAGE_LISTENERS" == true ]]; then
    for listener_name in $LISTENER_NAMES; do
      [[ "$listener_name" =~ ^[A-Za-z0-9_.-]+$ ]] || { opg_add_finding BLOCKED INVALID_LISTENER_NAME "Ongeldige geconfigureerde listenernaam." "$listener_name"; continue; }
      output="${RUN_DIR}/listener_status_before_${listener_name}.log"
      if opg_run_capture "listener_status_${listener_name}" "$output" "$TARGET_ORACLE_HOME/bin/lsnrctl" status "$listener_name" && ! grep -Eiq 'TNS-|NL-|no listener' "$output"; then
        if listener_running_from_target_home "$listener_name"; then
          detected_listeners+="${detected_listeners:+;}${listener_name}"
        else
          opg_add_finding BLOCKED LISTENER_HOME_MISMATCH "Actieve listener draait niet aantoonbaar uit de doelhome." "$listener_name"
        fi
      fi
    done
  fi

  if [[ ${OPG_TEST_MODE:-0} == 1 && -n ${OPG_FIXTURE_DIR:-} && -r ${OPG_FIXTURE_DIR}/database_inventory.csv ]]; then
    cp -- "${OPG_FIXTURE_DIR}/database_inventory.csv" "${RUN_DIR}/database_state_before.csv"
    count=$(awk 'END{print NR-1}' "${RUN_DIR}/database_state_before.csv")
    while IFS=, read -r sid home autostart running role mode cdb pdb listener services; do
      [[ "$sid" == SID ]] && continue
      sid=${sid//\"/}; role=${role//\"/}; running=${running//\"/}; cdb=${cdb//\"/}
      printf '"%s","%s"\n' "$sid" "${MOCK_INVALID_OBJECTS:-0}" >>"${RUN_DIR}/invalid_objects_before.csv"
      output="${RUN_DIR}/registry_inventory_${sid}.log"
      if write_mock_registry_inventory "$cdb" "$output"; then
        record_registry_baseline "$sid" "$cdb" "$output" || true
      else
        opg_add_finding UNKNOWN REGISTRY_QUERY_FAILED "Oracle-componentinventarisatie kon niet veilig worden uitgevoerd." "$sid"
      fi
      [[ "$running" == true && "$role" != PRIMARY ]] && opg_add_finding BLOCKED DATA_GUARD_UNSUPPORTED "Data Guard-role ${role} is niet ondersteund in deze MVP." "$sid"
    done <"${RUN_DIR}/database_state_before.csv"
  else
    while IFS='|' read -r sid home autostart; do
      [[ -n "$sid" ]] || continue
      count=$((count + 1)); running=false; role=UNKNOWN; mode=STOPPED; cdb=UNKNOWN; pdb=; listener=${detected_listeners:-NONE}; services=; invalid=UNKNOWN
      if pgrep -f "ora_pmon_${sid}([^A-Za-z0-9_]|$)" >/dev/null 2>&1; then
        running=true; output="${RUN_DIR}/inventory_${sid}.txt"
        pmon_pid=$(pgrep -f "ora_pmon_${sid}([^A-Za-z0-9_]|$)" | head -1)
        pmon_exe=$(readlink -f "/proc/${pmon_pid}/exe" 2>/dev/null || true)
        if [[ "$pmon_exe" != "$TARGET_ORACLE_HOME/bin/oracle" ]]; then
          opg_add_finding BLOCKED PMON_HOME_MISMATCH "PMON voor geselecteerde SID draait niet aantoonbaar uit de doelhome." "sid=${sid}, exe=${pmon_exe:-UNKNOWN}"
          printf '"%s","%s","%s","true","UNKNOWN","UNKNOWN","UNKNOWN","","%s",""\n' "$sid" "$home" "$autostart" "$listener" >>"${RUN_DIR}/database_state_before.csv"
          printf '"%s","UNKNOWN"\n' "$sid" >>"${RUN_DIR}/invalid_objects_before.csv"
          continue
        fi
        if opg_sqlplus "$sid" "inventory_${sid}" "${RUN_DIR}/inventory.sql" "$output" && opg_verify_command_success_text "$output"; then
          IFS='|' read -r _ _ role mode cdb < <(grep '^DB|' "$output" | tail -1)
          pdb=$(grep '^PDB|' "$output" | tail -1 | cut -d'|' -f2-)
          services=$(grep '^SERVICES|' "$output" | tail -1 | cut -d'|' -f2-)
          invalid=$(grep '^INVALID|' "$output" | tail -1 | cut -d'|' -f2)
          component_invalid=$(grep '^COMPONENT_INVALID|' "$output" | tail -1 | cut -d'|' -f2)
          sqlpatch_errors=$(grep '^SQLPATCH_ERRORS|' "$output" | tail -1 | cut -d'|' -f2)
          asm_files=$(grep '^ASM_FILES|' "$output" | tail -1 | cut -d'|' -f2)
          [[ ${component_invalid:-UNKNOWN} =~ ^[1-9] ]] && opg_add_finding BLOCKED INVALID_COMPONENTS "Databasecomponent heeft niet-VALID status." "$sid"
          [[ ${sqlpatch_errors:-UNKNOWN} =~ ^[1-9] ]] && opg_add_finding BLOCKED SQLPATCH_ERROR "Onverklaarde SQL patchfout gevonden." "$sid"
          [[ ${asm_files:-UNKNOWN} =~ ^[1-9] ]] && opg_add_finding BLOCKED ASM_STORAGE_DETECTED "Database gebruikt ASM-bestanden; deze MVP ondersteunt dat niet." "$sid"
          [[ ${invalid:-0} =~ ^[1-9] ]] && opg_add_finding CONDITIONAL PREEXISTING_INVALIDS "Vooraf bestaande invalid objects vereisen acceptatie." "${sid}:${invalid}"
          [[ "$role" != PRIMARY ]] && opg_add_finding BLOCKED DATA_GUARD_UNSUPPORTED "Data Guard-role ${role} is niet ondersteund in deze MVP." "$sid"
          record_registry_baseline "$sid" "$cdb" "$output" || true
        else
          opg_add_finding UNKNOWN DATABASE_QUERY_FAILED "Database-inventarisatie kon niet veilig worden uitgevoerd." "$sid"
        fi
      else
        opg_add_finding UNKNOWN REGISTRY_BASELINE_UNAVAILABLE "Voor een vooraf gestopte database kan geen betrouwbare componentbaseline worden verzameld zonder de database te starten." "$sid"
      fi
      printf '"%s","%s","%s","%s","%s","%s","%s","%s","%s","%s"\n' \
        "$sid" "$home" "$autostart" "$running" "$role" "$mode" "$cdb" "$pdb" "$listener" "$services" >>"${RUN_DIR}/database_state_before.csv"
      printf '"%s","%s"\n' "$sid" "$invalid" >>"${RUN_DIR}/invalid_objects_before.csv"
    done <"$parsed"
  fi
  (( count > 0 )) || opg_add_finding BLOCKED NO_DATABASES "Geen databases voor de gekozen Oracle Home gevonden." "$TARGET_ORACLE_HOME"
  (( count > 1 )) && opg_add_finding CONDITIONAL SHARED_HOME "Meerdere databases delen deze Oracle Home; de home blijft één patch-eenheid." "$count databases"
  LC_ALL=C sort -t'|' -k1,1 -k2,2 -k3,3n -k4,4 -o "${RUN_DIR}/registry_components_before.psv" "${RUN_DIR}/registry_components_before.psv"
  chmod 0440 "${RUN_DIR}/registry_components_before.psv" 2>/dev/null || true

  # Een PMON uit de doelhome die niet in het manifest voorkomt, blokkeert. Linux
  # toont het executable-pad niet altijd; onbekende gevallen worden gerapporteerd.
  if [[ ${OPG_TEST_MODE:-0} == 1 && ${MOCK_UNEXPECTED_DATABASE:-false} == true ]]; then
    opg_add_finding BLOCKED UNEXPECTED_DATABASE "Onverwachte database gebruikt de doelhome." "MOCKDB"
  fi
}

detect_home_processes() {
  local process_dir exe cmdline sid known=false
  : >"${RUN_DIR}/home_processes.txt"
  [[ -d /proc && ${OPG_TEST_MODE:-0} != 1 ]] || return 0
  for process_dir in /proc/[0-9]*; do
    [[ -r "$process_dir/exe" ]] || continue
    exe=$(readlink -f "$process_dir/exe" 2>/dev/null || true)
    [[ "$exe" == "$TARGET_ORACLE_HOME/"* ]] || continue
    cmdline=$(tr '\0' ' ' <"$process_dir/cmdline" 2>/dev/null || true)
    printf '%s|%s|%s\n' "${process_dir##*/}" "$exe" "$cmdline" >>"${RUN_DIR}/home_processes.txt"
    if [[ "$cmdline" =~ ora_pmon_([A-Za-z0-9_#$]+) ]]; then
      sid=${BASH_REMATCH[1]}; known=false
      while IFS= read -r manifest_sid; do [[ "$sid" == "$manifest_sid" ]] && known=true; done < <(opg_manifest_sids)
      [[ "$known" == true ]] || opg_add_finding BLOCKED UNEXPECTED_DATABASE "PMON uit de doelhome staat niet in het manifest." "$sid"
    fi
  done
}

detect_prior_runs() {
  local state_file prior_home prior_state prior_run prior_pid
  : >"${RUN_DIR}/prior_runs.txt"
  while IFS= read -r state_file; do
    [[ "$state_file" == "${RUN_DIR}/execution_state.json" ]] && continue
    prior_home=$(opg_get_json_string "$state_file" target_oracle_home)
    [[ "$prior_home" == "$TARGET_ORACLE_HOME" ]] || continue
    prior_state=$(opg_get_json_string "$state_file" state)
    prior_run=$(opg_get_json_string "$state_file" run_id)
    prior_pid=$(opg_get_json_number "$state_file" pid)
    printf '%s|%s|%s\n' "$prior_run" "$prior_state" "$state_file" >>"${RUN_DIR}/prior_runs.txt"
    case "$prior_state" in
      PARTIAL|MANUAL_INTERVENTION_REQUIRED|04_APPROVED|05_DATABASES_STOPPED|06_DB_BINARY_APPLIED|07_OJVM_BINARY_APPLIED|08_DATABASES_STARTED|09_DATAPATCH_COMPLETE|10_UTLRP_COMPLETE|11_VALIDATION_COMPLETE)
        opg_add_finding BLOCKED PRIOR_INCOMPLETE_RUN "Eerdere of afgebroken run voor deze Oracle Home vereist afhandeling." "run=${prior_run}, state=${prior_state}" ;;
      *)
        if [[ "$prior_pid" =~ ^[0-9]+$ ]] && kill -0 "$prior_pid" 2>/dev/null; then
          opg_add_finding BLOCKED PRIOR_RUNNING "Een eerdere run voor deze Oracle Home lijkt nog actief." "run=${prior_run}, pid=${prior_pid}"
        fi ;;
    esac
  done < <(find "$RUN_ROOT" -mindepth 2 -maxdepth 2 -type f -name execution_state.json 2>/dev/null)
}

detect_unsupported_topology() {
  local all=${RUN_DIR}/oratab_raw.txt srvctl_output="${RUN_DIR}/srvctl_config_database.txt"
  cp -- "$ORATAB_FILE" "$all" 2>/dev/null || true
  if grep -Eq '^[[:space:]]*(\+ASM|ASM|\+APX|MGMTDB)[^:]*:' "$ORATAB_FILE" 2>/dev/null; then
    opg_add_finding BLOCKED ASM_OR_GI_DETECTED "ASM/Grid-entry gedetecteerd; generieke single-instancecommando's zijn niet toegestaan." "$ORATAB_FILE"
  fi
  [[ -x "$TARGET_ORACLE_HOME/bin/crsctl" ]] && opg_add_finding BLOCKED GRID_HOME "Doelhome lijkt een Grid Infrastructure-home." "$TARGET_ORACLE_HOME"
  if [[ -x "$TARGET_ORACLE_HOME/bin/srvctl" ]]; then
    if opg_run_capture srvctl_config "$srvctl_output" "$TARGET_ORACLE_HOME/bin/srvctl" config database && grep -Eq '[A-Za-z0-9]' "$srvctl_output"; then
      opg_add_finding BLOCKED RAC_SEHA_DETECTED "srvctl rapporteert databaseconfiguratie; RAC/SEHA wordt niet generiek gepatcht." "$srvctl_output"
    fi
  fi
  [[ ${MOCK_TOPOLOGY:-SINGLE} =~ ^(RAC|SEHA|GRID|ASM)$ ]] && opg_add_finding BLOCKED UNSUPPORTED_TOPOLOGY "Niet-ondersteunde topologie gedetecteerd: ${MOCK_TOPOLOGY}." "$TARGET_ORACLE_HOME"
}

write_assessment_artifacts() {
  local findings_json first=true severity id message evidence
  findings_json="${RUN_DIR}/findings.json"
  {
    printf '[\n'
    while IFS='|' read -r severity id message evidence; do
      [[ "$first" == true ]] || printf ',\n'; first=false
      printf '  {"severity":"%s","id":"%s","message":"%s","evidence":"%s"}' \
        "$(opg_json_escape "$severity")" "$(opg_json_escape "$id")" "$(opg_json_escape "$message")" "$(opg_json_escape "$evidence")"
    done <"${RUN_DIR}/findings.psv"
    printf '\n]\n'
  } | opg_atomic_write "$findings_json"
  opg_atomic_write "${RUN_DIR}/assessment.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$(opg_json_escape "$RUN_ID")",
  "assessed_at": "$(opg_now)",
  "assessed_epoch": $(date +%s),
  "hostname": "$(opg_json_escape "$HOST_NAME")",
  "user": "$(opg_json_escape "$EXEC_USER")",
  "target_oracle_home": "$(opg_json_escape "$TARGET_ORACLE_HOME")",
  "status": "$ASSESSMENT_STATUS",
  "blocked_count": $BLOCKED_COUNT,
  "unknown_count": $UNKNOWN_COUNT,
  "conditional_count": $CONDITIONAL_COUNT,
  "database_backup_verified": "${DATABASE_BACKUP_VERIFIED}",
  "oracle_home_recovery_verified": "${ORACLE_HOME_RECOVERY_VERIFIED}",
  "rollback_plan_verified": "${ROLLBACK_PLAN_VERIFIED}",
  "findings_file": "findings.json"
}
EOF
  cp -- "${RUN_DIR}/assessment.json" "${RUN_DIR}/summary.txt"
}

write_patch_manifest() {
  local publish=${1:-true}
  local db_dir="${PATCH_ROOT}/${MONTH}/${DB_PATCH}" ojvm_dir="${PATCH_ROOT}/${MONTH}/${OJVM_PATCH}"
  local zip="${OPATCH_ROOT}/${OPATCH_ZIPFILE}" db_hash ojvm_hash zip_hash oratab_hash db_count recovery_hash window_hash registry_hash approval_key_hash
  if [[ "$LOCAL_MEDIA_MODE" == required ]]; then
    db_hash=${LOCAL_DB_TREE_SHA256:-UNAVAILABLE}; ojvm_hash=${LOCAL_OJVM_TREE_SHA256:-UNAVAILABLE}; zip_hash=${LOCAL_OPATCH_ZIP_SHA256:-UNAVAILABLE}
  else
    db_hash=$(opg_tree_hash "$db_dir" 2>/dev/null || printf UNAVAILABLE)
    ojvm_hash=$(opg_tree_hash "$ojvm_dir" 2>/dev/null || printf UNAVAILABLE)
    zip_hash=$(opg_sha256 "$zip" 2>/dev/null || printf 'UNAVAILABLE')
  fi
  oratab_hash=$(opg_sha256 "$ORATAB_FILE" 2>/dev/null || printf 'UNAVAILABLE')
  db_count=$(awk 'END{print NR-1}' "${RUN_DIR}/database_state_before.csv")
  recovery_hash=$(opg_sha256 "${RUN_DIR}/recovery_manifest.json" 2>/dev/null || printf 'UNAVAILABLE')
  window_hash=$(opg_sha256 "$MAINTENANCE_WINDOW_MANIFEST" 2>/dev/null || printf 'UNAVAILABLE')
  registry_hash=$(opg_sha256 "${RUN_DIR}/registry_components_before.psv" 2>/dev/null || printf 'UNAVAILABLE')
  approval_key_hash=$(approval_public_key_sha256 2>/dev/null || printf 'UNAVAILABLE')
  [[ "$db_hash" != UNAVAILABLE ]] || opg_add_finding UNKNOWN DB_PATCH_INTEGRITY_UNAVAILABLE "DB-RU-integriteitscontrole kon niet betrouwbaar worden voltooid." "$db_dir"
  [[ "$ojvm_hash" != UNAVAILABLE ]] || opg_add_finding UNKNOWN OJVM_PATCH_INTEGRITY_UNAVAILABLE "OJVM-integriteitscontrole kon niet betrouwbaar worden voltooid." "$ojvm_dir"
  [[ "$approval_key_hash" != UNAVAILABLE ]] || opg_add_finding BLOCKED APPROVAL_TRUST_UNAVAILABLE "Approval-public-key ontbreekt, is niet leesbaar, is geen regulier bestand of is een symlink." "${APPROVAL_PUBLIC_KEY:-UNCONFIGURED}"
  [[ "$publish" == true ]] || return 0
  opg_atomic_write "${RUN_DIR}/patch_manifest.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$(opg_json_escape "$RUN_ID")",
  "created_at": "$(opg_now)",
  "created_epoch": $(date +%s),
  "hostname": "$(opg_json_escape "$HOST_NAME")",
  "target_oracle_home": "$(opg_json_escape "$TARGET_ORACLE_HOME")",
  "db_patch": "$DB_PATCH",
  "ojvm_patch": "$OJVM_PATCH",
  "month": "$MONTH",
  "required_opatch_version": "$OPATCH_VERSION",
  "assessed_opatch_version": "$OPATCH_ACTUAL_VERSION",
  "opatch_upgrade_required": $OPATCH_UPGRADE_REQUIRED,
  "opatch_zipfile": "$(opg_json_escape "$OPATCH_ZIPFILE")",
  "opatch_zip_sha256": "$zip_hash",
  "db_patch_tree_sha256": "$db_hash",
  "ojvm_patch_tree_sha256": "$ojvm_hash",
  "media_mode": "$(if [[ "$LOCAL_MEDIA_MODE" == required ]]; then printf LOCAL_IMMUTABLE_V2; else printf LEGACY_V1; fi)",
  "local_stage_root": "$(opg_json_escape "${LOCAL_STAGE_ROOT:-}")",
  "local_media_identity": "$(opg_json_escape "${LOCAL_MEDIA_IDENTITY:-}")",
  "artifact_manifest_sha256": "$(opg_json_escape "${LOCAL_ARTIFACT_MANIFEST_SHA256:-}")",
  "artifact_signing_key_sha256": "$(opg_json_escape "${LOCAL_ARTIFACT_KEY_SHA256:-}")",
  "tree_hash_format": "$(opg_json_escape "${LOCAL_TREE_HASH_FORMAT:-OPG_TREE_HASH_V1}")",
  "oratab_sha256": "$oratab_hash",
  "recovery_manifest_sha256": "$recovery_hash",
  "maintenance_window_manifest_sha256": "$window_hash",
  "approval_public_key_sha256": "$approval_key_hash",
  "registry_components_before_sha256": "$registry_hash",
  "database_count": $db_count,
  "database_state_file": "database_state_before.csv",
  "registry_components_file": "registry_components_before.psv"
}
EOF
  opg_sha256 "${RUN_DIR}/patch_manifest.json" >"${RUN_DIR}/patch_manifest.sha256"
  chmod 0440 "${RUN_DIR}/patch_manifest.json" "${RUN_DIR}/patch_manifest.sha256" 2>/dev/null || true
}

precheck_summary_severity() {
  local ids=$1
  awk -F'|' -v ids="$ids" '
    BEGIN { count=split(ids, values, " "); for (i=1; i<=count; i++) wanted[values[i]]=1 }
    $2 in wanted {
      if ($1=="BLOCKED") blocked=1
      else if ($1=="UNKNOWN") unknown=1
      else if ($1=="CONDITIONAL") conditional=1
    }
    END {
      if (blocked) print "BLOCKED"
      else if (unknown) print "UNKNOWN"
      else if (conditional) print "CONDITIONAL"
    }
  ' "${RUN_DIR}/findings.psv"
}

precheck_summary_add() {
  local id=$1 success=$2 evidence=$3 ids=$4 severity
  severity=$(precheck_summary_severity "$ids")
  if [[ -z "$severity" ]]; then
    [[ "$success" == true ]] || return 0
    severity=READY
  fi
  printf '%s|%s|Readiness-samenvatting op basis van bestaande controles.|%s\n' \
    "$severity" "$id" "$evidence" >>"${RUN_DIR}/precheck_summary.psv"
}

write_precheck_summary() {
  local success sid running
  : >"${RUN_DIR}/precheck_summary.psv"

  success=false
  [[ -s "${RUN_DIR}/patch_metadata.txt" && -s "${RUN_DIR}/patch_checksums.sha256" ]] && success=true
  precheck_summary_add MEDIA_READINESS "$success" "${RUN_DIR}/patch_checksums.sha256" \
    'MEDIA_STAGE_UNAVAILABLE DB_PATCH_MISSING OJVM_PATCH_MISSING OPATCH_ZIP_MISSING PATCH_SYMLINK README_MISSING PATCH_FILE_HASH_FAILED DB_PATCH_INTEGRITY_UNAVAILABLE OJVM_PATCH_INTEGRITY_UNAVAILABLE'

  success=false
  [[ -s "${RUN_DIR}/host_info.txt" && -s "${RUN_DIR}/oracle_version.txt" && -s "${RUN_DIR}/inventory_before.txt" ]] && success=true
  precheck_summary_add PLATFORM_HOME_READINESS "$success" "${RUN_DIR}/host_info.txt" \
    'MISSING_DEPENDENCY OS_UNSUPPORTED ARCH_UNSUPPORTED SQLPLUS_MISSING OPATCH_MISSING HOME_OWNER_UNKNOWN HOME_OWNER_MISMATCH EXECUTION_USER_MISMATCH LOCAL_INVENTORY_MISSING CENTRAL_INVENTORY_MISSING ORACLE_VERSION_FAILED ORACLE_VERSION_UNSUPPORTED INVENTORY_INCONSISTENT APPROVAL_TRUST_UNAVAILABLE'

  success=false
  [[ -s "${RUN_DIR}/opatch_media_validation.txt" && -s "${RUN_DIR}/opatch_version.txt" ]] && success=true
  precheck_summary_add OPATCH_READINESS "$success" "${RUN_DIR}/opatch_media_validation.txt" \
    'OPATCH_MEDIA_VALID OPATCH_MEDIA_INVALID OPATCH_MEDIA_UNKNOWN OPATCH_VERSION OPATCH_SELF_UPGRADE'

  success=false
  [[ -s "${RUN_DIR}/conflict_db_ru.txt" && -s "${RUN_DIR}/conflict_ojvm.txt" ]] && success=true
  precheck_summary_add PATCH_CONFLICT_READINESS "$success" "${RUN_DIR}/conflict_db_ru.txt;${RUN_DIR}/conflict_ojvm.txt" \
    'DB_PATCH_MISSING OJVM_PATCH_MISSING DB_RU_CONFLICT OJVM_CONFLICT'

  success=false
  [[ -e "${RUN_DIR}/oratab_raw.txt" ]] && success=true
  precheck_summary_add TOPOLOGY_READINESS "$success" "${RUN_DIR}/oratab_raw.txt" \
    'ASM_OR_GI_DETECTED GRID_HOME RAC_SEHA_DETECTED UNSUPPORTED_TOPOLOGY ASM_STORAGE_DETECTED DATA_GUARD_UNSUPPORTED'

  success=false
  [[ -s "${RUN_DIR}/database_state_before.csv" ]] && (( $(wc -l <"${RUN_DIR}/database_state_before.csv") > 1 )) && success=true
  precheck_summary_add DATABASE_RUNTIME_READINESS "$success" "${RUN_DIR}/database_state_before.csv" \
    'DATABASE_INVENTORY_FAILED NO_DATABASES SHARED_HOME UNEXPECTED_DATABASE PMON_HOME_MISMATCH DATABASE_QUERY_FAILED DATA_GUARD_UNSUPPORTED REGISTRY_BASELINE_UNAVAILABLE'

  success=false
  if [[ -s "${RUN_DIR}/database_state_before.csv" ]] && awk -F, '
    NR>1 { value=$9; gsub(/"/, "", value); rows++; if (value=="" || value=="NONE") bad=1 }
    END { exit !(rows>0 && !bad) }
  ' "${RUN_DIR}/database_state_before.csv"; then success=true; fi
  precheck_summary_add LISTENER_READINESS "$success" "${RUN_DIR}/database_state_before.csv" \
    'INVALID_LISTENER_NAME LISTENER_HOME_MISMATCH'

  success=false
  if [[ -s "${RUN_DIR}/registry_components_before.psv" ]]; then
    success=true
    while IFS='|' read -r sid running; do
      [[ "$running" == true ]] || continue
      if [[ ! -s "${RUN_DIR}/inventory_${sid}.txt" ]] || ! grep -Fqx 'SQLPATCH_ERRORS|0' "${RUN_DIR}/inventory_${sid}.txt"; then
        success=false
        break
      fi
    done < <(awk -F, 'NR>1 { sid=$1; running=$4; gsub(/"/, "", sid); gsub(/"/, "", running); print sid "|" running }' "${RUN_DIR}/database_state_before.csv")
  fi
  precheck_summary_add REGISTRY_SQLPATCH_READINESS "$success" "${RUN_DIR}/registry_components_before.psv" \
    'REGISTRY_QUERY_FAILED REGISTRY_COMPONENT_UNHEALTHY REGISTRY_COMPONENT_UNKNOWN REGISTRY_BASELINE_UNAVAILABLE INVALID_COMPONENTS SQLPATCH_ERROR DATABASE_QUERY_FAILED'

  success=false
  if [[ -s "${RUN_DIR}/invalid_objects_before.csv" ]] && awk -F, '
    NR>1 { value=$2; gsub(/"/, "", value); rows++; if (value !~ /^[0-9]+$/ || value != 0) bad=1 }
    END { exit !(rows>0 && !bad) }
  ' "${RUN_DIR}/invalid_objects_before.csv"; then success=true; fi
  precheck_summary_add INVALID_OBJECT_READINESS "$success" "${RUN_DIR}/invalid_objects_before.csv" \
    'PREEXISTING_INVALIDS DATABASE_QUERY_FAILED PMON_HOME_MISMATCH'

  success=false
  grep -q '^READY|' "${RUN_DIR}/assess_datapump.txt" 2>/dev/null && success=true
  precheck_summary_add DATAPUMP_READINESS "$success" "${RUN_DIR}/assess_datapump.txt" \
    'ACTIVE_DATAPUMP DATAPUMP_UNKNOWN'

  success=false
  [[ -s "${RUN_DIR}/dataguard.txt" ]] && success=true
  precheck_summary_add DATAGUARD_READINESS "$success" "${RUN_DIR}/dataguard.txt" \
    'DATA_GUARD_UNSUPPORTED DATAGUARD_UNHEALTHY DATAGUARD_UNKNOWN'

  success=false
  [[ "$DATABASE_BACKUP_VERIFIED" == true && "$ORACLE_HOME_RECOVERY_VERIFIED" == true && -s "${RUN_DIR}/backup.txt" && -s "${RUN_DIR}/oracle_home_recovery.txt" ]] && success=true
  precheck_summary_add BACKUP_RECOVERY_READINESS "$success" "${RUN_DIR}/backup.txt;${RUN_DIR}/oracle_home_recovery.txt" \
    'BACKUP_NOT_VERIFIED HOME_RECOVERY_REBUILD_VERIFIED HOME_RECOVERY_NOT_VERIFIED HOME_RECOVERY_UNKNOWN'

  success=true
  for sid in HOME_SPACE INVENTORY_SPACE STAGE_SPACE TMP_SPACE; do
    grep -Fq "READY|${sid}|" "${RUN_DIR}/findings.psv" || success=false
  done
  precheck_summary_add CAPACITY_READINESS "$success" "${RUN_DIR}/findings.psv" \
    'HOME_SPACE INVENTORY_SPACE STAGE_SPACE TMP_SPACE'

  success=false
  [[ -e "${RUN_DIR}/prior_runs.txt" ]] && success=true
  precheck_summary_add RUN_COORDINATION_READINESS "$success" "${RUN_DIR}/prior_runs.txt" \
    'PRIOR_INCOMPLETE_RUN PRIOR_RUNNING'

  success=false
  if grep -Eq '^(READY:|OK$|VERIFIED$)' "${RUN_DIR}/maintenance_window.txt" 2>/dev/null; then success=true; fi
  precheck_summary_add MAINTENANCE_WINDOW_READINESS "$success" "${RUN_DIR}/maintenance_window.txt" \
    'WINDOW_INVALID WINDOW_UNKNOWN'
}

emit_precheck_result() {
  local severity id sid_list timestamp
  sid_list=$(opg_manifest_sids 2>/dev/null | paste -sd, -)
  [[ -n "$sid_list" ]] || sid_list=UNKNOWN
  timestamp=$(opg_now)
  {
    printf 'RESULT|host=%s|sid=%s|cycle=%s|timestamp=%s|run_id=%s|status=%s|exit_code=%s\n' \
      "$HOST_NAME" "$sid_list" "$MONTH" "$timestamp" "$RUN_ID" "$ASSESSMENT_STATUS" "$ASSESSMENT_EXIT"
    while IFS='|' read -r severity id _; do
      [[ -n "$severity" && -n "$id" ]] || continue
      printf 'FINDING|severity=%s|id=%s\n' "$severity" "$id"
    done <"${RUN_DIR}/findings.psv"
    while IFS='|' read -r severity id _; do
      [[ -n "$severity" && -n "$id" ]] || continue
      printf 'FINDING|severity=%s|id=%s\n' "$severity" "$id"
    done <"${RUN_DIR}/precheck_summary.psv"
  } | opg_atomic_write "${RUN_DIR}/precheck_result.psv"
  while IFS='|' read -r severity id _; do
    [[ -n "$severity" && -n "$id" ]] || continue
    printf 'OPG_PRECHECK_FINDING|run_id=%s|severity=%s|id=%s\n' "$RUN_ID" "$severity" "$id"
  done <"${RUN_DIR}/findings.psv"
  while IFS='|' read -r severity id _; do
    [[ -n "$severity" && -n "$id" ]] || continue
    printf 'OPG_PRECHECK_FINDING|run_id=%s|severity=%s|id=%s\n' "$RUN_ID" "$severity" "$id"
  done <"${RUN_DIR}/precheck_summary.psv"
  printf 'OPG_PRECHECK_RESULT|host=%s|sid=%s|cycle=%s|timestamp=%s|run_id=%s|status=%s|exit_code=%s\n' \
    "$HOST_NAME" "$sid_list" "$MONTH" "$timestamp" "$RUN_ID" "$ASSESSMENT_STATUS" "$ASSESSMENT_EXIT"
}

compare_opatch_versions() {
  local left=$1 right=$2
  [[ "$left" =~ ^[0-9]+([.][0-9]+){3,5}$ && "$right" =~ ^[0-9]+([.][0-9]+){3,5}$ ]] || return 2
  awk -v left="$left" -v right="$right" 'BEGIN {
    left_count=split(left,l,"."); right_count=split(right,r,"."); count=(left_count>right_count?left_count:right_count)
    for(i=1;i<=count;i++) { lv=(i<=left_count?l[i]+0:0); rv=(i<=right_count?r[i]+0:0); if(lv<rv){print -1;exit} if(lv>rv){print 1;exit} }
    print 0
  }'
}

validate_opatch_media() {
  local evidence=$1 zip="${OPATCH_ROOT}/${OPATCH_ZIPFILE}" actual_hash entry internal_version listing modes part
  local -a entry_parts
  : >"$evidence"
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    case ${MOCK_OPATCH_MEDIA:-VALID} in
      VALID)
        internal_version=${MOCK_OPATCH_ZIP_VERSION:-$OPATCH_VERSION}
        printf 'MEDIA|status=VALID|zip=%s|version=%s\n' "$zip" "$internal_version" >>"$evidence"
        [[ "$internal_version" == "$OPATCH_VERSION" ]] && return 0
        printf 'MEDIA|status=INVALID|reason=version_mismatch|expected=%s|actual=%s\n' "$OPATCH_VERSION" "$internal_version" >>"$evidence"
        return 2 ;;
      UNKNOWN) printf 'MEDIA|status=UNKNOWN|reason=mock_unreliable\n' >>"$evidence"; return 3 ;;
      *) printf 'MEDIA|status=INVALID|reason=mock_%s\n' "${MOCK_OPATCH_MEDIA}" >>"$evidence"; return 2 ;;
    esac
  fi
  [[ -f "$zip" && ! -L "$zip" && -r "$zip" ]] || { printf 'MEDIA|status=INVALID|reason=missing_unsafe_or_unreadable|zip=%s\n' "$zip" >>"$evidence"; return 2; }
  [[ "$OPATCH_ZIP_SHA256" =~ ^[0-9A-Fa-f]{64}$ ]] || { printf 'MEDIA|status=UNKNOWN|reason=expected_checksum_unavailable\n' >>"$evidence"; return 3; }
  actual_hash=$(opg_sha256 "$zip") || { printf 'MEDIA|status=UNKNOWN|reason=checksum_failed\n' >>"$evidence"; return 3; }
  printf 'MEDIA|sha256=%s|expected_sha256=%s\n' "$actual_hash" "${OPATCH_ZIP_SHA256,,}" >>"$evidence"
  [[ "${actual_hash,,}" == "${OPATCH_ZIP_SHA256,,}" ]] || { printf 'MEDIA|status=INVALID|reason=checksum_mismatch\n' >>"$evidence"; return 2; }
  if ! command -v unzip >/dev/null 2>&1 || ! command -v zipinfo >/dev/null 2>&1; then
    printf 'MEDIA|status=UNKNOWN|reason=zip_tools_unavailable\n' >>"$evidence"
    return 3
  fi
  unzip -tqq "$zip" >>"$evidence" 2>&1 || { printf 'MEDIA|status=INVALID|reason=zip_integrity\n' >>"$evidence"; return 2; }
  listing="${evidence}.entries"; modes="${evidence}.modes"
  unzip -Z1 "$zip" >"$listing" 2>>"$evidence" || { printf 'MEDIA|status=UNKNOWN|reason=entry_listing_failed\n' >>"$evidence"; return 3; }
  [[ -s "$listing" ]] || { printf 'MEDIA|status=INVALID|reason=empty_archive\n' >>"$evidence"; return 2; }
  while IFS= read -r entry; do
    entry=${entry%$'\r'}
    [[ -n "$entry" && "$entry" != /* && "$entry" != *\\* && "$entry" != [A-Za-z]:* ]] || { printf 'MEDIA|status=INVALID|reason=unsafe_path|entry=%s\n' "$entry" >>"$evidence"; return 2; }
    case "$entry" in OPatch|OPatch/|OPatch/*) ;; *) printf 'MEDIA|status=INVALID|reason=outside_opatch_root|entry=%s\n' "$entry" >>"$evidence"; return 2 ;; esac
    IFS=/ read -ra entry_parts <<<"$entry"
    for part in "${entry_parts[@]}"; do
      [[ "$part" != .. && "$part" != . ]] || { printf 'MEDIA|status=INVALID|reason=path_traversal|entry=%s\n' "$entry" >>"$evidence"; return 2; }
    done
  done <"$listing"
  zipinfo -l "$zip" >"$modes" 2>>"$evidence" || { printf 'MEDIA|status=UNKNOWN|reason=mode_listing_failed\n' >>"$evidence"; return 3; }
  if awk '$1 ~ /^[lbcps]/ {bad=1} END {exit(bad ? 0 : 1)}' "$modes"; then
    printf 'MEDIA|status=INVALID|reason=symlink_or_special_file\n' >>"$evidence"
    return 2
  fi
  internal_version=$(unzip -p "$zip" OPatch/version.txt 2>>"$evidence" | sed -nE 's/^[[:space:]]*OPATCH_VERSION[[:space:]]*:[[:space:]]*([^[:space:]\r]+).*$/\1/p; s/^[[:space:]]*OPatch Version[[:space:]]*:[[:space:]]*([^[:space:]\r]+).*$/\1/p' | head -1)
  [[ -n "$internal_version" ]] || { printf 'MEDIA|status=INVALID|reason=internal_version_missing\n' >>"$evidence"; return 2; }
  [[ "$internal_version" == "$OPATCH_VERSION" ]] || { printf 'MEDIA|status=INVALID|reason=version_mismatch|expected=%s|actual=%s\n' "$OPATCH_VERSION" "$internal_version" >>"$evidence"; return 2; }
  printf 'MEDIA|status=VALID|version=%s\n' "$internal_version" >>"$evidence"
}

perform_assessment() {
  local assessment_mode=${1:-formal}
  local owner central_inventory local_inventory db_dir ojvm_dir zip readme_count opatch_actual rc os_id os_version arch expected_owner
  local media_rc version_relation
  local OPG_READ_ONLY_PHASE=true OPG_CHECK_PHASE=assess OPG_WINDOW_BINDING_MODE=formal RECOVERY_MANIFEST_FILE OPG_STATE_READ_ONLY=false
  [[ "$assessment_mode" == formal || "$assessment_mode" == precheck ]] || return "$EXIT_INVALID_PARAMS"
  if [[ "$assessment_mode" == precheck ]]; then
    OPG_STATE_READ_ONLY=true
    OPG_WINDOW_BINDING_MODE=precheck
  fi
  init_new_run || return $?
  : >"${RUN_DIR}/findings.psv"; BLOCKED_COUNT=0; UNKNOWN_COUNT=0; CONDITIONAL_COUNT=0
  DATABASE_BACKUP_VERIFIED=false; ORACLE_HOME_RECOVERY_VERIFIED=false; ROLLBACK_PLAN_VERIFIED=false
  if ! initialize_local_media; then
    if [[ "$assessment_mode" == precheck ]]; then
      opg_add_finding BLOCKED MEDIA_STAGE_UNAVAILABLE "Lokale immutable patchmedia kon niet betrouwbaar worden gevalideerd." "${LOCAL_STAGE_ROOT}"
      opg_determine_assessment_status
      write_precheck_summary
      emit_precheck_result
      return "$ASSESSMENT_EXIT"
    fi
    opg_write_state BLOCKED MEDIA
    opg_result_line "$EXIT_BLOCKED" BLOCKED MEDIA
    return "$EXIT_BLOCKED"
  fi
  RECOVERY_MANIFEST_FILE="${RUN_DIR}/recovery_manifest.json"
  write_sql_files
  opg_write_state 01_ASSESS_STARTED ASSESS

  if [[ ${OPG_TEST_MODE:-0} != 1 ]]; then
    local dependency
    for dependency in flock timeout sha256sum openssl stat readlink mktemp pgrep df du find sort xargs awk grep; do
      command -v "$dependency" >/dev/null 2>&1 || opg_add_finding BLOCKED MISSING_DEPENDENCY "Vereiste platformtool ontbreekt: ${dependency}." "$dependency"
    done
  fi

  owner=$(stat -c '%U' "$TARGET_ORACLE_HOME" 2>/dev/null || printf UNKNOWN)
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    os_id=${MOCK_OS_ID:-ol}; os_version=${MOCK_OS_VERSION:-8.10}; arch=${MOCK_ARCH:-x86_64}
  else
    os_id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2);print tolower($2);exit}' /etc/os-release 2>/dev/null || true)
    os_version=$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2);print $2;exit}' /etc/os-release 2>/dev/null || true)
    arch=$(uname -m 2>/dev/null || true)
  fi
  printf 'hostname=%s\nuser=%s\nhome_owner=%s\nos_id=%s\nos_version=%s\nkernel=%s\narch=%s\n' "$HOST_NAME" "$EXEC_USER" "$owner" "$os_id" "$os_version" "$(uname -sr 2>/dev/null)" "$arch" >"${RUN_DIR}/host_info.txt"
  [[ "$os_id" =~ ^(ol|oracle|oraclelinux)$ && "$os_version" =~ ^(8|9)([.]|$) ]] || opg_add_finding BLOCKED OS_UNSUPPORTED "Alleen Oracle Linux 8/9 wordt door deze MVP ondersteund." "${os_id} ${os_version}"
  [[ "$arch" == x86_64 ]] || opg_add_finding BLOCKED ARCH_UNSUPPORTED "Alleen x86_64 is in deze MVP bewezen." "$arch"
  [[ -x "$TARGET_ORACLE_HOME/bin/sqlplus" ]] || opg_add_finding BLOCKED SQLPLUS_MISSING "bin/sqlplus ontbreekt of is niet uitvoerbaar." "$TARGET_ORACLE_HOME"
  [[ -x "$TARGET_ORACLE_HOME/OPatch/opatch" ]] || opg_add_finding BLOCKED OPATCH_MISSING "OPatch/opatch ontbreekt of is niet uitvoerbaar." "$TARGET_ORACLE_HOME"
  [[ "$owner" != UNKNOWN ]] || opg_add_finding UNKNOWN HOME_OWNER_UNKNOWN "Eigenaar van Oracle Home kon niet worden vastgesteld." "$TARGET_ORACLE_HOME"
  expected_owner=${EXPECTED_ORACLE_OWNER:-$owner}
  [[ "$owner" == "$expected_owner" ]] || opg_add_finding BLOCKED HOME_OWNER_MISMATCH "Oracle Home-owner wijkt af van configuratie." "gevonden=${owner}, verwacht=${expected_owner}"
  [[ "$EXEC_USER" == "$owner" ]] || opg_add_finding BLOCKED EXECUTION_USER_MISMATCH "Uitvoerende gebruiker is niet de Oracle Home-owner; configureer sudo -n naar de owner." "user=${EXEC_USER}, owner=${owner}"

  local_inventory="$TARGET_ORACLE_HOME/inventory/ContentsXML/oraclehomeproperties.xml"
  [[ -r "$local_inventory" ]] || opg_add_finding BLOCKED LOCAL_INVENTORY_MISSING "Local inventory ontbreekt of is niet leesbaar." "$local_inventory"
  central_inventory=$(awk -F= '$1 ~ /^[[:space:]]*inventory_loc[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$ORAINST_LOC" 2>/dev/null || true)
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then central_inventory=${MOCK_CENTRAL_INVENTORY:-${OPG_FIXTURE_DIR:-$TARGET_ORACLE_HOME}/central_inventory}; fi
  [[ -n "$central_inventory" && -r "$central_inventory/ContentsXML/inventory.xml" ]] || opg_add_finding BLOCKED CENTRAL_INVENTORY_MISSING "Central inventory ontbreekt of is niet leesbaar." "${central_inventory:-not-found}"

  opg_run_capture oracle_version "${RUN_DIR}/oracle_version.txt" "$TARGET_ORACLE_HOME/bin/sqlplus" -V || opg_add_finding BLOCKED ORACLE_VERSION_FAILED "Exacte Oracle-versie kon niet worden vastgesteld." "${RUN_DIR}/oracle_version.txt"
  if ! grep -Eq '19[.]' "${RUN_DIR}/oracle_version.txt" && [[ ${OPG_TEST_MODE:-0} != 1 ]]; then opg_add_finding BLOCKED ORACLE_VERSION_UNSUPPORTED "Deze MVP ondersteunt uitsluitend Oracle Database 19c." "${RUN_DIR}/oracle_version.txt"; fi
  opg_run_capture opatch_lsinventory_before "${RUN_DIR}/inventory_before.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" lsinventory -detail || opg_add_finding BLOCKED INVENTORY_INCONSISTENT "opatch lsinventory -detail is mislukt." "${RUN_DIR}/inventory_before.txt"
  grep -Ei 'one[- ]off|overlay|interim patch|Patch [0-9]+' "${RUN_DIR}/inventory_before.txt" >"${RUN_DIR}/oneoffs_overlays.txt" 2>/dev/null || true
  opg_run_capture opatch_version "${RUN_DIR}/opatch_version.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" version || true
  opatch_actual=$(sed -nE 's/^[[:space:]]*OPATCH_VERSION[[:space:]]*:[[:space:]]*([^[:space:]\r]+).*$/\1/p; s/^[[:space:]]*OPatch Version[[:space:]]*:[[:space:]]*([^[:space:]\r]+).*$/\1/p' "${RUN_DIR}/opatch_version.txt" | head -1)
  OPATCH_ACTUAL_VERSION=$opatch_actual
  OPATCH_UPGRADE_REQUIRED=false

  db_dir="${PATCH_ROOT}/${MONTH}/${DB_PATCH}"; ojvm_dir="${PATCH_ROOT}/${MONTH}/${OJVM_PATCH}"; zip="${OPATCH_ROOT}/${OPATCH_ZIPFILE}"
  [[ -d "$db_dir" ]] || opg_add_finding BLOCKED DB_PATCH_MISSING "DB-RU patchdirectory ontbreekt." "$db_dir"
  [[ -d "$ojvm_dir" ]] || opg_add_finding BLOCKED OJVM_PATCH_MISSING "OJVM patchdirectory ontbreekt." "$ojvm_dir"
  [[ -r "$zip" ]] || opg_add_finding BLOCKED OPATCH_ZIP_MISSING "OPatch-zip ontbreekt of is niet leesbaar." "$zip"
  if [[ -L "$db_dir" || -L "$ojvm_dir" || -L "$zip" ]] || find "$db_dir" "$ojvm_dir" -type l -print -quit 2>/dev/null | grep -q .; then
    opg_add_finding BLOCKED PATCH_SYMLINK "Symlinks in patchlocaties zijn niet toegestaan; checksumdekking moet eenduidig zijn." "$db_dir $ojvm_dir $zip"
  fi
  validate_opatch_media "${RUN_DIR}/opatch_media_validation.txt"; media_rc=$?
  case "$media_rc" in
    0) opg_add_finding READY OPATCH_MEDIA_VALID "OPatch-upgrademedium is volledig gevalideerd." "${RUN_DIR}/opatch_media_validation.txt" ;;
    2) opg_add_finding BLOCKED OPATCH_MEDIA_INVALID "OPatch-upgrademedium ontbreekt, is ongeldig of komt niet overeen met de verwachte checksum/versie." "${RUN_DIR}/opatch_media_validation.txt" ;;
    *) opg_add_finding UNKNOWN OPATCH_MEDIA_UNKNOWN "OPatch-upgrademedium kon niet betrouwbaar worden gevalideerd." "${RUN_DIR}/opatch_media_validation.txt" ;;
  esac
  version_relation=$(compare_opatch_versions "$opatch_actual" "$OPATCH_VERSION" 2>/dev/null) || version_relation=INVALID
  case "$version_relation" in
    0) opg_add_finding READY OPATCH_VERSION "Actieve OPatch-versie is exact de vereiste versie ${OPATCH_VERSION}." "${RUN_DIR}/opatch_version.txt" ;;
    -1)
      OPATCH_UPGRADE_REQUIRED=true
      if (( media_rc == 0 )); then
        opg_add_finding CONDITIONAL OPATCH_SELF_UPGRADE "Actieve OPatch ${opatch_actual} wordt vóór downtime gecontroleerd bijgewerkt naar ${OPATCH_VERSION}." "${RUN_DIR}/opatch_media_validation.txt"
      fi ;;
    1) opg_add_finding BLOCKED OPATCH_VERSION "Actieve OPatch-versie ${opatch_actual} is onverwacht nieuwer dan vereist ${OPATCH_VERSION}; automatische downgrade is verboden." "${RUN_DIR}/opatch_version.txt" ;;
    *) opg_add_finding BLOCKED OPATCH_VERSION "Actieve OPatch-versie is onverwacht of ongeldig: gevonden ${opatch_actual:-UNKNOWN}, vereist ${OPATCH_VERSION}." "${RUN_DIR}/opatch_version.txt" ;;
  esac
  readme_count=$(find "$db_dir" "$ojvm_dir" -maxdepth 2 -type f \( -iname 'README*' -o -iname '*.html' \) 2>/dev/null | wc -l)
  (( readme_count > 0 )) || opg_add_finding BLOCKED README_MISSING "Lokale patch-README ontbreekt; patchespecifieke eisen zijn niet verifieerbaar." "$db_dir $ojvm_dir"
  find "$db_dir" "$ojvm_dir" -maxdepth 2 -type f \( -iname 'README*' -o -iname '*.html' \) -print >"${RUN_DIR}/patch_readmes.txt" 2>/dev/null || true
  {
    printf 'DB_PATCH|id=%s|type=DB_RU|directory=%s\n' "$DB_PATCH" "$db_dir"
    printf 'OJVM_PATCH|id=%s|type=OJVM|directory=%s\n' "$OJVM_PATCH" "$ojvm_dir"
    printf 'OPATCH|version=%s|zip=%s\n' "$OPATCH_VERSION" "$zip"
  } >"${RUN_DIR}/patch_metadata.txt"
  : >"${RUN_DIR}/patch_checksums.sha256"
  find "$db_dir" "$ojvm_dir" -type f -print0 2>/dev/null | sort -z | xargs -0 sha256sum >>"${RUN_DIR}/patch_checksums.sha256" 2>/dev/null || opg_add_finding UNKNOWN PATCH_FILE_HASH_FAILED "Niet alle patchbestanden konden worden gehasht." "${RUN_DIR}/patch_checksums.sha256"
  [[ -r "$zip" ]] && sha256sum -- "$zip" >>"${RUN_DIR}/patch_checksums.sha256" 2>/dev/null

  if [[ -d "$db_dir" ]]; then
    opg_run_capture conflict_db_ru "${RUN_DIR}/conflict_db_ru.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph "$db_dir"; rc=$?
    if (( rc != 0 )) || ! opg_verify_command_success_text "${RUN_DIR}/conflict_db_ru.txt"; then
      opg_add_finding BLOCKED DB_RU_CONFLICT "DB-RU prerequisite/conflictcontrole is mislukt." "${RUN_DIR}/conflict_db_ru.txt"
    fi
  fi
  if [[ -d "$ojvm_dir" ]]; then
    opg_run_capture conflict_ojvm "${RUN_DIR}/conflict_ojvm.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph "$ojvm_dir"; rc=$?
    if (( rc != 0 )) || ! opg_verify_command_success_text "${RUN_DIR}/conflict_ojvm.txt"; then
      opg_add_finding BLOCKED OJVM_CONFLICT "OJVM prerequisite/conflictcontrole is mislukt." "${RUN_DIR}/conflict_ojvm.txt"
    fi
  fi

  detect_unsupported_topology
  inventory_databases || opg_add_finding BLOCKED DATABASE_INVENTORY_FAILED "Database-manifest kon niet worden gemaakt." "$ORATAB_FILE"
  detect_home_processes
  detect_prior_runs
  check_path_space "$TARGET_ORACLE_HOME" "$MIN_HOME_FREE_MB" HOME_SPACE "Oracle Home"
  [[ -n "$central_inventory" && -d "$central_inventory" ]] && check_path_space "$central_inventory" "$MIN_INVENTORY_FREE_MB" INVENTORY_SPACE "central inventory"
  [[ -d "$PATCH_ROOT" ]] && check_path_space "$PATCH_ROOT" "$MIN_STAGE_FREE_MB" STAGE_SPACE "patchstage"
  check_path_space /tmp "$MIN_TMP_FREE_MB" TMP_SPACE "/tmp"

  if run_optional_check backup "$BACKUP_CHECK_COMMAND" true; then DATABASE_BACKUP_VERIFIED=true; else DATABASE_BACKUP_VERIFIED=false; opg_add_finding BLOCKED BACKUP_NOT_VERIFIED "Recente bruikbare databaseback-up is niet aantoonbaar geverifieerd." "${RUN_DIR}/backup.txt"; fi
  if run_optional_check oracle_home_recovery "$ORACLE_HOME_RECOVERY_CHECK_COMMAND" true; then
    ORACLE_HOME_RECOVERY_VERIFIED=true
    opg_add_finding CONDITIONAL HOME_RECOVERY_REBUILD_VERIFIED "De gecontroleerde rebuild-herstelroute is beschikbaar; expliciete acceptatie blijft vereist." "${RUN_DIR}/recovery_manifest.json"
  else
    rc=$?; ORACLE_HOME_RECOVERY_VERIFIED=false
    if (( rc == 2 )); then opg_add_finding BLOCKED HOME_RECOVERY_NOT_VERIFIED "De rebuild-herstelroute voor de Oracle Home voldoet niet." "${RUN_DIR}/oracle_home_recovery.txt"
    else opg_add_finding UNKNOWN HOME_RECOVERY_UNKNOWN "De rebuild-herstelroute voor de Oracle Home kon niet betrouwbaar worden vastgesteld." "${RUN_DIR}/oracle_home_recovery.txt"; fi
  fi
  ROLLBACK_PLAN_VERIFIED=$ORACLE_HOME_RECOVERY_VERIFIED
  if check_datapump_evidence assess; then :; else rc=$?; (( rc == 2 )) && opg_add_finding BLOCKED ACTIVE_DATAPUMP "Actieve Data Pump-job gevonden." "${RUN_DIR}/assess_datapump.txt"; (( rc == 3 )) && opg_add_finding UNKNOWN DATAPUMP_UNKNOWN "Data Pump kon niet voor iedere draaiende database betrouwbaar worden gecontroleerd." "${RUN_DIR}/assess_datapump.txt"; fi
  if run_optional_check dataguard "$DATAGUARD_CHECK_COMMAND" true; then :; else rc=$?; (( rc == 2 )) && opg_add_finding BLOCKED DATAGUARD_UNHEALTHY "Data Guard is niet gezond of niet ondersteund." "${RUN_DIR}/dataguard.txt"; (( rc == 3 )) && opg_add_finding UNKNOWN DATAGUARD_UNKNOWN "Data Guard-afwezigheid/status kon niet aantoonbaar worden vastgesteld." "${RUN_DIR}/dataguard.txt"; fi
  if run_optional_check maintenance_window "$MAINTENANCE_WINDOW_CHECK_COMMAND" false; then :; else rc=$?; (( rc == 2 )) && opg_add_finding BLOCKED WINDOW_INVALID "Onderhoudsvenster is verlopen, ongeldig, niet passend of te kort." "${RUN_DIR}/maintenance_window.txt"; (( rc == 3 )) && opg_add_finding UNKNOWN WINDOW_UNKNOWN "Onderhoudsvenster kon niet betrouwbaar worden gecontroleerd." "${RUN_DIR}/maintenance_window.txt"; fi
  [[ ${MOCK_ACTIVE_DATAPUMP:-false} == true ]] && opg_add_finding BLOCKED ACTIVE_DATAPUMP "Actieve Data Pump-taak gevonden." MOCK
  [[ ${MOCK_SQLPATCH_ERROR:-false} == true ]] && opg_add_finding BLOCKED SQLPATCH_ERROR "Bestaande SQL-patchfout gevonden." MOCK

  if [[ "$assessment_mode" == precheck ]]; then
    write_patch_manifest false
  else
    write_patch_manifest true
  fi
  opg_determine_assessment_status
  write_assessment_artifacts
  opg_atomic_write "${RUN_DIR}/rollback_plan.txt" <<EOF
Rollbackplan voor run ${RUN_ID}
===============================
Automatische rollback is uitgeschakeld.
Databaseback-up geverifieerd: ${DATABASE_BACKUP_VERIFIED}
Oracle Home-herstel geverifieerd: ${ORACLE_HOME_RECOVERY_VERIFIED}
Bij binary patchfalen: stop, bewaar home/inventory/logs en volg de patch-README plus de lokaal goedgekeurde herstelprocedure.
DB-RU: ${DB_PATCH}; OJVM: ${OJVM_PATCH}; Home: ${TARGET_ORACLE_HOME}
EOF
  if [[ "$assessment_mode" == precheck ]]; then
    write_precheck_summary
    emit_precheck_result
    return "$ASSESSMENT_EXIT"
  fi
  if [[ "$ASSESSMENT_STATUS" == READY || "$ASSESSMENT_STATUS" == CONDITIONAL ]]; then
    opg_write_state 02_ASSESS_OK ASSESS
  else
    opg_write_state BLOCKED ASSESS
  fi
  opg_result_line "$ASSESSMENT_EXIT" "$ASSESSMENT_STATUS" ASSESS
  return "$ASSESSMENT_EXIT"
}

generate_plan() {
  if [[ ! -d "$RUN_DIR" ]]; then
    [[ -n ${DB_PATCH:-} && -n ${OJVM_PATCH:-} ]] || { usage; return "$EXIT_INVALID_PARAMS"; }
    perform_assessment; local rc=$?; (( rc == 0 || rc == 10 )) || return "$rc"
  else
    load_run_context || return "$EXIT_BLOCKED"
    initialize_local_media || { opg_result_line "$EXIT_BLOCKED" BLOCKED MEDIA; return "$EXIT_BLOCKED"; }
  fi
  [[ "$CURRENT_STATE" == 02_ASSESS_OK ]] || { opg_result_line "$EXIT_BLOCKED" BLOCKED PLAN; return "$EXIT_BLOCKED"; }
  opg_atomic_write "${RUN_DIR}/proposed_runbook.sh" <<EOF
#!/usr/bin/env bash
# INFORMATIEF. Dit bestand kan patchGD_guard.sh-controles niet omzeilen.
# Run: ${RUN_ID}; Host: ${HOST_NAME}; Home: ${TARGET_ORACLE_HOME}
echo '1. Herbevestig manifest, checksums, assessmentleeftijd, herstelroute en lock.'
echo '2. Werk OPatch indien manifestgebonden vereist gecontroleerd bij en valideer OPATCH_READY vóór downtime.'
echo '3. Stop uitsluitend oorspronkelijk actieve databases/listeners uit het manifest.'
echo '4. Pas DB-RU ${DB_PATCH} toe en valideer inventory.'
echo '5. Pas OJVM ${OJVM_PATCH} toe en valideer inventory.'
echo '6. Herstel oorspronkelijke database/PDB/listener/service-toestand.'
echo '7. Voer datapatch -verbose en utlrp.sql aantoonbaar per database uit.'
echo '8. Valideer SQL patchregistratie, componenten, objects, services en OEM-collecties.'
echo '9. Bewaar alle rollbackinformatie; cleanup is een afzonderlijke goedkeuring.'
EOF
  chmod 0440 "${RUN_DIR}/proposed_runbook.sh" 2>/dev/null || true
  opg_atomic_write "${RUN_DIR}/change_report.md" <<EOF
# Voorgesteld patchplan ${RUN_ID}

- Host: ${HOST_NAME}
- Oracle Home: ${TARGET_ORACLE_HOME}
- DB-RU: ${DB_PATCH}
- OJVM: ${OJVM_PATCH}
- Assessment: $(opg_get_json_string "${RUN_DIR}/assessment.json" status)
- Databases: $(opg_manifest_sids | paste -sd, -)
- OS-update en reboot: niet onderdeel van deze patchrun

De patch-README blijft leidend. Iedere CONDITIONAL finding moet met zijn eigen ID in het approval-token staan.
EOF
  opg_write_state 03_PLAN_GENERATED PLAN
  opg_result_line "$EXIT_OK" PLAN_GENERATED PLAN
}

verify_approval() {
  local manifest=$1 token=$2 actual_hash token_hash token_host token_home approved expires now condition accepted manifest_signature approval_signature
  APPROVAL_ERROR=
  [[ -r "$manifest" ]] || { APPROVAL_ERROR="approved manifest is not readable: ${manifest}"; return 1; }
  [[ -r "$token" ]] || { APPROVAL_ERROR="approval token is not readable: ${token}"; return 1; }
  actual_hash=$(opg_sha256 "$manifest") || { APPROVAL_ERROR="approved manifest hash could not be calculated"; return 1; }
  token_hash=$(opg_get_json_string "$token" manifest_sha256)
  token_host=$(opg_get_json_string "$token" hostname)
  token_home=$(opg_get_json_string "$token" target_oracle_home)
  approved=$(opg_get_json_boolean "$token" approved)
  expires=$(opg_get_json_number "$token" expires_epoch)
  [[ "$actual_hash" == "$token_hash" ]] || { APPROVAL_ERROR="manifest hash mismatch"; return 1; }
  [[ "$token_host" == "$HOST_NAME" ]] || { APPROVAL_ERROR="approval hostname mismatch"; return 1; }
  [[ "$token_home" == "$TARGET_ORACLE_HOME" ]] || { APPROVAL_ERROR="approval Oracle Home mismatch"; return 1; }
  [[ "$approved" == true ]] || { APPROVAL_ERROR="approval token does not approve this run"; return 1; }
  now=$(date +%s)
  [[ "$expires" =~ ^[0-9]+$ && "$expires" -ge "$now" ]] || { APPROVAL_ERROR="approval token expired"; return 1; }
  while IFS='|' read -r severity condition _; do
    [[ "$severity" == CONDITIONAL ]] || continue
    accepted=$(opg_get_json_string "$token" "accept_${condition}")
    [[ "$accepted" == "$condition" ]] || { APPROVAL_ERROR="conditional finding is not accepted: ${condition}"; return 1; }
  done <"${RUN_DIR}/findings.psv"
  if [[ ${OPG_TEST_MODE:-0} != 1 || ${TEST_REQUIRE_SIGNATURES:-false} == true ]]; then
    approval_public_key_sha256 >/dev/null 2>&1 || { APPROVAL_ERROR="approval public key is unavailable or invalid"; return 1; }
    manifest_signature=$(opg_get_json_string "$token" manifest_signature_file)
    approval_signature=$(opg_get_json_string "$token" approval_signature_file)
    [[ -n "$manifest_signature" && -r "$manifest_signature" ]] || { APPROVAL_ERROR="manifest signature is not readable"; return 1; }
    [[ -n "$approval_signature" && -r "$approval_signature" ]] || { APPROVAL_ERROR="approval signature is not readable"; return 1; }
    openssl dgst -sha256 -verify "$APPROVAL_PUBLIC_KEY" -signature "$manifest_signature" "$manifest" >/dev/null 2>&1 || { APPROVAL_ERROR="manifest signature verification failed"; return 1; }
    openssl dgst -sha256 -verify "$APPROVAL_PUBLIC_KEY" -signature "$approval_signature" "$token" >/dev/null 2>&1 || { APPROVAL_ERROR="approval signature verification failed"; return 1; }
  fi
  return 0
}

report_approval_blocked() {
  local message=$1
  printf 'APPROVAL CHECK BLOCKED: %s\n' "$message" >&2
  opg_log ERROR "APPROVAL_CHECK_BLOCKED|reason=${message}"
}

verify_database_state_unchanged() {
  local sid expected_running current_running output expected_role expected_mode expected_pdb expected_services current_role current_mode current_pdb current_services
  local pmon_pid pmon_exe sqlpatch_errors component_invalid asm_files
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    [[ ${MOCK_ENVIRONMENT_CHANGED:-false} != true && ${MOCK_PREAPPLY_DATAPUMP:-false} != true && ${MOCK_PREAPPLY_SQLPATCH_ERROR:-false} != true && ${MOCK_UNEXPECTED_DATABASE:-false} != true && ${MOCK_REGISTRY_PREAPPLY_CHANGED:-false} != true ]]
    return $?
  fi
  : >"${RUN_DIR}/registry_components_preapply.psv"
  while IFS= read -r sid; do
    expected_running=$(opg_read_original_state "$sid" running); current_running=false
    pgrep -f "ora_pmon_${sid}([^A-Za-z0-9_]|$)" >/dev/null 2>&1 && current_running=true
    [[ "$expected_running" == "$current_running" ]] || return 1
    [[ "$current_running" == true ]] || continue
    pmon_pid=$(pgrep -f "ora_pmon_${sid}([^A-Za-z0-9_]|$)" | head -1)
    pmon_exe=$(readlink -f "/proc/${pmon_pid}/exe" 2>/dev/null || true)
    [[ "$pmon_exe" == "$TARGET_ORACLE_HOME/bin/oracle" ]] || return 1
    output="${RUN_DIR}/preapply_recheck_${sid}.log"
    opg_sqlplus "$sid" "preapply_recheck_${sid}" "${RUN_DIR}/inventory.sql" "$output" && opg_verify_command_success_text "$output" || return 1
    expected_role=$(awk -F, -v sid="\"${sid}\"" '$1==sid{v=$5;gsub(/^"|"$/,"",v);print v;exit}' "${RUN_DIR}/database_state_before.csv")
    expected_mode=$(opg_read_original_state "$sid" open_mode)
    expected_pdb=$(opg_read_original_state "$sid" pdb_status)
    expected_services=$(opg_read_original_state "$sid" services)
    IFS='|' read -r _ _ current_role current_mode _ < <(grep '^DB|' "$output" | tail -1)
    current_pdb=$(grep '^PDB|' "$output" | tail -1 | cut -d'|' -f2-)
    current_services=$(grep '^SERVICES|' "$output" | tail -1 | cut -d'|' -f2-)
    [[ "$expected_role" == "$current_role" && "$expected_mode" == "$current_mode" && "$expected_pdb" == "$current_pdb" && "$expected_services" == "$current_services" ]] || return 1
    sqlpatch_errors=$(grep '^SQLPATCH_ERRORS|' "$output" | tail -1 | cut -d'|' -f2)
    component_invalid=$(grep '^COMPONENT_INVALID|' "$output" | tail -1 | cut -d'|' -f2)
    asm_files=$(grep '^ASM_FILES|' "$output" | tail -1 | cut -d'|' -f2)
    [[ "$sqlpatch_errors" == 0 && "$component_invalid" == 0 && "$asm_files" == 0 && "$current_role" == PRIMARY ]] || return 1
    compare_registry_with_baseline "$sid" "$(opg_read_original_state "$sid" cdb)" "$output" preapply || return 1
  done < <(opg_manifest_sids)
  verify_no_unexpected_home_processes
}

verify_no_unexpected_home_processes() {
  local process_dir exe cmdline sid known manifest_sid
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    [[ ${MOCK_UNEXPECTED_DATABASE:-false} != true ]]
    return $?
  fi
  for process_dir in /proc/[0-9]*; do
    [[ -r "$process_dir/exe" ]] || continue
    exe=$(readlink -f "$process_dir/exe" 2>/dev/null || true)
    [[ "$exe" == "$TARGET_ORACLE_HOME/bin/oracle" ]] || continue
    cmdline=$(tr '\0' ' ' <"$process_dir/cmdline" 2>/dev/null || true)
    [[ "$cmdline" =~ ora_pmon_([A-Za-z0-9_#$]+) ]] || continue
    sid=${BASH_REMATCH[1]}; known=false
    while IFS= read -r manifest_sid; do [[ "$sid" == "$manifest_sid" ]] && known=true; done < <(opg_manifest_sids)
    [[ "$known" == true ]] || return 1
  done
  return 0
}

verify_environment_unchanged() {
  local assessed_epoch now age_limit
  verify_static_context_unchanged || return 1
  assessed_epoch=$(opg_get_json_number "${RUN_DIR}/assessment.json" assessed_epoch); now=$(date +%s); age_limit=$((ASSESSMENT_MAX_AGE_MINUTES * 60))
  [[ "$assessed_epoch" =~ ^[0-9]+$ && $((now - assessed_epoch)) -le "$age_limit" ]] || return 1
  verify_database_state_unchanged
}

verify_static_context_unchanged() {
  local stored_host stored_home stored_oratab current_oratab stored_hash current_hash current_home
  local stored_db_hash stored_ojvm_hash stored_zip_hash current_db_hash current_ojvm_hash current_zip_hash stored_window_hash current_window_hash stored_registry_hash current_registry_hash
  stored_host=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" hostname)
  stored_home=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" target_oracle_home)
  opg_log INFO "STATIC_CONTEXT_CHECK_START|run_id=${RUN_ID}"
  current_home=$(opg_canonical_dir "$TARGET_ORACLE_HOME") || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=oracle_home_canonical"; return 1; }
  [[ "$stored_host" == "$HOST_NAME" ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=hostname|expected=${stored_host}|actual=${HOST_NAME}"; return 1; }
  [[ "$stored_home" == "$current_home" ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=oracle_home|expected=${stored_home}|actual=${current_home}"; return 1; }
  stored_oratab=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" oratab_sha256)
  current_oratab=$(opg_sha256 "$ORATAB_FILE" 2>/dev/null || printf UNAVAILABLE)
  [[ "$stored_oratab" == "$current_oratab" ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=oratab_sha256|expected=${stored_oratab}|actual=${current_oratab}"; return 1; }
  stored_hash=$(awk '{print $1}' "${RUN_DIR}/patch_manifest.sha256")
  current_hash=$(opg_sha256 "${RUN_DIR}/patch_manifest.json")
  [[ "$stored_hash" == "$current_hash" ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=patch_manifest_sha256|expected=${stored_hash}|actual=${current_hash}"; return 1; }
  stored_db_hash=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" db_patch_tree_sha256)
  stored_ojvm_hash=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" ojvm_patch_tree_sha256)
  stored_zip_hash=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" opatch_zip_sha256)
  if [[ "$LOCAL_MEDIA_MODE" == required ]]; then
    local stored_media_mode stored_identity stored_artifact stored_key stored_format
    stored_media_mode=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" media_mode)
    stored_identity=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" local_media_identity)
    stored_artifact=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" artifact_manifest_sha256)
    stored_key=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" artifact_signing_key_sha256)
    stored_format=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" tree_hash_format)
    [[ "$stored_media_mode" == LOCAL_IMMUTABLE_V2 ]] || return 1
    initialize_local_media || return 1
    [[ "$stored_identity" == "$LOCAL_MEDIA_IDENTITY" && "$stored_artifact" == "$LOCAL_ARTIFACT_MANIFEST_SHA256" && "$stored_key" == "$LOCAL_ARTIFACT_KEY_SHA256" && "$stored_format" == "$LOCAL_TREE_HASH_FORMAT" ]] || return 1
    current_db_hash=$LOCAL_DB_TREE_SHA256; current_ojvm_hash=$LOCAL_OJVM_TREE_SHA256; current_zip_hash=$LOCAL_OPATCH_ZIP_SHA256
  else
    current_db_hash=$(opg_tree_hash "${PATCH_ROOT}/${MONTH}/${DB_PATCH}" 2>/dev/null || printf UNAVAILABLE)
    current_ojvm_hash=$(opg_tree_hash "${PATCH_ROOT}/${MONTH}/${OJVM_PATCH}" 2>/dev/null || printf UNAVAILABLE)
    current_zip_hash=$(opg_sha256 "${OPATCH_ROOT}/${OPATCH_ZIPFILE}" 2>/dev/null || printf UNAVAILABLE)
  fi
  [[ "$stored_db_hash" == "$current_db_hash" ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=db_patch_tree_sha256|expected=${stored_db_hash}|actual=${current_db_hash}"; return 1; }
  [[ "$stored_ojvm_hash" == "$current_ojvm_hash" ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=ojvm_patch_tree_sha256|expected=${stored_ojvm_hash}|actual=${current_ojvm_hash}"; return 1; }
  [[ "$stored_zip_hash" == "$current_zip_hash" ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=opatch_zip_sha256|expected=${stored_zip_hash}|actual=${current_zip_hash}"; return 1; }
  stored_window_hash=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" maintenance_window_manifest_sha256)
  current_window_hash=$(opg_sha256 "$MAINTENANCE_WINDOW_MANIFEST" 2>/dev/null || printf UNAVAILABLE)
  [[ "$stored_window_hash" == "$current_window_hash" ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=maintenance_window_manifest_sha256|expected=${stored_window_hash}|actual=${current_window_hash}"; return 1; }
  stored_registry_hash=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" registry_components_before_sha256)
  current_registry_hash=$(opg_sha256 "${RUN_DIR}/registry_components_before.psv" 2>/dev/null || printf UNAVAILABLE)
  [[ "$stored_registry_hash" == "$current_registry_hash" && "$stored_registry_hash" != UNAVAILABLE ]] || { opg_log ERROR "STATIC_CONTEXT_MISMATCH|check=registry_components_before_sha256|expected=${stored_registry_hash}|actual=${current_registry_hash}"; return 1; }
  opg_log INFO "STATIC_CONTEXT_CHECK_END|run_id=${RUN_ID}|status=OK"
  return 0
}

verify_manifest_databases_stopped() {
  local sid listener
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    [[ ${MOCK_ENVIRONMENT_CHANGED:-false} != true ]]
    return $?
  fi
  while IFS= read -r sid; do
    pgrep -f "ora_pmon_${sid}([^A-Za-z0-9_]|$)" >/dev/null 2>&1 && return 1
  done < <(opg_manifest_sids)
  while IFS= read -r listener; do
    listener_running_from_target_home "$listener" && return 1
  done < <(manifest_listeners)
  return 0
}

verify_resume_start_progress() {
  local sid running marker output
  [[ ${MOCK_ENVIRONMENT_CHANGED:-false} != true ]] || return 1
  while IFS= read -r sid; do
    running=$(opg_read_original_state "$sid" running)
    [[ "$running" == true ]] || continue
    marker="${RUN_DIR}/startup_${sid}.complete"; output="${RUN_DIR}/startup_${sid}.log"
    if [[ -e "$marker" ]]; then
      opg_completion_marker_valid "$marker" "$output" "$sid" startup &&
        database_pmon_from_target_home "$sid" && verify_database_open_state "$sid" || return 1
    elif database_pmon_from_target_home "$sid"; then
      verify_successful_database_startup "$sid" "$output" || return 1
    fi
  done < <(opg_manifest_sids)
}

verify_resume_listener_progress() {
  local sid listener
  verify_database_state_unchanged || return 1
  while IFS= read -r sid; do
    [[ "$(opg_read_original_state "$sid" running)" == true ]] || continue
    database_pmon_from_target_home "$sid" || return 1
    verify_database_open_state "$sid" || return 1
  done < <(opg_manifest_sids)
  while IFS= read -r listener; do
    listener_running_wrong_home "$listener" && return 1
  done < <(manifest_listeners)
  return 0
}

verify_resume_environment() {
  verify_static_context_unchanged || return 1
  case "$CURRENT_STATE:$CURRENT_PHASE" in
    MEDIA_VALIDATED:OPATCH_UPGRADE|OPATCH_STAGED:OPATCH_UPGRADE|OPATCH_BACKED_UP:OPATCH_UPGRADE|OPATCH_INSTALLED_UNVERIFIED:OPATCH_UPGRADE|OPATCH_READY:OPATCH_UPGRADE|PARTIAL:OPATCH_STAGED|PARTIAL:OPATCH_BACKED_UP|PARTIAL:OPATCH_INSTALLED_UNVERIFIED) verify_database_state_unchanged ;;
    PARTIAL:DB_BINARY|PARTIAL:OJVM_BINARY|06_DB_BINARY_APPLIED:*|07_OJVM_BINARY_APPLIED:*) verify_manifest_databases_stopped ;;
    PARTIAL:START_DATABASES) verify_resume_start_progress ;;
    PARTIAL:START_LISTENER) verify_resume_listener_progress ;;
    08_DATABASES_STARTED:*|PARTIAL:DATAPATCH|09_DATAPATCH_COMPLETE:*|PARTIAL:UTLRP|10_UTLRP_COMPLETE:*|PARTIAL:VALIDATION|MANUAL_INTERVENTION_REQUIRED:VALIDATION) verify_database_state_unchanged ;;
    12_COMPLETE:*) return 0 ;;
    *) return 2 ;;
  esac
}

preapply_add() {
  local severity=$1 id=$2 message=$3 evidence=${4:-}
  printf '%s|%s|%s|%s\n' "$severity" "$id" "$message" "$evidence" >>"${RUN_DIR}/preapply_findings.psv"
  case "$severity" in
    BLOCKED) PREAPPLY_BLOCKED=$((PREAPPLY_BLOCKED + 1)) ;;
    UNKNOWN) PREAPPLY_UNKNOWN=$((PREAPPLY_UNKNOWN + 1)) ;;
  esac
}

preapply_check_space() {
  local path=$1 minimum=$2 id=$3 free
  free=$(opg_free_mb "$path")
  if [[ ${OPG_TEST_MODE:-0} == 1 && ${MOCK_PREAPPLY_SPACE_LOW:-false} == true ]]; then free=0; minimum=1; fi
  if [[ -z "$free" || ! "$free" =~ ^[0-9]+$ ]]; then
    preapply_add UNKNOWN "$id" "Vrije ruimte kon direct vóór apply niet betrouwbaar worden vastgesteld." "$path"
  elif (( free < minimum )); then
    preapply_add BLOCKED "$id" "Vrije ruimte is sinds assessment onvoldoende geworden." "${path}:${free}MiB<${minimum}MiB"
  fi
}

write_preapply_report() {
  local status=$1 exit_code=$2 first=true severity id message evidence
  {
    printf '{\n  "checked_at": "%s",\n  "hostname": "%s",\n  "target_oracle_home": "%s",\n  "lock_file": "%s",\n  "status": "%s",\n  "exit_code": %s,\n  "findings": [\n' \
      "$(opg_now)" "$(opg_json_escape "$HOST_NAME")" "$(opg_json_escape "$TARGET_ORACLE_HOME")" "$(opg_json_escape "${LOCK_FILE:-}")" "$status" "$exit_code"
    while IFS='|' read -r severity id message evidence; do
      [[ "$first" == true ]] || printf ',\n'; first=false
      printf '    {"severity":"%s","id":"%s","message":"%s","evidence":"%s"}' \
        "$(opg_json_escape "$severity")" "$(opg_json_escape "$id")" "$(opg_json_escape "$message")" "$(opg_json_escape "$evidence")"
    done <"${RUN_DIR}/preapply_findings.psv"
    printf '\n  ]\n}\n'
  } | opg_atomic_write "${RUN_DIR}/preapply_assessment.json"
}

perform_preapply_recheck() {
  local rc opatch_actual central_inventory os_id os_version arch owner db_dir ojvm_dir stored_recovery_hash current_recovery_hash
  local assessed_opatch planned_upgrade version_relation media_rc stored_approval_key_hash current_approval_key_hash
  local OPG_READ_ONLY_PHASE=true OPG_CHECK_PHASE=preapply OPG_WINDOW_BINDING_MODE=formal RECOVERY_MANIFEST_FILE="${RUN_DIR}/preapply_recovery_manifest.json"
  PREAPPLY_BLOCKED=0; PREAPPLY_UNKNOWN=0; : >"${RUN_DIR}/preapply_findings.psv"
  db_dir="${PATCH_ROOT}/${MONTH}/${DB_PATCH}"; ojvm_dir="${PATCH_ROOT}/${MONTH}/${OJVM_PATCH}"

  verify_environment_unchanged || preapply_add BLOCKED ENVIRONMENT_CHANGED "Host, home, manifest, patchset, oratab of databaseconfiguratie is gewijzigd sinds assessment." "Zie preapply_recheck- en manifestlogs."
  stored_approval_key_hash=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" approval_public_key_sha256)
  current_approval_key_hash=$(approval_public_key_sha256 2>/dev/null || printf 'UNAVAILABLE')
  [[ "$stored_approval_key_hash" == "$current_approval_key_hash" && "$stored_approval_key_hash" != UNAVAILABLE ]] || preapply_add BLOCKED APPROVAL_TRUST_CHANGED "Approval-public-key wijkt af van de tijdens assessment vastgelegde trust-anchor." "expected=${stored_approval_key_hash:-UNAVAILABLE}, actual=${current_approval_key_hash:-UNAVAILABLE}"
  [[ -n ${LOCK_FILE:-} ]] || preapply_add BLOCKED LOCK_NOT_HELD "Exclusieve home-lock is niet aantoonbaar verkregen." ""

  owner=$(stat -c '%U' "$TARGET_ORACLE_HOME" 2>/dev/null || true)
  [[ -n "$owner" && "$owner" == "$EXEC_USER" ]] || preapply_add BLOCKED EXECUTION_USER_CHANGED "Uitvoerende gebruiker/home-owner klopt direct vóór apply niet." "user=${EXEC_USER}, owner=${owner:-UNKNOWN}"
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    os_id=${MOCK_OS_ID:-ol}; os_version=${MOCK_OS_VERSION:-8.10}; arch=${MOCK_ARCH:-x86_64}
  else
    os_id=$(awk -F= '$1=="ID"{gsub(/"/,"",$2);print tolower($2);exit}' /etc/os-release 2>/dev/null || true)
    os_version=$(awk -F= '$1=="VERSION_ID"{gsub(/"/,"",$2);print $2;exit}' /etc/os-release 2>/dev/null || true)
    arch=$(uname -m 2>/dev/null || true)
  fi
  [[ "$os_id" =~ ^(ol|oracle|oraclelinux)$ && "$os_version" =~ ^(8|9)([.]|$) && "$arch" == x86_64 ]] || preapply_add BLOCKED PLATFORM_CHANGED "Platformcontrole faalt direct vóór apply." "${os_id} ${os_version} ${arch}"

  opg_run_capture preapply_oracle_version "${RUN_DIR}/preapply_oracle_version.txt" "$TARGET_ORACLE_HOME/bin/sqlplus" -V; rc=$?
  (( rc == 0 )) || preapply_add UNKNOWN ORACLE_VERSION_RECHECK_FAILED "Oracle-versie kon direct vóór apply niet worden bepaald." "${RUN_DIR}/preapply_oracle_version.txt"
  if [[ ${OPG_TEST_MODE:-0} != 1 ]] && ! grep -Eq '19[.]' "${RUN_DIR}/preapply_oracle_version.txt"; then preapply_add BLOCKED ORACLE_VERSION_CHANGED "Oracle-versie is niet langer aantoonbaar 19c." "${RUN_DIR}/preapply_oracle_version.txt"; fi

  opg_run_capture preapply_lsinventory "${RUN_DIR}/preapply_inventory.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" lsinventory -detail; rc=$?
  if (( rc != 0 )) || ! opg_verify_command_success_text "${RUN_DIR}/preapply_inventory.txt"; then
    preapply_add BLOCKED INVENTORY_RECHECK_FAILED "Inventorycontrole faalt direct vóór apply." "${RUN_DIR}/preapply_inventory.txt"
  fi
  opg_run_capture opatch_version "${RUN_DIR}/preapply_opatch_version.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" version; rc=$?
  opatch_actual=$(awk '/OPatch Version/{print $3; exit}' "${RUN_DIR}/preapply_opatch_version.txt")
  assessed_opatch=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" assessed_opatch_version)
  planned_upgrade=$(opg_get_json_boolean "${RUN_DIR}/patch_manifest.json" opatch_upgrade_required)
  version_relation=$(compare_opatch_versions "$opatch_actual" "$OPATCH_VERSION" 2>/dev/null) || version_relation=INVALID
  validate_opatch_media "${RUN_DIR}/preapply_opatch_media_validation.txt"; media_rc=$?
  if (( media_rc == 2 )); then
    preapply_add BLOCKED OPATCH_MEDIA_CHANGED "OPatch-upgrademedium faalt direct vóór apply op checksum, ZIP-integriteit, padveiligheid of interne versie." "${RUN_DIR}/preapply_opatch_media_validation.txt"
  elif (( media_rc != 0 )); then
    preapply_add UNKNOWN OPATCH_MEDIA_RECHECK_UNKNOWN "OPatch-upgrademedium kon direct vóór apply niet betrouwbaar worden gevalideerd." "${RUN_DIR}/preapply_opatch_media_validation.txt"
  fi
  if (( rc != 0 )) || [[ "$version_relation" == INVALID || "$version_relation" == 1 ]]; then
    preapply_add BLOCKED OPATCH_VERSION_CHANGED "OPatch-versie is direct vóór apply onverwacht of niet betrouwbaar." "gevonden=${opatch_actual:-UNKNOWN}, vereist=${OPATCH_VERSION}"
  elif [[ "$version_relation" == -1 ]] &&
       { [[ "$planned_upgrade" != true ]] || [[ "$opatch_actual" != "$assessed_opatch" ]]; }; then
    preapply_add BLOCKED OPATCH_UPGRADE_PLAN_CHANGED "De actieve oudere OPatch-versie komt niet meer overeen met het goedgekeurde upgradeplan." "gevonden=${opatch_actual:-UNKNOWN}, assessed=${assessed_opatch:-UNKNOWN}"
  fi

  opg_run_capture conflict_db_ru "${RUN_DIR}/preapply_conflict_db_ru.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph "$db_dir"; rc=$?
  if (( rc != 0 )) || ! opg_verify_command_success_text "${RUN_DIR}/preapply_conflict_db_ru.txt"; then
    preapply_add BLOCKED DB_RU_CONFLICT_RECHECK "DB-RU-conflictcontrole faalt direct vóór apply." "${RUN_DIR}/preapply_conflict_db_ru.txt"
  fi
  opg_run_capture conflict_ojvm "${RUN_DIR}/preapply_conflict_ojvm.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" prereq CheckConflictAgainstOHWithDetail -ph "$ojvm_dir"; rc=$?
  if (( rc != 0 )) || ! opg_verify_command_success_text "${RUN_DIR}/preapply_conflict_ojvm.txt"; then
    preapply_add BLOCKED OJVM_CONFLICT_RECHECK "OJVM-conflictcontrole faalt direct vóór apply." "${RUN_DIR}/preapply_conflict_ojvm.txt"
  fi

  central_inventory=$(awk -F= '$1 ~ /^[[:space:]]*inventory_loc[[:space:]]*$/ {gsub(/[[:space:]]/,"",$2); print $2; exit}' "$ORAINST_LOC" 2>/dev/null || true)
  [[ ${OPG_TEST_MODE:-0} == 1 ]] && central_inventory=${MOCK_CENTRAL_INVENTORY:-${OPG_FIXTURE_DIR:-$TARGET_ORACLE_HOME}/central_inventory}
  preapply_check_space "$TARGET_ORACLE_HOME" "$MIN_HOME_FREE_MB" HOME_SPACE_CHANGED
  if [[ -n "$central_inventory" && -d "$central_inventory" ]]; then
    preapply_check_space "$central_inventory" "$MIN_INVENTORY_FREE_MB" INVENTORY_SPACE_CHANGED
  else
    preapply_add UNKNOWN INVENTORY_PATH_UNKNOWN "Central inventorypad kon direct vóór apply niet worden gecontroleerd." "${central_inventory:-UNKNOWN}"
  fi
  preapply_check_space "$PATCH_ROOT" "$MIN_STAGE_FREE_MB" STAGE_SPACE_CHANGED
  preapply_check_space /tmp "$MIN_TMP_FREE_MB" TMP_SPACE_CHANGED

  if run_optional_check preapply_backup "$BACKUP_CHECK_COMMAND" true backup; then :; else rc=$?; (( rc == 2 )) && preapply_add BLOCKED BACKUP_CHANGED "Back-upvalidatie faalt direct vóór apply." "${RUN_DIR}/preapply_backup.txt"; (( rc != 2 )) && preapply_add UNKNOWN BACKUP_RECHECK_UNKNOWN "Back-upvalidatie kon direct vóór apply niet betrouwbaar worden uitgevoerd." "${RUN_DIR}/preapply_backup.txt"; fi
  if run_optional_check preapply_oracle_home_recovery "$ORACLE_HOME_RECOVERY_CHECK_COMMAND" true oracle_home_recovery; then
    stored_recovery_hash=$(opg_get_json_string "${RUN_DIR}/patch_manifest.json" recovery_manifest_sha256)
    current_recovery_hash=$(opg_sha256 "$RECOVERY_MANIFEST_FILE" 2>/dev/null || printf UNAVAILABLE)
    [[ "$stored_recovery_hash" == "$current_recovery_hash" ]] || preapply_add BLOCKED HOME_RECOVERY_CHANGED "Oracle Home-herstelroute is gewijzigd sinds assessment." "$RECOVERY_MANIFEST_FILE"
  else rc=$?; (( rc == 2 )) && preapply_add BLOCKED HOME_RECOVERY_CHANGED "Oracle Home-herstelroute faalt direct vóór apply." "${RUN_DIR}/preapply_oracle_home_recovery.txt"; (( rc != 2 )) && preapply_add UNKNOWN HOME_RECOVERY_RECHECK_UNKNOWN "Oracle Home-herstelroute kon niet opnieuw worden bevestigd." "${RUN_DIR}/preapply_oracle_home_recovery.txt"; fi
  if check_datapump_evidence preapply; then :; else rc=$?; (( rc == 2 )) && preapply_add BLOCKED DATAPUMP_ACTIVE_RECHECK "Data Pump-job is direct vóór apply actief." "${RUN_DIR}/preapply_datapump.txt"; (( rc == 3 )) && preapply_add UNKNOWN DATAPUMP_RECHECK_UNKNOWN "Data Pump kon niet opnieuw betrouwbaar worden gecontroleerd." "${RUN_DIR}/preapply_datapump.txt"; fi
  if run_optional_check preapply_dataguard "$DATAGUARD_CHECK_COMMAND" true dataguard; then :; else rc=$?; (( rc == 2 )) && preapply_add BLOCKED DATAGUARD_CHANGED "Data Guard-controle faalt direct vóór apply." "${RUN_DIR}/preapply_dataguard.txt"; (( rc != 2 )) && preapply_add UNKNOWN DATAGUARD_RECHECK_UNKNOWN "Data Guard-status kon niet opnieuw worden bewezen." "${RUN_DIR}/preapply_dataguard.txt"; fi
  if run_optional_check preapply_maintenance_window "$MAINTENANCE_WINDOW_CHECK_COMMAND" false maintenance_window; then :; else rc=$?; (( rc == 2 )) && preapply_add BLOCKED WINDOW_CHANGED "Onderhoudsvenster is direct vóór apply onvoldoende." "${RUN_DIR}/preapply_maintenance_window.txt"; (( rc != 2 )) && preapply_add UNKNOWN WINDOW_RECHECK_UNKNOWN "Onderhoudsvenster kon niet opnieuw worden bevestigd." "${RUN_DIR}/preapply_maintenance_window.txt"; fi

  if (( PREAPPLY_BLOCKED > 0 )); then write_preapply_report BLOCKED "$EXIT_BLOCKED"; return "$EXIT_BLOCKED"; fi
  if (( PREAPPLY_UNKNOWN > 0 )); then write_preapply_report UNKNOWN "$EXIT_UNKNOWN"; return "$EXIT_UNKNOWN"; fi
  write_preapply_report READY "$EXIT_OK"
  return 0
}

confirm_interactive_apply() {
  local expected="APPLY ${DB_PATCH} TO ${TARGET_ORACLE_HOME}" answer
  [[ "$NON_INTERACTIVE" == true ]] && return 0
  printf 'Typ exact: %s\n> ' "$expected" >&2
  IFS= read -r answer
  [[ "$answer" == "$expected" ]]
}

opatch_version_at() {
  local directory=$1 label=$2 output=$3 version rc
  [[ -x "$directory/opatch" ]] || return 1
  opg_run_capture "$label" "$output" "$directory/opatch" version; rc=$?
  (( rc == 0 )) || return "$rc"
  version=$(sed -nE 's/^[[:space:]]*OPatch Version[[:space:]]*:[[:space:]]*([^[:space:]\r]+).*$/\1/p' "$output" | head -1)
  [[ -n "$version" ]] || return 1
  printf '%s\n' "$version"
}

opatch_upgrade_metadata_value() {
  local key=$1
  awk -F= -v key="$key" '$1==key{sub(/^[^=]*=/,"");print;exit}' "${RUN_DIR}/opatch_upgrade_metadata.txt"
}

validate_staged_opatch() {
  local stage_opatch=$1 expected_uid expected_gid actual_uid actual_gid actual_mode staged_version
  [[ -d "$stage_opatch" && ! -L "$stage_opatch" && -x "$stage_opatch/opatch" ]] || return 1
  expected_uid=$(opatch_upgrade_metadata_value old_uid)
  expected_gid=$(opatch_upgrade_metadata_value old_gid)
  actual_uid=$(stat -c '%u' "$stage_opatch/opatch" 2>/dev/null) || return 1
  actual_gid=$(stat -c '%g' "$stage_opatch/opatch" 2>/dev/null) || return 1
  actual_mode=$(stat -c '%a' "$stage_opatch/opatch" 2>/dev/null) || return 1
  [[ "$actual_uid" == "$expected_uid" && "$actual_gid" == "$expected_gid" && "$actual_mode" =~ ^[0-7]{3,4}$ ]] || return 1
  (( (8#$actual_mode & 0022) == 0 && (8#$actual_mode & 0100) != 0 )) || return 1
  staged_version=$(opatch_version_at "$stage_opatch" opatch_stage_version "${RUN_DIR}/opatch_staged_version.txt") || return 1
  [[ "$staged_version" == "$OPATCH_VERSION" ]] || return 1
  opg_log INFO "OPATCH_STAGE_VALID|path=${stage_opatch}|version=${staged_version}|uid=${actual_uid}|gid=${actual_gid}|mode=${actual_mode}"
}

stage_opatch_upgrade() {
  local live="${TARGET_ORACLE_HOME}/OPatch" stage_root="${TARGET_ORACLE_HOME}/OPatch.stage-${RUN_ID}"
  local zip="${OPATCH_ROOT}/${OPATCH_ZIPFILE}" old_uid old_gid old_mode free_mb old_mb zip_mb required_mb live_dev stage_dev
  if [[ -e "$stage_root" ]]; then
    validate_staged_opatch "${stage_root}/OPatch"
    return $?
  fi
  [[ -d "$live" && ! -L "$live" && -x "$live/opatch" ]] || return 1
  old_uid=$(stat -c '%u' "$live/opatch" 2>/dev/null) || return 1
  old_gid=$(stat -c '%g' "$live/opatch" 2>/dev/null) || return 1
  old_mode=$(stat -c '%a' "$live/opatch" 2>/dev/null) || return 1
  free_mb=$(opg_free_mb "$TARGET_ORACLE_HOME") || return 1
  old_mb=$(du -sm -- "$live" 2>/dev/null | awk '{print $1}') || return 1
  zip_mb=$(du -m -- "$zip" 2>/dev/null | awk '{print $1}') || return 1
  [[ "$free_mb" =~ ^[0-9]+$ && "$old_mb" =~ ^[0-9]+$ && "$zip_mb" =~ ^[0-9]+$ ]] || return 1
  required_mb=$((old_mb + (2 * zip_mb) + OPATCH_UPGRADE_MIN_FREE_MB))
  (( free_mb >= required_mb )) || { opg_log ERROR "OPATCH_STAGE_SPACE|free_mib=${free_mb}|required_mib=${required_mb}"; return 1; }
  opg_atomic_write "${RUN_DIR}/opatch_upgrade_metadata.txt" <<EOF
run_id=${RUN_ID}
home=${TARGET_ORACLE_HOME}
zip=${zip}
zip_sha256=$(opg_sha256 "$zip")
old_version=${OPATCH_ACTUAL_VERSION}
required_version=${OPATCH_VERSION}
old_uid=${old_uid}
old_gid=${old_gid}
old_mode=${old_mode}
stage=${stage_root}
backup=${TARGET_ORACLE_HOME}/OPatch.before-${RUN_ID}
free_mib=${free_mb}
required_mib=${required_mb}
EOF
  mkdir -- "$stage_root" || return 1
  live_dev=$(stat -c '%d' "$live" 2>/dev/null) || return 1
  stage_dev=$(stat -c '%d' "$stage_root" 2>/dev/null) || return 1
  [[ "$live_dev" == "$stage_dev" ]] || { opg_log ERROR "OPATCH_STAGE_FILESYSTEM|live_device=${live_dev}|stage_device=${stage_dev}"; return 1; }
  opg_log INFO "OPATCH_STAGE_START|zip=${zip}|stage=${stage_root}|free_mib=${free_mb}|required_mib=${required_mb}"
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    cp -a -- "$live" "$stage_root/" || return 1
    printf '%s\n' "${MOCK_OPATCH_STAGED_VERSION:-$OPATCH_VERSION}" >"${stage_root}/OPatch/.opg-version"
  else
    unzip -q "$zip" -d "$stage_root" >>"${RUN_DIR}/opatch_stage_extract.log" 2>&1 || return 1
  fi
  validate_staged_opatch "${stage_root}/OPatch" || return 1
  opg_write_state OPATCH_STAGED OPATCH_UPGRADE
  opg_log INFO "OPATCH_STAGE_END|status=OK|stage=${stage_root}"
}

validate_active_opatch_after_upgrade() {
  local live="${TARGET_ORACLE_HOME}/OPatch" active_version uid gid mode
  active_version=$(opatch_version_at "$live" opatch_active_version_after_upgrade "${RUN_DIR}/opatch_active_version_after_upgrade.txt") || return 1
  [[ "$active_version" == "$OPATCH_VERSION" ]] || return 1
  uid=$(stat -c '%u' "$live/opatch" 2>/dev/null) || return 1
  gid=$(stat -c '%g' "$live/opatch" 2>/dev/null) || return 1
  mode=$(stat -c '%a' "$live/opatch" 2>/dev/null) || return 1
  [[ "$uid" == "$(opatch_upgrade_metadata_value old_uid)" && "$gid" == "$(opatch_upgrade_metadata_value old_gid)" ]] || return 1
  (( (8#$mode & 0022) == 0 && (8#$mode & 0100) != 0 )) || return 1
  opg_run_capture opatch_upgrade_inventory "${RUN_DIR}/opatch_upgrade_inventory.txt" "$live/opatch" lsinventory -detail || return 1
  opg_verify_command_success_text "${RUN_DIR}/opatch_upgrade_inventory.txt" || return 1
  opg_log INFO "OPATCH_ACTIVE_VALID|version=${active_version}|uid=${uid}|gid=${gid}|mode=${mode}|backup=${TARGET_ORACLE_HOME}/OPatch.before-${RUN_ID}"
}

perform_opatch_upgrade() {
  local live="${TARGET_ORACLE_HOME}/OPatch" stage_root="${TARGET_ORACLE_HOME}/OPatch.stage-${RUN_ID}"
  local staged="${TARGET_ORACLE_HOME}/OPatch.stage-${RUN_ID}/OPatch" backup="${TARGET_ORACLE_HOME}/OPatch.before-${RUN_ID}"
  local active_version relation media_rc planned_upgrade
  planned_upgrade=$(opg_get_json_boolean "${RUN_DIR}/patch_manifest.json" opatch_upgrade_required)
  if [[ "$CURRENT_STATE:$CURRENT_PHASE" == 04_APPROVED:APPROVAL ]] &&
     { [[ -e "$stage_root" ]] || [[ -e "$backup" ]]; }; then
    opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_UPGRADE "Rungebonden OPatch-stage of backup bestond al vóór de upgrade en wordt niet hergebruikt of overschreven." 1
    return 1
  fi
  if [[ -x "$live/opatch" ]]; then
    active_version=$(opatch_version_at "$live" opatch_version "${RUN_DIR}/opatch_version_before_upgrade.txt") || active_version=UNKNOWN
    relation=$(compare_opatch_versions "$active_version" "$OPATCH_VERSION" 2>/dev/null) || relation=INVALID
    if [[ "$relation" == 0 ]]; then
      if [[ -e "$backup" ]]; then
        [[ -r "${RUN_DIR}/opatch_upgrade_metadata.txt" ]] || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_UPGRADE "Actieve OPatch is vervangen, maar rungebonden upgrademetadata ontbreekt." 1; return 1; }
        opg_write_state OPATCH_INSTALLED_UNVERIFIED OPATCH_UPGRADE
        validate_active_opatch_after_upgrade || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_UPGRADE "Nieuwe actieve OPatch kon niet exact worden gevalideerd; automatische rollback is uitgeschakeld." 1; return 1; }
      else
        opg_run_capture opatch_upgrade_inventory "${RUN_DIR}/opatch_upgrade_inventory.txt" "$live/opatch" lsinventory -detail || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_UPGRADE "Bestaande vereiste OPatch kan de inventory niet lezen." 1; return 1; }
      fi
      opg_write_state OPATCH_READY OPATCH_UPGRADE
      opg_log INFO "OPATCH_UPGRADE_SKIP|reason=active_version_exact|version=${active_version}"
      return 0
    fi
    if [[ "$planned_upgrade" != true || "$active_version" != "$OPATCH_ACTUAL_VERSION" || "$relation" != -1 ]]; then
      opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_UPGRADE "Actieve OPatch-toestand wijkt af van het goedgekeurde upgradeplan; automatische downgrade/rollback is uitgeschakeld." 1
      return 1
    fi
  elif [[ ! -d "$backup" ]]; then
    opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_UPGRADE "Actieve OPatch ontbreekt zonder aantoonbare rungebonden backup." 1
    return 1
  fi

  validate_opatch_media "${RUN_DIR}/apply_opatch_media_validation.txt"; media_rc=$?
  if (( media_rc != 0 )); then
    if (( media_rc == 3 )); then
      opg_mark_failure UNKNOWN OPATCH_MEDIA "OPatch-medium kon vóór de upgrade niet betrouwbaar worden gevalideerd; geen downtime gestart." "$media_rc"
    else
      opg_mark_failure BLOCKED OPATCH_MEDIA "OPatch-medium faalt vóór de upgrade; geen downtime gestart." "$media_rc"
    fi
    return 1
  fi
  opg_write_state MEDIA_VALIDATED OPATCH_UPGRADE

  if [[ ! -e "$backup" ]]; then
    stage_opatch_upgrade || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_STAGING "OPatch-staging kon niet veilig worden voltooid; de actieve OPatch is niet vervangen." 1; return 1; }
    if [[ ${MOCK_OPATCH_INTERRUPT_AFTER:-} == STAGING ]]; then
      opg_mark_failure PARTIAL OPATCH_STAGED "Gesimuleerde onderbreking na OPatch-staging." 1
      return 1
    fi
    [[ ! -e "$backup" ]] || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_BACKUP "Rungebonden OPatch-backup bestaat al en wordt niet overschreven." 1; return 1; }
    opg_log INFO "OPATCH_BACKUP_START|source=${live}|backup=${backup}"
    mv -- "$live" "$backup" || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_BACKUP "Bestaande OPatch kon niet atomair naar de rungebonden backup worden verplaatst." 1; return 1; }
    opg_write_state OPATCH_BACKED_UP OPATCH_UPGRADE
    opg_log INFO "OPATCH_BACKUP_END|status=OK|backup=${backup}"
    if [[ ${MOCK_OPATCH_INTERRUPT_AFTER:-} == BACKUP ]]; then
      opg_mark_failure PARTIAL OPATCH_BACKED_UP "Gesimuleerde onderbreking na OPatch-backup." 1
      return 1
    fi
  fi

  if [[ ! -e "$live" ]]; then
    if [[ ! -d "$backup" || ! -d "$staged" ]] || ! validate_staged_opatch "$staged"; then
      opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_PROMOTION "Backup/staging vormen geen aantoonbaar veilige resume-toestand; automatische rollback is uitgeschakeld." 1
      return 1
    fi
    opg_log INFO "OPATCH_PROMOTE_START|stage=${staged}|target=${live}"
    mv -- "$staged" "$live" || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_PROMOTION "Gestagede OPatch kon niet atomair worden gepromoveerd; automatische rollback is uitgeschakeld." 1; return 1; }
    opg_write_state OPATCH_INSTALLED_UNVERIFIED OPATCH_UPGRADE
    opg_log INFO "OPATCH_PROMOTE_END|status=OK|target=${live}|stage_root=${stage_root}"
    if [[ ${MOCK_OPATCH_INTERRUPT_AFTER:-} == PROMOTION ]]; then
      opg_mark_failure PARTIAL OPATCH_INSTALLED_UNVERIFIED "Gesimuleerde onderbreking na OPatch-promotie." 1
      return 1
    fi
  fi
  validate_active_opatch_after_upgrade || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OPATCH_UPGRADE "Nieuwe actieve OPatch-versie/inventory/permissions zijn niet exact valide; automatische rollback is uitgeschakeld." 1; return 1; }
  opg_write_state OPATCH_READY OPATCH_UPGRADE
  opg_log INFO "OPATCH_UPGRADE_COMPLETE|old_version=${OPATCH_ACTUAL_VERSION}|new_version=${OPATCH_VERSION}|backup=${backup}"
}

stop_databases() {
  local sid running output
  while IFS= read -r sid; do
    running=$(opg_read_original_state "$sid" running)
    [[ "$running" == true ]] || { opg_log INFO "SID ${sid} was vooraf gestopt en blijft gestopt."; continue; }
    output="${RUN_DIR}/shutdown_${sid}.log"
    if ! opg_sqlplus "$sid" "shutdown_${sid}" "${RUN_DIR}/shutdown.sql" "$output" ||
       ! opg_verify_command_success_text "$output"; then
      opg_mark_failure PARTIAL STOP_DATABASES "Shutdown mislukt voor ${sid}." 1
      return 1
    fi
  done < <(opg_manifest_sids)
  stop_original_listeners || return 1
  opg_write_state 05_DATABASES_STOPPED STOP_DATABASES
}

manifest_listeners() {
  awk -F, 'NR>1 {v=$9; gsub(/^"|"$/, "", v); if (v!="" && v!="UNKNOWN" && v!="NONE") print v}' "${RUN_DIR}/database_state_before.csv" | tr ';' '\n' | sort -u
}

stop_original_listeners() {
  local listener output
  [[ "$MANAGE_LISTENERS" == true ]] || return 0
  while IFS= read -r listener; do
    [[ "$listener" =~ ^[A-Za-z0-9_.-]+$ ]] || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED STOP_LISTENER "Ongeldige listenernaam in manifest: ${listener}." 1; return 1; }
    output="${RUN_DIR}/listener_stop_${listener}.log"
    if ! opg_run_capture "listener_stop_${listener}" "$output" "$TARGET_ORACLE_HOME/bin/lsnrctl" stop "$listener" ||
       ! opg_verify_command_success_text "$output" 'TNS-|NL-|Listener failed|FAILED'; then
      opg_mark_failure PARTIAL STOP_LISTENER "Listener stop mislukt voor ${listener}." 1
      return 1
    fi
    if [[ "$DRY_RUN" != true && ${OPG_TEST_MODE:-0} != 1 ]] && ! wait_for_listener_stopped "$listener"; then
      opg_mark_failure PARTIAL STOP_LISTENER "Listener ${listener} draait na de begrensde stop-wachttijd nog steeds." 1
      return 1
    fi
  done < <(manifest_listeners)
}

wait_for_listener_stopped() {
  local listener=$1 started now deadline
  started=$(date +%s); deadline=$((started + LISTENER_STOP_TIMEOUT_SECONDS))
  opg_log INFO "LISTENER_STOP_WAIT_START|listener=${listener}|timeout_seconds=${LISTENER_STOP_TIMEOUT_SECONDS}"
  while listener_running_from_target_home "$listener"; do
    now=$(date +%s)
    (( now < deadline )) || { opg_log ERROR "LISTENER_STOP_WAIT_END|listener=${listener}|status=TIMEOUT|duration_seconds=$((now-started))"; return 1; }
    sleep "$LISTENER_POLL_SECONDS"
  done
  now=$(date +%s); opg_log INFO "LISTENER_STOP_WAIT_END|listener=${listener}|status=STOPPED|duration_seconds=$((now-started))"
}

listener_status_has_ready_service() {
  local output=$1 service=$2 sid=$3
  awk -v wanted_service="$service" -v wanted_sid="$sid" '
    /^Service "/ {
      current=$0; sub(/^Service "/,"",current); sub(/".*/,"",current)
      service_matches=(current==wanted_service)
      if (!service_matches && index(wanted_service,".")==0 && index(current,wanted_service ".")==1 && length(current)>length(wanted_service)+1) service_matches=1
      next
    }
    service_matches && /^  Instance "/ {
      instance=$0; sub(/^  Instance "/,"",instance); sub(/".*/,"",instance)
      if (instance==wanted_sid && $0 ~ /status READY([,[:space:]]|$)/) found=1
    }
    END { exit(found ? 0 : 1) }' "$output"
}

verify_listener_ready() {
  local listener=$1 output=$2 alias sid services service
  listener_running_from_target_home "$listener" || return 1
  opg_run_capture "listener_status_${listener}" "$output" "$TARGET_ORACLE_HOME/bin/lsnrctl" status "$listener" || return 1
  opg_verify_command_success_text "$output" 'TNS-|NL-|Listener failed|FAILED' || return 1
  alias=$(awk '$1=="Alias" {print $2; exit}' "$output")
  [[ "$alias" == "$listener" ]] || return 1
  while IFS= read -r sid; do
    [[ "$(opg_read_original_state "$sid" running)" == true ]] || continue
    services=$(opg_read_original_state "$sid" services)
    [[ -n "$services" && "$services" != UNKNOWN ]] || return 1
    while IFS= read -r service; do
      [[ -n "$service" ]] || continue
      listener_status_has_ready_service "$output" "$service" "$sid" || return 1
    done < <(printf '%s\n' "$services" | tr ';' '\n')
  done < <(opg_manifest_sids)
}

wait_for_listener_ready() {
  local listener=$1 output=$2 started now deadline attempt=0
  started=$(date +%s); deadline=$((started + LISTENER_READY_TIMEOUT_SECONDS))
  opg_log INFO "LISTENER_READY_WAIT_START|listener=${listener}|timeout_seconds=${LISTENER_READY_TIMEOUT_SECONDS}"
  while true; do
    attempt=$((attempt + 1))
    if verify_listener_ready "$listener" "$output"; then
      now=$(date +%s); opg_log INFO "LISTENER_READY_POLL|listener=${listener}|attempt=${attempt}|status=READY"
      opg_log INFO "LISTENER_READY_WAIT_END|listener=${listener}|status=READY|attempts=${attempt}|duration_seconds=$((now-started))"; return 0
    fi
    now=$(date +%s)
    opg_log INFO "LISTENER_READY_POLL|listener=${listener}|attempt=${attempt}|status=NOT_READY"
    (( now < deadline )) || { opg_log ERROR "LISTENER_READY_WAIT_END|listener=${listener}|status=TIMEOUT|attempts=${attempt}|duration_seconds=$((now-started))"; return 1; }
    sleep "$LISTENER_POLL_SECONDS"
  done
}

register_original_databases() {
  local sid running output
  while IFS= read -r sid; do
    running=$(opg_read_original_state "$sid" running)
    [[ "$running" == true ]] || continue
    database_pmon_from_target_home "$sid" || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED REGISTER_SERVICES "PMON voor ${sid} komt niet aantoonbaar uit de target Oracle Home." 1; return 1; }
    verify_database_open_state "$sid" || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED REGISTER_SERVICES "Database ${sid} is niet vers OPEN/ACTIVE/READ WRITE vóór listenerregistratie." 1; return 1; }
    output="${RUN_DIR}/listener_register_${sid}.log"
    opg_log INFO "LISTENER_REGISTER_START|sid=${sid}|home=${TARGET_ORACLE_HOME}"
    if ! opg_sqlplus "$sid" "listener_register_${sid}" "${RUN_DIR}/alter_system_register.sql" "$output" ||
       ! opg_verify_command_success_text "$output"; then
      opg_mark_failure MANUAL_INTERVENTION_REQUIRED REGISTER_SERVICES "ALTER SYSTEM REGISTER is mislukt voor ${sid}." 1
      return 1
    fi
    opg_log INFO "LISTENER_REGISTER_END|sid=${sid}|status=OK|evidence=${output}"
  done < <(opg_manifest_sids)
}

start_original_listeners() {
  local listener output marker previous_rc
  [[ "$MANAGE_LISTENERS" == true ]] || return 0
  while IFS= read -r listener; do
    [[ "$listener" =~ ^[A-Za-z0-9_.-]+$ ]] || return 1
    output="${RUN_DIR}/listener_start_${listener}.log"
    marker="${RUN_DIR}/listener_start_${listener}.complete"

    # Bij resume kan de listener handmatig al correct zijn gestart.
    # In dat geval niet opnieuw lsnrctl start uitvoeren.
    if [[ ! -e "$marker" ]] && listener_running_from_target_home "$listener"; then
      wait_for_listener_ready "$listener" "$output" || {
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_LISTENER "Draaiende listener ${listener} mist de verwachte READY-services of draait niet betrouwbaar." 1
        return 1
      }
      opg_write_completion_marker "$marker" "$output" "$listener" listener_start || {
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_LISTENER "Listener completion-marker kon niet veilig worden hersteld voor ${listener}." 1
        return 1
      }
      continue
    fi

    if [[ -e "$marker" ]]; then
      opg_completion_marker_valid "$marker" "$output" "$listener" listener_start || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_LISTENER "Ongeldig completion-marker voor listener ${listener}." 1; return 1; }
      wait_for_listener_ready "$listener" "$output" || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_LISTENER "Listenermarker bestaat maar listener ${listener} is niet volledig READY." 1; return 1; }
      continue
    fi
    if [[ -e "$output" ]]; then
      previous_rc=$(opg_last_command_exit "listener_start_${listener}")
      [[ -n "$previous_rc" && "$previous_rc" != 0 ]] || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_LISTENER "Eerdere listenerstart zonder geldig completion-marker is ambigu voor ${listener}." 1; return 1; }
    fi
    if ! opg_run_capture "listener_start_${listener}" "$output" "$TARGET_ORACLE_HOME/bin/lsnrctl" start "$listener" ||
       ! opg_verify_command_success_text "$output" 'TNS-|NL-|Listener failed|FAILED'; then
      opg_mark_failure PARTIAL START_LISTENER "Listener start mislukt voor ${listener}." 1
      return 1
    fi
    wait_for_listener_ready "$listener" "$output" || { opg_mark_failure PARTIAL START_LISTENER "Listener ${listener} draait na start niet met alle verwachte READY-services uit de doelhome." 1; return 1; }
    opg_write_completion_marker "$marker" "$output" "$listener" listener_start || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_LISTENER "Listener completion-marker kon niet worden geschreven voor ${listener}." 1; return 1; }
  done < <(manifest_listeners)
}

listener_running_from_target_home() {
  local listener=$1 process_dir exe cmdline
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    [[ ${MOCK_LISTENER_STATE_FAILURE:-false} != true && ${MOCK_LISTENER_WRONG_HOME:-false} != true && ${MOCK_LISTENER_RUNNING:-true} == true ]]
    return $?
  fi
  for process_dir in /proc/[0-9]*; do
    [[ -r "$process_dir/exe" ]] || continue
    exe=$(readlink -f "$process_dir/exe" 2>/dev/null || true)
    [[ "$exe" == "$TARGET_ORACLE_HOME/bin/tnslsnr" ]] || continue
    cmdline=$(tr '\0' ' ' <"$process_dir/cmdline" 2>/dev/null || true)
    [[ " $cmdline " == *" ${listener} "* ]] && return 0
  done
  return 1
}

listener_running_wrong_home() {
  local listener=$1 process_dir exe cmdline
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    [[ ${MOCK_LISTENER_WRONG_HOME:-false} == true ]]
    return $?
  fi
  for process_dir in /proc/[0-9]*; do
    [[ -r "$process_dir/exe" ]] || continue
    cmdline=$(tr '\0' ' ' <"$process_dir/cmdline" 2>/dev/null || true)
    [[ " $cmdline " == *" ${listener} "* ]] || continue
    exe=$(readlink -f "$process_dir/exe" 2>/dev/null || true)
    [[ "$exe" == */tnslsnr && "$exe" != "$TARGET_ORACLE_HOME/bin/tnslsnr" ]] && return 0
  done
  return 1
}

database_pmon_from_target_home() {
  local sid=$1 pid exe
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    [[ ${MOCK_STARTUP_PMON_PRESENT:-true} == true && ${MOCK_STARTUP_PMON_WRONG_HOME:-false} != true ]]
    return $?
  fi
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    exe=$(readlink -f "/proc/${pid}/exe" 2>/dev/null || true)
    [[ "$exe" == "$TARGET_ORACLE_HOME/bin/oracle" ]] && return 0
  done < <(pgrep -f "ora_pmon_${sid}([^A-Za-z0-9_]|$)" 2>/dev/null || true)
  return 1
}

verify_database_open_state() {
  local sid=$1 output
  output="${RUN_DIR}/startup_verify_${sid}.log"
  opg_sqlplus "$sid" "startup_verify_${sid}" "${RUN_DIR}/startup_verify.sql" "$output" &&
    opg_verify_command_success_text "$output" &&
    grep -Fxq 'STARTUP_STATE|OPEN|ACTIVE|READ WRITE' "$output"
}

prepare_pdbs_for_datapatch() {
  local sid=$1 cdb states entry pdb mode tag con_id name open_mode extra
  local oracle_name_regex='^[A-Za-z][A-Za-z0-9_$#]{0,29}$'
  local before_output after_output sql_file expected_file alter_count=0 expected_count=0 actual_count=0
  local -a entries=()
  local -A expected_modes=() current_modes=() container_ids=() seen_ids=() final_modes=() final_ids=()
  cdb=$(opg_read_original_state "$sid" cdb)
  expected_file="${RUN_DIR}/datapatch_expected_containers_${sid}.psv"
  if [[ "$cdb" == NO ]]; then
    printf '0|NONCDB\n' | opg_atomic_write "$expected_file"
    return $?
  fi
  [[ "$cdb" == YES ]] || return 1

  states=$(opg_read_original_state "$sid" pdb_status)
  if [[ -n "$states" ]]; then
    IFS=';' read -ra entries <<<"$states"
    for entry in "${entries[@]}"; do
      pdb=${entry%%=*}; mode=${entry#*=}
      [[ "$pdb" =~ $oracle_name_regex && "$pdb" != "PDB\$SEED" ]] || return 1
      [[ -z ${expected_modes[$pdb]+x} ]] || return 1
      case "$mode" in 'READ WRITE'|'READ ONLY'|MOUNTED) ;; *) return 1 ;; esac
      expected_modes[$pdb]=$mode
      expected_count=$((expected_count + 1))
    done
  fi

  before_output="${RUN_DIR}/datapatch_containers_before_${sid}.log"
  opg_sqlplus "$sid" "datapatch_containers_before_${sid}" "${RUN_DIR}/datapatch_containers.sql" "$before_output" &&
    opg_verify_command_success_text "$before_output" || return 1
  while IFS='|' read -r tag con_id name open_mode extra; do
    [[ "$tag" == DATAPATCH_CONTAINER && -z "$extra" ]] || return 1
    [[ "$con_id" =~ ^[0-9]+$ && "$name" =~ $oracle_name_regex ]] || return 1
    [[ "$open_mode" == 'READ WRITE' || "$open_mode" == 'READ ONLY' || "$open_mode" == MOUNTED ]] || return 1
    [[ -z ${seen_ids[$con_id]+x} && -z ${current_modes[$name]+x} ]] || return 1
    if [[ "$con_id" == 1 ]]; then
      [[ "$name" == "CDB\$ROOT" && "$open_mode" == 'READ WRITE' ]] || return 1
    else
      [[ "$con_id" -gt 2 && -n ${expected_modes[$name]+x} ]] || return 1
    fi
    seen_ids[$con_id]=$name; current_modes[$name]=$open_mode; container_ids[$name]=$con_id
    actual_count=$((actual_count + 1))
  done < <(grep '^DATAPATCH_CONTAINER|' "$before_output")
  [[ $actual_count -eq $((expected_count + 1)) && ${seen_ids[1]:-} == "CDB\$ROOT" ]] || return 1
  for pdb in "${!expected_modes[@]}"; do [[ -n ${current_modes[$pdb]+x} ]] || return 1; done

  {
    printf "1|CDB\$ROOT\n"
    for pdb in "${!expected_modes[@]}"; do printf '%s|%s\n' "${container_ids[$pdb]}" "$pdb"; done | sort -t'|' -k1,1n
  } | opg_atomic_write "$expected_file" || return 1
  for pdb in "${!expected_modes[@]}"; do
    [[ ${current_modes[$pdb]} == 'READ WRITE' ]] || alter_count=$((alter_count + 1))
  done

  sql_file="${RUN_DIR}/prepare_datapatch_pdb_${sid}.sql"
  {
    printf 'whenever sqlerror exit failure rollback\n'
    for entry in "${entries[@]}"; do
      pdb=${entry%%=*}; open_mode=${current_modes[$pdb]}
      [[ "$open_mode" == 'READ WRITE' ]] && continue
      printf 'prompt DATAPATCH_PDB_PREPARE|%s|current=%s|desired=READ WRITE\n' "$pdb" "$open_mode"
      [[ "$open_mode" == 'READ ONLY' ]] && printf 'alter pluggable database "%s" close immediate;\n' "$pdb"
      printf 'alter pluggable database "%s" open read write;\n' "$pdb"
    done
    printf 'exit success\n'
  } | opg_atomic_write "$sql_file" || return 1
  if (( alter_count > 0 )); then
    opg_sqlplus "$sid" "prepare_datapatch_pdb_${sid}" "$sql_file" "${RUN_DIR}/prepare_datapatch_pdb_${sid}.log" &&
      opg_verify_command_success_text "${RUN_DIR}/prepare_datapatch_pdb_${sid}.log" || return 1
  else
    printf 'DATAPATCH_PDB_PREPARE|UNCHANGED|sid=%s\n' "$sid" >"${RUN_DIR}/prepare_datapatch_pdb_${sid}.log"
  fi

  after_output="${RUN_DIR}/datapatch_containers_after_${sid}.log"
  opg_sqlplus "$sid" "datapatch_containers_after_${sid}" "${RUN_DIR}/datapatch_containers.sql" "$after_output" &&
    opg_verify_command_success_text "$after_output" || return 1
  actual_count=0
  while IFS='|' read -r tag con_id name open_mode extra; do
    [[ "$tag" == DATAPATCH_CONTAINER && -z "$extra" && "$con_id" =~ ^[0-9]+$ ]] || return 1
    [[ "$name" =~ $oracle_name_regex && "$open_mode" == 'READ WRITE' ]] || return 1
    [[ -z ${final_ids[$con_id]+x} && -z ${final_modes[$name]+x} ]] || return 1
    [[ ${seen_ids[$con_id]:-} == "$name" ]] || return 1
    final_ids[$con_id]=$name; final_modes[$name]=$open_mode
    actual_count=$((actual_count + 1))
  done < <(grep '^DATAPATCH_CONTAINER|' "$after_output")
  [[ $actual_count -eq $((expected_count + 1)) ]] || return 1
  while IFS='|' read -r con_id name extra; do
    [[ -z "$extra" && ${final_ids[$con_id]:-} == "$name" ]] || return 1
  done <"$expected_file"
}

validate_datapatch_sqlpatch_output() {
  local sid=$1 output=$2 expected_file tag con_id name patch_id action status action_time extra key label line failed=0
  local oracle_name_regex='^[A-Za-z][A-Za-z0-9_$#]{0,29}$'
  local -a patch_ids=("$DB_PATCH")
  local -A expected_containers=() expected_patches=() seen=()
  expected_file="${RUN_DIR}/datapatch_expected_containers_${sid}.psv"
  [[ -s "$expected_file" && -r "$output" ]] || return 1
  [[ "$DB_PATCH" =~ ^[0-9]+$ ]] || return 1
  if [[ -n "$OJVM_PATCH" ]]; then
    [[ "$OJVM_PATCH" =~ ^[0-9]+$ && "$OJVM_PATCH" != "$DB_PATCH" ]] || return 1
    patch_ids+=("$OJVM_PATCH")
  fi
  for patch_id in "${patch_ids[@]}"; do expected_patches[$patch_id]=1; done
  while IFS='|' read -r con_id name extra; do
    [[ -z "$extra" && "$con_id" =~ ^[0-9]+$ && "$name" =~ $oracle_name_regex ]] || return 1
    [[ -z ${expected_containers[$con_id]+x} ]] || return 1
    expected_containers[$con_id]=$name
  done <"$expected_file"
  [[ ${#expected_containers[@]} -gt 0 ]] || return 1

  # SQL selects the latest timestamp across ALL actions/statuses, retaining ties.
  # Historical APPLY/SUCCESS remains allowed; this does not bind a new attempt.
  # Parse the entire dedicated SQL output, not grep-selected partial records.
  while IFS= read -r line; do
    [[ "$line" =~ ^[[:space:]]*$ ]] && continue
    if [[ ${OPG_TEST_MODE:-0} == 1 && "$line" == 'MOCK label='* ]]; then continue; fi
    [[ "$line" =~ ^CDB_SQLPATCH\|[0-9]+\|[A-Za-z][A-Za-z0-9_\$#]{0,29}\|[0-9]+\|[A-Z]+\|[A-Z\ ]+\|[0-9]{20}$ ]] || {
      opg_log ERROR "DATAPATCH_CONTAINER_VALIDATION|sid=${sid}|result=FAIL|reason=unparseable_record"
      return 1
    }
    IFS='|' read -r tag con_id name patch_id action status action_time extra <<<"$line"
    if [[ "$tag" != CDB_SQLPATCH || -n "$extra" || ! "$con_id" =~ ^[0-9]+$ ||
          ! "$name" =~ $oracle_name_regex || ! "$patch_id" =~ ^[0-9]+$ ||
          ! "$action_time" =~ ^[0-9]{20}$ ]]; then
      opg_log ERROR "DATAPATCH_CONTAINER_VALIDATION|sid=${sid}|result=FAIL|reason=unparseable_record"
      return 1
    fi
    [[ ${expected_containers[$con_id]:-} == "$name" && -n ${expected_patches[$patch_id]+x} ]] || {
      opg_log ERROR "DATAPATCH_CONTAINER_VALIDATION|sid=${sid}|container=${name}|con_id=${con_id}|patch=${patch_id}|result=FAIL|reason=unexpected_record"
      return 1
    }
    key="${con_id}|${patch_id}"
    [[ -z ${seen[$key]+x} ]] || {
      opg_log ERROR "DATAPATCH_CONTAINER_VALIDATION|sid=${sid}|container=${name}|con_id=${con_id}|patch=${patch_id}|result=FAIL|reason=ambiguous_duplicate"
      return 1
    }
    seen[$key]=$status
    [[ "$patch_id" == "$DB_PATCH" ]] && label=RU || label=OJVM
    opg_log INFO "DATAPATCH_CONTAINER_VALIDATION|sid=${sid}|container=${name}|con_id=${con_id}|patch_type=${label}|patch_id=${patch_id}|status=${status}|action=${action}"
    [[ "$action" == APPLY && "$status" == SUCCESS ]] || failed=1
  done <"$output"
  # An unterminated last line may be a partially written SQL record.
  [[ -z "$line" ]] || return 1
  for con_id in "${!expected_containers[@]}"; do
    name=${expected_containers[$con_id]}
    for patch_id in "${patch_ids[@]}"; do
      key="${con_id}|${patch_id}"
      if [[ -z ${seen[$key]+x} ]]; then
        [[ "$patch_id" == "$DB_PATCH" ]] && label=RU || label=OJVM
        opg_log ERROR "DATAPATCH_CONTAINER_VALIDATION|sid=${sid}|container=${name}|con_id=${con_id}|patch_type=${label}|patch_id=${patch_id}|status=MISSING"
        failed=1
      fi
    done
  done
  (( failed == 0 )) || return 1
  opg_log INFO "DATAPATCH_CONTAINER_VALIDATION|sid=${sid}|result=PASS|containers=${#expected_containers[@]}|patches=${#patch_ids[@]}"
}

validate_datapatch_sqlpatch() {
  local sid=$1 prefix=${2:-datapatch_sqlpatch} cdb output sql_file
  cdb=$(opg_read_original_state "$sid" cdb)
  output="${RUN_DIR}/${prefix}_${sid}.log"
  case "$cdb" in
    YES) sql_file="${RUN_DIR}/datapatch_sqlpatch_cdb.sql" ;;
    NO) sql_file="${RUN_DIR}/datapatch_sqlpatch_noncdb.sql" ;;
    *) return 1 ;;
  esac
  opg_sqlplus "$sid" "${prefix}_${sid}" "$sql_file" "$output" &&
    opg_verify_command_success_text "$output" &&
    validate_datapatch_sqlpatch_output "$sid" "$output"
}

restore_pdb_state() {
  local sid=$1 states entry pdb mode current_mode sql_file output before_sql before_output after_output
  local expected_count=0 current_count=0 alter_count=0 restore_rc=0
  local -a entries=()
  local -A expected_modes=() current_modes=() final_modes=()
  states=$(opg_read_original_state "$sid" pdb_status)
  [[ -n "$states" ]] || return 0

  IFS=';' read -ra entries <<<"$states"
  for entry in "${entries[@]}"; do
    pdb=${entry%%=*}; mode=${entry#*=}
    [[ "$pdb" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ && "$pdb" != "PDB\$SEED" ]] || return 1
    [[ -z ${expected_modes[$pdb]+x} ]] || return 1
    case "$mode" in 'READ WRITE'|'READ ONLY'|MOUNTED) ;; *) return 1 ;; esac
    expected_modes[$pdb]=$mode
    expected_count=$((expected_count + 1))
  done

  before_sql="${RUN_DIR}/pdb_state_${sid}.sql"
  opg_atomic_write "$before_sql" <<'SQL'
set pages 0 feedback off heading off verify off echo off trimspool on lines 32767
whenever sqlerror exit failure rollback
select 'PDB_STATE|'||name||'|'||open_mode from v$pdbs where con_id > 2 order by con_id;
exit success
SQL
  before_output="${RUN_DIR}/pdb_state_before_${sid}.log"
  opg_sqlplus "$sid" "pdb_state_before_${sid}" "$before_sql" "$before_output" &&
    opg_verify_command_success_text "$before_output" || return 1
  while IFS='|' read -r entry pdb mode current_mode; do
    [[ "$entry" == PDB_STATE && -z "$current_mode" && "$pdb" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]] || return 1
    [[ "$mode" == 'READ WRITE' || "$mode" == 'READ ONLY' || "$mode" == MOUNTED ]] || return 1
    [[ -z ${current_modes[$pdb]+x} ]] || return 1
    current_modes[$pdb]=$mode
    current_count=$((current_count + 1))
  done < <(grep '^PDB_STATE|' "$before_output")
  [[ $current_count -eq $expected_count ]] || return 1
  for pdb in "${!expected_modes[@]}"; do [[ -n ${current_modes[$pdb]+x} ]] || return 1; done
  for pdb in "${!expected_modes[@]}"; do
    [[ ${current_modes[$pdb]} == "${expected_modes[$pdb]}" ]] || alter_count=$((alter_count + 1))
  done

  sql_file="${RUN_DIR}/restore_pdb_${sid}.sql"
  {
    printf 'whenever sqlerror exit failure rollback\n'
    for entry in "${entries[@]}"; do
      pdb=${entry%%=*}; mode=${entry#*=}
      current_mode=${current_modes[$pdb]}
      printf 'prompt PDB_RESTORE_BEFORE|%s|current=%s|desired=%s\n' "$pdb" "$current_mode" "$mode"
      [[ "$current_mode" == "$mode" ]] && continue
      case "${current_mode}:${mode}" in
        'MOUNTED:READ WRITE') printf 'alter pluggable database "%s" open read write;\n' "$pdb" ;;
        'MOUNTED:READ ONLY') printf 'alter pluggable database "%s" open read only;\n' "$pdb" ;;
        'READ WRITE:MOUNTED'|'READ ONLY:MOUNTED') printf 'alter pluggable database "%s" close immediate;\n' "$pdb" ;;
        'READ WRITE:READ ONLY')
          printf 'alter pluggable database "%s" close immediate;\nalter pluggable database "%s" open read only;\n' "$pdb" "$pdb"
          ;;
        'READ ONLY:READ WRITE')
          printf 'alter pluggable database "%s" close immediate;\nalter pluggable database "%s" open read write;\n' "$pdb" "$pdb"
          ;;
        *) return 1 ;;
      esac
    done
    printf 'exit success\n'
  } | opg_atomic_write "$sql_file" || return 1
  output="${RUN_DIR}/restore_pdb_${sid}.log"
  if (( alter_count > 0 )); then
    opg_sqlplus "$sid" "restore_pdb_${sid}" "$sql_file" "$output"
    restore_rc=$?
    if (( restore_rc == 0 )) && ! opg_verify_command_success_text "$output"; then restore_rc=1; fi
  else
    printf 'PDB_RESTORE|UNCHANGED|sid=%s\n' "$sid" >"$output"
  fi

  after_output="${RUN_DIR}/pdb_state_after_${sid}.log"
  opg_sqlplus "$sid" "pdb_state_after_${sid}" "$before_sql" "$after_output" &&
    opg_verify_command_success_text "$after_output" || return 1
  current_count=0
  while IFS='|' read -r entry pdb mode current_mode; do
    [[ "$entry" == PDB_STATE && -z "$current_mode" && "$pdb" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]] || return 1
    [[ "$mode" == 'READ WRITE' || "$mode" == 'READ ONLY' || "$mode" == MOUNTED ]] || return 1
    [[ -z ${final_modes[$pdb]+x} ]] || return 1
    final_modes[$pdb]=$mode
    current_count=$((current_count + 1))
  done < <(grep '^PDB_STATE|' "$after_output")
  [[ $current_count -eq $expected_count ]] || return 1
  for pdb in "${!expected_modes[@]}"; do
    [[ ${final_modes[$pdb]:-} == "${expected_modes[$pdb]}" ]] || return 1
  done
  if (( restore_rc != 0 )); then
    opg_log WARN "PDB_RESTORE_COMMAND_FAILED_BUT_FINAL_STATE_VERIFIED|sid=${sid}|exit_code=${restore_rc}|evidence=${after_output}"
  fi
}

apply_binary_patches() {
  local db_dir="${PATCH_ROOT}/${MONTH}/${DB_PATCH}" ojvm_dir="${PATCH_ROOT}/${MONTH}/${OJVM_PATCH}"
  opg_run_critical apply_db_ru "${RUN_DIR}/apply_db_ru.log" PARTIAL DB_BINARY "$TARGET_ORACLE_HOME/OPatch/opatch" apply -silent "$db_dir" || return 1
  opg_run_capture verify_db_ru "${RUN_DIR}/verify_db_ru.log" "$TARGET_ORACLE_HOME/OPatch/opatch" lspatches || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED DB_BINARY "DB-RU inventoryvalidatie mislukt." 1; return 1; }
  grep -q "$DB_PATCH" "${RUN_DIR}/verify_db_ru.log" || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED DB_BINARY "DB-RU ontbreekt na apply in inventory." 1; return 1; }
  opg_write_state 06_DB_BINARY_APPLIED DB_BINARY
  opg_run_critical apply_ojvm "${RUN_DIR}/apply_ojvm.log" PARTIAL OJVM_BINARY "$TARGET_ORACLE_HOME/OPatch/opatch" apply -silent "$ojvm_dir" || return 1
  opg_run_capture verify_ojvm "${RUN_DIR}/verify_ojvm.log" "$TARGET_ORACLE_HOME/OPatch/opatch" lspatches || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OJVM_BINARY "OJVM inventoryvalidatie mislukt." 1; return 1; }
  grep -q "$OJVM_PATCH" "${RUN_DIR}/verify_ojvm.log" || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OJVM_BINARY "OJVM ontbreekt na apply in inventory." 1; return 1; }
  opg_write_state 07_OJVM_BINARY_APPLIED OJVM_BINARY
}

verify_successful_database_startup() {
  local sid=$1 output=$2 previous_rc

  [[ -r "$output" ]] || { opg_log ERROR "STARTUP_VALIDATION_FAILED|sid=${sid}|check=startup_log_readable"; return 1; }

  previous_rc=$(opg_last_command_exit "startup_${sid}")
  [[ "$previous_rc" == 0 ]] || { opg_log ERROR "STARTUP_VALIDATION_FAILED|sid=${sid}|check=command_exit|actual=${previous_rc:-missing}"; return 1; }

  grep -Eq '^[[:space:]]*Database opened\.[[:space:]]*$' "$output" || { opg_log ERROR "STARTUP_VALIDATION_FAILED|sid=${sid}|check=database_opened_text"; return 1; }
  database_pmon_from_target_home "$sid" || { opg_log ERROR "STARTUP_VALIDATION_FAILED|sid=${sid}|check=pmon_target_home"; return 1; }

  # ORA-32004 is een waarschuwing over obsolete/deprecated parameters.
  # Alle overige Oracle- en SQL*Plus-fouten blijven fataal.
  if awk '!/^[[:space:]]*ORA-32004:/' "$output" |
       grep -Eiq 'ORA-|SP2-|OPatch failed|Prereq.*failed|FAILED'; then
    opg_log ERROR "STARTUP_VALIDATION_FAILED|sid=${sid}|check=fatal_startup_output"
    return 1
  fi

  verify_database_open_state "$sid" || { opg_log ERROR "STARTUP_VALIDATION_FAILED|sid=${sid}|check=fresh_sql_open_active_read_write"; return 1; }
  opg_log INFO "STARTUP_VALIDATION_OK|sid=${sid}|home=${TARGET_ORACLE_HOME}|state=OPEN_ACTIVE_READ_WRITE"
}

start_original_databases() {
  local sid running output marker previous_rc
  while IFS= read -r sid; do
    running=$(opg_read_original_state "$sid" running)
    [[ "$running" == true ]] || continue
    output="${RUN_DIR}/startup_${sid}.log"
    marker="${RUN_DIR}/startup_${sid}.complete"
    if [[ -e "$marker" ]]; then
      opg_completion_marker_valid "$marker" "$output" "$sid" startup || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_DATABASES "Ongeldig startup completion-marker voor ${sid}." 1; return 1; }
      if ! database_pmon_from_target_home "$sid" || ! verify_database_open_state "$sid"; then
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_DATABASES "Startupmarker voor ${sid} komt niet overeen met een OPEN database uit de doelhome." 1
        return 1
      fi
      continue
    fi
    if [[ -e "$output" ]]; then
      previous_rc=$(opg_last_command_exit "startup_${sid}")

      if [[ "$previous_rc" == 0 ]] &&
         verify_successful_database_startup "$sid" "$output"; then
        opg_write_completion_marker "$marker" "$output" "$sid" startup || {
          opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_DATABASES             "Startup completion-marker kon niet veilig worden hersteld voor ${sid}." 1
          return 1
        }
        continue
      fi

      [[ -n "$previous_rc" && "$previous_rc" != 0 ]] || {
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_DATABASES           "Eerdere startup zonder geldig completion-marker is ambigu voor ${sid}." 1
        return 1
      }
    fi
    if ! opg_sqlplus "$sid" "startup_${sid}" "${RUN_DIR}/startup.sql" "$output" ||
       ! verify_successful_database_startup "$sid" "$output"; then
      opg_mark_failure PARTIAL START_DATABASES "Startup mislukt voor ${sid}." 1
      return 1
    fi
    opg_write_completion_marker "$marker" "$output" "$sid" startup || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED START_DATABASES "Startup completion-marker kon niet worden geschreven voor ${sid}." 1; return 1; }
  done < <(opg_manifest_sids)
  register_original_databases || return 1
  start_original_listeners || return 1
  opg_write_state 08_DATABASES_STARTED START_DATABASES
}

run_datapatch_all() {
  local sid running output marker previous_rc
  while IFS= read -r sid; do
    running=$(opg_read_original_state "$sid" running)
    [[ "$running" == true ]] || continue
    output="${RUN_DIR}/datapatch_${sid}.log"
    marker="${RUN_DIR}/datapatch_${sid}.complete"
    if [[ ! -e "$marker" && -e "$output" ]]; then
      previous_rc=$(opg_last_command_exit "datapatch_${sid}")
      [[ -n "$previous_rc" && "$previous_rc" != 0 ]] || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED DATAPATCH "Eerdere datapatch zonder geldig completion-marker is ambigu voor ${sid}." 1; return 1; }
    fi
    prepare_pdbs_for_datapatch "$sid" || {
      opg_mark_failure MANUAL_INTERVENTION_REQUIRED PREPARE_DATAPATCH_PDB "Verwachte containers konden niet betrouwbaar worden vastgesteld of voor datapatch worden geopend voor ${sid}." 1
      return 1
    }
    if [[ -e "$marker" ]]; then
      opg_completion_marker_valid "$marker" "$output" "$sid" datapatch || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED DATAPATCH "Ongeldig datapatch completion-marker voor ${sid}." 1; return 1; }
      validate_datapatch_sqlpatch "$sid" || {
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED DATAPATCH "Per-container SQLPATCH-hercontrole is mislukt voor ${sid}." 1
        return 1
      }
    else
      export ORACLE_HOME=$TARGET_ORACLE_HOME ORACLE_SID=$sid PATH="$TARGET_ORACLE_HOME/OPatch:$TARGET_ORACLE_HOME/bin:$SAFE_PATH"
      if ! opg_run_capture "datapatch_${sid}" "$output" "$TARGET_ORACLE_HOME/OPatch/datapatch" -verbose ||
         ! opg_verify_command_success_text "$output"; then
        opg_mark_failure PARTIAL DATAPATCH "datapatch mislukt voor ${sid}; overige databases worden niet als geslaagd gemarkeerd." 1
        return 1
      fi
      validate_datapatch_sqlpatch "$sid" || {
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED DATAPATCH "Per-container SQLPATCH-validatie is mislukt voor ${sid}." 1
        return 1
      }
      opg_write_completion_marker "$marker" "$output" "$sid" datapatch || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED DATAPATCH "Datapatch completion-marker kon niet worden geschreven voor ${sid}." 1; return 1; }
    fi
    restore_pdb_state "$sid" || {
      opg_mark_failure MANUAL_INTERVENTION_REQUIRED RESTORE_PDB "Oorspronkelijke PDB-toestand kon na datapatch niet veilig worden hersteld voor ${sid}." 1
      return 1
    }
  done < <(opg_manifest_sids)
  opg_write_state 09_DATAPATCH_COMPLETE DATAPATCH
}

run_utlrp_all() {
  local sid running output marker previous_rc
  while IFS= read -r sid; do
    running=$(opg_read_original_state "$sid" running)
    [[ "$running" == true ]] || continue
    output="${RUN_DIR}/utlrp_${sid}.log"
    marker="${RUN_DIR}/utlrp_${sid}.complete"
    if [[ -e "$marker" ]]; then
      opg_completion_marker_valid "$marker" "$output" "$sid" utlrp || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED UTLRP "Ongeldig utlrp completion-marker voor ${sid}." 1; return 1; }
      continue
    fi
    if [[ -e "$output" ]]; then
      previous_rc=$(opg_last_command_exit "utlrp_${sid}")
      [[ -n "$previous_rc" && "$previous_rc" != 0 ]] || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED UTLRP "Eerdere utlrp zonder geldig completion-marker is ambigu voor ${sid}." 1; return 1; }
    fi
    if ! opg_sqlplus "$sid" "utlrp_${sid}" "${RUN_DIR}/utlrp_wrapper.sql" "$output" ||
       ! opg_verify_command_success_text "$output"; then
      opg_mark_failure PARTIAL UTLRP "utlrp.sql mislukt voor ${sid}." 1
      return 1
    fi
    opg_write_completion_marker "$marker" "$output" "$sid" utlrp || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED UTLRP "Utlrp completion-marker kon niet worden geschreven voor ${sid}." 1; return 1; }
  done < <(opg_manifest_sids)
  opg_write_state 10_UTLRP_COMPLETE UTLRP
}

validate_all() {
  local sid running output failed=0 expected_services current_services expected_pdb current_pdb role mode cdb listener
  local expected_role expected_mode expected_cdb invalid_before invalid_after
  printf 'SID,ORACLE_HOME,oratab_autostart,instance_running,database_role,open_mode,CDB,PDB_status,listener,services\n' >"${RUN_DIR}/database_state_after.csv"
  printf 'SID,patch_id,status,action_time,action,container_id,container_name\n' >"${RUN_DIR}/sqlpatch_after.csv"
  printf 'SID,invalid_objects\n' >"${RUN_DIR}/invalid_objects_after.csv"
  : >"${RUN_DIR}/registry_components_validation.psv"
  while IFS= read -r sid; do
    running=$(opg_read_original_state "$sid" running)
    if [[ "$running" != true ]]; then
      awk -F, -v sid="\"${sid}\"" '$1==sid{print;exit}' "${RUN_DIR}/database_state_before.csv" >>"${RUN_DIR}/database_state_after.csv"
      continue
    fi
    output="${RUN_DIR}/validation_${sid}.log"
    if ! opg_sqlplus "$sid" "validation_${sid}" "${RUN_DIR}/validate.sql" "$output" || ! opg_verify_command_success_text "$output"; then failed=1; continue; fi
    expected_services=$(opg_read_original_state "$sid" services)
    current_services=$(grep '^SERVICES|' "$output" | tail -1 | cut -d'|' -f2-)
    expected_pdb=$(opg_read_original_state "$sid" pdb_status)
    current_pdb=$(grep '^PDB|' "$output" | tail -1 | cut -d'|' -f2-)
    [[ "$expected_services" == "$current_services" ]] || { opg_log ERROR "Services wijken af voor ${sid}: verwacht=${expected_services}, actueel=${current_services}."; failed=1; }
    [[ "$expected_pdb" == "$current_pdb" ]] || { opg_log ERROR "PDB-status wijkt af voor ${sid}: verwacht=${expected_pdb}, actueel=${current_pdb}."; failed=1; }
    IFS='|' read -r _ _ role mode cdb < <(grep '^DB|' "$output" | tail -1)
    expected_role=$(opg_read_original_state "$sid" role)
    expected_mode=$(opg_read_original_state "$sid" open_mode)
    expected_cdb=$(opg_read_original_state "$sid" cdb)
    [[ "$role" == "$expected_role" && "$mode" == "$expected_mode" && "$cdb" == "$expected_cdb" ]] || { opg_log ERROR "Database-role/open mode/CDB wijkt af voor ${sid}."; failed=1; }
    listener=$(opg_read_original_state "$sid" listener)
    printf '"%s","%s","%s","true","%s","%s","%s","%s","%s","%s"\n' "$sid" "$TARGET_ORACLE_HOME" "$(opg_read_original_state "$sid" autostart)" "$role" "$mode" "$cdb" "$current_pdb" "$listener" "$current_services" >>"${RUN_DIR}/database_state_after.csv"
    compare_registry_with_baseline "$sid" "$cdb" "$output" validation || failed=1
    if validate_datapatch_sqlpatch "$sid" validation_sqlpatch; then
      awk -F'|' -v sid="$sid" '$1=="CDB_SQLPATCH"{printf "\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\",\"%s\"\n",sid,$4,$6,$7,$5,$2,$3}' \
        "${RUN_DIR}/validation_sqlpatch_${sid}.log" >>"${RUN_DIR}/sqlpatch_after.csv"
    else
      failed=1
    fi
    invalid_before=$(awk -F, -v sid="\"${sid}\"" '$1==sid{v=$2;gsub(/^"|"$/,"",v);print v;exit}' "${RUN_DIR}/invalid_objects_before.csv")
    invalid_after=$(grep '^INVALID|' "$output" | tail -1 | cut -d'|' -f2)
    [[ "$invalid_before" =~ ^[0-9]+$ && "$invalid_after" =~ ^[0-9]+$ && "$invalid_after" -le "$invalid_before" ]] || { opg_log ERROR "Invalid objects namen toe of konden niet worden vergeleken voor ${sid}: voor=${invalid_before:-UNKNOWN}, na=${invalid_after:-UNKNOWN}."; failed=1; }
    printf '"%s","%s"\n' "$sid" "$invalid_after" >>"${RUN_DIR}/invalid_objects_after.csv"
  done < <(opg_manifest_sids)
  (( failed == 0 )) || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED VALIDATION "Eindvalidatie is niet voor iedere database geslaagd." 1; return 1; }
  opg_run_capture opatch_lsinventory_after "${RUN_DIR}/inventory_after.txt" "$TARGET_ORACLE_HOME/OPatch/opatch" lsinventory -detail || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED VALIDATION "Inventory-after is mislukt." 1; return 1; }
  if [[ -n "$EMCTL_PATH" && -x "$EMCTL_PATH" ]]; then
    if ! opg_run_capture oem_refresh "${RUN_DIR}/oem_refresh.log" "$EMCTL_PATH" upload agent ||
       ! opg_verify_command_success_text "${RUN_DIR}/oem_refresh.log" 'EMD upload error|failed|error uploading'; then
      opg_mark_failure MANUAL_INTERVENTION_REQUIRED OEM_REFRESH "OEM-upload is mislukt." 1
      return 1
    fi
  else
    printf 'EMCTL_PATH_NOT_CONFIGURED\n' >"${RUN_DIR}/oem_refresh.log"
    opg_mark_failure MANUAL_INTERVENTION_REQUIRED OEM_REFRESH "OEM-upload kon niet worden uitgevoerd: EMCTL_PATH ontbreekt." 1
    return 1
  fi
  opg_write_state 11_VALIDATION_COMPLETE VALIDATION
  opg_atomic_write "${RUN_DIR}/summary.txt" <<EOF
Run ${RUN_ID} technisch voltooid
Host: ${HOST_NAME}
Oracle Home: ${TARGET_ORACLE_HOME}
DB-RU: ${DB_PATCH}
OJVM: ${OJVM_PATCH}
Databases: $(opg_manifest_sids | paste -sd, -)
Lokale stage-cleanup volgt pas na succesvolle completion-publicatie.
OS-update en reboot zijn niet uitgevoerd.
EOF
  opg_write_state 12_COMPLETE COMPLETE
}

perform_apply() {
  # Dynamisch gescopet naar opg_write_state() in lib/opg_core.sh.
  # shellcheck disable=SC2034
  local rc OPG_STATE_READ_ONLY=$DRY_RUN
  load_run_context || { printf 'Bestaande runcontext ontbreekt.\n' >&2; return "$EXIT_BLOCKED"; }
  initialize_local_media || { opg_result_line "$EXIT_BLOCKED" BLOCKED MEDIA; return "$EXIT_BLOCKED"; }
  [[ "$CURRENT_STATE" == 03_PLAN_GENERATED ]] || { opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  [[ "$REQUEST_OS_UPDATE" == false && "$REQUEST_REBOOT" == false ]] || { opg_mark_failure BLOCKED APPROVAL "OS-update en reboot zijn bewust gescheiden en niet ondersteund door apply." "$EXIT_INVALID_PARAMS"; opg_result_line "$EXIT_INVALID_PARAMS" INVALID_OEM_PARAMETERS APPROVAL; return "$EXIT_INVALID_PARAMS"; }
  [[ -n "$APPROVED_MANIFEST" ]] || { report_approval_blocked "approved manifest argument is missing"; opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  [[ -n "$APPROVAL_TOKEN" ]] || { report_approval_blocked "approval token argument is missing"; opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  [[ -r "$APPROVED_MANIFEST" ]] || { report_approval_blocked "approved manifest is not readable: ${APPROVED_MANIFEST}"; opg_mark_failure BLOCKED APPROVAL "Goedgekeurd manifest is niet leesbaar." 1; opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  [[ -r "$APPROVAL_TOKEN" ]] || { report_approval_blocked "approval token is not readable: ${APPROVAL_TOKEN}"; opg_mark_failure BLOCKED APPROVAL "Approval-token is niet leesbaar." 1; opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  opg_verify_manifest_hash || { report_approval_blocked "local manifest hash verification failed"; opg_mark_failure BLOCKED APPROVAL "Lokaal manifest is gewijzigd." 1; opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  [[ "$(opg_sha256 "$APPROVED_MANIFEST")" == "$(opg_sha256 "${RUN_DIR}/patch_manifest.json")" ]] || { report_approval_blocked "approved manifest differs from the run manifest"; opg_mark_failure BLOCKED APPROVAL "Goedgekeurd manifest wijkt af." 1; opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  verify_approval "$APPROVED_MANIFEST" "$APPROVAL_TOKEN" || { report_approval_blocked "${APPROVAL_ERROR:-approval verification failed}"; opg_mark_failure BLOCKED APPROVAL "Approval-token is ongeldig, onvolledig, verlopen of niet cryptografisch verifieerbaar." 1; opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  confirm_interactive_apply || { opg_result_line "$EXIT_BLOCKED" BLOCKED APPROVAL; return "$EXIT_BLOCKED"; }
  opg_acquire_lock; rc=$?
  if (( rc != 0 )); then
    if (( rc == EXIT_ALREADY_RUNNING )); then
      opg_result_line "$EXIT_ALREADY_RUNNING" BLOCKED_ALREADY_RUNNING LOCK
      return "$EXIT_ALREADY_RUNNING"
    fi
    opg_result_line "$EXIT_BLOCKED" BLOCKED LOCK_SETUP
    return "$EXIT_BLOCKED"
  fi
  trap 'opg_release_lock' EXIT
  perform_preapply_recheck; rc=$?
  if (( rc != 0 )); then
    if (( rc == EXIT_UNKNOWN )); then
      opg_mark_failure UNKNOWN PREAPPLY "Laatste hercontrole is UNKNOWN; geen database of listener is gestopt." "$rc"
      opg_result_line "$EXIT_UNKNOWN" UNKNOWN PREAPPLY
    else
      opg_mark_failure BLOCKED PREAPPLY "Laatste hercontrole is BLOCKED; geen database of listener is gestopt." "$rc"
      opg_result_line "$EXIT_BLOCKED" BLOCKED PREAPPLY
    fi
    return "$rc"
  fi
  # Approval en manifest worden na alle hercontroles nogmaals geverifieerd,
  # terwijl de exclusieve home-lock nog steeds wordt vastgehouden.
  if ! opg_verify_manifest_hash; then
    APPROVAL_ERROR="local manifest hash verification failed after preapply"
  elif [[ "$(opg_sha256 "$APPROVED_MANIFEST")" != "$(opg_sha256 "${RUN_DIR}/patch_manifest.json")" ]]; then
    APPROVAL_ERROR="approved manifest differs from the run manifest after preapply"
  elif ! verify_approval "$APPROVED_MANIFEST" "$APPROVAL_TOKEN"; then
    :
  else
    APPROVAL_ERROR=
  fi
  if [[ -n ${APPROVAL_ERROR:-} ]]; then
    report_approval_blocked "$APPROVAL_ERROR"
    opg_mark_failure BLOCKED PREAPPLY "Goedkeuring of manifest wijzigde/verliep tijdens de laatste hercontrole." 1
    opg_result_line "$EXIT_BLOCKED" BLOCKED PREAPPLY
    return "$EXIT_BLOCKED"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    opg_log INFO "DRY_RUN: approval, manifest en alle pre-applycontroles zijn succesvol geverifieerd."
    opg_log INFO "DRY_RUN: database, listener en Oracle Home worden niet gewijzigd."
    opg_release_lock
    trap - EXIT
    opg_result_line "$EXIT_OK" READY DRY_RUN
    return "$EXIT_OK"
  fi

  opg_write_state 04_APPROVED APPROVAL
  if ! perform_opatch_upgrade; then
    case "$CURRENT_STATE" in
      BLOCKED) rc=$EXIT_BLOCKED ;;
      UNKNOWN) rc=$EXIT_UNKNOWN ;;
      MANUAL_INTERVENTION_REQUIRED) rc=$EXIT_MANUAL ;;
      *) rc=$EXIT_PARTIAL ;;
    esac
    opg_result_line "$rc" "$CURRENT_STATE" "${CURRENT_PHASE:-OPATCH_UPGRADE}"
    return "$rc"
  fi
  stop_databases || { opg_result_line "$EXIT_PARTIAL" PARTIAL STOP_DATABASES; return "$EXIT_PARTIAL"; }
  apply_binary_patches || { opg_result_line "$EXIT_PARTIAL" "$CURRENT_STATE" "$CURRENT_PHASE"; return "$EXIT_PARTIAL"; }
  start_original_databases || { opg_result_line "$EXIT_PARTIAL" PARTIAL START_DATABASES; return "$EXIT_PARTIAL"; }
  run_datapatch_all || { opg_result_line "$EXIT_PARTIAL" PARTIAL DATAPATCH; return "$EXIT_PARTIAL"; }
  run_utlrp_all || { opg_result_line "$EXIT_PARTIAL" PARTIAL UTLRP; return "$EXIT_PARTIAL"; }
  validate_all || { opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED VALIDATION; return "$EXIT_MANUAL"; }
  opg_release_lock
  trap - EXIT
  opg_result_line "$EXIT_OK" COMPLETE VALIDATION
}

perform_resume() {
  local rc inventory OPG_READ_ONLY_PHASE=true
  load_run_context || { opg_result_line "$EXIT_BLOCKED" BLOCKED RESUME; return "$EXIT_BLOCKED"; }
  if [[ "$CURRENT_STATE:$CURRENT_PHASE" == 12_COMPLETE:COMPLETE && "$LOCAL_MEDIA_MODE" == required ]] &&
     validate_media_helper_trust && "$MEDIA_STAGE_HELPER" verify-purged-run "$RUN_ID" >/dev/null 2>>"${RUN_DIR}/media_stage_verify.err"; then
    opg_result_line "$EXIT_OK" COMPLETE RESUME
    return 0
  fi
  initialize_local_media || { opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED MEDIA; return "$EXIT_MANUAL"; }
  opg_acquire_lock; rc=$?
  if (( rc != 0 )); then
    if (( rc == EXIT_ALREADY_RUNNING )); then opg_result_line "$EXIT_ALREADY_RUNNING" BLOCKED_ALREADY_RUNNING LOCK; return "$EXIT_ALREADY_RUNNING"; fi
    opg_result_line "$EXIT_BLOCKED" BLOCKED LOCK_SETUP; return "$EXIT_BLOCKED"
  fi
  trap 'opg_release_lock' EXIT
  if verify_resume_environment; then
    rc=0
  else
    rc=$?
    if [[ "$DRY_RUN" != true ]]; then
      if (( rc == 2 )); then
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED RESUME "Niet-ondersteunde resume-state ${CURRENT_STATE}/${CURRENT_PHASE}; er is niet aangetoond dat statische context wijzigde." 1
      else
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED RESUME "Fasegebonden runtime- of statische contextcontrole faalde vóór resume." 1
      fi
    fi
    opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED RESUME; return "$EXIT_MANUAL"
  fi
  if [[ "$DRY_RUN" == true ]]; then
    opg_log INFO "RESUME_DRY_RUN_BOUNDARY|Geen muterende Oracle-, listener- of patchopdracht uitgevoerd."
    opg_release_lock; trap - EXIT
    opg_result_line "$EXIT_OK" READY RESUME_DRY_RUN
    return 0
  fi
  # Wordt indirect gelezen door opg_run_capture uit de ingeladen core-library.
  # shellcheck disable=SC2034
  OPG_READ_ONLY_PHASE=false
  case "$CURRENT_STATE:$CURRENT_PHASE" in
    MEDIA_VALIDATED:OPATCH_UPGRADE|OPATCH_STAGED:OPATCH_UPGRADE|OPATCH_BACKED_UP:OPATCH_UPGRADE|OPATCH_INSTALLED_UNVERIFIED:OPATCH_UPGRADE|OPATCH_READY:OPATCH_UPGRADE|PARTIAL:OPATCH_STAGED|PARTIAL:OPATCH_BACKED_UP|PARTIAL:OPATCH_INSTALLED_UNVERIFIED)
      if ! perform_opatch_upgrade || ! stop_databases || ! apply_binary_patches || ! start_original_databases || ! run_datapatch_all || ! run_utlrp_all || ! validate_all; then
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED "${CURRENT_PHASE:-RESUME}"
        return "$EXIT_MANUAL"
      fi
      opg_release_lock; trap - EXIT
      opg_result_line "$EXIT_OK" COMPLETE RESUME
      return 0 ;;
  esac
  inventory="${RUN_DIR}/resume_inventory.txt"
  opg_run_capture resume_inventory "$inventory" "$TARGET_ORACLE_HOME/OPatch/opatch" lspatches || {
    opg_mark_failure MANUAL_INTERVENTION_REQUIRED RESUME "Inventory kan niet worden geverifieerd." 1
    opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED RESUME; return "$EXIT_MANUAL";
  }
  case "$CURRENT_STATE:$CURRENT_PHASE" in
    PARTIAL:DB_BINARY|06_DB_BINARY_APPLIED:*)
      if ! grep -q "$DB_PATCH" "$inventory" || grep -q "$OJVM_PATCH" "$inventory"; then
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED RESUME "Binary toestand is niet eenduidig voor veilige hervatting." 1
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED RESUME
        return "$EXIT_MANUAL"
      fi
      opg_run_critical apply_ojvm "${RUN_DIR}/apply_ojvm_resume.log" MANUAL_INTERVENTION_REQUIRED OJVM_BINARY "$TARGET_ORACLE_HOME/OPatch/opatch" apply -silent "${PATCH_ROOT}/${MONTH}/${OJVM_PATCH}" || { opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED OJVM_BINARY; return "$EXIT_MANUAL"; }
      opg_run_capture verify_ojvm_resume "${RUN_DIR}/verify_ojvm_resume.log" "$TARGET_ORACLE_HOME/OPatch/opatch" lspatches || { opg_mark_failure MANUAL_INTERVENTION_REQUIRED OJVM_BINARY "OJVM inventoryvalidatie na resume is mislukt." 1; opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED OJVM_BINARY; return "$EXIT_MANUAL"; }
      if ! grep -q "$DB_PATCH" "${RUN_DIR}/verify_ojvm_resume.log" ||
         ! grep -q "$OJVM_PATCH" "${RUN_DIR}/verify_ojvm_resume.log"; then
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED OJVM_BINARY "Beide patches zijn na hervatte OJVM-apply niet aantoonbaar aanwezig." 1
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED OJVM_BINARY
        return "$EXIT_MANUAL"
      fi
      opg_write_state 07_OJVM_BINARY_APPLIED OJVM_BINARY
      if ! start_original_databases || ! run_datapatch_all || ! run_utlrp_all || ! validate_all; then
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED "${CURRENT_PHASE:-RESUME}"
        return "$EXIT_MANUAL"
      fi
      ;;
    07_OJVM_BINARY_APPLIED:*|PARTIAL:START_DATABASES)
      if ! grep -q "$DB_PATCH" "$inventory" || ! grep -q "$OJVM_PATCH" "$inventory"; then
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED RESUME "Beide binary patches zijn niet aantoonbaar aanwezig." 1
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED RESUME
        return "$EXIT_MANUAL"
      fi
      if ! start_original_databases || ! run_datapatch_all || ! run_utlrp_all || ! validate_all; then
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED "${CURRENT_PHASE:-RESUME}"
        return "$EXIT_MANUAL"
      fi
      ;;
    PARTIAL:START_LISTENER)
      if ! grep -q "$DB_PATCH" "$inventory" || ! grep -q "$OJVM_PATCH" "$inventory"; then
        opg_mark_failure MANUAL_INTERVENTION_REQUIRED RESUME "DB-RU en OJVM zijn niet beide aantoonbaar aanwezig voor listener-resume." 1
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED RESUME
        return "$EXIT_MANUAL"
      fi
      if ! verify_resume_listener_progress || ! register_original_databases || ! start_original_listeners; then
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED "${CURRENT_PHASE:-START_LISTENER}"
        return "$EXIT_MANUAL"
      fi
      opg_write_state 08_DATABASES_STARTED START_DATABASES
      if ! run_datapatch_all || ! run_utlrp_all || ! validate_all; then
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED "${CURRENT_PHASE:-RESUME}"
        return "$EXIT_MANUAL"
      fi
      ;;
    08_DATABASES_STARTED:*|PARTIAL:DATAPATCH)
      if ! run_datapatch_all || ! run_utlrp_all || ! validate_all; then
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED "${CURRENT_PHASE:-RESUME}"
        return "$EXIT_MANUAL"
      fi ;;
    09_DATAPATCH_COMPLETE:*|PARTIAL:UTLRP)
      if ! run_utlrp_all || ! validate_all; then
        opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED "${CURRENT_PHASE:-RESUME}"
        return "$EXIT_MANUAL"
      fi ;;
    10_UTLRP_COMPLETE:*|PARTIAL:VALIDATION|MANUAL_INTERVENTION_REQUIRED:VALIDATION)
      validate_all || { opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED "${CURRENT_PHASE:-VALIDATION}"; return "$EXIT_MANUAL"; } ;;
    12_COMPLETE:*) opg_result_line "$EXIT_OK" COMPLETE RESUME; return 0 ;;
    *) opg_mark_failure MANUAL_INTERVENTION_REQUIRED RESUME "Geen aantoonbaar veilige resume-route voor state ${CURRENT_STATE}/${CURRENT_PHASE}." 1; opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED RESUME; return "$EXIT_MANUAL" ;;
  esac
  opg_release_lock; trap - EXIT
  opg_result_line "$EXIT_OK" COMPLETE RESUME
}

perform_status() {
  local state_file="${RUN_DIR}/execution_state.json" pid marker status phase code
  [[ -r "$state_file" ]] || { TARGET_ORACLE_HOME=unknown; opg_result_line "$EXIT_UNKNOWN" PATCH_STATE_UNKNOWN STATUS; return "$EXIT_UNKNOWN"; }
  load_run_context || { opg_result_line "$EXIT_UNKNOWN" PATCH_STATE_UNKNOWN STATUS; return "$EXIT_UNKNOWN"; }
  pid=$(opg_get_json_number "$state_file" pid); marker="${RUN_DIR}/oem_timeout.marker"
  status=$CURRENT_STATE; phase=$CURRENT_PHASE; code=$EXIT_UNKNOWN
  case "$CURRENT_STATE" in 12_COMPLETE) status=COMPLETE; code=0;; BLOCKED) code=20;; PARTIAL) code=40;; MANUAL_INTERVENTION_REQUIRED) code=50;; *) code=30;; esac
  if [[ -r "$marker" ]]; then
    if [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null; then status=PATCH_PROCESS_RUNNING; code=$EXIT_UNKNOWN
    else status=PATCH_PROCESS_STOPPED; code=$EXIT_PARTIAL; fi
    printf 'OEM_JOB_TIMED_OUT|%s\n' "$(cat "$marker")"
  elif [[ "$pid" =~ ^[0-9]+$ ]] && kill -0 "$pid" 2>/dev/null && [[ "$CURRENT_STATE" != 12_COMPLETE ]]; then
    status=PATCH_PROCESS_RUNNING; code=$EXIT_UNKNOWN
  fi
  cat "$state_file"
  opg_result_line "$code" "$status" "$phase"
  return "$code"
}

perform_cleanup() {
  load_run_context || { opg_result_line "$EXIT_BLOCKED" BLOCKED CLEANUP; return "$EXIT_BLOCKED"; }
  [[ "$CURRENT_STATE" == 12_COMPLETE ]] || { opg_result_line "$EXIT_BLOCKED" BLOCKED CLEANUP; return "$EXIT_BLOCKED"; }
  [[ -n "$APPROVAL_TOKEN" && -r "$APPROVAL_TOKEN" ]] || { opg_result_line "$EXIT_BLOCKED" BLOCKED CLEANUP; return "$EXIT_BLOCKED"; }
  verify_approval "${RUN_DIR}/patch_manifest.json" "$APPROVAL_TOKEN" || { opg_result_line "$EXIT_BLOCKED" BLOCKED CLEANUP; return "$EXIT_BLOCKED"; }
  [[ "$(opg_get_json_boolean "$APPROVAL_TOKEN" cleanup_approved)" == true && "$(opg_get_json_boolean "$APPROVAL_TOKEN" functional_acceptance)" == true ]] || { opg_result_line "$EXIT_BLOCKED" BLOCKED CLEANUP; return "$EXIT_BLOCKED"; }
  # De MVP verwijdert bewust geen Oracle rollbackdata, inactive patches, OPatch.old,
  # logs, manifests of state. Cleanup produceert alleen een goedgekeurde kandidaatlijst.
  opg_atomic_write "${RUN_DIR}/cleanup_report.txt" <<EOF
Cleanup goedgekeurd op $(opg_now), maar de veilige MVP heeft niets verwijderd.
Handmatige review blijft vereist voor OPatch.old, inactive patches, rollbackdata en logs.
Bewaartermijn: ${ROLLBACK_RETENTION_HOURS} uur.
EOF
  opg_result_line "$EXIT_OK" CLEANUP_REVIEW_COMPLETE CLEANUP
}

# Wordt uitsluitend via de traps hieronder aangeroepen.
# shellcheck disable=SC2317,SC2329
handle_signal() {
  local signal_name=$1
  if [[ -d ${RUN_DIR:-/nonexistent} && -n ${TARGET_ORACLE_HOME:-} ]]; then
    opg_mark_failure MANUAL_INTERVENTION_REQUIRED SIGNAL "Signaal ${signal_name} ontvangen; geen automatische rollback of cleanup uitgevoerd." 128 || true
    opg_result_line "$EXIT_MANUAL" MANUAL_INTERVENTION_REQUIRED SIGNAL
  fi
  opg_release_lock || true
  opg_release_media_lock || true
  exit "$EXIT_MANUAL"
}

trap 'handle_signal TERM' TERM
trap 'handle_signal INT' INT
trap 'handle_signal HUP' HUP

case "$COMMAND" in
  precheck) perform_assessment precheck; exit $? ;;
  assess) perform_assessment; exit $? ;;
  plan) generate_plan; exit $? ;;
  apply) perform_apply; exit $? ;;
  status) perform_status; exit $? ;;
  resume) perform_resume; exit $? ;;
  cleanup) perform_cleanup; exit $? ;;
  *) usage; exit "$EXIT_INVALID_PARAMS" ;;
esac
