#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
BASE=/tmp/opg-signer-batch-tests.$$
PRIVATE=$BASE/private.pem
PUBLIC=$BASE/public.pem
PASS=0 FAIL=0
trap 'rm -rf -- "$BASE"' EXIT
mkdir -p "$BASE"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE" >/dev/null 2>&1
openssl pkey -in "$PRIVATE" -pubout -out "$PUBLIC" >/dev/null 2>&1
KEY_HASH=$(sha256sum "$PUBLIC" | awk '{print $1}')

record() {
  local name=$1 actual=$2
  if [[ "$actual" == 0 ]]; then
    printf 'ok - %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf 'not ok - %s (rc=%s)\n' "$name" "$actual"; FAIL=$((FAIL + 1))
  fi
}

setup_case() {
  CASE=$BASE/$1
  APPROVALS=$CASE/approvals
  BIN=$CASE/bin
  LOG=$CASE/approve.log
  OUT=$CASE/out
  FAIL_RUN=
  mkdir -p "$APPROVALS" "$BIN"
  cp -- "$ROOT/signer/opg_list_pending.sh" "$BIN/opg_list_pending.sh"
  cp -- "$ROOT/signer/opg_approve_pending.sh" "$BIN/opg_approve_pending.sh"
  cat >"$BIN/opg_approve_run.sh" <<'MOCK'
#!/usr/bin/env bash
set -u
set -o pipefail
umask 077
run_id=${1:-}
[[ "$run_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,79}$ ]] || exit 2
confirmation=
IFS= read -r confirmation || exit 20
[[ "$confirmation" == APPROVE ]] || exit 20
printf '%s\n' "$run_id" >>"$OPG_APPROVE_LOG"
[[ "$run_id" != "${OPG_FAIL_RUN:-}" ]] || exit 55
dir=$OPG_APPROVAL_ROOT/$run_id
[[ -d "$dir" && ! -L "$dir" && ! -e "$dir/approval.json" ]] || exit 20
hash=$(sha256sum "$dir/patch_manifest.json" | awk '{print $1}')
host=$(awk -F'"' '/"hostname"/{for(i=1;i<=NF;i++)if($i=="hostname"){print $(i+2);exit}}' "$dir/patch_manifest.json")
expires=$(( $(date +%s) + 86400 ))
accept_fields=
while IFS='|' read -r finding code rest; do
  if [[ "$finding" == CONDITIONAL && "$code" =~ ^[A-Z0-9_]{1,80}$ ]]; then
    accept_fields+=',"accept_'"$code"'":"'"$code"'"'
  fi
done <"$dir/findings.psv"
printf '{"approved":true,"manifest_sha256":"%s","hostname":"%s","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","expires_epoch":%s,"manifest_signature_file":"%s/patch_manifest.sig","approval_signature_file":"%s/approval.sig"%s}\n' \
  "$hash" "$host" "$expires" "$dir" "$dir" "$accept_fields" >"$dir/approval.json"
openssl dgst -sha256 -sign "$OPG_TEST_PRIVATE" -out "$dir/patch_manifest.sig" "$dir/patch_manifest.json" >/dev/null 2>&1
openssl dgst -sha256 -sign "$OPG_TEST_PRIVATE" -out "$dir/approval.sig" "$dir/approval.json" >/dev/null 2>&1
MOCK
  chmod 0750 "$BIN"/*.sh
}

make_run() {
  local run_id=$1 host=$2 sid=$3 epoch=$4 assessment=${5:-READY} state=${6:-03_PLAN_GENERATED} phase=${7:-PLAN}
  local dir created blocked=0 finding=READY code=ASSESSMENT_READY
  dir=$APPROVALS/$run_id
  created=$(date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ')
  case $assessment in
    BLOCKED) blocked=1; finding=BLOCKED; code=BLOCKED_TEST ;;
    CONDITIONAL) finding=CONDITIONAL; code=RISK_ACCEPT ;;
  esac
  mkdir "$dir"
  printf '{"schema_version":1,"run_id":"%s","created_at":"%s","created_epoch":%s,"hostname":"%s","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","month":"JUL2026","approval_public_key_sha256":"%s"}\n' \
    "$run_id" "$created" "$epoch" "$host" "$KEY_HASH" >"$dir/patch_manifest.json"
  printf '{"run_id":"%s","hostname":"%s","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","status":"%s","blocked_count":%s,"unknown_count":0}\n' \
    "$run_id" "$host" "$assessment" "$blocked" >"$dir/assessment.json"
  printf '%s|%s|test|evidence\n' "$finding" "$code" >"$dir/findings.psv"
  printf '{"schema_version":1,"run_id":"%s","timestamp":"%s","hostname":"%s","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","sid":"%s","state":"%s","phase":"%s","exit_code":0}\n' \
    "$run_id" "$created" "$host" "$sid" "$state" "$phase" >"$dir/execution_state.json"
}

run_batch() {
  OPG_SIGNER_BIN=$BIN OPG_APPROVAL_ROOT=$APPROVALS OPG_APPROVAL_PUBLIC_KEY=$PUBLIC \
    OPG_TEST_PRIVATE=$PRIVATE OPG_APPROVE_LOG=$LOG OPG_FAIL_RUN=${FAIL_RUN:-} \
    "$BIN/opg_approve_pending.sh" "$@"
}

sign_direct() {
  printf 'APPROVE\n' | OPG_APPROVAL_ROOT=$APPROVALS OPG_TEST_PRIVATE=$PRIVATE OPG_APPROVE_LOG=$LOG \
    OPG_FAIL_RUN='' "$BIN/opg_approve_run.sh" "$1"
}

# 1-6. Selectie gebruikt uitsluitend de bestaande PENDING/readinessstatus.
setup_case selection
READY_A=DBHOST01-ORCL1-JUL2026-OEM-20260827T120000Z
CONDITIONAL=DBHOST02-ORCL2-JUL2026-OEM-20260827T120001Z
BLOCKED=DBHOST03-ORCL3-JUL2026-OEM-20260827T120002Z
UNKNOWN=DBHOST04-ORCL4-JUL2026-OEM-20260827T120003Z
APPROVED=DBHOST05-ORCL5-JUL2026-OEM-20260827T120004Z
COMPLETE=DBHOST06-ORCL6-JUL2026-OEM-20260827T120005Z
make_run "$READY_A" DBHOST01 ORCL1 1787832000
make_run "$CONDITIONAL" DBHOST02 ORCL2 1787832001 CONDITIONAL
make_run "$BLOCKED" DBHOST03 ORCL3 1787832002 BLOCKED
make_run "$UNKNOWN" DBHOST04 ORCL4 1787832003; printf '{broken\n' >"$APPROVALS/$UNKNOWN/assessment.json"
make_run "$APPROVED" DBHOST05 ORCL5 1787832004; sign_direct "$APPROVED"
make_run "$COMPLETE" DBHOST06 ORCL6 1787832005 READY 12_COMPLETE COMPLETE; sign_direct "$COMPLETE"
: >"$LOG"
run_batch --all --dry-run >"$OUT" 2>&1; rc=$?
ready_section=$(sed '/^SKIPPED:/,$d' "$OUT")
[[ $rc -eq 0 && "$ready_section" == *"$READY_A"* && "$ready_section" == *"$CONDITIONAL"* ]]
record '--all selecteert alleen PENDING/READY-runs' $?
[[ "$ready_section" != *"$BLOCKED"* && $(grep -c "$BLOCKED" "$OUT") -eq 1 ]]
record 'BLOCKED wordt nooit geselecteerd' $?
[[ "$ready_section" != *"$UNKNOWN"* && $(grep -c "$UNKNOWN" "$OUT") -eq 1 ]]
record 'UNKNOWN wordt nooit geselecteerd' $?
[[ "$ready_section" != *"$APPROVED"* && ! -s "$LOG" ]]
record 'APPROVED wordt nooit opnieuw gesigned' $?
[[ "$ready_section" != *"$COMPLETE"* && ! -s "$LOG" ]]
record 'COMPLETE wordt nooit geselecteerd' $?

setup_case conditional
CONDITIONAL=DBHOST02-ORCL2-JUL2026-OEM-20260827T121001Z
make_run "$CONDITIONAL" DBHOST02 ORCL2 1787832601 CONDITIONAL
printf 'yes\n' | run_batch --all >"$OUT" 2>&1; rc=$?
[[ $rc -eq 0 && -f "$APPROVALS/$CONDITIONAL/approval.sig" && $(cat "$LOG") == "$CONDITIONAL" ]]
record 'CONDITIONAL gebruikt dezelfde single-run approvalregels' $?

# 7. Mutatie na selectie en vóór bevestiging wordt bij de verse hercontrole geweigerd.
setup_case race
RACE=DBHOST07-ORCL7-JUL2026-OEM-20260827T122000Z
make_run "$RACE" DBHOST07 ORCL7 1787833200
mkfifo "$CASE/input"
exec 9<>"$CASE/input"
run_batch --all <"$CASE/input" >"$OUT" 2>&1 & batch_pid=$!
for _ in {1..100}; do grep -q 'Approve all 1 READY runs?' "$OUT" 2>/dev/null && break; sleep 0.05; done
sed -i 's/"03_PLAN_GENERATED"/"04_STATE_CHANGED"/' "$APPROVALS/$RACE/execution_state.json"
printf 'yes\n' >&9
wait "$batch_pid"; race_rc=$?
exec 9>&-
[[ $race_rc -eq 30 && ! -e "$APPROVALS/$RACE/approval.json" && ! -s "$LOG" ]]
record 'statuswijziging tussen selectie en signing wordt niet blind gesigned' $?

# 8. Dry-run is byte-identiek voor de approvalroot.
setup_case dryrun
DRY=DBHOST08-ORCL8-JUL2026-OEM-20260827T123000Z
make_run "$DRY" DBHOST08 ORCL8 1787833800
before=$(find "$APPROVALS" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
run_batch --all --dry-run >"$OUT" 2>&1; rc=$?
after=$(find "$APPROVALS" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
[[ $rc -eq 0 && "$before" == "$after" && ! -s "$LOG" ]]
record '--dry-run schrijft geen approval-artifacts' $?

# 9. Alleen exact yes activeert de single-run signer.
printf 'YES\n' | run_batch --all >"$OUT" 2>&1; rc=$?
[[ $rc -eq 0 && ! -e "$APPROVALS/$DRY/approval.json" && ! -s "$LOG" ]]
record 'bevestiging anders dan exact yes schrijft niets' $?

# 10. Twee targets behouden elk hun eigen token/signatures en signer-aanroep.
setup_case multitarget
MULTI_A=DBHOST01-ORCL1-JUL2026-OEM-20260827T124000Z
MULTI_B=DBHOST02-ORCL2-JUL2026-OEM-20260827T124001Z
make_run "$MULTI_A" DBHOST01 ORCL1 1787834400
make_run "$MULTI_B" DBHOST02 ORCL2 1787834401
printf 'yes\n' | run_batch --all >"$OUT" 2>&1; rc=$?
[[ $rc -eq 0 && -f "$APPROVALS/$MULTI_A/approval.sig" && -f "$APPROVALS/$MULTI_B/approval.sig" &&
   $(sort -u "$LOG" | wc -l) -eq 2 ]]
record 'multi-target runs krijgen afzonderlijke approvals' $?

# 11. Eén single-run failure stopt een onafhankelijk volgend target niet.
setup_case continue
FAIL_ONE=DBHOST03-ORCL3-JUL2026-OEM-20260827T125001Z
GOOD_ONE=DBHOST04-ORCL4-JUL2026-OEM-20260827T125000Z
make_run "$FAIL_ONE" DBHOST03 ORCL3 1787835001
make_run "$GOOD_ONE" DBHOST04 ORCL4 1787835000
FAIL_RUN=$FAIL_ONE
printf 'yes\n' | run_batch --all >"$OUT" 2>&1; rc=$?
[[ $rc -eq 30 && ! -e "$APPROVALS/$FAIL_ONE/approval.json" && -f "$APPROVALS/$GOOD_ONE/approval.sig" &&
   $(sort -u "$LOG" | wc -l) -eq 2 ]]
record 'failure op één RUN_ID signeert andere RUN_ID niet verkeerd' $?

# 12. Een symlinkrun blijft UNKNOWN en het target buiten de approvalroot blijft intact.
setup_case symlink
SAFE=DBHOST05-ORCL5-JUL2026-OEM-20260827T130000Z
make_run "$SAFE" DBHOST05 ORCL5 1787835600
mkdir "$CASE/outside"; printf 'keep\n' >"$CASE/outside/sentinel"
ln -s "$CASE/outside" "$APPROVALS/SYMLINK-RUN"
run_batch --all --dry-run >"$OUT" 2>&1; rc=$?
[[ $rc -eq 0 && $(cat "$CASE/outside/sentinel") == keep && $(grep -c 'SYMLINK-RUN' "$OUT") -eq 1 ]]
record 'symlink/pathgrens wordt fail-closed overgeslagen' $?

# 13-14. Default/help zijn read-only en geven de aanbevolen route.
setup_case default
DEFAULT=DBHOST06-ORCL6-JUL2026-OEM-20260827T131000Z
make_run "$DEFAULT" DBHOST06 ORCL6 1787836200
run_batch >"$OUT" 2>&1; rc=$?
[[ $rc -eq 0 && ! -s "$LOG" ]] && grep -Fq "$DEFAULT" "$OUT" && grep -Fq -- '--all --dry-run' "$OUT"
record 'default toont READY-runs en wijzigt niets' $?
run_batch --help >"$OUT" 2>&1; rc=$?
[[ $rc -eq 0 ]] && grep -Fq -- '--all' "$OUT" && grep -Fq -- '--dry-run' "$OUT"
record '--help documenteert de batchopties' $?

printf '\nSigner batch results: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
