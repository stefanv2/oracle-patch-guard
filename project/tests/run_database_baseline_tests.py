#!/usr/bin/env python3
"""Focused OPG-02 database-baseline binding and mutation-boundary tests."""

from pathlib import Path
import hashlib
import json
import re
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]
GUARD = (ROOT / "patchGD_guard.sh").read_text()
HEADER = ("SID,ORACLE_HOME,oratab_autostart,instance_running,database_role,"
          "open_mode,CDB,PDB_status,listener,services")
HOME = "/u01/app/oracle/product/19/dbhome_1"


def row(sid="DB1", home=HOME, running="true"):
    values = (sid, home, "Y", running, "PRIMARY", "READ WRITE", "NO", "",
              "LISTENER", "APP")
    return ",".join('"' + value + '"' for value in values)


def baseline(rows):
    return (HEADER + "\n" + "\n".join(rows) + "\n").encode()


def manifest(path, data, count=None, digest=None, schema=2, include_hash=True):
    document = {"schema_version": schema, "target_oracle_home": HOME,
                "database_count": len(data) if count is None else count,
                "database_state_file": "database_state_before.csv"}
    if include_hash:
        document["database_state_before_sha256"] = (
            hashlib.sha256(path.read_bytes()).hexdigest() if digest is None else digest)
    return document


def guard_function(name):
    match = re.search(r"^" + name + r"\(\) \{\n.*?^\}", GUARD, re.M | re.S)
    if not match:
        raise RuntimeError("function not found: " + name)
    return match.group()


def shell(work, command, functions=()):
    env = {"PATH": "/usr/bin:/bin", "LANG": "C", "RUN_DIR": str(work),
           "RUN_ID": "OPG02", "TARGET_ORACLE_HOME": HOME,
           "HOST_NAME": "fixture", "EXEC_USER": "oracle", "DRY_RUN": "false"}
    code = "source '" + str(ROOT / "lib/opg_core.sh") + "'\n"
    code += "\n".join(guard_function(name) for name in functions) + "\nset -u\n" + command
    return subprocess.run(["bash", "-o", "pipefail", "-c", code], env=env,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)


def prepare_case(name, content, mutate=None, **manifest_args):
    with tempfile.TemporaryDirectory(prefix="opg02-baseline.") as directory:
        work = Path(directory)
        source = work / "database_state_before.csv"
        if content is not None:
            source.write_bytes(content)
        document = manifest(source, [1], **manifest_args) if source.exists() else {
            "schema_version": 2, "target_oracle_home": HOME, "database_count": 1,
            "database_state_file": "database_state_before.csv",
            "database_state_before_sha256": "0" * 64}
        (work / "patch_manifest.json").write_text(json.dumps(document) + "\n")
        if mutate:
            mutate(source, work / "patch_manifest.json")
        result = shell(work, "opg_prepare_database_baseline_snapshot \"$RUN_DIR/patch_manifest.json\"")
        return name, result


def main():
    good_one = baseline([row()])
    good_two = baseline([row("DB1"), row("DB2")])
    checks = []

    checks.append((*prepare_case("valid single database", good_one), True))
    checks.append((*prepare_case("valid multiple databases", good_two, count=2), True))
    checks.append((*prepare_case("removed database row", good_two, count=2,
                                 mutate=lambda p, _m: p.write_bytes(good_one)), False))
    checks.append((*prepare_case("empty baseline", good_one,
                                 mutate=lambda p, _m: p.write_bytes(b"")), False))
    checks.append((*prepare_case("missing baseline", good_one,
                                 mutate=lambda p, _m: p.unlink()), False))
    checks.append((*prepare_case("changed SID", good_one,
                                 mutate=lambda p, _m: p.write_bytes(baseline([row("OTHER")]))), False))
    checks.append((*prepare_case("changed state", good_one,
                                 mutate=lambda p, _m: p.write_bytes(baseline([row(running="false")]))), False))
    checks.append((*prepare_case("changed Oracle Home", good_one,
                                 mutate=lambda p, _m: p.write_bytes(baseline([row(home="/other/home")]))), False))
    checks.append((*prepare_case("signed row from wrong Oracle Home",
                                 baseline([row(home="/other/home")])), False))
    checks.append((*prepare_case("empty SID", baseline([row("")])), False))
    checks.append((*prepare_case("duplicate SID", baseline([row(), row()]), count=2), False))
    checks.append((*prepare_case("database count mismatch", good_one, count=2), False))
    checks.append((*prepare_case("non-positive database count", good_one, count=0), False))
    checks.append((*prepare_case("wrong manifest hash", good_one, digest="1" * 64), False))
    checks.append((*prepare_case("missing manifest hash", good_one, include_hash=False), False))
    checks.append((*prepare_case("malformed manifest hash", good_one, digest="xyz"), False))
    checks.append((*prepare_case("old manifest schema", good_one, schema=1), False))
    checks.append((*prepare_case("wrong header", good_one,
                                 mutate=lambda p, _m: p.write_bytes(b"SID,HOME\n\"DB1\",\"x\"\n")), False))

    with tempfile.TemporaryDirectory(prefix="opg02-symlink.") as directory:
        work = Path(directory)
        target = work / "target.csv"
        target.write_bytes(good_one)
        (work / "database_state_before.csv").symlink_to(target)
        document = manifest(target, [1])
        (work / "patch_manifest.json").write_text(json.dumps(document) + "\n")
        result = shell(work, "opg_prepare_database_baseline_snapshot \"$RUN_DIR/patch_manifest.json\"")
        checks.append(("symlink baseline", result, False))

    with tempfile.TemporaryDirectory(prefix="opg02-snapshot.") as directory:
        work = Path(directory)
        source = work / "database_state_before.csv"
        source.write_bytes(good_one)
        (work / "patch_manifest.json").write_text(json.dumps(manifest(source, [1])) + "\n")
        result = shell(work, r'''
opg_prepare_database_baseline_snapshot "$RUN_DIR/patch_manifest.json"
printf '%s' 'changed after validation' >"$RUN_DIR/database_state_before.csv"
[[ "$(opg_read_original_state DB1 running)" == true ]]
''')
        checks.append(("validated snapshot remains the consumed baseline", result, True))

    def route_case(name, route, state="", schema=2, tamper=True):
        directory = tempfile.TemporaryDirectory(prefix="opg02-route.")
        work = Path(directory.name)
        source = work / "database_state_before.csv"
        source.write_bytes(good_one)
        (work / "patch_manifest.json").write_text(
            json.dumps(manifest(source, [1], schema=schema)) + "\n")
        if tamper:
            source.write_bytes(baseline([row(running="false")]))
        common = r'''
opg_mark_failure() { :; }; opg_result_line() { :; }; report_approval_blocked() { :; }
initialize_local_media() { :; }; opg_acquire_lock() { :; }; opg_release_lock() { :; }
opg_write_state() { :; }; verify_resume_environment() { :; }
perform_preapply_recheck() { :; }; opg_verify_manifest_hash() { :; }
verify_approval() { :; }; confirm_interactive_apply() { :; }; opg_sha256() { command sha256sum "$1" | awk '{print $1}'; }
perform_opatch_upgrade() { echo OPATCH >>"$RUN_DIR/mutations"; }
stop_databases() { echo STOP >>"$RUN_DIR/mutations"; }
apply_binary_patches() { echo PATCH >>"$RUN_DIR/mutations"; }
start_original_databases() { echo START >>"$RUN_DIR/mutations"; }
run_datapatch_all() { echo DATAPATCH >>"$RUN_DIR/mutations"; }
run_utlrp_all() { echo UTLRP >>"$RUN_DIR/mutations"; }
validate_all() { echo VALIDATE >>"$RUN_DIR/mutations"; }
'''
        if route == "apply":
            command = common + r'''
cp "$RUN_DIR/patch_manifest.json" "$RUN_DIR/approved"; touch "$RUN_DIR/token"
APPROVED_MANIFEST="$RUN_DIR/approved"; APPROVAL_TOKEN="$RUN_DIR/token"
REQUEST_OS_UPDATE=false; REQUEST_REBOOT=false; LOCAL_MEDIA_MODE=disabled
load_run_context() { CURRENT_STATE=03_PLAN_GENERATED; CURRENT_PHASE=PLAN; }
if perform_apply; then rc=0; else rc=$?; fi
[[ $rc -eq 20 && ! -e "$RUN_DIR/mutations" ]]
'''
            funcs = ("perform_apply",)
        else:
            current, phase = state.split(":", 1)
            command = common + "\nload_run_context() { CURRENT_STATE=" + current + "; CURRENT_PHASE=" + phase + "; LOCAL_MEDIA_MODE=disabled; }\n" + r'''
if perform_resume; then rc=0; else rc=$?; fi
[[ $rc -eq 50 && ! -e "$RUN_DIR/mutations" ]]
'''
            funcs = ("perform_resume",)
        result = shell(work, command, funcs)
        directory.cleanup()
        return name, result, True

    checks.append(route_case("changed baseline stops APPLY before mutation", "apply"))
    checks.append(route_case("old manifest stops APPLY before mutation", "apply",
                             schema=1, tamper=False))
    checks.append(route_case("changed baseline stops early resume before mutation", "resume",
                             "MEDIA_VALIDATED:OPATCH_UPGRADE"))
    checks.append(route_case("changed baseline stops binary resume before mutation", "resume",
                             "PARTIAL:DB_BINARY"))
    checks.append(route_case("changed baseline stops datapatch resume before mutation", "resume",
                             "PARTIAL:DATAPATCH"))

    checks.append(("manifest publishes signed baseline field",
                   subprocess.CompletedProcess([], 0 if (
                       '"schema_version": 2' in guard_function("write_patch_manifest") and
                       '"database_state_before_sha256": "$baseline_hash"' in
                       guard_function("write_patch_manifest")) else 1, "", ""), True))

    failures = []
    for name, result, should_pass in checks:
        passed = result.returncode == 0
        if passed != should_pass:
            failures.append((name, result))
        else:
            print("PASS", name)
    if failures:
        for name, result in failures:
            print("FAIL", name, "rc=" + str(result.returncode))
            if result.stderr:
                print(result.stderr.strip())
        print("FAILED: {}/{}".format(len(failures), len(checks)))
        return 1
    print("PASS: {}/{}".format(len(checks), len(checks)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
