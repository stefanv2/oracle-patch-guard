#!/usr/bin/env bash
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)
LIST=${ROOT}/signer/opg_list_pending.sh
BASE=/tmp/opg-signer-pending-tests.$$
APPROVALS=$BASE/approvals
PRIVATE=$BASE/private.pem
PUBLIC=$BASE/public.pem
PASS=0 FAIL=0
trap 'rm -rf -- "$BASE"' EXIT
mkdir -p "$APPROVALS"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE" >/dev/null 2>&1
openssl pkey -in "$PRIVATE" -pubout -out "$PUBLIC" >/dev/null 2>&1
KEY_HASH=$(sha256sum "$PUBLIC" | awk '{print $1}')

record() {
  local name=$1 expected=$2 actual=$3
  if [[ "$expected" == "$actual" ]]; then
    printf 'ok - %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf 'not ok - %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"; FAIL=$((FAIL + 1))
  fi
}

make_run() {
  local run_id=$1 host=$2 sid=$3 cycle=$4 epoch=$5 state=${6:-03_PLAN_GENERATED} phase=${7:-PLAN}
  local state_epoch=${8:-$epoch}
  local dir created state_timestamp
  dir=$APPROVALS/$run_id
  created=$(date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ')
  state_timestamp=$(date -u -d "@$state_epoch" '+%Y-%m-%dT%H:%M:%SZ')
  mkdir "$dir"
  cat >"$dir/patch_manifest.json" <<EOF
{"schema_version":1,"run_id":"$run_id","created_at":"$created","created_epoch":$epoch,"hostname":"$host","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","month":"$cycle","approval_public_key_sha256":"$KEY_HASH"}
EOF
  cat >"$dir/assessment.json" <<EOF
{"run_id":"$run_id","hostname":"$host","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","status":"READY","blocked_count":0,"unknown_count":0}
EOF
  printf 'READY|ASSESSMENT_READY|ready|evidence\n' >"$dir/findings.psv"
  cat >"$dir/execution_state.json" <<EOF
{"schema_version":1,"run_id":"$run_id","timestamp":"$state_timestamp","hostname":"$host","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","sid":"$sid","state":"$state","phase":"$phase","exit_code":0}
EOF
}

approve_run() {
  local run_id=$1
  local expires=${2:-$(( $(date +%s) + 86400 ))}
  local dir hash
  dir=$APPROVALS/$run_id
  hash=$(sha256sum "$dir/patch_manifest.json" | awk '{print $1}')
  cat >"$dir/approval.json" <<EOF
{"approved":true,"manifest_sha256":"$hash","hostname":"$(awk -F'"' '/"hostname"/{for(i=1;i<=NF;i++)if($i=="hostname"){print $(i+2);exit}}' "$dir/patch_manifest.json")","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","expires_epoch":$expires,"manifest_signature_file":"$dir/patch_manifest.sig","approval_signature_file":"$dir/approval.sig"}
EOF
  openssl dgst -sha256 -sign "$PRIVATE" -out "$dir/patch_manifest.sig" "$dir/patch_manifest.json"
  openssl dgst -sha256 -sign "$PRIVATE" -out "$dir/approval.sig" "$dir/approval.json"
}

write_completion() {
  local run_id=$1 sid=$2 completion_epoch=$3
  local dir completed_at host cycle manifest_hash approval_hash
  dir=$APPROVALS/$run_id
  completed_at=$(date -u -d "@$completion_epoch" '+%Y-%m-%dT%H:%M:%SZ')
  host=$(awk -F'"' '/"hostname"/{for(i=1;i<=NF;i++)if($i=="hostname"){print $(i+2);exit}}' "$dir/patch_manifest.json")
  cycle=$(awk -F'"' '/"month"/{for(i=1;i<=NF;i++)if($i=="month"){print $(i+2);exit}}' "$dir/patch_manifest.json")
  manifest_hash=$(sha256sum "$dir/patch_manifest.json" | awk '{print $1}')
  approval_hash=$(sha256sum "$dir/approval.json" | awk '{print $1}')
  cat >"$dir/completion.json" <<EOF
{"schema_version":1,"run_id":"$run_id","hostname":"$host","sid":"$sid","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","patch_cycle":"$cycle","completed_at":"$completed_at","completion_epoch":$completion_epoch,"state":"12_COMPLETE","phase":"COMPLETE","exit_code":0,"manifest_sha256":"$manifest_hash","approval_sha256":"$approval_hash"}
EOF
}

run_list() {
  OPG_APPROVAL_ROOT=$APPROVALS OPG_APPROVAL_PUBLIC_KEY=$PUBLIC bash "$LIST" "$@"
}

run_list_config() {
  OPG_CONFIG_FILE=$BASE/patchGD_guard.conf bash "$LIST" "$@"
}

PENDING_A=DBHOST01-ORCL1-JUL2026-OEM-20260827T120000Z
PENDING_B=DBHOST02-ORCL2-JUL2026-OEM-20260827T120001Z
APPROVED=DBHOST03-ORCL3-JUL2026-OEM-20260827T120002Z
COMPLETE=DBHOST04-ORCL4-JUL2026-OEM-20260827T120003Z
CORRUPT=DBHOST05-ORCL5-JUL2026-OEM-20260827T120004Z
PRESENCE=DBHOST06-ORCL6-JUL2026-OEM-20260827T120005Z
BADSIG=DBHOST07-ORCL7-JUL2026-OEM-20260827T120006Z
META=DBHOST08-ORCL8-JUL2026-OEM-20260827T120007Z
HISTORIC_COMPLETE=DBHOST09-ORCL9-JUL2026-OEM-20260827T120008Z
EXPIRED_ACTIVE=DBHOST10-ORCL10-JUL2026-OEM-20260827T120009Z
LATE_COMPLETE=DBHOST11-ORCL11-JUL2026-OEM-20260827T120010Z
INVALID_COMPLETE=DBHOST12-ORCL12-JUL2026-OEM-20260827T120011Z
FQDN_FALLBACK=DBHOST13-ORCL13-JUL2026-OEM-20260827T120012Z
UNRELIABLE_COMPLETE=DBHOST14-ORCL14-JUL2026-OEM-20260827T120013Z
HOST_MISMATCH=DBHOST15-ORCL15-JUL2026-OEM-20260827T120014Z
INCOMPLETE_COMPLETION=DBHOST16-ORCL16-JUL2026-OEM-20260827T120015Z
CORRUPT_COMPLETION=DBHOST17-ORCL17-JUL2026-OEM-20260827T120016Z
BAD_MANIFEST_SIG=DBHOST18-ORCL18-JUL2026-OEM-20260827T120017Z
SYMLINK_COMPLETION=DBHOST19-ORCL19-JUL2026-OEM-20260827T120018Z
LIVE_EXPIRED_COMPLETE=DBHOST20-ORCL20-JUL2026-OEM-20260827T120600Z
PRECHECK_ONLY=DBHOST21-ORCL21-JUL2026-PRECHECK-20260827T120700Z
TEST_NOW=$(date +%s)
HISTORIC_EXPIRY=$((TEST_NOW - 3600))
LIVE_COMPLETION_EPOCH=1787834226
LIVE_EXPIRES_EPOCH=1787861820

make_run "$PENDING_A" DBHOST01 '' JUL2026 1787832000
make_run "$PENDING_B" DBHOST02 '' JUL2026 1787832001
make_run "$APPROVED" DBHOST03 ORCL3 JUL2026 1787832002; approve_run "$APPROVED"
make_run "$COMPLETE" DBHOST04 ORCL4 JUL2026 1787832003; approve_run "$COMPLETE"; write_completion "$COMPLETE" ORCL4 1787832003
make_run "$CORRUPT" DBHOST05 ORCL5 JUL2026 1787832004; printf '{broken\n' >"$APPROVALS/$CORRUPT/patch_manifest.json"
make_run "$PRESENCE" DBHOST06 ORCL6 JUL2026 1787832005; printf '{}\n' >"$APPROVALS/$PRESENCE/approval.json"; printf fake >"$APPROVALS/$PRESENCE/patch_manifest.sig"; printf fake >"$APPROVALS/$PRESENCE/approval.sig"
make_run "$BADSIG" DBHOST07 ORCL7 JUL2026 1787832006; approve_run "$BADSIG"; printf '\000' | dd of="$APPROVALS/$BADSIG/approval.sig" bs=1 count=1 conv=notrunc status=none
make_run "$META" DBHOST08 ORCL8 JUL2026 1787832007
make_run "$HISTORIC_COMPLETE" DBHOST09 ORCL9 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$HISTORIC_COMPLETE" "$HISTORIC_EXPIRY"; write_completion "$HISTORIC_COMPLETE" ORCL9 $((HISTORIC_EXPIRY - 60))
make_run "$EXPIRED_ACTIVE" DBHOST10 ORCL10 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$EXPIRED_ACTIVE" "$HISTORIC_EXPIRY"
make_run "$LATE_COMPLETE" DBHOST11 ORCL11 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$LATE_COMPLETE" "$HISTORIC_EXPIRY"; write_completion "$LATE_COMPLETE" ORCL11 $((HISTORIC_EXPIRY + 1))
make_run "$INVALID_COMPLETE" DBHOST12 ORCL12 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$INVALID_COMPLETE" "$HISTORIC_EXPIRY"; write_completion "$INVALID_COMPLETE" ORCL12 $((HISTORIC_EXPIRY - 60)); printf '\000' | dd of="$APPROVALS/$INVALID_COMPLETE/approval.sig" bs=1 count=1 conv=notrunc status=none
make_run "$FQDN_FALLBACK" dbhost13.example.com '' JUL2026 $((TEST_NOW - 120))
make_run "$UNRELIABLE_COMPLETE" DBHOST14 ORCL14 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$UNRELIABLE_COMPLETE" "$HISTORIC_EXPIRY"; write_completion "$UNRELIABLE_COMPLETE" ORCL14 $((HISTORIC_EXPIRY - 60)); sed -i 's/"completed_at":"[^"]*"/"completed_at":"INVALID"/' "$APPROVALS/$UNRELIABLE_COMPLETE/completion.json"
make_run "$HOST_MISMATCH" DBHOST15 ORCL15 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$HOST_MISMATCH" "$HISTORIC_EXPIRY"; write_completion "$HOST_MISMATCH" ORCL15 $((HISTORIC_EXPIRY - 60)); sed -i 's/"hostname":"DBHOST15"/"hostname":"OTHERHOST"/' "$APPROVALS/$HOST_MISMATCH/completion.json"
make_run "$INCOMPLETE_COMPLETION" DBHOST16 ORCL16 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$INCOMPLETE_COMPLETION" "$HISTORIC_EXPIRY"; printf '{"schema_version":1}\n' >"$APPROVALS/$INCOMPLETE_COMPLETION/completion.json"
make_run "$CORRUPT_COMPLETION" DBHOST17 ORCL17 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$CORRUPT_COMPLETION" "$HISTORIC_EXPIRY"; printf '{broken\n' >"$APPROVALS/$CORRUPT_COMPLETION/completion.json"
make_run "$BAD_MANIFEST_SIG" DBHOST18 ORCL18 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$BAD_MANIFEST_SIG" "$HISTORIC_EXPIRY"; write_completion "$BAD_MANIFEST_SIG" ORCL18 $((HISTORIC_EXPIRY - 60)); printf '\000' | dd of="$APPROVALS/$BAD_MANIFEST_SIG/patch_manifest.sig" bs=1 count=1 conv=notrunc status=none
make_run "$SYMLINK_COMPLETION" DBHOST19 ORCL19 JUL2026 $((HISTORIC_EXPIRY - 600)); approve_run "$SYMLINK_COMPLETION" "$HISTORIC_EXPIRY"; printf '{}\n' >"$BASE/outside-completion.json"; ln -s "$BASE/outside-completion.json" "$APPROVALS/$SYMLINK_COMPLETION/completion.json"
make_run "$LIVE_EXPIRED_COMPLETE" dbhost20.example.com '' JUL2026 $((LIVE_COMPLETION_EPOCH - 600)); approve_run "$LIVE_EXPIRED_COMPLETE" "$LIVE_EXPIRES_EPOCH"; write_completion "$LIVE_EXPIRED_COMPLETE" ORCL20 "$LIVE_COMPLETION_EPOCH"
mkdir "$APPROVALS/$PRECHECK_ONLY"
printf '{"run_id":"%s","status":"UNKNOWN"}\n' "$PRECHECK_ONLY" >"$APPROVALS/$PRECHECK_ONLY/assessment.json"
printf 'UNKNOWN|PRECHECK_TEST|test|evidence\n' >"$APPROVALS/$PRECHECK_ONLY/findings.psv"
printf 'UNKNOWN|run_id=%s|exit_code=30\n' "$PRECHECK_ONLY" >"$APPROVALS/$PRECHECK_ONLY/precheck_result.psv"

default_out=$(run_list); default_rows=$(printf '%s\n' "$default_out" | awk 'NR>1{print $5"|"$6}')
[[ $(printf '%s\n' "$default_rows" | wc -l) -eq 4 && "$default_rows" != *APPROVED* && "$default_rows" != *COMPLETE* && "$default_rows" != *UNKNOWN* ]]
record 'default toont uitsluitend PENDING' 0 $?

pending_out=$(run_list --pending); [[ "$default_out" == "$pending_out" ]]
record '--pending is functioneel gelijk aan default' 0 $?

list_out=$(run_list --list)
for wanted in PENDING APPROVED COMPLETE UNKNOWN; do printf '%s\n' "$list_out" | awk -v s="$wanted" 'NR>1 && $5==s{found=1}END{exit !found}' || FAIL=$((FAIL + 100)); done
record '--list bevat PENDING APPROVED COMPLETE UNKNOWN' 0 $(( FAIL >= 100 ? 1 : 0 )); (( FAIL >= 100 )) && FAIL=$((FAIL - 100))

printf 'APPROVAL_ROOT=%s\nAPPROVAL_PUBLIC_KEY=%s\n' "$APPROVALS" "$PUBLIC" >"$BASE/patchGD_guard.conf"
config_out=$(run_list_config --list); rc=$?
printf '%s\n' "$config_out" | awk -v r="$LIVE_EXPIRED_COMPLETE" '$6==r && $5=="COMPLETE"{found=1}END{exit !found}' || rc=$?
record 'signer leest approvalroot en public key uit config' 0 "$rc"

printf 'APPROVAL_ROOT=relative/approvals\nAPPROVAL_PUBLIC_KEY=%s\n' "$PUBLIC" >"$BASE/patchGD_guard.conf"
run_list_config --list >/dev/null 2>&1; record 'signer weigert relatieve approvalroot uit config' 30 $?

printf 'APPROVAL_PUBLIC_KEY=%s\n' "$PUBLIC" >"$BASE/patchGD_guard.conf"
run_list_config --list >/dev/null 2>&1; record 'signer faalt bij ontbrekende APPROVAL_ROOT' 30 $?

printf 'APPROVAL_ROOT=relative/ignored\nAPPROVAL_PUBLIC_KEY=relative/ignored.pem\n' >"$BASE/patchGD_guard.conf"
OPG_CONFIG_FILE=$BASE/patchGD_guard.conf OPG_APPROVAL_ROOT=$APPROVALS OPG_APPROVAL_PUBLIC_KEY=$PUBLIC bash "$LIST" --list >/dev/null 2>&1
record 'signer environment override heeft precedence op config' 0 $?

printf '%s\n' "$list_out" | awk -v r="$PRESENCE" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'bestand-aanwezigheid alleen geeft geen APPROVED' 0 $?
printf '%s\n' "$list_out" | awk -v r="$BADSIG" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'ongeldige signature geeft UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$CORRUPT" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'corrupte approvaldirectory geeft UNKNOWN met RUN_ID' 0 $?
printf '%s\n' "$list_out" | awk -v r="$APPROVED" '$6==r && $5=="APPROVED"{found=1}END{exit !found}'
record 'geldige niet-verlopen approval met PLAN is APPROVED' 0 $?
printf '%s\n' "$list_out" | awk -v r="$HISTORIC_COMPLETE" '$6==r && $5=="COMPLETE"{found=1}END{exit !found}'
record 'verlopen approval met COMPLETE vóór expiry blijft COMPLETE' 0 $?
live_epoch_rc=0
(( TEST_NOW > LIVE_EXPIRES_EPOCH && LIVE_EXPIRES_EPOCH - LIVE_COMPLETION_EPOCH == 27594 )) || live_epoch_rc=99
printf '%s\n' "$list_out" | awk -v r="$LIVE_EXPIRED_COMPLETE" '$6==r && $2=="ORCL20" && $5=="COMPLETE"{found=1}END{exit !found}' || live_epoch_rc=$?
record 'live epochs: historische COMPLETE negeert current-time expiry' 0 "$live_epoch_rc"
printf '%s\n' "$list_out" | awk -v r="$EXPIRED_ACTIVE" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'verlopen approval voor niet-COMPLETE blijft UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$LATE_COMPLETE" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'COMPLETE na approval-expiry is UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$INVALID_COMPLETE" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'ongeldige signature blijft voor historische COMPLETE UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$UNRELIABLE_COMPLETE" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'onbetrouwbare COMPLETE-timestamp is UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$HOST_MISMATCH" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'completion hostname-mismatch is UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$INCOMPLETE_COMPLETION" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'incomplete completion is UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$CORRUPT_COMPLETION" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'corrupte completion is UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$BAD_MANIFEST_SIG" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'ongeldige manifestsignature met completion is UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$SYMLINK_COMPLETION" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'symlink completion is UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$PRECHECK_ONLY" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'handmatig onder approval-root geplaatste PRECHECK blijft UNKNOWN' 0 $?
printf '%s\n' "$default_out" | grep -Fq "$PRECHECK_ONLY"; precheck_pending_rc=$?
[[ $precheck_pending_rc -ne 0 ]]
record 'PRECHECK wordt niet als PENDING geselecteerd' 0 $?

printf '%s\n' "$list_out" | awk -v a="$PENDING_A" -v b="$PENDING_B" '$6==a && $1=="DBHOST01"{x=1}$6==b && $1=="DBHOST02"{y=1}END{exit !(x&&y)}'
record 'multi-target runs blijven afzonderlijk gekoppeld' 0 $?
printf '%s\n' "$list_out" | awk -v a="$COMPLETE" -v b="$HISTORIC_COMPLETE" '$6==a && $5=="COMPLETE"{x=1}$6==b && $5=="COMPLETE"{y=1}END{exit !(x&&y)}'
record 'multi-target completions blijven per RUN_ID geïsoleerd' 0 $?
printf '%s\n' "$list_out" | awk -v r="$META" '$6==r && $1=="DBHOST08" && $2=="ORCL8" && $3=="JUL2026"{found=1}END{exit !found}'
record 'host SID cycle en RUN_ID komen uit gecontroleerde metadata' 0 $?
printf '%s\n' "$list_out" | awk -v r="$PENDING_A" '$6==r && $2=="ORCL1"{found=1}END{exit !found}'
record 'SID-directoryfallback is gebonden aan host cycle en RUN_ID' 0 $?
printf '%s\n' "$list_out" | awk -v r="$FQDN_FALLBACK" '$6==r && $1=="dbhost13.example.com" && $2=="ORCL13"{found=1}END{exit !found}'
record 'FQDN-manifest gebruikt gecontroleerde short-host SID-fallback' 0 $?

outside=$BASE/outside; printf keep >"$outside"; ln -s "$outside" "$APPROVALS/SYMLINK-RUN"; mkfifo "$APPROVALS/FIFO-RUN"
safety_out=$(run_list --list)
printf '%s\n' "$safety_out" | awk '$6=="SYMLINK-RUN" && $5=="UNKNOWN"{s=1}$6=="FIFO-RUN" && $5=="UNKNOWN"{f=1}END{exit !(s&&f)}'
record 'symlink en onverwacht filetype worden per run UNKNOWN' 0 $?
before=$(find "$APPROVALS" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
run_list --cleanup >"$BASE/cleanup.out" 2>"$BASE/cleanup.err"; cleanup_rc=$?
after=$(find "$APPROVALS" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
[[ $cleanup_rc -eq 70 && "$before" == "$after" && $(cat "$outside") == keep ]]
record 'uitgestelde cleanup verwijdert PENDING APPROVED COMPLETE UNKNOWN of symlinktarget nooit' 0 $?

warning_output=$(
  printf 'RUN_ROOT="/tmp/run"\n' | awk -F= '$1=="RUN_ROOT"{sub(/^[^=]*=/,"");gsub(/^"|"$/ ,"");print;exit}' >/dev/null
  printf '"DB1",x\n' | awk -F, 'NR>0{gsub(/"/,"",$1)}' >/dev/null
  awk -F= '$1=="ID"{gsub(/"/,"",$2);print;exit}' /etc/os-release >/dev/null
) 2>&1
[[ "$warning_output" != *"regexp escape sequence"* ]]
record 'actieve awk-patronen produceren geen GNU awk quote-warning' 0 $?
if grep -nF 'gsub(/\"/' "$ROOT/project"/*.sh "$ROOT/oem-tasks"/*.sh >/dev/null; then active_escape_rc=1; else active_escape_rc=0; fi
record 'actieve runtime-tree bevat geen foutieve gsub regex-escape' 0 "$active_escape_rc"

bash "$LIST" --help >/dev/null; record '--help is beschikbaar' 0 $?

printf '\nSigner pending results: %d passed, %d failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
