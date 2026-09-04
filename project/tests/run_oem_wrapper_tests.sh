#!/usr/bin/env bash
# Unit/regressietests voor de dunne OEM discovery/context/routing-wrapper.
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
WRAPPER=${ROOT}/oem-tasks/opg_oem.sh
TMP_BASE=$(mktemp -d /tmp/opg-oem-wrapper-tests.XXXXXX) || exit 1
PASS=0 FAIL=0
trap 'rm -rf -- "$TMP_BASE"' EXIT

record() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then printf 'ok - %s\n' "$name"; PASS=$((PASS + 1))
  else printf 'not ok - %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"; FAIL=$((FAIL + 1)); [[ -r ${OUT:-} ]] && tail -n 20 "$OUT"; fi
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)[sys.argv[2]])
PY
}

write_mock() {
  local path=$1 body=$2
  printf '#!/usr/bin/env bash\n%s\n' "$body" >"$path"
  chmod 0750 "$path"
}

setup_case() {
  local name=$1
  CASE="$TMP_BASE/$name"; CENTRAL="$CASE/central"; OPG_ROOT="$CENTRAL/oracle-patch-guard"; TASK_ROOT="$CASE/oem-tasks"; PROJECT="$CASE/current/project"; LOCAL_SBIN="$CASE/local-sbin"; CONTEXT_HELPER="$LOCAL_SBIN/opg_context_root.sh"
  HOME_DIR="$CASE/dbhome_1"; CONFIG="$CASE/etc/patchGD_guard.conf"; RUN_ROOT="$CASE/runs"; CONTEXT_ROOT="$CASE/var/lib/oracle-patch-guard"
  mkdir -p "$OPG_ROOT/config" "$OPG_ROOT/approvals" "$TASK_ROOT" "$PROJECT/lib" "$LOCAL_SBIN" "$HOME_DIR/bin" "$CENTRAL/JUL2026/39472050" "$CENTRAL/JUL2026/39222882" "$CENTRAL/opatch" "$CASE/etc" "$RUN_ROOT"
  chmod 0755 "$LOCAL_SBIN"
  chmod 0750 "$OPG_ROOT/approvals"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$HOME_DIR/bin/oracle"; chmod 0750 "$HOME_DIR/bin/oracle"
  printf 'JUL2026\n' >"$OPG_ROOT/config/active_cycle"
  cat >"$CENTRAL/JUL2026/opg_cycle.conf" <<'EOF'
PATCH_CYCLE=JUL2026
DB_RU_PATCH_ID=39472050
OJVM_PATCH_ID=39222882
OPATCH_VERSION=12.2.0.1.52
OPATCH_ZIP=p6880880_190000_Linux-x86-64.zip
EOF
  printf 'zip\n' >"$CENTRAL/opatch/p6880880_190000_Linux-x86-64.zip"
  cat >"$CONFIG" <<EOF
OPG_ROOT=$OPG_ROOT
APPROVAL_ROOT=$OPG_ROOT/approvals
PATCH_ROOT=$CENTRAL
OPATCH_ROOT=$CENTRAL/opatch
RUN_ROOT=$RUN_ROOT
ORATAB_FILE=$CASE/oratab
EOF
  printf 'DB1|%s|%s\n' "$HOME_DIR" "$HOME_DIR" >"$CASE/discovery.psv"
  chmod 0600 "$OPG_ROOT/config/active_cycle" "$CENTRAL/JUL2026/opg_cycle.conf" "$CENTRAL/opatch/p6880880_190000_Linux-x86-64.zip" "$CONFIG" "$CASE/discovery.psv"
  : >"$CASE/routes.log"; : >"$CASE/summary.log"; printf '0\n' >"$CASE/core.rc"
  write_mock "$TASK_ROOT/opg_prepare_host.sh" "printf 'prepare|%s\\n' \"\$*\" >>'$CASE/routes.log'; exit 0"
  write_mock "$TASK_ROOT/opg_create_window.sh" "printf 'window|%s|%s|%s\\n' \"\$1\" \"\$2\" \"\$3\" >>'$CASE/routes.log'; exit 0"
  write_mock "$TASK_ROOT/opg_assess_task.sh" "printf 'assess|sid=%s|home=%s|ld=%s|args=%s\\n' \"\$ORACLE_SID\" \"\$ORACLE_HOME\" \"\$LD_LIBRARY_PATH\" \"\$*\" >>'$CASE/routes.log'; exit 10"
  write_mock "$TASK_ROOT/opg_stage_approval.sh" "printf 'stage|%s\\n' \"\$1\" >>'$CASE/routes.log'; exit 0"
  cp "$ROOT/oem-tasks/opg_context_root.sh" "$CONTEXT_HELPER"; chmod 0755 "$CONTEXT_HELPER"
  write_mock "$CASE/mock-sudo" "[[ \"\$1\" == -n ]] || exit 70; shift; export OPG_CONTEXT_HELPER_TEST_MODE=1 OPG_CONTEXT_HELPER_TEST_ROOT='$CONTEXT_ROOT' OPG_CONTEXT_HELPER_TEST_RUN_ROOT='$RUN_ROOT' OPG_CONTEXT_HELPER_TEST_APPROVAL_ROOT='$OPG_ROOT/approvals' OPG_CONTEXT_HELPER_TEST_GROUP='$(id -gn)'; exec \"\$@\""
  write_mock "$PROJECT/patchGD_guard.sh" "printf 'core|%s\\n' \"\$*\" >>'$CASE/routes.log'; exit \"\$(cat '$CASE/core.rc')\""
  write_mock "$PROJECT/lib/opg_result_summary_v1.1.sh" "printf 'summary|%s|%s\\n' \"\$1\" \"\$2\" >>'$CASE/summary.log'; exit 0"
  write_mock "$PROJECT/oem_apply.sh" "printf 'apply|sid=%s|home=%s|args=%s\\n' \"\$ORACLE_SID\" \"\$ORACLE_HOME\" \"\$*\" >>'$CASE/routes.log'; [[ -r \"\$2\" && -r \"\$3\" ]] || { printf 'OPG_RESULT|status=BLOCKED|phase=APPROVAL|exit_code=20\\n'; exit 20; }; state_host=svtest.example; [[ ! -f '$CASE/mock-apply-wrong-host' ]] || state_host=wrong.example; printf '{\"schema_version\":1,\"run_id\":\"%s\",\"timestamp\":\"2026-08-24T10:30:00Z\",\"hostname\":\"%s\",\"target_oracle_home\":\"$HOME_DIR\",\"sid\":\"\",\"state\":\"12_COMPLETE\",\"phase\":\"COMPLETE\",\"exit_code\":0}\\n' \"\$1\" \"\$state_host\" >'$RUN_ROOT/'\"\$1\"'/execution_state.json'; exit 0"
  write_mock "$PROJECT/oem_approval_check.sh" "printf 'approval-check|%s\\n' \"\$*\" >>'$CASE/routes.log'; exit 0"
  export OPG_WRAPPER_TEST_MODE=1 OPG_TEST_ROOT="$CASE" OPG_TEST_OPG_ROOT="$OPG_ROOT" OPG_TEST_CONFIG="$CONFIG" OPG_TEST_CONTEXT_ROOT="$CONTEXT_ROOT"
  export OPG_TEST_TASK_ROOT="$TASK_ROOT" OPG_TEST_PROJECT_ROOT="$PROJECT" OPG_TEST_DISCOVERY_FIXTURE="$CASE/discovery.psv"
  OPG_TEST_CONTEXT_OWNER=$(id -un)
  OPG_TEST_CONTEXT_GROUP=$(id -gn)
  export OPG_TEST_CONTEXT_OWNER OPG_TEST_CONTEXT_GROUP OPG_TEST_SHORT_HOST=svtest OPG_TEST_FQDN=svtest.example
  export OPG_TEST_SUDO_BIN="$CASE/mock-sudo"
  OPG_TEST_CONTEXT_HELPER_OWNER=$(id -un)
  OPG_TEST_CONTEXT_HELPER_GROUP=$(id -gn)
  export OPG_TEST_CONTEXT_HELPER="$CONTEXT_HELPER" OPG_TEST_CONTEXT_HELPER_OWNER OPG_TEST_CONTEXT_HELPER_GROUP OPG_TEST_CONTEXT_HELPER_PARENT_STOP="$LOCAL_SBIN"
  export OPG_TEST_NOW_ISO=2026-08-24T10:30:00Z OPG_TEST_RUN_STAMP=20260824T103000Z
  OUT="$CASE/out"
}

run_wrapper() { /bin/bash "$WRAPPER" "$1" >"$OUT" 2>&1; }
run_wrapper_args() { /bin/bash "$WRAPPER" "$@" >"$OUT" 2>&1; }

write_state() {
  local run=$1 state=$2 phase=${3:-TEST}
  mkdir -p "$RUN_ROOT/$run"
  printf '{"state":"%s","phase":"%s"}\n' "$state" "$phase" >"$RUN_ROOT/$run/execution_state.json"
}

activate_cycle() {
  local cycle=$1 db_patch=$2 ojvm_patch=$3
  mkdir -p "$CENTRAL/$cycle/$db_patch" "$CENTRAL/$cycle/$ojvm_patch"
  cat >"$CENTRAL/$cycle/opg_cycle.conf" <<EOF
PATCH_CYCLE=$cycle
DB_RU_PATCH_ID=$db_patch
OJVM_PATCH_ID=$ojvm_patch
OPATCH_VERSION=12.2.0.1.52
OPATCH_ZIP=p6880880_190000_Linux-x86-64.zip
EOF
  printf '%s\n' "$cycle" >"$OPG_ROOT/config/active_cycle"
  chmod 0600 "$CENTRAL/$cycle/opg_cycle.conf" "$OPG_ROOT/config/active_cycle"
}

prepare_approval_run() {
  local run=$1 dir=$OPG_ROOT/approvals/$1 manifest_hash
  mkdir -p "$dir"
  chmod 0750 "$dir"
  cat >"$dir/patch_manifest.json" <<EOF
{"schema_version":1,"run_id":"$run","hostname":"svtest.example","target_oracle_home":"$HOME_DIR","month":"JUL2026"}
EOF
  manifest_hash=$(sha256sum "$dir/patch_manifest.json" | awk '{print $1}')
  cat >"$dir/approval.json" <<EOF
{"approved":true,"manifest_sha256":"$manifest_hash","hostname":"svtest.example","target_oracle_home":"$HOME_DIR","expires_epoch":2000000000,"manifest_signature_file":"$dir/patch_manifest.sig","approval_signature_file":"$dir/approval.sig"}
EOF
  printf 'READY|ASSESSMENT_READY|ready|evidence\n' >"$dir/findings.psv"
  printf 'manifest-signature\n' >"$dir/patch_manifest.sig"
  printf 'approval-signature\n' >"$dir/approval.sig"
  chmod 0440 "$dir/patch_manifest.json" "$dir/approval.json" "$dir/findings.psv" "$dir/patch_manifest.sig" "$dir/approval.sig"
}

enable_pilot07_media() {
  MEDIA_HELPER="$LOCAL_SBIN/opg_media_stage_root.sh"
  printf '\nLOCAL_MEDIA_MODE=required\n' >>"$CONFIG"
  cat >>"$CENTRAL/JUL2026/opg_cycle.conf" <<'EOF'
DB_RU_ZIP=p39472050_190000_Linux-x86-64.zip
DB_RU_ZIP_SHA256=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
OJVM_ZIP=p39222882_190000_Linux-x86-64.zip
OJVM_ZIP_SHA256=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
OPATCH_ZIP_SHA256=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
ARTIFACT_MANIFEST=artifact_manifest.json
ARTIFACT_MANIFEST_SIG=artifact_manifest.sig
EOF
  printf zip >"$CENTRAL/JUL2026/p39472050_190000_Linux-x86-64.zip"; printf zip >"$CENTRAL/JUL2026/p39222882_190000_Linux-x86-64.zip"
  write_mock "$MEDIA_HELPER" "printf 'media-stage|%s\\n' \"\$*\" >>'$CASE/routes.log'; exit 0"; chmod 0755 "$MEDIA_HELPER"
  OPG_TEST_MEDIA_STAGE_HELPER_OWNER=$(id -un); OPG_TEST_MEDIA_STAGE_HELPER_GROUP=$(id -gn)
  export OPG_TEST_MEDIA_STAGE_HELPER="$MEDIA_HELPER" OPG_TEST_MEDIA_STAGE_HELPER_OWNER OPG_TEST_MEDIA_STAGE_HELPER_GROUP OPG_TEST_MEDIA_STAGE_HELPER_PARENT_STOP="$LOCAL_SBIN"
}

# 1. Correcte cycle discovery.
setup_case cycleok; run_wrapper prepare; rc=$?; context="$CONTEXT_ROOT/current_run.json"
[[ "$(json_get "$context" patch_cycle)" == JUL2026 && "$(json_get "$context" db_ru_patch_id)" == 39472050 && "$(json_get "$context" opatch_zip)" == p6880880_190000_Linux-x86-64.zip ]] || rc=99
context_mode=$(stat -c '%a' "$context")
[[ "$(stat -c '%a' "$CONTEXT_ROOT")" == 750 && "$context_mode" == 640 ]] || rc=98
(( (8#$context_mode & 0022) == 0 )) || rc=97
record 'correcte cycle discovery' 0 "$rc"

# 2-6. Fail-closed cyclemetadata.
setup_case noactive; rm "$OPG_ROOT/config/active_cycle"; run_wrapper prepare; record 'ontbrekende active cycle' 20 $?
setup_case noconf; rm "$CENTRAL/JUL2026/opg_cycle.conf"; run_wrapper prepare; record 'ontbrekende opg_cycle.conf' 20 $?
setup_case badpatchid; sed -i 's/DB_RU_PATCH_ID=39472050/DB_RU_PATCH_ID=bad/' "$CENTRAL/JUL2026/opg_cycle.conf"; run_wrapper prepare; record 'ongeldige patch ID' 20 $?
setup_case nopatchdir; rmdir "$CENTRAL/JUL2026/39472050"; run_wrapper prepare; record 'ontbrekende patch directory' 20 $?
setup_case nozip; rm "$CENTRAL/opatch/p6880880_190000_Linux-x86-64.zip"; run_wrapper prepare; record 'ontbrekende OPatch zip' 20 $?

# 7-9. Target discovery.
setup_case one; run_wrapper prepare; rc=$?; [[ "$(json_get "$CONTEXT_ROOT/current_run.json" oracle_sid)" == DB1 && "$(json_get "$CONTEXT_ROOT/current_run.json" oracle_home)" == "$HOME_DIR" ]] || rc=99; record 'precies één SID/home gevonden' 0 "$rc"
setup_case many; HOME2="$CASE/dbhome_2"; mkdir -p "$HOME2/bin"; cp "$HOME_DIR/bin/oracle" "$HOME2/bin/oracle"; printf 'DB2|%s|%s\n' "$HOME2" "$HOME2" >>"$CASE/discovery.psv"; run_wrapper prepare; record 'meerdere SIDs fail closed' 20 $?
setup_case none; : >"$CASE/discovery.psv"; run_wrapper prepare; record 'geen SID fail closed' 20 $?

# 10-11. Eén context, hergebruik door volgende task.
setup_case contextreuse; run_wrapper prepare; first=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); first_hash=$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')
run_wrapper prepare; rc=$?; second=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); second_hash=$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}'); [[ "$first" == "$second" && "$first_hash" == "$second_hash" ]] || rc=99
record 'RUN_ID één keer aangemaakt' 0 "$rc"
run_wrapper create-window; rc=$?; grep -q "^window|${first}|${HOME_DIR}|" "$CASE/routes.log" || rc=99; record 'volgende task gebruikt exact dezelfde RUN_ID' 0 "$rc"
run_wrapper show-context; rc=$?; grep -q "\"run_id\": \"${first}\"" "$OUT" || rc=99; record 'show-context leest dezelfde group-readable context' 0 "$rc"

# 12. Terminale oude run wordt niet hergebruikt.
setup_case oldcomplete; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 12_COMPLETE COMPLETE; run_wrapper assess; record 'oude COMPLETE run niet stil hergebruikt' 20 $?

# 13-18. Routing en parameteropbouw.
setup_case prepareroute; run_wrapper prepare; rc=$?; grep -q '^prepare|$' "$CASE/routes.log" || rc=99; record 'prepare routing' 0 "$rc"
setup_case windowroute; run_wrapper create-window; rc=$?; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); grep -q "^window|${run}|${HOME_DIR}|OPG-JUL2026-20260824T103000Z$" "$CASE/routes.log" || rc=99; record 'create-window routing' 0 "$rc"
setup_case assessroute; run_wrapper assess; rc=$?; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); grep -q "^assess|sid=DB1|home=${HOME_DIR}|ld=${HOME_DIR}/lib:/lib:/usr/lib|args=${HOME_DIR} ${run} 39472050 39222882 JUL2026 12.2.0.1.52 p6880880_190000_Linux-x86-64.zip ${CONFIG}$" "$CASE/routes.log" || rc=99; record 'assess parameteropbouw' 10 "$rc"
setup_case planroute; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 02_ASSESS_OK ASSESS; printf '42\n' >"$CASE/core.rc"; run_wrapper plan; rc=$?; grep -q "^core|plan --non-interactive --run-id ${run} --config ${CONFIG}$" "$CASE/routes.log" || rc=99; grep -q "^summary|${RUN_ROOT}/${run}|PLAN$" "$CASE/summary.log" || rc=98; record 'plan routing en exit-code preservation' 42 "$rc"
setup_case stageroute; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 03_PLAN_GENERATED PLAN; run_wrapper stage; rc=$?; grep -q "^stage|${run}$" "$CASE/routes.log" || rc=99; record 'stage routing' 0 "$rc"
setup_case applyroute; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 03_PLAN_GENERATED PLAN; prepare_approval_run "$run"; run_wrapper apply; rc=$?; grep -q "^apply|sid=DB1|home=${HOME_DIR}|args=${run} ${OPG_ROOT}/approvals/${run}/patch_manifest.json ${OPG_ROOT}/approvals/${run}/approval.json ${CONFIG}$" "$CASE/routes.log" || rc=99; [[ -f "$OPG_ROOT/approvals/$run/completion.json" && $(json_get "$OPG_ROOT/approvals/$run/completion.json" run_id) == "$run" ]] || rc=98; grep -q "OPG_COMPLETION_PUBLISH|run_id=${run}|status=SUCCESS" "$OUT" || rc=97; record 'succesvolle apply publiceert rungebonden completion' 0 "$rc"

setup_case applycleanup; enable_pilot07_media; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 03_PLAN_GENERATED PLAN; prepare_approval_run "$run"; run_wrapper apply; rc=$?; grep -q "media-stage|purge-run ${run}" "$CASE/routes.log" || rc=99; grep -q 'completion=PUBLISHED|cleanup=PURGED' "$OUT" || rc=98; record 'succesvolle completion start automatisch gedeelde stage-cleanup' 0 "$rc"
run_wrapper_args cleanup-stage --run-id "$run"; rc=$?; grep -q "media-stage|purge-run ${run}" "$CASE/routes.log" || rc=99; record 'handmatige cleanup-stage gebruikt dezelfde begrensde purge-engine' 0 "$rc"

setup_case cleanupfailurecomplete; enable_pilot07_media; write_mock "$MEDIA_HELPER" "printf 'OPG_MEDIA_CLEANUP|run_id=%s|status=FAILED_RETAINED\\n' \"\$2\"; exit 30"; chmod 0755 "$MEDIA_HELPER"; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 03_PLAN_GENERATED PLAN; prepare_approval_run "$run"; run_wrapper apply; rc=$?; [[ $(json_get "$RUN_ROOT/$run/execution_state.json" state) == 12_COMPLETE ]] || rc=99; grep -q 'status=COMPLETE|phase=COMPLETE|exit_code=0' "$OUT" || rc=98; grep -q 'cleanup=FAILED_RETAINED' "$OUT" || rc=97; record 'cleanup-fout draait COMPLETE niet terug' 0 "$rc"

setup_case applypublishfail; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 03_PLAN_GENERATED PLAN; prepare_approval_run "$run"; touch "$CASE/mock-apply-wrong-host"; run_wrapper apply; rc=$?; [[ $(json_get "$RUN_ROOT/$run/execution_state.json" state) == 12_COMPLETE && ! -e "$OPG_ROOT/approvals/$run/completion.json" ]] || rc=99; grep -q "OPG_COMPLETION_PUBLISH|run_id=${run}|status=FAILED" "$OUT" || rc=98; grep -q 'OPG_OEM_RESULT|status=UNKNOWN|phase=PUBLISH_COMPLETION|exit_code=30' "$OUT" || rc=97; record 'publicatiefout is zichtbaar zonder COMPLETE-state terug te draaien' 30 "$rc"
sed -i 's/wrong[.]example/svtest.example/' "$RUN_ROOT/$run/execution_state.json"; run_wrapper publish-completion; rc=$?; [[ -f "$OPG_ROOT/approvals/$run/completion.json" ]] || rc=99; grep -q "OPG_COMPLETION_PUBLISH|run_id=${run}|status=SUCCESS" "$OUT" || rc=98; record 'publish-completion retry finaliseert bestaande COMPLETE-run' 0 "$rc"

# 19. Ontbrekende approval wordt door bestaande apply-wrapper/core afgewezen.
setup_case noapproval; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 03_PLAN_GENERATED PLAN; run_wrapper apply; rc=$?; grep -q '^apply|' "$CASE/routes.log" || rc=99; grep -q 'status=BLOCKED|phase=APPROVAL|exit_code=20' "$OUT" || rc=98; record 'approval ontbreekt: bestaande apply-route faalt veilig' 20 "$rc"

# Aanvullende defensieve parser- en beheerpaden.
setup_case unknownkey; printf 'UNSAFE_KEY=value\n' >>"$CENTRAL/JUL2026/opg_cycle.conf"; run_wrapper prepare; record 'onbekende cycle-key fail closed' 20 $?
setup_case cycleconflict; sed -i 's/PATCH_CYCLE=JUL2026/PATCH_CYCLE=OCT2026/' "$CENTRAL/JUL2026/opg_cycle.conf"; run_wrapper prepare; record 'conflicterende cyclemetadata fail closed' 20 $?
setup_case cyclesymlink; mv "$CENTRAL/JUL2026/opg_cycle.conf" "$CENTRAL/JUL2026/opg_cycle.real"; ln -s opg_cycle.real "$CENTRAL/JUL2026/opg_cycle.conf"; run_wrapper prepare; record 'symlink cyclemetadata fail closed' 20 $?

setup_case approvalcheck; run_wrapper prepare; run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$run" 03_PLAN_GENERATED PLAN; run_wrapper approval-check; rc=$?; grep -q "^approval-check|${run} DB1 ${HOME_DIR}$" "$CASE/routes.log" || rc=99; record 'optionele approval-check routing' 0 "$rc"

setup_case newruninitial; unset OPG_NEW_RUN_REASON; run_wrapper new-run; rc=$?
initial_run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); [[ "$initial_run" == svtest-DB1-JUL2026-OEM-20260824T103000Z ]] || rc=99
grep -q "OPG_NEW_RUN_RESULT|status=CREATED|run_id=${initial_run}|cycle=JUL2026|reason=Initial OEM run context for JUL2026" "$OUT" || rc=98
record 'new-run maakt zonder bestaande context een initiële formele context' 0 "$rc"

setup_case newrundangling; mkdir -p "$CONTEXT_ROOT"; ln -s missing-context.json "$CONTEXT_ROOT/current_run.json"; run_wrapper new-run; rc=$?
[[ -L "$CONTEXT_ROOT/current_run.json" ]] || rc=99
record 'new-run behandelt een dangling current-contextsymlink niet als afwezige context' 20 "$rc"

setup_case newrunauto; activate_cycle APR2026 39034528 38906621; unset OPG_NEW_RUN_REASON; run_wrapper new-run; old_run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$old_run" 12_COMPLETE COMPLETE
cp "$CONTEXT_ROOT/current_run.json" "$CASE/old-context.json"; activate_cycle JUL2026 39472050 39222882
export OPG_TEST_NOW_ISO=2026-08-24T10:31:00Z OPG_TEST_RUN_STAMP=20260824T103100Z
run_wrapper new-run; rc=$?; new_run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); archive_file=$(find "$CONTEXT_ROOT/archive" -maxdepth 1 -type f -name "${old_run}.*.json" -print -quit)
[[ "$new_run" != "$old_run" && -n "$archive_file" ]] || rc=99; cmp -s "$CASE/old-context.json" "$archive_file" || rc=98
grep -q "run_id=${old_run}|state=12_COMPLETE|reason=Automatic OEM run rotation: APR2026 -> JUL2026" "$CONTEXT_ROOT/context_history.log" || rc=97
grep -q "OPG_NEW_RUN_RESULT|status=ROTATED|run_id=${new_run}|cycle=JUL2026|reason=Automatic OEM run rotation: APR2026 -> JUL2026" "$OUT" || rc=96
record 'APR2026 COMPLETE roteert met automatische auditreden naar JUL2026' 0 "$rc"

setup_case newrunoverride; activate_cycle APR2026 39034528 38906621; run_wrapper new-run; old_run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$old_run" 12_COMPLETE COMPLETE; activate_cycle JUL2026 39472050 39222882
export OPG_NEW_RUN_REASON='Goedgekeurde DBA rotatie naar JUL2026' OPG_TEST_NOW_ISO=2026-08-24T10:31:00Z OPG_TEST_RUN_STAMP=20260824T103100Z
run_wrapper new-run; rc=$?; grep -q "run_id=${old_run}|state=12_COMPLETE|reason=Goedgekeurde DBA rotatie naar JUL2026" "$CONTEXT_ROOT/context_history.log" || rc=99
record 'expliciete OPG_NEW_RUN_REASON blijft exacte override' 0 "$rc"
unset OPG_NEW_RUN_REASON

setup_case newrunreuse; run_wrapper new-run; reused_run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); context_hash=$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')
export OPG_TEST_NOW_ISO=2026-08-24T10:31:00Z OPG_TEST_RUN_STAMP=20260824T103100Z; run_wrapper new-run; rc=$?
[[ "$reused_run" == "$(json_get "$CONTEXT_ROOT/current_run.json" run_id)" && "$context_hash" == "$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')" ]] || rc=99
[[ ! -e "$CONTEXT_ROOT/archive" && ! -e "$CONTEXT_ROOT/context_history.log" ]] || rc=98
grep -q "OPG_NEW_RUN_RESULT|status=REUSED|run_id=${reused_run}|cycle=JUL2026" "$OUT" || rc=97
record 'new-run hergebruikt dezelfde target/cycle-context zonder rotatie' 0 "$rc"

setup_case newrunnonterminal; activate_cycle APR2026 39034528 38906621; run_wrapper new-run; blocked_run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$blocked_run" 02_ASSESS_OK ASSESS; context_hash=$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}'); activate_cycle JUL2026 39472050 39222882
export OPG_TEST_NOW_ISO=2026-08-24T10:31:00Z OPG_TEST_RUN_STAMP=20260824T103100Z; run_wrapper new-run; rc=$?
[[ "$context_hash" == "$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')" && ! -e "$CONTEXT_ROOT/archive" ]] || rc=99
record 'new-run blokkeert conflicterende niet-terminale vorige run' 20 "$rc"

setup_case helperargs; run_wrapper prepare >/dev/null; "$CASE/mock-sudo" -n "$CONTEXT_HELPER" publish /tmp/evil >"$OUT" 2>&1; record 'root-helper weigert arbitraire padargumenten' 70 $?

setup_case nosudo; chmod 0640 "$CASE/mock-sudo"; run_wrapper prepare; record 'ontbrekende sudo-helperroute faalt gesloten' 30 $?

setup_case writablehelper; chmod 0775 "$CONTEXT_HELPER"; run_wrapper prepare; record 'group-writable lokale helper wordt geweigerd' 30 $?

setup_case symlinkhelper; mv "$CONTEXT_HELPER" "$LOCAL_SBIN/opg_context_root.real"; ln -s opg_context_root.real "$CONTEXT_HELPER"; run_wrapper prepare; record 'symlink lokale helper wordt geweigerd' 30 $?

setup_case wrongowner
if (( EUID == 0 )); then chown 65534 "$CONTEXT_HELPER"; fi
export OPG_TEST_CONTEXT_HELPER_OWNER=root
run_wrapper prepare; record 'niet-root-owned lokale helper wordt geweigerd' 30 $?

setup_case writableparent; chmod 0775 "$LOCAL_SBIN"; run_wrapper prepare; record 'group-writable helper-parent wordt geweigerd' 30 $?

setup_case missinghelper; rm "$CONTEXT_HELPER"; run_wrapper prepare; record 'ontbrekende lokale helper wordt geweigerd' 30 $?

setup_case p07media; enable_pilot07_media; run_wrapper prepare >/dev/null; run_wrapper stage-media; rc=$?; grep -q '^media-stage|stage-active-cycle$' "$CASE/routes.log" || rc=99; record 'Pilot07 stage-media gebruikt exact lokale root-helperactie' 0 "$rc"
setup_case p07writable; enable_pilot07_media; chmod 0775 "$MEDIA_HELPER"; run_wrapper prepare >/dev/null; run_wrapper stage-media; record 'writable media-helper wordt geweigerd' 30 $?
setup_case p07symlink; enable_pilot07_media; mv "$MEDIA_HELPER" "$LOCAL_SBIN/opg_media_stage_root.real"; ln -s opg_media_stage_root.real "$MEDIA_HELPER"; run_wrapper prepare >/dev/null; run_wrapper stage-media; record 'symlink media-helper wordt geweigerd' 30 $?
setup_case p07missing; enable_pilot07_media; rm "$MEDIA_HELPER"; run_wrapper prepare >/dev/null; run_wrapper stage-media; record 'ontbrekende media-helper wordt fail-closed geweigerd' 30 $?

setup_case configpaths; unset OPG_TEST_OPG_ROOT OPG_TEST_APPROVAL_ROOT; run_wrapper prepare; rc=$?; [[ -f "$CONTEXT_ROOT/current_run.json" ]] || rc=99; record 'OEM-wrapper leest OPG_ROOT en APPROVAL_ROOT uit config' 0 "$rc"
setup_case relativeopg; sed -i "s|^OPG_ROOT=.*|OPG_ROOT=relative/oracle-patch-guard|" "$CONFIG"; unset OPG_TEST_OPG_ROOT OPG_TEST_APPROVAL_ROOT; run_wrapper prepare; record 'OEM-wrapper weigert relatieve OPG_ROOT' 20 $?
setup_case missingapprovalroot; sed -i '/^APPROVAL_ROOT=/d' "$CONFIG"; unset OPG_TEST_OPG_ROOT OPG_TEST_APPROVAL_ROOT; run_wrapper prepare; record 'OEM-wrapper faalt bij ontbrekende APPROVAL_ROOT' 20 $?

# PRECHECK gebruikt discovery en cyclemetadata, maar raakt current_run.json niet.
setup_case precheckroute; export OPG_TEST_PRECHECK_RUN_STAMP=20260824T090000Z; run_wrapper precheck; rc=$?
precheck_run=svtest-DB1-JUL2026-PRECHECK-20260824T090000Z
grep -q "^core|precheck --non-interactive --target-oracle-home ${HOME_DIR} --run-id ${precheck_run} --config ${CONFIG} 39472050 39222882 JUL2026 12.2.0.1.52 p6880880_190000_Linux-x86-64.zip$" "$CASE/routes.log" || rc=99
[[ ! -e "$CONTEXT_ROOT/current_run.json" ]] || rc=98
[[ -z "$(find "$OPG_ROOT/approvals" -mindepth 1 -print -quit)" ]] || rc=97
record 'OEM PRECHECK route maakt geen formele current context' 0 "$rc"

setup_case precheckpreserve; run_wrapper prepare; context_hash=$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}'); export OPG_TEST_PRECHECK_RUN_STAMP=20260824T090100Z; run_wrapper precheck; rc=$?
[[ "$context_hash" == "$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')" ]] || rc=99
record 'OEM PRECHECK overschrijft bestaande current run niet' 0 "$rc"

setup_case precheckapprovedapply; run_wrapper prepare; approved_run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$approved_run" 03_PLAN_GENERATED PLAN; prepare_approval_run "$approved_run"
context_before=$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')
approval_before=$(find "$OPG_ROOT/approvals/$approved_run" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
export OPG_TEST_PRECHECK_RUN_STAMP=20260824T090150Z; run_wrapper precheck; rc=$?
[[ "$context_before" == "$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')" ]] || rc=99
[[ "$approval_before" == "$(find "$OPG_ROOT/approvals/$approved_run" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" ]] || rc=98
run_wrapper apply; apply_rc=$?
grep -q "^apply|.*args=${approved_run} ${OPG_ROOT}/approvals/${approved_run}/patch_manifest.json ${OPG_ROOT}/approvals/${approved_run}/approval.json ${CONFIG}$" "$CASE/routes.log" || apply_rc=97
[[ $rc -eq 0 && $apply_rc -eq 0 ]] || apply_rc=96
record 'APPROVED -> PRECHECK -> APPLY behoudt formele run en approvals byte-identiek' 0 "$apply_rc"

setup_case precheckunknownisolation; run_wrapper prepare; formal_run=$(json_get "$CONTEXT_ROOT/current_run.json" run_id); write_state "$formal_run" 03_PLAN_GENERATED PLAN; prepare_approval_run "$formal_run"
context_before=$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')
approval_before=$(find "$OPG_ROOT/approvals" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
printf '30\n' >"$CASE/core.rc"; export OPG_TEST_PRECHECK_RUN_STAMP=20260824T090151Z; run_wrapper precheck; unknown_rc=$?
unknown_isolation_rc=0
[[ $unknown_rc -eq 30 && "$context_before" == "$(sha256sum "$CONTEXT_ROOT/current_run.json" | awk '{print $1}')" ]] || unknown_isolation_rc=99
[[ "$approval_before" == "$(find "$OPG_ROOT/approvals" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)" ]] || unknown_isolation_rc=98
[[ ! -d "$OPG_ROOT/approvals/svtest-DB1-JUL2026-PRECHECK-20260824T090151Z" ]] || unknown_isolation_rc=97
record 'PRECHECK UNKNOWN wijzigt current context en approval-root niet' 0 "$unknown_isolation_rc"

setup_case precheckrepeat; export OPG_TEST_PRECHECK_RUN_STAMP=20260824T090200Z; run_wrapper precheck; first_rc=$?; export OPG_TEST_PRECHECK_RUN_STAMP=20260824T090201Z; run_wrapper precheck; second_rc=$?
grep -q 'PRECHECK-20260824T090200Z' "$CASE/routes.log" || second_rc=99
grep -q 'PRECHECK-20260824T090201Z' "$CASE/routes.log" || second_rc=98
[[ "$first_rc" == 0 && ! -e "$CONTEXT_ROOT/current_run.json" ]] || second_rc=97
record 'OEM PRECHECK is herhaalbaar met unieke RUN_ID' 0 "$second_rc"
unset OPG_TEST_PRECHECK_RUN_STAMP

runtime_path_hits=0
grep -F '/mnt/patch-share/oracle-patch-guard' "$ROOT/oem-tasks/opg_context_root.sh" "$ROOT/oem-tasks/opg_oem.sh" "$ROOT/oem-tasks/opg_stage_approval.sh" "$ROOT/oem-tasks/opg_media_stage_root.py" "$ROOT/project/oem_approval_check.sh" "$ROOT/signer/opg_list_pending.sh" >/dev/null 2>&1 && runtime_path_hits=1
record 'actieve runtime bevat geen generieke Oracle Patch Guard-sharefallback' 0 "$runtime_path_hits"

printf '\nOEM wrapper results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
