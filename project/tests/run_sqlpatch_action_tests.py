#!/usr/bin/env python3
"""OPG-01: real generated SELECTs + Bash validators, isolated from Oracle.

SQLite exercises the portable MAX/equality selection; it does not prove Oracle
view visibility or datapatch execution. Only unrelated Oracle operations are
stubbed. Every subprocess receives a clean environment and temporary run root.
"""
from pathlib import Path
import re
import shlex
import sqlite3
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / "patchGD_guard.sh").read_text()
FUNCTIONS = ("write_sql_files", "validate_datapatch_sqlpatch_output",
             "validate_datapatch_sqlpatch", "run_datapatch_all", "validate_all")
CODE = "\n".join(re.search(r"^" + name + r"\(\) \{\n.*?^\}", SOURCE,
                           re.M | re.S).group() for name in FUNCTIONS)
OLD = "20200101120000000000"
NEW = "20200102120000000000"
PATCHES = (39472050, 39222882)


def shell(work, cdb, command):
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "HOME": str(work),
           "RUN_DIR": str(work), "RUN_ID": "ACTION-TEST", "HOST_NAME": "fixture",
           "TARGET_ORACLE_HOME": str(work / "home"), "DB_PATCH": str(PATCHES[0]),
           "OJVM_PATCH": str(PATCHES[1]), "OPG_TEST_MODE": "1",
           "SAFE_PATH": "/usr/bin:/bin", "EMCTL_PATH": "/bin/true", "CDB": cdb}
    harness = "source " + shlex.quote(str(ROOT / "lib/opg_core.sh")) + "\n" + CODE
    harness += r'''
opg_sqlplus() {
  printf '%s\n' "$2" >>"$RUN_DIR/sql_calls"
  if [[ "$2" == validation_DB1 ]]; then
    cat "$RUN_DIR/general" "$RUN_DIR/rows" >"$4"
  else
    cat "$RUN_DIR/rows" >"$4"
  fi
}
# PDB opening/restore and registry comparison are outside OPG-01.
prepare_pdbs_for_datapatch() { :; }
restore_pdb_state() { :; }
compare_registry_with_baseline() { :; }
'''
    return subprocess.run(["bash", "-c", harness + "\n" + command], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          universal_newlines=True)


def select_rows(work, cdb, containers, history):
    filename = "datapatch_sqlpatch_" + ("cdb" if cdb == "YES" else "noncdb") + ".sql"
    sql = (work / filename).read_text()
    query = re.search(r"select 'CDB_SQLPATCH.*?;", sql, re.S).group()
    db = sqlite3.connect(":memory:")
    db.create_function("to_char", 2, lambda value, _format: value)
    db.execute("create table cdb_registry_sqlpatch(con_id,patch_id,action,status,action_time)")
    db.execute("create table dba_registry_sqlpatch(con_id,patch_id,action,status,action_time)")
    db.execute('create table "v$containers"(con_id,name)')
    db.executemany('insert into "v$containers" values (?,?)', containers)
    for table in ("cdb_registry_sqlpatch", "dba_registry_sqlpatch"):
        db.executemany("insert into " + table + " values (?,?,?,?,?)", history)
    try:
        return "".join(row[0] + "\n" for row in db.execute(query))
    finally:
        db.close()


def check(scope, route, scenario):
    containers = {"noncdb": [(0, "NONCDB")], "root": [(1, "CDB$ROOT")],
                  "pdb": [(1, "CDB$ROOT"), (3, "PDB1"), (4, "PDB2")]}[scope]
    cdb = "NO" if scope == "noncdb" else "YES"
    with tempfile.TemporaryDirectory(prefix="opg01-action.") as directory:
        work = Path(directory)
        (work / "home").mkdir()
        pdbs = "PDB1=READ WRITE;PDB2=READ WRITE" if scope == "pdb" else ""
        (work / "database_state_before.csv").write_text(
            'SID,HOME,AUTOSTART,RUNNING,ROLE,MODE,CDB,PDB,LISTENER,SERVICES\n'
            '"DB1","{0}","Y","true","PRIMARY","READ WRITE","{1}","{2}","NONE","APP"\n'
            .format(work / "home", cdb, pdbs))
        (work / "invalid_objects_before.csv").write_text('SID,invalid_objects\n"DB1","0"\n')
        (work / "datapatch_expected_containers_DB1.psv").write_text(
            "".join("{}|{}\n".format(*item) for item in containers))
        (work / "general").write_text(
            "DB|DB1|PRIMARY|READ WRITE|{}\nPDB|{}\nSERVICES|APP\nINVALID|0\n"
            "SQLPATCH|39472050|SUCCESS\nSQLPATCH|39222882|SUCCESS\n".format(cdb, pdbs))
        generated = shell(work, cdb, "write_sql_files")
        assert generated.returncode == 0, generated.stderr
        history = [(cid, patch, "APPLY", "SUCCESS", OLD)
                   for cid, _ in containers for patch in PATCHES]
        target = (containers[-1][0], PATCHES[1])
        if scenario == "ru_rollback": target = (containers[-1][0], PATCHES[0])
        if scenario in ("rollback", "ru_rollback", "apply_then_rollback", "errors", "unknown", "tie"):
            action = "UNRECOGNIZED" if scenario == "unknown" else "ROLLBACK"
            status = "WITH ERRORS" if scenario == "errors" else "SUCCESS"
            if scenario == "errors": action = "APPLY"
            if scenario == "rollback":
                history = [row for row in history if row[:2] != target]
            history.append(target + (action, status, OLD if scenario == "tie" else NEW))
        elif scenario == "rollback_then_apply":
            history = [row for row in history if row[:2] != target]
            history.extend([target + ("ROLLBACK", "SUCCESS", OLD),
                            target + ("APPLY", "SUCCESS", NEW)])
        rows = select_rows(work, cdb, containers, history)
        lines = rows.splitlines()
        if scenario == "missing_action":
            # Remove ACTION only if emitted; old implementation already omits it.
            lines = ["|".join(line.split("|")[:4] + line.split("|")[5:])
                     if len(line.split("|")) == 7 else line for line in lines]
        elif scenario == "missing_combination": lines.pop()
        elif scenario == "duplicate": lines.append(lines[-1])
        elif scenario == "wrong_patch":
            fields = lines[-1].split("|")
            fields[3] = "99999999"
            lines[-1] = "|".join(fields)
        elif scenario == "wrong_container": lines[-1] = lines[-1].replace("|" + containers[-1][1] + "|", "|OTHER|")
        elif scenario == "extra_field": lines[-1] += "|"
        elif scenario == "partial_extra": lines.append("CDB_SQLPATCH|1")
        rows = "\n".join(lines) + "\n"
        if scenario == "truncated": rows = rows.rstrip("\n")[:-3]
        (work / "rows").write_text(rows)
        if route == "post":
            command = "run_datapatch_all"
        elif route == "marker":
            (work / "datapatch_DB1.log").write_text("historical successful invocation\n")
            command = ('opg_write_completion_marker "$RUN_DIR/datapatch_DB1.complete" '
                       '"$RUN_DIR/datapatch_DB1.log" DB1 datapatch\nrun_datapatch_all')
        else:
            command = "validate_all"
        result = shell(work, cdb, command)
        expected = scenario in ("apply", "rollback_then_apply", "historical")
        actual = result.returncode == 0
        # A valid historical marker must cause a fresh SELECT, never datapatch.
        if route == "marker":
            commands = (work / "commands.log").read_text() if (work / "commands.log").exists() else ""
            assert "COMMAND_START|label=datapatch_DB1|" not in commands
            assert "datapatch_sqlpatch_DB1" in (work / "sql_calls").read_text()
        if actual != expected:
            print("FAIL {} {} {} expected={} rc={}".format(scope, route, scenario, expected, result.returncode))
            return False
        return True


def main():
    passed = failed = 0
    for scope in ("noncdb", "root", "pdb"):
        for route in ("post", "marker", "final"):
            for scenario in ("apply", "rollback", "apply_then_rollback", "rollback_then_apply",
                             "ru_rollback", "errors", "missing_action", "unknown", "tie", "historical",
                             "missing_combination", "duplicate", "wrong_patch", "wrong_container",
                             "extra_field", "partial_extra", "truncated"):
                if check(scope, route, scenario): passed += 1
                else: failed += 1
    print("SQLPATCH ACTION results: {} passed, {} failed".format(passed, failed))
    return int(failed != 0)


if __name__ == "__main__":
    raise SystemExit(main())
