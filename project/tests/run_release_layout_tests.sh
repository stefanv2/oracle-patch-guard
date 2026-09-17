#!/usr/bin/env bash
set -u
set -o pipefail

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)
OEM_SOURCE="$ROOT/oem-tasks"
WRAPPER="$OEM_SOURCE/opg_oem.sh"
BOOTSTRAP="$OEM_SOURCE/opg_bootstrap_host.sh"

passed=0
failed=0

record() {
  local name=$1 rc=$2
  if [[ $rc -eq 0 ]]; then
    printf 'PASS: %s\n' "$name"
    passed=$((passed + 1))
  else
    printf 'FAIL: %s\n' "$name"
    failed=$((failed + 1))
  fi
}

rc=0
for helper in \
  opg_oem.sh \
  opg_prepare_host.sh \
  opg_create_window.sh \
  opg_assess_task.sh \
  opg_stage_approval.sh \
  opg_blackout.py
do
  [[ -f "$OEM_SOURCE/$helper" && ! -L "$OEM_SOURCE/$helper" ]] || rc=1
done
record 'releasebron bevat alle vereiste OEM-runtimebestanden' "$rc"

rc=0
grep -Fqx '  TASK_ROOT=${OPG_ROOT}/current/oem-tasks' "$WRAPPER" || rc=1
grep -Fqx '  TASK_ROOT=${OPG_TEST_TASK_ROOT:-${OPG_ROOT}/current/oem-tasks}' "$WRAPPER" || rc=1
record 'wrapper routeert productie en testdefault naar current/oem-tasks' "$rc"

rc=0
if grep -R -n -E '\$\{OPG_ROOT\}/oem-tasks|/oracle-patch-guard/oem-tasks/' \
  --exclude-dir=tests --exclude-dir=__pycache__ \
  "$ROOT/oem-tasks" "$ROOT/project" "$ROOT/signer" \
  >/dev/null; then
  rc=1
fi
record 'actieve runtimecode bevat geen oude OPG_ROOT/oem-tasks-route' "$rc"

rc=0
grep -Fqx 'SRC_CONFIG="$OPG_ROOT/config/patchGD_guard.conf"' "$BOOTSTRAP" || rc=1
grep -Fqx '    CONFIG_DST=/etc/oracle-patch-guard/patchGD_guard.conf' "$BOOTSTRAP" || rc=1
record 'bootstrap installeert centrale config als lokale hostconfig' "$rc"

rc=0
for script in "$OEM_SOURCE"/*.sh; do
  bash -n "$script" || rc=1
done
python3 -c 'import ast, sys; ast.parse(open(sys.argv[1], encoding="utf-8").read())' \
  "$OEM_SOURCE/opg_blackout.py" || rc=1
record 'OEM-releasebron slaagt voor shell- en Python-syntax' "$rc"

printf '\nRelease-layout results: %d passed, %d failed\n' "$passed" "$failed"
[[ $failed -eq 0 ]]
