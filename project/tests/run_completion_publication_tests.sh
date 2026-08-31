#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
HELPER=${ROOT}/oem-tasks/opg_context_root.sh
BASE=/tmp/opg-context-helper-tests.completion.$$
OWNER=$(id -un)
GROUP=$(id -gn)
PASS=0 FAIL=0
trap 'rm -rf -- "$BASE"' EXIT
mkdir -p "$BASE"

record() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf 'not ok - %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"; FAIL=$((FAIL + 1))
    [[ -r ${OUT:-} ]] && tail -n 20 "$OUT"
  fi
}

json_get() {
  python3 - "$1" "$2" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as handle:
    value = json.load(handle)[sys.argv[2]]
print(value)
PY
}

setup_case() {
  local name=$1
  CASE=$BASE/$name
  CONTEXT_ROOT=$CASE/context
  RUN_ROOT=$CASE/runs
  APPROVAL_ROOT=$CASE/approvals
  OUT=$CASE/out
  mkdir -p "$CONTEXT_ROOT" "$RUN_ROOT" "$APPROVAL_ROOT"
  chmod 0750 "$CONTEXT_ROOT" "$APPROVAL_ROOT"
}

write_evidence() {
  local run_id=$1 host=$2 sid=$3 cycle=$4 completed_epoch=$5 expires_epoch=$6
  local home=${7:-/u01/app/oracle/product/19/dbhome_1}
  local local_run=$RUN_ROOT/$run_id approval_run=$APPROVAL_ROOT/$run_id completed_at manifest_hash
  completed_at=$(date -u -d "@$completed_epoch" '+%Y-%m-%dT%H:%M:%SZ')
  mkdir -p "$local_run" "$approval_run"
  chmod 0700 "$local_run"
  chmod 0750 "$approval_run"
  cat >"$CONTEXT_ROOT/current_run.json" <<EOF
{"schema_version":"1","run_id":"$run_id","fqdn":"$host","oracle_sid":"$sid","oracle_home":"$home","patch_cycle":"$cycle"}
EOF
  chmod 0640 "$CONTEXT_ROOT/current_run.json"
  cat >"$local_run/execution_state.json" <<EOF
{"schema_version":1,"run_id":"$run_id","timestamp":"$completed_at","hostname":"$host","target_oracle_home":"$home","sid":"","state":"12_COMPLETE","phase":"COMPLETE","exit_code":0}
EOF
  cat >"$approval_run/patch_manifest.json" <<EOF
{"schema_version":1,"run_id":"$run_id","hostname":"$host","target_oracle_home":"$home","month":"$cycle"}
EOF
  manifest_hash=$(sha256sum "$approval_run/patch_manifest.json" | awk '{print $1}')
  cat >"$approval_run/approval.json" <<EOF
{"approved":true,"manifest_sha256":"$manifest_hash","hostname":"$host","target_oracle_home":"$home","expires_epoch":$expires_epoch,"manifest_signature_file":"$approval_run/patch_manifest.sig","approval_signature_file":"$approval_run/approval.sig"}
EOF
  printf 'READY|ASSESSMENT_READY|ready|evidence\n' >"$approval_run/findings.psv"
  printf 'manifest-signature\n' >"$approval_run/patch_manifest.sig"
  printf 'approval-signature\n' >"$approval_run/approval.sig"
  chmod 0600 "$local_run/execution_state.json"
  chmod 0440 "$approval_run/patch_manifest.json" "$approval_run/approval.json" \
    "$approval_run/findings.psv" "$approval_run/patch_manifest.sig" "$approval_run/approval.sig"
}

run_helper() {
  OPG_CONTEXT_HELPER_TEST_MODE=1 \
  OPG_CONTEXT_HELPER_TEST_ROOT=$CONTEXT_ROOT \
  OPG_CONTEXT_HELPER_TEST_RUN_ROOT=$RUN_ROOT \
  OPG_CONTEXT_HELPER_TEST_APPROVAL_ROOT=$APPROVAL_ROOT \
  OPG_CONTEXT_HELPER_TEST_GROUP=$GROUP \
    bash "$HELPER" "$@" >"$OUT" 2>&1
}

run_helper_with_config() {
  OPG_CONTEXT_HELPER_TEST_MODE=1 \
  OPG_CONTEXT_HELPER_TEST_ROOT=$CONTEXT_ROOT \
  OPG_CONTEXT_HELPER_TEST_RUN_ROOT=$RUN_ROOT \
  OPG_CONTEXT_HELPER_TEST_CONFIG=$CASE/patchGD_guard.conf \
  OPG_CONTEXT_HELPER_TEST_GROUP=$GROUP \
    bash "$HELPER" "$@" >"$OUT" 2>&1
}

NOW=$(date +%s)

setup_case publish
RUN=DBHOST01-ORCL1-JUL2026-OEM-20260828T100000Z
write_evidence "$RUN" dbhost01.example.com ORCL1 JUL2026 "$NOW" $((NOW + 3600))
run_helper publish-completion "$RUN"; rc=$?
COMPLETION=$APPROVAL_ROOT/$RUN/completion.json
[[ -f "$COMPLETION" && ! -L "$COMPLETION" && "$(stat -c '%U:%G:%a' "$COMPLETION")" == "$OWNER:$GROUP:440" ]] || rc=99
[[ "$(json_get "$COMPLETION" run_id)" == "$RUN" && "$(json_get "$COMPLETION" state)" == 12_COMPLETE && "$(json_get "$COMPLETION" phase)" == COMPLETE && "$(json_get "$COMPLETION" exit_code)" == 0 ]] || rc=98
record 'COMPLETE target publiceert veilig completion.json' 0 "$rc"

expected_manifest=$(sha256sum "$APPROVAL_ROOT/$RUN/patch_manifest.json" | awk '{print $1}')
expected_approval=$(sha256sum "$APPROVAL_ROOT/$RUN/approval.json" | awk '{print $1}')
[[ "$(json_get "$COMPLETION" manifest_sha256)" == "$expected_manifest" && "$(json_get "$COMPLETION" approval_sha256)" == "$expected_approval" ]]
record 'completion bindt exacte manifest- en approval-SHA256' 0 $?

before=$(sha256sum "$COMPLETION" | awk '{print $1}'); run_helper publish-completion "$RUN"; rc=$?; after=$(sha256sum "$COMPLETION" | awk '{print $1}')
[[ "$before" == "$after" ]] || rc=99
record 'identieke completionpublicatie is idempotent' 0 "$rc"

setup_case live_signer_modes
RUN=DBHOST09-ORCL9-JUL2026-OEM-20260828T100008Z
write_evidence "$RUN" dbhost09.example.com ORCL9 JUL2026 "$NOW" $((NOW + 3600))
chmod 0644 "$APPROVAL_ROOT/$RUN/approval.json" "$APPROVAL_ROOT/$RUN/approval.sig" \
  "$APPROVAL_ROOT/$RUN/patch_manifest.sig"
chmod 0440 "$APPROVAL_ROOT/$RUN/patch_manifest.json"
run_helper publish-completion "$RUN"; rc=$?
[[ -f "$APPROVAL_ROOT/$RUN/completion.json" ]] || rc=99
record 'live signer-modes 0644 met staged manifest 0440 publiceren veilig' 0 "$rc"

for unsafe_mode in 0664 0666 0646; do
  setup_case "unsafe_signer_mode_$unsafe_mode"
  RUN="DBHOST10-ORCL10-JUL2026-OEM-20260828T10${unsafe_mode}Z"
  write_evidence "$RUN" dbhost10.example.com ORCL10 JUL2026 "$NOW" $((NOW + 3600))
  chmod "$unsafe_mode" "$APPROVAL_ROOT/$RUN/approval.json"
  run_helper publish-completion "$RUN"; rc=$?
  [[ ! -e "$APPROVAL_ROOT/$RUN/completion.json" ]] || rc=99
  record "group/world-writable signer-artifact mode $unsafe_mode blokkeert" 20 "$rc"
done

setup_case nonterminal
RUN=DBHOST02-ORCL2-JUL2026-OEM-20260828T100001Z
write_evidence "$RUN" dbhost02.example.com ORCL2 JUL2026 "$NOW" $((NOW + 3600))
sed -i 's/"12_COMPLETE"/"03_PLAN_GENERATED"/;s/"phase":"COMPLETE"/"phase":"PLAN"/' "$RUN_ROOT/$RUN/execution_state.json"
run_helper publish-completion "$RUN"; rc=$?
[[ ! -e "$APPROVAL_ROOT/$RUN/completion.json" ]] || rc=99
record 'niet-terminale target-state publiceert niet' 20 "$rc"

setup_case mismatch
RUN=DBHOST03-ORCL3-JUL2026-OEM-20260828T100002Z
write_evidence "$RUN" dbhost03.example.com ORCL3 JUL2026 "$NOW" $((NOW + 3600))
sed -i 's/dbhost03[.]example[.]com/other.example.com/' "$RUN_ROOT/$RUN/execution_state.json"
run_helper publish-completion "$RUN"; rc=$?
[[ ! -e "$APPROVAL_ROOT/$RUN/completion.json" ]] || rc=99
record 'hostnamebinding-mismatch blokkeert publicatie' 20 "$rc"

setup_case expiry
RUN=DBHOST04-ORCL4-JUL2026-OEM-20260828T100003Z
write_evidence "$RUN" dbhost04.example.com ORCL4 JUL2026 "$NOW" $((NOW - 1))
run_helper publish-completion "$RUN"; rc=$?
[[ ! -e "$APPROVAL_ROOT/$RUN/completion.json" ]] || rc=99
record 'completion na approval-expiry publiceert niet' 20 "$rc"

setup_case traversal
run_helper publish-completion '../escape'; record 'path traversal RUN_ID wordt geweigerd' 70 $?

setup_case symlink
RUN=DBHOST05-ORCL5-JUL2026-OEM-20260828T100004Z
write_evidence "$RUN" dbhost05.example.com ORCL5 JUL2026 "$NOW" $((NOW + 3600))
mv "$APPROVAL_ROOT/$RUN" "$CASE/real-approval-run"
ln -s "$CASE/real-approval-run" "$APPROVAL_ROOT/$RUN"
run_helper publish-completion "$RUN"; record 'symlink approval-rundirectory wordt geweigerd' 20 $?

setup_case conflict
RUN=DBHOST06-ORCL6-JUL2026-OEM-20260828T100005Z
write_evidence "$RUN" dbhost06.example.com ORCL6 JUL2026 "$NOW" $((NOW + 3600))
printf '{"conflict":true}\n' >"$APPROVAL_ROOT/$RUN/completion.json"; chmod 0440 "$APPROVAL_ROOT/$RUN/completion.json"
before=$(sha256sum "$APPROVAL_ROOT/$RUN/completion.json" | awk '{print $1}')
run_helper publish-completion "$RUN"; rc=$?; after=$(sha256sum "$APPROVAL_ROOT/$RUN/completion.json" | awk '{print $1}')
[[ "$before" == "$after" ]] || rc=99
record 'bestaande afwijkende completion wordt nooit overschreven' 20 "$rc"

setup_case multi
RUN_A=DBHOST07-ORCL7-JUL2026-OEM-20260828T100006Z
RUN_B=DBHOST08-ORCL8-JUL2026-OEM-20260828T100007Z
write_evidence "$RUN_A" dbhost07.example.com ORCL7 JUL2026 "$NOW" $((NOW + 3600)); run_helper publish-completion "$RUN_A"; rc=$?
write_evidence "$RUN_B" dbhost08.example.com ORCL8 JUL2026 "$NOW" $((NOW + 3600)); run_helper publish-completion "$RUN_B" || rc=$?
[[ "$(json_get "$APPROVAL_ROOT/$RUN_A/completion.json" run_id)" == "$RUN_A" && "$(json_get "$APPROVAL_ROOT/$RUN_B/completion.json" run_id)" == "$RUN_B" ]] || rc=99
record 'multi-target completions blijven per RUN_ID geïsoleerd' 0 "$rc"

setup_case config_root
RUN=DBHOST11-ORCL11-JUL2026-OEM-20260828T100011Z
write_evidence "$RUN" dbhost11.example.com ORCL11 JUL2026 "$NOW" $((NOW + 3600))
printf 'APPROVAL_ROOT=%s\n' "$APPROVAL_ROOT" >"$CASE/patchGD_guard.conf"
run_helper_with_config publish-completion "$RUN"; rc=$?
[[ -f "$APPROVAL_ROOT/$RUN/completion.json" ]] || rc=99
record 'completion-helper leest APPROVAL_ROOT uit config' 0 "$rc"

setup_case relative_config_root
printf 'APPROVAL_ROOT=relative/approvals\n' >"$CASE/patchGD_guard.conf"
run_helper_with_config publish-completion DBHOST12-ORCL12-JUL2026-OEM-20260828T100012Z
record 'completion-helper weigert relatieve configroot' 20 $?

setup_case missing_config_root
printf 'OPG_ROOT=/safe/root\n' >"$CASE/patchGD_guard.conf"
run_helper_with_config publish-completion DBHOST13-ORCL13-JUL2026-OEM-20260828T100013Z
record 'completion-helper faalt bij ontbrekende APPROVAL_ROOT' 20 $?

printf '\nCompletion publication results: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
