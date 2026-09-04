#!/usr/bin/env bash
# Gedeelde functies voor Oracle Patch Guard. Niet zelfstandig uitvoeren.

# Publieke symbolen van deze ingeladen library worden in patchGD_guard.sh gebruikt.
# shellcheck disable=SC2034
OPG_VERSION="0.1.2-pilot05b"

# shellcheck disable=SC2034
readonly EXIT_OK=0 EXIT_CONDITIONAL=10 EXIT_BLOCKED=20 EXIT_UNKNOWN=30 \
  EXIT_PARTIAL=40 EXIT_MANUAL=50 EXIT_ALREADY_RUNNING=60 EXIT_INVALID_PARAMS=70

opg_now() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

opg_json_escape() {
  local value=${1-}
  value=${value//\\/\\\\}
  value=${value//\"/\\\"}
  value=${value//$'\n'/\\n}
  value=${value//$'\r'/\\r}
  value=${value//$'\t'/\\t}
  printf '%s' "$value"
}

opg_sha256() {
  local file=$1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$file" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$file" | awk '{print $1}'
  else
    return 1
  fi
}

opg_hash_text() {
  local value=$1
  if command -v sha256sum >/dev/null 2>&1; then
    printf '%s' "$value" | sha256sum | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    printf '%s' "$value" | shasum -a 256 | awk '{print $1}'
  else
    return 1
  fi
}

opg_canonical_dir() {
  local path=$1
  [[ -d "$path" ]] || return 1
  if command -v realpath >/dev/null 2>&1; then
    realpath -e -- "$path"
  else
    (cd -P -- "$path" 2>/dev/null && pwd -P)
  fi
}

opg_atomic_write() {
  local destination=$1
  local directory temporary
  directory=$(dirname -- "$destination") || return 1
  mkdir -p -- "$directory" || return 1
  temporary=$(mktemp "${directory}/.opg.tmp.XXXXXX") || return 1
  cat >"$temporary" || { rm -f -- "$temporary"; return 1; }
  chmod 0600 "$temporary" 2>/dev/null || true
  mv -f -- "$temporary" "$destination"
}

opg_get_json_string() {
  local file=$1 key=$2
  awk -v key="\"${key}\"" '
    index($0,key) {
      line=$0; sub(".*" key "[[:space:]]*:[[:space:]]*\"", "", line)
      sub("\".*", "", line); print line; exit
    }' "$file"
}

opg_get_json_number() {
  local file=$1 key=$2
  awk -v key="\"${key}\"" '
    index($0,key) {
      line=$0; sub(".*" key "[[:space:]]*:[[:space:]]*", "", line)
      sub("[^0-9].*", "", line); print line; exit
    }' "$file"
}

opg_get_json_boolean() {
  local file=$1 key=$2
  awk -v key="\"${key}\"" '
    index($0,key) {
      line=$0; sub(".*" key "[[:space:]]*:[[:space:]]*", "", line)
      if (line ~ /^true/) print "true"; else if (line ~ /^false/) print "false"; exit
    }' "$file"
}

opg_log() {
  local level=$1; shift
  local message=$*
  if [[ -n ${RUN_DIR:-} ]]; then
    printf '%s|%s|%s\n' "$(opg_now)" "$level" "$message" >>"${RUN_DIR}/commands.log"
  fi
  if [[ "$level" == ERROR || "$level" == WARN ]]; then
    printf '%s: %s\n' "$level" "$message" >&2
  fi
}

opg_result_line() {
  local code=$1 status=$2 phase=$3
  printf 'OPG_RESULT|host=%s|home=%s|run_id=%s|status=%s|phase=%s|exit_code=%s\n' \
    "${HOST_NAME:-unknown}" "${TARGET_ORACLE_HOME:-unknown}" "${RUN_ID:-unknown}" "$status" "$phase" "$code"
}

opg_write_state() {
  local next=$1 phase=${2:-$1} sid=${3:-} command=${4:-} command_exit=${5:-0}
  local previous=${CURRENT_STATE:-NONE} timestamp
  if [[ ${OPG_STATE_READ_ONLY:-false} == true ]]; then
    opg_log INFO "STATE_WRITE_SUPPRESSED|previous=${previous}|next=${next}|phase=${phase}|reason=read_only_apply"
    return 0
  fi
  timestamp=$(opg_now)
  CURRENT_STATE=$next
  CURRENT_PHASE=$phase
  opg_atomic_write "${RUN_DIR}/execution_state.json" <<EOF
{
  "schema_version": 1,
  "run_id": "$(opg_json_escape "$RUN_ID")",
  "timestamp": "$timestamp",
  "user": "$(opg_json_escape "${EXEC_USER:-unknown}")",
  "hostname": "$(opg_json_escape "${HOST_NAME:-unknown}")",
  "target_oracle_home": "$(opg_json_escape "${TARGET_ORACLE_HOME:-unknown}")",
  "sid": "$(opg_json_escape "$sid")",
  "previous_state": "$(opg_json_escape "$previous")",
  "state": "$(opg_json_escape "$next")",
  "phase": "$(opg_json_escape "$phase")",
  "command": "$(opg_json_escape "$command")",
  "exit_code": $command_exit,
  "pid": $$
}
EOF
  printf '%s|%s|%s|%s|%s|%s|%s\n' "$timestamp" "$previous" "$next" "$phase" "$sid" "$command_exit" "$command" >>"${RUN_DIR}/state_history.log"
}

opg_load_state() {
  local state_file="${RUN_DIR}/execution_state.json"
  [[ -r "$state_file" ]] || return 1
  CURRENT_STATE=$(opg_get_json_string "$state_file" state)
  # Uitvoer voor de aanroepende hoofdscriptcontext.
  # shellcheck disable=SC2034
  CURRENT_PHASE=$(opg_get_json_string "$state_file" phase)
  [[ -n "$CURRENT_STATE" ]]
}

opg_mark_failure() {
  local state=$1 phase=$2 message=$3 code=${4:-1}
  opg_log ERROR "$message"
  opg_write_state "$state" "$phase" "" "$message" "$code" || true
  printf '%s\n' "$message" >"${RUN_DIR}/last_error.txt"
}

opg_run_capture() {
  local label=$1 output_file=$2; shift 2
  local rc started finished command_text
  command_text=$(printf '%q ' "$@")
  started=$(opg_now)
  opg_log INFO "COMMAND_START|label=${label}|command=${command_text}"
  # Dry-run onderdrukt alleen muterende opdrachten. Assessment en pre-apply
  # zetten OPG_READ_ONLY_PHASE=true zodat hun controles echt blijven draaien.
  if [[ ${DRY_RUN:-false} == true && ${OPG_READ_ONLY_PHASE:-false} != true ]]; then
    printf 'DRY_RUN: %s\n' "$command_text" >"$output_file"
    rc=0
  elif [[ ${OPG_TEST_MODE:-0} == 1 && ${OPG_TEST_EXECUTE_CAPTURE:-false} != true ]]; then
    opg_mock_command "$label" "$output_file" "$@"
    rc=$?
  elif command -v timeout >/dev/null 2>&1; then
    timeout --signal=TERM --kill-after=30 "${COMMAND_TIMEOUT_SECONDS}" "$@" >"$output_file" 2>&1
    rc=$?
  else
    "$@" >"$output_file" 2>&1
    rc=$?
  fi
  finished=$(opg_now)
  opg_log INFO "COMMAND_END|label=${label}|started=${started}|finished=${finished}|exit_code=${rc}|output=${output_file}"
  return "$rc"
}

opg_mock_command() {
  local label=$1 output_file=$2; shift 2
  local variable rc=${MOCK_DEFAULT_RC:-0}
  variable="MOCK_RC_${label//[^A-Za-z0-9_]/_}"
  if [[ -n ${!variable+x} ]]; then rc=${!variable}; fi
  printf 'MOCK label=%s command=' "$label" >"$output_file"
  printf '%q ' "$@" >>"$output_file"
  printf '\n' >>"$output_file"
  case "$label" in
    startup_verify_*)
      printf 'STARTUP_STATE|%s|%s|%s\n' "${MOCK_STARTUP_INSTANCE_STATUS:-OPEN}" "${MOCK_STARTUP_DATABASE_STATUS:-ACTIVE}" "${MOCK_STARTUP_OPEN_MODE:-READ WRITE}" >>"$output_file" ;;
    datapatch_containers_before_*|datapatch_containers_after_*)
      local container_sid container_states container_entry container_name container_mode container_id=3
      container_sid=${label#datapatch_containers_before_}; container_sid=${container_sid#datapatch_containers_after_}
      if [[ -n ${MOCK_DATAPATCH_CONTAINER_ROWS:-} ]]; then
        printf '%s\n' "$MOCK_DATAPATCH_CONTAINER_ROWS" | tr ';' '\n' >>"$output_file"
      else
        printf "DATAPATCH_CONTAINER|1|CDB\$ROOT|READ WRITE\n" >>"$output_file"
        container_states=${MOCK_PDB_CURRENT_STATES:-$(opg_read_original_state "$container_sid" pdb_status 2>/dev/null || true)}
        while IFS= read -r container_entry; do
          [[ -n "$container_entry" ]] || continue
          container_name=${container_entry%%=*}; container_mode=${container_entry#*=}
          printf 'DATAPATCH_CONTAINER|%s|%s|%s\n' "$container_id" "$container_name" "$container_mode" >>"$output_file"
          container_id=$((container_id + 1))
        done < <(printf '%s\n' "$container_states" | tr ';' '\n')
      fi ;;
    prepare_datapatch_pdb_*)
      if (( rc == 0 )); then
        local prepare_sid prepare_states prepare_entry prepare_name prepared=''
        prepare_sid=${label#prepare_datapatch_pdb_}
        prepare_states=$(opg_read_original_state "$prepare_sid" pdb_status 2>/dev/null || true)
        while IFS= read -r prepare_entry; do
          [[ -n "$prepare_entry" ]] || continue
          prepare_name=${prepare_entry%%=*}
          prepared+="${prepared:+;}${prepare_name}=READ WRITE"
        done < <(printf '%s\n' "$prepare_states" | tr ';' '\n')
        MOCK_PDB_CURRENT_STATES=${MOCK_DATAPATCH_PREPARE_FINAL_STATES:-$prepared}
        export MOCK_PDB_CURRENT_STATES
      fi
      printf 'PDB datapatch preparation command completed.\n' >>"$output_file" ;;
    pdb_state_before_*|pdb_state_after_*)
      local pdb_states pdb_entry pdb_name pdb_mode pdb_sid
      pdb_sid=${label#pdb_state_before_}; pdb_sid=${pdb_sid#pdb_state_after_}
      pdb_states=${MOCK_PDB_CURRENT_STATES:-$(opg_read_original_state "$pdb_sid" pdb_status 2>/dev/null || true)}
      while IFS= read -r pdb_entry; do
        [[ -n "$pdb_entry" ]] || continue
        pdb_name=${pdb_entry%%=*}; pdb_mode=${pdb_entry#*=}
        printf 'PDB_STATE|%s|%s\n' "$pdb_name" "$pdb_mode" >>"$output_file"
      done < <(printf '%s\n' "$pdb_states" | tr ';' '\n')
      ;;
    restore_pdb_*)
      MOCK_PDB_CURRENT_STATES=${MOCK_PDB_RESTORE_FINAL_STATES:-$(opg_read_original_state "${label#restore_pdb_}" pdb_status 2>/dev/null || true)}
      export MOCK_PDB_CURRENT_STATES
      if [[ -n ${MOCK_PDB_RESTORE_ERROR:-} ]]; then printf '%s\n' "$MOCK_PDB_RESTORE_ERROR" >>"$output_file"; else printf 'PDB restore command completed successfully.\n' >>"$output_file"; fi
      ;;
    startup_*)
      [[ ${MOCK_STARTUP_ORA32004:-false} == true ]] && printf 'ORA-32004: obsolete or deprecated parameter(s) specified for RDBMS instance\n' >>"$output_file"
      [[ -n ${MOCK_STARTUP_ERROR:-} ]] && printf '%s\n' "$MOCK_STARTUP_ERROR" >>"$output_file"
      printf 'ORACLE instance started.\nDatabase mounted.\nDatabase opened.\n' >>"$output_file" ;;
    listener_status_*)
      local listener_name=${label#listener_status_} listener_sid listener_services listener_service listener_state reported_service reported_sid
      [[ ${MOCK_LISTENER_ALIAS_WRONG:-false} == true ]] && listener_name=WRONG_LISTENER
      printf 'Alias                     %s\n' "$listener_name" >>"$output_file"
      MOCK_LISTENER_STATUS_POLLS=$(( ${MOCK_LISTENER_STATUS_POLLS:-0} + 1 ))
      if [[ ${MOCK_LISTENER_SERVICES_READY:-true} == true ]] &&
         (( MOCK_LISTENER_STATUS_POLLS >= ${MOCK_LISTENER_READY_AFTER_POLLS:-1} )); then
        listener_state=READY
      else
        listener_state=UNKNOWN
      fi
      while IFS= read -r listener_sid; do
        [[ "$(opg_read_original_state "$listener_sid" running 2>/dev/null)" == true ]] || continue
        listener_services=$(opg_read_original_state "$listener_sid" services 2>/dev/null || true)
        while IFS= read -r listener_service; do
          [[ -n "$listener_service" ]] || continue
          reported_service=${MOCK_LISTENER_REPORTED_SERVICE:-$listener_service}
          reported_sid=${MOCK_LISTENER_REPORTED_SID:-$listener_sid}
          printf 'Service "%s" has 1 instance(s).\n  Instance "%s", status %s, has 1 handler(s) for this service...\n' "$reported_service" "$reported_sid" "$listener_state" >>"$output_file"
        done < <(printf '%s\n' "$listener_services" | tr ';' '\n')
      done < <(opg_manifest_sids) ;;
    opatch_lsinventory_before)
      printf 'Oracle Database 19c\nNo target patches installed.\n' >>"$output_file" ;;
    verify_db_ru)
      printf 'Patch %s : applied\n' "${DB_PATCH:-0}" >>"$output_file" ;;
    opatch_lsinventory_after|opatch_upgrade_inventory|verify_ojvm|verify_ojvm_resume)
      printf 'Oracle Database 19c\nPatch %s : applied\nPatch %s : applied\n' "${DB_PATCH:-0}" "${OJVM_PATCH:-0}" >>"$output_file" ;;
    resume_inventory)
      if [[ ${MOCK_RESUME_INVENTORY:-DB_ONLY} == BOTH ]]; then
        printf 'Patch %s : applied\nPatch %s : applied\n' "${DB_PATCH:-0}" "${OJVM_PATCH:-0}" >>"$output_file"
      else
        printf 'Patch %s : applied\n' "${DB_PATCH:-0}" >>"$output_file"
      fi ;;
    opatch_stage_version)
      printf 'OPatch Version: %s\n' "${MOCK_OPATCH_STAGED_VERSION:-${OPATCH_VERSION:-unknown}}" >>"$output_file" ;;
    opatch_version|opatch_active_version_after_upgrade)
      local mock_active_version=${MOCK_OPATCH_VERSION:-${OPATCH_VERSION:-unknown}}
      if [[ -r ${TARGET_ORACLE_HOME:-}/OPatch/.opg-version ]]; then
        mock_active_version=$(<"${TARGET_ORACLE_HOME}/OPatch/.opg-version")
      fi
      printf 'OPatch Version: %s\n' "$mock_active_version" >>"$output_file" ;;
    conflict_db_ru|conflict_ojvm)
      printf 'Prereq CheckConflictAgainstOHWithDetail passed.\n' >>"$output_file" ;;
    datapatch_sqlpatch_*)
      local sqlpatch_sid expected_file expected_con_id expected_name expected_patch mock_status=${MOCK_DATAPATCH_SQLPATCH_STATUS:-SUCCESS}
      sqlpatch_sid=${label#datapatch_sqlpatch_}
      if [[ -n ${MOCK_DATAPATCH_SQLPATCH_ROWS:-} ]]; then
        printf '%s\n' "$MOCK_DATAPATCH_SQLPATCH_ROWS" | tr ';' '\n' >>"$output_file"
      else
        expected_file="${RUN_DIR}/datapatch_expected_containers_${sqlpatch_sid}.psv"
        while IFS='|' read -r expected_con_id expected_name; do
          for expected_patch in "${DB_PATCH:-0}" "${OJVM_PATCH:-0}"; do
            [[ -n "$expected_patch" ]] || continue
            printf 'CDB_SQLPATCH|%s|%s|%s|%s|20260830120000000000\n' \
              "$expected_con_id" "$expected_name" "$expected_patch" "$mock_status" >>"$output_file"
          done
        done <"$expected_file"
      fi ;;
    datapatch_*) printf 'SQL Patching tool complete on %s\n' "${label#datapatch_}" >>"$output_file" ;;
    validation_*)
      local validation_sid=${label#validation_}
      local mock_sqlpatch_status=SUCCESS mock_registry_rows validation_cdb validation_expected_file validation_con_id validation_name validation_patch
      [[ ${MOCK_VALIDATION_SQLPATCH_BAD:-false} == true ]] && mock_sqlpatch_status='WITH ERRORS'
      validation_cdb=$(opg_read_original_state "$validation_sid" cdb 2>/dev/null || printf YES)
      printf 'DB|%s|%s|%s|%s\nPDB|%s\nSERVICES|%s\nSQLPATCH|%s|%s\nSQLPATCH|%s|%s\nINVALID|%s\n' \
        "$validation_sid" "$(opg_read_original_state "$validation_sid" role 2>/dev/null || printf PRIMARY)" \
        "$(opg_read_original_state "$validation_sid" open_mode 2>/dev/null || printf 'READ WRITE')" \
        "$validation_cdb" \
        "$(opg_read_original_state "$validation_sid" pdb_status 2>/dev/null || true)" \
        "$(opg_read_original_state "$validation_sid" services 2>/dev/null || true)" \
        "${DB_PATCH:-0}" "$mock_sqlpatch_status" "${OJVM_PATCH:-0}" "$mock_sqlpatch_status" \
        "${MOCK_VALIDATION_INVALID_COUNT:-0}" >>"$output_file"
      if [[ "$validation_cdb" == YES ]]; then
        if [[ -n ${MOCK_DATAPATCH_SQLPATCH_ROWS:-} ]]; then
          printf '%s\n' "$MOCK_DATAPATCH_SQLPATCH_ROWS" | tr ';' '\n' >>"$output_file"
        else
          validation_expected_file="${RUN_DIR}/datapatch_expected_containers_${validation_sid}.psv"
          while IFS='|' read -r validation_con_id validation_name; do
            for validation_patch in "${DB_PATCH:-0}" "${OJVM_PATCH:-0}"; do
              [[ -n "$validation_patch" ]] || continue
              printf 'CDB_SQLPATCH|%s|%s|%s|%s|20260830120000000000\n' \
                "$validation_con_id" "$validation_name" "$validation_patch" "$mock_sqlpatch_status" >>"$output_file"
            done
          done <"$validation_expected_file"
        fi
      fi
      mock_registry_rows=${MOCK_REGISTRY_AFTER:-${MOCK_REGISTRY_BEFORE:-REGISTRY|CATALOG|VALID}}
      printf '%s\n' "$mock_registry_rows" | tr ';' '\n' >>"$output_file"
      if [[ -z ${MOCK_REGISTRY_AFTER:-} && -z ${MOCK_REGISTRY_BEFORE:-} && "$validation_cdb" == YES ]]; then
        printf 'CDB_REGISTRY|1|CATALOG|VALID\n' >>"$output_file"
      fi ;;
    *) printf 'Command completed successfully.\n' >>"$output_file" ;;
  esac
  return "$rc"
}

opg_run_critical() {
  local label=$1 output_file=$2 failure_state=$3 phase=$4; shift 4
  opg_run_capture "$label" "$output_file" "$@"
  local rc=$?
  if (( rc != 0 )); then
    opg_mark_failure "$failure_state" "$phase" "Kritieke opdracht mislukt: ${label}. Zie ${output_file}." "$rc"
    return "$rc"
  fi
  return 0
}

opg_add_finding() {
  local severity=$1 id=$2 message=$3 evidence=${4:-}
  printf '%s|%s|%s|%s\n' "$severity" "$id" "$message" "$evidence" >>"${RUN_DIR}/findings.psv"
  case "$severity" in
    BLOCKED) BLOCKED_COUNT=$((BLOCKED_COUNT + 1)) ;;
    UNKNOWN) UNKNOWN_COUNT=$((UNKNOWN_COUNT + 1)) ;;
    CONDITIONAL) CONDITIONAL_COUNT=$((CONDITIONAL_COUNT + 1)) ;;
  esac
}

# Stelt uitvoervariabelen in voor de aanroepende hoofdscriptcontext.
# shellcheck disable=SC2034
opg_determine_assessment_status() {
  if (( BLOCKED_COUNT > 0 )); then
    ASSESSMENT_STATUS=BLOCKED; ASSESSMENT_EXIT=$EXIT_BLOCKED
  elif (( UNKNOWN_COUNT > 0 )); then
    ASSESSMENT_STATUS=UNKNOWN; ASSESSMENT_EXIT=$EXIT_UNKNOWN
  elif (( CONDITIONAL_COUNT > 0 )); then
    ASSESSMENT_STATUS=CONDITIONAL; ASSESSMENT_EXIT=$EXIT_CONDITIONAL
  else
    ASSESSMENT_STATUS=READY; ASSESSMENT_EXIT=$EXIT_OK
  fi
}

opg_acquire_lock() {
  local home_id lock_file metadata owner_pid owner_host owner_run owner_home root_owner root_mode other_digit
  if [[ ${OPG_TEST_MODE:-0} == 1 && ${MOCK_LOCK_BUSY:-false} == true ]]; then
    opg_log WARN "Gesimuleerde lock is bezet; lock wordt niet verwijderd."
    return "$EXIT_ALREADY_RUNNING"
  fi
  if [[ ! -d "$LOCK_ROOT" || -L "$LOCK_ROOT" || ! -x "$LOCK_ROOT" || ! -w "$LOCK_ROOT" ]]; then
    opg_log ERROR "LOCK_SETUP|lock-root ontbreekt, is een symlink of is niet toegankelijk/schrijfbaar: ${LOCK_ROOT}"
    return "$EXIT_BLOCKED"
  fi
  if [[ ${OPG_TEST_MODE:-0} != 1 ]]; then
    root_owner=$(stat -c '%U' "$LOCK_ROOT" 2>/dev/null) || return "$EXIT_BLOCKED"
    root_mode=$(stat -c '%a' "$LOCK_ROOT" 2>/dev/null) || return "$EXIT_BLOCKED"
    other_digit=${root_mode: -1}
    if [[ "$root_owner" != root || ! "$other_digit" =~ ^[0-7]$ ]] || (( (other_digit & 2) != 0 )); then
      opg_log ERROR "LOCK_SETUP|lock-root moet root-owned en niet world-writable zijn: ${LOCK_ROOT} owner=${root_owner:-UNKNOWN} mode=${root_mode:-UNKNOWN}"
      return "$EXIT_BLOCKED"
    fi
  fi
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    LOCK_FILE="${LOCK_ROOT}/mock-${RUN_ID}.lock"
    printf 'pid=%s\nhost=%s\nrun_id=%s\nhome=%s\n' "$$" "$HOST_NAME" "$RUN_ID" "$TARGET_ORACLE_HOME" >"$LOCK_FILE" || return "$EXIT_BLOCKED"
    LOCK_FD=
    return 0
  fi
  command -v flock >/dev/null 2>&1 || { opg_log ERROR "LOCK_SETUP|flock ontbreekt; exclusiviteit kan niet worden bewezen."; return "$EXIT_BLOCKED"; }
  home_id=$(opg_hash_text "${HOST_NAME}|${TARGET_ORACLE_HOME}") || return "$EXIT_BLOCKED"
  lock_file="${LOCK_ROOT}/${home_id}.lock"
  LOCK_FILE=$lock_file
  # Open append-only so metadata van een actieve eigenaar niet vóór flock wordt
  # afgekapt. Pas nadat de lock werkelijk is verkregen wordt inhoud vervangen.
  exec {LOCK_FD}>>"$lock_file" || { opg_log ERROR "LOCK_SETUP|lockbestand kan niet veilig worden geopend: ${lock_file}"; return "$EXIT_BLOCKED"; }
  if ! flock -n "$LOCK_FD"; then
    metadata=$(cat "$lock_file" 2>/dev/null || true)
    owner_pid=$(printf '%s\n' "$metadata" | awk -F= '$1=="pid"{print $2}')
    owner_host=$(printf '%s\n' "$metadata" | awk -F= '$1=="host"{print $2}')
    owner_run=$(printf '%s\n' "$metadata" | awk -F= '$1=="run_id"{sub(/^[^=]*=/,"");print}')
    owner_home=$(printf '%s\n' "$metadata" | awk -F= '$1=="home"{sub(/^[^=]*=/,"");print}')
    if [[ ! "$owner_pid" =~ ^[0-9]+$ || -z "$owner_host" ]] ||
       ! opg_validate_run_id "$owner_run" || [[ "$owner_home" != "$TARGET_ORACLE_HOME" ]]; then
      opg_log ERROR "LOCK_SETUP|bezette lock heeft ongeldige of niet-homegebonden metadata: ${lock_file}"
      exec {LOCK_FD}>&-
      LOCK_FD=
      return "$EXIT_BLOCKED"
    fi
    opg_log WARN "Lock bezet door host=${owner_host:-unknown} pid=${owner_pid:-unknown}; lock wordt niet verwijderd."
    exec {LOCK_FD}>&-
    LOCK_FD=
    return "$EXIT_ALREADY_RUNNING"
  fi
  : >"$lock_file"
  printf 'pid=%s\nhost=%s\nrun_id=%s\nhome=%s\nstarted=%s\n' "$$" "$HOST_NAME" "$RUN_ID" "$TARGET_ORACLE_HOME" "$(opg_now)" >&"$LOCK_FD"
  return 0
}

opg_release_lock() {
  if [[ -n ${LOCK_FD:-} ]]; then
    flock -u "$LOCK_FD" 2>/dev/null || true
    exec {LOCK_FD}>&-
    LOCK_FD=
  fi
  return 0
}

opg_acquire_media_lock() {
  local lock_dir lock_file owner group mode
  [[ ${LOCAL_MEDIA_MODE:-disabled} == required ]] || return 0
  [[ -n ${MEDIA_LOCK_FD:-} ]] && return 0
  if [[ ${OPG_TEST_MODE:-0} == 1 ]]; then
    return 0
  fi
  command -v flock >/dev/null 2>&1 || return "$EXIT_BLOCKED"
  lock_dir="${LOCAL_STAGE_ROOT}/.locks"
  lock_file="${lock_dir}/media-stage.lock"
  [[ -d "$lock_dir" && ! -L "$lock_dir" && -f "$lock_file" && ! -L "$lock_file" ]] || return "$EXIT_BLOCKED"
  owner=$(stat -c '%U' "$lock_dir" 2>/dev/null) || return "$EXIT_BLOCKED"
  group=$(stat -c '%G' "$lock_dir" 2>/dev/null) || return "$EXIT_BLOCKED"
  mode=$(stat -c '%a' "$lock_dir" 2>/dev/null) || return "$EXIT_BLOCKED"
  [[ "$owner:$group:$mode" == root:oinstall:750 ]] || return "$EXIT_BLOCKED"
  owner=$(stat -c '%U' "$lock_file" 2>/dev/null) || return "$EXIT_BLOCKED"
  group=$(stat -c '%G' "$lock_file" 2>/dev/null) || return "$EXIT_BLOCKED"
  mode=$(stat -c '%a' "$lock_file" 2>/dev/null) || return "$EXIT_BLOCKED"
  [[ "$owner:$group:$mode" == root:oinstall:640 && $(stat -c '%h' "$lock_file" 2>/dev/null) == 1 ]] || return "$EXIT_BLOCKED"
  exec {MEDIA_LOCK_FD}<"$lock_file" || return "$EXIT_BLOCKED"
  if ! flock -sn "$MEDIA_LOCK_FD"; then
    exec {MEDIA_LOCK_FD}>&-
    MEDIA_LOCK_FD=
    return "$EXIT_ALREADY_RUNNING"
  fi
}

opg_release_media_lock() {
  if [[ -n ${MEDIA_LOCK_FD:-} ]]; then
    flock -u "$MEDIA_LOCK_FD" 2>/dev/null || true
    exec {MEDIA_LOCK_FD}>&-
    MEDIA_LOCK_FD=
  fi
}

opg_free_mb() {
  local path=$1
  df -Pm -- "$path" 2>/dev/null | awk 'NR==2{print $4}'
}

opg_tree_hash() {
  local directory=$1 list_file rc started finished duration timeout_seconds
  [[ -d "$directory" ]] || return 1
  timeout_seconds=${INTEGRITY_CHECK_TIMEOUT_SECONDS:-1800}
  [[ "$timeout_seconds" =~ ^[1-9][0-9]*$ ]] || return 1
  command -v timeout >/dev/null 2>&1 || { opg_log ERROR "INTEGRITY_CHECK_END|path=${directory}|status=NO_TIMEOUT_COMMAND"; return 1; }
  started=$(date +%s)
  opg_log INFO "INTEGRITY_CHECK_START|path=${directory}|timeout_seconds=${timeout_seconds}"
  if [[ ${OPG_TEST_MODE:-0} == 1 && ${MOCK_TREE_HASH_DELAY_SECONDS:-0} =~ ^[1-9][0-9]*$ ]]; then
    timeout --signal=TERM --kill-after=1 "$timeout_seconds" sleep "$MOCK_TREE_HASH_DELAY_SECONDS"
    rc=$?
    if (( rc != 0 )); then
      finished=$(date +%s); duration=$((finished - started))
      opg_log ERROR "INTEGRITY_CHECK_END|path=${directory}|status=TIMEOUT|exit_code=${rc}|duration_seconds=${duration}"
      return "$rc"
    fi
  fi
  list_file=$(mktemp "${TMPDIR:-/tmp}/opg.hashes.XXXXXX") || return 1
  # De enkele quotes zijn bewust: $1 wordt pas in de begrensde subshell gevuld.
  # shellcheck disable=SC2016
  timeout --signal=TERM --kill-after=30 "$timeout_seconds" bash -c \
    'set -o pipefail; find "$1" -type f -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum' \
    opg-tree-hash "$directory" >"$list_file" 2>/dev/null
  rc=$?
  if (( rc != 0 )); then
    rm -f -- "$list_file"
    finished=$(date +%s); duration=$((finished - started))
    if (( rc == 124 || rc == 137 )); then
      opg_log ERROR "INTEGRITY_CHECK_END|path=${directory}|status=TIMEOUT|exit_code=${rc}|duration_seconds=${duration}"
    else
      opg_log ERROR "INTEGRITY_CHECK_END|path=${directory}|status=FAILED|exit_code=${rc}|duration_seconds=${duration}"
    fi
    return "$rc"
  fi
  local result
  result=$(opg_sha256 "$list_file"); rc=$?
  rm -f -- "$list_file"
  finished=$(date +%s); duration=$((finished - started))
  if (( rc == 0 )); then
    opg_log INFO "INTEGRITY_CHECK_END|path=${directory}|status=OK|duration_seconds=${duration}"
    printf '%s\n' "$result"
  else
    opg_log ERROR "INTEGRITY_CHECK_END|path=${directory}|status=FAILED|exit_code=${rc}|duration_seconds=${duration}"
  fi
  return "$rc"
}

opg_csv_escape() {
  local value=${1-}
  value=${value//\"/\"\"}
  printf '"%s"' "$value"
}

opg_sqlplus() {
  local sid=$1 label=$2 sql_file=$3 output_file=$4
  local saved_home=${ORACLE_HOME-} saved_sid=${ORACLE_SID-}
  export ORACLE_HOME=$TARGET_ORACLE_HOME ORACLE_SID=$sid PATH="$TARGET_ORACLE_HOME/bin:$SAFE_PATH"
  opg_run_capture "$label" "$output_file" "$TARGET_ORACLE_HOME/bin/sqlplus" -s / as sysdba "@${sql_file}"
  local rc=$?
  if (( rc != 0 )); then
    export ORACLE_HOME=$saved_home ORACLE_SID=$saved_sid
    return "$rc"
  fi
  if [[ "$ORACLE_HOME" != "$TARGET_ORACLE_HOME" ]]; then
    opg_log ERROR "ORACLE_HOME wijzigde onverwacht tijdens ${label}."
    export ORACLE_HOME=$saved_home ORACLE_SID=$saved_sid
    return 98
  fi
  export ORACLE_HOME=$saved_home ORACLE_SID=$saved_sid
  return 0
}

opg_verify_command_success_text() {
  local file=$1 failure_pattern=${2:-'ORA-|SP2-|OPatch failed|Prereq.*failed|FAILED'}
  ! grep -Eiq "$failure_pattern" "$file"
}

opg_parse_oratab() {
  local output=$1 line sid home autostart canonical
  : >"$output"
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=${line%$'\r'}
    [[ "$line" =~ ^[[:space:]]*$ || "$line" =~ ^[[:space:]]*# ]] && continue
    IFS=: read -r sid home autostart _ <<<"$line"
    sid=${sid//[[:space:]]/}; home=${home%/}; autostart=${autostart^^}
    [[ -z "$sid" || -z "$home" || "$sid" == \* ]] && continue
    [[ "$sid" == +ASM* || "$sid" == ASM* || "$sid" == +APX* || "$sid" == MGMTDB ]] && continue
    [[ "$sid" =~ ^[A-Za-z][A-Za-z0-9_$#]{0,29}$ ]] || continue
    [[ "$home" =~ ^/[A-Za-z0-9_./-]+$ ]] || continue
    [[ "$autostart" == Y || "$autostart" == N ]] || autostart=UNKNOWN
    canonical=$(opg_canonical_dir "$home" 2>/dev/null || printf '%s' "$home")
    printf '%s|%s|%s\n' "$sid" "$canonical" "$autostart" >>"$output"
  done <"$ORATAB_FILE"
}

opg_manifest_sids() {
  awk -F, 'NR>1 {gsub(/^"|"$/, "", $1); print $1}' "${RUN_DIR}/database_state_before.csv"
}

opg_verify_manifest_hash() {
  local manifest=${1:-${RUN_DIR}/patch_manifest.json} expected_file="${RUN_DIR}/patch_manifest.sha256" actual expected
  [[ -r "$manifest" && -r "$expected_file" ]] || return 1
  actual=$(opg_sha256 "$manifest") || return 1
  expected=$(awk '{print $1}' "$expected_file")
  [[ "$actual" == "$expected" ]]
}

opg_write_completion_marker() {
  local marker=$1 log_file=$2 sid=$3 step=$4 log_hash
  [[ -r "$log_file" ]] || return 1
  log_hash=$(opg_sha256 "$log_file") || return 1
  opg_atomic_write "$marker" <<EOF
step=${step}
run_id=${RUN_ID}
sid=${sid}
home=${TARGET_ORACLE_HOME}
log_sha256=${log_hash}
EOF
}

opg_completion_marker_valid() {
  local marker=$1 log_file=$2 sid=$3 step=$4 stored_hash actual_hash stored_sid stored_step stored_home stored_run
  [[ -r "$marker" && -r "$log_file" ]] || return 1
  stored_step=$(awk -F= '$1=="step"{print $2;exit}' "$marker")
  stored_run=$(awk -F= '$1=="run_id"{sub(/^[^=]*=/,"");print;exit}' "$marker")
  stored_sid=$(awk -F= '$1=="sid"{print $2;exit}' "$marker")
  stored_home=$(awk -F= '$1=="home"{sub(/^[^=]*=/,"");print;exit}' "$marker")
  stored_hash=$(awk -F= '$1=="log_sha256"{print $2;exit}' "$marker")
  actual_hash=$(opg_sha256 "$log_file") || return 1
  [[ "$stored_step" == "$step" && "$stored_run" == "$RUN_ID" && "$stored_sid" == "$sid" && "$stored_home" == "$TARGET_ORACLE_HOME" && "$stored_hash" == "$actual_hash" ]]
}

opg_last_command_exit() {
  local label=$1
  awk -v needle="label=${label}" 'index($0,"COMMAND_END|") && index($0,needle){line=$0; sub(".*exit_code=","",line); sub(/[|].*/,"",line); rc=line} END{if(rc!="")print rc}' "${RUN_DIR}/commands.log"
}

opg_read_original_state() {
  local sid=$1 field=$2 csv="${RUN_DIR}/database_state_before.csv" column
  case "$field" in
    autostart) column=3 ;;
    running) column=4 ;;
    role) column=5 ;;
    open_mode) column=6 ;;
    cdb) column=7 ;;
    pdb_status) column=8 ;;
    listener) column=9 ;;
    services) column=10 ;;
    *) return 1 ;;
  esac
  awk -F, -v sid="\"${sid}\"" -v column="$column" '$1==sid {v=$column; gsub(/^"|"$/, "", v); print v; exit}' "$csv"
}

opg_validate_run_id() {
  [[ $1 =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]]
}

opg_validate_patch_value() {
  [[ $1 =~ ^[0-9]{6,10}$ ]]
}

opg_validate_month() {
  [[ $1 =~ ^[A-Z]{3,9}[0-9]{4}$ ]]
}

opg_validate_version() {
  [[ $1 =~ ^[0-9]+([.][0-9]+){3,5}$ ]]
}

opg_validate_zip_name() {
  [[ $1 =~ ^[A-Za-z0-9._-]+[.]zip$ && $1 != *..* ]]
}

opg_test_fixture_load() {
  [[ ${OPG_TEST_MODE:-0} == 1 ]] || return 0
  [[ ${ALLOW_TEST_MODE:-false} == true ]] || { printf 'Testmodus is niet toegestaan door de configuratie.\n' >&2; return 1; }
  [[ -n ${OPG_FIXTURE_FILE:-} && -r ${OPG_FIXTURE_FILE:-} ]] || return 0
  # Alleen de lokale test-harness mag fixtures als shellvariabelen laden.
  # shellcheck disable=SC1090
  source "$OPG_FIXTURE_FILE"
}
