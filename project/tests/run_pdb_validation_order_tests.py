#!/usr/bin/env python3
"""Focused OPG-06 PDB validation-order and restoration tests."""

from pathlib import Path
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
GUARD = (ROOT / "patchGD_guard.sh").read_text()
HEADER = ("SID,ORACLE_HOME,oratab_autostart,instance_running,database_role,"
          "open_mode,CDB,PDB_status,listener,services")


def function(name):
    match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", GUARD, re.M | re.S)
    if not match:
        raise RuntimeError("function not found: " + name)
    return match.group()


def run(work, command, functions=()):
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "RUN_DIR": str(work),
           "RUN_ID": "OPG06", "TARGET_ORACLE_HOME": str(work / "home"),
           "SAFE_PATH": "/usr/bin:/bin", "OPG_TEST_MODE": "1",
           "HOST_NAME": "fixture", "EXEC_USER": "oracle"}
    code = "source '" + str(ROOT / "lib/opg_core.sh") + "'\n"
    code += "\n".join(function(name) for name in functions) + "\nset -u\n"
    return subprocess.run(["bash", "-o", "pipefail", "-c", code + command],
                          env=env, stdout=subprocess.PIPE,
                          stderr=subprocess.PIPE, text=True)


def write_baseline(work, pdb_states, cdb="YES"):
    values = ("DB1", str(work / "home"), "Y", "true", "PRIMARY",
              "READ WRITE", cdb, pdb_states, "NONE", "APP")
    path = work / "bound-baseline.csv"
    path.write_text(HEADER + "\n" + ",".join('"' + value + '"' for value in values) + "\n")
    return path


def restore_case(name, original, current, expected_sql=(), forbidden_sql=(),
                 final=None, after_rc=0, expect_success=True):
    with tempfile.TemporaryDirectory(prefix="opg06-restore.") as directory:
        work = Path(directory)
        (work / "home").mkdir()
        baseline = write_baseline(work, original)
        final_assignment = ""
        if final is not None:
            final_assignment = "MOCK_PDB_RESTORE_FINAL_STATES='{}'\n".format(final)
        command = """
OPG_DATABASE_BASELINE_FILE='{baseline}'
MOCK_PDB_CURRENT_STATES='{current}'
MOCK_RC_pdb_state_after_DB1={after_rc}
{final_assignment}
export OPG_DATABASE_BASELINE_FILE MOCK_PDB_CURRENT_STATES MOCK_RC_pdb_state_after_DB1 MOCK_PDB_RESTORE_FINAL_STATES
restore_pdb_state DB1
""".format(baseline=baseline, current=current, after_rc=after_rc,
           final_assignment=final_assignment)
        result = run(work, command, ("restore_pdb_state",))
        sql = ((work / "restore_pdb_DB1.sql").read_text()
               if (work / "restore_pdb_DB1.sql").exists() else "")
        ok = (result.returncode == 0) == expect_success
        ok = ok and all(line in sql for line in expected_sql)
        ok = ok and all(line not in sql for line in forbidden_sql)
        return ok, name, result


def flow_case(name, validate_rc=0, final_validate_rc=None, restore_rc=0, expected_rc=0):
    with tempfile.TemporaryDirectory(prefix="opg06-flow.") as directory:
        work = Path(directory)
        (work / "home").mkdir()
        command = r'''
opg_manifest_sids() { printf 'DB1\n'; }
opg_read_original_state() { [[ "$2" == running ]] && printf 'true\n' || printf 'YES\n'; }
prepare_pdbs_for_datapatch() { printf 'PREPARE\n' >>"$RUN_DIR/events"; }
opg_run_capture() { printf 'DATAPATCH\n' >>"$RUN_DIR/events"; printf 'ok\n' >"$2"; }
opg_verify_command_success_text() { :; }
validation_calls=0
validate_datapatch_sqlpatch() {
  validation_calls=$((validation_calls + 1))
  printf 'SQLPATCH\n' >>"$RUN_DIR/events"
  (( validation_calls == 1 )) && return __VALIDATE_RC__
  return __FINAL_VALIDATE_RC__
}
opg_write_completion_marker() { printf 'MARKER:%s\n' "$4" >>"$RUN_DIR/events"; }
restore_pdb_state() { printf 'RESTORE\n' >>"$RUN_DIR/events"; return __RESTORE_RC__; }
opg_mark_failure() { printf 'FAILURE:%s\n' "$2" >>"$RUN_DIR/events"; }
opg_write_state() { printf 'STATE:%s\n' "$1" >>"$RUN_DIR/events"; }
if run_datapatch_all; then rc=0; else rc=$?; fi
cat "$RUN_DIR/events"
[[ $rc -eq __EXPECTED_RC__ ]]
'''.replace("__VALIDATE_RC__", str(validate_rc)).replace(
            "__FINAL_VALIDATE_RC__", str(validate_rc if final_validate_rc is None else final_validate_rc)).replace(
            "__RESTORE_RC__", str(restore_rc)).replace("__EXPECTED_RC__", str(expected_rc))
        result = run(work, command, ("run_datapatch_all",))
        events = (work / "events").read_text().splitlines()
        return result, events


def apply_result_case(name, state, phase, expected_status, expected_exit,
                      final_validation=False):
    with tempfile.TemporaryDirectory(prefix="opg06-apply-result.") as directory:
        work = Path(directory)
        (work / "home").mkdir()
        (work / "patch_manifest.json").write_text("manifest\n")
        (work / "approved").write_text("manifest\n")
        (work / "token").write_text("token\n")
        command = r'''
DRY_RUN=false; REQUEST_OS_UPDATE=false; REQUEST_REBOOT=false; LOCAL_MEDIA_MODE=disabled
APPROVED_MANIFEST="$RUN_DIR/approved"; APPROVAL_TOKEN="$RUN_DIR/token"
load_run_context() { CURRENT_STATE=03_PLAN_GENERATED; CURRENT_PHASE=PLAN; }
initialize_local_media() { :; }; opg_verify_manifest_hash() { :; }
opg_sha256() { printf 'same\n'; }; verify_approval() { :; }
confirm_interactive_apply() { :; }; opg_acquire_lock() { :; }
opg_release_lock() { :; }; opg_prepare_database_baseline_snapshot() { :; }
perform_preapply_recheck() { :; }
opg_write_state() { CURRENT_STATE=$1; CURRENT_PHASE=$2; }
perform_opatch_upgrade() { :; }; stop_databases() { :; }
apply_binary_patches() { :; }; start_original_databases() { :; }
run_datapatch_all() {
  CURRENT_STATE='__STATE__'; CURRENT_PHASE='__PHASE__'
  OPG_DATAPATCH_FINAL_VALIDATION_FAILED=__FINAL_VALIDATION__
  return 1
}
run_utlrp_all() { printf 'UNEXPECTED_UTLRP\n' >>"$RUN_DIR/mutations"; }
validate_all() { printf 'UNEXPECTED_VALIDATE\n' >>"$RUN_DIR/mutations"; }
if perform_apply >"$RUN_DIR/result" 2>"$RUN_DIR/error"; then rc=0; else rc=$?; fi
cat "$RUN_DIR/result"
check_rc=0
[[ $rc -eq __EXPECTED_EXIT__ ]] || check_rc=1
grep -Eq 'OPG_RESULT\|.*status=__EXPECTED_STATUS__\|phase=__PHASE__\|exit_code=__EXPECTED_EXIT__$' "$RUN_DIR/result" || check_rc=1
[[ ! -e "$RUN_DIR/mutations" ]] || check_rc=1
exit "$check_rc"
'''.replace("__STATE__", state).replace("__PHASE__", phase).replace(
            "__EXPECTED_STATUS__", expected_status).replace(
            "__EXPECTED_EXIT__", str(expected_exit)).replace(
            "__FINAL_VALIDATION__", "true" if final_validation else "false")
        result = run(work, command, ("perform_apply",))
        return result.returncode == 0, name, result


def main():
    checks = []
    checks.append(restore_case(
        "MOUNTED restored exactly", "PDB1=MOUNTED", "PDB1=READ WRITE",
        ('alter pluggable database "PDB1" close immediate;',)))
    checks.append(restore_case(
        "READ ONLY restored exactly", "PDB1=READ ONLY", "PDB1=READ WRITE",
        ('alter pluggable database "PDB1" close immediate;',
         'alter pluggable database "PDB1" open read only;')))
    checks.append(restore_case(
        "READ WRITE remains unchanged", "PDB1=READ WRITE", "PDB1=READ WRITE",
        forbidden_sql=("alter pluggable database",)))
    checks.append(restore_case(
        "mixed PDB states restored separately",
        "PDB1=MOUNTED;PDB2=READ ONLY;PDB3=READ WRITE",
        "PDB1=READ WRITE;PDB2=READ WRITE;PDB3=READ WRITE",
        ('alter pluggable database "PDB1" close immediate;',
         'alter pluggable database "PDB2" open read only;'),
        ('alter pluggable database "PDB3"',)))
    checks.append(restore_case(
        "one PDB restore mismatch fails closed",
        "PDB1=MOUNTED;PDB2=READ ONLY", "PDB1=READ WRITE;PDB2=READ WRITE",
        final="PDB1=MOUNTED;PDB2=READ WRITE", expect_success=False))
    checks.append(restore_case(
        "final restored-state query failure fails closed",
        "PDB1=MOUNTED", "PDB1=READ WRITE", after_rc=1,
        expect_success=False))
    checks.append(restore_case(
        "PDB seed remains rejected", "PDB$SEED=READ ONLY", "PDB$SEED=READ WRITE",
        forbidden_sql=("alter pluggable database",), expect_success=False))

    result, events = flow_case("successful CDB sequence")
    checks.append((result.returncode == 0 and
                   max(index for index, event in enumerate(events) if event == "SQLPATCH") <
                   events.index("RESTORE") < events.index("STATE:09_DATAPATCH_COMPLETE"),
                   "SQLPATCH validation precedes restore and state publication", result))

    result, events = flow_case("validation failure", validate_rc=1, expected_rc=1)
    checks.append(("RESTORE" in events and not any(item.startswith("STATE:") for item in events),
                   "SQLPATCH failure still attempts restore and never advances state", result))

    result, events = flow_case("validation and restore failure", validate_rc=1,
                               restore_rc=1, expected_rc=1)
    checks.append(("SQLPATCH" in events and "RESTORE" in events and
                   "FAILURE:RESTORE_PDB" in events and
                   not any(item.startswith("STATE:") for item in events),
                   "validation plus restore failure requires intervention", result))

    result, events = flow_case("final validation failure", final_validate_rc=1,
                               expected_rc=1)
    checks.append((events.count("SQLPATCH") == 2 and "RESTORE" in events and
                   "FAILURE:VALIDATION" in events and
                   not any(item.startswith("STATE:") for item in events),
                   "final SQLPATCH failure restores PDBs and never advances state", result))

    run_source = function("run_datapatch_all")
    final_source = function("validate_all")
    checks.append(("validate_datapatch_sqlpatch \"$sid\"" in run_source and
                   "validate_datapatch_sqlpatch \"$sid\" validation_sqlpatch" not in final_source and
                   "opg_completion_marker_valid" in final_source,
                   "final validation reuses bound pre-restore SQLPATCH evidence", subprocess.CompletedProcess([], 0)))

    for name, phase, final_validation in (
            ("invalid datapatch marker result", "DATAPATCH", False),
            ("SQLPATCH validation result", "DATAPATCH", False),
            ("final SQLPATCH validation result", "VALIDATION", True),
            ("datapatch marker result", "DATAPATCH", False),
            ("SQLPATCH validation marker result", "DATAPATCH", False),
            ("PDB restore result", "RESTORE_PDB", False)):
        checks.append(apply_result_case(name, "MANUAL_INTERVENTION_REQUIRED", phase,
                                        "MANUAL_INTERVENTION_REQUIRED", 50,
                                        final_validation))
    checks.append(apply_result_case("datapatch command remains PARTIAL", "PARTIAL",
                                    "DATAPATCH", "PARTIAL", 40))

    with tempfile.TemporaryDirectory(prefix="opg06-noncdb.") as directory:
        work = Path(directory)
        (work / "home").mkdir()
        baseline = write_baseline(work, "", cdb="NO")
        result = run(work, "OPG_DATABASE_BASELINE_FILE='{}'; export OPG_DATABASE_BASELINE_FILE; restore_pdb_state DB1".format(baseline),
                     ("restore_pdb_state",))
        checks.append((result.returncode == 0, "non-CDB restore remains a no-op", result))

    passed = 0
    for ok, name, result in checks:
        if ok:
            passed += 1
            print("PASS", name)
        else:
            print("FAIL", name, "rc=" + str(result.returncode))
            if result.stderr:
                print(result.stderr.strip())
    print("OPG-06 results: {} passed, {} failed".format(passed, len(checks) - passed))
    return int(passed != len(checks))


if __name__ == "__main__":
    raise SystemExit(main())
