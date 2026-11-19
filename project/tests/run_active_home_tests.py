#!/usr/bin/env python3
"""Exercise lsof interpretation and PRECHECK without Oracle processes."""

import contextlib
import importlib.util
import io
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch


sys.dont_write_bytecode = True
PROJECT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("active_home", PROJECT / "lib/opg_active_home.py")
active_home = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(active_home)
HOME = b"/opt/oracle/dbhome_1"
PROCESS = b"p421\0cpython3\0u1001\0\n"


def mapping(path, fd=b"mem"):
    return b"f" + fd + b"\0tREG\0n" + path + b"\0\n"


class InspectionTests(unittest.TestCase):
    def test_pid_one_denial_has_limited_owner_scope(self):
        for uids, expected_error in (({0}, None), ({1001}, "pid=1 errno=13"),
                                     (set(), "pid=1 errno=13")):
            with self.subTest(uids=uids), \
                    patch.object(active_home, "proc_pids", return_value=[b"1"]), \
                    patch.object(active_home.os, "geteuid", return_value=1001), \
                    patch.object(active_home, "process_uids", return_value=uids), \
                    patch("builtins.open", side_effect=PermissionError(13, "Permission denied")), \
                    contextlib.redirect_stdout(io.StringIO()) as evidence:
                self.assertEqual(active_home.scan_proc(None), (set(), expected_error))
                self.assertEqual("PROC_COVERAGE_LIMITED" in evidence.getvalue(), expected_error is None)

    def inspect(self, rc, output=b"", stderr=b"", proc=(set(), None)):
        result = subprocess.CompletedProcess([], rc, output, stderr)
        evidence = io.StringIO()
        with patch.object(active_home.subprocess, "run", return_value=result) as command, \
                patch.object(active_home, "scan_proc", return_value=proc) as scan, \
                contextlib.redirect_stdout(evidence):
            status = active_home.main(os.fsdecode(HOME))
        command.assert_called_once_with(
            ["lsof", "-nP", "-a", "-d", "txt,mem,DEL", "-F0pcuftn"],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        return status, evidence.getvalue(), scan.call_count

    def test_external_executable_with_target_mappings(self):
        stdout = PROCESS + mapping(b"/usr/bin/python3", b"txt")
        for name in (b"libclntsh.so.19.1", b"libsqlplus.so", b"libother.so"):
            stdout += mapping(HOME + b"/lib/" + name)
        status, evidence, proc_calls = self.inspect(0, stdout)
        self.assertEqual(status, 20)
        self.assertEqual(proc_calls, 0)
        self.assertEqual(evidence.count("ACTIVE_HOME_FILE|pid=421|uid=1001|process=\"python3\""), 3)
        self.assertIn("libother.so", evidence)

    def test_deleted_mapping(self):
        status, evidence, _ = self.inspect(0, PROCESS + mapping(HOME + b"/other.so (deleted)", b"DEL"))
        self.assertEqual(status, 20)
        self.assertIn("other.so (deleted)", evidence)

    def test_other_home_with_same_prefix(self):
        stdout = PROCESS + mapping(HOME + b"0/bin/sqlplus", b"txt")
        status, evidence, proc_calls = self.inspect(0, stdout)
        self.assertEqual(status, 0)
        self.assertEqual(proc_calls, 1)
        self.assertIn("ACTIVE_HOME_SCAN_CLEAR", evidence)

    def test_empty_exit_one_requires_proc_corroboration(self):
        self.assertEqual(self.inspect(1)[0], 0)
        status, evidence, calls = self.inspect(1, proc=(set(), "pid=17 errno=13"))
        self.assertEqual(status, 30)
        self.assertEqual(calls, 1)
        self.assertIn("PROC_COVERAGE_UNKNOWN", evidence)

    def test_silent_lsof_omission_can_be_detected_via_proc(self):
        hit = (23, 101, b"oracle", HOME + b"/lib/additional.so")
        status, evidence, _ = self.inspect(1, proc=({hit}, "pid=17 errno=13"))
        self.assertEqual(status, 20)
        self.assertIn("additional.so", evidence)

    def test_unreliable_results(self):
        cases = [
            (0, b"", b""), (0, b"unrecognizable", b""),
            (0, PROCESS + b"fmem\0tREG\0", b""),
            (1, PROCESS, b""), (2, b"", b""), (124, b"", b""),
            (1, b"", b"lsof: permission denied"),
        ]
        for rc, stdout, stderr in cases:
            with self.subTest(rc=rc, stdout=stdout, stderr=stderr):
                status, evidence, calls = self.inspect(rc, stdout, stderr)
                self.assertEqual(status, 30)
                self.assertEqual(calls, 0)
                self.assertNotIn("ACTIVE_HOME_SCAN_CLEAR", evidence)

    def test_missing_lsof(self):
        with patch.object(active_home.subprocess, "run", side_effect=FileNotFoundError("lsof")), \
                contextlib.redirect_stdout(io.StringIO()):
            self.assertEqual(active_home.main(os.fsdecode(HOME)), 30)

    @unittest.skipUnless(shutil.which("lsof"), "lsof ontbreekt voor live fixture")
    def test_live_external_mapping(self):
        with tempfile.TemporaryDirectory(prefix="opg-active-file.") as tmp:
            path = Path(tmp) / "other-library.so"
            path.write_bytes(b"test mapping")
            code = "import mmap,sys; f=open(sys.argv[1],'rb'); "
            code += "m=mmap.mmap(f.fileno(),0,access=mmap.ACCESS_READ); f.close(); "
            code += "print('ready',flush=True); sys.stdin.read()"
            with subprocess.Popen([sys.executable, "-c", code, str(path)],
                                  stdin=subprocess.PIPE, stdout=subprocess.PIPE) as process:
                try:
                    self.assertEqual(process.stdout.readline(), b"ready\n")
                    evidence = io.StringIO()
                    with contextlib.redirect_stdout(evidence):
                        status = active_home.main(tmp)
                    self.assertEqual(status, 20, evidence.getvalue())
                    self.assertIn("pid={}".format(process.pid), evidence.getvalue())
                    self.assertIn(str(path), evidence.getvalue())
                finally:
                    process.stdin.close()


class NativePrerequisiteTests(unittest.TestCase):
    def test_acc_opatch_verdicts(self):
        passed = 'Prereq "checkActiveFilesAndExecutables" for patch 39915792 passed.\n'
        failed = 'Prereq "checkActiveFilesAndExecutables" for patch 39915792 failed.\n'
        incomplete = 'Prereq "checkActiveFilesAndExecutables" for patch 39915792 passed'
        cases = (
            ("passed", passed, "39915792", 0),
            ("failed", failed, "39915792", 20),
            ("different patch passed", passed, "39803650", 30),
            ("different patch failed", failed, "39803650", 30),
            ("contradictory", passed + failed, "39915792", 30),
            ("incomplete", incomplete, "39915792", 30),
            ("incomplete after pass", passed + incomplete, "39915792", 30),
            ("other patch after pass", passed + failed.replace("39915792", "39803650"), "39915792", 30),
        )
        source = (PROJECT / "patchGD_guard.sh").read_text(encoding="utf-8")
        definition = source.split("\nactive_files_prereq_result() {", 1)[1].split("\n}", 1)[0]
        script = "active_files_prereq_result() {" + definition + '\n}\nactive_files_prereq_result "$@"'
        with tempfile.TemporaryDirectory(prefix="opg-native-prereq.") as tmp:
            output = Path(tmp) / "prereq.log"
            for label, contents, patch_id, expected in cases:
                with self.subTest(label=label):
                    output.write_bytes(contents.encode("ascii"))
                    result = subprocess.run(["bash", "-c", script, "_", str(output), patch_id])
                    self.assertEqual(result.returncode, expected)


class PrecheckTests(unittest.TestCase):
    def find_processes(self, client):
        source = (PROJECT / "patchGD_guard.sh").read_text()
        function = source.split("\ndetect_home_processes() {", 1)[1].split("\n}", 1)[0]
        script = r'''
set -u
TARGET_ORACLE_HOME=$1
RUN_DIR=$2
unset OPG_TEST_MODE
opg_add_finding() { printf '%s|%s\n' "$1" "$2"; }
opg_manifest_sids() { printf 'TESTDB\n'; }
type() { return 1; }
''' + "detect_home_processes() {" + function + "\n}\ndetect_home_processes precheck\n"
        with tempfile.TemporaryDirectory(prefix="opg-precheck-proc.") as tmp:
            home = Path(tmp) / "dbhome"
            run = Path(tmp) / "run"
            (home / "bin").mkdir(parents=True)
            run.mkdir()
            processes = [("oracle", "ora_pmon_TESTDB"), ("tnslsnr", "tnslsnr")]
            if client:
                processes.append(("sqlplus", "sqlplus"))
            with contextlib.ExitStack() as stack:
                for binary, name in processes:
                    executable = home / "bin" / binary
                    shutil.copy2(shutil.which("sleep"), executable)
                    process = stack.enter_context(subprocess.Popen([name, "15"], executable=str(executable)))
                    stack.callback(process.terminate)
                output = subprocess.check_output(["bash", "-c", script, "_", str(home), str(run)])
                evidence = (run / "home_processes.txt").read_text()
                self.assertIn("/bin/oracle|ora_pmon_TESTDB", evidence)
                self.assertIn("/bin/tnslsnr|tnslsnr", evidence)
                return output

    def test_database_and_listener_are_expected(self):
        output = self.find_processes(False)
        self.assertNotIn(b"HOME_CLIENT_ACTIVE", output)
        self.assertNotIn(b"BLOCKED", output)

    def test_sqlplus_is_conditional(self):
        self.assertIn(b"CONDITIONAL|HOME_CLIENT_ACTIVE", self.find_processes(True))


if __name__ == "__main__":
    unittest.main(verbosity=2)
