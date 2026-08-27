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
  local dir created
  dir=$APPROVALS/$run_id
  created=$(date -u -d "@$epoch" '+%Y-%m-%dT%H:%M:%SZ')
  mkdir "$dir"
  cat >"$dir/patch_manifest.json" <<EOF
{"schema_version":1,"run_id":"$run_id","created_at":"$created","created_epoch":$epoch,"hostname":"$host","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","month":"$cycle","approval_public_key_sha256":"$KEY_HASH"}
EOF
  cat >"$dir/assessment.json" <<EOF
{"run_id":"$run_id","hostname":"$host","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","status":"READY","blocked_count":0,"unknown_count":0}
EOF
  printf 'READY|ASSESSMENT_READY|ready|evidence\n' >"$dir/findings.psv"
  cat >"$dir/execution_state.json" <<EOF
{"schema_version":1,"run_id":"$run_id","timestamp":"$created","hostname":"$host","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","sid":"$sid","state":"$state","phase":"$phase","exit_code":0}
EOF
}

approve_run() {
  local run_id=$1 dir hash expires
  dir=$APPROVALS/$run_id
  hash=$(sha256sum "$dir/patch_manifest.json" | awk '{print $1}')
  expires=$(( $(date +%s) + 86400 ))
  cat >"$dir/approval.json" <<EOF
{"approved":true,"manifest_sha256":"$hash","hostname":"$(awk -F'"' '/"hostname"/{for(i=1;i<=NF;i++)if($i=="hostname"){print $(i+2);exit}}' "$dir/patch_manifest.json")","target_oracle_home":"/u01/app/oracle/product/19/dbhome_1","expires_epoch":$expires,"manifest_signature_file":"$dir/patch_manifest.sig","approval_signature_file":"$dir/approval.sig"}
EOF
  openssl dgst -sha256 -sign "$PRIVATE" -out "$dir/patch_manifest.sig" "$dir/patch_manifest.json"
  openssl dgst -sha256 -sign "$PRIVATE" -out "$dir/approval.sig" "$dir/approval.json"
}

run_list() {
  OPG_APPROVAL_ROOT=$APPROVALS OPG_APPROVAL_PUBLIC_KEY=$PUBLIC bash "$LIST" "$@"
}

PENDING_A=DBHOST01-ORCL1-JUL2026-OEM-20260827T120000Z
PENDING_B=DBHOST02-ORCL2-JUL2026-OEM-20260827T120001Z
APPROVED=DBHOST03-ORCL3-JUL2026-OEM-20260827T120002Z
COMPLETE=DBHOST04-ORCL4-JUL2026-OEM-20260827T120003Z
CORRUPT=DBHOST05-ORCL5-JUL2026-OEM-20260827T120004Z
PRESENCE=DBHOST06-ORCL6-JUL2026-OEM-20260827T120005Z
BADSIG=DBHOST07-ORCL7-JUL2026-OEM-20260827T120006Z
META=DBHOST08-ORCL8-JUL2026-OEM-20260827T120007Z

make_run "$PENDING_A" DBHOST01 '' JUL2026 1787832000
make_run "$PENDING_B" DBHOST02 '' JUL2026 1787832001
make_run "$APPROVED" DBHOST03 ORCL3 JUL2026 1787832002; approve_run "$APPROVED"
make_run "$COMPLETE" DBHOST04 ORCL4 JUL2026 1787832003 12_COMPLETE COMPLETE; approve_run "$COMPLETE"
make_run "$CORRUPT" DBHOST05 ORCL5 JUL2026 1787832004; printf '{broken\n' >"$APPROVALS/$CORRUPT/patch_manifest.json"
make_run "$PRESENCE" DBHOST06 ORCL6 JUL2026 1787832005; printf '{}\n' >"$APPROVALS/$PRESENCE/approval.json"; printf fake >"$APPROVALS/$PRESENCE/patch_manifest.sig"; printf fake >"$APPROVALS/$PRESENCE/approval.sig"
make_run "$BADSIG" DBHOST07 ORCL7 JUL2026 1787832006; approve_run "$BADSIG"; printf '\000' | dd of="$APPROVALS/$BADSIG/approval.sig" bs=1 count=1 conv=notrunc status=none
make_run "$META" DBHOST08 ORCL8 JUL2026 1787832007

default_out=$(run_list); default_rows=$(printf '%s\n' "$default_out" | awk 'NR>1{print $5"|"$6}')
[[ $(printf '%s\n' "$default_rows" | wc -l) -eq 3 && "$default_rows" != *APPROVED* && "$default_rows" != *COMPLETE* && "$default_rows" != *UNKNOWN* ]]
record 'default toont uitsluitend PENDING' 0 $?

pending_out=$(run_list --pending); [[ "$default_out" == "$pending_out" ]]
record '--pending is functioneel gelijk aan default' 0 $?

list_out=$(run_list --list)
for wanted in PENDING APPROVED COMPLETE UNKNOWN; do printf '%s\n' "$list_out" | awk -v s="$wanted" 'NR>1 && $5==s{found=1}END{exit !found}' || FAIL=$((FAIL + 100)); done
record '--list bevat PENDING APPROVED COMPLETE UNKNOWN' 0 $(( FAIL >= 100 ? 1 : 0 )); (( FAIL >= 100 )) && FAIL=$((FAIL - 100))

printf '%s\n' "$list_out" | awk -v r="$PRESENCE" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'bestand-aanwezigheid alleen geeft geen APPROVED' 0 $?
printf '%s\n' "$list_out" | awk -v r="$BADSIG" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'ongeldige signature geeft UNKNOWN' 0 $?
printf '%s\n' "$list_out" | awk -v r="$CORRUPT" '$6==r && $5=="UNKNOWN"{found=1}END{exit !found}'
record 'corrupte approvaldirectory geeft UNKNOWN met RUN_ID' 0 $?

printf '%s\n' "$list_out" | awk -v a="$PENDING_A" -v b="$PENDING_B" '$6==a && $1=="DBHOST01"{x=1}$6==b && $1=="DBHOST02"{y=1}END{exit !(x&&y)}'
record 'multi-target runs blijven afzonderlijk gekoppeld' 0 $?
printf '%s\n' "$list_out" | awk -v r="$META" '$6==r && $1=="DBHOST08" && $2=="ORCL8" && $3=="JUL2026"{found=1}END{exit !found}'
record 'host SID cycle en RUN_ID komen uit gecontroleerde metadata' 0 $?
printf '%s\n' "$list_out" | awk -v r="$PENDING_A" '$6==r && $2=="ORCL1"{found=1}END{exit !found}'
record 'SID-directoryfallback is gebonden aan host cycle en RUN_ID' 0 $?

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
