#!/usr/bin/env python3
"""Focused OPG-05 state-publication fault and mutation-boundary tests."""

from pathlib import Path
import os
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
GUARD = (ROOT / "patchGD_guard.sh").read_text()


def function(name):
    match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", GUARD, re.M | re.S)
    if not match:
        raise RuntimeError("function not found: " + name)
    return match.group()


def run(script, functions=()):
    with tempfile.TemporaryDirectory(prefix="opg05-state.") as directory:
        work = Path(directory)
        env = {"PATH": "/usr/bin:/bin", "LANG": "C", "RUN_DIR": directory,
               "RUN_ID": "OPG05", "HOST_NAME": "fixture",
               "TARGET_ORACLE_HOME": str(work / "home"), "EXEC_USER": "tester"}
        (work / "home").mkdir()
        code = "source '" + str(ROOT / "lib/opg_core.sh") + "'\n"
        code += "\n".join(function(name) for name in functions) + "\n"
        code += "set -e\n"
        result = subprocess.run(["bash", "-o", "pipefail", "-c", code + script],
                                env=env, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE, universal_newlines=True)
        return result


def expect_failure(name, command, functions=()):
    result = run(command, functions)
    return result.returncode == 0, name, result


def atomic_cases():
    return [
        ("temporary create failure", """
mktemp() { return 1; }
if opg_atomic_write "$RUN_DIR/value" <<<'x'; then exit 1; fi
[[ ! -e "$RUN_DIR/value" ]]
[[ "$OPG_ATOMIC_WRITE_ERROR" == temporary_create ]]
"""),
        ("write or close failure", """
cat() { command cat >/dev/null; return 1; }
if opg_atomic_write "$RUN_DIR/value" <<<'x'; then exit 1; fi
[[ ! -e "$RUN_DIR/value" ]]
[[ "$OPG_ATOMIC_WRITE_ERROR" == write_or_close ]]
"""),
        ("flush failure", """
sync() { return 1; }
if opg_atomic_write "$RUN_DIR/value" <<<'x'; then exit 1; fi
[[ ! -e "$RUN_DIR/value" ]]
[[ "$OPG_ATOMIC_WRITE_ERROR" == flush ]]
"""),
        ("rename failure", """
mv() { return 1; }
if opg_atomic_write "$RUN_DIR/value" <<<'x'; then exit 1; fi
[[ ! -e "$RUN_DIR/value" ]]
[[ "$OPG_ATOMIC_WRITE_ERROR" == rename ]]
"""),
        ("directory flush failure after rename", """
sync_calls=0
sync() {
  sync_calls=$((sync_calls + 1))
  (( sync_calls < 2 )) || return 1
  command sync "$@"
}
if opg_atomic_write "$RUN_DIR/value" <<<'x'; then exit 1; fi
[[ -f "$RUN_DIR/value" ]]
[[ "$OPG_ATOMIC_WRITE_ERROR" == directory_flush ]]
"""),
    ]


def mutation_state_failure(name, injection, reason, disk_state):
    command = """
CURRENT_STATE=05_DATABASES_STOPPED; CURRENT_PHASE=STOP_DATABASES
opg_write_state 05_DATABASES_STOPPED STOP_DATABASES
PATCH_ROOT="$RUN_DIR/patches"; MONTH=M; DB_PATCH=111; OJVM_PATCH=222
__INJECTION__
opg_run_critical() { printf '%s\n' "$1" >>"$RUN_DIR/mutations"; : >"$2"; }
opg_run_capture() { printf '%s\n' "$1" >>"$RUN_DIR/commands"; printf '111\n222\n' >"$2"; }
if apply_binary_patches 2>"$RUN_DIR/error"; then exit 1; fi
grep -qx apply_db_ru "$RUN_DIR/mutations"
! grep -q apply_ojvm "$RUN_DIR/mutations"
[[ "$CURRENT_STATE:$CURRENT_PHASE" == 05_DATABASES_STOPPED:STOP_DATABASES ]]
[[ "$(opg_get_json_string "$RUN_DIR/execution_state.json" state)" == __DISK_STATE__ ]]
grep -q '|05_DATABASES_STOPPED|06_DB_BINARY_APPLIED|DB_BINARY|' "$RUN_DIR/state_history.log"
grep -q 'STATE_PUBLICATION_FAILED|reason=__REASON__' "$RUN_DIR/error"
"""
    command = command.replace("__INJECTION__", injection)
    command = command.replace("__REASON__", reason)
    command = command.replace("__DISK_STATE__", disk_state)
    return expect_failure(name, command, ("apply_binary_patches",))


def main():
    checks = []
    for name, command in atomic_cases():
        checks.append(expect_failure(name, command))

    checks.append(expect_failure("history failure preserves authoritative and memory state", """
CURRENT_STATE=OLD; CURRENT_PHASE=OLD_PHASE
opg_write_state OLD OLD_PHASE
rm -f "$RUN_DIR/state_history.log"
mkdir "$RUN_DIR/state_history.log"
if opg_write_state NEXT NEXT_PHASE 2>"$RUN_DIR/error"; then exit 1; fi
[[ "$CURRENT_STATE:$CURRENT_PHASE" == OLD:OLD_PHASE ]]
[[ "$(opg_get_json_string "$RUN_DIR/execution_state.json" state)" == OLD ]]
grep -q 'STATE_PUBLICATION_FAILED.*history' "$RUN_DIR/error"
"""))

    checks.append(expect_failure("positive state transition", """
CURRENT_STATE=OLD; CURRENT_PHASE=OLD_PHASE
opg_write_state NEXT NEXT_PHASE
[[ "$CURRENT_STATE:$CURRENT_PHASE" == NEXT:NEXT_PHASE ]]
[[ "$(opg_get_json_string "$RUN_DIR/execution_state.json" state)" == NEXT ]]
grep -q '|OLD|NEXT|NEXT_PHASE|' "$RUN_DIR/state_history.log"
"""))

    checks.append(expect_failure("non-writable run path preserves memory state", """
CURRENT_STATE=OLD; CURRENT_PHASE=OLD_PHASE; RUN_DIR="/proc/opg-state-test-$$"
if opg_write_state NEXT NEXT_PHASE 2>"/tmp/opg05-state-$$"; then exit 1; fi
rc=0
[[ "$CURRENT_STATE:$CURRENT_PHASE" == OLD:OLD_PHASE ]] || rc=1
grep -q 'STATE_PUBLICATION_FAILED' "/tmp/opg05-state-$$" || rc=1
rm -f "/tmp/opg05-state-$$"
exit "$rc"
"""))

    checks.append(expect_failure("failure reporting without writable run path", """
RUN_DIR="/proc/opg-state-test-$$"
if opg_mark_failure MANUAL_INTERVENTION_REQUIRED STATE_WRITE boom 1 2>"/tmp/opg05-error-$$"; then mark_rc=0; else mark_rc=$?; fi
rc=0
[[ $mark_rc -ne 0 ]] || rc=1
grep -q 'STATE_PUBLICATION_FAILED' "/tmp/opg05-error-$$" || rc=1
grep -q 'manual_intervention_required=true' "/tmp/opg05-error-$$" || rc=1
rm -f "/tmp/opg05-error-$$"
exit "$rc"
"""))

    checks.append(expect_failure("state failure before first mutation", """
touch "$RUN_DIR/manifest" "$RUN_DIR/token"
APPROVED_MANIFEST="$RUN_DIR/manifest"; APPROVAL_TOKEN="$RUN_DIR/token"
REQUEST_OS_UPDATE=false; REQUEST_REBOOT=false; DRY_RUN=false; LOCAL_MEDIA_MODE=disabled
load_run_context() { CURRENT_STATE=03_PLAN_GENERATED; CURRENT_PHASE=PLAN; }
initialize_local_media() { :; }; opg_verify_manifest_hash() { :; }
opg_sha256() { printf same; }; verify_approval() { :; }; confirm_interactive_apply() { :; }
opg_acquire_lock() { :; }; opg_release_lock() { :; }; perform_preapply_recheck() { :; }
perform_opatch_upgrade() { printf 'OPATCH\n' >>"$RUN_DIR/mutations"; }
stop_databases() { printf 'STOP\n' >>"$RUN_DIR/mutations"; }
apply_binary_patches() { printf 'DBPATCH\n' >>"$RUN_DIR/mutations"; }
start_original_databases() { printf 'START\n' >>"$RUN_DIR/mutations"; }
run_datapatch_all() { printf 'DATAPATCH\n' >>"$RUN_DIR/mutations"; }
run_utlrp_all() { printf 'UTLRP\n' >>"$RUN_DIR/mutations"; }; validate_all() { :; }
mkdir "$RUN_DIR/state_history.log"
if perform_apply >"$RUN_DIR/result" 2>"$RUN_DIR/error"; then rc=0; else rc=$?; fi
[[ $rc -eq 50 && ! -e "$RUN_DIR/mutations" ]]
grep -q 'STATE_PUBLICATION_FAILED' "$RUN_DIR/error"
""", ("perform_apply",)))

    checks.append(mutation_state_failure(
        "history flush failure stops next patch mutation",
        "sync() { return 1; }", "history_flush", "05_DATABASES_STOPPED"))
    checks.append(mutation_state_failure(
        "state write failure after successful history stops next mutation",
        "cat() { command cat >/dev/null; return 1; }",
        "authoritative_state_write_or_close", "05_DATABASES_STOPPED"))
    checks.append(mutation_state_failure(
        "state rename failure after successful history stops next mutation",
        "mv() { return 1; }", "authoritative_state_rename", "05_DATABASES_STOPPED"))
    checks.append(mutation_state_failure(
        "directory flush failure after rename stops next mutation",
        """sync_calls=0
sync() {
  sync_calls=$((sync_calls + 1))
  (( sync_calls < 3 )) || return 1
  command sync "$@"
}""", "authoritative_state_directory_flush", "06_DB_BINARY_APPLIED"))

    checks.append(expect_failure("state failure after completed mutation", """
touch "$RUN_DIR/manifest" "$RUN_DIR/token"
APPROVED_MANIFEST="$RUN_DIR/manifest"; APPROVAL_TOKEN="$RUN_DIR/token"
REQUEST_OS_UPDATE=false; REQUEST_REBOOT=false; DRY_RUN=false; LOCAL_MEDIA_MODE=disabled
load_run_context() { CURRENT_STATE=03_PLAN_GENERATED; CURRENT_PHASE=PLAN; }
initialize_local_media() { :; }; opg_verify_manifest_hash() { :; }
opg_sha256() { printf same; }; verify_approval() { :; }; confirm_interactive_apply() { :; }
opg_acquire_lock() { :; }; opg_release_lock() { :; }; perform_preapply_recheck() { :; }
perform_opatch_upgrade() { :; }; stop_databases() { :; }
apply_binary_patches() {
  printf 'DBPATCH\n' >>"$RUN_DIR/mutations"
  rm -f "$RUN_DIR/state_history.log"; mkdir "$RUN_DIR/state_history.log"
  opg_write_state 06_DB_BINARY_APPLIED DB_BINARY
}
start_original_databases() { printf 'START\n' >>"$RUN_DIR/mutations"; }
run_datapatch_all() { printf 'DATAPATCH\n' >>"$RUN_DIR/mutations"; }
run_utlrp_all() { printf 'UTLRP\n' >>"$RUN_DIR/mutations"; }; validate_all() { :; }
if perform_apply >"$RUN_DIR/result" 2>"$RUN_DIR/error"; then rc=0; else rc=$?; fi
[[ $rc -eq 50 ]]
grep -qx DBPATCH "$RUN_DIR/mutations"
! grep -q START "$RUN_DIR/mutations"
grep -q 'MANUAL_INTERVENTION_REQUIRED' "$RUN_DIR/result"
grep -q 'STATE_PUBLICATION_FAILED' "$RUN_DIR/error"
""", ("perform_apply",)))

    passed = 0
    for ok, name, result in checks:
        if ok:
            passed += 1
            print("ok - " + name)
        else:
            print("not ok - " + name)
            if result.stderr:
                print(result.stderr.strip())
    print("State write results: {0} passed, {1} failed".format(passed, len(checks) - passed))
    return int(passed != len(checks))


if __name__ == "__main__":
    raise SystemExit(main())
