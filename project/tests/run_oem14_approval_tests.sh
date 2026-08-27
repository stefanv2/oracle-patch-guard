#!/usr/bin/env bash
# Gerichte OEM14-regressies voor state-preserving approval dry-run.
set -u
set -o pipefail
umask 077

ROOT=$(cd -P -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
STAGE_SCRIPT=$(cd -P -- "$ROOT/../oem-tasks" 2>/dev/null && pwd -P)/opg_stage_approval.sh
TMP_BASE=$(mktemp -d "${TMPDIR:-/tmp}/opg-oem14-tests.XXXXXX") || exit 1
PASS=0 FAIL=0
PRIVATE_KEY="$TMP_BASE/approval-private.pem"
PUBLIC_KEY="$TMP_BASE/approval-public.pem"
openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$PRIVATE_KEY" >/dev/null 2>&1 || exit 1
openssl pkey -in "$PRIVATE_KEY" -pubout -out "$PUBLIC_KEY" >/dev/null 2>&1 || exit 1
trap 'rm -rf -- "$TMP_BASE"' EXIT

record() {
  local name=$1 expected=$2 actual=$3 output=${4:-} ok=true
  if [[ -n "$output" ]]; then
    grep -q "|exit_code=${expected}$" "$output" 2>/dev/null || ok=false
  fi
  if [[ "$expected" == "$actual" && "$ok" == true ]]; then
    printf 'ok - %s\n' "$name"; PASS=$((PASS + 1))
  else
    printf 'not ok - %s (expected=%s actual=%s)\n' "$name" "$expected" "$actual"
    [[ -r "$output" ]] && tail -n 20 "$output"
    FAIL=$((FAIL + 1))
  fi
}

state_is_plan_and_unchanged() {
  local before=$1 state_file=$2
  [[ "$before" == "$(sha256sum "$state_file" | awk '{print $1}')" ]] &&
    grep -q '"state": "03_PLAN_GENERATED"' "$state_file" &&
    grep -q '"phase": "PLAN"' "$state_file"
}

setup_case() {
  local name=$1
  CASE_DIR="$TMP_BASE/$name"; HOME_DIR="$CASE_DIR/dbhome_1"; RUN_ROOT="$CASE_DIR/runs"; LOCK_ROOT="$CASE_DIR/locks"
  PATCH_ROOT="$CASE_DIR/patches"; OPATCH_ROOT="$PATCH_ROOT/opatch"; ORATAB="$CASE_DIR/oratab"
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
  cp -- "$PUBLIC_KEY" "$CASE_DIR/approval-public.pem"
  sed "s|__TARGET_HOME__|$HOME_DIR|g" "$ROOT/fixtures/healthy_single/database_inventory.csv" >"$CASE_DIR/fixture/database_inventory.csv"
  CONFIG="$CASE_DIR/opg.conf"
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
TEST_REQUIRE_SIGNATURES=true
MOCK_CENTRAL_INVENTORY=$CASE_DIR/central_inventory
EOF
  FIXTURE_ENV="$CASE_DIR/fixture.env"
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

prepare_plan() {
  local run=$1
  guard assess --non-interactive --target-oracle-home "$HOME_DIR" --run-id "$run" 39472050 39222882 JUL2026 12.2.0.1.52 p6880880_190000_Linux-x86-64.zip >/dev/null 2>&1 || [[ $? == 10 ]]
  guard plan --non-interactive --run-id "$run" >/dev/null 2>&1
}

make_approval() {
  local run=$1 expires=${2:-$(( $(date +%s) + 3600 ))} token manifest_signature approval_signature hash
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
  "accept_HOME_RECOVERY_REBUILD_VERIFIED": "HOME_RECOVERY_REBUILD_VERIFIED",
  "manifest_signature_file": "$manifest_signature",
  "approval_signature_file": "$approval_signature"
}
EOF
  openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$manifest_signature" "$RUN_ROOT/$run/patch_manifest.json"
  openssl dgst -sha256 -sign "$PRIVATE_KEY" -out "$approval_signature" "$token"
  printf '%s\n' "$token"
}

dry_apply() {
  local run=$1 manifest=$2 token=$3 output=$4
  guard apply --dry-run --non-interactive --run-id "$run" --approved-manifest "$manifest" --approval-token "$token" >"$output" 2>&1
}

setup_stage_boundary() {
  local approval_root=$1 helper_dir="$CASE_DIR/local-sbin" helper="$CASE_DIR/local-sbin/opg_context_root.sh" mock_sudo="$CASE_DIR/mock-sudo"
  local current_owner current_group
  current_owner=$(id -un)
  current_group=$(id -gn)
  mkdir -p "$helper_dir" "$approval_root" "$CASE_DIR/helper-context" "$CASE_DIR/helper-runs"
  chmod 0755 "$helper_dir"
  chmod 0750 "$approval_root"
  cp "$ROOT/../oem-tasks/opg_context_root.sh" "$helper"
  chmod 0755 "$helper"
  cat >"$mock_sudo" <<EOF
#!/usr/bin/env bash
[[ \$1 == -n ]] || exit 70
shift
export OPG_CONTEXT_HELPER_TEST_MODE=1
export OPG_CONTEXT_HELPER_TEST_ROOT='$CASE_DIR/helper-context'
export OPG_CONTEXT_HELPER_TEST_RUN_ROOT='$CASE_DIR/helper-runs'
export OPG_CONTEXT_HELPER_TEST_APPROVAL_ROOT='$approval_root'
export OPG_CONTEXT_HELPER_TEST_GROUP='$current_group'
exec "\$@"
EOF
  chmod 0755 "$mock_sudo"
  export OPG_STAGE_TEST_MODE=1 OPG_STAGE_SUDO_BIN="$mock_sudo" OPG_STAGE_CONTEXT_HELPER="$helper"
  export OPG_STAGE_CONTEXT_HELPER_OWNER="$current_owner" OPG_STAGE_CONTEXT_HELPER_GROUP="$current_group" OPG_STAGE_CONTEXT_HELPER_PARENT_STOP="$helper_dir"
  export OPG_APPROVAL_DIRECTORY_OWNER="$current_owner" OPG_APPROVAL_GROUP="$current_group"
}

setup_case ready; prepare_plan O14A; token=$(make_approval O14A); state="$RUN_ROOT/O14A/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14A "$RUN_ROOT/O14A/patch_manifest.json" "$token" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99
record 'valid approval dry-run READY preserves PLAN state' 0 "$rc" "$CASE_DIR/out"

setup_case unreadable; prepare_plan O14B; token=$(make_approval O14B); state="$RUN_ROOT/O14B/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14B "$CASE_DIR/does-not-exist.json" "$token" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99; grep -q 'approved manifest is not readable' "$CASE_DIR/out" || rc=98
record 'unreadable approved manifest BLOCKED preserves PLAN state' 20 "$rc" "$CASE_DIR/out"

setup_case missingtoken; prepare_plan O14C; state="$RUN_ROOT/O14C/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14C "$RUN_ROOT/O14C/patch_manifest.json" "$CASE_DIR/missing-token.json" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99
record 'missing approval token BLOCKED preserves PLAN state' 20 "$rc" "$CASE_DIR/out"

setup_case badmanifestsig; prepare_plan O14D; token=$(make_approval O14D); printf 'bad\n' >"$RUN_ROOT/O14D/patch_manifest.sig"; state="$RUN_ROOT/O14D/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14D "$RUN_ROOT/O14D/patch_manifest.json" "$token" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99; grep -q 'manifest signature verification failed' "$CASE_DIR/out" || rc=98
record 'bad manifest signature BLOCKED preserves PLAN state' 20 "$rc" "$CASE_DIR/out"

setup_case badapprovalsig; prepare_plan O14E; token=$(make_approval O14E); printf 'bad\n' >"$RUN_ROOT/O14E/approval.sig"; state="$RUN_ROOT/O14E/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14E "$RUN_ROOT/O14E/patch_manifest.json" "$token" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99; grep -q 'approval signature verification failed' "$CASE_DIR/out" || rc=98
record 'bad approval signature BLOCKED preserves PLAN state' 20 "$rc" "$CASE_DIR/out"

setup_case expired; prepare_plan O14F; token=$(make_approval O14F "$(( $(date +%s) - 1 ))"); state="$RUN_ROOT/O14F/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14F "$RUN_ROOT/O14F/patch_manifest.json" "$token" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99; grep -q 'approval token expired' "$CASE_DIR/out" || rc=98
record 'expired approval BLOCKED preserves PLAN state' 20 "$rc" "$CASE_DIR/out"

setup_case mismatch; prepare_plan O14G; token=$(make_approval O14G); cp "$RUN_ROOT/O14G/patch_manifest.json" "$CASE_DIR/other-manifest.json"; chmod u+w "$CASE_DIR/other-manifest.json"; printf '\n' >>"$CASE_DIR/other-manifest.json"; state="$RUN_ROOT/O14G/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14G "$CASE_DIR/other-manifest.json" "$token" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99
record 'manifest mismatch BLOCKED preserves PLAN state' 20 "$rc" "$CASE_DIR/out"

setup_case preblocked; prepare_plan O14H; token=$(make_approval O14H); printf '\nMOCK_CHECK_BACKUP=BLOCKED\n' >>"$FIXTURE_ENV"; state="$RUN_ROOT/O14H/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14H "$RUN_ROOT/O14H/patch_manifest.json" "$token" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99
record 'preapply BLOCKED dry-run preserves PLAN state' 20 "$rc" "$CASE_DIR/out"

setup_case preunknown; prepare_plan O14I; token=$(make_approval O14I); printf '\nMOCK_CHECK_BACKUP=UNKNOWN\n' >>"$FIXTURE_ENV"; state="$RUN_ROOT/O14I/execution_state.json"; before=$(sha256sum "$state" | awk '{print $1}')
dry_apply O14I "$RUN_ROOT/O14I/patch_manifest.json" "$token" "$CASE_DIR/out"; rc=$?; state_is_plan_and_unchanged "$before" "$state" || rc=99
record 'preapply UNKNOWN dry-run preserves PLAN state' 30 "$rc" "$CASE_DIR/out"

setup_case realapply; prepare_plan O14J; token=$(make_approval O14J)
guard apply --non-interactive --run-id O14J --approved-manifest "$RUN_ROOT/O14J/patch_manifest.json" --approval-token "$token" >"$CASE_DIR/out" 2>&1; rc=$?; grep -q '"state": "12_COMPLETE"' "$RUN_ROOT/O14J/execution_state.json" || rc=99
record 'real APPLY retains state-machine progression' 0 "$rc" "$CASE_DIR/out"

setup_case staging; prepare_plan O14K; setup_stage_boundary "$CASE_DIR/approvals"; current_owner=$(id -un); current_group=$(id -gn)
OPG_STAGE_RUN_ROOT="$RUN_ROOT" OPG_STAGE_APPROVAL_ROOT="$CASE_DIR/approvals" bash "$STAGE_SCRIPT" O14K >"$CASE_DIR/stage.out" 2>&1; rc=$?
staged="$CASE_DIR/approvals/O14K"; [[ "$(stat -c '%U:%G:%a' "$staged")" == "$current_owner:$current_group:750" ]] || rc=99
for file in patch_manifest.json assessment.json findings.psv execution_state.json; do [[ "$(stat -c '%U:%G:%a' "$staged/$file")" == "$current_owner:$current_group:440" ]] || rc=98; done
compgen -G "$CASE_DIR/approvals/.O14K.staging.*" >/dev/null && rc=97
record 'privileged staging publiceert veilige directory en files' 0 "$rc"

setup_case stagepath; prepare_plan O14L; bash "$STAGE_SCRIPT" '../O14L' >"$CASE_DIR/stage.out" 2>&1; record 'approval staging weigert path traversal RUN_ID' 2 $?

setup_case stagesymlink; prepare_plan O14M; mkdir "$CASE_DIR/approval-real"; chmod 0750 "$CASE_DIR/approval-real"; ln -s "$CASE_DIR/approval-real" "$CASE_DIR/approval-link"; setup_stage_boundary "$CASE_DIR/approval-link"
OPG_STAGE_RUN_ROOT="$RUN_ROOT" OPG_STAGE_APPROVAL_ROOT="$CASE_DIR/approval-link" bash "$STAGE_SCRIPT" O14M >"$CASE_DIR/stage.out" 2>&1
record 'approval staging weigert symlink approvalroot' 30 $?

printf '\nOEM14 results: %s passed, %s failed\n' "$PASS" "$FAIL"
(( FAIL == 0 ))
